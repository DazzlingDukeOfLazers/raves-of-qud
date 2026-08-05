using System;
using System.Collections.Generic;
using ConsoleLib.Console;   // Location2D not needed; kept minimal
using Qud.UI;               // PopupMessage, QudMenuItem, QudTextMenuController, UITextSkin, ControlledTMPInputField
using UnityEngine;          // GameObject.activeSelf on the input box
using XRL;                  // GameManager, The
using XRL.UI;               // UIManager

namespace RavesOfQud
{
    /// <summary>
    /// Mirrors Qud's modal popups (Popup.Show / ShowSpace / ShowYesNo / PickOption / AskString — all of
    /// which route through <c>UIManager.getWindow("PopupMessage")</c>) to Raves, and injects the viewer's
    /// answer back so Qud's blocked turn thread unblocks.
    ///
    /// Threading: a popup blocks the TURN thread inside WaitNewPopupMessage → awaitTask. But the UI thread
    /// keeps drawing the popup and draining <c>uiQueue</c> the whole time (the popup itself was shown via
    /// awaitTask, and its MonoBehaviour Update() runs every frame). So we do ALL Unity access on a
    /// self-requeuing uiQueue watcher: it can read the live PopupMessage and invoke its dismiss methods
    /// even while the turn thread is parked. Detection can't live in Tick/TickRender because those run on
    /// the turn thread (Tick) or may not fire mid-popup — the watcher is the reliable pump.
    ///
    /// Wire: on a state change we broadcast {"type":"popup", "active":true, ...} (or active:false). Raves
    /// ALSO hides its overlay on any normal snapshot — a snapshot can only publish once the turn thread has
    /// unblocked, i.e. the popup is already gone — so a coalesced-away active:false frame can't strand it.
    /// </summary>
    public static class PopupBridge
    {
        private static volatile bool _pumping;
        private static volatile bool _resend;   // set on client-connect → re-broadcast the live popup once
        private static int _id;
        private static bool _active;
        private static string _sig = "";
        private static int _lastPollMs;
        private static PopupMessage _pm;        // cached visible popup — checked cheaply each poll (Visible)
        private static int _lastScanMs;         // throttles the scene scan that finds a fresh popup
        // The exact instance whose content was last ANNOUNCED to Raves. Answers target
        // THIS instance: async copies (NewPopupMessageAsync/copyWindow — ShowYesNoAsync,
        // PickOptionAsync, AskString) can vanish from FindObjectsByType by answer-time,
        // and a re-scan then hits a decoy singleton — the injected answer went nowhere.
        private static PopupMessage _announcedPm;

        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        /// <summary>
        /// The currently-visible Qud popup, or null. Qud shows modals via TWO windows: the singleton
        /// (WaitNewPopupMessage's off-UI-thread path — most in-turn popups) AND a per-popup COPY
        /// (NewPopupMessageAsync via UIManager.copyWindow — AskString and UI-thread-triggered popups, view
        /// "DynamicPopupMessage"). getWindow("PopupMessage") only sees the singleton, so we scan for any
        /// visible PopupMessage. The find is cached: while one stays up we just re-check .Visible (cheap);
        /// the scene scan is throttled so idle frames don't pay for it.
        /// </summary>
        // A popup is LIVE only while it still has a pending callback — OnActivateCommand/OnSelect null it out
        // on dismiss. NewPopupMessageAsync leaves dismissed copies momentarily visible, so "visible" alone
        // picks up ghosts (seen as a stale inputBox + empty buttons); require a live callback too.
        private static bool IsLive(PopupMessage w)
        {
            try { return w != null && w.Visible && (w.commandCallback != null || w.selectCallback != null); }
            catch { return false; }
        }

        /// UIManager pools its popup COPIES in a private static Queue (copyWindow dequeues,
        /// releaseCopy enqueues). A RELEASED copy can still look "live" — visible with a
        /// non-null callback — so a plain scan picks pooled ghosts, and answers vanished
        /// into them (the copyWindow class: ShowYesNoAsync / PickOptionAsync / AskString).
        /// The IN-USE popup is the one that is NOT in the free pool.
        private static bool InFreePool(PopupMessage w)
        {
            try
            {
                var f = typeof(UIManager).GetField("popupMessages",
                    System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
                var q = f?.GetValue(null) as System.Collections.IEnumerable;
                if (q == null) return false;
                foreach (object o in q) if (ReferenceEquals(o, w)) return true;
            }
            catch { }
            return false;
        }

        private static PopupMessage FindVisiblePopup(bool force)
        {
            if (IsLive(_pm) && !InFreePool(_pm)) return _pm;
            _pm = null;
            try
            {
                var s = UIManager.getWindow("PopupMessage") as PopupMessage;
                if (IsLive(s) && !InFreePool(s)) return _pm = s;
            }
            catch { }
            int now = Environment.TickCount;
            if (!force && now - _lastScanMs < 120) return null;   // dynamic-copy scan: ~8 Hz when idle
            _lastScanMs = now;
            try
            {
                var all = UnityEngine.Object.FindObjectsByType<PopupMessage>(FindObjectsSortMode.None);
                for (int i = 0; i < all.Length; i++)
                    if (IsLive(all[i]) && !InFreePool(all[i])) return _pm = all[i];
            }
            catch { }
            return null;
        }

        /// <summary>Called (on the accept thread) when a client connects. A popup is published only on
        /// change, so a viewer that connects — or a rebuilt Raves that reconnects — WHILE a modal is up
        /// would otherwise never learn of it (the turn thread is blocked, so no snapshot flows either).
        /// Flag a one-shot re-broadcast of the current popup on the next poll.</summary>
        public static void OnClientConnect() { _resend = true; }

        /// <summary>Idempotent — starts the UI-thread watcher if it isn't already running. Called from the
        /// per-turn / per-frame ticks so a game load (or a torn-down + rebuilt uiQueue) re-arms it.</summary>
        public static void Ensure()
        {
            if (_pumping) return;
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            _pumping = true;
            Kick(gm);
        }

        private static void Kick(GameManager gm)
        {
            try
            {
                gm.uiQueue.queueTask(delegate
                {
                    try { Poll(); } catch (Exception e) { Log("popup poll: " + e.Message); }
                    GameManager g = GameManager.Instance;
                    if (g != null && g.uiQueue != null) Kick(g); else _pumping = false;   // stop; Ensure() re-arms
                }, 0);
            }
            catch { _pumping = false; }
        }

        /// UI THREAD. Detect the active PopupMessage, and publish a popup frame whenever its state changes
        /// (appeared / content changed / dismissed). Signature-gated so we send once per distinct state.
        private static void Poll()
        {
            int now = Environment.TickCount;
            if (now - _lastPollMs < 33) return;   // ~30 Hz is plenty; the check is cheap but not free
            _lastPollMs = now;

            BridgeServer server = Bridge.Server;
            if (server == null || server.ClientCount == 0) return;

            bool resend = _resend;   // one-shot: a client just connected — re-broadcast the live popup
            _resend = false;

            PopupMessage pm = FindVisiblePopup(false);
            // Believed-active but not found? FORCE the full scan before declaring a
            // dismissal: the cheap path rate-limits the dynamic-copy scan (~8 Hz), so a
            // one-poll IsLive hiccup on an AskString COPY published a false
            // active:false + a fresh-id reshow — which reset the text the user was
            // typing in Raves ("kept resetting as I tried to type QUIT").
            if (pm == null && _active) pm = FindVisiblePopup(true);
            bool active = pm != null;

            if (!active)
            {
                if (_active)
                {
                    _active = false;
                    _sig = "";
                    _announcedPm = null;
                    var jc = new JsonWriter();
                    jc.BeginObject().Member("type", Protocol.TypePopup).Member("active", false).Member("id", ++_id).EndObject();
                    Publish(server, jc.ToString());
                }
                return;
            }

            List<QudMenuItem> buttons = pm.controller != null ? pm.controller.bottomContextOptions : null;
            List<QudMenuItem> options = pm.controller != null ? pm.controller.menuData : null;
            bool input = pm.inputBox != null && pm.inputBox.gameObject.activeSelf;
            string message = pm.Message != null ? pm.Message.text : "";
            string title = pm.Title != null ? pm.Title.text : "";
            string inputDefault = input ? (pm.inputBox.text ?? "") : "";

            string sig = Sig(message, title, buttons, options, input, inputDefault);
            _announcedPm = pm;   // answers target the instance Raves is looking at
            if (_active && sig == _sig && !resend) return;   // same popup, same content — Raves already has it
            _active = true;
            _sig = sig;

            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypePopup);
            j.Member("active", true);
            j.Member("id", ++_id);
            j.Member("message", message ?? "");
            j.Member("title", title ?? "");
            j.Member("input", input);
            j.Member("inputDefault", inputDefault);
            j.Member("kind", input ? "input" : (options != null && options.Count > 0 ? "menu" : "message"));
            WriteItems(j, "buttons", buttons);
            WriteItems(j, "options", options);
            j.EndObject();
            Publish(server, j.ToString());
        }

        private static void WriteItems(JsonWriter j, string name, List<QudMenuItem> items)
        {
            j.Name(name).BeginArray();
            if (items != null)
                foreach (QudMenuItem it in items)
                    j.BeginObject()
                        .Member("text", it.text ?? "")
                        .Member("command", it.command ?? "")
                        .Member("hotkey", it.hotkey ?? "")
                     .EndObject();
            j.EndArray();
        }

        private const char SEP = '\u0001';   // unit separator; never occurs in popup text

        private static string Sig(string msg, string title, List<QudMenuItem> b, List<QudMenuItem> o, bool input, string inDef)
        {
            var sb = new System.Text.StringBuilder();
            sb.Append(msg).Append(SEP).Append(title).Append(SEP).Append(input ? '1' : '0').Append(inDef).Append(SEP);
            if (b != null) foreach (var it in b) sb.Append(it.command).Append('|');
            sb.Append(SEP);
            if (o != null) foreach (var it in o) sb.Append(it.text).Append('|');
            return sb.ToString();
        }

        private static void Publish(BridgeServer server, string json)
        {
            try { server.Publish(Protocol.Frame(json)); }
            catch (Exception e) { Log("popup publish: " + e.Message); }
        }

        /// <summary>Handle a "popup" command from Raves. Runs on the SOCKET thread, so it just marshals the
        /// dismissal onto the uiQueue — which drains on the UI thread even while the turn thread is parked
        /// in the popup. Invoking OnActivateCommand / OnSelect / OnInputSubmit fires Qud's callback and
        /// Hide()s the popup, unblocking the turn thread.</summary>
        public static void HandleCommand(Dictionary<string, string> f)
        {
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            f.TryGetValue("action", out string action);
            f.TryGetValue("btn", out string btn);
            f.TryGetValue("index", out string indexStr);
            f.TryGetValue("text", out string text);
            gm.uiQueue.queueTask(delegate
            {
                try
                {
                    // Target the ANNOUNCED instance first — async copies (ShowYesNoAsync /
                    // PickOptionAsync / AskString via copyWindow) can vanish from a re-scan
                    // by answer-time, which used to hand the answer to a decoy singleton.
                    PopupMessage pm = _announcedPm;
                    bool held = false;
                    try { held = pm != null && pm.Visible; } catch { pm = null; }
                    if (!held) pm = FindVisiblePopup(true);
                    if (pm == null) { Log("[popup] answer: no target"); return; }
                    Log("[popup] answer -> " + action + " held=" + held + " live=" + IsLive(pm)
                        + " inst=" + pm.GetInstanceID());
                    List<QudMenuItem> buttons = pm.controller != null ? pm.controller.bottomContextOptions : null;
                    List<QudMenuItem> options = pm.controller != null ? pm.controller.menuData : null;

                    if (action == "option")
                    {
                        if (int.TryParse(indexStr, out int idx) && options != null && idx >= 0 && idx < options.Count)
                            pm.OnSelect(options[idx]);
                    }
                    else if (action == "input")
                    {
                        // Qud's own submit path (OnInputSubmit -> OnSelect on the Submit/
                        // Accept button) — with the HELD copy this now reaches AskString too.
                        if (pm.inputBox != null) pm.inputBox.text = text ?? "";
                        pm.OnInputSubmit(text ?? "");
                    }
                    else
                    {
                        // "button" / "cancel": dismiss with the matching bottom button (or a fabricated one).
                        QudMenuItem chosen = FindByCommand(buttons, btn);
                        if (string.IsNullOrEmpty(chosen.command)) chosen = new QudMenuItem { command = btn ?? "Accept", text = btn ?? "" };
                        pm.OnActivateCommand(chosen);
                    }
                    // The answered callback usually completes a TaskCompletionSource whose
                    // awaiting chain resumes through Unity's SynchronizationContext — which
                    // macOS stops draining for an UNFOCUSED window. Pump it so the follow-on
                    // (next popup, screen close, keymap load…) happens now, not on next focus.
                    Bridge.PumpSyncContext(8);
                }
                catch (Exception e) { Log("popup cmd: " + e.Message); }
            }, 0);
        }

        private static QudMenuItem FindByCommand(List<QudMenuItem> items, string command)
        {
            if (items != null && command != null)
                foreach (QudMenuItem it in items)
                    if (string.Equals(it.command, command, StringComparison.OrdinalIgnoreCase))
                        return it;
            return default(QudMenuItem);
        }

        private static QudMenuItem FindButton(List<QudMenuItem> items, params string[] commands)
        {
            if (items != null)
                foreach (string c in commands)
                {
                    QudMenuItem hit = FindByCommand(items, c);
                    if (!string.IsNullOrEmpty(hit.command)) return hit;
                }
            // Fall back to the first button, else an Accept.
            if (items != null && items.Count > 0) return items[0];
            return new QudMenuItem { command = "Accept" };
        }
    }
}

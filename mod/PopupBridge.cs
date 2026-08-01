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

        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

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

            PopupMessage pm = UIManager.getWindow("PopupMessage") as PopupMessage;
            bool active = pm != null && pm.Visible;

            if (!active)
            {
                if (_active)
                {
                    _active = false;
                    _sig = "";
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
                    PopupMessage pm = UIManager.getWindow("PopupMessage") as PopupMessage;
                    if (pm == null || !pm.Visible) return;
                    List<QudMenuItem> buttons = pm.controller != null ? pm.controller.bottomContextOptions : null;
                    List<QudMenuItem> options = pm.controller != null ? pm.controller.menuData : null;

                    if (action == "option")
                    {
                        if (int.TryParse(indexStr, out int idx) && options != null && idx >= 0 && idx < options.Count)
                            pm.OnSelect(options[idx]);
                        return;
                    }
                    if (action == "input")
                    {
                        if (pm.inputBox != null) pm.inputBox.text = text ?? "";
                        // Submit through the accept/submit bottom button; its callback reads inputBox.text.
                        QudMenuItem acc = FindButton(buttons, "keep", "Accept", "Submit");
                        pm.OnActivateCommand(acc);
                        return;
                    }
                    // "button" / "cancel": dismiss with the matching bottom button (or a fabricated one).
                    QudMenuItem chosen = FindByCommand(buttons, btn);
                    if (string.IsNullOrEmpty(chosen.command)) chosen = new QudMenuItem { command = btn ?? "Accept", text = btn ?? "" };
                    pm.OnActivateCommand(chosen);
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

using System;
using System.IO;
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
        // The announce ids that belong to the popup CURRENTLY on screen. A NEW popup bumps `_id`;
        // a RE-announce of the same one does NOT (see Poll), so in practice an episode is a single
        // id -- but a close frame bumps it too, and clients answer asynchronously, so the range is
        // still what decides. The episode's FIRST id pins the lower bound: ids are monotonic and an
        // episode is contiguous, so [_episodeMinId, _id] is exactly this popup and nothing before it.
        private static int _episodeMinId;

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

        /// <summary>UI THREAD. Export the LIVE popup's chrome sprites — the same walk
        /// <see cref="TitleExporter"/> runs over the main menu, pointed at whatever modal is on
        /// screen right now, so they land as real PNGs in <c>&lt;support&gt;/title/chrome/</c>
        /// beside the rest.
        ///
        /// It has to be the LIVE instance and it has to be here. The popup's chrome comes off a
        /// SpriteAtlas, so a name lookup through <c>Resources.FindObjectsOfTypeAll&lt;Sprite&gt;()</c>
        /// finds nothing (UiProbe records the same trap) — the Image that is drawing it is the only
        /// handle. And a popup parks Qud's TURN thread, so the main-thread command queue that
        /// Tick/TickRender drains may never drain while one is up; the uiQueue this rides on does,
        /// which is the whole reason the mirror watcher lives there too.</summary>
        public static bool ExportChrome()
        {
            PopupMessage pm = FindVisiblePopup(true);
            if (pm == null) { Log("[popup] chrome export: no live popup"); return false; }
            int n = TitleExporter.ExportChromeUnder(pm.transform, "popup_chrome_dump.txt");
            Log("[popup] chrome export: " + n + " sprites from " + pm.gameObject.name);
            return n > 0;
        }

        /// <summary>Called (on the accept thread) when a client connects. A popup is published only on
        /// change, so a viewer that connects — or a rebuilt Raves that reconnects — WHILE a modal is up
        /// would otherwise never learn of it (the turn thread is blocked, so no snapshot flows either).
        /// Flag a one-shot re-broadcast of the current popup on the next poll.</summary>
        public static void OnClientConnect() { _resend = true; PickerBridge.OnClientConnect(); CyberBridge.OnClientConnect(); }

        // ---- watcher liveness ------------------------------------------------------------
        // `_pumping` on its own is a flag that cannot fail. The watcher is a task that
        // re-queues ITSELF, so if the uiQueue it rides on is torn down and rebuilt (a game
        // load), the old chain simply stops running and nothing ever clears the flag —
        // Ensure() then reports "already armed" over a dead watcher, forever.
        //
        // So do not ask the flag, ask for PROOF OF LIFE: the chain stamps `_aliveMs` on every
        // drain, and Ensure() re-arms whenever that stamp goes stale. `_pumpGen` retires the
        // old chain on a re-arm, so healing a dead watcher can never leave two pumps running.
        private static volatile int _aliveMs;
        private static volatile int _pumpGen;
        private const int PumpStaleMs = 2000;   // ~60 missed 30Hz polls: dead, not merely busy

        /// <summary>Is the mirror's watcher actually RUNNING (not merely flagged as started)?</summary>
        public static bool WatcherAlive
        {
            get { return _pumping && unchecked(Environment.TickCount - _aliveMs) < PumpStaleMs; }
        }

        /// <summary>Idempotent — starts (or re-starts) the UI-thread watcher unless one is
        /// provably alive.
        ///
        /// WHERE THIS IS CALLED FROM MATTERS. It used to be called from `Bridge.TickRender`
        /// and nowhere else, and `TickRender` rides `BeforeRenderEvent`, which does not fire
        /// while a modal has Qud's turn thread parked. That made the arming unreachable in
        /// exactly the case it exists for: a popup that opens before the watcher is armed
        /// blocks the only thing that would arm it. It is now driven by the mod's own
        /// heartbeat thread (StartupHook), which runs once a second regardless of focus,
        /// turns, render frames, or whether a game is live at all.</summary>
        public static void Ensure()
        {
            if (WatcherAlive) return;
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            int gen = ++_pumpGen;
            _pumping = true;
            _aliveMs = Environment.TickCount;   // grace: don't re-arm again before the first drain
            Log("[popup] arming the mirror watcher (gen " + gen + ")");
            Kick(gm, gen);
        }

        private static void Kick(GameManager gm, int gen)
        {
            try
            {
                gm.uiQueue.queueTask(delegate
                {
                    if (gen != _pumpGen) return;        // a newer chain took over — retire quietly
                    _aliveMs = Environment.TickCount;   // proof of life, BEFORE Poll's own rate limit
                    try { InputDiag.Sample(); InputDiag.SamplePopup(); } catch { }
                    try { Poll(); } catch (Exception e) { Log("popup poll: " + e.Message); }
                    GameManager g = GameManager.Instance;
                    if (g != null && g.uiQueue != null) Kick(g, gen);
                    else if (gen == _pumpGen) _pumping = false;   // stop; Ensure() re-arms
                }, 0);
            }
            catch { if (gen == _pumpGen) _pumping = false; }
        }

        /// <summary>The status screens' ACTIVE TAB ("Tinkering", "Journal", "Quests", ...), cached
        /// here for the heartbeat to report.
        ///
        /// The heartbeat runs on its own thread and may only touch plain fields, so it cannot walk
        /// the screen itself: StatusScreensScreen.CurrentScreen is an int index into Screens, and
        /// turning that into a name means reading a Transform, which is a Unity call. This watcher
        /// is already on the UI thread at ~30Hz, so it does the read and leaves a string behind.
        ///
        /// Without this, highvisor can see "the status screens are open" but not WHICH tab, so no
        /// gametree node below status_screens had a Qud detector and `hv assert --node
        /// status_tinkering` could never pass for Qud -- only for Raves.</summary>
        public static string StatusTab = "";

        /// <summary>Journal SUB-TAB header widths, keyed by the header string, measured by Qud's own
        /// TMP component.
        ///
        /// The journal header block is closed by a 1px tick whose x is the text's laid-out width --
        /// and Qud measures "Locations" at 143.04 where Source Code Pro's 24px advance gives 129.6.
        /// The extra 13.44 is either per-character tracking or a fixed pad; ONE sample cannot tell
        /// those apart, and they disagree for every other string. So do not model it: ask the live
        /// component. TMP_Text.GetPreferredValues(s) measures any string with the element's own font,
        /// size and spacing WITHOUT disturbing what it is showing, so all seven sub-tabs can be
        /// measured off the one header Qud has laid out.
        ///
        /// Filled once per visit to the Journal tab (the metrics cannot change while it is up) and
        /// dropped on the way out, so a font/scale change is re-measured next time.</summary>
        public static readonly System.Collections.Generic.Dictionary<string, float> JournalHeaderW
            = new System.Collections.Generic.Dictionary<string, float>();

        /// UI THREAD.
        private static void PollJournalHeader()
        {
            try
            {
                if (StatusTab != "Journal") { JournalHeaderW.Clear(); return; }
                if (JournalHeaderW.Count > 0) return;          // already measured this visit
                var jr = UnityEngine.Object.FindObjectOfType<Qud.UI.JournalStatusScreen>();
                if (jr == null) return;
                var t = jr.transform.Find("JournalHeader/Header");
                if (t == null) return;
                var tmp = t.GetComponent<TMPro.TextMeshProUGUI>();
                if (tmp == null) return;
                foreach (var tab in JournalExporter.Tabs)
                {
                    if (string.IsNullOrEmpty(tab)) continue;
                    string nm;
                    try { nm = XRL.UI.JournalScreen.GetTabDisplayName(tab) ?? tab; }
                    catch { nm = tab; }
                    if (JournalHeaderW.ContainsKey(nm)) continue;
                    JournalHeaderW[nm] = tmp.GetPreferredValues(nm).x;
                }
            }
            catch { }
        }

        /// <summary>The ability bar's per-cell WIDTHS, in bar order, as a CSV.
        ///
        /// Qud sizes each cell to its content and then shares out the slack, and Godot shares that
        /// slack EQUALLY between expanding children where Unity distributes it by flexible width --
        /// so the same content lands on different widths and no amount of matching padding or
        /// spacing fixes it (rebuilding our cell to Qud's exact nesting made the bar worse, because
        /// correct padding leaves MORE slack to spread). The widths are the only thing that carries
        /// both its text metrics and its distribution rule, so ship them, like the picker's tabW and
        /// the journal's hdrW.</summary>
        public static string BarCells = "";

        /// Qud's three TOGGLE buttons in the top-right cluster, as "name=0|1,…". Qud draws each with
        /// `ActiveButton`, which swaps `TargetImage.sprite` between ActiveImage and DisabledImage on
        /// `IsActive` — so the state is a live UI flag, not an Option, and the WINDOW LOCK has no
        /// Option at all. Sampled HERE because reading it is a Unity call, and the turn thread must
        /// never make one; the snapshot writer just reads this string.
        public static string NavButtons = "";

        /// UI THREAD.
        private static void PollBarCells()
        {
            try
            {
                var sb = new System.Text.StringBuilder();
                foreach (var rt in UnityEngine.Object.FindObjectsOfType<UnityEngine.RectTransform>())
                {
                    if (rt == null || rt.name != "ButtonArea" || !rt.gameObject.activeInHierarchy) continue;
                    for (int i = 0; i < rt.childCount; i++)
                    {
                        var c = rt.GetChild(i) as UnityEngine.RectTransform;
                        if (c == null || !c.gameObject.activeInHierarchy) continue;
                        if (!c.name.StartsWith("AbilityBarButton")) continue;
                        if (sb.Length > 0) sb.Append(',');
                        sb.Append(c.rect.width.ToString("0.##",
                            System.Globalization.CultureInfo.InvariantCulture));
                    }
                    break;
                }
                BarCells = sb.ToString();
            }
            catch { }
        }

        /// Click one of Qud's top-bar buttons BY NAME, by invoking its own onClick — so whatever the
        /// button does (the window lock has no Option behind it, just UI state) is Qud's code doing
        /// it, and `IsActive` flips as Qud decides. Marshalled onto the uiQueue: Unity objects, and
        /// the turn thread must never touch those.
        public static void ClickNavButton(string name)
        {
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null || string.IsNullOrEmpty(name)) return;
            gm.uiQueue.queueTask(delegate
            {
                try
                {
                    foreach (var btn in UnityEngine.Object.FindObjectsOfType<Qud.UI.ActiveButton>())
                    {
                        if (btn == null || btn.gameObject.name != name) continue;
                        var b = btn.gameObject.GetComponent<UnityEngine.UI.Button>();
                        if (b == null) { Log("[nav] " + name + " has no Button"); return; }
                        b.onClick.Invoke();
                        Log("[nav] clicked " + name + " -> IsActive " + btn.IsActive);
                        return;
                    }
                    Log("[nav] no ActiveButton named " + name);
                }
                catch (Exception e) { Log("[nav] navclick: " + e.Message); }
            });
        }

        private static string _lastView = "\u0000";

        /// UI THREAD. Publish Qud's CurrentGameView when it CHANGES, as its own frame.
        ///
        /// NOT ON THE SNAPSHOT, and that is the whole point. Qud's legacy screens -- the Looker --
        /// park the TURN thread, which is what writes snapshots, so a client waiting for the news on
        /// that channel learns it exactly never: measured, Raves sat with `qudView` unset for as
        /// long as the Looker was up, which is precisely when it needed to know. This watcher runs
        /// on the UI thread and keeps going while the turn thread is parked -- the same reason the
        /// popup mirror lives here.
        private static void PollView(BridgeServer server)
        {
            try
            {
                if (server == null || server.ClientCount == 0) return;
                string v = GameManager.Instance != null ? (GameManager.Instance.CurrentGameView ?? "") : "";
                if (v == _lastView) return;
                _lastView = v;
                var j = new JsonWriter();
                j.BeginObject().Member("type", Protocol.TypeView).Member("name", v).EndObject();
                Publish(server, j.ToString());
            }
            catch { }
        }

        /// UI THREAD. The three ActiveButtons' live on/off, for the client's icon swap.
        private static void PollNavButtons()
        {
            try
            {
                var sb = new System.Text.StringBuilder();
                foreach (var btn in UnityEngine.Object.FindObjectsOfType<Qud.UI.ActiveButton>())
                {
                    if (btn == null || !btn.gameObject.activeInHierarchy) continue;
                    if (sb.Length > 0) sb.Append(',');
                    sb.Append(btn.gameObject.name).Append('=').Append(btn.IsActive ? '1' : '0');
                }
                NavButtons = sb.ToString();
            }
            catch { }
        }

        /// UI THREAD. Cheap: two field reads and a name.
        private static void PollStatusTab()
        {
            try
            {
                var ss = Qud.UI.StatusScreensScreen.instance;
                if (ss == null || ss.Screens == null || ss.Screens.Count == 0) { StatusTab = ""; return; }
                int i = ss.CurrentScreen;
                if (i < 0 || i >= ss.Screens.Count) { StatusTab = ""; return; }
                var t = ss.Screens[i];
                StatusTab = (t != null) ? (t.name ?? "") : "";
            }
            catch { StatusTab = ""; }
        }

        /// UI THREAD. Detect the active PopupMessage, and publish a popup frame whenever its state changes
        /// (appeared / content changed / dismissed). Signature-gated so we send once per distinct state.
        private static void Poll()
        {
            int now = Environment.TickCount;
            if (now - _lastPollMs < 33) return;   // ~30 Hz is plenty; the check is cheap but not free
            _lastPollMs = now;

            // BEFORE the client gate: the tab report goes to a FILE that highvisor reads, so it has
            // to keep working when no Raves is attached.
            PollStatusTab();
            PollJournalHeader();
            PollBarCells();
            PollNavButtons();
            PollView(Bridge.Server);

            BridgeServer server = Bridge.Server;
            if (server == null || server.ClientCount == 0) return;

            bool resend = _resend;   // one-shot: a client just connected — re-broadcast the live popup
            _resend = false;

            // The item PICKER rides on this same watcher: it is a separate Qud SCREEN, but it blocks the
            // turn thread exactly like a popup does, so the UI-thread pump is the only place either can be
            // read. Poll it FIRST — a picker can be up with no popup, and vice versa; they are independent.
            try { PickerBridge.Poll(server); } catch (Exception e) { Log("picker poll: " + e.Message); }
            // The cybernetics/generic TERMINAL rides the same watcher, and must: it parks the
            // turn thread exactly like the popup and the picker do, so this is the only pump
            // still running while it is up.
            try { CyberBridge.Poll(server); } catch (Exception e) { Log("cyber poll: " + e.Message); }

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
                    // WHY a popup went away, in one line, every time. Qud nulls
                    // `commandCallback` in OnActivateCommand and `selectCallback` in OnSelect,
                    // so a modal that closes with BOTH still set was never answered by anyone
                    // — it was HIDDEN, and `Popup.PickOption` then returns its untouched
                    // DefaultSelected (the self-answering item menu, 2026-08-08). Without this
                    // line "the viewer answered" and "something tore the modal down" look
                    // identical from every channel outside Qud.
                    try
                    {
                        var gone = _announcedPm;
                        Log("[popup] closed: cmdCb=" + (gone != null && gone.commandCallback != null)
                            + " selCb=" + (gone != null && gone.selectCallback != null)
                            + " pooled=" + (gone != null && InFreePool(gone))
                            + (gone != null && gone.commandCallback != null && gone.selectCallback != null
                               ? "  <-- UNANSWERED: hidden out from under the viewer" : ""));
                    }
                    catch { }
                    _active = false;
                    _sig = "";
                    _announcedPm = null;
                    _episodeMinId = int.MaxValue;   // nothing is answerable until the next announce
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

            // The CONTEXT belongs in the signature. Two items' menus carry identical
            // options and an identical message, differing only in the header -- without
            // this, opening a second item's menu would look like "same popup, already
            // sent" and Raves would keep showing the first item's tile and name.
            string ctxSig = "";
            try
            {
                if (pm.contextText != null && pm.contextText.gameObject.activeSelf)
                    ctxSig = pm.contextText.text ?? "";
                var tc0 = pm.contextImage != null ? pm.contextImage.threeColorTile : null;
                if (tc0 != null && tc0.image != null && tc0.image.sprite != null)
                    ctxSig += SEP + tc0.image.sprite.name + SEP + Hex(tc0.Foreground) + Hex(tc0.Detail);
            }
            catch { }
            string sig = Sig(message, title, buttons, options, input, inputDefault) + SEP + ctxSig;
            _announcedPm = pm;   // answers target the instance Raves is looking at
            if (_active && sig == _sig && !resend) return;   // same popup, same content — Raves already has it
            bool freshEpisode = !_active || sig != _sig;   // a resend is the SAME episode, not a new one
            _active = true;
            _sig = sig;
            // A RESEND REUSES THE ID, so the frame is byte-identical to the one every client
            // already holds. It used to bump `_id`, which made an unchanged popup arrive as a
            // NEW popup about twice a second -- `_resend` is set on every client connect and
            // highvisor's state poller connects and drops at that rate, forever, for as long as
            // the modal is up. That churn is not theoretical: it reset half-typed AskString text
            // ("kept resetting as I tried to type QUIT") and sprang an option list's selection
            // back to the first row, and both were fixed by teaching the CLIENT to recognise a
            // re-announce by content. The client-side defences stay -- a resend after a genuine
            // content change still has to be absorbed -- but the source no longer sprays, and a
            // client that dedupes on id alone is now correct.
            if (freshEpisode) { _episodeMinId = _id + 1; _id++; }

            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypePopup);
            j.Member("active", true);
            j.Member("id", _id);
            j.Member("message", message ?? "");
            j.Member("title", title ?? "");
            j.Member("input", input);
            j.Member("inputDefault", inputDefault);
            j.Member("kind", input ? "input" : (options != null && options.Count > 0 ? "menu" : "message"));
            WriteItems(j, "buttons", buttons);
            WriteItems(j, "options", options);
            WriteContext(j, pm, sig);
            j.EndObject();
            Publish(server, j.ToString());
        }

        /// The popup's CONTEXT HEADER -- the framed block Qud puts above the command
        /// list, holding the subject's tile and its name (an item menu shows the item).
        /// ShowPopup takes contextRender/contextTitle as PARAMETERS, so there is nothing
        /// to read on the instance; the live components are the source of truth:
        /// contextImage.threeColorTile (sprite + already-resolved Foreground/Detail/
        /// Background) and contextText. Shipping resolved RGBA means the client needs no
        /// palette lookup for this at all.
        // Last context sprite we actually dumped, and under what popup signature. A
        // RESEND re-runs this whole block, and a resend happens on EVERY client connect
        // -- including highvisor's state poller, which connects and drops about twice a
        // second. Without this cache that meant a GPU texture readback, a PNG write and
        // a file delete at 2Hz forever, plus a fresh popup id each time (which is what
        // kept resetting the client's menu selection).
        private static string _ctxSig = "";
        private static string _ctxFile = "";
        private static int _ctxSeq;

        private static void WriteContext(JsonWriter j, Qud.UI.PopupMessage pm, string sig)
        {
            try
            {
                if (pm.contextContainer == null || !pm.contextContainer.activeSelf) return;
                j.Name("context").BeginObject();
                try { j.Member("frame", pm.contextFrame != null && pm.contextFrame.activeSelf); } catch { }
                try
                {
                    if (pm.contextText != null && pm.contextText.gameObject.activeSelf)
                    {
                        j.Member("text", pm.contextText.text ?? "");
                        // the label's own colour, for the runs the markup does not paint
                        j.Member("textColor", Hex(pm.contextText.color));
                    }
                }
                catch { }
                try
                {
                    var disp = pm.contextImage;
                    var tc = disp != null ? disp.threeColorTile : null;
                    if (tc != null && tc.gameObject.activeSelf && tc.image != null && tc.image.sprite != null)
                    {
                        // No name to ship: this sprite comes off an atlas with an empty
                        // sprite.name AND texture.name, so its PIXELS are the only identity
                        // it has. Dump them into the tiles dir under a per-popup filename --
                        // per-popup because the client caches tile textures by NAME, so a
                        // stable name would serve the previous item's art forever.
                        // Re-dump ONLY when the popup itself changed. The filename still
                        // varies per dump (the client caches tile textures by name), it
                        // just stops varying per announce.
                        string tile = _ctxFile;
                        bool have = sig == _ctxSig && !string.IsNullOrEmpty(tile)
                                    && File.Exists(Path.Combine(TileExporter.Dir, tile));
                        if (!have)
                        {
                            tile = "__popup_ctx_" + (++_ctxSeq) + ".png";
                            if (TitleExporter.ExportSpriteToTiles(tc.image.sprite, tile))
                            {
                                foreach (string old in Directory.GetFiles(TileExporter.Dir, "__popup_ctx_*.png"))
                                {
                                    try { if (Path.GetFileName(old) != tile) File.Delete(old); } catch { }
                                }
                                _ctxSig = sig;
                                _ctxFile = tile;
                                have = true;
                            }
                        }
                        if (have) j.Member("tile", tile);
                        j.Member("fg", Hex(tc.Foreground));
                        j.Member("dt", Hex(tc.Detail));
                        if (tc.Background.a > 0.01f) j.Member("bg", Hex(tc.Background));
                        // one-time: the draw box, so the client sizes it from Qud rather
                        // than from a measured guess
                        var rt = tc.image.rectTransform;
                    }
                }
                catch (Exception ie) { System.Console.WriteLine("[raves] popup context image: " + ie.Message); }
                // Qud's palette rides along: a popup can be the FIRST thing Raves draws
                // after connecting, before any zone snapshot has delivered one, and then
                // its markup ({{b|}} badges and the like) silently falls back to the
                // client's approximate table -- the same trap the status screens hit.
                try
                {
                    j.Name("palette").BeginObject();
                    foreach (char pch in "rRgGbBcCmMwWoOyYkK")
                    {
                        try
                        {
                            UnityEngine.Color pc = ConsoleLib.Console.ColorUtility.colorFromChar(pch);
                            j.Member(pch.ToString(), Hex(pc));
                        }
                        catch { }
                    }
                    j.EndObject();
                }
                catch { }
                j.EndObject();
            }
            catch (Exception e) { System.Console.WriteLine("[raves] popup context: " + e.Message); }
        }

        private static string Hex(UnityEngine.Color c)
        {
            return string.Format("#{0:x2}{1:x2}{2:x2}", (int)(c.r * 255f), (int)(c.g * 255f), (int)(c.b * 255f));
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
            f.TryGetValue("id", out string idStr);
            gm.uiQueue.queueTask(delegate
            {
                try
                {
                    PopupMessage pm = AnswerableTarget(idStr, out string why);
                    if (pm == null)
                    {
                        Log("[popup] REFUSED " + (action ?? "?") + " (id " + (idStr ?? "-") + "): " + why
                            + " — the bridge only answers a popup it has announced.");
                        // Say so on the WIRE too, not just in the log: a client that just had an
                        // answer refused is, by definition, out of step with what is on screen.
                        // Re-announcing the truth (the live popup, or active:false) is what stops
                        // it retrying into the same refusal.
                        _resend = true;
                        return;
                    }
                    Log("[popup] answer -> " + action + " id=" + (idStr ?? "-")
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

        /// <summary>The ONLY popup the bridge will answer: the exact instance whose content was
        /// last ANNOUNCED to the client, still live, still in use, and named by an id belonging
        /// to the episode currently on screen. Returns null (with a reason) for anything else.
        ///
        /// This used to fall back to "scan for whatever popup is visible" when the announced
        /// instance did not check out — a check that cannot fail, and it failed in both
        /// directions. With no announcement at all it cheerfully answered a modal the viewer
        /// had never seen; and for the async COPIES (ShowYesNoAsync / PickOptionAsync /
        /// AskString, all via UIManager.copyWindow) the scan can return a POOLED GHOST that
        /// still looks visible and still has a callback, so the answer went nowhere while Qud's
        /// real modal kept its `onHide` dangling — which surfaces one popup later as
        /// `ShowPopup::OnHide wasn't called!` and leaves the popup bookkeeping inconsistent.
        ///
        /// A refusal that names its reason is strictly better than an answer that might be
        /// right: the caller can re-read and retry, where a wrong answer is unrecoverable.</summary>
        private static PopupMessage AnswerableTarget(string idStr, out string why)
        {
            PopupMessage pm = _announcedPm;
            if (pm == null || !_active)
            {
                why = "no popup has been announced (nothing is on screen, or the watcher never armed)";
                return null;
            }
            // The client names WHICH popup it is answering. An answer that races the popup
            // closing, or a queued retry, names an id we have moved past — and applying it to
            // the SUCCESSOR popup is precisely the "answered a stale instance" bug. Clients
            // that send no id still work; they just get the instance checks below.
            if (!string.IsNullOrEmpty(idStr))
            {
                if (!int.TryParse(idStr, out int want))
                {
                    why = "unparseable popup id " + idStr;
                    return null;
                }
                if (want < _episodeMinId || want > _id)
                {
                    why = "answer names popup " + want + ", but the one on screen is "
                          + _episodeMinId + ".." + _id;
                    return null;
                }
            }
            if (!IsLive(pm)) { why = "the announced popup is no longer live"; return null; }
            if (InFreePool(pm)) { why = "the announced popup has been released to UIManager's pool"; return null; }
            why = "";
            return pm;
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

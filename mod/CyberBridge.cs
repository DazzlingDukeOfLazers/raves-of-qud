using System;
using System.Text;
using Qud.UI;               // CyberneticsTerminalScreen
using XRL;                  // GameManager
using XRL.UI;               // CyberneticsTerminal (its own public static Instance)
using XRL.UI.Framework;     // APIDispatch

namespace RavesOfQud
{
    /// <summary>
    /// Mirrors Qud's CYBERNETICS / GENERIC TERMINAL (<c>Qud.UI.CyberneticsTerminalScreen</c>) to Raves —
    /// the becoming-nook menu a True Kin gets from a terminal.
    ///
    /// A THIRD MIRROR, and it needs to be, for the same reason PickerBridge is not PopupBridge: this is
    /// neither a PopupMessage nor the item picker but its own SingletonWindowBase screen, with its own
    /// completionSource, its own FrameworkScroller and its own data model. Neither existing mirror can
    /// see it — before this, Qud showed the terminal and Raves showed the bare playfield.
    ///
    /// Threading: the same as both of those, and for the same reason. `_ShowCyberneticsTerminal` parks
    /// the caller on `await completionSource.Task` while the UI thread keeps drawing and keeps draining
    /// uiQueue — so we poll from PopupBridge's UI-thread watcher, which is the one channel that still
    /// runs while the turn thread is parked.
    ///
    /// The model is exactly what the screen's own GetMenuItems() yields, so Raves reproduces the rows
    /// without inventing any:
    ///   row 0  = CurrentScreen.RenderedTextForModernUI  (the welcome/body block, OptionID -1)
    ///   rows 1+ = CurrentScreen.Options[i]              (OptionID i)
    /// plus the screen's FooterText ("Credits: 0  License Tier: 2  Points Used: 2"), which the screen
    /// composes in BeforeRender and which we must NOT re-derive — the tier/points arithmetic lives in
    /// Qud's own screen classes and would drift the moment they change it.
    ///
    /// GENERIC TERMINALS ARE NOT COVERED YET, and are excluded rather than half-handled: the screen
    /// serves both, but the generic side hangs off a PRIVATE `genericTerminal` field with no public
    /// static to read it from, where cybernetics has `CyberneticsTerminal.Instance`. A reflection
    /// grab for it is a separate slice; until then a generic terminal simply does not mirror, which
    /// is honest, rather than mirroring as an empty frame that looks like a bug.
    /// </summary>
    public static class CyberBridge
    {
        private static volatile bool _resend;   // client (re)connected -> re-announce once
        private static int _id;
        private static bool _active;
        private static string _sig = "";

        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        public static void OnClientConnect() { _resend = true; }

        /// <summary>The terminal screen if it is genuinely up, else null. `Visible` alone is not enough:
        /// the singleton persists after Hide(), and both terminal references are nulled only on the NEXT
        /// show — so require a live terminal WITH a current screen, which is what the rows come from.</summary>
        private static CyberneticsTerminalScreen Live()
        {
            try
            {
                var sc = CyberneticsTerminalScreen.instance;
                if (sc == null || !sc.Visible) return null;
                return Terminal() != null ? sc : null;
            }
            catch { return null; }
        }

        /// The live terminal MODEL. Read off `CyberneticsTerminal.Instance` -- its own public static --
        /// rather than the screen's `cyberneticsTerminal` field, which is PRIVATE and would need
        /// reflection to reach. Same object either way: `_ShowCyberneticsTerminal` is handed the
        /// instance that set itself as Instance when the terminal was used.
        private static CyberneticsTerminal Terminal()
        {
            try
            {
                var t = CyberneticsTerminal.Instance;
                return (t != null && t.CurrentScreen != null) ? t : null;
            }
            catch { return null; }
        }

        /// UI THREAD (driven by PopupBridge's watcher). Publish whenever what the viewer can see changes.
        public static void Poll(BridgeServer server)
        {
            if (server == null || server.ClientCount == 0) return;
            bool resend = _resend;
            _resend = false;

            var sc = Live();
            if (sc == null)
            {
                if (_active)
                {
                    _active = false;
                    _sig = "";
                    var jc = new JsonWriter();
                    jc.BeginObject().Member("type", Protocol.TypeCyber)
                      .Member("active", false).Member("id", ++_id).EndObject();
                    Publish(server, jc.ToString());
                }
                return;
            }

            string body, footer;
            var opts = ReadRows(sc, out body, out footer);
            if (opts == null) return;

            var sb = new StringBuilder();
            sb.Append(body).Append('').Append(footer).Append('').Append(Selected(sc));
            foreach (var o in opts) sb.Append('').Append(o);
            string sig = sb.ToString();
            if (_active && sig == _sig && !resend) return;
            bool fresh = !_active || sig != _sig;
            _active = true;
            _sig = sig;
            if (fresh) _id++;

            var j = new JsonWriter();
            j.BeginObject();
            j.Member("type", Protocol.TypeCyber);
            j.Member("active", true);
            j.Member("id", _id);
            j.Member("kind", "cybernetics");
            j.Member("body", body ?? "");
            j.Member("footer", footer ?? "");
            j.Member("selected", Selected(sc));
            j.Name("options").BeginArray();
            foreach (var o in opts) j.Value(o ?? "");
            j.EndArray();
            j.EndObject();
            Publish(server, j.ToString());
        }

        /// Qud's own row source: the body block, then Options in order. Reading only — no Activate.
        private static System.Collections.Generic.List<string> ReadRows(
            CyberneticsTerminalScreen sc, out string body, out string footer)
        {
            body = ""; footer = "";
            try
            {
                footer = sc.FooterText ?? "";
                var list = new System.Collections.Generic.List<string>();
                var t = Terminal();
                if (t == null) return null;
                var cur = t.CurrentScreen;
                body = cur.RenderedTextForModernUI ?? "";
                if (cur.Options != null) foreach (var o in cur.Options) list.Add(o ?? "");
                return list;
            }
            catch (Exception e) { Log("[cyber] read: " + e.Message); return null; }
        }

        /// The highlighted OPTION index, or -1 on the body row. The scroller counts the body block as
        /// position 0, so the option index is one less -- the same off-by-one Show() encodes when it
        /// sets `selectedPosition = 1` to land on the first real option.
        private static int Selected(CyberneticsTerminalScreen sc)
        {
            try { return (sc.displayScroller?.scrollContext?.selectedPosition ?? 1) - 1; }
            catch { return 0; }
        }

        /// <summary>Answer the terminal from Raves: highlight an option and accept it.
        ///
        /// APIDispatch IS CORRECT HERE, and that is not a contradiction of the rule that bit us three
        /// times today (SkillsExporter / Twiddle / EquipPicker). That rule is about WHO PARKED the turn
        /// thread: those three are driven while the game is idle and the turn thread is free to slam the
        /// view back to Stage under the modal. This screen parks the turn thread ITSELF on
        /// `await completionSource.Task` before we can be called, so we are in exactly the position
        /// Qud's own HandleSelect is in — and HandleSelect uses APIDispatch, verbatim, for these same two
        /// calls. Copying Qud's placement is the whole point.</summary>
        public static void Select(int optionIndex)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            gm.uiQueue.queueTask(() =>
            {
                try
                {
                    var sc = Live();
                    var term = Terminal();
                    if (sc == null || term == null) { Log("[cyber] select: no live terminal"); return; }
                    int n = term.CurrentScreen != null && term.CurrentScreen.Options != null
                        ? term.CurrentScreen.Options.Count : 0;
                    if (optionIndex < 0 || optionIndex >= n)
                    { Log("[cyber] select: index " + optionIndex + " outside 0.." + (n - 1)); return; }
                    Log("[cyber] select " + optionIndex + " ("
                        + (term.CurrentScreen.Options[optionIndex] ?? "?") + ")");
                    term.Selected = optionIndex;
                    APIDispatch.RunAndWaitAsync(delegate
                    {
                        try { term.CurrentScreen.Activate(); }
                        catch (Exception ae) { Log("[cyber] Activate: " + ae.Message); }
                    }).ContinueWith(delegate
                    {
                        // Re-render the way the screen does after a selection: BeforeRender refreshes
                        // the body + footer for whatever screen Activate() moved us to, then Show()
                        // rebuilds the rows. Marshalled back onto the UI thread -- ContinueWith lands
                        // on a threadpool thread, which must not touch Unity objects.
                        var g2 = GameManager.Instance;
                        if (g2 != null && g2.uiQueue != null)
                            g2.uiQueue.queueTask(() =>
                            {
                                try
                                {
                                    var s2 = CyberneticsTerminalScreen.instance;
                                    var t2 = CyberneticsTerminal.Instance;
                                    if (s2 == null || t2 == null) return;
                                    if (t2.CurrentScreen == null) { s2.Exit(); return; }
                                    string f = "";
                                    t2.CurrentScreen.BeforeRender(null, ref f);
                                    s2.FooterText = f;
                                    s2.Show();
                                }
                                catch (Exception re) { Log("[cyber] re-render: " + re.Message); }
                            }, 0);
                    });
                }
                catch (Exception e) { Log("[cyber] select error: " + e.Message); }
            }, 0);
        }

        /// Close the terminal (Qud's [Esc] quit).
        public static void Quit()
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            gm.uiQueue.queueTask(() =>
            {
                try
                {
                    var sc = Live();
                    if (sc != null) { Log("[cyber] quit"); sc.Exit(); }
                }
                catch (Exception e) { Log("[cyber] quit error: " + e.Message); }
            }, 0);
        }

        private static void Publish(BridgeServer server, string json)
        {
            try { server.Publish(Protocol.Frame(json)); }
            catch (Exception e) { Log("[cyber] publish: " + e.Message); }
        }
    }
}

using System;
using System.Reflection;
using System.Collections;
using Qud.UI;               // PopupMessage
using XRL;                  // GameManager
using XRL.UI;               // UIManager

namespace RavesOfQud
{
    /// <summary>
    /// The instrument that found the self-answering item menu (2026-08-08). It traces, per
    /// UI frame, the two things that decide a modal's fate and that nothing outside Qud can
    /// see: the COMMAND ControlManager is delivering this frame, and the popup window's whole
    /// visibility state next to the GAME VIEW STACK.
    ///
    /// Keep it. Three rounds of hypothesis-guessing (a stray keystroke, the harness's mouse
    /// restore, a fabricated Cancel) got nowhere, and one run of this printed the answer:
    ///     pm f4322 ... view=PopupMessage/PopupMessage stack=Stage,Stage,PopupMessage
    ///     pm f4323 ... view=Stage/PopupMessage        stack=Stage,Stage,Stage
    ///     pm f4324 canv=False hnf=1 onHide=False cmd=True sel=True
    /// i.e. the game view was slammed back to Stage under a live popup, the window was hidden,
    /// `onHide` cancelled the awaiting task, and BOTH callbacks were still unfired — so nothing
    /// "answered" anything. `cmd`/`sel` being true at the close is the whole discriminator
    /// between "the viewer answered" and "something hid the modal".
    ///
    /// OFF by default: `SamplePopup` runs on every uiQueue drain and logs on every change,
    /// which is a lot of Player.log for a healthy game. Flip `Enabled` and restart Qud
    /// (mod .cs compiles at startup) when a modal misbehaves again.
    ///
    /// ControlManager keeps a Queue&lt;FrameCommand&gt; and hands ONE command per frame to
    /// FrameDownCommand, which is what every menu's Update() tests through isCommandDown.
    /// Both fields are private statics; reflection is the only way in from a mod.
    /// </summary>
    public static class InputDiag
    {
        public static bool Enabled = false;

        private static Type _cm;
        private static FieldInfo _fDown, _fQueue, _fSkip;
        private static bool _init;
        private static string _lastDown = "";
        private static int _lastQ = -1;

        private static void Init()
        {
            if (_init) return;
            _init = true;
            try
            {
                _cm = Type.GetType("ControlManager, Assembly-CSharp");
                if (_cm == null) return;
                const BindingFlags F = BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Static;
                _fDown = _cm.GetField("FrameDownCommand", F);
                _fQueue = _cm.GetField("CommandQueue", F);
                _fSkip = _cm.GetField("SkipFrames", F);
                Bridge.Server?.Log("[diag] ControlManager reflection: down=" + (_fDown != null)
                    + " queue=" + (_fQueue != null) + " skip=" + (_fSkip != null));
            }
            catch (Exception e) { try { Bridge.Server?.Log("[diag] init: " + e.Message); } catch { } }
        }

        public static string Snapshot()
        {
            Init();
            string down = "-", q = "-", skip = "-";
            try { var d = _fDown?.GetValue(null); down = d == null ? "null" : d.ToString(); } catch { }
            try
            {
                var qq = _fQueue?.GetValue(null) as ICollection;
                if (qq != null)
                {
                    q = qq.Count.ToString();
                    if (qq.Count > 0)
                    {
                        var sb = new System.Text.StringBuilder("[");
                        foreach (object o in qq) sb.Append(o).Append(' ');
                        q += sb.Append(']').ToString();
                    }
                }
            }
            catch { }
            try { skip = Convert.ToString(_fSkip?.GetValue(null)); } catch { }
            return "down=" + down + " queue=" + q + " skip=" + skip;
        }

        // ---- popup lifecycle sampler ------------------------------------------------
        private static FieldInfo _fHideNext;
        private static string _lastPop = "";

        /// The game-view STACK. PopGameView/RemoveGameView also record what they left in
        /// LeftGameViews, so the two together say WHICH mechanism moved the view: a pop
        /// names the view it left, a SetGameViewStack/ForceGameView does not.
        public static string ViewStack()
        {
            try
            {
                var gm = GameManager.Instance;
                if (gm == null) return "?";
                return string.Join(",", gm.GetGameViewStackCopy());
            }
            catch { return "?"; }
        }

        public static string LeftViews()
        {
            try
            {
                var f = typeof(GameManager).GetField("LeftGameViews",
                    BindingFlags.Static | BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                var v = f?.GetValue(f.IsStatic ? null : GameManager.Instance) as IEnumerable;
                if (v == null) return "-";
                var sb = new System.Text.StringBuilder();
                foreach (object o in v) sb.Append(o).Append('|');
                return sb.Length == 0 ? "" : sb.ToString();
            }
            catch { return "?"; }
        }

        /// UI THREAD, every uiQueue drain. Log the SINGLETON popup's whole visibility
        /// state whenever any part of it changes, so the ORDER of the teardown is
        /// readable: HideNextFrame going to 2 means PopupMessage.Hide() ran (and with it
        /// onHide, which is what cancels the awaiting PickOption); the canvas going dark
        /// with HideNextFrame still 0 means something outside hid the WINDOW.
        public static void SamplePopup()
        {
            if (!Enabled) return;
            try
            {
                var pm = UIManager.getWindow("PopupMessage") as PopupMessage;
                if (pm == null) return;
                if (_fHideNext == null)
                    _fHideNext = typeof(PopupMessage).GetField("HideNextFrame",
                        BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                int hnf = -1;
                try { hnf = Convert.ToInt32(_fHideNext?.GetValue(pm) ?? -1); } catch { }
                string s = "act=" + pm.gameObject.activeInHierarchy
                    + " canv=" + (pm.canvas != null && pm.canvas.enabled)
                    + " ray=" + (pm.raycaster != null && pm.raycaster.enabled)
                    + " hnf=" + hnf
                    + " onHide=" + (pm.onHide != null)
                    + " cmd=" + (pm.commandCallback != null)
                    + " sel=" + (pm.selectCallback != null)
                    + " opts=" + (pm.controller != null && pm.controller.menuData != null
                                  ? pm.controller.menuData.Count : -1)
                    + " row=" + (pm.controller != null ? pm.controller.selectedOption : -1)
                    + " view=" + (GameManager.Instance != null
                                  ? GameManager.Instance.CurrentGameView : "?")
                    + "/" + (GameManager.Instance != null
                             ? GameManager.Instance._ActiveGameView : "?")
                    + " stack=" + ViewStack() + " left=" + LeftViews();
                if (s == _lastPop) return;
                _lastPop = s;
                Bridge.Server?.Log("[diag] pm f" + UnityEngine.Time.frameCount + " " + s);
            }
            catch (Exception e) { try { Bridge.Server?.Log("[diag] pm: " + e.Message); } catch { } }
        }

        /// UI THREAD, every uiQueue drain. Logs a line only when something CHANGES.
        public static void Sample()
        {
            if (!Enabled) return;
            Init();
            if (_cm == null) return;
            try
            {
                object d = _fDown?.GetValue(null);
                string down = d == null ? "" : d.ToString();
                var qq = _fQueue?.GetValue(null) as ICollection;
                int qn = qq == null ? -1 : qq.Count;
                if (down != _lastDown && !string.IsNullOrEmpty(down))
                    Bridge.Server?.Log("[diag] frame command: " + down
                        + " (queue " + qn + ", frame " + UnityEngine.Time.frameCount + ")");
                if (qn != _lastQ && qn > 0)
                    Bridge.Server?.Log("[diag] command queue depth " + qn
                        + " (frame " + UnityEngine.Time.frameCount + ")");
                _lastDown = down;
                _lastQ = qn;
            }
            catch { }
        }
    }
}

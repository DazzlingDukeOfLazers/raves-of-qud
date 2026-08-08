using System;
using XRL;   // HasModSensitiveStaticCache, ModSensitiveCacheInit (XRL namespace)

namespace RavesOfQud
{
    /// <summary>
    /// The mod's PRE-GAME entry point. Everything else in the bridge runs off the in-game
    /// per-turn tick (BridgePart), so nothing used to run at Qud's main menu — but the "embark"
    /// command has to be received THERE, before any game exists.
    ///
    /// Qud invokes every <c>[ModSensitiveCacheInit]</c> method at the end of mod loading
    /// (ModManager.BuildMods -> ResetModSensitiveStaticCaches), i.e. at STARTUP before the menu,
    /// and again on a live mod reload. We use it to start the bridge listener early so Raves can
    /// send commands (e.g. "embark") at the menu. Idempotent — Bridge.Server is a lazy singleton,
    /// so the reload re-invocation is harmless.
    ///
    /// NB: we deliberately do NOT use Harmony here. On this macOS build, runtime code patching
    /// fails with "mprotect returned EACCES" (hardened-runtime W^X blocks executable-page
    /// rewriting), so the drive bypasses the chargen UI by driving Qud's real EmbarkBuilder
    /// through its public API instead — see EmbarkDriver.
    /// </summary>
    [HasModSensitiveStaticCache]
    public static class StartupHook
    {
        [ModSensitiveCacheInit]
        public static void Init()
        {
            try
            {
                // Lazy singleton — touching it starts the TCP listener if it isn't up yet, so
                // the "embark" command works at the main menu. Snapshot publishing still only
                // happens in-game (driven by BridgePart); this just moves command RECEPTION early.
                _ = Bridge.Server;
                // Register the message-log callback NOW (before any game loads) so the "since load" count
                // catches the same load-time messages Qud's own sidebar does — matching its log length.
                ZoneSnapshot.EnsureMessageCallback();
                System.Console.WriteLine("[raves] pre-game bridge listener up.");
                StartHeartbeat();
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] pre-game bridge start failed: " + e);
            }
        }

        private static System.Threading.Thread _heartbeat;

        // ---- main-thread UI sampler (the heartbeat thread must not touch Unity) ----
        // Qud's modern menu screens (Modding Toolkit, Mod Manager, Workshop Uploader,
        // Histographicnomicon, Waveform generator …) are Qud.UI.WindowBase singletons; the
        // legacy view field stays "MainMenu" for all of them, so the heartbeat alone can't
        // tell them apart. Once a second we marshal ONE sample through GameManager.uiQueue
        // (the mod's standard main-thread hop) that records the current visible window's
        // type name; the heartbeat folds it into `scene` while no game is live. Reflection
        // keeps this compile-proof across Qud versions — a missing member just degrades to
        // the old behaviour.
        private static volatile string _uiWindow = "";
        private static volatile string _uiScene = "";
        private static volatile string _uiMenu = "";
        private static long _uiSampleTs;
        private static volatile bool _uiSamplePending;

        private static void SampleUiOnMainThread()
        {
            try
            {
                string win = "";
                var umType = Type.GetType("Qud.UI.UIManager, Assembly-CSharp");
                object um = umType != null ? umType.GetField("instance").GetValue(null) : null;
                if (um != null)
                {
                    var cw = umType.GetField("_currentWindow",
                        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public
                        | System.Reflection.BindingFlags.NonPublic)?.GetValue(um);
                    if (cw != null)
                    {
                        var visProp = cw.GetType().GetProperty("Visible",
                            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public
                            | System.Reflection.BindingFlags.NonPublic);
                        bool vis = visProp != null && visProp.GetValue(cw, null) is bool b && b;
                        if (vis) win = cw.GetType().Name;
                    }
                }
                // Some toolkit screens are SingletonWindowBase windows that never become
                // UIManager._currentWindow (verified live: Workshop Uploader, Blueprint
                // Browser, Histographicnomicon, Waveform generator) — probe them directly.
                // instance is a static on the SingletonWindowBase<T> generic base.
                if (win == "")
                {
                    foreach (var tn in new[] { "SteamWorkshopUploaderView", "BrowseBlueprintsView",
                                               "HistoryTestView", "WaveformTestView" })
                    {
                        var t = Type.GetType(tn + ", Assembly-CSharp");
                        var instF = t?.BaseType?.GetField("instance",
                            System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Public
                            | System.Reflection.BindingFlags.NonPublic);
                        object inst = instF != null ? instF.GetValue(null) : null;
                        if (inst == null) continue;
                        var vp = inst.GetType().GetProperty("Visible",
                            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public
                            | System.Reflection.BindingFlags.NonPublic);
                        if (vp != null && vp.GetValue(inst, null) is bool v && v) { win = tn; break; }
                    }
                }
                _uiWindow = win;
                // WHICH Map Editor dropdown is down, if any — the reflection lives in
                // MapEditorDriver next to the code that CLOSES one, so there is a single
                // description of the menu bar's shape. Reported below as `tab`.
                _uiMenu = MapEditorDriver.OpenMenuName();
                _uiScene = UnityEngine.SceneManagement.SceneManager.GetActiveScene().name;
                _uiSampleTs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            }
            catch { /* sampler must never take down the UI thread */ }
            finally { _uiSamplePending = false; }
        }

        /// Background heartbeat: write bridge_status.txt ("live" while a game is running, else "menu")
        /// once a second, regardless of focus / idle / turn state. Raves' menu polls the file's
        /// freshness + content to detect "Qud up" and "game live" ROBUSTLY — the lightweight menu
        /// probe can't reliably drain the full zone-snapshot stream just to sense that a game exists.
        private static void StartHeartbeat()
        {
            if (_heartbeat != null) return;
            _heartbeat = new System.Threading.Thread(() =>
            {
                string dir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "Library", "Application Support", "RavesOfQud");
                string path = System.IO.Path.Combine(dir, "bridge_status.txt");
                string statePath = System.IO.Path.Combine(dir, "qud_state.json");
                while (true)
                {
                    try
                    {
                        System.IO.Directory.CreateDirectory(dir);
                        bool live = false;
                        try { live = The.Game != null && The.Game.Running && The.Player != null; }
                        catch { /* game state mid-transition — treat as not-live this tick */ }
                        System.IO.File.WriteAllText(path, live ? "live" : "menu");
                        // First-party state report for highvisor's state tree (its "scene" signal —
                        // beats OCR guessing). The active view is a plain string field; reading it
                        // off-thread is safe. Scene = the RAW view name ("MainMenu", "Stage", popup
                        // views…); highvisor's gametree lists the ones it maps. Same file contract
                        // as Raves' raves_state.json.
                        string view = "";
                        try { view = GameManager.Instance != null ? (GameManager.Instance._ActiveGameView ?? "") : ""; }
                        catch { }
                        // DIAGNOSTIC TRIO for the "game ended, view stuck on Stage" strand.
                        // All three are plain field reads, which is all this thread may do.
                        //
                        // `curView` is the one that splits the problem in half. Qud keeps TWO view
                        // names: _CurrentGameView (the logical one the legacy menu loop sets) and
                        // _ActiveGameView (what UpdateView last applied -- assigned in exactly one
                        // place, GameManager.UpdateView). XRLCore's menu loop restores the menu with
                        //     if (CurrentGameView != "MainMenu") SetGameViewStack("MainMenu")
                        // i.e. it tests the LOGICAL one, while we report the APPLIED one. So at a
                        // strand:
                        //   curView=MainMenu, view=Stage -> the menu loop ran; UpdateView did not.
                        //   curView=Stage,    view=Stage -> control never got back to the loop at all.
                        // Those are different bugs in different threads and the single after-the-fact
                        // snapshot we had could not tell them apart.
                        //
                        // running/player split `live`, which ANDs three things. If player is null
                        // while running is still true, the game never ended and RunGame is still
                        // looping -- a third possibility the collapsed flag hid completely.
                        string curView = "";
                        bool running = false, hasPlayer = false;
                        try { curView = GameManager.Instance != null ? (GameManager.Instance.CurrentGameView ?? "") : ""; }
                        catch { }
                        try { running = The.Game != null && The.Game.Running; } catch { }
                        try { hasPlayer = The.Player != null; } catch { }
                        // Ask the main thread for a fresh window sample (at most one in flight).
                        try
                        {
                            var gm = GameManager.Instance;
                            if (!_uiSamplePending && gm != null && gm.uiQueue != null)
                            {
                                _uiSamplePending = true;
                                gm.uiQueue.queueTask(SampleUiOnMainThread, 0);
                            }
                        }
                        catch { _uiSamplePending = false; }
                        // A live game IS "play" even when the view string still says
                        // "MainMenu" — after an UNFOCUSED load the view pump hasn't run,
                        // and the stale scene fooled the state tree into "title".
                        string scene = live && (view == "Stage" || view == "" || view == "MainMenu")
                            ? "play" : view;
                        // Menu-land: a visible Qud.UI window is the most specific screen name
                        // (e.g. ModToolkit, ModManagerUI, SteamWorkshopUploaderView) for the
                        // WindowBase menus, whose legacy view field IS stuck at "MainMenu".
                        //
                        // But only when the legacy view has nothing better to say. It was taken
                        // unconditionally, which overwrote a RIGHT answer with a wrong one:
                        // standing on Qud's high-scores screen the state file read
                        //     view=ModernHighScores  window=MainMenu  scene=MainMenu
                        // — the legacy field had it exactly right and the sampler clobbered it,
                        // so `hv goto qud records` reported "did not arrive" while Qud was
                        // plainly on the screen. Navigation was never the problem.
                        //
                        // In-game, `scene` stays "play" and neither of these applies.
                        string win = _uiWindow;
                        long uiAge = _uiSampleTs > 0
                            ? DateTimeOffset.UtcNow.ToUnixTimeSeconds() - _uiSampleTs : -1;
                        bool viewVague = view.Length == 0
                            || view.Equals("MainMenu", StringComparison.OrdinalIgnoreCase);
                        bool winUseful = win.Length > 0
                            && !win.Equals("MainMenu", StringComparison.OrdinalIgnoreCase);
                        if (!live && viewVague && winUseful && uiAge >= 0 && uiAge <= 5) scene = win;
                        bool popup = view.IndexOf("Popup", StringComparison.OrdinalIgnoreCase) >= 0;
                        // WHICH status tab, when the status screens are the active view. Cached by
                        // the UI-thread watcher: resolving it here would mean a Unity call off-thread.
                        string tab = "";
                        try
                        {
                            if (view.IndexOf("StatusScreens", StringComparison.OrdinalIgnoreCase) >= 0)
                                tab = PopupBridge.StatusTab ?? "";
                            // The Map Editor's open dropdown rides the SAME slot, because it is the
                            // same kind of thing: a sub-screen inside one window that the window name
                            // cannot distinguish. highvisor's `tab` signature requires a `scene`
                            // alongside it, so "File" can never match while some other screen is up.
                            else if (scene.IndexOf("MapEditor", StringComparison.OrdinalIgnoreCase) >= 0)
                                tab = _uiMenu ?? "";
                        }
                        catch { }
                        System.IO.File.WriteAllText(statePath,
                            "{\"scene\":\"" + scene.Replace("\"", "'") + "\",\"live\":" + (live ? "true" : "false")
                            + (popup ? ",\"popup\":\"" + view.Replace("\"", "'") + "\"" : "")
                            + (tab.Length > 0 ? ",\"tab\":\"" + tab.Replace("\"", "'") + "\"" : "")
                            + ",\"view\":\"" + view.Replace("\"", "'") + "\""
                            + ",\"cur_view\":\"" + curView.Replace("\"", "'") + "\""
                            + ",\"running\":" + (running ? "true" : "false")
                            + ",\"player\":" + (hasPlayer ? "true" : "false")
                            + ",\"window\":\"" + win.Replace("\"", "'") + "\""
                            + ",\"unity_scene\":\"" + _uiScene.Replace("\"", "'") + "\""
                            + ",\"ui_age\":" + uiAge
                            // The two inputs to the focus keeper, so a stall can be DIAGNOSED
                            // instead of argued about. The keeper only asserts bThreadFocus while
                            // ClientCount > 0, so "stalled" splits three ways that look identical
                            // from outside: no client attached (keeper idle), client attached but
                            // bThreadFocus still false (keeper not running / losing a race), or
                            // bThreadFocus true and the UI stalled anyway (the gate is not the
                            // cause). Reading these costs nothing and settles which.
                            + ",\"clients\":" + ClientCountSafe()
                            + ",\"thread_focus\":" + (ThreadFocusSafe() ? "true" : "false")
                            + ",\"ts\":" + DateTimeOffset.UtcNow.ToUnixTimeSeconds() + "}");
                    }
                    catch { /* transient IO — retry next tick */ }
                    try { LoadSave.Pump(); }   // re-arm a pending picker load (~1/s)
                    catch { }
                    System.Threading.Thread.Sleep(1000);
                }
            })
            { IsBackground = true, Name = "RavesHeartbeat" };
            _heartbeat.Start();
        }

        /// <summary>Attached bridge clients, or -1 if the server is not up yet. Off-thread safe:
        /// ClientCount takes its own lock and touches no Unity object.</summary>
        private static int ClientCountSafe()
        {
            try { return Bridge.Server != null ? Bridge.Server.ClientCount : -1; }
            catch { return -1; }
        }

        /// <summary>XRLCore.bThreadFocus — the flag gating Unity's Update(), which the keeper holds
        /// true while a client is attached. A plain static read, no Unity API call.</summary>
        private static bool ThreadFocusSafe()
        {
            try { return XRL.Core.XRLCore.bThreadFocus; }
            catch { return false; }
        }
    }
}

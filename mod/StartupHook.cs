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
                        // (e.g. ModToolkit, ModManagerUI, SteamWorkshopUploaderView) — it wins
                        // over the stuck "MainMenu" view. In-game, `scene` stays "play".
                        string win = _uiWindow;
                        long uiAge = _uiSampleTs > 0
                            ? DateTimeOffset.UtcNow.ToUnixTimeSeconds() - _uiSampleTs : -1;
                        if (!live && win != "" && uiAge >= 0 && uiAge <= 5) scene = win;
                        bool popup = view.IndexOf("Popup", StringComparison.OrdinalIgnoreCase) >= 0;
                        // WHICH status tab, when the status screens are the active view. Cached by
                        // the UI-thread watcher: resolving it here would mean a Unity call off-thread.
                        string tab = "";
                        try
                        {
                            if (view.IndexOf("StatusScreens", StringComparison.OrdinalIgnoreCase) >= 0)
                                tab = PopupBridge.StatusTab ?? "";
                        }
                        catch { }
                        System.IO.File.WriteAllText(statePath,
                            "{\"scene\":\"" + scene.Replace("\"", "'") + "\",\"live\":" + (live ? "true" : "false")
                            + (popup ? ",\"popup\":\"" + view.Replace("\"", "'") + "\"" : "")
                            + (tab.Length > 0 ? ",\"tab\":\"" + tab.Replace("\"", "'") + "\"" : "")
                            + ",\"view\":\"" + view.Replace("\"", "'") + "\""
                            + ",\"window\":\"" + win.Replace("\"", "'") + "\""
                            + ",\"unity_scene\":\"" + _uiScene.Replace("\"", "'") + "\""
                            + ",\"ui_age\":" + uiAge
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
    }
}

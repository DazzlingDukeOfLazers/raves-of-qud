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
                        string scene = live && (view == "Stage" || view == "") ? "play" : view;
                        bool popup = view.IndexOf("Popup", StringComparison.OrdinalIgnoreCase) >= 0;
                        System.IO.File.WriteAllText(statePath,
                            "{\"scene\":\"" + scene.Replace("\"", "'") + "\",\"live\":" + (live ? "true" : "false")
                            + (popup ? ",\"popup\":\"" + view.Replace("\"", "'") + "\"" : "")
                            + ",\"ts\":" + DateTimeOffset.UtcNow.ToUnixTimeSeconds() + "}");
                    }
                    catch { /* transient IO — retry next tick */ }
                    System.Threading.Thread.Sleep(1000);
                }
            })
            { IsBackground = true, Name = "RavesHeartbeat" };
            _heartbeat.Start();
        }
    }
}

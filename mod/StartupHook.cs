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
                System.Console.WriteLine("[raves] pre-game bridge listener up.");
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] pre-game bridge start failed: " + e);
            }
        }
    }
}

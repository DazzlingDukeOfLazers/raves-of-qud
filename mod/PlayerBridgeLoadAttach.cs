using System;
using XRL;
using XRL.World;

namespace RavesOfQud
{
    /// <summary>
    /// Attaches <see cref="BridgePart"/> to the player ON LOAD, not just on creation.
    ///
    /// WHY THIS EXISTS. <see cref="PlayerBridgeMutator"/> is a [PlayerMutator], and that runs
    /// when the player GameObject is CREATED. It does not run when an existing save is loaded.
    /// So any character made before the bridge mod was installed came back with no BridgePart —
    /// and BridgePart is the only thing that drives Bridge.Tick / TickAction / TickRender, i.e.
    /// the only thing that PUBLISHES. The failure is invisible in the worst way:
    ///
    ///   - the bridge server still starts (StartupHook) and still accepts commands, so
    ///     `mapedit`, `uiback` and `loadsave` all work and log — everything looks healthy
    ///   - but nothing is ever published: snap.py blocks forever, and Raves sits connected
    ///     with empty panels reading "HP: —" while its own log says "Raves bridge: connected"
    ///
    /// That cost a long debugging pass on Lumpy (2026-08-07) which blamed, in order, the Raves
    /// data connection, a merged StartupHook change, and window focus — none of them.
    ///
    /// PlayerBecome already carries the part across a body swap, so between the three the part
    /// now survives every way a player object can come into being: created, loaded, swapped.
    /// </summary>
    [HasCallAfterGameLoaded]
    public static class PlayerBridgeLoadAttach
    {
        [CallAfterGameLoaded]
        public static void AttachOnLoad()
        {
            try
            {
                GameObject player = The.Player;
                if (player == null) return;               // no player yet — the mutator covers creation
                if (player.HasPart<BridgePart>()) return; // created with the mod, nothing to do
                player.AddPart(new BridgePart());
                try { Bridge.Server?.Log("bridge: attached BridgePart on load (save predates the mod)"); }
                catch { }
            }
            catch (Exception e)
            {
                // Never take the load down over this: a game that loads without the bridge is
                // recoverable, one that refuses to load is not.
                try { Bridge.Server?.Log("bridge: load-attach failed: " + e.Message); } catch { }
            }
        }
    }
}

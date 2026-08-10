using System;
using System.Collections.Generic;
using XRL.World;          // GameObject, Cell, GameObjectFactory

namespace RavesOfQud
{
    // ========================================================================
    //  CYBERNETICS TEST FIXTURE — the two things a becoming-nook session needs
    //  before it can exercise anything, and they are NOT the same kind of thing.
    //  That distinction is the whole reason this file has two entry points:
    //
    //    CREDITS are ITEMS.  XRL.UI.CyberneticsTerminal recomputes them every
    //    time it opens, by walking the subject's inventory:
    //        if (GO.TryGetPart<CyberneticsCreditWedge>(out var Part) && Part.Credits > 0)
    //            Credits += Part.Credits * GO.Count;
    //    so the only way to have credits is to be carrying wedges. Hence a chest.
    //
    //    LICENCE TIER IS NOT.  It is a plain integer property on the SUBJECT:
    //        Licenses = Subject.GetIntProperty("CyberneticsLicenses");
    //    and the whole of Qud's Upgrade Your License flow, after it has destroyed
    //    the wedges it charged you, is one line:
    //        Subject.ModIntProperty("CyberneticsLicenses", 1);
    //    So granting tiers needs no item at all, and Grant() below is that same
    //    line. `Points Used` is derived (the sum of installed CyberneticsBaseItem
    //    .Cost) and `LicensesRemaining` is Licenses - LicensesUsed, so neither is
    //    settable and neither should be faked here.
    //
    //  MAIN-THREAD ONLY, both of them: they create GameObjects and mutate cells,
    //  so they belong on the Server.Incoming path (drained by Tick/TickRender)
    //  exactly like `zoo` and `check`, never on the socket thread.
    // ========================================================================
    public static class CyberTestbed
    {
        /// Every implant blueprint in the game, in a chest on an adjacent cell, plus a stack of
        /// credit wedges. Shares ZooBuilder's selector rather than re-deriving the set: "implants"
        /// there is already `bp.HasPart("CyberneticsBaseItem")`, which is the same predicate the
        /// terminal's own install list is built from.
        /// Put `n` implants straight into the PLAYER'S PACK, unidentified.
        ///
        /// The chest below is the right fixture for the terminal (that is where Qud expects the
        /// parts to live) and the wrong one for the INVENTORY SCREEN, which can only show what is
        /// carried -- and there is no cheap way from the harness to get a chest's contents into the
        /// pack (walking onto it does not take them; only currency is auto-taken). An unidentified
        /// artifact in the pack is the starting state for every "identification re-files the item"
        /// test, so it needs a one-command source.
        public static string Carry(GameObject player, int n)
        {
            if (player == null) return "no player";
            int added = 0;
            foreach (string bp in ZooBuilder.Select("implants"))
            {
                if (added >= n) break;
                try
                {
                    GameObject o = GameObjectFactory.Factory.CreateObject(bp);
                    if (o == null) continue;
                    // Do NOT touch Understood here: a freshly built implant carries its Examiner
                    // unidentified, which is the whole point -- it enters the list as "weird
                    // artifact" under Artifacts, exactly as one looted from a ruin would.
                    player.Inventory.AddObject(o);
                    added++;
                }
                catch { }
            }
            return "carried " + added + " unidentified implants";
        }

        public static string Build(GameObject player, int wedges)
        {
            if (player == null) return "no player";
            Cell here = player.CurrentCell;
            if (here == null) return "player has no cell";

            // Qud's own wish handler picks a spot the same way -- first ADJACENT EMPTY cell, and it
            // says so out loud when there is none rather than dropping the object silently.
            Cell target = null;
            foreach (Cell c in here.GetAdjacentCells())
            {
                if (c != null && c.IsEmpty()) { target = c; break; }
            }
            if (target == null) return "no adjacent empty cell for the chest";

            GameObject chest = GameObjectFactory.Factory.CreateObject("Chest");
            if (chest == null) return "could not create Chest";
            target.AddObject(chest);

            int implants = 0, failed = 0;
            foreach (string bp in ZooBuilder.Select("implants"))
            {
                try
                {
                    GameObject o = GameObjectFactory.Factory.CreateObject(bp);
                    if (o == null) { failed++; continue; }
                    chest.Inventory.AddObject(o);
                    implants++;
                }
                catch { failed++; }   // one bad blueprint must not cost us the other 200
            }

            int wedgeCount = 0;
            try
            {
                GameObject w = GameObjectFactory.Factory.CreateObject("CyberneticsCreditWedge");
                if (w != null)
                {
                    // Wedges stack, and the terminal multiplies by Count (`Part.Credits * GO.Count`),
                    // so one stacked object is worth the same as N loose ones and keeps the chest
                    // readable.
                    if (wedges > 1) w.Count = wedges;
                    chest.Inventory.AddObject(w);
                    wedgeCount = wedges;
                }
            }
            catch { }

            return "chest at " + target.X + "," + target.Y + " with " + implants + " implants ("
                + failed + " failed), " + wedgeCount + " credit wedges";
        }

        /// Add licence TIERS directly, the same way Qud's upgrade screen does once it has taken
        /// payment. No item involved, so this is the honest way to hand them out for testing.
        public static string Grant(GameObject player, int n)
        {
            if (player == null) return "no player";
            player.ModIntProperty("CyberneticsLicenses", n);
            int now = player.GetIntProperty("CyberneticsLicenses");
            int free = player.GetIntProperty("FreeCyberneticsLicenses");
            return "CyberneticsLicenses +" + n + " -> " + now + " (of which free: " + free + ")";
        }
    }
}

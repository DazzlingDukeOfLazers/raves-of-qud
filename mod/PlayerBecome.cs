using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL;             // The (The.Game / The.Core)
using XRL.World;       // GameObject, Zone, Cell, GameObjectFactory

namespace RavesOfQud
{
    // ========================================================================
    //  QUD-COUPLED CODE (the WRITE side).  Swaps the player's controlled body
    //  to an ARBITRARY blueprint — creature, item, or furniture. "It's not
    //  Qud's fault if they're an immobile dresser": if the chosen blueprint has
    //  no Brain/legs, the player simply can't move. That is intended.
    //
    //  Verified names against Assembly-CSharp.dll + Base XML (compiler is the
    //  source of truth; RavesOfQudBridge.csproj type-checks these against the
    //  real DLL):
    //    - GameObjectFactory.Factory.CreateObject(blueprint)
    //    - The.Game.Player.Body  (GameObject; assigning it re-homes control)
    //    - Cell.AddObject(GameObject) / Cell.RemoveObject(GameObject)
    //    - GameObject.HasPart<T>() / AddPart(IPart) / Obliterate()
    //    - GameObject.DisplayNameOnly, GameObject.CurrentCell
    // ========================================================================

    /// <summary>
    /// Turns the player INTO another blueprint by building that object, moving
    /// player control onto it, and retiring the old body. The bridge tick lives
    /// on a <see cref="BridgePart"/> attached to the player object, so the part
    /// is carried onto the new body first — otherwise the swap would silence the
    /// bridge the instant control moves.
    /// </summary>
    public static class PlayerBecome
    {
        public static string Become(GameObject player, string blueprint)
        {
            if (string.IsNullOrEmpty(blueprint)) return "no blueprint";
            if (player == null || player.CurrentCell == null) return "no player cell";

            GameObject next;
            try { next = GameObjectFactory.Factory.CreateObject(blueprint); }
            catch (Exception e) { return "create failed: " + e.Message; }
            if (next == null) return "unknown blueprint '" + blueprint + "'";

            Cell cell = player.CurrentCell;
            GameObject old = player;

            // Drop the new body where the player stands, THEN hand it the bridge
            // tick so it keeps streaming to Godot once it becomes the player.
            cell.AddObject(next);
            if (!next.HasPart<BridgePart>())
                next.AddPart(new BridgePart());

            // Re-home player control onto the new body. Qud's camera + input follow
            // whatever GameObject is Player.Body.
            The.Game.Player.Body = next;

            // Retire the old body so we don't leave an armed twin standing around.
            // Detach from the zone first (stops any NPC turns) then obliterate.
            try
            {
                if (old.CurrentCell != null) old.CurrentCell.RemoveObject(old);
                old.Obliterate();
            }
            catch { /* mid-event teardown; the object is already out of the zone */ }

            // Repaint Qud's own map around the new body.
            try { if (The.Core != null) The.Core.RenderBase(); } catch { }

            string label = blueprint;
            try { label = next.DisplayNameOnly; } catch { }
            return "became " + label + " [" + blueprint + "]";
        }

        // Categories the character-creator menu offers. Shares ZooBuilder's blueprint
        // enumeration so the two features never drift out of sync.
        private static readonly string[] Categories =
            { "creatures", "weapons", "food", "items", "implants", "furniture" };

        /// <summary>
        /// Dump the pickable blueprint catalog to become_catalog.json next to the
        /// screenshots, so the Godot menu can populate itself without a live
        /// request/response over the socket. File IO only — safe on the main thread.
        /// Values are blueprint ids (e.g. "Dresser", "Snapjaw Scavenger"), which the
        /// menu shows directly and sends verbatim back to <see cref="Become"/>. We do
        /// NOT resolve friendly names here — that would mean instantiating ~1300
        /// objects, which is slow and can have side effects.
        /// </summary>
        public static string WriteCatalog()
        {
            var sb = new StringBuilder();
            sb.Append('{');
            for (int c = 0; c < Categories.Length; c++)
            {
                if (c > 0) sb.Append(',');
                sb.Append('"').Append(Categories[c]).Append("\":[");
                List<string> names = ZooBuilder.Select(Categories[c]);
                for (int i = 0; i < names.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append('"').Append(Esc(names[i])).Append('"');
                }
                sb.Append(']');
            }
            sb.Append('}');

            string path = Path.GetFullPath(Path.Combine(TileExporter.Dir, "..", "become_catalog.json"));
            File.WriteAllText(path, sb.ToString());
            return path;
        }

        private static string Esc(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}

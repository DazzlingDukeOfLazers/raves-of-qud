using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL.World;          // GameObject, Zone, Cell, GameObjectFactory
using XRL.World.Parts;    // Render

namespace RavesOfQud
{
    // ========================================================================
    //  QUD-COUPLED CODE (the WRITE side), same contract as ZooBuilder.cs:
    //  creates game objects and mutates the active zone. Verified names:
    //    - Cell.GetObjects() (ObjectRack -> enumerable), Cell.RemoveObject/AddObject
    //    - GameObject.Obliterate(), player.SystemMoveTo(cell)
    //    - Render.Tile / ColorString / DetailColor / DisplayName
    // ========================================================================

    /// <summary>
    /// The Object Checker stage (phase2-test-plan Workstream A): ONE blueprint on a
    /// clean field, player adjacent — several proximity-gated effects need distance
    /// ≤ 1 (ConcealedHologramMaterial's glitch flicker; puffers puff). Each Check()
    /// clears the stage rect and re-dresses it, so a sweep just calls it per element.
    /// Ground truth for the element goes to checker_stage.json next to the tiles dir;
    /// the Python driver (tools/capture/checker.py) compares it against the wire.
    /// </summary>
    public static class ObjectChecker
    {
        // Stage rect half-extents around the zone-center stage cell. Big enough to
        // isolate the element from leftover zone dressing; small enough to leave
        // the rest of the zone (and any parked zoo) alone.
        private const int RX = 3;
        private const int RY = 2;

        // Blueprint enumeration for the sweep — the checker's OWN list (walls,
        // plants, liquids added), separate from PlayerBecome.Categories so the
        // character-creator menu doesn't change. Selection logic stays shared in
        // ZooBuilder.Select — one source of truth for what a category contains.
        private static readonly string[] Categories =
            { "walls", "plants", "creatures", "liquids", "furniture", "items", "weapons", "food", "implants" };

        public static string Check(GameObject player, string bp)
        {
            if (player == null || player.CurrentCell == null) return WriteResult(bp, false, "no player cell", null, 0, 0, 0);
            Zone zone = player.CurrentCell.ParentZone;
            if (zone == null) return WriteResult(bp, false, "no zone", null, 0, 0, 0);
            if (string.IsNullOrEmpty(bp)) return WriteResult(bp, false, "no blueprint given", null, 0, 0, 0);

            int cx = zone.Width / 2;
            int cy = zone.Height / 2;
            int cleared = ClearStage(zone, player, cx, cy);

            GameObject obj;
            try { obj = GameObjectFactory.Factory.CreateObject(bp); }
            catch (Exception e) { return WriteResult(bp, false, "create threw: " + e.Message, null, cx, cy, cleared); }
            if (obj == null) return WriteResult(bp, false, "create returned null", null, cx, cy, cleared);

            Cell stage = zone.GetCell(cx, cy);
            if (stage == null) return WriteResult(bp, false, "no stage cell", null, cx, cy, cleared);
            stage.AddObject(obj);

            // Park the player adjacent (west of the stage) — inside the cleared
            // field, distance 1, so proximity-gated behaviour is armed.
            Cell seat = zone.GetCell(cx - 1, cy);
            if (seat != null) player.SystemMoveTo(seat);

            return WriteResult(bp, true, null, obj, cx, cy, cleared);
        }

        /// Remove every object in the stage rect except the player. Obliterate after
        /// RemoveObject (the PlayerBecome retire pattern) so nothing lingers in pools.
        private static int ClearStage(Zone zone, GameObject player, int cx, int cy)
        {
            int n = 0;
            for (int y = cy - RY; y <= cy + RY; y++)
                for (int x = cx - RX; x <= cx + RX; x++)
                {
                    Cell c = zone.GetCell(x, y);
                    if (c == null) continue;
                    var doomed = new List<GameObject>();
                    foreach (GameObject go in c.GetObjects())
                        if (go != null && go != player) doomed.Add(go);
                    foreach (GameObject go in doomed)
                    {
                        try { c.RemoveObject(go); go.Obliterate(); n++; } catch { }
                    }
                }
            return n;
        }

        /// <summary>
        /// Dump the checker's category -> blueprint-list enumeration to
        /// checker_catalog.json, mirroring PlayerBecome.WriteCatalog (ids only —
        /// resolving friendly names would instantiate ~1300 objects).
        /// </summary>
        public static string WriteChecklist()
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

            string path = Path.GetFullPath(Path.Combine(TileExporter.Dir, "..", "checker_catalog.json"));
            File.WriteAllText(path, sb.ToString());
            return path;
        }

        /// Ground truth the Python driver diffs the wire against: what the mod
        /// believes it staged (static blueprint render facts, stage coords).
        private static string WriteResult(string bp, bool ok, string error, GameObject obj, int cx, int cy, int cleared)
        {
            string tile = "", color = "", detail = "", name = "";
            if (obj != null)
            {
                try
                {
                    Render r = obj.GetPart<Render>();
                    if (r != null) { tile = r.Tile ?? ""; color = r.ColorString ?? ""; detail = r.DetailColor ?? ""; }
                    name = obj.DisplayNameOnly ?? "";
                }
                catch { }
            }

            var sb = new StringBuilder();
            sb.Append('{');
            sb.Append("\"bp\":\"").Append(Esc(bp)).Append("\",");
            sb.Append("\"ok\":").Append(ok ? "true" : "false").Append(',');
            sb.Append("\"error\":\"").Append(Esc(error ?? "")).Append("\",");
            sb.Append("\"x\":").Append(cx).Append(',');
            sb.Append("\"y\":").Append(cy).Append(',');
            sb.Append("\"cleared\":").Append(cleared).Append(',');
            sb.Append("\"tile\":\"").Append(Esc(tile)).Append("\",");
            sb.Append("\"color\":\"").Append(Esc(color)).Append("\",");
            sb.Append("\"detail\":\"").Append(Esc(detail)).Append("\",");
            sb.Append("\"name\":\"").Append(Esc(name)).Append('"');
            sb.Append('}');

            string path = Path.GetFullPath(Path.Combine(TileExporter.Dir, "..", "checker_stage.json"));
            File.WriteAllText(path, sb.ToString());
            return ok ? ("staged '" + bp + "' at (" + cx + "," + cy + "), cleared " + cleared)
                      : ("check FAILED for '" + bp + "': " + error);
        }

        private static string Esc(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL.World;          // GameObject, Zone, Cell, GameObjectFactory
using XRL.World.Parts;    // Render, Brain

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
        // The clear is the WHOLE ZONE, not a stage rect: a rect leaks — staged
        // creatures wander out between checks and accumulate into a zone-wide
        // brawl (the 908-creature sweep died to exactly that: escapee goatfolk,
        // ambient popups, a feared player). "Clean field" means the zone.

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
            int cleared = ClearZone(zone, player);

            GameObject obj;
            try { obj = GameObjectFactory.Factory.CreateObject(bp); }
            catch (Exception e) { return WriteResult(bp, false, "create threw: " + e.Message, null, cx, cy, cleared); }
            if (obj == null) return WriteResult(bp, false, "create returned null", null, cx, cy, cleared);

            Pacify(obj, player);

            Cell stage = zone.GetCell(cx, cy);
            if (stage == null) return WriteResult(bp, false, "no stage cell", null, cx, cy, cleared);

            // AddObject fires the object-entered event chain — special blueprints
            // (period variants, corpses) can THROW in a handler. Unwrapped, that
            // skipped WriteResult and the sweep saw only a silent timeout; report
            // the real error instead (the 908-creature sweep's 7 mystery FAILs).
            try
            {
                stage.AddObject(obj);

                // Park the player adjacent (west of the stage) — inside the cleared
                // field, distance 1, so proximity-gated behaviour is armed.
                Cell seat = zone.GetCell(cx - 1, cy);
                if (seat != null) player.SystemMoveTo(seat);
            }
            catch (Exception e)
            {
                return WriteResult(bp, false, "stage threw: " + e.Message, obj, cx, cy, cleared);
            }

            return WriteResult(bp, true, null, obj, cx, cy, cleared);
        }

        /// Remove every object in the zone except the player. Obliterate after
        /// RemoveObject (the PlayerBecome retire pattern) so nothing lingers in pools.
        private static int ClearZone(Zone zone, GameObject player)
        {
            int n = 0;
            for (int y = 0; y < zone.Height; y++)
                for (int x = 0; x < zone.Width; x++)
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

        /// Deterministic-stage rule: a staged creature must not fight, flee, or
        /// wander off the stage — but it stays ACTIVE (animations must run; the
        /// proximity-gated behaviours are the point of the adjacent seat). The
        /// KNOWN EXCEPTIONS (engulfers pull, puffers burst — aggression that
        /// isn't hostility) stay live by design; the sweep is what finds them.
        private static void Pacify(GameObject obj, GameObject player)
        {
            try
            {
                Brain brain = obj.GetPart<Brain>();
                if (brain == null) return;
                brain.Hostile = false;
                brain.Wanders = false;
                brain.WandersRandomly = false;
                try { brain.Goals.Clear(); } catch { }
                try { brain.AdjustFeeling(player, 100); } catch { }
            }
            catch { }
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

            // ATOMIC write (temp + replace): WriteAllText truncates in place, and
            // the driver's mtime poll can read the empty in-between (it killed a
            // 748-element run at 317). Replace/Move is atomic on NTFS.
            string path = Path.GetFullPath(Path.Combine(TileExporter.Dir, "..", "checker_stage.json"));
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, sb.ToString());
            try { if (File.Exists(path)) File.Delete(path); } catch { }
            File.Move(tmp, path);
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

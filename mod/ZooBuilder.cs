using System;
using System.Collections.Generic;
using System.Linq;
using XRL.World;          // GameObject, Zone, Cell, GameObjectFactory, GameObjectBlueprint
using XRL.World.Parts;    // Render, Description

namespace RavesOfQud
{
    // ========================================================================
    //  QUD-COUPLED CODE (the WRITE side).  Everything here CREATES game objects
    //  and mutates the active zone, unlike ZoneSnapshot.cs which only reads.
    //  Keep Qud symbol coupling confined to this file so a Qud patch only breaks
    //  in one place.  Verified names against Assembly-CSharp.dll + Base XML:
    //    - GameObjectFactory.Factory.CreateObject(blueprint)
    //    - GameObjectFactory.Factory.Blueprints : Dictionary<string, GameObjectBlueprint>
    //    - GameObjectBlueprint.Name / InheritsFrom(string) / HasPart(string)
    //    - Cell.AddObject(string) / Cell.AddObject(GameObject)
    //    - Render.DisplayName, Description.Short
    //    - Blueprints: Sign, IronFence, "Iron Gate"  (spaces are real)
    // ========================================================================

    /// <summary>
    /// Builds a debug "zoo" into the player's current zone: a grid of fenced pens,
    /// one creature per pen with a labeled sign, or dense labeled caches of items
    /// (weapons / food / items / implants). Paginated because the full creature
    /// catalog (~1300) spans many zones.
    /// </summary>
    public static class ZooBuilder
    {
        // Pen = 3x3 fence ring (creature in the middle, gate bottom-center) + a sign
        // one cell below the gate. Laid on a 4-wide x 5-tall pitch (1-cell aisles).
        private const int PenPitchX = 4;
        private const int PenPitchY = 5;

        private const string Fence = "IronFence";
        private const string Gate = "Iron Gate";
        private const string SignBlueprint = "Sign";

        public static string Build(GameObject player, string category, int page)
        {
            if (player == null || player.CurrentCell == null) return "no player cell";
            Zone zone = player.CurrentCell.ParentZone;
            if (zone == null) return "no zone";

            category = string.IsNullOrEmpty(category) ? "creatures" : category.ToLowerInvariant();
            List<string> names = Select(category);
            if (names.Count == 0) return "no blueprints for '" + category + "'";

            bool pens = category == "creatures";
            int perPage = pens ? CreaturesPerPage(zone) : CachePerPage(zone);
            int pages = Math.Max(1, (names.Count + perPage - 1) / perPage);
            if (page < 0) page = 0;
            if (page >= pages) page = pages - 1;
            List<string> slice = names.Skip(page * perPage).Take(perPage).ToList();

            if (pens) BuildPens(zone, slice);
            else BuildCache(zone, slice, category);

            // Park the player in the NW border aisle, clear of the pens.
            Cell home = zone.GetCell(0, 0);
            if (home != null) player.SystemMoveTo(home);

            return string.Format("zoo '{0}' page {1}/{2}: placed {3} of {4}",
                category, page + 1, pages, slice.Count, names.Count);
        }

        private static int CreaturesPerPage(Zone z)
        {
            int cols = (z.Width - 1) / PenPitchX;
            int rows = (z.Height - 1) / PenPitchY;
            return Math.Max(1, cols * rows);
        }

        private static int CachePerPage(Zone z)
        {
            int cols = (z.Width - 2) / 2;   // items on even columns, aisles between
            int rows = (z.Height - 3) / 2;  // reserve row 0 for the banner
            return Math.Max(1, cols * rows);
        }

        private static void BuildPens(Zone zone, List<string> names)
        {
            GameObjectFactory factory = GameObjectFactory.Factory;
            int i = 0;
            for (int gy = 1; gy + 3 < zone.Height && i < names.Count; gy += PenPitchY)
                for (int gx = 1; gx + 2 < zone.Width && i < names.Count; gx += PenPitchX)
                    BuildPen(zone, factory, gx, gy, names[i++]);
        }

        private static void BuildPen(Zone zone, GameObjectFactory factory, int x, int y, string bp)
        {
            for (int dx = 0; dx < 3; dx++)
                for (int dy = 0; dy < 3; dy++)
                {
                    bool border = dx == 0 || dx == 2 || dy == 0 || dy == 2;
                    if (!border) continue;
                    if (dx == 1 && dy == 2) continue;   // leave the gate slot open
                    AddBlueprint(zone, x + dx, y + dy, Fence);
                }
            AddBlueprint(zone, x + 1, y + 2, Gate);

            string label = bp;
            GameObject creature = TryCreate(factory, bp);
            if (creature != null)
            {
                try { label = creature.DisplayNameOnly; } catch { }
                Cell center = zone.GetCell(x + 1, y + 1);
                if (center != null) center.AddObject(creature);
            }

            GameObject sign = MakeSign(factory, label, bp);
            if (sign != null)
            {
                Cell below = zone.GetCell(x + 1, y + 3);
                if (below != null) below.AddObject(sign);
            }
        }

        private static void BuildCache(Zone zone, List<string> names, string category)
        {
            GameObjectFactory factory = GameObjectFactory.Factory;

            GameObject banner = MakeSign(factory, category + " cache", category);
            if (banner != null)
            {
                Cell bc = zone.GetCell(1, 0);
                if (bc != null) bc.AddObject(banner);
            }

            int i = 0;
            for (int y = 2; y < zone.Height && i < names.Count; y += 2)
                for (int x = 2; x < zone.Width && i < names.Count; x += 2)
                {
                    GameObject obj = TryCreate(factory, names[i++]);
                    if (obj == null) continue;
                    Cell c = zone.GetCell(x, y);
                    if (c != null) c.AddObject(obj);
                }
        }

        private static GameObject MakeSign(GameObjectFactory factory, string label, string bp)
        {
            GameObject sign = TryCreate(factory, SignBlueprint);
            if (sign == null) return null;
            Render render = sign.GetPart<Render>();
            if (render != null) render.DisplayName = label + " sign";
            Description desc = sign.GetPart<Description>();
            if (desc != null) desc.Short = label + "  [" + bp + "]";
            return sign;
        }

        private static GameObject TryCreate(GameObjectFactory factory, string bp)
        {
            try { return factory.CreateObject(bp); }
            catch { return null; }
        }

        private static void AddBlueprint(Zone zone, int x, int y, string bp)
        {
            Cell c = zone.GetCell(x, y);
            if (c == null) return;
            try { c.AddObject(bp); } catch { }
        }

        // Enumerate every non-base blueprint matching a category, sorted for stable paging.
        // Public so the character-creator ("become") catalog shares one source of truth.
        public static List<string> Select(string category)
        {
            GameObjectFactory factory = GameObjectFactory.Factory;
            var outp = new List<string>();
            foreach (GameObjectBlueprint bp in factory.Blueprints.Values)
            {
                if (bp == null || string.IsNullOrEmpty(bp.Name)) continue;
                if (bp.Name.StartsWith("Base")) continue;
                if (!Match(bp, category)) continue;
                outp.Add(bp.Name);
            }
            outp.Sort(StringComparer.OrdinalIgnoreCase);
            return outp;
        }

        private static bool Match(GameObjectBlueprint bp, string category)
        {
            switch (category)
            {
                case "creatures":
                    return bp.InheritsFrom("Creature");
                case "weapons":
                    return bp.HasPart("MeleeWeapon") || bp.HasPart("MissileWeapon");
                case "food":
                    return bp.HasPart("Food");
                case "implants":
                    return bp.HasPart("CyberneticsBaseItem");
                case "furniture":
                    return bp.InheritsFrom("Furniture");
                case "walls":
                    return bp.InheritsFrom("Wall");
                case "plants":
                    // Two roots: the Plant blueprint tree and the part-based flora
                    // (some fungi/vines carry PlantProperties without the ancestor).
                    return bp.InheritsFrom("Plant") || bp.HasPart("PlantProperties");
                case "liquids":
                    // Pool/puddle blueprints (open liquid on the floor), not
                    // liquid CONTAINERS (waterskins etc. stay in "items").
                    return bp.InheritsFrom("LiquidPool") || bp.InheritsFrom("Water");
                case "items":
                    return bp.InheritsFrom("Item")
                        && !bp.HasPart("MeleeWeapon") && !bp.HasPart("MissileWeapon")
                        && !bp.HasPart("Food") && !bp.HasPart("CyberneticsBaseItem");
                case "all":
                    return true;
                default:
                    return false;
            }
        }
    }
}

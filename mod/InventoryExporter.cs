using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL.World;
using XRL.World.Anatomy;   // BodyPart (the paper doll)

namespace RavesOfQud
{
    /// <summary>
    /// Export the player's INVENTORY — categories, their items, weights and the
    /// carried/max header — to <c>inventory.json</c> for Raves' Equipment tab.
    ///
    /// Mirrors Qud's own screen (InventoryAndEquipmentStatusScreen + InventoryLine):
    /// items are grouped by <c>GameObject.GetInventoryCategory()</c>, the row label is
    /// <c>go.DisplayName</c> (Qud markup intact), the item weight column is
    /// <c>[{go.Weight} lbs.]</c>, a category's column is <c>|{sum} lbs.|</c>, and the
    /// header is Qud's own <c>${GetFreeDrams()}</c> + <c>{carried}/{max} lbs.</c>.
    /// Tiles come from <c>RenderForUI("Inventory")</c> — the PERCEIVED render, so an
    /// unidentified artifact shows Qud's unknown icon, not its true tile.
    /// </summary>
    public static class InventoryExporter
    {
        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] inventory export failed: " + e.Message); }
        }

        private static void WriteTile(JsonWriter j, GameObject go, string context = "Inventory")
        {
            try
            {
                // RenderForUI returns a RenderEvent (fields, not the Renderable accessors)
                var r = go.RenderForUI(context);
                if (r == null) return;
                string tile = r._Tile;
                if (string.IsNullOrEmpty(tile)) return;
                TileExporter.Ensure(tile);
                j.Member("tile", tile).Member("color", r.ColorString ?? "")
                 .Member("detail", r.DetailColor ?? "");
            }
            catch { }
        }

        /// True when a display name carries no actual NOUN — only markup, badges and
        /// punctuation (the worn-armour case: "{{b|<0x04>}}1 {{K|\t}}0").
        private static bool QudText_LooksNameless(string s)
        {
            if (string.IsNullOrEmpty(s)) return true;
            bool depth = false;
            int letters = 0;
            for (int i = 0; i < s.Length; i++)
            {
                if (i + 1 < s.Length && s[i] == '{' && s[i + 1] == '{') { depth = true; i++; continue; }
                if (s[i] == '|' && depth) { depth = false; continue; }
                if (i + 1 < s.Length && s[i] == '}' && s[i + 1] == '}') { i++; continue; }
                if (!depth && char.IsLetter(s[i])) letters++;
            }
            return letters < 2;
        }

        private static void Export()
        {
            GameObject p = null;
            try { p = XRL.The.Player; } catch { }
            if (p == null) return;

            var j = new JsonWriter();
            j.BeginObject();
            // header, Qud's own strings (InventoryAndEquipmentStatusScreen.UpdateViewFromData)
            try { j.Member("drams", p.GetFreeDrams()); } catch { }
            try { j.Member("carried", p.GetCarriedWeight()); } catch { }
            try { j.Member("maxCarried", p.GetMaxCarriedWeight()); } catch { }

            // group by Qud's inventory category, like the screen's objectCategories
            var cats = new Dictionary<string, List<GameObject>>();
            try
            {
                var inv = p.Inventory;
                if (inv != null)
                    foreach (GameObject go in inv.GetObjectsDirect())
                    {
                        if (go == null) continue;
                        string cat = "Miscellaneous";
                        try { cat = go.GetInventoryCategory() ?? cat; } catch { }
                        if (!cats.ContainsKey(cat)) cats[cat] = new List<GameObject>();
                        cats[cat].Add(go);
                    }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] inventory scan: " + e.Message); }

            // BODY PARTS (the paper doll): Qud's own body tree — each part's name,
            // type and whatever is equipped there (EquipmentLine renders the same set).
            j.Name("slots").BeginArray();
            try
            {
                var body = p.Body;
                if (body != null)
                    foreach (BodyPart bp in body.GetParts())
                    {
                        if (bp == null) continue;
                        j.BeginObject();
                        try { j.Member("name", bp.Name ?? ""); } catch { }
                        try { j.Member("type", bp.Type ?? ""); } catch { }
                        try { j.Member("desc", bp.GetOrdinalName() ?? ""); } catch { }
                        try { j.Member("primary", bp.Primary); } catch { }
                        // EQUIPPED ONLY — EquipmentLine renders bp.Equipped (plus
                        // Cybernetics), never DefaultBehavior, so a natural weapon like a
                        // mutant claw shows NO tile in Qud's doll. Our DefaultBehavior
                        // fallback drew a claw in a slot Qud leaves empty (parity leaf
                        // doll_image[4]: Qud ink 1x3, ours 39x35).
                        GameObject eq = null;
                        try { eq = bp.Equipped; } catch { }
                        if (eq == null) { try { eq = bp.Cybernetics; } catch { } }
                        if (eq != null)
                        {
                            try { j.Member("item", eq.DisplayName ?? ""); } catch { }
                            // the PAPER DOLL uses Qud's "Equipment" render context
                            // (EquipmentLine: RenderForUI("Equipment")) — a different tile
                            // and colours than the "Inventory" context the list uses
                            WriteTile(j, eq, "Equipment");
                        }
                        j.EndObject();
                    }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] body scan: " + e.Message); }
            j.EndArray();

            // FILTER-STRIP ORDER, Qud's way: its item list is sorted by sortString (the
            // item's stripped lowercase DISPLAY NAME, globally — not by category), and
            // filterBarCategories collects each category on FIRST APPEARANCE in that list.
            // So the strip order is "category of the alphabetically-first item", which is
            // nothing like the alphabetical category order the list itself uses.
            try
            {
                var flat = new List<KeyValuePair<string, string>>();   // name -> category
                var invOrder = p.Inventory;
                if (invOrder != null)
                    foreach (GameObject go in invOrder.GetObjectsDirect())
                    {
                        if (go == null) continue;
                        string c2 = "Miscellaneous", n2 = "";
                        try { c2 = go.GetInventoryCategory() ?? c2; } catch { }
                        try { n2 = (go.DisplayNameOnlyStripped ?? "").ToLowerInvariant(); } catch { }
                        flat.Add(new KeyValuePair<string, string>(n2, c2));
                    }
                // EQUIPPED items count too: Qud's filter list is built from the screen's
                // whole object list, which includes what's on the body — so a category
                // only worn (armour, a wielded blade) still gets a strip cell, and its
                // item name participates in the first-appearance ordering.
                try
                {
                    var body2 = p.Body;
                    if (body2 != null)
                        foreach (BodyPart bp in body2.GetParts())
                        {
                            GameObject eq = null;
                            try { eq = bp.Equipped; } catch { }
                            if (eq == null) continue;
                            string ec = "Miscellaneous", en = "";
                            try { ec = eq.GetInventoryCategory() ?? ec; } catch { }
                            try { en = (eq.DisplayNameOnlyStripped ?? "").ToLowerInvariant(); } catch { }
                            bool dup = false;
                            foreach (var f2 in flat) if (f2.Key == en && f2.Value == ec) { dup = true; break; }
                            if (!dup) flat.Add(new KeyValuePair<string, string>(en, ec));
                        }
                }
                catch { }
                // NOT sorted: Qud's filter bar follows the inventory's own object order
                // (first appearance while walking the pack), which is why its strip reads
                // Water Containers, Light Sources, Melee Weapons, Tools… rather than any
                // alphabetical sequence. Sorting by name produced a different order.
                var seen = new List<string>();
                foreach (var kv in flat)
                    if (!seen.Contains(kv.Value)) seen.Add(kv.Value);
                // objects, not bare names: a category can be EQUIPPED-ONLY (e.g. Clothes)
                // and so have no list entry to borrow an icon from
                j.Name("filterOrder").BeginArray();
                foreach (string n in seen)
                {
                    j.BeginObject();
                    j.Member("name", n);
                    try
                    {
                        string ic;
                        if (Qud.UI.FilterBarCategoryButton.categoryImageMap.TryGetValue(n, out ic)
                            && !string.IsNullOrEmpty(ic))
                        {
                            TileExporter.Ensure(ic);
                            j.Member("icon", ic);
                        }
                    }
                    catch { }
                    j.EndObject();
                }
                j.EndArray();
            }
            catch (Exception e) { System.Console.WriteLine("[raves] filter order: " + e.Message); }

            // WHICH filters are currently ON. Qud persists the enabled set with the
            // save, so the strip comes back olive on the same categories after a
            // restart — without this, Raves always drew "ALL" and its cell colours
            // could never match. Read it off the live buttons rather than the
            // FilterBar, since several screens own a bar and the button is the thing
            // that actually paints (FilterBarCategoryButton.categoryEnabled).
            try
            {
                j.Name("enabledFilters").BeginArray();
                var btns = UnityEngine.Resources.FindObjectsOfTypeAll<Qud.UI.FilterBarCategoryButton>();
                if (btns != null)
                    foreach (var b in btns)
                    {
                        if (b == null || !b.categoryEnabled) continue;
                        if (string.IsNullOrEmpty(b.category)) continue;
                        j.Value(b.category);
                    }
                j.EndArray();
            }
            catch (Exception e) { System.Console.WriteLine("[raves] enabled filters: " + e.Message); }

            var names = new List<string>(cats.Keys);
            names.Sort(StringComparer.OrdinalIgnoreCase);
            j.Name("categories").BeginArray();
            foreach (string cat in names)
            {
                List<GameObject> items = cats[cat];
                items.Sort((a, b) =>
                {
                    string an = "", bn = "";
                    try { an = a.DisplayNameOnlyStripped ?? ""; } catch { }
                    try { bn = b.DisplayNameOnlyStripped ?? ""; } catch { }
                    return string.Compare(an, bn, StringComparison.OrdinalIgnoreCase);
                });
                int catWeight = 0;
                foreach (GameObject go in items) { try { catWeight += go.Weight; } catch { } }
                j.BeginObject();
                j.Member("name", cat).Member("weight", catWeight).Member("count", items.Count);
                // Qud's OWN filter-bar icon for this category (FilterBarCategoryButton's
                // static categoryImageMap) plus the fixed two-tone it paints them with.
                try
                {
                    string icon;
                    if (Qud.UI.FilterBarCategoryButton.categoryImageMap.TryGetValue(cat, out icon)
                        && !string.IsNullOrEmpty(icon))
                    {
                        TileExporter.Ensure(icon);
                        j.Member("icon", icon);
                    }
                }
                catch { }
                j.Name("items").BeginArray();
                foreach (GameObject go in items)
                {
                    j.BeginObject();
                    // DisplayName = GetDisplayNameEvent over (Render.DisplayName ?? Blueprint):
                    // for some worn items that base is empty and only the AV/DV badges come
                    // back, so fall back to the explicit full overload, then the short name.
                    string nm = "";
                    try { nm = go.DisplayName ?? ""; } catch { }
                    try
                    {
                        if (QudText_LooksNameless(nm))
                        {
                            string alt = go.GetDisplayName(int.MaxValue);
                            if (!QudText_LooksNameless(alt)) nm = alt;
                        }
                    }
                    catch { }
                    try
                    {
                        if (QudText_LooksNameless(nm))
                        {
                            string alt2 = go.DisplayNameOnly;
                            if (!QudText_LooksNameless(alt2)) nm = alt2;
                        }
                    }
                    catch { }
                    try { if (QudText_LooksNameless(nm)) nm = go.Blueprint ?? nm; } catch { }
                    j.Member("name", nm);
                    try { j.Member("weight", go.Weight); } catch { }
                    try { j.Member("id", go.IDIfAssigned ?? ""); } catch { }
                    WriteTile(j, go);
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();

            Directory.CreateDirectory(Root);
            File.WriteAllText(Path.Combine(Root, "inventory.json"), j.ToString(), new UTF8Encoding(false));
        }
    }
}

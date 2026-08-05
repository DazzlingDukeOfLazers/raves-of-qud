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

        private static void WriteTile(JsonWriter j, GameObject go)
        {
            try
            {
                // RenderForUI returns a RenderEvent (fields, not the Renderable accessors)
                var r = go.RenderForUI("Inventory");
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
                        GameObject eq = null;
                        try { eq = bp.Equipped; } catch { }
                        if (eq == null) { try { eq = bp.DefaultBehavior; } catch { } }
                        if (eq != null)
                        {
                            try { j.Member("item", eq.DisplayName ?? ""); } catch { }
                            WriteTile(j, eq);
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
                var flat = new List<KeyValuePair<string, string>>();   // sortName -> category
                foreach (var kv in cats)
                    foreach (GameObject go in kv.Value)
                    {
                        string sn = "";
                        try { sn = (go.DisplayNameOnlyStripped ?? "").ToLowerInvariant(); } catch { }
                        flat.Add(new KeyValuePair<string, string>(sn, kv.Key));
                    }
                flat.Sort((a, b) => string.CompareOrdinal(a.Key, b.Key));
                var seen = new List<string>();
                foreach (var kv in flat)
                    if (!seen.Contains(kv.Value)) seen.Add(kv.Value);
                j.Name("filterOrder").BeginArray();
                foreach (string n in seen) j.Value(n);
                j.EndArray();
            }
            catch (Exception e) { System.Console.WriteLine("[raves] filter order: " + e.Message); }

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

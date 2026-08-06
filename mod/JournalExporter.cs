using System;
using System.IO;
using Qud.API;              // IBaseJournalEntry, JournalMapNote, JournalRecipeNote
using XRL.UI;               // JournalScreen

namespace RavesOfQud
{
    /// <summary>
    /// Exports the JOURNAL's seven tabs, mirroring Qud.UI.JournalStatusScreen + JournalLine.setData.
    ///
    /// Entries come from <c>JournalScreen.GetRawEntriesFor(tab)</c> — the same call the screen's
    /// UpdateData uses — and their text from <c>entry.GetDisplayText()</c>. The two prefixes
    /// setData draws are exported as FLAGS rather than baked into the string, so the client can
    /// colour them the way Qud does:
    ///   tradable   "{{G|$}} " when entry.Tradable, "{{K|$}} " when not
    ///   tracked    "[X] " / "[ ] " on a JournalMapNote
    /// A sultan-tomb entry is additionally wrapped in "{{w|[tomb engraving] …}}".
    ///
    /// Recipes are their own shape: setData puts Recipe.GetDisplayName() in the header and builds
    /// the body from GetIngredients() + GetDescription(), so those are exported separately instead
    /// of flattened into one string.
    ///
    /// A VILLAGE note also has a map target, but JournalLineData resolves it through a chain of
    /// per-village zone lookups (Joppa -> the cell holding TerrainJoppa, and so on). Not exported
    /// yet, so the map centres only for map notes.
    ///
    /// CATEGORIES are exported too. currentInfo.CategoryFor is a delegate on the screen's
    /// categoryInfos, but the delegates themselves are PURE FUNCTIONS OF THE ENTRY —
    /// ObservationCategory is entry.LearnedFrom, LocationCategory is a map note's Category,
    /// Sultan/Village are HistoryAPI.GetEntityName of their id — so no screen state is needed and
    /// the earlier "we can't see this from here" was too pessimistic. Only tabs 0-3 group;
    /// Chronology sets UsesCategories=false explicitly.
    /// </summary>
    public static class JournalExporter
    {
        // JournalScreen's tab constants, in the order the screen shows them.
        // internal: PopupBridge measures each of these headers with Qud's own TMP component.
        internal static readonly string[] Tabs =
        {
            "Locations", "Chronology", "Gossip and Lore", "Sultan Histories",
            "Village Histories", "General Notes", "Recipes",
        };

        public static string Path_ => System.IO.Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "journal.json");

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] journal export failed: " + e.Message); }
        }

        public static void Export()
        {
            var j = new JsonWriter();
            j.BeginObject();
            InventoryExporter.WritePalette(j);
            j.Name("tabs").BeginArray();
            foreach (var tab in Tabs)
            {
                j.BeginObject();
                j.Member("id", tab);
                string disp = tab;
                try { disp = JournalScreen.GetTabDisplayName(tab) ?? tab; } catch { }
                j.Member("name", disp);
                // The header's LAID-OUT width, measured by the screen's own TMP component (see
                // PopupBridge.JournalHeaderW). The 1px tick that closes the header block sits at
                // this width plus the icon slot, and Qud's metric is not ours: it measures
                // "Locations" at 143.04 where Source Code Pro's 24px advance gives 129.6. Absent
                // (the Journal tab has not been opened yet this session) it is omitted, and Raves
                // falls back to its own measurement.
                try
                {
                    float hw;
                    if (PopupBridge.JournalHeaderW.TryGetValue(disp, out hw) && hw > 0f)
                        j.Member("hdrW", hw.ToString("0.##",
                            System.Globalization.CultureInfo.InvariantCulture));
                }
                catch { }
                // Only these two tabs show the world map (categoryInfos' UsesMap).
                j.Member("usesMap", tab == "Locations" || tab == "Village Histories");
                // …and only these four GROUP (UsesCategories); Chronology opts out explicitly.
                bool cats = tab == "Locations" || tab == "Gossip and Lore"
                    || tab == "Sultan Histories" || tab == "Village Histories";
                j.Member("usesCategories", cats);
                // SortCategoriesAZ — set on every grouping tab EXCEPT Sultan Histories, which keeps
                // its natural (chronological) order.
                j.Member("sortAZ", cats && tab != "Sultan Histories");
                // Sultans get a different header form: "{{W|HISTORY OF <NAME>}}".
                j.Member("sultanHeaders", tab == "Sultan Histories");
                int n = 0;
                j.Name("entries").BeginArray();
                try
                {
                    foreach (var e in JournalScreen.GetRawEntriesFor(tab))
                    {
                        if (e == null) continue;
                        n++;
                        j.BeginObject();
                        WriteEntry(j, e);
                        if (cats) j.Member("category", CategoryFor(tab, e));
                        j.EndObject();
                    }
                }
                catch (Exception ex)
                {
                    System.Console.WriteLine("[raves] journal tab '" + tab + "': " + ex.Message);
                }
                j.EndArray();
                j.Member("count", n);
                // Qud's own empty-state row text, so Raves doesn't invent its own wording.
                if (n == 0) j.Member("empty", Qud.UI.JournalStatusScreen.NO_ENTRIES_TEXT ?? "No entries found.");
                j.EndObject();
            }
            j.EndArray();
            MapExporter.WritePlayerPos(j);
            j.EndObject();
            File.WriteAllText(Path_, j.ToString());
        }

        /// The screen's own CategoryFor delegates, which are pure functions of the entry.
        private static string CategoryFor(string tab, IBaseJournalEntry e)
        {
            try
            {
                if (tab == "Gossip and Lore")
                    return string.IsNullOrEmpty(e.LearnedFrom) ? "Unknown" : e.LearnedFrom;
                if (tab == "Locations")
                {
                    var mn = e as JournalMapNote;
                    return (mn != null && !string.IsNullOrEmpty(mn.Category)) ? mn.Category : "Unknown";
                }
                if (tab == "Sultan Histories")
                {
                    var sn = e as JournalSultanNote;
                    if (sn == null) return "Unknown";
                    return HistoryAPI.GetEntityName(sn.SultanID) ?? "Unknown";
                }
                if (tab == "Village Histories")
                {
                    var vn = e as JournalVillageNote;
                    if (vn == null) return "Unknown";
                    return HistoryAPI.GetEntityName(vn.VillageID) ?? "Unknown";
                }
            }
            catch { }
            return "Unknown";
        }

        private static void WriteEntry(JsonWriter j, IBaseJournalEntry e)
        {
            try { j.Member("id", e.ID ?? ""); } catch { }
            try { j.Member("text", e.GetDisplayText() ?? ""); } catch { }
            try { j.Member("tradable", e.Tradable); } catch { }
            try { if (!string.IsNullOrEmpty(e.LearnedFrom)) j.Member("from", e.LearnedFrom); } catch { }
            // setData wraps a tomb-propaganda entry in "{{w|[tomb engraving] …}}".
            try { if (e.Has("sultanTombPropaganda")) j.Member("tomb", true); } catch { }

            var map = e as JournalMapNote;
            if (map != null)
            {
                try { j.Member("tracked", map.Tracked); } catch { }
                // JournalLineData.mapTarget for a map note is just its parasang coords; the map
                // panel centres on this when the entry is selected.
                try { j.Member("mx", map.ParasangX).Member("my", map.ParasangY); } catch { }
            }

            var rec = e as JournalRecipeNote;
            if (rec != null)
            {
                try
                {
                    if (rec.Recipe != null)
                    {
                        j.Member("recipe", rec.Recipe.GetDisplayName() ?? "");
                        j.Member("ingredients", rec.Recipe.GetIngredients() ?? "");
                        j.Member("effects", rec.Recipe.GetDescription() ?? "");
                    }
                }
                catch { }
            }
        }
    }
}

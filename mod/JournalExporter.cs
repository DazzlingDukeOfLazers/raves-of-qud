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
    /// NOT MIRRORED YET: the per-tab CATEGORY grouping. Categories come from
    /// currentInfo.CategoryFor(entry), a delegate on the screen's own categoryInfos — screen state
    /// we can't see from here — so entries are exported flat, in Qud's order, per tab. Same call as
    /// the Quests map: the list first, the grouping as its own piece of work.
    /// </summary>
    public static class JournalExporter
    {
        // JournalScreen's tab constants, in the order the screen shows them.
        private static readonly string[] Tabs =
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
                try { j.Member("name", JournalScreen.GetTabDisplayName(tab) ?? tab); }
                catch { j.Member("name", tab); }
                // Only these two tabs show the world map (categoryInfos' UsesMap).
                j.Member("usesMap", tab == "Locations" || tab == "Village Histories");
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

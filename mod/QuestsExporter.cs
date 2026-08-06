using System;
using System.Collections.Generic;
using System.IO;
using ConsoleLib.Console;   // ColorUtility.StripFormatting
using Qud.API;              // QuestsAPI
using XRL.UI;               // QuestLog
using XRL.World;            // Quest

namespace RavesOfQud
{
    /// <summary>
    /// Exports the ACTIVE quest log for Raves' Quests tab, mirroring what
    /// <c>Qud.UI.QuestsStatusScreen.UpdateViewFromData</c> puts on screen.
    ///
    /// The list is Qud's: <c>QuestsAPI.allQuests()</c> filtered to <c>!quest.Finished</c>, in that
    /// order. A quest with no entries is not an empty list — Qud pushes a single placeholder row
    /// reading "You have no active quests.", so that string is a rendering state, not an error.
    ///
    /// The BODY of each quest comes from <c>QuestLog.GetLinesForQuest(q, IncludeTitle:false,
    /// Clip:true, 70)</c> — Qud's own step renderer, at the same clip width QuestsLine.setData uses.
    /// Calling it rather than walking StepsByID ourselves is the point: step ordering, completion
    /// marks and the wording of an optional/failed step are all decisions we would otherwise have to
    /// re-derive and keep in sync with the game.
    /// </summary>
    public static class QuestsExporter
    {
        // QuestsLine.setData: 70 normally, 45 on a Small screen. We export at Qud's default; Raves
        // renders at a fixed width, so the small-screen branch would only add a wrap we don't want.
        private const int ClipWidth = 70;

        public static string Path_ => System.IO.Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "quests.json");

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] quests export failed: " + e.Message); }
        }

        public static void Export()
        {
            var j = new JsonWriter();
            j.BeginObject();
            InventoryExporter.WritePalette(j);

            var quests = new List<Quest>();
            try
            {
                foreach (var q in QuestsAPI.allQuests())
                    if (q != null && !q.Finished) quests.Add(q);
            }
            catch (Exception e) { System.Console.WriteLine("[raves] allQuests failed: " + e.Message); }

            j.Member("count", quests.Count);
            // Qud's own empty-state string, so Raves doesn't invent its own wording.
            if (quests.Count == 0) j.Member("empty", "You have no active quests.");

            j.Name("quests").BeginArray();
            foreach (var q in quests)
            {
                j.BeginObject();
                try
                {
                    j.Member("id", q.ID ?? "");
                    // setData strips the markup off the title before showing it; the giver line is
                    // "<giver> / <location>" with "<unknown>" standing in for either half.
                    j.Member("name", StripSafe(q.DisplayName));
                    j.Member("giver", (q.QuestGiverName ?? "<unknown>") + " / " +
                                      (q.QuestGiverLocationName ?? "<unknown>"));
                    try { j.Member("level", q.Level); } catch { }
                    j.Name("body").BeginArray();
                    try
                    {
                        var lines = QuestLog.GetLinesForQuest(q, IncludeTitle: false, Clip: true, ClipWidth: ClipWidth);
                        if (lines != null)
                            foreach (var line in lines) j.Value(line ?? "");
                    }
                    catch (Exception e) { j.Value("(quest text unavailable: " + e.Message + ")"); }
                    j.EndArray();
                }
                catch { }
                j.EndObject();
            }
            j.EndArray();
            // Quest-giver pins for the map panel, computed the way the screen does.
            MapExporter.WritePins(j);
            j.EndObject();

            File.WriteAllText(Path_, j.ToString());
        }

        private static string StripSafe(string s)
        {
            try { return ColorUtility.StripFormatting(s ?? ""); }
            catch { return s ?? ""; }
        }
    }
}

using System;
using System.Collections.Generic;
using System.IO;
using XRL;                  // The
using XRL.World;            // GameObject, BitLocker, BitType, BitCost, ModifyBitCostEvent
using XRL.World.Parts;      // TinkerItem
using XRL.World.Parts.Skill;// Tinkering (the SKILL, not a plain part)
using XRL.World.Tinkering;  // TinkerData

namespace RavesOfQud
{
    /// <summary>
    /// Exports the TINKERING tab: the known BUILD recipes and the player's BIT LOCKER, mirroring
    /// Qud.UI.TinkeringStatusScreen + TinkeringLine.setData.
    ///
    /// Recipes are <c>TinkerData.KnownRecipes</c> filtered to <c>Type == "Build"</c> — the screen's
    /// own UpdateTinkeringData split — grouped by <c>UICategory</c>, which is what its category rows
    /// use. The cost string is built exactly as TinkeringLineData.cost does for mode 0:
    ///     BitCost.Import(TinkerItem.GetBitCostFor(blueprint)) -> ModifyBitCostEvent.Process(player)
    /// Reproducing that rather than reading the raw <c>Cost</c> field matters: the event is what
    /// applies the player's own cost modifiers, so the raw field is the wrong number for anyone
    /// carrying one.
    ///
    /// Bits come from the player's BitLocker over BitType.BitOrder, with each type's colour and
    /// description — the same source UpdateBitlocker walks.
    ///
    /// NOT MIRRORED YET: the MODIFICATIONS mode (CurrentCategory 1). Its rows are per-ITEM — the
    /// cost depends on the object being modified (its slots used, tech tier) and the list is the
    /// applicable items in your inventory — so it is a genuinely different view, not a filter of
    /// this one. Deferred like the Quests/Journal map panels.
    /// </summary>
    public static class TinkeringExporter
    {
        public static string Path_ => System.IO.Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "tinkering.json");

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] tinkering export failed: " + e.Message); }
        }

        public static void Export()
        {
            var j = new JsonWriter();
            j.BeginObject();
            InventoryExporter.WritePalette(j);

            // ---- known BUILD recipes, grouped by the screen's UICategory
            var byCat = new SortedDictionary<string, List<TinkerData>>(StringComparer.Ordinal);
            int total = 0;
            try
            {
                foreach (var d in TinkerData.KnownRecipes)
                {
                    if (d == null || d.Type != "Build") continue;
                    string cat = "";
                    try { cat = d.UICategory ?? ""; } catch { }
                    if (!byCat.ContainsKey(cat)) byCat[cat] = new List<TinkerData>();
                    byCat[cat].Add(d);
                    total++;
                }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] known recipes: " + e.Message); }

            j.Member("recipeCount", total);
            // setData's own empty-state string for the category row.
            if (total == 0) j.Member("empty", "You don't have any schematics.");
            j.Name("categories").BeginArray();
            foreach (var kv in byCat)
            {
                j.BeginObject().Member("name", kv.Key).Member("count", kv.Value.Count);
                j.Name("items").BeginArray();
                foreach (var d in kv.Value)
                {
                    j.BeginObject();
                    try { j.Member("name", d.DisplayName ?? ""); } catch { }
                    try { j.Member("blueprint", d.Blueprint ?? ""); } catch { }
                    try { j.Member("tier", d.Tier); } catch { }
                    try { j.Member("cost", CostFor(d)); } catch { }
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();

            // ---- the bit locker
            j.Name("bits").BeginArray();
            try
            {
                GameObject player = The.Player;
                BitLocker locker = null;
                if (player != null)
                    locker = (player.GetPart<Tinkering>() == null)
                        ? player.GetPart<BitLocker>() : player.RequirePart<BitLocker>();
                if (locker != null)
                {
                    foreach (char c in BitType.BitOrder)
                    {
                        BitType bt = null;
                        try { bt = BitType.BitMap[c]; } catch { }
                        if (bt == null) continue;
                        j.BeginObject()
                         .Member("bit", c.ToString())
                         .Member("color", bt.Color.ToString())
                         // The LABEL Qud prints ("A scrap power systems"): UpdateBitlocker builds
                         // "{{Color|<char> <Description>}}" where the char is CharTranslateBit under
                         // the AlphanumericBits option. The colour char (R/G/b/c…) is NOT the label.
                         .Member("label", BitType.CharTranslateBit(bt.Color).ToString())
                         .Member("desc", bt.Description ?? "");
                        try { j.Member("count", locker.GetBitCount(c)); } catch { j.Member("count", 0); }
                        j.EndObject();
                    }
                }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] bitlocker: " + e.Message); }
            j.EndArray();

            j.EndObject();
            File.WriteAllText(Path_, j.ToString());
        }

        /// TinkeringLineData.cost, mode 0 — including the player's cost modifiers.
        private static string CostFor(TinkerData d)
        {
            try
            {
                var cost = new BitCost();
                cost.Import(TinkerItem.GetBitCostFor(d.Blueprint));
                ModifyBitCostEvent.Process(The.Player, cost, d.Type);
                return cost.ToString() ?? "";
            }
            catch { return d.Cost ?? ""; }
        }
    }
}

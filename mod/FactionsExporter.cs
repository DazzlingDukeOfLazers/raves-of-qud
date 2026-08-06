using System;
using System.IO;
using ConsoleLib.Console;   // ColorUtility
using XRL.UI;               // FactionsScreen
using XRL.World;            // Factions, Faction, Reputation

namespace RavesOfQud
{
    /// <summary>
    /// Exports the REPUTATION tab's faction list, mirroring
    /// <c>Qud.UI.FactionsStatusScreen.UpdateViewFromData</c> + <c>FactionsLine.setData</c>.
    ///
    /// Every string is Qud's own renderer, not a re-derivation:
    ///   label    ColorUtility.CapitalizeExceptFormatting(faction.GetFormattedName())
    ///   rep      Faction.PlayerReputation.Get(id), formatted by FactionsScreen.FormatFactionReputation
    ///   colour   Reputation.GetColor(rep) -- the indicator's colour CHAR, resolved client-side
    ///   feeling  faction.GetFeelingText()
    ///   rank     GetRankText() + GetPetText() + GetHolyPlaceText(), joined the way setData joins them
    ///   secret   Faction.GetPreferredSecretDescription(id)
    /// Reputation thresholds, rank wording and which secret is "preferred" are all game rules that
    /// would rot the moment Qud tuned them; asking the game keeps them the game's.
    ///
    /// Order is BY NAME -- what the screen shows on open (checked against Qud, not inferred from
    /// UpdateViewFromData's sort branches). Its sort toggle is screen state and is not mirrored.
    /// </summary>
    public static class FactionsExporter
    {
        public static string Path_ => System.IO.Path.Combine(
            Directory.GetParent(TileExporter.Dir).FullName, "factions.json");

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] factions export failed: " + e.Message); }
        }

        public static void Export()
        {
            var j = new JsonWriter();
            j.BeginObject();
            InventoryExporter.WritePalette(j);

            var rows = new System.Collections.Generic.List<Faction>();
            try
            {
                foreach (string nm in FactionsScreen.getFactionsByName())
                {
                    Faction f = null;
                    try { f = Factions.Get(nm); } catch { }
                    if (f != null && f.Visible) rows.Add(f);
                }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] faction list failed: " + e.Message); }

            // ORDER: as getFactionsByName() gives it, i.e. BY NAME. FactionsStatusScreen can sort
            // three ways (rep desc / rep asc / name) and its live SortMode is screen state we don't
            // see from here -- but name is what the screen actually shows on open, verified against
            // Qud side by side. Sorting by reputation here looked reasonable from the code and was
            // simply wrong on screen. The sort TOGGLE is not mirrored.

            j.Member("count", rows.Count);
            j.Name("factions").BeginArray();
            foreach (var f in rows)
            {
                j.BeginObject();
                try
                {
                    int rep = Rep(f.Name);
                    j.Member("id", f.Name ?? "");
                    try { j.Member("name", f.DisplayName ?? ""); } catch { }
                    try { j.Member("label", ColorUtility.CapitalizeExceptFormatting(f.GetFormattedName())); } catch { }
                    j.Member("rep", rep);
                    try { j.Member("repText", FactionsScreen.FormatFactionReputation(f.Name) ?? ""); } catch { }
                    // The indicator's colour is a Qud colour CHAR; the client resolves it through the
                    // same palette as everything else rather than us baking an RGB here.
                    try { j.Member("repColor", Reputation.GetColor(rep).ToString()); } catch { }
                    try { j.Member("feeling", f.GetFeelingText() ?? ""); } catch { }
                    try { j.Member("rank", RankText(f)); } catch { }
                    try { j.Member("secret", Faction.GetPreferredSecretDescription(f.Name) ?? ""); } catch { }
                    WriteEmblem(j, f);
                }
                catch { }
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();
            File.WriteAllText(Path_, j.ToString());
        }

        private static int Rep(string id)
        {
            try { return Faction.PlayerReputation.Get(id); } catch { return 0; }
        }

        /// setData's join: rank, then pet, then holy place — each appended only when non-empty.
        private static string RankText(Faction f)
        {
            string s = "";
            try { s = f.GetRankText() ?? ""; } catch { }
            try
            {
                string pet = f.GetPetText() ?? "";
                s = string.IsNullOrEmpty(s) ? pet : (string.IsNullOrEmpty(pet) ? s : s + " " + pet);
            }
            catch { }
            try
            {
                string holy = f.GetHolyPlaceText() ?? "";
                s = string.IsNullOrEmpty(s) ? holy : (string.IsNullOrEmpty(holy) ? s : s + " " + holy);
            }
            catch { }
            return s;
        }

        /// The faction EMBLEM is an IRenderable, not a GameObject, so it can't go through
        /// InventoryExporter.WriteTile — pull its tile + colours straight off the renderable.
        private static void WriteEmblem(JsonWriter j, Faction f)
        {
            try
            {
                var r = f.Emblem;
                if (r == null) return;
                // IRenderable exposes GETTERS, not properties, and getDetailColor() returns a CHAR.
                string tile = r.getTile();
                if (string.IsNullOrEmpty(tile)) return;
                TileExporter.Ensure(tile);
                j.Member("tile", tile)
                 .Member("color", r.getColorString() ?? "")
                 .Member("tilecolor", r.getTileColor() ?? "")
                 .Member("detail", r.getDetailColor().ToString());
            }
            catch { }
        }
    }
}

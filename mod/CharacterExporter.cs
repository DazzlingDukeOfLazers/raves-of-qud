using System;
using System.IO;
using System.Text;
using XRL.World;
using XRL.World.Parts;

namespace RavesOfQud
{
    /// <summary>
    /// Export the player's CHARACTER SHEET data — attributes, resistances, points and
    /// the full mutation list with per-rank text — to <c>character.json</c> in the
    /// RavesOfQud support dir, for the status screens' Attributes &amp; Powers tab.
    ///
    /// Live data (stats change every level/effect), so there is no one-shot guard:
    /// the bridge "export" command re-runs it (Raves' screen requests one on open),
    /// and the connect block seeds a first copy when a game is live. Data-only reads
    /// of the player object (no Unity calls) — same class of access as ZoneSnapshot.
    /// </summary>
    public static class CharacterExporter
    {
        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] character export failed: " + e.Message); }
        }

        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        private static int Stat(GameObject p, string name)
        {
            try { return p.Stat(name); } catch { return 0; }
        }

        /// Qud's DISPLAY value (MoveSpeed shows as 200-value, etc.) — mirrors Statistic.GetDisplayValue.
        private static string DisplayStat(GameObject p, string name)
        {
            try
            {
                var st = p.Statistics != null && p.Statistics.ContainsKey(name) ? p.Statistics[name] : null;
                if (st != null) return st.GetDisplayValue();
            }
            catch { }
            return Stat(p, name).ToString();
        }

        private static XRL.World.Statistic StatObj(GameObject p, string name)
        {
            try { return p.Statistics != null && p.Statistics.ContainsKey(name) ? p.Statistics[name] : null; }
            catch { return null; }
        }

        /// Qud's exact value-colour rule (CharacterAttributeLine.setData): C default,
        /// G above base, lowercase r below — MS inverts (lower is better).
        private static string CodeFor(XRL.World.Statistic st, bool inverse)
        {
            if (st == null) return "C";
            if (!inverse)
            {
                if (st.Value > st.BaseValue) return "G";
                if (st.Value < st.BaseValue) return "r";
            }
            else
            {
                if (st.Value < st.BaseValue) return "G";
                if (st.Value > st.BaseValue) return "r";
            }
            return "C";
        }

        private static void StatBox(JsonWriter j, string key, int shown, string code, XRL.World.Statistic st, bool withMod)
        {
            j.Name(key).BeginObject();
            j.Member("v", shown).Member("c", code);
            if (withMod && st != null) j.Member("m", st.Modifier);
            j.EndObject();
        }

        private static string Help(GameObject p, string name)
        {
            try
            {
                var st = p.Statistics != null && p.Statistics.ContainsKey(name) ? p.Statistics[name] : null;
                if (st != null) return st.GetHelpText() ?? "";
            }
            catch { }
            return "";
        }

        private static void Export()
        {
            GameObject p = null;
            try { p = XRL.The.Player; } catch { }
            if (p == null) return;   // menu / mid-transition — nothing to export

            var j = new JsonWriter();
            j.BeginObject();
            try { j.Member("name", p.DisplayNameOnlyStripped ?? ""); } catch { }
            // "Mutated Human Tinker" — genotype + subtype, as the sheet's subtitle
            string geno = "", sub = "";
            try { geno = p.GetGenotype() ?? ""; } catch { }
            try { sub = p.GetStringProperty("Subtype") ?? ""; } catch { }
            j.Member("title", (geno + " " + sub).Trim());
            // the portrait tile, self-contained (no snapshot dependency): path + detail
            // colour code; TileExporter queues the art if it isn't on disk yet
            try
            {
                var r = p.GetPart<XRL.World.Parts.Render>();
                if (r != null)
                {
                    string tile = r.Tile ?? "";
                    if (tile.Length > 0) TileExporter.Ensure(tile);
                    j.Member("tile", tile).Member("detail", r.DetailColor ?? "");
                }
            }
            catch { }
            j.Member("level", Stat(p, "Level"));
            try { j.Member("hp", p.hitpoints).Member("hpMax", p.baseHitpoints); } catch { }
            j.Member("xp", Stat(p, "XP"));
            try { j.Member("xpNext", Leveler.GetXPForLevel(Stat(p, "Level") + 1)); } catch { }
            try { j.Member("weight", p.Weight); } catch { }   // the sheet shows TOTAL object weight, not carried
            j.Member("ap", Stat(p, "AP"));
            j.Member("mp", Stat(p, "MP"));

            // Per-box data mirroring CharacterAttributeLine.setData verbatim: the shown
            // number (combat values for AV/DV/MA, 200-Value for MS), Qud's colour CODE
            // (palette-resolved client-side), and Statistic.Modifier for the mains.
            j.Name("stats").BeginObject();
            var names = new[] { "Strength", "Agility", "Toughness", "Intelligence", "Willpower", "Ego" };
            var keys = new[] { "STR", "AGI", "TOU", "INT", "WIL", "EGO" };
            for (int i = 0; i < names.Length; i++)
            {
                var st = StatObj(p, names[i]);
                StatBox(j, keys[i], st != null ? st.Value : Stat(p, names[i]), CodeFor(st, false), st, true);
            }
            var qn = StatObj(p, "Speed");
            StatBox(j, "QN", qn != null ? qn.Value : 0, CodeFor(qn, false), qn, false);
            var ms = StatObj(p, "MoveSpeed");
            StatBox(j, "MS", ms != null ? 200 - ms.Value : 0, CodeFor(ms, true), ms, false);
            int av = 0, dv = 0, ma = 0;
            try { av = XRL.Rules.Stats.GetCombatAV(p); } catch { }
            try { dv = XRL.Rules.Stats.GetCombatDV(p); } catch { }
            try { ma = XRL.Rules.Stats.GetCombatMA(p); } catch { }
            StatBox(j, "AV", av, CodeFor(StatObj(p, "AV"), false), null, false);
            StatBox(j, "DV", dv, CodeFor(StatObj(p, "DV"), false), null, false);
            StatBox(j, "MA", ma, CodeFor(StatObj(p, "MA"), false), null, false);
            var rn = new[] { "AcidResistance", "ElectricResistance", "ColdResistance", "HeatResistance" };
            var rk = new[] { "AR", "ER", "CR", "HR" };
            for (int i = 0; i < rn.Length; i++)
            {
                var st = StatObj(p, rn[i]);
                StatBox(j, rk[i], st != null ? st.Value : 0, CodeFor(st, false), st, false);
            }
            j.EndObject();

            j.Name("help").BeginObject();
            j.Member("STR", Help(p, "Strength")).Member("AGI", Help(p, "Agility"))
             .Member("TOU", Help(p, "Toughness")).Member("INT", Help(p, "Intelligence"))
             .Member("WIL", Help(p, "Willpower")).Member("EGO", Help(p, "Ego"))
             .Member("QN", Help(p, "Speed")).Member("MS", Help(p, "MoveSpeed"))
             .Member("AV", Help(p, "AV")).Member("DV", Help(p, "DV")).Member("MA", Help(p, "MA"))
             .Member("AR", Help(p, "AcidResistance")).Member("ER", Help(p, "ElectricResistance"))
             .Member("CR", Help(p, "ColdResistance")).Member("HR", Help(p, "HeatResistance"));
            j.EndObject();

            j.Name("mutations").BeginArray();
            try
            {
                var muts = p.GetPart<Mutations>();
                if (muts != null && muts.MutationList != null)
                {
                    foreach (var m in muts.MutationList)
                    {
                        if (m == null) continue;
                        j.BeginObject();
                        try { j.Member("name", m.GetDisplayName(false) ?? ""); } catch { }
                        try { j.Member("display", m.GetDisplayName(true) ?? ""); } catch { }   // Qud's own list text, annotations included
                        j.Member("level", m.Level);
                        try { j.Member("uiLevel", m.GetUIDisplayLevel()); } catch { }
                        try { j.Member("maxLevel", m.GetMaxLevel()); } catch { }
                        try { j.Member("defect", m.IsDefect()); } catch { }
                        try { j.Member("showLevel", m.ShouldShowLevel()); } catch { }   // Qud's own (n)-suffix rule
                        try { j.Member("type", m.GetMutationType() ?? ""); } catch { }
                        try { j.Member("desc", m.GetDescription() ?? ""); } catch { }
                        try { j.Member("levelText", m.GetLevelText(m.Level) ?? ""); } catch { }
                        try { if (m.Level < m.GetMaxLevel()) j.Member("nextText", m.GetLevelText(m.Level + 1) ?? ""); } catch { }
                        j.EndObject();
                    }
                }
            }
            catch { }
            j.EndArray();
            j.EndObject();

            Directory.CreateDirectory(Root);
            File.WriteAllText(Path.Combine(Root, "character.json"), j.ToString(), new UTF8Encoding(false));   // NO BOM — Godot's JSON.parse_string rejects it
        }
    }
}

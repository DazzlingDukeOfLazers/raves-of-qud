using System;
using System.IO;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Export Qud's CHARACTER-CREATION data — the options each chargen stage presents — to
    /// <c>chargen.json</c> in the RavesOfQud support dir, so Raves can build a faithful, interactive
    /// character creator (see docs / the raves-chargen plan). Read from the player's own install
    /// (base + mods), never redistributed.
    ///
    /// Vertical-slice order: GENOTYPE first (Mutated Human / True Kin), then subtypes, attributes,
    /// mutations, cybernetics, game modes as each screen is built.
    ///
    /// Data-only: reads Qud's static registries (<see cref="XRL.GenotypeFactory"/>, lazy-loaded from
    /// XML — no Unity calls), so it's safe on the turn thread like the other exporters. Chargen data
    /// doesn't change at runtime, so a one-shot per session is plenty; the bridge "export" command
    /// re-runs it on demand. (Tile art is queued through TileExporter, same as everywhere else.)
    /// </summary>
    public static class ChargenExporter
    {
        private static int _tried;

        /// <summary>Re-run on demand (bridge "export" command), bypassing the one-shot guard.</summary>
        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] chargen re-export failed: " + e.Message); }
        }

        /// <summary>Turn-thread safe: export the chargen data once per session.</summary>
        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            try
            {
                Export();
                System.Console.WriteLine("[raves] chargen exported -> " + Path.Combine(Root, "chargen.json"));
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] chargen export failed: " + e.Message);
                _tried = 0;   // let a later turn retry
            }
        }

        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string root = Path.Combine(home, "Library", "Application Support", "RavesOfQud");
                Directory.CreateDirectory(root);
                return root;
            }
        }

        private static void Export()
        {
            var j = new JsonWriter();
            j.BeginObject();
            WriteGenotypes(j);
            j.EndObject();
            File.WriteAllText(Path.Combine(Root, "chargen.json"), j.ToString());
        }

        /// The genotypes (Mutated Human / True Kin, + any mod additions), from the loaded registry so
        /// this reflects what Qud's own chargen would offer — not a re-parse of the base XML.
        private static void WriteGenotypes(JsonWriter j)
        {
            j.Name("genotypes").BeginArray();
            foreach (var g in XRL.GenotypeFactory.Genotypes)
            {
                if (g == null) continue;
                string name = SafeStr("name", () => g.Name, "?");
                string tile = SafeStr("tile", () => g.Tile, null);
                if (!string.IsNullOrEmpty(tile)) { try { TileExporter.Ensure(tile); } catch { } }
                j.BeginObject();
                j.Member("name", name);
                j.Member("display", SafeStr("display", () => g.DisplayName, name));
                j.Member("tile", tile);
                j.Member("detail", SafeStr("detail", () => g.DetailColor, null));
                j.Member("statPoints", SafeInt(() => g.StatPoints));
                j.Member("mutationPoints", SafeInt(() => g.MutationPoints));
                j.Member("cyberLicensePoints", SafeInt(() => g.CyberneticsLicensePoints));
                j.Member("subtypes", SafeStr("subtypes", () => g.Subtypes, null));   // "Callings" / "Castes"
                j.Member("isMutant", SafeBool(() => g.IsMutant));
                j.Member("isTrueKin", SafeBool(() => g.IsTrueKin));
                j.Member("supportsMutations", SafeBool(() => g.supportsMutations));
                j.Member("supportsCybernetics", SafeBool(() => g.supportsCybernetics));
                // per-attribute min/max + chargen description (the 6 stats)
                j.Name("stats").BeginArray();
                try
                {
                    foreach (var kv in g.Stats)
                    {
                        var s = kv.Value;
                        if (s == null) continue;
                        j.BeginObject()
                            .Member("name", s.Name)
                            .Member("min", s.Minimum)
                            .Member("max", s.Maximum)
                            .Member("bonus", s.Bonus)
                            .Member("desc", s.ChargenDescription ?? "")
                        .EndObject();
                    }
                }
                catch (Exception e) { System.Console.WriteLine("[raves] chargen stats: " + e.Message); }
                j.EndArray();
                // the perk bullets Qud shows for the genotype ("Mutations", "High starting attributes", …)
                j.Name("extraInfo").BeginArray();
                try { foreach (var x in g.ExtraInfo) j.Value(x ?? ""); }
                catch (Exception e) { System.Console.WriteLine("[raves] chargen extrainfo: " + e.Message); }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
        }

        private static string SafeStr(string tag, Func<string> f, string fallback)
        {
            try { string s = f(); return string.IsNullOrEmpty(s) ? fallback : s; }
            catch (Exception e) { System.Console.WriteLine("[raves] chargen field '" + tag + "': " + e.Message); return fallback; }
        }
        private static int SafeInt(Func<int> f) { try { return f(); } catch { return 0; } }
        private static bool SafeBool(Func<bool> f) { try { return f(); } catch { return false; } }
    }
}

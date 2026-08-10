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
            WriteSubtypes(j);
            WriteGameModes(j);
            WriteCharTypes(j);
            j.EndObject();
            // Write ATOMICALLY: WriteAllText truncates-then-writes, so a Raves chargen screen reading the
            // file mid-write catches it empty ("No chargen data yet"). Write a temp then atomically swap
            // it in, so readers only ever see the complete previous or new file.
            var path = Path.Combine(Root, "chargen.json");
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, j.ToString());
            try
            {
                if (File.Exists(path)) File.Replace(tmp, path, null);   // atomic swap (dest exists)
                else File.Move(tmp, path);                              // first run: dest doesn't exist
            }
            catch
            {
                // Rare fallback (fs without Replace): last resort, non-atomic.
                File.Copy(tmp, path, true);
                try { File.Delete(tmp); } catch { }
            }
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

        /// The subtypes, grouped exactly as Qud's chargen groups them: class (Castes for True Kin /
        /// Callings for Mutated Human) → category (arcology / region) → subtype. Each subtype carries
        /// its stat bonuses + Qud's OWN ready-made chargen bullets (GetChargenInfo — formatted stat/
        /// save/skill lines), so the screen shows what Qud shows. The genotype's `subtypes` field
        /// ("Castes"/"Callings") selects which class the screen displays.
        private static void WriteSubtypes(JsonWriter j)
        {
            j.Name("subtypeClasses").BeginArray();
            System.Collections.Generic.List<XRL.SubtypeClass> classes;
            try { classes = XRL.SubtypeFactory.Classes; }
            catch (Exception e) { System.Console.WriteLine("[raves] chargen subtypes: " + e.Message); j.EndArray(); return; }
            foreach (var cls in classes)
            {
                if (cls == null) continue;
                j.BeginObject();
                j.Member("id", SafeStr("subtypeClass.id", () => cls.ID, "?"));                 // "Castes" / "Callings"
                j.Member("chargenTitle", SafeStr("subtypeClass.title", () => cls.ChargenTitle, null));  // "choose caste"
                j.Member("singular", SafeStr("subtypeClass.singular", () => cls.SingluarTitle, null));   // "caste" (Qud spells it SingluarTitle)
                j.Member("statBox", SafeBool(() => cls.StatBoxDisplay == "true"));
                j.Name("categories").BeginArray();
                foreach (var cat in cls.Categories)
                {
                    if (cat == null) continue;
                    j.BeginObject();
                    j.Member("name", SafeStr("category.name", () => cat.Name, ""));
                    j.Member("display", SafeStr("category.display", () => cat.DisplayName, cat.Name));   // Qud markup
                    j.Name("subtypes").BeginArray();
                    foreach (var s in cat.Subtypes)
                    {
                        if (s == null) continue;
                        string name = SafeStr("subtype.name", () => s.Name, "?");
                        string tile = SafeStr("subtype.tile", () => s.Tile, null);
                        if (!string.IsNullOrEmpty(tile)) { try { TileExporter.Ensure(tile); } catch { } }
                        j.BeginObject();
                        j.Member("name", name);
                        j.Member("display", SafeStr("subtype.display", () => s.DisplayName, name));
                        j.Member("tile", tile);
                        j.Member("detail", SafeStr("subtype.detail", () => s.DetailColor, null));
                        j.Member("cyberLicensePoints", SafeInt(() => s.CyberneticsLicensePoints));
                        // structured stat bonuses (for a stat box)
                        j.Name("statBonuses").BeginArray();
                        try
                        {
                            foreach (var kv in s.Stats)
                                if (kv.Value != null && kv.Value.Bonus != 0)
                                    j.BeginObject().Member("name", kv.Value.Name).Member("bonus", kv.Value.Bonus).EndObject();
                        }
                        catch (Exception e) { System.Console.WriteLine("[raves] chargen subtype stats: " + e.Message); }
                        j.EndArray();
                        // Qud's OWN ready-made chargen bullets (formatted stat/save/skill lines)
                        j.Name("info").BeginArray();
                        try { foreach (var line in s.GetChargenInfo()) j.Value(line ?? ""); }
                        catch (Exception e) { System.Console.WriteLine("[raves] chargen subtype info: " + e.Message); }
                        j.EndArray();
                        j.EndObject();
                    }
                    j.EndArray();
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
        }

        /// The chargen GAME MODES (Qud's ":choose game mode:" step), mirroring EmbarkModules.xml →
        /// QudGamemodeModule: id/title/description + each card's icon tile (an &lt;icon Tile="…"&gt; child)
        /// and its foreground/detail colour codes. The icon PNGs are queued through TileExporter, exactly
        /// like the genotype/subtype art, so Raves' Game Mode screen can show Qud's own sprites. Static
        /// mirror (the module's GameModes dict only populates inside a live chargen builder), kept in
        /// sync with that file; `hotkey` is the per-card letter Qud assigns in order.
        private static void WriteGameModes(JsonWriter j)
        {
            var modes = new[]
            {
                new[] { "Tutorial", "Tutorial", "A", "Items/sw_square_cap.bmp",   "K", "W", "Learn the basics of Caves of Qud." },
                new[] { "Classic",  "Classic",  "B", "UI/sw_classic_mode.bmp",    "y", "K", "Permadeath: lose your character when you die." },
                new[] { "Roleplay", "Roleplay", "C", "UI/sw_roleplay_mode.bmp",   "b", "B", "Checkpointing at settlements." },
                new[] { "Wander",   "Wander",   "D", "UI/sw_wander_mode.bmp",     "g", "C", "{{c|ù}} Most creatures begin neutral to you.\n{{c|ù}} No XP for killing.\n{{c|ù}} More XP for discoveries and performing the water ritual.\n{{c|ù}} Checkpointing at settlements." },
                new[] { "Daily",    "Daily",    "E", "Items/sw_clockthing.bmp",   "w", "W", "{{c|ù}} One chance with a fixed character and world seed." },
            };
            j.Name("gameModes").BeginArray();
            foreach (var m in modes)
            {
                string tile = m[3];
                if (!string.IsNullOrEmpty(tile)) { try { TileExporter.Ensure(tile); } catch { } }
                j.BeginObject()
                    .Member("name", m[0])
                    .Member("display", m[1])
                    .Member("hotkey", m[2])
                    .Member("tile", tile)
                    .Member("fg", m[4])
                    .Member("detail", m[5])
                    .Member("desc", m[6])
                .EndObject();
            }
            j.EndArray();
        }

        /// The chargen CHARACTER TYPES (Qud's ":choose character type:" step, between game mode and
        /// genotype), mirroring EmbarkModules.xml → QudChartypeModule's &lt;types&gt; block: Presets /
        /// New / Random / Library / Last, each with its card icon + fg/detail colour codes. Static
        /// mirror for the same reason WriteGameModes is (the module's GameTypes dict only populates
        /// inside a live chargen builder); `name` is the module's ID — the string selectType() takes —
        /// and `display` its on-card Title, which differ for Pregen/Presets.
        private static void WriteCharTypes(JsonWriter j)
        {
            var types = new[]
            {
                new[] { "Pregen",  "Presets", "A", "UI/sw_preset.bmp",        "W", "w", "Pick from several preset characters. Once you get comfortable, you can customize them." },
                new[] { "New",     "New",     "B", "UI/sw_newchar.bmp",       "W", "w", "Create a new character." },
                new[] { "Random",  "Random",  "C", "UI/sw_random.bmp",        "w", "W", "Roll a random character." },
                new[] { "Library", "Library", "D", "Items/sw_bookshelf1.bmp", "w", "W", "Choose a character from your build library." },
                new[] { "Last",    "Last",    "E", "UI/sw_lastchar.bmp",      "W", "w", "Replay the last character you played." },
            };
            j.Name("charTypes").BeginArray();
            foreach (var t in types)
            {
                string tile = t[3];
                if (!string.IsNullOrEmpty(tile)) { try { TileExporter.Ensure(tile); } catch { } }
                j.BeginObject()
                    .Member("name", t[0])
                    .Member("display", t[1])
                    .Member("hotkey", t[2])
                    .Member("tile", tile)
                    .Member("fg", t[4])
                    .Member("detail", t[5])
                    .Member("desc", t[6])
                .EndObject();
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

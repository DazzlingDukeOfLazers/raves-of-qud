using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Export Qud's OBJECT BLUEPRINT hierarchy — the same data its Modding Toolkit "Blueprint
    /// Browser" shows — to <c>blueprints.json</c> in the RavesOfQud support dir, so Raves can
    /// render the browser from the player's own install (mods included) instead of a bundled copy.
    ///
    /// The tree is <c>GameObjectFactory.Factory.Blueprints</c>: a flat name→blueprint map where
    /// <c>Inherits</c> names the parent. We emit the FLAT list (name, inherits, plus the handful of
    /// fields the browser displays) and let the client build the tree — the client already needs an
    /// index by name for the filter box, and a flat file diffs sanely between Qud versions.
    ///
    /// Blueprint COUNT is large (~10k on a stock install), so the payload is deliberately thin:
    /// no parts/stats dumps, just what a browser row needs. Deep per-blueprint detail is a later
    /// leaf — and should be an on-demand query, not this bulk file.
    ///
    /// Data-only: reads the factory dictionary (populated at startup, stable after) and writes a
    /// file — no Unity calls — so it is TURN-THREAD SAFE, like <see cref="ModsExporter"/> and
    /// unlike <see cref="TitleExporter"/>.
    /// </summary>
    public static class BlueprintExporter
    {
        private static int _tried;

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

        /// <summary>Re-run on demand (the bridge "export" command), bypassing the one-shot guard.</summary>
        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] blueprint re-export failed: " + e.Message); }
        }

        /// <summary>Turn-thread safe: export once per session.</summary>
        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            try { Export(); }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] blueprint export failed: " + e.Message);
                _tried = 0;   // let a later turn retry
            }
        }

        private static void Export()
        {
            var factory = XRL.World.GameObjectFactory.Factory;
            if (factory == null || factory.Blueprints == null)
            {
                System.Console.WriteLine("[raves] blueprints: factory not loaded yet");
                return;
            }

            // Which names are somebody's parent — the client draws an expander only for those.
            // Computed here (one pass over a dictionary we already hold) rather than trusting
            // GameObjectBlueprint.hasChildren, which is an internal cache flag.
            var parents = new HashSet<string>();
            foreach (var kv in factory.Blueprints)
            {
                string inh = kv.Value != null ? kv.Value.Inherits : null;
                if (!string.IsNullOrEmpty(inh)) parents.Add(inh);
            }

            var j = new JsonWriter();
            j.BeginObject();
            j.Member("count", factory.Blueprints.Count);
            j.Name("blueprints").BeginArray();
            int n = 0;
            foreach (var kv in factory.Blueprints)
            {
                var bp = kv.Value;
                if (bp == null || string.IsNullOrEmpty(bp.Name)) continue;
                j.BeginObject();
                j.Member("name", bp.Name);
                // "" (not null) for a root, so the client can group roots without a null check
                j.Member("inherits", bp.Inherits ?? "");
                j.Member("parent", parents.Contains(bp.Name));
                // The browser row shows the blueprint NAME; display name + tile are what make a
                // row identifiable at a glance. Each is guarded: a malformed blueprint must not
                // abort the whole export mid-object (that would truncate the JSON).
                j.Member("display", Safe(() => bp.CachedDisplayNameStripped, ""));
                j.Member("tile", Safe(() => GetTag(bp, "Tile"), ""));
                j.Member("render", Safe(() => GetTag(bp, "RenderString"), ""));
                j.Member("colors", Safe(() => GetTag(bp, "ColorString"), ""));
                // The RECOLOUR pair. A Qud tile is a 2-colour mask (black -> TileColor,
                // white -> DetailColor), so ColorString alone cannot render one — it carries
                // the &FG^BG text colour, a different thing. QudTiles.texture() wants these two.
                j.Member("tilecolor", Safe(() => GetTag(bp, "TileColor"), ""));
                j.Member("detail", Safe(() => GetTag(bp, "DetailColor"), ""));
                EndTiers(j, bp);
                j.EndObject();
                n++;
            }
            j.EndArray();
            j.EndObject();

            string dest = Path.Combine(Root, "blueprints.json");
            File.WriteAllText(dest, j.ToString());
            System.Console.WriteLine("[raves] blueprints exported: " + n + " -> " + dest);
        }

        /// Tier/TechTier are int properties that can throw on a half-built blueprint; keep them
        /// in one guarded helper so a throw costs two fields, not the row.
        private static void EndTiers(JsonWriter j, XRL.World.GameObjectBlueprint bp)
        {
            int tier = 0, tech = 0;
            try { tier = bp.Tier; tech = bp.TechTier; }
            catch { }
            j.Member("tier", tier);
            j.Member("techtier", tech);
        }

        /// A blueprint's render field by key, "" when absent. Qud stores these as PARAMETERS on the
        /// Render part (Parts["Render"] is a GamePartBlueprint, not a plain dictionary — read them
        /// with GetParameterString), with Tags as the fallback home.
        ///
        /// NB these are the blueprint's STATIC values. Runtime art can differ (PickRandomTile and
        /// friends resolve at spawn) — the same accessors-not-fields rule the snapshot path follows;
        /// a browser row showing the authored value is correct, a WORLD tile would not be.
        private static string GetTag(XRL.World.GameObjectBlueprint bp, string key)
        {
            try
            {
                if (bp.Parts != null && bp.Parts.TryGetValue("Render", out var render) && render != null)
                {
                    string v = render.GetParameterString(key);
                    if (!string.IsNullOrEmpty(v)) return v;
                }
            }
            catch { }
            try
            {
                if (bp.Tags != null && bp.Tags.TryGetValue(key, out string t) && t != null)
                    return t;
            }
            catch { }
            return "";
        }

        private static string Safe(Func<string> f, string fallback)
        {
            try { string v = f(); return v ?? fallback; }
            catch { return fallback; }
        }
    }
}

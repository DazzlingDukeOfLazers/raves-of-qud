using System;
using System.IO;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Export the player's installed-mod list — Qud's OWN <see cref="XRL.ModManager.ModMap"/> —
    /// to <c>mods.json</c> in the RavesOfQud support dir, so Raves' Mods screen shows exactly what
    /// Qud shows (title / author / version / size / tags / enabled / source / preview), read from
    /// the player's install and never redistributed. Same install-extraction idea as the title art.
    ///
    /// Data-only: it reads ModMap (populated at startup, stable after) and writes a file — no Unity
    /// calls — so it runs safely on the turn thread, unlike <see cref="TitleExporter"/>. One-shot
    /// per session; refreshes next launch if the mod set changes.
    /// </summary>
    public static class ModsExporter
    {
        private static int _tried;

        /// <summary>Turn-thread safe: export the mod list once per session.</summary>
        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            try
            {
                Export();
                System.Console.WriteLine("[raves] mods exported -> " + Path.Combine(Root, "mods.json"));
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] mods export failed: " + e.Message);
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
            j.BeginObject().Name("mods").BeginArray();
            foreach (var kv in XRL.ModManager.ModMap)
            {
                XRL.ModInfo m = kv.Value;
                if (m == null) continue;

                // Gather every field DEFENSIVELY *before* writing, so a broken mod can't throw
                // mid-object and corrupt the JSON (unbalanced braces) or fail the whole export.
                // Culprits seen in the wild: DisplayTitleStripped -> StripFormatting on a null
                // title/ID, and IsEnabled with no ModSettings entry. Worst case: skip that mod.
                string id, title, author, version, description, size, source, path, preview;
                bool enabled, scripting;
                string[] tags;
                try
                {
                    XRL.ModManifest man = m.Manifest;
                    id = m.ID;
                    title = SafeStr(() => m.DisplayTitleStripped, string.IsNullOrEmpty(id) ? "(unknown mod)" : id);
                    author = man != null ? man.Author : null;
                    version = man != null && man.Version != null ? man.Version.ToString() : null;
                    description = man != null ? man.Description : null;
                    tags = man != null ? man.Tags : null;
                    size = HumanSize(m.Size);
                    enabled = SafeBool(() => m.IsEnabled, true);
                    scripting = SafeBool(() => m.IsScripting, false);
                    source = m.Source.ToString();
                    path = m.Path ?? (m.Directory != null ? m.Directory.FullName : null);
                    preview = SafePreview(m, man);
                }
                catch (Exception e)
                {
                    System.Console.WriteLine("[raves] mods export skipped a mod: " + e.Message);
                    continue;   // nothing written yet -> JSON stays balanced
                }

                j.BeginObject();
                j.Member("id", id);
                j.Member("title", title);
                j.Member("author", author);
                j.Member("version", version);
                j.Member("description", description);
                j.Name("tags").BeginArray();
                if (tags != null)
                    foreach (string t in tags) j.Value(t ?? "");
                j.EndArray();
                j.Member("size", size);
                j.Member("enabled", enabled);
                j.Member("scripting", scripting);
                j.Member("source", source);
                j.Member("path", path);
                j.Member("preview", preview);
                j.EndObject();
            }
            j.EndArray().EndObject();
            File.WriteAllText(Path.Combine(Root, "mods.json"), j.ToString());
        }

        private static string SafeStr(Func<string> f, string fallback)
        {
            try { string s = f(); return string.IsNullOrEmpty(s) ? fallback : s; }
            catch { return fallback; }
        }

        private static bool SafeBool(Func<bool> f, bool fallback)
        {
            try { return f(); }
            catch { return fallback; }
        }

        private static string SafePreview(XRL.ModInfo m, XRL.ModManifest man)
        {
            try
            {
                if (man != null && !string.IsNullOrEmpty(man.PreviewImage) && m.Directory != null)
                {
                    string p = Path.Combine(m.Directory.FullName, man.PreviewImage);
                    if (File.Exists(p)) return p;   // Raves loads the PNG straight from the install
                }
            }
            catch { }
            return null;
        }

        private static string HumanSize(long b)
        {
            if (b < 1024) return b + " B";
            if (b < 1024L * 1024L) return (b / 1024L) + " KB";
            return ((double)b / 1024.0 / 1024.0).ToString("0.0") + " MB";
        }
    }
}

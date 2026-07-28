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

                // EACH field is read through a self-guarding helper, so no single field can throw
                // (which mid-object would corrupt the JSON) or drop the mod — the worst case is one
                // field falling back, and the tagged log names the culprit. (Seen: some ModInfo
                // property NREs before ModSettings is fully populated on a fresh session.)
                string id = SafeStr("id", () => m.ID, "?");
                j.BeginObject();
                j.Member("id", id);
                j.Member("title", SafeStr("title", () => m.DisplayTitleStripped, id));
                j.Member("author", SafeStr("author", () => m.Manifest != null ? m.Manifest.Author : null, null));
                j.Member("version", SafeStr("version",
                    () => m.Manifest != null && m.Manifest.Version != null ? m.Manifest.Version.ToString() : null, null));
                j.Member("description", SafeStr("description", () => m.Manifest != null ? m.Manifest.Description : null, null));
                j.Name("tags").BeginArray();
                string[] tags = SafeArr("tags", () => m.Manifest != null ? m.Manifest.Tags : null);
                if (tags != null)
                    foreach (string t in tags) j.Value(t ?? "");
                j.EndArray();
                j.Member("size", SafeStr("size", () => HumanSize(m.Size), "?"));
                j.Member("enabled", SafeBool("enabled", () => m.IsEnabled, true));
                j.Member("scripting", SafeBool("scripting", () => m.IsScripting, false));
                j.Member("source", SafeStr("source", () => m.Source.ToString(), "?"));
                j.Member("path", SafeStr("path", () => m.Path ?? (m.Directory != null ? m.Directory.FullName : null), null));
                j.Member("preview", SafePreview(m, m.Manifest));
                j.EndObject();
            }
            j.EndArray().EndObject();
            File.WriteAllText(Path.Combine(Root, "mods.json"), j.ToString());
        }

        private static string SafeStr(string tag, Func<string> f, string fallback)
        {
            try { string s = f(); return string.IsNullOrEmpty(s) ? fallback : s; }
            catch (Exception e) { System.Console.WriteLine("[raves] mods field '" + tag + "': " + e.Message); return fallback; }
        }

        private static bool SafeBool(string tag, Func<bool> f, bool fallback)
        {
            try { return f(); }
            catch (Exception e) { System.Console.WriteLine("[raves] mods field '" + tag + "': " + e.Message); return fallback; }
        }

        private static string[] SafeArr(string tag, Func<string[]> f)
        {
            try { return f(); }
            catch (Exception e) { System.Console.WriteLine("[raves] mods field '" + tag + "': " + e.Message); return null; }
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

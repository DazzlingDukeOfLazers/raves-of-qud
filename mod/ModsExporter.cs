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
                XRL.ModManifest man = m.Manifest;

                string preview = null;
                if (man != null && !string.IsNullOrEmpty(man.PreviewImage) && m.Directory != null)
                {
                    string p = Path.Combine(m.Directory.FullName, man.PreviewImage);
                    if (File.Exists(p)) preview = p;   // Raves loads the PNG straight from the install
                }

                j.BeginObject();
                j.Member("id", m.ID);
                j.Member("title", m.DisplayTitleStripped);
                j.Member("author", man != null ? man.Author : null);
                j.Member("version", man != null && man.Version != null ? man.Version.ToString() : null);
                j.Member("description", man != null ? man.Description : null);
                j.Name("tags").BeginArray();
                if (man != null && man.Tags != null)
                    foreach (string t in man.Tags) j.Value(t);
                j.EndArray();
                j.Member("size", HumanSize(m.Size));
                j.Member("enabled", m.IsEnabled);
                j.Member("scripting", m.IsScripting);
                j.Member("source", m.Source.ToString());
                j.Member("path", m.Path ?? (m.Directory != null ? m.Directory.FullName : null));
                j.Member("preview", preview);
                j.EndObject();
            }
            j.EndArray().EndObject();
            File.WriteAllText(Path.Combine(Root, "mods.json"), j.ToString());
        }

        private static string HumanSize(long b)
        {
            if (b < 1024) return b + " B";
            if (b < 1024L * 1024L) return (b / 1024L) + " KB";
            return ((double)b / 1024.0 / 1024.0).ToString("0.0") + " MB";
        }
    }
}

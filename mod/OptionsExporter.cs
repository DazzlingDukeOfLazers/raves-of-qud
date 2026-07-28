using System;
using System.IO;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Export Qud's FULL options tree — <c>XRL.UI.Options.OptionsByCategory</c> (every category
    /// and option: definition + current value + live visibility) — to options.json in the
    /// RavesOfQud dir, so Raves' Options screen can mirror Qud's 1:1 (a settings editor read
    /// from the player's own install). Same install-extraction idea as the mod list / title art;
    /// data-only (reads the loaded Options registry + GetOption), safe on the turn thread.
    ///
    /// Write-back (Raves changing a Qud option) is a later phase via <c>Options.SetOption</c>.
    /// </summary>
    public static class OptionsExporter
    {
        private static int _tried;

        public static void Ensure()
        {
            if (Interlocked.Exchange(ref _tried, 1) != 0) return;
            try
            {
                Export();
                System.Console.WriteLine("[raves] options exported -> " + Path.Combine(Root, "options.json"));
            }
            catch (Exception e)
            {
                System.Console.WriteLine("[raves] options export failed: " + e.Message);
                _tried = 0;
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
            var byCat = XRL.UI.Options.OptionsByCategory;
            if (byCat == null) return;

            var j = new JsonWriter();
            j.BeginObject().Name("categories").BeginArray();
            foreach (var kv in byCat)   // insertion order == Options.xml order == Qud's sidebar order
            {
                j.BeginObject();
                j.Member("name", kv.Key);
                j.Name("options").BeginArray();
                foreach (XRL.UI.GameOption o in kv.Value)
                {
                    if (o == null) continue;
                    j.BeginObject();
                    j.Member("id", o.ID);
                    j.Member("label", o.DisplayText);
                    j.Member("type", o.Type);
                    j.Member("category", o.Category);
                    j.Member("value", XRL.UI.Options.GetOption(o.ID, o.Default));
                    j.Member("default", o.Default);
                    j.Member("min", o.Min);
                    j.Member("max", o.Max);
                    j.Member("increment", o.Increment);
                    WriteArray(j, "values", o.Values);
                    WriteArray(j, "displayValues", o.DisplayValues);
                    j.Member("visible", VisibleNow(o));   // Requires + platform capability met = Qud shows it
                    j.Member("restart", o.Restart);
                    j.Member("help", o.HelpText);
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray().EndObject();
            File.WriteAllText(Path.Combine(Root, "options.json"), j.ToString());
        }

        private static void WriteArray(JsonWriter j, string name, string[] arr)
        {
            j.Name(name).BeginArray();
            if (arr != null)
                foreach (string v in arr) j.Value(v ?? "");
            j.EndArray();
        }

        /// Whether Qud would currently DISPLAY this option: its Requires dependency is satisfied
        /// (e.g. "OptionSound==Yes", the advanced-options toggle) AND its platform capability is met.
        private static bool VisibleNow(XRL.UI.GameOption o)
        {
            try
            {
                bool req = o.Requires == null || o.Requires.RequirementsMet;
                return req && o.RequiresCapabilityMet();
            }
            catch
            {
                return true;
            }
        }
    }
}

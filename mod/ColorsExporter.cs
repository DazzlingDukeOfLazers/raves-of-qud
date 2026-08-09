using System;
using System.IO;
using System.Reflection;
using System.Text;

namespace RavesOfQud
{
    /// <summary>
    /// Export Qud's REAL colour palette — the code-character to RGB mapping behind every
    /// <c>{{g|...}}</c> markup run — to <c>colors.json</c> in the RavesOfQud support dir.
    ///
    /// WHY. Raves' QUD_COLORS table was hand-approximated, and measuring the caste screen's three
    /// arcology band rules against Qud's showed how far off that is: Raves drew the Ibul band
    /// (96,162,174) as (97,245,245) and the Yawningmoon band (168,64,14) as (244,75,75) — bright
    /// generic ANSI colours where Qud uses a muted palette. That is not a caste bug; the same table
    /// colours every screen in the app, so every parity comparison has been carrying it.
    ///
    /// Read from the player's own install through XRL's ColorUtility.colorFromChar, so it tracks
    /// the game rather than a screenshot. Reflection keeps it compile-proof across Qud versions.
    /// </summary>
    public static class ColorsExporter
    {
        /// <summary>Every code Qud's markup accepts, plus the digits it uses for shades.</summary>
        private const string CODES = "rRgGbBcCmMwWoOyYkK";

        public static string Path_ => System.IO.Path.Combine(Root, "colors.json");

        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string root = System.IO.Path.Combine(home, "Library", "Application Support", "RavesOfQud");
                Directory.CreateDirectory(root);
                return root;
            }
        }

        public static void Export()
        {
            var t = Type.GetType("ConsoleLib.Console.ColorUtility, Assembly-CSharp");
            if (t == null)
                foreach (var cand in typeof(GameManager).Assembly.GetTypes())
                    if (cand.Name == "ColorUtility") { t = cand; break; }
            if (t == null) { Console.WriteLine("[raves] colors: no ColorUtility"); return; }

            var mi = t.GetMethod("colorFromChar", BindingFlags.Static | BindingFlags.Public
                                                  | BindingFlags.NonPublic);
            if (mi == null) { Console.WriteLine("[raves] colors: no colorFromChar"); return; }

            var sb = new StringBuilder();
            sb.Append("{\n");
            bool first = true;
            foreach (char c in CODES)
            {
                string hex;
                try
                {
                    var col = (UnityEngine.Color)mi.Invoke(null, new object[] { c });
                    hex = string.Format("#{0:x2}{1:x2}{2:x2}",
                        (int)Math.Round(col.r * 255f), (int)Math.Round(col.g * 255f),
                        (int)Math.Round(col.b * 255f));
                }
                catch { continue; }
                if (!first) sb.Append(",\n");
                first = false;
                sb.Append("  \"" + c + "\": \"" + hex + "\"");
            }
            sb.Append("\n}\n");
            try
            {
                File.WriteAllText(Path_, sb.ToString());
                Console.WriteLine("[raves] colors exported -> " + Path_);
            }
            catch (Exception e) { Console.WriteLine("[raves] colors export failed: " + e.Message); }
        }
    }
}

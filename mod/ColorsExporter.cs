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
        public static string ShaderPath_ => System.IO.Path.Combine(Root, "shaders.json");

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
            ExportShaders();
        }

        /// <summary>The NAMED colours — <c>{{rules|…}}</c>, <c>{{painted|…}}</c>, <c>{{rocket|…}}</c>.
        ///
        /// The single-char table above is only half of Qud's markup. A span's code can also be a
        /// SHADER NAME, and the client was resolving those by taking the first character: `rules`
        /// became `r`, so every rules line in every item description rendered dark red where Qud
        /// draws it light blue (`&lt;shader Name="rules" Type="solid" Colors="C"/&gt;`). Reported
        /// 2026-08-10 as "red effect text in Raves should be light blue as in Qud", and the same
        /// bug was quietly colouring `{{painted|painted}}`, `{{spaser|…}}` and the rest.
        ///
        /// Read off MarkupShaders' own registry rather than Colors.xml so mod-added shaders come
        /// too. The KIND matters as much as the colours, because each is a different function of
        /// character position (ConsoleLib.Console.MarkupShaders):
        ///   solid        Colors[0] throughout
        ///   sequence     Colors[totalPos % Colors.Length]                  — cycles per character
        ///   alternation  Colors[totalPos * Colors.Length / totalLen]       — N equal bands
        ///   bordered     Colors[1] on the first and last character, else Colors[0]
        /// All four are pure functions of position, so the client can reproduce them exactly --
        /// there is nothing time-varying to chase here.
        private static void ExportShaders()
        {
            try
            {
                var t = Type.GetType("ConsoleLib.Console.MarkupShaders, Assembly-CSharp");
                if (t == null)
                    foreach (var cand in typeof(GameManager).Assembly.GetTypes())
                        if (cand.Name == "MarkupShaders") { t = cand; break; }
                if (t == null) { Console.WriteLine("[raves] shaders: no MarkupShaders"); return; }

                // ByName is the dictionary Qud's own `{{name|` lookup goes through, so it is the
                // one that cannot disagree with what the game renders. Fall back to the public
                // Shaders list if the field is ever renamed.
                System.Collections.IEnumerable shaders = null;
                var byName = t.GetField("ByName", BindingFlags.Static | BindingFlags.NonPublic
                                                  | BindingFlags.Public);
                if (byName != null)
                {
                    var dict = byName.GetValue(null) as System.Collections.IDictionary;
                    if (dict != null) shaders = dict.Values;
                }
                if (shaders == null)
                {
                    var lst = t.GetField("Shaders", BindingFlags.Static | BindingFlags.Public);
                    if (lst != null) shaders = lst.GetValue(null) as System.Collections.IEnumerable;
                }
                if (shaders == null) { Console.WriteLine("[raves] shaders: no registry"); return; }

                var sb = new StringBuilder();
                sb.Append("{\n");
                bool first = true;
                var seen = new System.Collections.Generic.HashSet<string>();
                foreach (object sh in shaders)
                {
                    if (sh == null) continue;
                    Type st = sh.GetType();
                    string name = null, colors = null;
                    try
                    {
                        var fn = Field(st, "Name");
                        if (fn != null) name = fn.GetValue(sh) as string;
                        var fc = Field(st, "Colors");
                        var arr = fc != null ? fc.GetValue(sh) as char[] : null;
                        if (arr != null) colors = new string(arr);
                    }
                    catch { }
                    if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(colors)) continue;
                    if (!seen.Add(name)) continue;
                    // The concrete class IS the kind: Solid / Sequence / Alternation / Bordered
                    // (and the abstract bases I*, for patterns). Lowercased to match Colors.xml.
                    string kind = st.Name.TrimStart('I').ToLowerInvariant();
                    if (!first) sb.Append(",\n");
                    first = false;
                    sb.Append("  \"").Append(Esc(name)).Append("\": {\"kind\": \"").Append(Esc(kind))
                      .Append("\", \"colors\": \"").Append(Esc(colors)).Append("\"}");
                }
                sb.Append("\n}\n");
                File.WriteAllText(ShaderPath_, sb.ToString());
                Console.WriteLine("[raves] shaders exported -> " + ShaderPath_);
            }
            catch (Exception e) { Console.WriteLine("[raves] shaders export failed: " + e.Message); }
        }

        /// Colors/Name live on IMarkupShader, not on the concrete subclass, so walk up.
        private static FieldInfo Field(Type t, string name)
        {
            for (Type c = t; c != null; c = c.BaseType)
            {
                var f = c.GetField(name, BindingFlags.Instance | BindingFlags.Public
                                         | BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
                if (f != null) return f;
            }
            return null;
        }

        private static string Esc(string s)
        {
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }
    }
}

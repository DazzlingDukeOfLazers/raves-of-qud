using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

namespace RavesOfQud
{
    /// <summary>
    /// Dump the LIVE UI window object's shape — type, base chain, methods, and the fields that
    /// look like selection state — to <c>ui_reflect.txt</c> in the RavesOfQud support dir.
    ///
    /// WHY THIS EXISTS. Qud's chargen module windows cannot be driven from outside by any input
    /// path: SendKeys, raw SendInput scancodes, the printed [A]-[L] hotkeys, and every tag form
    /// through Keyboard.PushMouseEvent / PushCommand all moved exactly 0 pixels (measured by frame
    /// differencing, 2026-08-08). Zero every time and never a near-miss is not a wrong tag, it is a
    /// queue nobody reads: both push APIs feed Qud's LEGACY console input queue, and these are
    /// modern Qud.UI windows that do not consume it. So the only way in is to call the window
    /// object's own methods — and to do that we must know what they are.
    ///
    /// REFLECT, DON'T GREP (the repo rule) and don't decompile either: ilspycmd would describe the
    /// assembly on disk, while this describes the object that is actually on screen right now,
    /// including which of several candidate windows is live and what its selection index currently
    /// reads. That is strictly more information, needs no toolchain installed, and cannot drift
    /// from the running game.
    ///
    /// MAIN THREAD ONLY — it touches UIManager and Unity components, so callers marshal through
    /// GameManager.Instance.uiQueue (the turn-thread golden rule).
    /// </summary>
    public static class UiReflector
    {
        /// <summary>
        /// The visible modern UI window object, or null. MAIN THREAD ONLY.
        ///
        /// Two shapes, both needed: most screens become UIManager._currentWindow, but several
        /// toolkit screens are SingletonWindowBase windows that never do (verified live: Workshop
        /// Uploader, Blueprint Browser, Histographicnomicon, Waveform generator) and have to be
        /// probed by name through the generic base's static `instance`.
        /// </summary>
        public static object CurrentWindow()
        {
            const BindingFlags ANY = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            try
            {
                var umType = Type.GetType("Qud.UI.UIManager, Assembly-CSharp");
                object um = umType != null ? umType.GetField("instance")?.GetValue(null) : null;
                if (um != null)
                {
                    var cw = umType.GetField("_currentWindow", ANY)?.GetValue(um);
                    if (cw != null && IsVisible(cw)) return cw;
                }
                foreach (var tn in new[] { "SteamWorkshopUploaderView", "BrowseBlueprintsView",
                                           "HistoryTestView", "WaveformTestView" })
                {
                    var t = Type.GetType(tn + ", Assembly-CSharp");
                    object inst = t?.BaseType?.GetField("instance",
                        BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)?.GetValue(null);
                    if (inst != null && IsVisible(inst)) return inst;
                }
            }
            catch { /* a sampler must never take down the UI thread */ }
            return null;
        }

        private static bool IsVisible(object win)
        {
            const BindingFlags ANY = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            var vis = win.GetType().GetProperty("Visible", ANY);
            return vis != null && vis.GetValue(win, null) is bool b && b;
        }

        /// <summary>Type name of the visible window, or "" — what the heartbeat reports as `scene`.</summary>
        public static string CurrentWindowName()
        {
            var w = CurrentWindow();
            return w == null ? "" : w.GetType().Name;
        }

        public static string Path_ => System.IO.Path.Combine(Root, "ui_reflect.txt");

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

        /// <summary>
        /// Reflect over the visible window (or a named type, when the window we want is not the one
        /// currently up) and write the dump. MAIN THREAD ONLY.
        /// </summary>
        public static void Dump(string typeName = null)
        {
            var sb = new StringBuilder();
            try
            {
                object win = null;
                Type t = null;
                if (!string.IsNullOrEmpty(typeName))
                {
                    // Qud's UI types are spread over Qud.UI, XRL.UI, XRL.UI.Framework and
                    // XRL.CharacterBuilds.*, so a qualified guess misses more often than it hits —
                    // fall back to scanning the assembly for the simple name.
                    t = Type.GetType(typeName + ", Assembly-CSharp");
                    if (t == null)
                        foreach (var cand in typeof(GameManager).Assembly.GetTypes())
                            if (cand.Name == typeName || cand.FullName == typeName) { t = cand; break; }
                    sb.AppendLine("# requested type: " + typeName + (t == null ? "  NOT FOUND" : ""));
                }
                else
                {
                    win = CurrentWindow();
                    t = win?.GetType();
                    sb.AppendLine("# visible window: " + (t == null ? "(none)" : t.FullName));
                }
                if (t == null) { Write(sb); return; }

                sb.Append("# base chain:");
                for (var b = t.BaseType; b != null && b != typeof(object); b = b.BaseType)
                    sb.Append(" <- " + b.Name);
                sb.AppendLine();
                sb.AppendLine();

                // Methods DECLARED on the window types themselves. Walking into MonoBehaviour and
                // friends buries the handful that matter under hundreds of Unity members.
                sb.AppendLine("## methods");
                foreach (var ty in Chain(t))
                {
                    var ms = ty.GetMethods(BindingFlags.Instance | BindingFlags.Static
                                           | BindingFlags.Public | BindingFlags.NonPublic
                                           | BindingFlags.DeclaredOnly)
                              .Where(m => !m.IsSpecialName)
                              .OrderBy(m => m.Name).ToList();
                    if (ms.Count == 0) continue;
                    sb.AppendLine("--- " + ty.Name);
                    foreach (var m in ms)
                        sb.AppendLine("    " + (m.IsStatic ? "static " : "") + Short(m.ReturnType) + " "
                                      + m.Name + "(" + string.Join(", ",
                                          m.GetParameters().Select(p => Short(p.ParameterType) + " " + p.Name)) + ")");
                }

                // Fields and properties WITH THEIR CURRENT VALUES — the half a decompiler cannot
                // give you. A selection index reading 2 while the third card is lit names itself.
                sb.AppendLine();
                sb.AppendLine("## state (live values)");
                foreach (var ty in Chain(t))
                {
                    sb.AppendLine("--- " + ty.Name);
                    foreach (var f in ty.GetFields(BindingFlags.Instance | BindingFlags.Static
                                                   | BindingFlags.Public | BindingFlags.NonPublic
                                                   | BindingFlags.DeclaredOnly).OrderBy(f => f.Name))
                        sb.AppendLine("    " + Short(f.FieldType) + " " + f.Name + " = " + Val(() => f.GetValue(win)));
                    foreach (var p in ty.GetProperties(BindingFlags.Instance | BindingFlags.Static
                                                       | BindingFlags.Public | BindingFlags.NonPublic
                                                       | BindingFlags.DeclaredOnly)
                                        .Where(p => p.CanRead && p.GetIndexParameters().Length == 0)
                                        .OrderBy(p => p.Name))
                        sb.AppendLine("    " + Short(p.PropertyType) + " " + p.Name + " => " + Val(() => p.GetValue(win, null)));
                }
            }
            catch (Exception e)
            {
                sb.AppendLine("!! reflect failed: " + e);
            }
            Write(sb);
        }

        /// <summary>The type and its bases, stopping before Unity's own — those are noise here.</summary>
        private static System.Collections.Generic.IEnumerable<Type> Chain(Type t)
        {
            for (var ty = t; ty != null && ty != typeof(object); ty = ty.BaseType)
            {
                var n = ty.FullName ?? "";
                if (n.StartsWith("UnityEngine.") || n.StartsWith("TMPro.")) yield break;
                yield return ty;
            }
        }

        private static string Short(Type t)
        {
            if (t == null) return "?";
            if (!t.IsGenericType) return t.Name;
            return t.Name.Split('`')[0] + "<" + string.Join(", ", t.GetGenericArguments().Select(Short)) + ">";
        }

        /// <summary>
        /// Render a value for the dump. Getters on a live UI object can throw or block, and a
        /// collection can be enormous, so every read is guarded and every sequence is truncated —
        /// a dump that takes the UI thread down tells us nothing.
        /// </summary>
        private static string Val(Func<object> get)
        {
            object v;
            try { v = get(); }
            catch (Exception e) { return "<throws: " + (e.InnerException ?? e).GetType().Name + ">"; }
            if (v == null) return "null";
            if (v is string s) return "\"" + (s.Length > 120 ? s.Substring(0, 120) + "..." : s) + "\"";
            if (v is IEnumerable seq && !(v is IDictionary))
            {
                var parts = new System.Collections.Generic.List<string>();
                try
                {
                    foreach (var item in seq)
                    {
                        if (parts.Count == 8) { parts.Add("..."); break; }
                        parts.Add(item == null ? "null" : item.ToString());
                    }
                }
                catch { parts.Add("<enumeration threw>"); }
                return "[" + string.Join(", ", parts) + "]";
            }
            try { return v.ToString(); }
            catch { return "<ToString threw>"; }
        }

        private static void Write(StringBuilder sb)
        {
            try { File.WriteAllText(Path_, sb.ToString()); }
            catch (Exception e) { Console.WriteLine("[raves] ui_reflect write failed: " + e.Message); }
        }
    }
}

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace RavesOfQud
{
    /// <summary>
    /// Drive Qud's modern chargen windows by calling their OWN methods, not by synthesizing input.
    ///
    /// The whole input surface is dead for these screens — SendKeys, raw SendInput scancodes, the
    /// printed [A]-[L] hotkeys, and every tag through Keyboard.PushMouseEvent / PushCommand moved
    /// exactly 0 pixels, because both push APIs feed the LEGACY console queue and these windows do
    /// not read it (see the note on Bridge's `pick`). Reflecting the live window
    /// (<see cref="UiReflector"/>) named the way in:
    ///
    ///     IEnumerable&lt;ChoiceWithColorIcon&gt; GetSelections()
    ///     void ChoiceSelected(FrameworkDataElement data)
    ///
    /// declared on QudGamemodeModuleWindow and its siblings. So: enumerate the window's own
    /// choices, match one by label, hand it back to the window's own handler. No coordinates, no
    /// OCR, no dependence on focus — and it cannot land on the wrong card the way a click can,
    /// because the choice object IS the identity.
    ///
    /// MAIN THREAD ONLY (Unity objects) — callers marshal through GameManager.Instance.uiQueue.
    /// </summary>
    public static class UiDriver
    {
        private const BindingFlags ANY = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        /// <summary>
        /// Select a choice on the visible module window by label (substring, case-insensitive,
        /// colour markup ignored) or by 0-based index. Writes what it saw to ui_reflect.txt so a
        /// miss names the choices that WERE there instead of just failing.
        /// </summary>
        public static void Choose(string label, int index)
        {
            var log = new StringBuilder();
            try
            {
                object win = UiReflector.CurrentWindow();
                if (win == null) { Fail(log, "no visible window"); return; }
                log.AppendLine("# window: " + win.GetType().FullName);

                var getSel = FindMethod(win.GetType(), "GetSelections", 0);
                if (getSel == null) { Fail(log, "window has no GetSelections()"); return; }
                var seq = getSel.Invoke(win, null) as IEnumerable;
                if (seq == null) { Fail(log, "GetSelections() returned null"); return; }

                var choices = new List<object>();
                foreach (var c in seq) choices.Add(c);
                log.AppendLine("# choices: " + choices.Count);
                for (int i = 0; i < choices.Count; i++)
                    log.AppendLine("  [" + i + "] " + Describe(choices[i]));

                object pick = null;
                if (index >= 0 && index < choices.Count) pick = choices[index];
                else if (!string.IsNullOrEmpty(label))
                {
                    // Exact match first, so "Classic" cannot be stolen by a longer label that
                    // merely contains it.
                    foreach (var c in choices)
                        if (Labels(c).Exists(s => string.Equals(s, label, StringComparison.OrdinalIgnoreCase)))
                        { pick = c; break; }
                    if (pick == null)
                        foreach (var c in choices)
                            if (Labels(c).Exists(s => s.IndexOf(label, StringComparison.OrdinalIgnoreCase) >= 0))
                            { pick = c; break; }
                }
                if (pick == null)
                {
                    Fail(log, "no choice matched label=" + (label ?? "(none)") + " index=" + index);
                    return;
                }

                var chosen = FindHandler(win.GetType(), pick.GetType(), log);
                if (chosen == null) { Fail(log, "no selection handler on " + win.GetType().Name); return; }
                log.AppendLine("# handler: " + chosen.Name);
                log.AppendLine("# selecting: " + Describe(pick));
                chosen.Invoke(win, new[] { pick });
                log.AppendLine("# " + chosen.Name + " returned");
            }
            catch (Exception e)
            {
                log.AppendLine("!! choose failed: " + (e.InnerException ?? e));
            }
            Write(log);
        }

        /// <summary>
        /// Invoke a no-argument method on the visible window by name — the escape hatch for the
        /// verbs reflection turns up that are not "pick a choice": RandomSelection, ResetSelection,
        /// EnsureContentsActive. Kept generic on purpose; the reflection dump is the menu.
        /// </summary>
        public static void Invoke(string method)
        {
            var log = new StringBuilder();
            try
            {
                object win = UiReflector.CurrentWindow();
                if (win == null) { Fail(log, "no visible window"); return; }
                var mi = FindMethod(win.GetType(), method, 0);
                if (mi == null) { Fail(log, win.GetType().Name + " has no " + method + "()"); return; }
                mi.Invoke(win, null);
                log.AppendLine("# " + win.GetType().Name + "." + method + "() returned");
            }
            catch (Exception e)
            {
                log.AppendLine("!! invoke failed: " + (e.InnerException ?? e));
            }
            Write(log);
        }

        /// <summary>
        /// Find the window's "a choice was picked" handler STRUCTURALLY, because the name is not
        /// stable across screens — QudGamemodeModuleWindow declares ChoiceSelected(FrameworkDataElement),
        /// QudGenotypeModuleWindow declares onSelectGenotype(FrameworkDataElement). Collecting names
        /// would mean a new one to discover on every screen; the SHAPE is the same on both.
        ///
        /// The shape: returns void, takes exactly one parameter the choice actually fits, and is
        /// not HandleMenuOption. Returning void rules out IsChoiceSelected(ChoiceWithColorIcon);
        /// the parameter test rules out BeforeShow/AfterShow/DebugQuickstart, whose parameters a
        /// choice does not fit. HandleMenuOption is the one method that passes the shape test and
        /// is still wrong, so it is excluded by name — deliberately the only name in here.
        ///
        /// Search the WHOLE base chain, because the handler can sit above the type that declares
        /// GetSelections(): QudSubtypeModuleCategoryWindow declares its own GetSelections() but
        /// inherits onSelectSubtype from QudSubtypeModuleWindow, so a search bounded at the
        /// declaring type found nothing on the Choose Caste screen. Bounding the walk by TYPE was
        /// tried and is wrong in the other direction — QudGamemodeModuleWindow declares its own
        /// HandleMenuOption(MenuOption) overload, so treating that as the framework boundary broke
        /// the one screen that already worked.
        /// </summary>
        private static MethodInfo FindHandler(Type winType, Type choiceType, StringBuilder log)
        {
            for (var ty = winType; ty != null && ty != typeof(object); ty = ty.BaseType)
            {
                var hits = new List<MethodInfo>();
                foreach (var m in ty.GetMethods(ANY | BindingFlags.DeclaredOnly))
                {
                    if (m.ReturnType != typeof(void) || m.Name == "HandleMenuOption") continue;
                    var ps = m.GetParameters();
                    if (ps.Length != 1 || !ps[0].ParameterType.IsAssignableFrom(choiceType)) continue;
                    hits.Add(m);
                }
                if (hits.Count == 0) continue;   // keep climbing the concrete window layer
                if (hits.Count > 1)
                {
                    // Ambiguity is a fact about the screen, not something to resolve silently — say
                    // so in the dump, then take the first so the drive still makes progress.
                    var names = new List<string>();
                    foreach (var m in hits) names.Add(m.Name);
                    log.AppendLine("# NOTE ambiguous handlers: " + string.Join(", ", names.ToArray()));
                }
                return hits[0];
            }
            return null;
        }

        /// <summary>Walk the base chain — these methods are declared at several levels.</summary>
        private static MethodInfo FindMethod(Type t, string name, int argc)
        {
            for (var ty = t; ty != null && ty != typeof(object); ty = ty.BaseType)
                foreach (var m in ty.GetMethods(ANY | BindingFlags.DeclaredOnly))
                    if (m.Name == name && m.GetParameters().Length == argc) return m;
            return null;
        }

        private static readonly Regex Markup = new Regex(@"\{\{[^|}]*\|", RegexOptions.Compiled);

        /// <summary>Every string a choice carries, colour markup stripped — the match candidates.</summary>
        private static List<string> Labels(object c)
        {
            var outp = new List<string>();
            if (c == null) return outp;
            for (var ty = c.GetType(); ty != null && ty != typeof(object); ty = ty.BaseType)
            {
                foreach (var f in ty.GetFields(ANY | BindingFlags.DeclaredOnly))
                    if (f.FieldType == typeof(string)) Add(outp, () => (string)f.GetValue(c));
                foreach (var p in ty.GetProperties(ANY | BindingFlags.DeclaredOnly))
                    if (p.PropertyType == typeof(string) && p.CanRead && p.GetIndexParameters().Length == 0)
                        Add(outp, () => (string)p.GetValue(c, null));
            }
            return outp;
        }

        private static void Add(List<string> outp, Func<string> get)
        {
            string v;
            try { v = get(); } catch { return; }
            if (string.IsNullOrEmpty(v)) return;
            v = Markup.Replace(v, "").Replace("}}", "").Trim();
            if (v.Length > 0 && !outp.Contains(v)) outp.Add(v);
        }

        private static string Describe(object c)
        {
            return c == null ? "null" : c.GetType().Name + " " + string.Join(" | ", Labels(c).ToArray());
        }

        private static void Fail(StringBuilder log, string why)
        {
            log.AppendLine("!! " + why);
            Write(log);
            Console.WriteLine("[raves] uidriver: " + why);
        }

        private static void Write(StringBuilder log)
        {
            try { File.WriteAllText(UiReflector.Path_, log.ToString()); }
            catch (Exception e) { Console.WriteLine("[raves] ui_reflect write failed: " + e.Message); }
        }
    }
}

using System;
using System.IO;
using System.Text;
using XRL.UI;

namespace RavesOfQud
{
    /// <summary>
    /// Export the CONTROL MAPPING data — categories, commands and the player's CURRENT
    /// keyboard bindings — to <c>bindings.json</c>, for Raves' Control Mapping screen.
    ///
    /// Mirrors KeybindsScreen.QueryKeybinds() verbatim: CategoriesInOrder →
    /// CommandsByCategory, the same per-command include condition, and
    /// CommandBindingManager.GetCommandBindings for QUD'S OWN formatted bind strings
    /// ("Shift+↑", "Control+Enter", …) — up to four per command. Data-only; re-run
    /// via the bridge "export" command so a rebind in Qud refreshes Raves.
    /// </summary>
    public static class BindingsExporter
    {
        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] bindings export failed: " + e.Message); }
        }

        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        private static void Export()
        {
            if (CommandBindingManager.CategoriesInOrder == null) return;   // not initialized yet

            var j = new JsonWriter();
            j.BeginObject();
            j.Name("categories").BeginArray();
            foreach (string cat in CommandBindingManager.CategoriesInOrder)
            {
                j.BeginObject();
                j.Member("name", cat ?? "");
                j.Name("commands").BeginArray();
                System.Collections.Generic.List<GameCommand> cmds;
                if (CommandBindingManager.CommandsByCategory != null
                    && CommandBindingManager.CommandsByCategory.TryGetValue(cat, out cmds) && cmds != null)
                {
                    foreach (GameCommand c in cmds)
                    {
                        if (c == null) continue;
                        // the screen's own include condition (keyboard): Button-type
                        // commands except GamepadAlt — the add sits INSIDE the negated
                        // if in the decompile, easy to read backwards
                        if (!(c.Type == UnityEngine.InputSystem.InputActionType.Button && c.ID != "GamepadAlt"))
                            continue;
                        string b1, b2, b3, b4;
                        try
                        {
                            CommandBindingManager.GetCommandBindings(c.ID,
                                ControlManager.InputDeviceType.Keyboard, out b1, out b2, out b3, out b4);
                        }
                        catch { b1 = b2 = b3 = b4 = ""; }
                        j.BeginObject();
                        j.Member("id", c.ID ?? "").Member("display", c.DisplayText ?? "");
                        j.Member("b1", b1 ?? "").Member("b2", b2 ?? "")
                         .Member("b3", b3 ?? "").Member("b4", b4 ?? "");
                        j.EndObject();
                    }
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();

            Directory.CreateDirectory(Root);
            File.WriteAllText(Path.Combine(Root, "bindings.json"), j.ToString(), new UTF8Encoding(false));
        }
    }
}

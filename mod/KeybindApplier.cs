using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using UnityEngine.InputSystem;
using XRL;      // Extensions.GetAwaiter makes The.UiContext awaitable
using XRL.UI;

namespace RavesOfQud
{
    /// <summary>
    /// Apply CONTROL MAPPING edits sent from Raves — set / remove a binding, restore
    /// Qud defaults, or restore the GOLDEN copy of the player's original map.
    ///
    /// Mirrors KeybindsScreen.HandleRebindAsync / HandleMenuOption verbatim, minus the
    /// hardware key capture (Raves captures the key; we rebuild the binding exactly like
    /// GetRebindAsync.OnApplyBinding: plain path, OneModifier, or TwoModifiers — with
    /// Qud's own quirk that a third modifier is dropped). Conflict/confirm popups use
    /// Popup.Show*Async, so they mirror into Raves through the popup bridge and the
    /// answers round-trip like any modal.
    ///
    /// GOLDEN COPY: before the FIRST mutation ever applied from Raves, the current
    /// bindings.json is copied to bindings.golden.json and Qud's real keymap file to
    /// keymap.golden.json (both in the RavesOfQud support dir). "golden" restores the
    /// latter via Qud's own LoadCurrentKeymap.
    /// </summary>
    public static class KeybindApplier
    {
        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        /// Re-snapshot the golden copy from the CURRENT bindings (overwrites both files).
        /// The auto-snapshot only ever fires once — before the first Raves-side edit — so
        /// a keymap the player has since tuned needs an explicit refresh to become the
        /// restore point. Confirmed in-app, because it discards the previous golden.
        public static async Task ReGolden()
        {
            try
            {
                await The.UiContext;
                if (await Popup.ShowYesNoAsync("Replace the golden control mapping with your CURRENT bindings?")
                    != DialogResult.Yes)
                    return;
                CommandBindingManager.SaveCurrentKeymap();   // make sure the file is current first
                BindingsExporter.ReExport();
                Directory.CreateDirectory(Root);
                string cur = Path.Combine(Root, "bindings.json");
                string g = Path.Combine(Root, "bindings.golden.json");
                if (File.Exists(cur)) File.Copy(cur, g, true);
                string km = CommandBindingManager.GetCurrentKeymapPath();
                string kg = Path.Combine(Root, "keymap.golden.json");
                if (File.Exists(km)) File.Copy(km, kg, true);
                System.Console.WriteLine("[raves] golden copy refreshed from current bindings");
                await Popup.ShowAsync("Golden control mapping updated.");
            }
            catch (Exception e) { System.Console.WriteLine("[raves] regolden error: " + e.Message); }
        }

        public static void EnsureGolden()
        {
            try
            {
                Directory.CreateDirectory(Root);
                string g = Path.Combine(Root, "bindings.golden.json");
                if (!File.Exists(g))
                {
                    BindingsExporter.ReExport();
                    string cur = Path.Combine(Root, "bindings.json");
                    if (File.Exists(cur)) File.Copy(cur, g);
                }
                string kg = Path.Combine(Root, "keymap.golden.json");
                string km = CommandBindingManager.GetCurrentKeymapPath();
                if (!File.Exists(kg))
                {
                    // a fresh install may never have SAVED a keymap file — serialize the
                    // (still-pristine) CurrentMap first so the golden isn't skipped
                    if (!File.Exists(km))
                        CommandBindingManager.SaveKeymap(CommandBindingManager.CurrentMap, km);
                    if (File.Exists(km)) File.Copy(km, kg);
                }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] golden: " + e.Message); }
        }

        /// Build the serialized binding for key+modifiers exactly like GetRebindAsync's
        /// OnApplyBinding (keyboard only — no gamepad-alt leg here).
        private static List<string> BuildBinding(string key, bool ctrl, bool shift, bool alt, out string err)
        {
            err = null;
            string path = "<Keyboard>/" + key;
            try
            {
                if (InputSystem.FindControl(path) == null) { err = "unknown key control " + path; return null; }
            }
            catch (Exception e) { err = e.Message; return null; }
            int num = (ctrl ? 1 : 0) + (alt ? 1 : 0) + (shift ? 1 : 0);
            using (InputAction action = new InputAction())
            {
                switch (num)
                {
                    case 0:
                        action.AddBinding(path);
                        break;
                    case 1:
                    {
                        var one = action.AddCompositeBinding("OneModifier");
                        one.With("Binding", path);
                        if (ctrl) one.With("Modifier", "<Keyboard>/ctrl");
                        if (shift) one.With("Modifier", "<Keyboard>/shift");
                        if (alt) one.With("Modifier", "<Keyboard>/alt");
                        break;
                    }
                    default:
                    {
                        var two = action.AddCompositeBinding("TwoModifiers");
                        two.With("Binding", path);
                        int n = 1;
                        if (ctrl) two.With($"Modifier{n++}", "<Keyboard>/ctrl");
                        if (shift) two.With($"Modifier{n++}", "<Keyboard>/shift");
                        if (alt && n != 3) two.With($"Modifier{n++}", "<Keyboard>/alt");   // Qud drops a 3rd modifier
                        break;
                    }
                }
                return action.SerializedFormat();
            }
        }

        public static async Task Apply(string id, int slot, string key, bool ctrl, bool shift, bool alt)
        {
            try
            {
                await The.UiContext;
                EnsureGolden();
                List<string> rebind = BuildBinding(key, ctrl, shift, alt, out string err);
                if (rebind == null)
                {
                    await Popup.ShowAsync("Raves rebind failed: " + err + ".");
                    return;
                }
                GameCommand command;
                if (!CommandBindingManager.CommandsByID.TryGetValue(id, out command) || command == null)
                {
                    await Popup.ShowAsync("Raves rebind: unknown command " + id + ".");
                    return;
                }
                var deviceType = ControlManager.InputDeviceType.Keyboard;
                if (CommandBindingManager.CommandUsesBinding(command, rebind))
                    return;   // already bound to this command — Qud treats it as a no-op
                List<GameCommand> conflicts = CommandBindingManager
                    .GetCommandsWithBinding(rebind, CommandBindingManager.ConflictChecker(command)).ToList();
                string disp = CommandBindingManager.GetBindingDisplayString(rebind);
                GameCommand required = conflicts.Find(c => !c.CanRemoveBinding(deviceType));
                if (required != null)
                {
                    await Popup.ShowAsync("Cannot bind {{C|" + disp + "}} — it is required by {{C|"
                        + required.DisplayText + "}}.");
                    return;
                }
                if (conflicts.Count > 0)
                {
                    string names = string.Join(", ", conflicts.Select(c => c.DisplayText));
                    if (await Popup.ShowYesNoAsync("{{C|" + disp + "}} is already bound to {{C|" + names
                        + "}}. Move it to {{C|" + command.DisplayText + "}}?") != DialogResult.Yes)
                        return;
                    foreach (GameCommand c in conflicts)
                        CommandBindingManager.RemoveCommandBinding(c.ID, rebind);
                }
                CommandBindingManager.ReplaceCommandBindingIndex(id, slot, rebind, deviceType);
                CommandBindingManager.InitializeInputManager(AllowLegacyUpgrade: false, restoreLayers: true);
                CommandBindingManager.SaveCurrentKeymap();
                BindingsExporter.ReExport();
                System.Console.WriteLine("[raves] rebind " + id + "[" + slot + "] = " + disp);
            }
            catch (Exception e) { System.Console.WriteLine("[raves] rebind error: " + e.Message); }
        }

        public static async Task Remove(string id, int slot)
        {
            try
            {
                await The.UiContext;
                EnsureGolden();
                GameCommand command;
                if (!CommandBindingManager.CommandsByID.TryGetValue(id, out command) || command == null) return;
                var deviceType = ControlManager.InputDeviceType.Keyboard;
                if (!command.CanRemoveBinding(deviceType))
                {
                    await Popup.ShowAsync("Can not remove the last binding for {{C|" + command.DisplayText + "}}.");
                    return;
                }
                if (await Popup.ShowYesNoAsync("Are you sure you want to clear this binding for {{C|"
                    + command.DisplayText + "}}?") != DialogResult.Yes)
                    return;
                CommandBindingManager.ReplaceCommandBindingIndex(id, slot, new List<string>(), deviceType);
                CommandBindingManager.InitializeInputManager();
                CommandBindingManager.SaveCurrentKeymap();
                BindingsExporter.ReExport();
                System.Console.WriteLine("[raves] unbind " + id + "[" + slot + "]");
            }
            catch (Exception e) { System.Console.WriteLine("[raves] unbind error: " + e.Message); }
        }

        public static async Task Defaults()
        {
            try
            {
                await The.UiContext;
                EnsureGolden();
                if (await Popup.ShowYesNoAsync("Are you sure you want to override your bindings with the default?")
                    != DialogResult.Yes)
                    return;
                await CommandBindingManager.RestoreDefaults();   // pops Qud's Normal/HJKL picker (mirrored)
                CommandBindingManager.SaveCurrentKeymap();
                BindingsExporter.ReExport();
                System.Console.WriteLine("[raves] keybinds restored to defaults");
            }
            catch (Exception e) { System.Console.WriteLine("[raves] defaults error: " + e.Message); }
        }

        public static async Task RestoreGolden()
        {
            try
            {
                await The.UiContext;
                string kg = Path.Combine(Root, "keymap.golden.json");
                if (!File.Exists(kg))
                {
                    await Popup.ShowAsync("No golden keymap has been saved yet — it is written before the first Raves-side edit.");
                    return;
                }
                if (await Popup.ShowYesNoAsync("Restore the GOLDEN copy of your original control mapping?")
                    != DialogResult.Yes)
                    return;
                CommandBindingManager.LoadCurrentKeymap(kg, AllowLegacyUpgrade: false, restoreLayers: true, targetSet: null);
                CommandBindingManager.SaveCurrentKeymap();
                BindingsExporter.ReExport();
                System.Console.WriteLine("[raves] keybinds restored from golden copy");
            }
            catch (Exception e) { System.Console.WriteLine("[raves] golden restore error: " + e.Message); }
        }
    }
}

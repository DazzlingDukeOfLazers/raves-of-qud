using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Qud.API;             // EquipmentAPI.TwiddleObject — Qud's own item menu
using XRL.UI;              // InventoryAction
using XRL.UI.Framework;    // (APIDispatch retired here 2026-08-10 — the turn thread is the right one)
using XRL.World;
using XRL.World.Anatomy;   // BodyPart (the paper doll)

namespace RavesOfQud
{
    /// <summary>
    /// Export the player's INVENTORY — categories, their items, weights and the
    /// carried/max header — to <c>inventory.json</c> for Raves' Equipment tab.
    ///
    /// Mirrors Qud's own screen (InventoryAndEquipmentStatusScreen + InventoryLine):
    /// items are grouped by <c>GameObject.GetInventoryCategory()</c>, the row label is
    /// <c>go.DisplayName</c> (Qud markup intact), the item weight column is
    /// <c>[{go.Weight} lbs.]</c>, a category's column is <c>|{sum} lbs.|</c>, and the
    /// header is Qud's own <c>${GetFreeDrams()}</c> + <c>{carried}/{max} lbs.</c>.
    /// Tiles come from <c>RenderForUI("Inventory")</c> — the PERCEIVED render, so an
    /// unidentified artifact shows Qud's unknown icon, not its true tile.
    /// </summary>
    public static class InventoryExporter
    {
        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        /// Raves picked an item: run QUD'S OWN interaction popup for it.
        ///
        /// This deliberately does not reimplement the menu. Qud's screen does
        ///     await APIDispatch.RunAndWaitAsync(() =>
        ///         EquipmentAPI.TwiddleObject(The.Player, go, ref bDone, out action))
        /// and TwiddleObject raises the option list, applies the choice, and runs every
        /// follow-on prompt itself. Because our popup mirror already forwards Qud's
        /// modals to Raves (option lists included, async ones too), driving Qud's own
        /// flow gets the whole menu -- correct verbs, correct order, correct side
        /// effects -- for free. Same reasoning as the Skills tab's SelectNode.
        ///
        /// RUNS ON THE TURN THREAD, like Twiddle below and for the same reason (see its
        /// note). `ShowBodypartEquipUI` blocks on `PickItem.ShowPicker` -- a synchronous
        /// modal -- so all three placements behave differently and only one is right:
        /// a uiQueue task DEADLOCKS the wait, an APIDispatch threadpool thread lets the
        /// free-spinning turn loop slam the view back to Stage and tear the picker down
        /// (it then returns its default, i.e. equips something nobody chose), and the
        /// gameQueue opens it ON the thread whose loop would otherwise race it. This was
        /// the LAST of the three APIDispatch copies, fixed 2026-08-10 alongside the
        /// reported skills one; unreported, found by grepping for the pattern.
        /// Qud's "what fits here" picker for a body part -- EquipmentScreen.ShowBodypartEquipUI,
        /// which is what InventoryAndEquipmentStatusScreen.HandleSelectItem runs for a slot with
        /// nothing equipped in it (and for a greyed natural-weapon slot on a LEFT click; only a
        /// right-click looks at those). Addressed by BodyPart.ID, since an empty slot has no
        /// object to name.
        public static void EquipPicker(string partId)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.gameQueue == null) return;
            // Same refusal as Twiddle: a queue nobody drains turns this into a picker that
            // opens later, over whatever screen is up by then.
            string parkedView;
            if (!Bridge.GameQueueDraining(out parkedView))
            {
                string msg = "equip picker refused: Qud is on " + parkedView
                    + ", where the turn thread is parked and gameQueue never drains."
                    + " Leave that screen (hv back / hv goto qud in_game) and click again.";
                System.Console.WriteLine("[raves] " + msg);
                try { Bridge.Server?.Log(msg); } catch { }
                return;
            }
            gm.gameQueue.queueSingletonTask("raves equip picker", () =>
            {
                try
                {
                    GameObject p = XRL.The.Player;
                    if (p == null || p.Body == null) return;
                    // lenient, and LOUD: a bare TryParse returning silently is how a
                    // client sending "188.0" (a JSON number round-tripped through a
                    // float) looked exactly like a click that never happened
                    int pid;
                    if (!int.TryParse(partId, out pid))
                    {
                        double dpid;
                        if (double.TryParse(partId, out dpid)) pid = (int)dpid;
                        else
                        {
                            System.Console.WriteLine("[raves] equip picker: bad part id " + (partId ?? "null"));
                            return;
                        }
                    }
                    BodyPart part = p.Body.GetPartByID(pid);
                    if (part == null)
                    {
                        System.Console.WriteLine("[raves] equip picker: no body part " + partId);
                        return;
                    }
                    System.Console.WriteLine("[raves] equip picker for " + (part.Name ?? "?"));
                    try { XRL.UI.EquipmentScreen.ShowBodypartEquipUI(p, part); }
                    catch (Exception ee) { System.Console.WriteLine("[raves] ShowBodypartEquipUI: " + ee.Message); }
                    ReExport();
                }
                catch (Exception e) { System.Console.WriteLine("[raves] equip picker error: " + e.Message); }
            });
        }

        /// <summary>Raise Qud's item menu for an object, ON THE TURN THREAD.
        ///
        /// WHICH THREAD RUNS TwiddleObject IS THE WHOLE BUG (2026-08-08). This used to be
        /// `uiQueue.queueTask` + `APIDispatch.RunAndWaitAsync`, copied from
        /// `InventoryAndEquipmentStatusScreen.HandleSelectItem`. APIDispatch runs its delegate
        /// on a THREADPOOL thread (`Task.Run`), which is correct for Qud's caller — the status
        /// screen has already parked the turn thread — and wrong for ours, because a
        /// bridge-driven twiddle leaves the turn thread free and spinning in
        /// `XRLCore.PlayerTurn`'s wait-for-input loop. That loop, and `ActionManager.RunSegment`,
        /// each execute
        ///     GameManager.Instance.CurrentGameView = Options.StageViewID;
        /// unconditionally on every iteration. `Popup.PickOption` shows the menu by PUSHING the
        /// "PopupMessage" game view; the next loop iteration slams the view back to "Stage",
        /// `GameManager.UpdateView` then reassigns the canvas and HIDES the popup window, and
        /// `PopupMessage.Hide()` fires `onHide` -> `TaskCompletionSource.TrySetCanceled`. The
        /// `Wait()` in `Popup.WaitNewPopupMessage` throws, and because that method is
        /// `async void` the exception never reaches `PickOption` — which then returns its
        /// untouched local `SelectedOption`, i.e. **DefaultSelected**. So the menu executes its
        /// own highlighted row (for a cloth robe: "equip (auto)"). Measured 6/8 raises.
        ///
        /// Qud's own equivalent — a UI window asking for an item menu with the game idle — is
        /// `NearbyItemsWindow.OnSelect`, and it does exactly this:
        ///     GameManager.Instance.gameQueue.queueSingletonTask("nearby items twiddle",
        ///         () =&gt; EquipmentAPI.TwiddleObject(data.go));
        /// The gameQueue drains inside `Keyboard.getvk(..., pumpActions: true)` — the turn
        /// thread's own input wait — so TwiddleObject runs ON the turn thread, that loop is
        /// inside it rather than racing it, and nothing re-asserts the Stage view under the
        /// popup. It is also the thread `Popup.WaitNewPopupMessage` is written for: off the UI
        /// thread it takes the blocking `uiQueue.awaitTask` branch that the popup mirror
        /// already answers.
        ///
        /// Do NOT wrap this in APIDispatch again. The deadlock APIDispatch exists to avoid is
        /// the one you get calling TwiddleObject from a *uiQueue* task; the turn thread is
        /// where Qud itself calls it from.</summary>
        public static void Twiddle(string id, string mode = null)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.gameQueue == null) return;
            // REFUSE rather than queue into a queue nobody is draining -- see Bridge.GameQueueDraining.
            // Qud parked on one of its own modern menus makes every paper-doll and item-list click in
            // Raves do nothing, and then fire all at once, on whatever the ids resolve to by then, the
            // moment Qud returns to play. Silence plus a delayed wrong action is the worst of both.
            string parkedView;
            if (!Bridge.GameQueueDraining(out parkedView))
            {
                string msg = "twiddle refused: Qud is on " + parkedView
                    + ", where the turn thread is parked and gameQueue never drains."
                    + " Leave that screen in Qud (hv back / hv goto qud in_game) and click again.";
                System.Console.WriteLine("[raves] " + msg);
                try { Bridge.Server?.Log(msg); } catch { }
                return;
            }
            // Singleton: two twiddles cannot be in flight at once (Qud's own key, same reason).
            gm.gameQueue.queueSingletonTask("raves item twiddle", () =>
            {
                try
                {
                    GameObject p = XRL.The.Player;
                    if (p == null) return;
                    GameObject target = FindById(p, id);
                    if (target == null)
                    {
                        System.Console.WriteLine("[raves] twiddle: no object with id " + id);
                        return;
                    }
                    if (mode == "look")
                    {
                        // What EquipmentLine.HandleSelectItem does for a slot holding only a
                        // DefaultBehavior (a natural weapon): Qud will not twiddle those, it
                        // looks at them. Mirroring the split keeps a click on the greyed claw
                        // from offering to drop a body part.
                        System.Console.WriteLine("[raves] look " + target.DisplayNameOnlyStripped);
                        try { InventoryActionEvent.Check(target, p, target, "Look"); }
                        catch (Exception le) { System.Console.WriteLine("[raves] Look: " + le.Message); }
                        return;
                    }
                    System.Console.WriteLine("[raves] twiddle " + target.DisplayNameOnlyStripped);
                    bool bDone = false;
                    InventoryAction action = null;
                    try { EquipmentAPI.TwiddleObject(p, target, ref bDone, out action); }
                    catch (Exception te) { System.Console.WriteLine("[raves] TwiddleObject: " + te.Message); }
                    // "Mod" hands off to the tinkering screen, which Raves has no tab for yet --
                    // say so rather than silently doing nothing.
                    if (action != null && action.Command == "Mod")
                        System.Console.WriteLine("[raves] twiddle chose Mod (tinkering screen not mirrored yet)");
                    ReExport();
                }
                catch (Exception e) { System.Console.WriteLine("[raves] twiddle error: " + e.Message); }
            });
        }

        /// Look an object up by the id the export shipped (go.IDIfAssigned): the pack
        /// first, then the body, so an equipped item can be twiddled from the doll too.
        private static GameObject FindById(GameObject p, string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            try
            {
                var inv = p.Inventory;
                if (inv != null)
                    foreach (GameObject go in inv.GetObjectsDirect())
                        if (go != null && go.ID == id) return go;
            }
            catch { }
            try
            {
                var body = p.Body;
                if (body != null)
                    foreach (BodyPart bp in body.GetParts())
                    {
                        GameObject eq = null;
                        try { eq = bp.Equipped; } catch { }
                        if (eq != null && eq.ID == id) return eq;
                        try { eq = bp.Cybernetics; } catch { }
                        if (eq != null && eq.ID == id) return eq;
                        // DefaultBehavior too: a natural weapon is what the doll shows in
                        // that slot (greyed), so it is clickable and must be resolvable --
                        // without this the claw's id came back "no object with id".
                        try { eq = bp.DefaultBehavior; } catch { }
                        if (eq != null && eq.ID == id) return eq;
                    }
            }
            catch { }
            return null;
        }

        /// <summary>Identify carried artifacts OUTRIGHT — the test fixture for "an identified item
        /// must leave Artifacts for its real category".
        ///
        /// WHY THIS EXISTS RATHER THAN "just examine it in the menu": identification is the one
        /// event that re-files an item under you, so it is the event every list-refresh bug hides
        /// behind — and the only in-game way to reach it is Tinkering's `examine`, which lives
        /// INSIDE the item menu, takes several tries per item at a random rate, and (2026-08-10)
        /// drops the item the moment it succeeds. A probe that has to survive three popups and a
        /// dice roll to observe one boolean is not a probe. This flips the boolean directly.
        ///
        /// Category is not stored anywhere: `GetInventoryCategory()` raises an event that
        /// `Examiner` answers with "Artifacts" while `!Understood()`, so understanding the object
        /// re-files it with no further call. That is exactly what makes this a fair test of the
        /// EXPORT rather than a way of faking one.
        ///
        /// Turn thread, like Twiddle -- it mutates game objects and then re-exports.</summary>
        public static void Identify(string id, bool all)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.gameQueue == null) return;
            string parkedView;
            if (!Bridge.GameQueueDraining(out parkedView))
            {
                string msg = "identify refused: Qud is on " + parkedView
                    + ", where the turn thread is parked and gameQueue never drains.";
                System.Console.WriteLine("[raves] " + msg);
                try { Bridge.Server?.Log(msg); } catch { }
                return;
            }
            gm.gameQueue.queueSingletonTask("raves identify", () =>
            {
                try
                {
                    GameObject p = XRL.The.Player;
                    if (p == null) return;
                    var targets = new List<GameObject>();
                    if (all)
                    {
                        var inv = p.Inventory;
                        if (inv != null)
                            foreach (GameObject go in inv.GetObjectsDirect())
                                if (go != null && !go.Understood()) targets.Add(go);
                    }
                    else
                    {
                        GameObject one = FindById(p, id);
                        if (one == null)
                        {
                            System.Console.WriteLine("[raves] identify: no object with id " + id);
                            return;
                        }
                        targets.Add(one);
                    }
                    int done = 0;
                    foreach (GameObject go in targets)
                    {
                        // Snapshot the BEFORE category: the whole point of the fixture is the pair,
                        // and after the call there is no way to ask what it used to be.
                        string was = "?";
                        try { was = go.GetInventoryCategory() ?? "?"; } catch { }
                        bool changed = false;
                        try { changed = go.MakeUnderstood(); } catch { }
                        if (!changed) continue;
                        done++;
                        string now = "?";
                        try { now = go.GetInventoryCategory() ?? "?"; } catch { }
                        System.Console.WriteLine("[raves] identify " + go.ID + " "
                            + go.DisplayNameOnlyStripped + ": " + was + " -> " + now);
                    }
                    System.Console.WriteLine("[raves] identify: " + done + " of " + targets.Count);
                    ReExport();
                }
                catch (Exception e) { System.Console.WriteLine("[raves] identify error: " + e.Message); }
            });
        }

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] inventory export failed: " + e.Message); }
        }

        /// <summary>Qud's own 18-colour palette as a "palette" member. Shared with the picker mirror
        /// (PickerBridge) so every screen resolves colour chars from the SAME table the game ships —
        /// the client's fallback approximates 'w' as a dark orange where Qud's is a khaki.</summary>
        internal static void WritePalette(JsonWriter j)
        {
            try
            {
                j.Name("palette").BeginObject();
                foreach (char pch in "rRgGbBcCmMwWoOyYkK")
                {
                    try
                    {
                        UnityEngine.Color pc = ConsoleLib.Console.ColorUtility.colorFromChar(pch);
                        j.Member(pch.ToString(), string.Format("#{0:x2}{1:x2}{2:x2}",
                            (int)(pc.r * 255f), (int)(pc.g * 255f), (int)(pc.b * 255f)));
                    }
                    catch { }
                }
                j.EndObject();
            }
            catch { }
        }

        internal static void WriteTile(JsonWriter j, GameObject go, string context = "Inventory",
            bool grey = false)
        {
            try
            {
                // RenderForUI returns a RenderEvent (fields, not the Renderable accessors)
                var r = go.RenderForUI(context);
                if (r == null) return;
                // GreyOutForUI just forces both tones to 'K'; let QUD apply it so the
                // resolved chars below come back already greyed
                if (grey) { try { r = r.GreyOutForUI(); } catch { } }
                string tile = r._Tile;
                if (string.IsNullOrEmpty(tile)) return;
                TileExporter.Ensure(tile);
                j.Member("tile", tile).Member("color", r.ColorString ?? "")
                 .Member("detail", r.DetailColor ?? "");
                // THE colours Qud actually paints with: UIThreeColorProperties.FromRenderable
                // uses getColorChars() -- which resolves TileColor over ColorString -- not the
                // raw ColorString we were sending. Exporting the resolved chars removes the
                // client's guess entirely. Flips matter too (FromRenderable sets them).
                try
                {
                    var cc = r.getColorChars();
                    j.Member("fg", cc.foreground.ToString())
                     .Member("dt", cc.detail.ToString())
                     .Member("bg", cc.background == 'k' ? "" : cc.background.ToString());
                }
                catch { }
                try { if (r.getHFlip()) j.Member("hflip", true); } catch { }
                try { if (r.getVFlip()) j.Member("vflip", true); } catch { }
                // FRAME-DRIVEN COLOURS ARE NOT A COLOUR. AnimatedMaterialFire and its siblings
                // override the detail char on EVERY render out of
                //     (XRLCore.CurrentFrame + FrameOffset) % 60
                // so the `dt` above is one arbitrary frame of an animation, not the object's
                // colour -- and each call also does FrameOffset += RandomCosmetic(1,5), so two
                // exports of the same torch disagree. Qud's own EquipmentLine samples once and
                // keeps it, which is why its paper doll shows a different flame every time the
                // screen is opened (reported 2026-08-10 as an inconsistent torch).
                //
                // Naming the ANIMATION lets the client stop guessing from a sampled char: it can
                // run the cycle itself in user mode and pin a fixed phase in 1:1. Every kind is
                // exported, not just the one the client handles, so a new one shows up in the data
                // rather than needing a mod edit and a restart to discover.
                try
                {
                    string kind = AnimKind(go);
                    if (kind != null) j.Member("anim", kind);
                }
                catch { }
            }
            catch { }
        }

        /// The animation driving this object's colours, or null when nothing does.
        ///
        /// TWO SOURCES, ONE CYCLE. The obvious family is AnimatedMaterial* (ten-odd variants,
        /// matched on the type name so a new one reports itself rather than needing a mod edit).
        /// But the TORCH -- the object that started this -- is not one of them: it animates from
        /// `TorchProperties.Render` with ChangeDetailColor="true", whose table is character for
        /// character the same as AnimatedMaterialFire's:
        ///     num &lt; 15 -&gt; 'R',  30 &lt;= num &lt; 45 -&gt; 'r',  otherwise 'W'
        /// so both report as "fire" and the client runs one cycle for both. Checking only the
        /// class-name family found nothing on a torch and exported no `anim` at all.
        ///
        /// AND ONLY WHILE LIT. TorchProperties guards its whole Render on `pLight.Lit`, and
        /// Extinguish() writes DetailColor="r" once and leaves it — so an unlit torch is not
        /// animated, it is statically dark red, and must NOT be flagged or the client would
        /// flicker a torch that is out.
        private static string AnimKind(GameObject go)
        {
            const string PREFIX = "AnimatedMaterial";
            try
            {
                foreach (var part in go.PartsList)
                {
                    if (part == null) continue;
                    string n = part.GetType().Name;
                    if (n.StartsWith(PREFIX, StringComparison.Ordinal) && n.Length > PREFIX.Length)
                        return n.Substring(PREFIX.Length).ToLowerInvariant();
                }
            }
            catch { }
            try
            {
                var tp = go.GetPart<XRL.World.Parts.TorchProperties>();
                if (tp != null && (tp.ChangeColorString || tp.ChangeDetailColor))
                {
                    var ls = go.GetPart<XRL.World.Parts.LightSource>();
                    if (ls != null && ls.Lit) return "fire";
                }
            }
            catch { }
            return null;
        }

        /// True when a display name carries no actual NOUN — only markup, badges and
        /// punctuation (the worn-armour case: "{{b|<0x04>}}1 {{K|\t}}0").
        private static bool QudText_LooksNameless(string s)
        {
            if (string.IsNullOrEmpty(s)) return true;
            bool depth = false;
            int letters = 0;
            for (int i = 0; i < s.Length; i++)
            {
                if (i + 1 < s.Length && s[i] == '{' && s[i + 1] == '{') { depth = true; i++; continue; }
                if (s[i] == '|' && depth) { depth = false; continue; }
                if (i + 1 < s.Length && s[i] == '}' && s[i + 1] == '}') { i++; continue; }
                if (!depth && char.IsLetter(s[i])) letters++;
            }
            return letters < 2;
        }

        private static void Export()
        {
            GameObject p = null;
            try { p = XRL.The.Player; } catch { }
            if (p == null) return;

            var j = new JsonWriter();
            j.BeginObject();
            // QUD'S REAL PALETTE, shipped with the screen data. It normally rides on a
            // zone snapshot, but the status panes are built from these files and can
            // render before one has arrived — and the client's fallback table is only an
            // approximation ('w' there is a dark orange; Qud's is a khaki). That single
            // wrong entry was repainting every equipped item on the paper doll.
            WritePalette(j);
            // header, Qud's own strings (InventoryAndEquipmentStatusScreen.UpdateViewFromData)
            try { j.Member("drams", p.GetFreeDrams()); } catch { }
            try { j.Member("carried", p.GetCarriedWeight()); } catch { }
            try { j.Member("maxCarried", p.GetMaxCarriedWeight()); } catch { }

            // group by Qud's inventory category, like the screen's objectCategories
            var cats = new Dictionary<string, List<GameObject>>();
            try
            {
                var inv = p.Inventory;
                if (inv != null)
                    foreach (GameObject go in inv.GetObjectsDirect())
                    {
                        if (go == null) continue;
                        string cat = "Miscellaneous";
                        try { cat = go.GetInventoryCategory() ?? cat; } catch { }
                        if (!cats.ContainsKey(cat)) cats[cat] = new List<GameObject>();
                        cats[cat].Add(go);
                    }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] inventory scan: " + e.Message); }

            // BODY PARTS (the paper doll): Qud's own body tree — each part's name,
            // type and whatever is equipped there (EquipmentLine renders the same set).
            j.Name("slots").BeginArray();
            try
            {
                var body = p.Body;
                if (body != null)
                    foreach (BodyPart bp in body.GetParts())
                    {
                        if (bp == null) continue;
                        j.BeginObject();
                        // the PART's own id, on every slot including the empty ones: an empty
                        // slot has no object to name, and Qud's equip picker is addressed by
                        // body part, not by item
                        try { j.Member("part", bp.ID); } catch { }
                        try { j.Member("name", bp.Name ?? ""); } catch { }
                        try { j.Member("type", bp.Type ?? ""); } catch { }
                        try { j.Member("desc", bp.GetOrdinalName() ?? ""); } catch { }
                        try { j.Member("primary", bp.Primary); } catch { }
                        // EquipmentLine.setData, verbatim: the slot shows
                        //     Equipped ?? DefaultBehavior
                        // and when it falls through to DefaultBehavior it renders
                        // GreyOutForUI()'d -- which is why a mutant claw appears in the
                        // doll as a DARK TEAL ghost rather than not at all. An earlier
                        // note here claimed Qud leaves those slots empty; that came from
                        // a parity leaf reading 0 ink, which is what a brightness-
                        // thresholded ink mask reports for a sprite painted in 'K'.
                        // Qud greys the same way when an item is equipped across several
                        // parts and this is not the FIRST of them (the off-hand of a
                        // two-handed weapon), so mirror that too.
                        GameObject eq = null;
                        bool greyed = false;
                        try { eq = bp.Equipped; } catch { }
                        if (eq == null) { try { eq = bp.Cybernetics; } catch { } }
                        if (eq == null)
                        {
                            try { eq = bp.DefaultBehavior; greyed = eq != null; } catch { }
                        }
                        else
                        {
                            try
                            {
                                var on = new List<BodyPart>();
                                bp.ParentBody.GetPartsEquippedOn(eq, on);
                                if (on.Count > 0 && on[0] != bp) greyed = true;
                            }
                            catch { }
                        }
                        if (eq != null)
                        {
                            try { j.Member("item", eq.DisplayName ?? ""); } catch { }
                            try { j.Member("id", eq.ID ?? ""); } catch { }
                            if (greyed) j.Member("greyed", true);
                            // the PAPER DOLL uses Qud's "Equipment" render context
                            // (EquipmentLine: RenderForUI("Equipment")) — a different tile
                            // and colours than the "Inventory" context the list uses
                            WriteTile(j, eq, "Equipment", greyed);
                        }
                        // THE CYBERNETICS VIEW (EquipmentLine.showCybernetics, toggled by the
                        // framework "Toggle" command): the same doll showing each part's IMPLANT.
                        // Exported as its own member — the fallback above only surfaces an
                        // implant when nothing is Equipped over it, and the view swap must not
                        // need a re-export.
                        GameObject cyb = null;
                        try { cyb = bp.Cybernetics; } catch { }
                        if (cyb != null)
                        {
                            j.Name("cyber").BeginObject();
                            try { j.Member("item", cyb.DisplayName ?? ""); } catch { }
                            try { j.Member("id", cyb.ID ?? ""); } catch { }
                            WriteTile(j, cyb, "Equipment", false);
                            j.EndObject();
                        }
                        j.EndObject();
                    }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] body scan: " + e.Message); }
            j.EndArray();

            // FILTER-STRIP ORDER, Qud's way: its item list is sorted by sortString (the
            // item's stripped lowercase DISPLAY NAME, globally — not by category), and
            // filterBarCategories collects each category on FIRST APPEARANCE in that list.
            // So the strip order is "category of the alphabetically-first item", which is
            // nothing like the alphabetical category order the list itself uses.
            try
            {
                var flat = new List<KeyValuePair<string, string>>();   // name -> category
                var invOrder = p.Inventory;
                if (invOrder != null)
                    foreach (GameObject go in invOrder.GetObjectsDirect())
                    {
                        if (go == null) continue;
                        string c2 = "Miscellaneous", n2 = "";
                        try { c2 = go.GetInventoryCategory() ?? c2; } catch { }
                        try { n2 = (go.DisplayNameOnlyStripped ?? "").ToLowerInvariant(); } catch { }
                        flat.Add(new KeyValuePair<string, string>(n2, c2));
                    }
                // EQUIPPED items count too: Qud's filter list is built from the screen's
                // whole object list, which includes what's on the body — so a category
                // only worn (armour, a wielded blade) still gets a strip cell, and its
                // item name participates in the first-appearance ordering.
                try
                {
                    var body2 = p.Body;
                    if (body2 != null)
                        foreach (BodyPart bp in body2.GetParts())
                        {
                            GameObject eq = null;
                            try { eq = bp.Equipped; } catch { }
                            if (eq == null) continue;
                            string ec = "Miscellaneous", en = "";
                            try { ec = eq.GetInventoryCategory() ?? ec; } catch { }
                            try { en = (eq.DisplayNameOnlyStripped ?? "").ToLowerInvariant(); } catch { }
                            bool dup = false;
                            foreach (var f2 in flat) if (f2.Key == en && f2.Value == ec) { dup = true; break; }
                            if (!dup) flat.Add(new KeyValuePair<string, string>(en, ec));
                        }
                }
                catch { }
                // NOT sorted: Qud's filter bar follows the inventory's own object order
                // (first appearance while walking the pack), which is why its strip reads
                // Water Containers, Light Sources, Melee Weapons, Tools… rather than any
                // alphabetical sequence. Sorting by name produced a different order.
                var seen = new List<string>();
                foreach (var kv in flat)
                    if (!seen.Contains(kv.Value)) seen.Add(kv.Value);
                // objects, not bare names: a category can be EQUIPPED-ONLY (e.g. Clothes)
                // and so have no list entry to borrow an icon from
                // The strip's LIVE colours, per category. FilterBarCategoryButton.LateUpdate
                // paints `background` from four states -- enabled+focused #FFFFFF, enabled
                // #858951, focused #4A757E, else #134F4E -- but ONLY when the state changes,
                // so a button nobody has ever toggled keeps its prefab colour instead. That
                // is unmodellable from outside: whether a cell is #134F4E or prefab depends
                // on the save's whole interaction history. Read what each button IS.
                var filterColors = new Dictionary<string, string>();
                try
                {
                    foreach (var fb in UnityEngine.Resources.FindObjectsOfTypeAll<Qud.UI.FilterBarCategoryButton>())
                    {
                        if (fb == null || fb.background == null) continue;
                        if (!fb.gameObject.activeInHierarchy) continue;   // pooled copies lie
                        if (string.IsNullOrEmpty(fb.category)) continue;
                        var c = fb.background.color;
                        filterColors[fb.category] = string.Format("#{0:x2}{1:x2}{2:x2}",
                            (int)(c.r * 255f), (int)(c.g * 255f), (int)(c.b * 255f));
                    }
                }
                catch (Exception fe) { System.Console.WriteLine("[raves] filter colours: " + fe.Message); }

                j.Name("filterOrder").BeginArray();
                foreach (string n in seen)
                {
                    j.BeginObject();
                    j.Member("name", n);
                    string fcol;
                    if (filterColors.TryGetValue(n, out fcol)) j.Member("color", fcol);
                    try
                    {
                        string ic;
                        if (Qud.UI.FilterBarCategoryButton.categoryImageMap.TryGetValue(n, out ic)
                            && !string.IsNullOrEmpty(ic))
                        {
                            TileExporter.Ensure(ic);
                            j.Member("icon", ic);
                        }
                    }
                    catch { }
                    j.EndObject();
                }
                j.EndArray();
                // and the "*All" cell, which is a FilterBarCategoryButton like any other
                try
                {
                    string allCol;
                    if (filterColors.TryGetValue("*All", out allCol)) j.Member("allColor", allCol);
                }
                catch { }
            }
            catch (Exception e) { System.Console.WriteLine("[raves] filter order: " + e.Message); }

            // WHICH filters are currently ON. Qud persists the enabled set with the
            // save, so the strip comes back olive on the same categories after a
            // restart — without this, Raves always drew "ALL" and its cell colours
            // could never match. Read it off the live buttons rather than the
            // FilterBar, since several screens own a bar and the button is the thing
            // that actually paints (FilterBarCategoryButton.categoryEnabled).
            try
            {
                j.Name("enabledFilters").BeginArray();
                var btns = UnityEngine.Resources.FindObjectsOfTypeAll<Qud.UI.FilterBarCategoryButton>();
                if (btns != null)
                    foreach (var b in btns)
                    {
                        if (b == null || !b.categoryEnabled) continue;
                        if (string.IsNullOrEmpty(b.category)) continue;
                        j.Value(b.category);
                    }
                j.EndArray();
            }
            catch (Exception e) { System.Console.WriteLine("[raves] enabled filters: " + e.Message); }

            var names = new List<string>(cats.Keys);
            names.Sort(StringComparer.OrdinalIgnoreCase);
            j.Name("categories").BeginArray();
            foreach (string cat in names)
            {
                List<GameObject> items = cats[cat];
                items.Sort((a, b) =>
                {
                    string an = "", bn = "";
                    try { an = a.DisplayNameOnlyStripped ?? ""; } catch { }
                    try { bn = b.DisplayNameOnlyStripped ?? ""; } catch { }
                    return string.Compare(an, bn, StringComparison.OrdinalIgnoreCase);
                });
                int catWeight = 0;
                foreach (GameObject go in items) { try { catWeight += go.Weight; } catch { } }
                j.BeginObject();
                j.Member("name", cat).Member("weight", catWeight).Member("count", items.Count);
                // Qud's OWN filter-bar icon for this category (FilterBarCategoryButton's
                // static categoryImageMap) plus the fixed two-tone it paints them with.
                try
                {
                    string icon;
                    if (Qud.UI.FilterBarCategoryButton.categoryImageMap.TryGetValue(cat, out icon)
                        && !string.IsNullOrEmpty(icon))
                    {
                        TileExporter.Ensure(icon);
                        j.Member("icon", icon);
                    }
                }
                catch { }
                j.Name("items").BeginArray();
                foreach (GameObject go in items)
                {
                    j.BeginObject();
                    // DisplayName = GetDisplayNameEvent over (Render.DisplayName ?? Blueprint):
                    // for some worn items that base is empty and only the AV/DV badges come
                    // back, so fall back to the explicit full overload, then the short name.
                    string nm = "";
                    try { nm = go.DisplayName ?? ""; } catch { }
                    try
                    {
                        if (QudText_LooksNameless(nm))
                        {
                            string alt = go.GetDisplayName(int.MaxValue);
                            if (!QudText_LooksNameless(alt)) nm = alt;
                        }
                    }
                    catch { }
                    try
                    {
                        if (QudText_LooksNameless(nm))
                        {
                            string alt2 = go.DisplayNameOnly;
                            if (!QudText_LooksNameless(alt2)) nm = alt2;
                        }
                    }
                    catch { }
                    try { if (QudText_LooksNameless(nm)) nm = go.Blueprint ?? nm; } catch { }
                    j.Member("name", nm);
                    try { j.Member("weight", go.Weight); } catch { }
                    // go.ID, not IDIfAssigned: the latter is null until something has
                    // caused Qud to assign one, and 13 of 14 items in a normal pack have
                    // never been asked -- so every row shipped without a handle and the
                    // interaction popup could not be opened for any of them. ID just
                    // persists the object's existing BaseID; it invents no identity.
                    try { j.Member("id", go.ID ?? ""); } catch { }
                    WriteTile(j, go);
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();

            Directory.CreateDirectory(Root);
            File.WriteAllText(Path.Combine(Root, "inventory.json"), j.ToString(), new UTF8Encoding(false));
        }
    }
}

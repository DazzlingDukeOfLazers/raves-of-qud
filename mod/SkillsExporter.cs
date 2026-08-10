using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL.UI;
using XRL.UI.Framework;   // (APIDispatch retired here 2026-08-10 — the turn thread is the right one)
using XRL.World;
using XRL.World.Skills;   // PowerEntry / PowerEntryRequirement

namespace RavesOfQud
{
    /// <summary>
    /// Export the SKILLS &amp; POWERS tree — categories, their powers, costs, learned
    /// state, per-node detail text — to <c>skills.json</c> for Raves' Skills tab.
    ///
    /// Mirrors Qud's own screen rather than re-deriving anything: the row text is
    /// <c>SPNode.ModernUIText(player)</c> VERBATIM (it already encodes every colour
    /// rule — {{W|}} learned skill, {{w|}} unlearned, [{{C|}}sp] affordable vs
    /// [{{R|}}sp] not, {{G|:power}} learned power, requirement/exclusion tails), and
    /// the detail pane mirrors SkillsAndPowersStatusScreen.UpdateDetailsFromNode
    /// (learned banner, ":: cost SP ::" line, requirement list with [none]).
    /// Client-side we only resolve the markup through the palette — no colour logic.
    /// </summary>
    public static class SkillsExporter
    {
        private static string Root
        {
            get
            {
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, "Library", "Application Support", "RavesOfQud");
            }
        }

        public static void ReExport()
        {
            try { Export(); }
            catch (Exception e) { System.Console.WriteLine("[raves] skills export failed: " + e.Message); }
        }

        /// Qud's detail-pane cost + requirement block (UpdateDetailsFromNode, verbatim).
        private static string DetailRequirements(SPNode node, GameObject GO)
        {
            var sb = new StringBuilder();
            SPNode.LearnedStatus st = node.IsLearned(GO);
            if (st == SPNode.LearnedStatus.Learned) { }
            else if (node.Skill != null)
                sb.Append(GO.GetStatValue("SP") >= node.Skill.Cost
                    ? $":: {{{{C|{node.Skill.Cost}}}}} SP ::" : $":: {{{{R|{node.Skill.Cost}}}}} SP ::");
            else if (node.Power != null)
                sb.Append(GO.GetStatValue("SP") >= node.Power.Cost
                    ? $":: {{{{C|{node.Power.Cost}}}}} SP ::" : $":: {{{{R|{node.Power.Cost}}}}} SP ::");
            if (st == SPNode.LearnedStatus.None && node.Power != null && node.Power.requirements != null)
            {
                int n = 0;
                foreach (PowerEntryRequirement req in node.Power.requirements)
                {
                    sb.Append(n == 0 ? "\n:: " : " or \n:: ");
                    n++;
                    try { req.Render(GO, sb); } catch { }
                    sb.Append(" ::\n");
                }
            }
            return sb.ToString();
        }

        /// Raves picked a row: run QUD'S OWN accept (SkillsAndPowersScreen.SelectNode —
        /// it owns the whole purchase flow, including the "purchase the required skill?"
        /// / "already have that" / "not enough SP" popups, which mirror to Raves), or
        /// toggle a category's expand state (SkillsAndPowersLine.XAxis / ExpanderClicked).
        ///
        /// THE ACCEPT PATH RUNS ON THE TURN THREAD, and that is the whole bug (2026-08-10,
        /// reported as "clicking on a skill instabuys it — a popup pops up, but it goes
        /// away right away"). This is INVENTORY'S BUG, EXACTLY (see InventoryExporter.Twiddle's
        /// long note, 2026-08-08); the same wrong pattern survived here because the two were
        /// written a week apart and only one got the lesson. The comment this replaces even
        /// recorded the wrong conclusion — "must run on the GAME thread via APIDispatch".
        ///
        /// `APIDispatch.RunAndWaitAsync` runs its delegate on a THREADPOOL thread (Task.Run),
        /// which is right for Qud's own caller (the status screen has already parked the turn
        /// thread) and wrong for ours: a bridge-driven select leaves the turn thread free and
        /// spinning in XRLCore.PlayerTurn's wait-for-input loop, which executes
        ///     GameManager.Instance.CurrentGameView = Options.StageViewID;
        /// unconditionally every iteration. SelectNode's closing
        /// `Popup.ShowYesNo("Are you sure you want to buy X for N sp?")` PUSHES the
        /// PopupMessage view; the next loop iteration slams it back to Stage, UpdateView
        /// hides the popup, Hide() fires onHide -> TrySetCanceled, the Wait() throws inside
        /// an `async void` where nothing can catch it, and ShowYesNo returns its untouched
        /// default — Yes. So the confirm flashes up, vanishes, and the skill is bought with
        /// the player's points. Irreversible, and never actually answered by anyone.
        ///
        /// gameQueue drains inside Keyboard.getvk(pumpActions: true) — the turn thread's own
        /// input wait — so the modal opens ON that thread, the loop is inside it rather than
        /// racing it, and nothing re-asserts the Stage view underneath. Do NOT reintroduce
        /// APIDispatch here.
        public static void Select(int index, string mode)
        {
            var gm = GameManager.Instance;
            if (gm == null) return;

            if (mode == "toggle")
            {
                // Pure UI state (an expand flag) with no modal: the uiQueue is right for it,
                // and it keeps working while Qud sits on one of its own screens.
                if (gm.uiQueue == null) return;
                gm.uiQueue.queueTask(() =>
                {
                    try
                    {
                        List<SPNode> nodes = SkillsAndPowersScreen.Nodes;
                        if (nodes == null || index < 0 || index >= nodes.Count) return;
                        SPNode node = nodes[index];
                        if (node == null) return;
                        // a power row toggles ITS CATEGORY, like Qud's XAxis does
                        SPNode target = node.Skill != null ? node : node.ParentNode;
                        if (target != null) target.Expand = !target.Expand;
                        System.Console.WriteLine("[raves] skills toggle " + (target != null ? target.Name : "?"));
                        Bridge.PumpSyncContext(4);
                        ReExport();
                    }
                    catch (Exception e) { System.Console.WriteLine("[raves] skills toggle error: " + e.Message); }
                }, 0);
                return;
            }

            if (gm.gameQueue == null) return;
            // REFUSE rather than queue into a queue nobody is draining — Twiddle's rule, and
            // it matters more here: a silently-queued PURCHASE fires later against whatever
            // row the index resolves to by then.
            string parkedView;
            if (!Bridge.GameQueueDraining(out parkedView))
            {
                string msg = "skill select refused: Qud is on " + parkedView
                    + ", where the turn thread is parked and gameQueue never drains."
                    + " Leave that screen (hv back / hv goto qud in_game) and click again.";
                System.Console.WriteLine("[raves] " + msg);
                try { Bridge.Server?.Log(msg); } catch { }
                return;
            }
            // Singleton: two purchase confirms cannot be in flight at once.
            gm.gameQueue.queueSingletonTask("raves skill select", () =>
            {
                try
                {
                    GameObject p = XRL.The.Player;
                    if (p == null) return;
                    List<SPNode> nodes = SkillsAndPowersScreen.Nodes;
                    if (nodes == null || index < 0 || index >= nodes.Count) return;
                    SPNode node = nodes[index];
                    if (node == null) return;
                    System.Console.WriteLine("[raves] skills select " + node.Name);
                    try { SkillsAndPowersScreen.SelectNode(node, p); }
                    catch (Exception se) { System.Console.WriteLine("[raves] SelectNode: " + se.Message); }
                    ReExport();
                }
                catch (Exception e) { System.Console.WriteLine("[raves] skills select error: " + e.Message); }
            });
        }

        private static void Export()
        {
            GameObject p = null;
            try { p = XRL.The.Player; } catch { }
            if (p == null) return;

            // Qud's own tree, rebuilt for the player exactly like the screen's Show()
            // does (SkillsAndPowersScreen.BuildNodes(StatusScreensScreen.GO)) — so the
            // node list, ordering and expand state are Qud's, not ours.
            List<SPNode> nodes = null;
            try { SkillsAndPowersScreen.BuildNodes(p); } catch (Exception e) { System.Console.WriteLine("[raves] skills BuildNodes: " + e.Message); }
            try { nodes = SkillsAndPowersScreen.Nodes; } catch { }
            if (nodes == null) return;

            var j = new JsonWriter();
            j.BeginObject();
            j.Member("sp", p.GetStatValue("SP"));
            // the header stat strip (Qud shows the six mains above the tree)
            j.Name("stats").BeginObject();
            var names = new[] { "Strength", "Agility", "Toughness", "Intelligence", "Willpower", "Ego" };
            var keys = new[] { "STR", "AGI", "TOU", "INT", "WIL", "EGO" };
            for (int i = 0; i < names.Length; i++)
            {
                try { j.Member(keys[i], p.Stat(names[i])); } catch { j.Member(keys[i], 0); }
            }
            j.EndObject();

            j.Name("nodes").BeginArray();
            for (int ni = 0; ni < nodes.Count; ni++)
            {
                SPNode node = nodes[ni];
                if (node == null) continue;
                j.BeginObject();
                j.Member("idx", ni);   // index in QUD'S list — what a select/toggle sends back
                bool isSkill = node.Skill != null;
                j.Member("kind", isSkill ? "skill" : "power");
                try { j.Member("name", node.Name ?? ""); } catch { }
                // THE row markup, Qud's own — colours/costs/requirement tails included
                try { j.Member("text", node.ModernUIText(p) ?? ""); } catch { j.Member("text", ""); }
                try { j.Member("expand", node.Expand); } catch { }
                try { j.Member("visible", node.Visible); } catch { }
                try { j.Member("desc", node.Description ?? ""); } catch { }
                string learned = "None";
                try { learned = node.IsLearned(p).ToString(); } catch { }
                j.Member("learned", learned);
                try { j.Member("cost", isSkill ? node.Skill.Cost : node.Power.Cost); } catch { }
                // CATEGORY rows carry Qud's own left/right column text
                // (SkillsAndPowersLine.setData verbatim): the name is re-coloured by
                // learned state, and the right column is the cost / "Learned [n/total]".
                if (isSkill)
                {
                    try
                    {
                        int total = 0, got = 0;
                        foreach (SPNode c in node.powers)
                        {
                            total++;
                            if (c.IsLearned(p) == SPNode.LearnedStatus.Learned) got++;
                        }
                        bool afford = p.GetStatValue("SP") >= node.Skill.Cost;
                        string costTag = (afford ? "{{g|[" : "{{r|[") + node.Skill.Cost + " sp]}}";
                        var st2 = node.IsLearned(p);
                        if (st2 == SPNode.LearnedStatus.None)
                        {
                            j.Member("left", node.Name ?? "");
                            j.Member("right", "Starting Cost " + costTag);
                        }
                        else if (st2 == SPNode.LearnedStatus.Partial)
                        {
                            j.Member("left", " {{g|" + node.Name + "}}");
                            j.Member("right", "Starting Cost " + costTag + $" [{got}/{total}]");
                        }
                        else
                        {
                            j.Member("left", " {{G|" + node.Name + "}}");
                            j.Member("right", $"{{{{g|Learned}}}} [{got}/{total}]");
                        }
                    }
                    catch { }
                }
                j.Member("detail", DetailRequirements(node, p));
                // the node's icon (skill/power sprite) — same tile pipeline as mutations
                try
                {
                    var ic = node.UIIcon;
                    if (ic != null)
                    {
                        string tile = ic.getTile();
                        if (!string.IsNullOrEmpty(tile))
                        {
                            TileExporter.Ensure(tile);
                            string col = ic.getTileColor();
                            if (string.IsNullOrEmpty(col)) col = ic.getColorString();
                            char dc = ic.getDetailColor();
                            j.Member("iconTile", tile).Member("iconColor", col ?? "")
                             .Member("iconDetail", dc == '\0' ? "" : dc.ToString());
                        }
                    }
                }
                catch { }
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();

            Directory.CreateDirectory(Root);
            File.WriteAllText(Path.Combine(Root, "skills.json"), j.ToString(), new UTF8Encoding(false));
        }
    }
}

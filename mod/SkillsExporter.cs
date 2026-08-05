using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using XRL.UI;
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
        /// Runs on the UI thread; re-exports after so Raves sees the new state.
        public static void Select(int index, string mode)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            gm.uiQueue.queueTask(() =>
            {
                try
                {
                    GameObject p = XRL.The.Player;
                    if (p == null) return;
                    List<SPNode> nodes = SkillsAndPowersScreen.Nodes;
                    if (nodes == null || index < 0 || index >= nodes.Count) return;
                    SPNode node = nodes[index];
                    if (node == null) return;
                    if (mode == "toggle")
                    {
                        // a power row toggles ITS CATEGORY, like Qud's XAxis does
                        SPNode target = node.Skill != null ? node : node.ParentNode;
                        if (target != null) target.Expand = !target.Expand;
                        System.Console.WriteLine("[raves] skills toggle " + (target != null ? target.Name : "?"));
                    }
                    else
                    {
                        SkillsAndPowersScreen.SelectNode(node, p);
                        System.Console.WriteLine("[raves] skills select " + node.Name);
                    }
                    Bridge.PumpSyncContext(4);
                    ReExport();
                }
                catch (Exception e) { System.Console.WriteLine("[raves] skills select error: " + e.Message); }
            }, 0);
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

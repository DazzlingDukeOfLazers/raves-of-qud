using System;
using XRL;                       // The
using XRL.World;                 // Cell, GameObject, Zone
using XRL.World.AI.GoalHandlers; // MoveTo
using XRL.World.Capabilities;    // AutoAct
using ConsoleLib.Console;        // Keyboard.PushCommand

namespace RavesOfQud
{
    /// <summary>
    /// Qud's click-to-travel: walk the player to a cell in the current zone.
    ///
    /// DRIVEN THROUGH QUD'S OWN GOAL, not a hand-rolled walk. `Brain.PushGoal(new MoveTo(cell))`
    /// is the same handler Qud's own navigation pushes, so pathfinding weights, doors, hostiles
    /// interrupting the travel, and the "you are interrupted" message all behave identically to
    /// Qud for free. Stepping a path here would look right until something attacked, and 1:1 is
    /// the whole point. (API read off the shipped assembly, not guessed:
    /// XRL.World.AI.GoalHandlers.MoveTo(Cell, bool careful = false, ...) and
    /// XRL.World.Parts.Brain.PushGoal(GoalHandler).)
    ///
    /// THREADING. This mutates game state, so it runs on the TURN thread via
    /// `gameQueue.queueSingletonTask` — the same channel `InventoryExporter.Twiddle` uses, and
    /// for the same reason recorded there: an APIDispatch/threadpool call races the turn thread
    /// instead of running inside its input wait. Singleton because two travel goals in flight at
    /// once is never what a second click means — the newer click should win, and Qud's own goal
    /// stack is what decides that, not us queueing both.
    /// </summary>
    public static class Navigator
    {
        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        /// <summary>Queue a walk to zone cell (x,y). Returns false only for reasons we can see
        /// from HERE — the queue being absent. Whether the path exists is Qud's answer, and it
        /// arrives later on the turn thread, so it is logged rather than returned.</summary>
        public static bool MoveToCell(int x, int y)
        {
            var gm = GameManager.Instance;
            if (gm == null || gm.gameQueue == null) { Log("[nav] no gameQueue"); return false; }
            gm.gameQueue.queueSingletonTask("raves moveto", () =>
            {
                try
                {
                    GameObject p = The.Player;
                    if (p == null) { Log("[nav] no player"); return; }
                    Zone z = p.CurrentZone;
                    if (z == null) { Log("[nav] no zone"); return; }
                    if (x < 0 || y < 0 || x >= z.Width || y >= z.Height)
                    { Log("[nav] cell " + x + "," + y + " is outside the zone"); return; }

                    Cell target = z.GetCell(x, y);
                    if (target == null) { Log("[nav] no cell at " + x + "," + y); return; }

                    // Clicking where you already stand is a no-op, not a zero-length goal.
                    Cell here = p.CurrentCell;
                    if (here != null && here.X == x && here.Y == y)
                    { Log("[nav] already on " + x + "," + y); return; }

                    if (p.Brain == null) { Log("[nav] player has no Brain"); return; }
                    p.Brain.PushGoal(new MoveTo(target));
                    // AND LET TURNS ELAPSE. The goal alone is not enough for the PLAYER: the
                    // turn loop parks waiting for input, so the walk only advances when
                    // something takes a turn. Measured -- pushing the goal and then sending
                    // five CmdWaits walked (40,24) to (44,20) exactly, while the goal on its
                    // own sat still indefinitely. `AutoAct.Setting` is what makes Qud advance
                    // turns by itself; any value outside {'.','g','o','r','z'} reads as
                    // MOVEMENT to AutoAct.IsMovement, which is the class that gets interrupted
                    // by hostiles -- the behaviour we want inherited rather than reimplemented.
                    AutoAct.Setting = "M";
                    // ONE turn to unpark the loop. Measured, all three states: the goal alone
                    // never moves (the loop sits in its input wait and nothing re-checks);
                    // goal + AutoAct alone never moves either, for the same reason; goal +
                    // AutoAct + a SINGLE CmdWait walked (40,24) to (48,15) with nothing else
                    // sent, because once a turn elapses AutoAct keeps taking them. So this is
                    // a kick, not a loop -- we are not stepping the path, Qud is.
                    Keyboard.PushCommand("CmdWait", null);
                    Log("[nav] moveto " + x + "," + y
                        + (here != null ? " from " + here.X + "," + here.Y : ""));
                }
                catch (Exception e) { Log("[nav] moveto error: " + e.Message); }
            });
            return true;
        }
    }
}

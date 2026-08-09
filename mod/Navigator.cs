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
    /// THREADING — AND WHY NOT gameQueue. Mutating game state needs the turn thread, and the
    /// obvious channel is `GameManager.Instance.gameQueue.queueSingletonTask` (what
    /// InventoryExporter.Twiddle uses). It works, and it is WRONG HERE: that queue is drained by
    /// Unity's main loop, which stops while the window is in the background. Raves in front means
    /// Qud in the background, which is the normal case for every click the player makes — so the
    /// task simply never ran. Measured, with Qud unfocused: no log line at all for 8s, then the
    /// walk happening the moment Qud came forward. It never looked broken from outside, because a
    /// TCP write to a mod whose queue is parked still succeeds.
    ///
    /// So the target is PARKED here and applied from `BeginTakeActionEvent` (Bridge.TickAction ->
    /// Pump), which fires on the TURN thread and keeps firing unfocused. The kick that gets a turn
    /// started is `Keyboard.PushCommand`, the same carrier the arrow keys already use from this
    /// same socket thread — the one input path proven to reach a backgrounded Qud.
    /// </summary>
    public static class Navigator
    {
        private static void Log(string s) { try { Bridge.Server?.Log(s); } catch { } }

        // The parked target. Written from the socket thread, read + cleared on the turn thread;
        // an int pair behind a lock rather than a Cell, so nothing hands a game object across
        // threads. -1 = nothing pending.
        private static readonly object _lock = new object();
        private static int _wantX = -1, _wantY = -1;

        /// <summary>Ask for a walk to zone cell (x,y). Returns immediately: this only parks the
        /// target and wakes the turn loop. Whether a path exists is Qud's answer and it arrives
        /// later, on the turn thread, so it is logged rather than returned.</summary>
        public static bool MoveToCell(int x, int y)
        {
            lock (_lock) { _wantX = x; _wantY = y; }
            // Wake the parked input loop so a player action begins and Pump gets its turn thread.
            // Unfocused-safe: this is Qud's legacy console queue, which the turn thread drains
            // whatever Unity's main loop is doing.
            Keyboard.PushCommand("CmdWait", null);
            return true;
        }

        /// <summary>Apply a parked target. TURN THREAD ONLY — called from BeginTakeAction.</summary>
        public static void Pump(GameObject player)
        {
            int x, y;
            lock (_lock)
            {
                if (_wantX < 0) return;
                x = _wantX; y = _wantY;
                _wantX = -1; _wantY = -1;
            }
            try
            {
                if (player == null) { Log("[nav] no player"); return; }
                Zone z = player.CurrentZone;
                if (z == null) { Log("[nav] no zone"); return; }
                if (x < 0 || y < 0 || x >= z.Width || y >= z.Height)
                { Log("[nav] cell " + x + "," + y + " is outside the zone"); return; }

                Cell target = z.GetCell(x, y);
                if (target == null) { Log("[nav] no cell at " + x + "," + y); return; }

                // Clicking where you already stand is a no-op, not a zero-length goal.
                Cell here = player.CurrentCell;
                if (here != null && here.X == x && here.Y == y)
                { Log("[nav] already on " + x + "," + y); return; }

                if (player.Brain == null) { Log("[nav] player has no Brain"); return; }
                player.Brain.PushGoal(new MoveTo(target));
                // AND LET TURNS ELAPSE. The goal alone is not enough for the PLAYER: the turn loop
                // parks waiting for input, so the walk only advances when something takes a turn.
                // `AutoAct.Setting` is what makes Qud keep taking them by itself; any value outside
                // {'.','g','o','r','z'} reads as MOVEMENT to AutoAct.IsMovement, which is the class
                // that gets interrupted by hostiles -- the behaviour we want inherited rather than
                // reimplemented. Measured: goal alone never moves, goal + AutoAct + one turn walks
                // the whole path. We are not stepping it; Qud is.
                AutoAct.Setting = "M";
                Log("[nav] moveto " + x + "," + y
                    + (here != null ? " from " + here.X + "," + here.Y : ""));
            }
            catch (Exception e) { Log("[nav] moveto error: " + e.Message); }
        }
    }
}

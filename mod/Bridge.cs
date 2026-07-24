using System;
using XRL;        // The, IPlayerMutator, IEventRegistrar
using XRL.World;  // GameObject, Zone, Cell, CommandEvent, EndTurnEvent

namespace RavesOfQud
{
    // ========================================================================
    //  QUD-COUPLED CODE.  Everything the bridge touches in the game lives in
    //  this file, BridgePart.cs, and ZoneSnapshot.cs — nowhere else.
    //  Re-targeting a new Qud patch = fixing symbols in these three spots.
    //
    //  VERIFIED against the installed 1.0 build by reflecting Assembly-CSharp.dll
    //  (exact signatures, not string guesses):
    //    - XRL.The.ActiveZone / The.Player
    //    - Movement command IDs "CmdMoveN/S/E/W/NE/NW/SE/SW" (Commands.xml)
    //    - XRL.World.CommandEvent.Send(actor, command, target, cell, standoff,
    //        forced, silent, handler) — no 2-arg overload; pass nulls/defaults.
    //    - GameObject.GetPart<T>(), HasPart<T>(), AddPart(IPart)
    //    - Per-turn hook: pooled XRL.World.EndTurnEvent (has static .ID). See BridgePart.
    // ========================================================================

    /// <summary>Process-wide holder for the single bridge server + per-turn tick.</summary>
    public static class Bridge
    {
        private static BridgeServer _server;
        private static readonly object _gate = new object();

        public static BridgeServer Server
        {
            get
            {
                if (_server == null)
                {
                    lock (_gate)
                    {
                        if (_server == null)
                        {
                            var s = new BridgeServer(Protocol.DefaultPort);
                            // TODO(qud-api): route through Qud's logger if you prefer
                            // (e.g. MetricsManager.LogInfo). System.Console is safe.
                            s.Log = m => System.Console.WriteLine("[raves] " + m);
                            s.Start();
                            _server = s;
                        }
                    }
                }
                return _server;
            }
        }

        /// <summary>
        /// Runs on the GAME MAIN THREAD (called from BridgePart's per-turn hook):
        ///   1) drain queued commands from Godot and apply them,
        ///   2) publish the current zone snapshot back to Godot.
        /// </summary>
        public static void Tick(GameObject player)
        {
            BridgeServer server = Server;

            // (1) apply input — MAIN THREAD ONLY.
            while (server.Incoming.TryDequeue(out string json))
            {
                try { Apply(player, json); }
                catch (Exception e) { server.Log("apply error: " + e.Message); }
            }

            // (2) snapshot — read state on the main thread, hand bytes to the socket.
            try
            {
                string snap = ZoneSnapshot.BuildJson(player);
                server.Publish(Protocol.Frame(snap));
            }
            catch (Exception e) { server.Log("snapshot error: " + e.Message); }
        }

        private static void Apply(GameObject player, string json)
        {
            var f = MiniJson.ParseFlat(json);
            f.TryGetValue("name", out string name);
            switch (name)
            {
                case "move":
                    f.TryGetValue("dir", out string dir);
                    Step(player, dir);
                    break;
                case "shot":
                    QueueScreenshot();
                    break;
                // Extend: "activate", "wait", "getUp", ... route each through Qud.
                default:
                    break;
            }
        }

        /// <summary>
        /// Have Qud screenshot ITSELF, next to the exported tiles.
        ///
        /// The OS screencapture needs Screen Recording permission the agent doesn't
        /// have, so this is how a collaborator gets to see the game. Same rule as
        /// tile export: ScreenCapture is a graphics call, so it must be marshalled
        /// to the main thread via uiQueue — calling it here would crash the game.
        /// The file appears at end-of-frame, not immediately.
        /// </summary>
        private static void QueueScreenshot()
        {
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            string path;
            try
            {
                path = System.IO.Path.GetFullPath(
                    System.IO.Path.Combine(TileExporter.Dir, "..", "qud_shot.png"));
            }
            catch { return; }
            gm.uiQueue.queueTask(() =>
            {
                try { UnityEngine.ScreenCapture.CaptureScreenshot(path); }
                catch (Exception e) { Server.Log("screenshot: " + e.Message); }
            }, 0);
        }

        // Godot sends the 8 compass strings; Qud's command IDs are "CmdMove" + that.
        private static readonly System.Collections.Generic.HashSet<string> Dirs =
            new System.Collections.Generic.HashSet<string> { "N", "S", "E", "W", "NE", "NW", "SE", "SW" };

        private static void Step(GameObject player, string dir)
        {
            if (player == null || string.IsNullOrEmpty(dir) || !Dirs.Contains(dir)) return;

            // Route through the command system so doors/combat/NPC turns resolve
            // exactly as from a keypress. Verified overload:
            //   Send(Actor, Command, Target, TargetCell, StandoffDistance, Forced, Silent, Handler)
            CommandEvent.Send(player, "CmdMove" + dir, null, null, 0, false, false, null);
        }
    }
}

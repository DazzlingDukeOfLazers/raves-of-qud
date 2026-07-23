using System;
using XRL;
using XRL.World;
using XRL.World.Events; // CommandEvent (confirmed: World/Events/CommandEvent.cs)

namespace RavesOfQud
{
    // ========================================================================
    //  QUD-COUPLED CODE.  Everything the bridge touches in the game lives in
    //  this file, BridgePart.cs, and ZoneSnapshot.cs — nowhere else.
    //  Re-targeting a new Qud patch = fixing symbols in these three spots.
    //
    //  CONFIRMED against the installed 1.0 build (Assembly-CSharp.dll metadata):
    //    - The.ActiveZone (get_ActiveZone), The.Player
    //    - Movement command IDs are "CmdMoveN/S/E/W/NE/NW/SE/SW" (Commands.xml)
    //    - CommandEvent exists (World/Events/CommandEvent.cs) — the right way to
    //      inject a command so combat/doors/NPC turns resolve like a keypress.
    //    - GameObject.GetFirstPart<T>() (GetPart<T> not present), AddPart
    //  STILL CONFIRM in ILSpy (signatures/overloads, not just names):
    //    - IPart.Register(GameObject, IEventRegistrar) + FireEvent(Event) shape,
    //      and the "EndTurn" event name (or pooled EndTurnEvent). See BridgePart.
    //    - CommandEvent.Send(...) exact signature (see Step() below).
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
                // Extend: "activate", "wait", "getUp", ... route each through Qud.
                default:
                    break;
            }
        }

        // Godot sends the 8 compass strings; Qud's command IDs are "CmdMove" + that.
        private static readonly System.Collections.Generic.HashSet<string> Dirs =
            new System.Collections.Generic.HashSet<string> { "N", "S", "E", "W", "NE", "NW", "SE", "SW" };

        private static void Step(GameObject player, string dir)
        {
            if (player == null || string.IsNullOrEmpty(dir) || !Dirs.Contains(dir)) return;

            // Route through the command system so doors/combat/NPC turns resolve
            // exactly as from a keypress. Command IDs confirmed in Commands.xml.
            // TODO(qud-api): confirm CommandEvent.Send's exact signature in ILSpy
            // (World/Events/CommandEvent.cs). Fallback if Send differs:
            //     player.FireEvent(Event.New("Command" + "CmdMove" + dir));
            CommandEvent.Send(player, "CmdMove" + dir);
        }
    }
}

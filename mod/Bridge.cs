using System;
using System.Threading;    // focus-keeper watchdog thread
using ConsoleLib.Console;  // Keyboard.PushCommand — wakes the main thread while unfocused
using XRL;        // The, IPlayerMutator, IEventRegistrar
using XRL.Core;   // XRLCore.IsCoreThread, The.Core.RenderBase
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
                            // Route commands the instant they arrive (background thread),
                            // so movement can wake an unfocused game (see OnPayload).
                            s.OnPayload = OnPayload;
                            s.Start();
                            _server = s;
                            StartFocusKeeper();
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
        private static bool _ranInBackground;

        public static void Tick(GameObject player)
        {
            BridgeServer server = Server;

            // Raves not connected? Do NOTHING. This turn hook otherwise runs on EVERY Qud
            // turn even when the viewer is closed — recompositing the map (RenderBase) and
            // building the full zone snapshot (~16ms) for bytes nobody reads, and flipping
            // Qud's global runInBackground/vsync. That made plain solo Qud sluggish on every
            // move. Gate the whole thing on a live client so the mod is inert without Raves.
            if (server == null || server.ClientCount == 0) return;

            // Keep Unity RENDERING the window while it's unfocused, so Qud's own map
            // repaints in sync with commands we drive from Godot. Unity pauses the
            // main-thread render loop for a backgrounded window unless runInBackground
            // is set — and Application.runInBackground is MAIN-THREAD ONLY. This Tick
            // runs on Qud's TURN thread (EndTurnEvent), so setting it here throws and
            // the old `catch {}` silently ate it, leaving the map frozen. Marshal it
            // onto the UI/main thread via uiQueue, which drains now (startup, focused).
            // (The focus-keeper thread handles the separate TURN-thread focus gate.)
            if (!_ranInBackground)
            {
                _ranInBackground = true;
                try
                {
                    GameManager gm = GameManager.Instance;
                    if (gm != null && gm.uiQueue != null)
                    {
                        gm.uiQueue.queueTask(() =>
                        {
                            try
                            {
                                UnityEngine.Application.runInBackground = true;
                                // Candidate fix: with vsync on, the present is paced by the
                                // focused display's refresh, which can stall for an unfocused
                                // window. Decouple present from vsync (targetFrameRate still caps).
                                UnityEngine.QualitySettings.vSyncCount = 0;
                                server.Log("[raves] runInBackground=" + UnityEngine.Application.runInBackground
                                    + " vSyncCount=" + UnityEngine.QualitySettings.vSyncCount
                                    + " targetFrameRate=" + UnityEngine.Application.targetFrameRate);
                            }
                            catch (Exception e) { server.Log("runInBackground set failed: " + e.Message); }
                        }, 0);
                    }
                }
                catch (Exception e) { server.Log("runInBackground marshal failed: " + e.Message); }
            }

            // (1) apply input — MAIN THREAD ONLY.
            while (server.Incoming.TryDequeue(out string json))
            {
                try { Apply(player, json); }
                catch (Exception e) { server.Log("apply error: " + e.Message); }
            }

            // Refresh Qud's OWN on-screen map. A move injected via PushCommand doesn't
            // reliably hit the CmdMove RenderBase path (gated on Options.DrawStepImmediately)
            // or the idle animation pump, so the on-screen tile mesh stayed stale even though
            // the game state advanced and the window kept rendering (~4fps unfocused) — it was
            // just re-drawing an un-refreshed buffer. RenderBase recomposites the buffer from
            // current state; it must run on the core thread, which this EndTurnEvent tick is.
            try
            {
                if (XRLCore.IsCoreThread && The.Core != null)
                    The.Core.RenderBase(UpdateSidebar: false);
            }
            catch (Exception e) { server.Log("renderbase error: " + e.Message); }

            // (2) snapshot — read state on the main thread, hand bytes to the socket.
            try
            {
                string snap = ZoneSnapshot.BuildJson(player);
                server.Publish(Protocol.Frame(snap));
            }
            catch (Exception e) { server.Log("snapshot error: " + e.Message); }
        }

        /// <summary>
        /// Runs EVERY rendered frame (BeforeRenderEvent), on the main thread, even while
        /// the player is idle at the input prompt. Drains + applies any commands that
        /// arrived from an external driver, and — if one applied while idle — publishes a
        /// snapshot immediately so the driver gets a response without waiting for a turn.
        /// </summary>
        public static void TickRender(GameObject player)
        {
            BridgeServer server = Server;
            bool applied = false;
            while (server.Incoming.TryDequeue(out string json))
            {
                try { Apply(player, json); applied = true; }
                catch (Exception e) { server.Log("apply error: " + e.Message); }
            }
            if (applied)
            {
                try { server.Publish(Protocol.Frame(ZoneSnapshot.BuildJson(player))); }
                catch (Exception e) { server.Log("snapshot error: " + e.Message); }
            }
        }

        /// <summary>
        /// Keep Qud's turn thread alive while the OS window is unfocused.
        ///
        /// XRLCore's player loop gates on `while (!GameManager.focused) Thread.Sleep(200)`,
        /// so a backgrounded window freezes the game outright and any injected command sits
        /// unprocessed until the window is foremost again. `GameManager.focused` is just a
        /// static flag (set false by OnApplicationFocus); we hold it true so the turn thread
        /// keeps servicing input — including our PushCommand injections — regardless of which
        /// window is focused. Gated on a connected client so normal solo play keeps Qud's
        /// default pause-on-unfocus. The false->true edge clears the input queue, so we
        /// re-assert focus within 50 ms of a focus loss (when nothing is pending) rather than
        /// at command time, and drive commands only once focus is already held.
        /// </summary>
        private static Thread _focusKeeper;

        private static void StartFocusKeeper()
        {
            if (_focusKeeper != null) return;
            _focusKeeper = new Thread(() =>
            {
                while (true)
                {
                    try
                    {
                        if (_server != null && _server.ClientCount > 0
                            && The.Game != null && !GameManager.focused)
                        {
                            GameManager.focused = true;
                        }
                    }
                    catch { /* transient game-state teardown; retry next tick */ }
                    Thread.Sleep(50);
                }
            })
            { IsBackground = true, Name = "RavesFocusKeeper" };
            _focusKeeper.Start();
        }

        /// <summary>
        /// Runs on the BACKGROUND socket read thread, the instant a command arrives.
        ///
        /// Movement is injected straight into Qud's input queue via Keyboard.PushCommand.
        /// That enqueues under a lock and Sets the KeyEvent the game's main thread is
        /// parked on inside getvk() — so the move is processed EVEN WHILE QUD IS UNFOCUSED.
        /// (A thread blocked in ManualResetEvent.WaitOne wakes regardless of window focus;
        /// our render-tied Tick/TickRender do NOT fire while the window is in the
        /// background, which is why draining Incoming from them can't drive an idle game.)
        /// PushCommand only touches a locked queue + the event, no game state, so it is
        /// safe off the main thread. The move then resolves through Qud's own command
        /// path, ends a turn, and Tick publishes the resulting snapshot as usual.
        ///
        /// Anything that genuinely needs the main thread (screenshots) is left on Incoming
        /// for Tick/TickRender to drain.
        /// </summary>
        private static void OnPayload(string json)
        {
            try
            {
                var f = MiniJson.ParseFlat(json);
                f.TryGetValue("name", out string name);
                if (name == "move")
                {
                    f.TryGetValue("dir", out string dir);
                    if (!string.IsNullOrEmpty(dir) && Dirs.Contains(dir))
                        Keyboard.PushCommand("CmdMove" + dir, null);
                    return;
                }
                if (name == "wait")
                {
                    // Wait one turn (Qud's CmdWait). Wakes the turn thread like a move, so it
                    // publishes a fresh snapshot even when the player is idle (used to prime the
                    // first render on load). NB: this DOES pass a turn.
                    Keyboard.PushCommand("CmdWait", null);
                    return;
                }
            }
            catch (Exception e) { try { Server.Log("onpayload error: " + e.Message); } catch { } }
            // not consumed inline -> hand to the main-thread drain
            Server.Incoming.Enqueue(json);
        }

        private static void Apply(GameObject player, string json)
        {
            var f = MiniJson.ParseFlat(json);
            f.TryGetValue("name", out string name);
            switch (name)
            {
                case "shot":
                    QueueScreenshot();
                    break;
                // Movement is handled on the socket thread (see OnPayload), so it can
                // drive an unfocused game. Extend here for main-thread-only commands.
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
        // Injected via Keyboard.PushCommand (OnPayload), which routes through Qud's own
        // input/command path — doors/combat/NPC turns resolve exactly as from a keypress.
        private static readonly System.Collections.Generic.HashSet<string> Dirs =
            new System.Collections.Generic.HashSet<string> { "N", "S", "E", "W", "NE", "NW", "SE", "SW" };
    }
}

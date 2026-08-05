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

        /// <summary>
        /// Drain Unity's SynchronizationContext by hand (private Exec(), reflection).
        /// macOS stops pumping posted continuations for an UNFOCUSED window even with
        /// runInBackground=true — async chains (popup callbacks, screen closes, keymap
        /// loads) then stall until the next focus. MAIN THREAD ONLY (uiQueue tasks are).
        /// </summary>
        /// Pump the sync context ACROSS frames: each uiQueue task drains it once and
        /// re-queues itself. Async Qud UI (StatusScreensScreen.show) resolves over
        /// several frames, so a single drain leaves it half-started.
        public static void PumpTrain(int frames)
        {
            if (frames <= 0) return;
            var gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            gm.uiQueue.queueTask(() =>
            {
                PumpSyncContext(2);
                PumpTrain(frames - 1);
            }, 0);
        }

        public static void PumpSyncContext(int n)
        {
            try
            {
                // QUD'S context, not SynchronizationContext.Current: inside a uiQueue task
                // Current can be null, so the old pump silently did nothing (an async
                // StatusScreensScreen.show() then hung forever with no fault logged).
                var sc = GameManager.Instance != null ? GameManager.Instance.uiSynchronizationContext : null;
                if (sc == null) sc = System.Threading.SynchronizationContext.Current;
                var exec = sc?.GetType().GetMethod("Exec",
                    System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
                if (exec == null && sc != null)
                    System.Console.WriteLine("[raves] sync pump: no Exec on " + sc.GetType().Name);
                for (int i = 0; i < n && exec != null; i++) exec.Invoke(sc, null);
            }
            catch (Exception e) { System.Console.WriteLine("[raves] sync pump: " + e.Message); }
        }

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
                            // On any client connect, force a snapshot publish. It only fires if a game is
                            // live (TickRender/TickAction run only then), so a fresh client gets current
                            // data at once — and a client can distinguish "game live" from "socket open at
                            // Qud's menu" without sending a turn-passing wait.
                            s.OnConnect = () => { ForcePublishSoon = true; PopupBridge.OnClientConnect(); };
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
        /// Microseconds the last RenderBase (Qud's own map recomposite) took; 0 if skipped.
        /// Sent in the snapshot so the client can see the mod's per-turn cost split.
        public static long LastRenderBaseUs;

        // --- Qud scanline suppression (1:1 test) ---------------------------------------------
        // Qud's "scanlines" are TWO independent effects, neither reachable from the in-game
        // OptionDisplayScanlines checkbox (it's read only in GameManager's screen-warp "Fuzzing"
        // branch, GameManager.cs:3017, never at startup/options-change) nor from Display.txt (its
        // `shaders` block is dead config — no code reads it):
        //   (a) CC_AnalogTV camera post-effect — always on, but at scanlinesCount=1853 it's
        //       sub-visible; zeroing scanlinesIntensity is correct-but-invisible.
        //   (b) THE VISIBLE ONES, via THREE mechanisms:
        //       - Modern-UI shader overlays: "UI/Textured-Overlay" multiplies each panel by an
        //         overlay grunge texture (_OverlayTex "distress-diagonal") tinted by _ColorOverlay;
        //         "UI/ThreeColorOffset" adds a per-row _Offset. Neutralise the tint + texture + offset.
        //       - SPRITE-based patterns on plain UI/Default Images: the bottom "AbilityBar" uses a
        //         sprite literally named "horizstripetexture" (THE command-bar scanlines), and a
        //         full-screen "Creases" uses a "creases" grunge sprite. Flatten a stripe image to a
        //         solid chrome-dark quad; hide a grunge overlay (alpha 0).
        //       All are screen-row-keyed and show THROUGH the translucent panels (the opaque play
        //       field hides them, so the world stays clean). We re-sweep on a throttle to catch
        //       late-created panels; originals captured per-material/image for restore.
        // Reversible via the flag so Raves can restore Qud's authentic look. Verified clean: top bar,
        // sidebars, and command bar all drop from even-odd dev ~10-17 to ~0-1.4. See
        // reports/1to1-qud-scanlines.md.
        public static bool DisableQudScanlines = true;    // 1:1 default: kill Qud's always-on scanlines
        private static bool _scanlineApplyPending;        // a uiQueue task is in flight
        private static bool? _scanlineAppliedValue;       // the value the camera currently reflects
        private static float _origScanlineIntensity = float.NaN;  // captured once, for restore

        /// Runs on the TURN THREAD at the start of each player action (BeginTakeActionEvent). Unlike the
        /// render-tied TickRender, this fires even while Qud is unfocused — so it can flush a publish
        /// queued off-turn (a direction prompt answered from Raves, e.g. Make Camp) as soon as the game
        /// unblocks, without waiting for a real turn.
        public static void TickAction(GameObject player)
        {
            BridgeServer server = Server;
            EnsureScanlineState();   // also drive scanline suppression off turns (renders can stall unfocused)
            if (server == null || server.ClientCount == 0) return;
            if (ForcePublishSoon)
            {
                ForcePublishSoon = false;
                PublishNow(player);
            }
        }

        public static void Tick(GameObject player)
        {
            BridgeServer server = Server;
            EnsureScanlineState();   // drive scanline suppression on every turn too, not just render frames

            // Raves not connected? Do NOTHING. This turn hook otherwise runs on EVERY Qud
            // turn even when the viewer is closed — recompositing the map (RenderBase) and
            // building the full zone snapshot (~16ms) for bytes nobody reads, and flipping
            // Qud's global runInBackground/vsync. That made plain solo Qud sluggish on every
            // move. Gate the whole thing on a live client so the mod is inert without Raves.
            if (server == null || server.ClientCount == 0) return;

            // One-shot: export Qud's title art (its MainMenu textures are still resident,
            // the GameObject just inactive) so Raves' menu can render the real assets.
            TitleExporter.Ensure();
            // One-shot: export the installed-mod list (ModManager.ModMap) for Raves' Mods screen.
            ModsExporter.Ensure();
            // One-shot: export Qud's full options tree (OptionsByCategory) for Raves' Options mirror.
            OptionsExporter.Ensure();
            // One-shot: export Qud's high-score records (Scoreboard2 / HighScores.json) for Raves' Records screen.
            RecordsExporter.Ensure();
            // One-shot: export Qud's character-creation data (genotypes, …) for Raves' chargen screens.
            ChargenExporter.Ensure();
            // Live: seed the character-sheet export when a game is up (re-run via "export").
            CharacterExporter.ReExport();

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
            // This recomposites Qud's WHOLE console and is not free. Skip it on the WORLD MAP
            // (z<0), where it was a chunk of the per-turn cost and the map barely changes step to
            // step; normal zones keep it so Qud's window / the F12 shot stay live. Timed into
            // LastRenderBaseUs so the client can see the cost.
            // The player's current zone, reused below: RenderBase skips on the world map (z<0),
            // and a change in it forces an immediate publish past the throttle (see (2)).
            string zid = null;
            bool worldMap = false;
            try
            {
                var pz = player != null && player.CurrentCell != null ? player.CurrentCell.ParentZone : null;
                if (pz != null) { zid = pz.ZoneID; worldMap = pz.Z < 0; }
            }
            catch (Exception e) { server.Log("zone read error: " + e.Message); }

            try
            {
                if (!worldMap && XRLCore.IsCoreThread && The.Core != null)
                {
                    var rw = System.Diagnostics.Stopwatch.StartNew();
                    The.Core.RenderBase(UpdateSidebar: false);
                    LastRenderBaseUs = (long)(rw.Elapsed.TotalMilliseconds * 1000.0);
                }
                else LastRenderBaseUs = 0;
            }
            catch (Exception e) { server.Log("renderbase error: " + e.Message); }

            // (2) snapshot — THROTTLED for same-zone bursts, but a ZONE CHANGE always publishes NOW.
            // World-map travel fires a BURST of EndTurns per step; building a 2000-cell snapshot for
            // each saturated the turn thread and flooded Godot, so we cap the rate. BUT the trailing
            // flush lives in TickRender (BeforeRenderEvent), which does NOT fire while Qud is
            // backgrounded — the normal "watching Raves" case — so a coalesced frame could strand
            // until the next input. Zone entries (startup, world-map<->surface) are exactly the
            // transitions that needed "extra inputs" to appear; force those through immediately.
            // Same-zone turns still throttle, and TickRender flushes their tail when Qud is focused.
            _dirty = true;
            bool zoneChanged = zid != null && zid != _lastPublishedZone;
            if (zoneChanged || System.Environment.TickCount - _lastPublishMs >= PublishThrottleMs)
                PublishNow(player);
        }

        private static int _lastPublishMs;
        private static bool _dirty;
        // Set when Raves answers/cancels a prompt off-turn (a direction click); TickRender then forces one
        // publish after the game unblocks, so state changed during the prompt (e.g. a new campfire) shows.
        public static bool ForcePublishSoon;
        private static bool _clocksExported;   // one-shot guard for the day/night clock-sprite export
        private static bool _clocksQueued;     // a clock-export uiQueue task is in flight

        /// Queue the one-shot day/night clock-sprite export onto the uiQueue (Unity main thread —
        /// graphics readback MUST NOT run on the render/turn hook, that crashes the game natively).
        private static void MaybeExportClocks()
        {
            if (_clocksExported || _clocksQueued) return;
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;
            _clocksQueued = true;
            gm.uiQueue.queueTask(() =>
            {
                try { if (TitleExporter.ExportTimeClocks()) _clocksExported = true; }
                catch (Exception ex) { try { Server.Log("clock export: " + ex.Message); } catch { } }
                finally { _clocksQueued = false; }
            }, 0);
        }
        private static string _lastPublishedZone;   // zone id of the last snapshot sent; a change bypasses the throttle
        private const int PublishThrottleMs = 66;   // ~15 snapshots/sec ceiling during a burst

        // No-turn reactive refresh. TickRender diffs a cheap fingerprint of the observed state ~10x/sec;
        // any change marks the snapshot dirty so it republishes WITHOUT waiting for a turn.
        private static string _lastSignature;
        private static int _lastSigCheckMs;
        private const int SigCheckMs = 100;          // ~10 signature checks/sec (cheap; the publish still throttles)
        private static readonly System.Text.StringBuilder _sigSb = new System.Text.StringBuilder(128);

        // ── THINGS THAT GENERATE A SNAPSHOT ──────────────────────────────────────────────────────────
        //  Turn-based (always, throttled)          — any action that ends a turn            → Tick (EndTurnEvent)
        //  A command Raves drove (immediate)       — move / wait / key / become / zoo / shot → TickRender
        //  Player changed zone (immediate)         — walk over an edge, soar/descend, travel → Tick + TickRender
        //  --- no-turn signals, diffed in BuildSignature below (this is the extensible list) ---
        //    • combat target changed or cleared    (XRL.UI.Sidebar.CurrentTarget)
        //    • player HP changed                   (hitpoints / baseHitpoints)
        //    • player moved / was teleported        (CurrentCell X,Y)
        //    • level or XP changed                 (GetStatValue Level / XP)
        //    • active effects gained or lost        (player.Effects class set)
        //    • new message(s) in the log            (Messages.Messages.Count)
        //    • body temperature changed             (pPhysics.Temperature)
        //    • zone id                              (also forced immediately above; here for completeness)
        //  To make more things reactive, add the signal to BuildSignature — nothing else needs to change.
        // ─────────────────────────────────────────────────────────────────────────────────────────────

        /// A CHEAP fingerprint of the observed state the panels show — deliberately NOT a zone scan.
        /// TickRender diffs this to catch no-turn changes; see the trigger list above.
        private static string BuildSignature(GameObject player)
        {
            var sb = _sigSb;
            sb.Clear();
            try { var t = XRL.UI.Sidebar.CurrentTarget; sb.Append("t:").Append(t != null ? t.ID : "-").Append('|'); } catch { }
            if (player != null)
            {
                try { sb.Append("hp:").Append(player.hitpoints).Append('/').Append(player.baseHitpoints).Append('|'); } catch { }
                try { var c = player.CurrentCell; if (c != null) sb.Append("xy:").Append(c.X).Append(',').Append(c.Y).Append('|'); } catch { }
                try { sb.Append("lv:").Append(player.GetStatValue("Level")).Append(',').Append(player.GetStatValue("XP")).Append('|'); } catch { }
                try { if (player.pPhysics != null) sb.Append("tp:").Append(player.pPhysics.Temperature).Append('|'); } catch { }
                try
                {
                    sb.Append("fx:");
                    foreach (var e in player.Effects) if (e != null) sb.Append(e.ClassName).Append(',');
                    sb.Append('|');
                }
                catch { }
            }
            try { var mq = The.Game != null ? The.Game.Player?.Messages : null; sb.Append("m:").Append(mq != null && mq.Messages != null ? mq.Messages.Count : 0).Append('|'); } catch { }
            try { sb.Append("z:").Append(ZoneIdOf(player)); } catch { }
            return sb.ToString();
        }

        /// The player's current zone id, or null if it can't be read (teardown, no cell).
        private static string ZoneIdOf(GameObject player)
        {
            try
            {
                var c = player != null ? player.CurrentCell : null;
                var z = c != null ? c.ParentZone : null;
                return z != null ? z.ZoneID : null;
            }
            catch { return null; }
        }

        /// Build + send the current snapshot now (unless nobody's listening), and reset the throttle.
        private static void PublishNow(GameObject player)
        {
            BridgeServer server = Server;
            if (server == null || server.ClientCount == 0) { _dirty = false; return; }
            _lastPublishMs = System.Environment.TickCount;
            _dirty = false;
            try
            {
                server.Publish(Protocol.Frame(ZoneSnapshot.BuildJson(player)));
                _lastPublishedZone = ZoneIdOf(player);   // remember what we just showed, for the zone-change gate
                _lastSignature = BuildSignature(player);  // reset the no-turn baseline: this is the state Raves now has
            }
            catch (Exception e) { server.Log("snapshot error: " + e.Message); }
        }

        /// <summary>
        /// Runs EVERY rendered frame (BeforeRenderEvent), on the main thread, even while
        /// the player is idle at the input prompt. Drains + applies any commands that
        /// arrived from an external driver, and — if one applied while idle — publishes a
        /// snapshot immediately so the driver gets a response without waiting for a turn.
        /// </summary>
        /// Set while ZoneSnapshot rebuilds the light map via a nested BeforeRenderEvent.Send —
        /// that send re-dispatches to OUR BridgePart handler too; without this guard the
        /// snapshot build would re-enter TickRender from inside itself.
        internal static bool InSnapshotRelight;

        public static void TickRender(GameObject player)
        {
            if (InSnapshotRelight) return;
            BridgeServer server = Server;
            EnsureScanlineState();              // keep Qud's always-on CC_AnalogTV scanlines suppressed (1:1)
            MaybeExportClocks();                // one-shot day/night sky discs — marshalled to the uiQueue
            PopupBridge.Ensure();               // arm the UI-thread popup watcher (mirrors Qud modals to Raves)
            bool applied = false;
            while (server.Incoming.TryDequeue(out string json))
            {
                try { Apply(player, json); applied = true; }
                catch (Exception e) { server.Log("apply error: " + e.Message); }
            }
            if (applied)
            {
                PublishNow(player);                 // a driven command gets an immediate response
                return;
            }
            // A direction prompt was just answered/cancelled off-turn (e.g. Make Camp). The game was
            // BLOCKED in PickDirection so no snapshot could fire; now that it's unblocked, force one so
            // the result (the new campfire, etc.) shows without waiting for a move.
            if (ForcePublishSoon)
            {
                ForcePublishSoon = false;
                PublishNow(player);
                return;
            }
            // Publish the moment the player's ZONE changes, even without a turn. A soar/descend
            // switches zones OUTSIDE an EndTurn, so Tick's zone-change publish fires on the stale
            // pre-switch zone and Raves lagged one input behind. TickRender runs every rendered
            // frame, so it catches the switch as soon as it lands — no extra wait needed.
            string zid = ZoneIdOf(player);
            if (zid != null && zid != _lastPublishedZone)
            {
                PublishNow(player);
                return;
            }
            // No-turn reactive refresh: mark dirty when any observed signal changed (target, HP, position,
            // level, effects, messages, temperature, zone — see BuildSignature). Checked ~10x/sec so it's
            // cheap; the throttle below coalesces the actual publish. This is what makes targeting (and
            // other no-turn changes) appear in Raves without waiting for a move.
            if (System.Environment.TickCount - _lastSigCheckMs >= SigCheckMs)
            {
                _lastSigCheckMs = System.Environment.TickCount;
                if (BuildSignature(player) != _lastSignature)
                    _dirty = true;
            }
            if (_dirty && System.Environment.TickCount - _lastPublishMs >= PublishThrottleMs)
                PublishNow(player);                 // flush the last state coalesced during a burst
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
                if (name == "popup")
                {
                    // Answer a mirrored Qud popup (dismiss / pick option / submit text). Marshals onto the
                    // uiQueue itself — the turn thread is parked inside the popup, but the UI thread drains.
                    PopupBridge.HandleCommand(f);
                    return;
                }
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
                if (name == "command")
                {
                    // A named Qud command (CmdFire, CmdReload, …) from a Raves button/hotkey. Injected
                    // like a move so it wakes an unfocused game and runs through Qud's own command path
                    // (any targeting UI opens in the Qud window). Binding-independent (no key guessing).
                    f.TryGetValue("command", out string cmd);
                    if (!string.IsNullOrEmpty(cmd))
                        Keyboard.PushCommand(cmd, null);
                    return;
                }
                if (name == "zoom")
                {
                    // Zoom Qud's stage from the bridge: CmdZoomIn/Out are reachable only via real
                    // Rewired input or the control-panel button (OnControlPanelButton) — PushCommand
                    // never gets there. Call GameManager.ZoomIn/Out directly; they touch Unity
                    // state, so marshal via uiQueue (the turn-thread golden rule). Steps are Qud's
                    // own quarter-steps; "dir":"out" zooms out, anything else zooms in.
                    f.TryGetValue("dir", out string sdir);
                    bool zout = sdir == "out";
                    var zgm = GameManager.Instance;
                    if (zgm != null && zgm.uiQueue != null)
                        zgm.uiQueue.queueTask(() => { if (zout) zgm.ZoomOut(); else zgm.ZoomIn(); });
                    return;
                }
                if (name == "setoption")
                {
                    // SetOption touches UI/audio state — run it on the uiQueue, which drains
                    // at the MENU too. (The turn-thread drain also has a setoption case, but
                    // that only runs in-game — menu edits from Raves' Options queued forever.)
                    f.TryGetValue("id", out string soid);
                    f.TryGetValue("value", out string soval);
                    f.TryGetValue("defer", out string sodefer);
                    if (!string.IsNullOrEmpty(soid))
                    {
                        var sgm = GameManager.Instance;
                        if (sgm != null && sgm.uiQueue != null)
                            sgm.uiQueue.queueTask(() =>
                            {
                                try
                                {
                                    XRL.UI.Options.SetOption(soid, soval ?? "");
                                    if (sodefer != "1") OptionsExporter.ReExport();
                                    Server.Log("[setoption] " + soid + " = " + soval);
                                }
                                catch (Exception ex) { Server.Log("setoption error: " + ex.Message); }
                            });
                    }
                    return;
                }
                if (name == "deletesave")
                {
                    // Raves' picker confirmed a delete: remove it via Qud's own
                    // SaveGameInfo.Delete() (DataManager.DeleteSaveDirectory — the
                    // exact cleanup a picker-row delete performs). Confirm UX is
                    // Raves-side; this command is the already-confirmed action.
                    f.TryGetValue("id", out string dsid);
                    if (!string.IsNullOrEmpty(dsid))
                    {
                        var dgm = GameManager.Instance;
                        if (dgm != null && dgm.uiQueue != null)
                            dgm.uiQueue.queueTask(() =>
                            {
                                try
                                {
                                    var t = Qud.API.SavesAPI.GetSavedGameInfo();
                                    t.Wait(5000);
                                    Qud.API.SaveGameInfo hit = null;
                                    if (t.IsCompleted && t.Result != null)
                                        foreach (var i in t.Result)
                                            if (i != null && i.ID == dsid) { hit = i; break; }
                                    if (hit == null) { Server.Log("[deletesave] no save with ID " + dsid); return; }
                                    hit.Delete();
                                    Server.Log("[deletesave] deleted '" + hit.Name + "' (" + dsid + ")");
                                }
                                catch (Exception ex) { Server.Log("deletesave error: " + ex.Message); }
                            });
                    }
                    return;
                }
                if (name == "loadsave")
                {
                    // Raves' 1:1 picker chose a save: load it by ID via Qud's own
                    // picker flow (see LoadSave.cs — completes the completionSource
                    // exactly like a row click; opens the picker first if needed).
                    f.TryGetValue("id", out string lsid);
                    if (!string.IsNullOrEmpty(lsid)) LoadSave.Request(lsid);
                    return;
                }
                if (name == "statusscreen")
                {
                    // SOLVED, and NOT the way this command does it: the reliable opener is the
                    // ordinary TURN-THREAD command path — `command CmdEquipment` (CmdSkills,
                    // CmdCharacter, …) opens Qud's status screens at that tab, because the turn
                    // thread is what Qud's own keypress path uses. Calling
                    // StatusScreensScreen.show() directly hangs from BOTH a uiQueue task and a
                    // UiContext.Post: its NavigationController.SuspendContextWhile waits on the
                    // gameplay input context, which is exactly what the turn thread owns.
                    // Kept for the tab INDEX it documents; prefer the command path.
                    // Tab order matches the carousel:
                    // 0 skills · 1 attributes · 2 equipment · 3 tinkering · 4 journal ·
                    // 5 quests · 6 reputation · 7 message log.
                    f.TryGetValue("tab", out string ssTab);
                    int.TryParse(ssTab, out int ssIdx);
                    // NOT uiQueue: post straight to Qud's UI SynchronizationContext, so the
                    // call runs on Unity's own update pump like a real button click. Calling
                    // show() from inside a uiQueue task re-entered NavigationController's
                    // SuspendContextWhile and the task hung forever (never completed, never
                    // faulted). Post() is thread-safe, so this goes from the socket thread.
                    try
                    {
                        var ssCtx = GameManager.Instance != null
                            ? GameManager.Instance.uiSynchronizationContext : null;
                        if (ssCtx == null) { System.Console.WriteLine("[raves] statusscreen: no ui context"); return; }
                        ssCtx.Post(delegate
                        {
                            try
                            {
                                GameObject who = XRL.The.Player;
                                if (who == null) { System.Console.WriteLine("[raves] statusscreen: no player"); return; }
                                try { Qud.UI.StatusScreensScreen.prewarm(); } catch { }
                                var t = Qud.UI.StatusScreensScreen.show(ssIdx, who);
                                t.ContinueWith(tt =>
                                {
                                    if (tt.IsFaulted)
                                        System.Console.WriteLine("[raves] statusscreen FAULT: "
                                            + (tt.Exception != null ? tt.Exception.GetBaseException().Message : "?"));
                                    else
                                        System.Console.WriteLine("[raves] statusscreen closed (tab " + ssIdx + ")");
                                });
                                System.Console.WriteLine("[raves] statusscreen posted tab " + ssIdx);
                            }
                            catch (Exception ex) { System.Console.WriteLine("[raves] statusscreen: " + ex.Message); }
                        }, null);
                    }
                    catch (Exception ex) { System.Console.WriteLine("[raves] statusscreen post: " + ex.Message); }
                    return;
                }
                if (name == "invaction")
                {
                    // Raves' Equipment tab: open Qud's own item interaction popup for
                    // the selected object. The menu itself mirrors back over the popup
                    // channel -- nothing here builds one.
                    f.TryGetValue("id", out string invId);
                    InventoryExporter.Twiddle(invId);
                    return;
                }
                if (name == "skill")
                {
                    // Raves' Skills tab: accept a row (Qud's own SelectNode purchase
                    // flow, popups included) or toggle a category's expand state.
                    f.TryGetValue("index", out string skIdx);
                    f.TryGetValue("mode", out string skMode);
                    int.TryParse(skIdx, out int skI);
                    SkillsExporter.Select(skI, skMode ?? "accept");
                    return;
                }
                if (name == "rebind")
                {
                    // (see KeybindApplier; PumpSyncContext below keeps unfocused async flows moving)
                    // Raves' Control Mapping edits (KeybindApplier mirrors Qud's own
                    // KeybindsScreen flows; confirm/conflict popups mirror back to
                    // Raves through the popup bridge). action: set|remove|defaults|golden.
                    f.TryGetValue("action", out string rbAct);
                    f.TryGetValue("id", out string rbId);
                    f.TryGetValue("slot", out string rbSlotS);
                    int.TryParse(rbSlotS, out int rbSlot);
                    f.TryGetValue("key", out string rbKey);
                    f.TryGetValue("ctrl", out string rbC);
                    f.TryGetValue("shift", out string rbS);
                    f.TryGetValue("alt", out string rbA);
                    switch (rbAct)
                    {
                        case "remove":   _ = KeybindApplier.Remove(rbId, rbSlot); break;
                        case "defaults": _ = KeybindApplier.Defaults(); break;
                        case "golden":   _ = KeybindApplier.RestoreGolden(); break;
                        case "regolden": _ = KeybindApplier.ReGolden(); break;
                        default:         _ = KeybindApplier.Apply(rbId, rbSlot, rbKey,
                                             rbC == "1", rbS == "1", rbA == "1"); break;
                    }
                    return;
                }
                if (name == "uiback")
                {
                    // First-party "press Escape" for Qud's MODERN menu screens (Records/
                    // Options/Mods/…). Those screens read input hardware-side, so OS-
                    // synthesized Escape never lands (highvisor's HID events included);
                    // fire the framework's own cancel event instead. UI state — uiQueue.
                    var bgm = GameManager.Instance;
                    if (bgm != null && bgm.uiQueue != null)
                        bgm.uiQueue.queueTask(() =>
                        {
                            try
                            {
                                // Most faithful: the active modern window's own OnCancel()
                                // (ModManagerUI, high scores, …) — the method its UI wires up.
                                try
                                {
                                    var uim = Qud.UI.UIManager.instance;
                                    var wnd = (uim != null) ? uim.currentWindow : null;
                                    if (wnd == null)
                                    {
                                        // currentWindow is nulled on some view transitions —
                                        // resolve by the ACTIVE VIEW NAME instead (the same
                                        // string our heartbeat reports as the scene).
                                        var view = GameManager.Instance != null
                                            ? GameManager.Instance._ActiveGameView : null;
                                        if (!string.IsNullOrEmpty(view))
                                            try { wnd = Qud.UI.UIManager.getWindow(view); } catch { }
                                    }
                                    if (wnd != null)
                                    {
                                        var mi = wnd.GetType().GetMethod("OnCancel", System.Type.EmptyTypes);
                                        // StatusScreensScreen: go straight to the unguarded Exit() — its
                                        // OnCancel/OnCloseButton no-op when the nav context died (seen
                                        // after a mutation-buy popup left the screen un-Escapable even
                                        // for the KEYBOARD; Exit() always tears it down).
                                        // KeybindsScreen: same story — the inherited OnCancel() is a no-op;
                                        // its real close is Exit() (CancelButton handler; completes the
                                        // completionSource so KeybindsMenu() resumes and Hide()s).
                                        if (wnd.GetType().Name == "StatusScreensScreen"
                                            || wnd.GetType().Name == "KeybindsScreen")
                                        {
                                            var exi = wnd.GetType().GetMethod("Exit", System.Type.EmptyTypes);
                                            if (exi != null) mi = exi;
                                        }
                                        if (mi == null) mi = wnd.GetType().GetMethod("Exit", System.Type.EmptyTypes);
                                        if (mi != null)
                                        {
                                            mi.Invoke(wnd, null);
                                            // OnCancel -> RemoveGameView(Hard:false) sets bViewUpdated
                                            // but the view pump only runs when the console buffer is
                                            // dirty — at an idle title screen that's NEVER. Kick it, or
                                            // _ActiveGameView (our scene report) stays stale forever.
                                            ConsoleLib.Console.TextConsole.BufferUpdated = true;
                                            // UNFOCUSED Qud: async void Exit() completes its await chain
                                            // (completionSource -> KeybindsMenu resume -> Hide -> the
                                            // system-menu handler) through Unity's SynchronizationContext,
                                            // which macOS stops draining for a backgrounded window even
                                            // with runInBackground=true (turns + uiQueue keep running —
                                            // only these continuations stall, leaving the screen up and
                                            // TURNS BLOCKED until the next focus). We're ON the main
                                            // thread here: pump the context so the close resolves now.
                                            PumpSyncContext(8);
                                            System.Console.WriteLine("[raves] uiback: " + wnd.GetType().Name + " cancel/exit invoked");
                                            return;
                                        }
                                    }
                                }
                                catch (Exception wex) { System.Console.WriteLine("[raves] uiback window: " + wex.Message); }
                                var nav = XRL.UI.Framework.NavigationController.instance;
                                if (nav == null) { System.Console.WriteLine("[raves] uiback: no NavigationController"); return; }
                                // Screens register commandHandlers["Cancel"] (string id), not the
                                // button enum — fire the command; button event as a fallback.
                                // SINGLE-SHOT ladder — fire exactly one cancel. A shotgun of
                                // fallbacks double-fires: the extra Cancel lands on the main
                                // menu, where Cancel == "Are you sure you want to quit?".
                                var ev = nav.FireInputCommandEvent("Cancel");
                                if (ev != null && ev.handled)
                                {
                                    ConsoleLib.Console.TextConsole.BufferUpdated = true;
                                    System.Console.WriteLine("[raves] uiback: nav command Cancel handled");
                                    return;
                                }
                                var ev2 = nav.FireInputButtonEvent(XRL.UI.Framework.InputButtonTypes.CancelButton);
                                if (ev2 != null && ev2.handled)
                                {
                                    ConsoleLib.Console.TextConsole.BufferUpdated = true;
                                    System.Console.WriteLine("[raves] uiback: nav button Cancel handled");
                                    return;
                                }
                                // Last rung — screens that POLL ControlManager.isCommandDown("Cancel"):
                                // inject a Cancel FrameCommand the way real input does (enqueue into
                                // the private CommandQueue; next frame promotes it). Data access only.
                                bool queued = false;
                                try
                                {
                                    var cmType = typeof(ControlManager);
                                    var fcType = cmType.GetNestedType("FrameCommand");
                                    var fc = Activator.CreateInstance(fcType);
                                    fcType.GetField("id").SetValue(fc, "Cancel");
                                    var qField = cmType.GetField("CommandQueue",
                                        System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
                                    var q = qField.GetValue(null);
                                    q.GetType().GetMethod("Enqueue").Invoke(q, new object[] { fc });
                                    queued = true;
                                }
                                catch (Exception rex) { System.Console.WriteLine("[raves] uiback reflection: " + rex.Message); }
                                ConsoleLib.Console.TextConsole.BufferUpdated = true;
                                System.Console.WriteLine("[raves] uiback: queue-injected Cancel (queued=" + queued + ")");
                            }
                            catch (Exception ex) { System.Console.WriteLine("[raves] uiback error: " + ex.Message); }
                        });
                    return;
                }
                if (name == "dir")
                {
                    // Answer a Qud direction prompt (PickDirection) with a LeftClick at a CELL — Qud
                    // derives the direction itself (adjacent -> that way, own cell -> self, else ignored).
                    // Used by Raves' direction picker (e.g. Make Camp).
                    f.TryGetValue("x", out string sx);
                    f.TryGetValue("y", out string sy);
                    if (int.TryParse(sx, out int cx) && int.TryParse(sy, out int cy))
                        Keyboard.PushMouseEvent("LeftClick", cx, cy);
                    ForcePublishSoon = true;   // refresh Raves once the prompt resolves (e.g. the new campfire)
                    return;
                }
                if (name == "dircancel")
                {
                    Keyboard.PushMouseEvent("RightClick", 0, 0);   // PickDirection: RightClick -> cancel (unblocks Qud)
                    ForcePublishSoon = true;
                    return;
                }
                if (name == "key")
                {
                    // Forward a raw key press (e.g. Raves' S/D) INTO Qud's keymap, so it fires
                    // whatever the player has that key bound to — soar/descend, etc. — instead of
                    // us guessing command ids. allowmap:true routes through the bindings; PushKey
                    // Sets KeyEvent, so it wakes an unfocused game exactly like the move injection.
                    f.TryGetValue("key", out string k);
                    if (!string.IsNullOrEmpty(k))
                        PushKeyChar(k[0]);
                    return;
                }
                if (name == "export")
                {
                    // Re-run the DATA exporters NOW, even at the main menu. The fall-through path
                    // below enqueues to Server.Incoming, which only drains in-game (turn/render tick)
                    // — so chargen/mods/etc. data would never refresh at the menu, exactly where the
                    // chargen screens ask for it. Run it on the uiQueue instead (main thread, drains
                    // each frame while focused), so a screen that opens at the menu gets fresh data +
                    // its tile art (TileExporter also queues onto uiQueue). Data-only + cheap.
                    var gmx = GameManager.Instance;
                    if (gmx != null && gmx.uiQueue != null)
                        gmx.uiQueue.queueTask(() =>
                        {
                            try
                            {
                                ModsExporter.ReExport();
                                OptionsExporter.ReExport();
                                RecordsExporter.ReExport();
                                ChargenExporter.ReExport();
                                CharacterExporter.ReExport();   // live sheet data for the status screens
                                BindingsExporter.ReExport();    // control-mapping data
                                SkillsExporter.ReExport();      // skills & powers tree
                                InventoryExporter.ReExport();   // inventory (Equipment tab)
                                TitleExporter.ExportCellFrame();     // Qud's own 9-slice cell frame
                                TitleExporter.ExportChargenEmblem();                        // resident even at the menu
                                TitleExporter.ExportNamedSprite("tiny-frame-h", "card_frame.png");         // the game-mode card's dotted frame
                                TitleExporter.ExportNamedSprite("polat-locator-big", "sel_frame.png");     // the selected-card frame (corner brackets)
                                TitleExporter.ExportNamedSprite("leftrightarrow", "nav_arrow.png");        // back/forward chevron
                                TitleExporter.ExportNamedSprite("polat-center-divider-knob", "deco_knob.png"); // the sub-text ornament
                                if (!_clocksExported && TitleExporter.ExportTimeClocks()) _clocksExported = true;  // day/night sky discs (resident once a HUD has existed)
                                Server.Log("[export] re-exported (menu path) chargen chrome");
                            }
                            catch (Exception e) { try { Server.Log("export error: " + e.Message); } catch { } }
                        }, 0);
                    return;
                }
                if (name == "dumpframes")
                {
                    // One-shot: dump all resident frame-like sprites (+ a manifest with 9-slice
                    // borders) so we can identify Qud's real selection frame. Main-thread readback.
                    var gmf = GameManager.Instance;
                    if (gmf != null && gmf.uiQueue != null)
                        gmf.uiQueue.queueTask(() =>
                        {
                            try { TitleExporter.DumpFrameSprites(); Server.Log("[dumpframes] done"); }
                            catch (Exception e) { try { Server.Log("dumpframes error: " + e.Message); } catch { } }
                        }, 0);
                    return;
                }
                if (name == "dumpnav")
                {
                    // One-shot: dump the top-bar nav-button icons (ActiveButton sprites). uiQueue = main thread.
                    var gmn = GameManager.Instance;
                    if (gmn != null && gmn.uiQueue != null)
                        gmn.uiQueue.queueTask(() => { try { TitleExporter.ExportNavIcons(); } catch (Exception e) { try { Server.Log("dumpnav: " + e.Message); } catch { } } }, 0);
                    return;
                }
                if (name == "metagame")
                {
                    // Boot a background "Meta" pseudo-game (Marsh Taur pregen, Classic) so Raves has a
                    // live game — lights up Continue + gives the viewer a real zone without manual chargen.
                    EmbarkDriver.RequestMeta();
                    return;
                }
                if (name == "tutorial")
                {
                    // BEGIN the guided tutorial: start its chargen so Qud is at the genotype window and
                    // its live tip gets captured to tutorial_tip.txt (Raves reads it). No boot yet.
                    EmbarkDriver.RequestTutorial();
                    return;
                }
                if (name == "tutorial_go")
                {
                    // COMMIT: the player confirmed on Raves' guided genotype screen — boot the tutorial.
                    EmbarkDriver.RequestTutorialCommit();
                    return;
                }
                if (name == "embark")
                {
                    // THE DRIVE: create the character Raves assembled and start the run, skipping
                    // Qud's on-screen chargen. RequestEmbark stashes the spec, wakes the main menu
                    // ("Pick:New Game" -> XRLCore.NewGame() -> EmbarkBuilder.Begin()), then drives
                    // the live builder headlessly on the UI queue. Only meaningful at the main menu
                    // (no-op / times out if a game is already running or the menu isn't active).
                    f.TryGetValue("genotype", out string g);
                    f.TryGetValue("subtype", out string sub);
                    if (string.IsNullOrEmpty(g) || string.IsNullOrEmpty(sub))
                    {
                        try { Server.Log("embark ignored: need both genotype and subtype"); } catch { }
                        return;
                    }
                    var spec = new EmbarkDriver.PendingBuildSpec { Genotype = g, Subtype = sub };
                    f.TryGetValue("gamemode", out string gm);
                    if (!string.IsNullOrEmpty(gm)) spec.Gamemode = gm;
                    f.TryGetValue("start", out string sl);
                    if (!string.IsNullOrEmpty(sl)) spec.StartingLocation = sl;
                    EmbarkDriver.RequestEmbark(spec);
                    return;
                }
            }
            catch (Exception e) { try { Server.Log("onpayload error: " + e.Message); } catch { } }
            // not consumed inline -> hand to the main-thread drain
            Server.Incoming.Enqueue(json);
        }

        /// Inject a single character as a key press routed through Qud's keybindings. Unity's
        /// KeyCode values for 'a'..'z' and '0'..'9' equal their lowercase-ASCII codepoints, so the
        /// char casts straight to the KeyCode. allowmap:true makes Qud resolve it to the bound
        /// command; the enqueue+Set wakes the turn thread even while the window is unfocused.
        private static void PushKeyChar(char ch)
        {
            try
            {
                char c = char.ToLowerInvariant(ch);
                bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
                if (!ok) return;                       // letters/digits only for now
                var code = (UnityEngine.KeyCode)c;     // KeyCode.A==97=='a', Alpha0==48=='0'
                Keyboard.PushKey(new Keyboard.XRLKeyEvent(code, c), bAllowMap: true);
            }
            catch (Exception e) { try { Server.Log("pushkey error: " + e.Message); } catch { } }
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
                case "zoo":
                    // Build a debug showcase into the current zone. MAIN-THREAD ONLY:
                    // creates GameObjects and mutates cells, so it must run here (drained
                    // by Tick/TickRender), never on the socket thread.
                    try
                    {
                        f.TryGetValue("cat", out string cat);
                        f.TryGetValue("page", out string pageStr);
                        int pg = 0;
                        int.TryParse(pageStr, out pg);
                        Server.Log("[zoo] " + ZooBuilder.Build(player, cat, pg));
                    }
                    catch (Exception e) { Server.Log("zoo error: " + e.Message); }
                    break;
                case "become":
                    // Turn the player INTO an arbitrary blueprint. MAIN-THREAD ONLY:
                    // creates a GameObject, re-homes player control, retires the old
                    // body — all game-state mutation, so it must run here.
                    try
                    {
                        f.TryGetValue("bp", out string bp);
                        Server.Log("[become] " + PlayerBecome.Become(player, bp));
                    }
                    catch (Exception e) { Server.Log("become error: " + e.Message); }
                    break;
                case "catalog":
                    // Dump the pickable-blueprint catalog to disk for the Godot menu.
                    try { Server.Log("[catalog] wrote " + PlayerBecome.WriteCatalog()); }
                    catch (Exception e) { Server.Log("catalog error: " + e.Message); }
                    break;
                case "export":
                    // Re-run the DATA exporters on demand — the clean replacement for ticking a
                    // fake turn to fire the one-shot Ensure()s. Data-only + cheap; add each new
                    // exporter (records, …) here. Title art is one-shot (never changes), so skip it.
                    try
                    {
                        ModsExporter.ReExport();
                        OptionsExporter.ReExport();
                        RecordsExporter.ReExport();
                        ChargenExporter.ReExport();
                        Server.Log("[export] re-exported mods + options + records + chargen");
                    }
                    catch (Exception e) { Server.Log("export error: " + e.Message); }
                    break;
                case "setoption":
                    // Update Qud from Raves' Options mirror. MAIN-THREAD ONLY: SetOption updates
                    // flags / audio / UI. Re-export so Raves reflects the applied value + any
                    // dependent-option visibility change. Some options need a restart (o.Restart).
                    try
                    {
                        f.TryGetValue("id", out string oid);
                        f.TryGetValue("value", out string oval);
                        f.TryGetValue("defer", out string odefer);   // "1" = batch apply: skip the
                        if (!string.IsNullOrEmpty(oid))               //  per-call re-export; caller sends
                        {                                            //  one "export" after the last one.
                            XRL.UI.Options.SetOption(oid, oval ?? "");
                            if (odefer != "1") OptionsExporter.ReExport();
                            Server.Log("[setoption] " + oid + " = " + oval);
                        }
                    }
                    catch (Exception e) { Server.Log("setoption error: " + e.Message); }
                    break;
                case "itemaction":
                    // Invoke an inventory action on one of the player's equipped weapons — e.g. the
                    // context menu's "[?]" -> ReplaceSocketCell (change the battery). MAIN-THREAD ONLY:
                    // InventoryActionEvent.Check mutates state and can open a picker UI, so it must run
                    // here (drained by Tick/TickRender), never on the socket thread.
                    try
                    {
                        f.TryGetValue("item", out string itemId);
                        f.TryGetValue("command", out string icmd);
                        if (!string.IsNullOrEmpty(itemId) && !string.IsNullOrEmpty(icmd))
                        {
                            GameObject item = FindEquippedById(player, itemId);
                            if (item != null)
                                InventoryActionEvent.Check(item, player, item, icmd);
                            else
                                Server.Log("itemaction: no equipped weapon id=" + itemId);
                        }
                    }
                    catch (Exception e) { Server.Log("itemaction error: " + e.Message); }
                    break;
                case "wish":
                    // Grant a Qud wish (the Ctrl+Shift+W prompt) from Raves — the user types the wish text
                    // in Raves and we run it through Qud's own handler, no on-screen prompt. MAIN-THREAD
                    // ONLY: wishes spawn objects / grant xp / mutate state, so it runs here (drained by
                    // Tick/TickRender), never on the socket thread.
                    try
                    {
                        f.TryGetValue("wish", out string wishText);
                        if (!string.IsNullOrEmpty(wishText))
                        {
                            XRL.World.Capabilities.Wishing.HandleWish(player, wishText);
                            ForcePublishSoon = true;   // refresh Raves once the wish applies (xp, items, …)
                            Server.Log("[wish] " + wishText);
                        }
                    }
                    catch (Exception e) { Server.Log("wish error: " + e.Message); }
                    break;
                // Movement is handled on the socket thread (see OnPayload), so it can
                // drive an unfocused game. Extend here for main-thread-only commands.
                default:
                    break;
            }
        }

        /// <summary>
        /// Idempotent: once the Main Camera exists, push the current scanline preference to its
        /// CC_AnalogTV. Called every rendered frame from TickRender — it no-ops once the camera
        /// already reflects DisableQudScanlines, and re-arms itself if the flag later changes or
        /// if the camera isn't built yet. The actual field write is marshalled to the main thread
        /// via uiQueue (touching a Unity component off the main thread crashes the game — same rule
        /// as the tile export and screenshot paths).
        /// </summary>
        internal static void EnsureScanlineState()
        {
            if (_scanlineApplyPending) return;
            // Already in the desired state? If restoring, we're done. If suppressing, keep re-sweeping on a
            // throttle — Qud instantiates some panels (ability-bar buttons, popups) AFTER the first sweep,
            // each with its own material instance, so a one-shot latch leaves those still scanlined.
            if (_scanlineAppliedValue == DisableQudScanlines)
            {
                if (!DisableQudScanlines) return;
                if ((_sweepTick++ % 20) != 0) return;
            }
            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;   // too early (pre-game thread); retry next frame
            _scanlineApplyPending = true;
            bool want = DisableQudScanlines;
            gm.uiQueue.queueTask(() =>
            {
                _scanlineApplyPending = false;
                try
                {
                    // (a) The camera-level CC_AnalogTV scanlines (invisible in practice, but zero them
                    //     too so "Qud's scanline effect" is fully off). May be >1 across cameras.
                    foreach (var tv in UnityEngine.Object.FindObjectsOfType<CC_AnalogTV>())
                    {
                        if (tv == null) continue;
                        if (float.IsNaN(_origScanlineIntensity)) _origScanlineIntensity = tv.scanlinesIntensity;
                        tv.scanlinesIntensity = want ? 0f : _origScanlineIntensity;
                    }

                    // (b) THE VISIBLE ONES: Qud's UI chrome is drawn with custom shaders — "UI/Textured-Overlay"
                    //     applies a grunge/scanline OVERLAY texture (_OverlayTex "distress-diagonal") tinted by
                    //     _ColorOverlay, and "UI/ThreeColorOffset" adds a per-row _Offset. Together these paint
                    //     the screen-space horizontal lines that show through the translucent panels (the opaque
                    //     play field hides them, so the world stays clean). There is NO _ScanlinesIntensity on
                    //     these UI materials (that name belongs to the camera CC_AnalogTV only). Neutralise the
                    //     overlay tint + the offset on every material that has them; capture originals to restore.
                    int graphics = 0, newMats = 0;
                    foreach (var g in UnityEngine.Object.FindObjectsOfType<UnityEngine.UI.Graphic>())
                    {
                        if (g == null) continue;
                        var mat = g.material;
                        if (mat == null || mat.shader == null) continue;
                        bool touched = false;
                        if (mat.HasProperty("_ColorOverlay"))
                        {
                            if (!_uiOrigOverlayCol.ContainsKey(mat)) { _uiOrigOverlayCol[mat] = mat.GetColor("_ColorOverlay"); newMats++; }
                            mat.SetColor("_ColorOverlay", want ? new UnityEngine.Color(0f, 0f, 0f, 0f) : _uiOrigOverlayCol[mat]);
                            touched = true;
                        }
                        // Some panels (e.g. the highlighted ability button) modulate by the overlay TEXTURE
                        // itself, not just the tint — clearing _ColorOverlay isn't enough. Swap _OverlayTex to
                        // a flat white texture (neutral under both add and multiply); restore the original.
                        if (mat.HasProperty("_OverlayTex"))
                        {
                            if (!_uiOrigOverlayTex.ContainsKey(mat)) { _uiOrigOverlayTex[mat] = mat.GetTexture("_OverlayTex"); newMats++; }
                            mat.SetTexture("_OverlayTex", want ? UnityEngine.Texture2D.whiteTexture : _uiOrigOverlayTex[mat]);
                            touched = true;
                        }
                        if (mat.HasProperty("_Offset"))
                        {
                            if (!_uiOrigOffset.ContainsKey(mat)) { _uiOrigOffset[mat] = mat.GetFloat("_Offset"); newMats++; }
                            mat.SetFloat("_Offset", want ? 0f : _uiOrigOffset[mat]);
                            touched = true;
                        }
                        if (touched) graphics++;
                    }

                    // (c) SPRITE-based overlays that don't go through the overlay shader: some UI Images are
                    //     plain UI/Default but their SPRITE is the pattern — the bottom "AbilityBar" uses
                    //     sprite "horizstripetexture" (the command-bar scanlines), and a full-screen "Creases"
                    //     uses "creases" grunge. Flatten a stripe image to a solid chrome-dark quad (drop the
                    //     sprite, set the fill), and hide a grunge overlay (alpha 0). Originals restored via flag.
                    foreach (var img in UnityEngine.Object.FindObjectsOfType<UnityEngine.UI.Image>())
                    {
                        if (img == null || img.sprite == null) continue;
                        string sn = img.sprite.name + "|" + (img.sprite.texture != null ? img.sprite.texture.name : "");
                        bool stripe = sn.IndexOf("stripe", StringComparison.OrdinalIgnoreCase) >= 0
                                   || sn.IndexOf("scanline", StringComparison.OrdinalIgnoreCase) >= 0;
                        bool grunge = sn.IndexOf("crease", StringComparison.OrdinalIgnoreCase) >= 0
                                   || sn.IndexOf("distress", StringComparison.OrdinalIgnoreCase) >= 0
                                   || sn.IndexOf("grain", StringComparison.OrdinalIgnoreCase) >= 0;
                        if (!stripe && !grunge) continue;
                        if (!_uiOrigSprite.ContainsKey(img))
                        {
                            _uiOrigSprite[img] = img.sprite;
                            _uiOrigColor[img] = img.color;
                            newMats++;
                        }
                        if (want)
                        {
                            if (stripe) { img.sprite = null; img.color = new UnityEngine.Color(0.047f, 0.055f, 0.059f, 1f); }
                            else { var c = img.color; img.color = new UnityEngine.Color(c.r, c.g, c.b, 0f); }
                        }
                        else { img.sprite = _uiOrigSprite[img]; img.color = _uiOrigColor[img]; }
                        graphics++;
                    }

                    // Latch the state once we've actually found chrome panels (the first in-game tick can fire
                    // before the UI is built — a premature latch would leave it scanlined). Re-sweeps are
                    // throttled by the caller; only log the first apply and any sweep that finds NEW materials
                    // (late-created panels like the ability bar), so the log doesn't spam.
                    if (graphics > 0)
                    {
                        bool first = _scanlineAppliedValue != want;
                        _scanlineAppliedValue = want;
                        if (first || newMats > 0)
                            Server.Log("scanlines " + (want ? "disabled" : "restored")
                                + " — overlay/offset neutralised on " + graphics + " graphics (+"
                                + newMats + " new this sweep)");
                    }
                    else if (_diagCount++ == 0)
                    {
                        Server.Log("scanline: in-game but no overlay/offset UI materials yet — retrying");
                    }
                    if (_verboseDiag && !_diagged) { _diagged = true; DumpScanlineSuspects(); }
                }
                catch (Exception e) { Server.Log("scanline set: " + e.Message); }
            }, 0);
        }

        // Per-material originals for restore of the chrome overlay knobs.
        private static readonly System.Collections.Generic.Dictionary<UnityEngine.Material, UnityEngine.Color> _uiOrigOverlayCol
            = new System.Collections.Generic.Dictionary<UnityEngine.Material, UnityEngine.Color>();
        private static readonly System.Collections.Generic.Dictionary<UnityEngine.Material, float> _uiOrigOffset
            = new System.Collections.Generic.Dictionary<UnityEngine.Material, float>();
        private static readonly System.Collections.Generic.Dictionary<UnityEngine.Material, UnityEngine.Texture> _uiOrigOverlayTex
            = new System.Collections.Generic.Dictionary<UnityEngine.Material, UnityEngine.Texture>();
        // Sprite-based stripe/grunge overlays (e.g. AbilityBar "horizstripetexture", full-screen "Creases").
        private static readonly System.Collections.Generic.Dictionary<UnityEngine.UI.Image, UnityEngine.Sprite> _uiOrigSprite
            = new System.Collections.Generic.Dictionary<UnityEngine.UI.Image, UnityEngine.Sprite>();
        private static readonly System.Collections.Generic.Dictionary<UnityEngine.UI.Image, UnityEngine.Color> _uiOrigColor
            = new System.Collections.Generic.Dictionary<UnityEngine.UI.Image, UnityEngine.Color>();
        private static bool _diagged;
        private static int _diagCount;              // throttle for the 0-match scene dump
        private static int _sweepTick;              // throttle for periodic re-sweeps (late-created panels)
        private static bool _verboseDiag = false;   // flip to true to re-dump the bottom-bar scanline suspects

        /// <summary>
        /// One-shot scene walk (main thread): dump every UI Graphic whose screen rect sits in the
        /// BOTTOM ~90px of the screen (the command/ability bar) — name, shader, full material knobs,
        /// and screen Y — so we can see what draws the residual scanlines there and why the overlay
        /// sweep didn't clear it. Screen coords via GetWorldCorners (Screen-Space-Overlay canvases
        /// report corners directly in screen pixels; Unity Y is bottom-up so the bottom bar has low Y).
        /// </summary>
        private static void DumpScanlineSuspects()
        {
            try
            {
                float sh = UnityEngine.Screen.height;
                var corners = new UnityEngine.Vector3[4];
                int hit = 0;
                foreach (var g in UnityEngine.Object.FindObjectsOfType<UnityEngine.UI.Graphic>())
                {
                    if (g == null || !g.isActiveAndEnabled) continue;
                    g.rectTransform.GetWorldCorners(corners);
                    float ymin = corners[0].y, ymax = corners[0].y, xmin = corners[0].x, xmax = corners[0].x;
                    for (int i = 1; i < 4; i++)
                    {
                        if (corners[i].y < ymin) ymin = corners[i].y; if (corners[i].y > ymax) ymax = corners[i].y;
                        if (corners[i].x < xmin) xmin = corners[i].x; if (corners[i].x > xmax) xmax = corners[i].x;
                    }
                    // bottom bar: element bottom edge within 90px of screen bottom, and reasonably wide
                    if (ymin > 90f || (xmax - xmin) < 30f) continue;
                    var mat = g.material;
                    string msh = (mat != null && mat.shader != null) ? mat.shader.name : "<null>";
                    var knobs = new System.Collections.Generic.List<string>();
                    if (mat != null)
                    {
                        string[] probe = { "_ColorOverlay", "_OverlayTex", "_Offset", "_MainTex",
                                           "_ScanlinesIntensity", "_Color", "_Foreground", "_Background" };
                        foreach (var p in probe)
                        {
                            if (!mat.HasProperty(p)) continue;
                            try
                            {
                                if (p == "_OverlayTex" || p == "_MainTex")
                                { var t = mat.GetTexture(p); knobs.Add(p + "=tex:" + (t != null ? t.name : "null")); }
                                else if (p == "_Offset" || p == "_ScanlinesIntensity")
                                    knobs.Add(p + "=" + mat.GetFloat(p).ToString("0.##"));
                                else { var c = mat.GetColor(p); knobs.Add(p + "=" + c.ToString()); }
                            }
                            catch { }
                        }
                    }
                    // UI Images carry their texture via the sprite / CanvasRenderer, not the shared
                    // material's _MainTex — log both so a scanline sprite shows up.
                    string sprite = "";
                    var img = g as UnityEngine.UI.Image;
                    if (img != null && img.sprite != null)
                        sprite = " sprite='" + img.sprite.name + "'"
                            + (img.sprite.texture != null ? "/tex:" + img.sprite.texture.name : "");
                    string crTex = "";
                    try
                    {
                        var cr = g.canvasRenderer;
                        if (cr != null && cr.materialCount > 0)
                        {
                            var cm = cr.GetMaterial(0);
                            if (cm != null && cm.mainTexture != null) crTex = " CRtex='" + cm.mainTexture.name + "'";
                        }
                    }
                    catch { }
                    Server.Log("BOTTOM '" + g.name + "' <" + g.GetType().Name + "> shader=" + msh
                        + " y=" + (int)ymin + ".." + (int)ymax + " w=" + (int)(xmax - xmin)
                        + " a=" + g.color.a.ToString("0.##") + sprite + crTex
                        + " {" + string.Join(", ", knobs) + "}");
                    if (++hit >= 40) { Server.Log("BOTTOM …capped"); break; }
                }
                Server.Log("BOTTOM-bar dump complete (" + hit + " graphics)");
            }
            catch (Exception e) { Server.Log("DIAG error: " + e.Message); }
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

        /// Find one of the player's equipped missile weapons by its GameObject.ID (the client targets a
        /// specific weapon for an item action). Returns null if not found.
        private static GameObject FindEquippedById(GameObject player, string id)
        {
            try
            {
                var mws = player.GetMissileWeapons();
                if (mws != null)
                    foreach (var w in mws)
                        if (w != null && w.ID == id) return w;
            }
            catch { }
            return null;
        }
    }
}

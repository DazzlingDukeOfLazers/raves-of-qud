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
        /// Microseconds the last RenderBase (Qud's own map recomposite) took; 0 if skipped.
        /// Sent in the snapshot so the client can see the mod's per-turn cost split.
        public static long LastRenderBaseUs;

        /// Runs on the TURN THREAD at the start of each player action (BeginTakeActionEvent). Unlike the
        /// render-tied TickRender, this fires even while Qud is unfocused — so it can flush a publish
        /// queued off-turn (a direction prompt answered from Raves, e.g. Make Camp) as soon as the game
        /// unblocks, without waiting for a real turn.
        public static void TickAction(GameObject player)
        {
            BridgeServer server = Server;
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
                        Server.Log("[export] re-exported mods + options");
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
                        if (!string.IsNullOrEmpty(oid))
                        {
                            XRL.UI.Options.SetOption(oid, oval ?? "");
                            OptionsExporter.ReExport();
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

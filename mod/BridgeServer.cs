using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace RavesOfQud
{
    /// <summary>
    /// Plain-.NET localhost TCP server. Deliberately references NO Qud types, so
    /// this half is deterministic and unit-testable outside the game.
    ///
    /// Threading model (this is the part that will bite you if you get it wrong):
    ///   - Accept runs on a background thread. Each client gets its OWN background
    ///     read thread AND write thread (see <see cref="ClientConn"/>).
    ///   - Inbound command payloads land in <see cref="Incoming"/> (a concurrent
    ///     queue) or the <see cref="OnPayload"/> hook, on the client's read thread.
    ///   - <see cref="Publish"/> is called from the GAME MAIN THREAD once per turn.
    ///     It NEVER blocks: it hands each client its latest frame and returns. The
    ///     blocking socket Write happens on that client's writer thread.
    ///   - The game-side glue (Bridge.Tick) must drain Incoming and touch game
    ///     state ONLY on the main thread. Never read a GameObject off these
    ///     background threads.
    ///
    /// Why per-client writers: the broadcast used to be a synchronous Write to every
    /// client on the game thread. A single client that stopped draining its socket
    /// (e.g. a Raves window parked at a menu whose probe never reads) filled the OS
    /// send buffer, and the Write BLOCKED — stalling the whole game's turn thread and
    /// freezing snapshots for everyone (head-of-line blocking). Now each client has a
    /// one-slot, coalescing outbox: Publish just drops the newest frame in and signals.
    /// Snapshots are full state (the client already renders only the latest), so a slow
    /// client simply skips stale intermediates, and a truly stuck one is dropped on a
    /// write timeout — never touching the game thread.
    /// </summary>
    public sealed class BridgeServer
    {
        // Drop a client that makes NO send progress for this long. Must exceed the longest a HEALTHY
        // client can legitimately stop draining — the Godot viewer blocks its socket read while it
        // rebuilds a zone (1–3s) — so this is generous; it's for truly dead/stuck peers, not busy ones.
        private const int WriteStallMs = 6000;
        private const int SendChunk = 16 * 1024;  // write in small chunks (after Poll says writable) so no single Write blocks long

        private readonly int _port;
        private TcpListener _listener;
        private Thread _acceptThread;
        private volatile bool _running;

        private readonly object _clientsLock = new object();
        private readonly List<ClientConn> _clients = new List<ClientConn>();

        /// <summary>Live client count. Used to gate the focus-keeper: only override
        /// Qud's pause-on-unfocus while a viewer / driver is actually attached.</summary>
        public int ClientCount { get { lock (_clientsLock) return _clients.Count; } }

        /// <summary>Command payloads received from clients, oldest first.</summary>
        public readonly ConcurrentQueue<string> Incoming = new ConcurrentQueue<string>();

        /// <summary>
        /// Optional per-payload hook, invoked on the BACKGROUND read thread the instant
        /// a frame arrives. The game side sets this to route latency-critical commands
        /// (movement) straight into Qud's input queue — which wakes the main thread even
        /// when the window is unfocused — instead of waiting for a main-thread drain of
        /// <see cref="Incoming"/>. If unset, payloads fall back to Incoming. Whatever the
        /// hook does NOT consume, it should enqueue to Incoming itself.
        /// </summary>
        public Action<string> OnPayload;

        /// <summary>Optional hook fired (on the accept thread) each time a client connects. The game side
        /// uses it to force a snapshot publish — which only actually happens if a game is live — so a
        /// newly-connected client gets current data immediately (and can tell "game live" from "just a
        /// socket") without having to send a turn-passing command.</summary>
        public Action OnConnect;

        /// <summary>Optional log sink; set from the game side to route to Qud's log.</summary>
        public Action<string> Log = _ => { };

        public BridgeServer(int port) { _port = port; }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _listener = new TcpListener(IPAddress.Loopback, _port);
            _listener.Start();
            _acceptThread = new Thread(AcceptLoop) { IsBackground = true, Name = "RavesBridgeAccept" };
            _acceptThread.Start();
            Log($"listening on 127.0.0.1:{_port}");
        }

        public void Stop()
        {
            _running = false;
            try { _listener?.Stop(); } catch { /* ignore */ }
            ClientConn[] snapshot;
            lock (_clientsLock) { snapshot = _clients.ToArray(); _clients.Clear(); }
            foreach (var c in snapshot) c.Kill();
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                TcpClient client;
                try { client = _listener.AcceptTcpClient(); }
                catch { if (!_running) break; else continue; }

                client.NoDelay = true;
                ClientConn conn;
                try { conn = new ClientConn(this, client); }
                catch { try { client.Close(); } catch { } continue; }
                ReapDead();   // clear any dead ghost (e.g. the just-killed Raves) before the replacement joins
                lock (_clientsLock) _clients.Add(conn);
                conn.Start();
                Log("client connected");
                try { OnConnect?.Invoke(); } catch { /* game side hook; never let it kill the accept loop */ }
            }
        }

        private void Remove(ClientConn conn)
        {
            bool had;
            lock (_clientsLock) had = _clients.Remove(conn);
            if (had) Log("client disconnected");
        }

        private static bool ReadFully(Stream s, byte[] buf, int count)
        {
            int off = 0;
            while (off < count)
            {
                int n = s.Read(buf, off, count - off);
                if (n <= 0) return false;
                off += n;
            }
            return true;
        }

        /// <summary>
        /// Broadcast a framed message to every connected client. Called on the game main
        /// thread — and NON-BLOCKING: it just hands each client its newest frame (dropping
        /// any stale one still queued) and returns. The actual socket Write happens on each
        /// client's writer thread, so a slow/stuck client can never stall the game thread.
        /// </summary>
        public void Publish(byte[] frame)
        {
            ReapDead();
            lock (_clientsLock)
            {
                for (int i = 0; i < _clients.Count; i++)
                    _clients[i].Offer(frame);
            }
        }

        /// <summary>
        /// Cull clients whose peer has vanished. Called from <see cref="Publish"/> (so a rebuilt Raves
        /// reconnecting never has to share the roster with its own dead ghost — the ghost is dropped on the
        /// very next publish) and from the accept path (so it's gone the instant the replacement connects).
        /// Collects under the lock but Kills OUTSIDE it: Kill re-enters Remove, and we don't hold
        /// _clientsLock across that.
        /// </summary>
        private void ReapDead()
        {
            List<ClientConn> dead = null;
            lock (_clientsLock)
            {
                for (int i = _clients.Count - 1; i >= 0; i--)
                {
                    if (_clients[i].IsPeerGone())
                    {
                        if (dead == null) dead = new List<ClientConn>();
                        dead.Add(_clients[i]);
                        _clients.RemoveAt(i);
                    }
                }
            }
            if (dead != null)
                foreach (var c in dead) { Log("reaped dead client"); c.Kill(); }
        }

        /// <summary>
        /// One connected client: a read thread (commands in) and a write thread draining a
        /// single-slot, coalescing outbox (latest snapshot out). All blocking I/O lives here,
        /// off the game thread.
        /// </summary>
        private sealed class ClientConn
        {
            private readonly BridgeServer _srv;
            private readonly TcpClient _tcp;
            private readonly NetworkStream _stream;
            private readonly AutoResetEvent _wake = new AutoResetEvent(false);
            private byte[] _pending;              // newest frame awaiting send (coalesced); swapped via Interlocked
            private volatile bool _alive = true;
            private int _killed;                  // Interlocked one-shot so teardown/removal runs once

            public ClientConn(BridgeServer srv, TcpClient tcp)
            {
                _srv = srv;
                _tcp = tcp;
                _stream = tcp.GetStream();
                // Best-effort TCP keepalive so a peer that vanishes WITHOUT a clean FIN (a hard-killed
                // Raves, a yanked connection) is eventually RST'd by the OS and our blocking read unblocks.
                // Mono may ignore the fine-grained timing knobs; the publish/accept reaper is the real net.
                try { tcp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true); }
                catch { /* option unsupported on this runtime — reaper still covers us */ }
            }

            public void Start()
            {
                new Thread(ReadLoop)  { IsBackground = true, Name = "RavesBridgeRead" }.Start();
                new Thread(WriteLoop) { IsBackground = true, Name = "RavesBridgeWrite" }.Start();
            }

            /// Non-blocking hand-off from Publish: replace the pending frame with the newest and
            /// wake the writer. A backed-up client only ever ships the LATEST snapshot; stale
            /// intermediates are dropped (safe — snapshots are full state, not deltas).
            public void Offer(byte[] frame)
            {
                if (!_alive) return;
                Interlocked.Exchange(ref _pending, frame);
                try { _wake.Set(); } catch { /* disposed during teardown */ }
            }

            /// Non-blocking liveness probe used by the reaper. A peer that closed or reset shows up as
            /// "readable with nothing to read" (Poll true + Available 0); a live socket with no pending
            /// data is NOT readable. Sampled twice to close the one race with the read thread: a live
            /// client whose inbound command is consumed between samples reads readable-then-empty once,
            /// but a truly-dead peer stays readable-with-0 across both. Never blocks more than ~1ms.
            public bool IsPeerGone()
            {
                if (!_alive) return true;
                Socket s;
                try { s = _tcp.Client; } catch { return true; }
                if (s == null) return true;
                try
                {
                    if (!(s.Poll(0, SelectMode.SelectRead) && s.Available == 0)) return false;
                    return s.Poll(1000, SelectMode.SelectRead) && s.Available == 0;   // 1ms confirm
                }
                catch { return true; }   // disposed / errored socket → treat as gone
            }

            // Send the newest frame WITHOUT ever doing a long blocking Write. The socket stays in blocking
            // mode (so the shared READ side is unaffected — flipping Blocking breaks reads), but we only
            // Write a small chunk AFTER Poll reports the send buffer has room, so no single Write stalls.
            // Verified: with a blocking full-frame Write, a non-draining peer's stuck Write still caused a
            // brief game-thread hiccup (Mono holds an io resource during the blocking syscall); chunked
            // Poll-gated writes remove it. A peer that never drains for WriteStallMs is dropped; progress
            // resets the clock, so a viewer that pauses to rebuild a zone (1–3s) is NOT dropped.
            private void WriteLoop()
            {
                Socket sock = _tcp.Client;
                try
                {
                    while (_alive)
                    {
                        _wake.WaitOne();
                        byte[] frame = Interlocked.Exchange(ref _pending, null);
                        if (frame == null) continue;               // spurious wake / already sent
                        int off = 0;
                        var stall = System.Diagnostics.Stopwatch.StartNew();
                        while (off < frame.Length && _alive)
                        {
                            if (!sock.Poll(50000, SelectMode.SelectWrite))   // 50ms; false = buffer still full
                            {
                                if (stall.ElapsedMilliseconds > WriteStallMs)
                                    throw new IOException("client stalled " + stall.ElapsedMilliseconds + "ms");
                                continue;                          // peer not draining yet — wait, up to the stall cap
                            }
                            int chunk = Math.Min(frame.Length - off, SendChunk);
                            _stream.Write(frame, off, chunk);      // buffer had room (Poll) + small chunk → no long block
                            off += chunk;
                            stall.Restart();                       // made progress → reset the stall clock
                        }
                    }
                }
                catch (Exception e) { try { _srv.Log("dropped slow/broken client: " + e.Message); } catch { } }
                finally { Kill(); }
            }

            private void ReadLoop()
            {
                try
                {
                    var lenBuf = new byte[4];
                    while (_alive && _srv._running)
                    {
                        if (!ReadFully(_stream, lenBuf, 4)) break;
                        int len = (lenBuf[0] << 24) | (lenBuf[1] << 16) | (lenBuf[2] << 8) | lenBuf[3];
                        if (len < 0 || len > (16 << 20)) break;    // 16 MB sanity cap
                        var payload = new byte[len];
                        if (!ReadFully(_stream, payload, len)) break;
                        string s = Encoding.UTF8.GetString(payload);
                        Action<string> hook = _srv.OnPayload;
                        if (hook != null) hook(s); else _srv.Incoming.Enqueue(s);
                    }
                }
                catch { /* client dropped */ }
                finally { Kill(); }
            }

            /// Idempotent teardown: stop both loops, close the socket, drop from the roster.
            public void Kill()
            {
                if (Interlocked.Exchange(ref _killed, 1) != 0) return;
                _alive = false;
                try { _wake.Set(); } catch { /* wake the writer so it exits WaitOne */ }
                try { _tcp.Close(); } catch { /* also unblocks a Write/Read in progress */ }
                _srv.Remove(this);
            }
        }
    }
}

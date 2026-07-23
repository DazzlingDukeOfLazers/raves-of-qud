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
    ///   - Accept + per-client read loops run on BACKGROUND threads. Inbound
    ///     command payloads land in <see cref="Incoming"/> (a concurrent queue).
    ///   - <see cref="Publish"/> is called from the GAME MAIN THREAD once per turn.
    ///   - The game-side glue (Bridge.Tick) must drain Incoming and touch game
    ///     state ONLY on the main thread. Never read a GameObject off these
    ///     background threads.
    /// </summary>
    public sealed class BridgeServer
    {
        private readonly int _port;
        private TcpListener _listener;
        private Thread _acceptThread;
        private volatile bool _running;

        private readonly object _clientsLock = new object();
        private readonly List<TcpClient> _clients = new List<TcpClient>();

        /// <summary>Command payloads received from clients, oldest first.</summary>
        public readonly ConcurrentQueue<string> Incoming = new ConcurrentQueue<string>();

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
            lock (_clientsLock)
            {
                foreach (var c in _clients) { try { c.Close(); } catch { /* ignore */ } }
                _clients.Clear();
            }
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                TcpClient client;
                try { client = _listener.AcceptTcpClient(); }
                catch { if (!_running) break; else continue; }

                client.NoDelay = true;
                lock (_clientsLock) _clients.Add(client);
                new Thread(() => ReadLoop(client)) { IsBackground = true, Name = "RavesBridgeRead" }.Start();
                Log("client connected");
            }
        }

        private void ReadLoop(TcpClient client)
        {
            try
            {
                NetworkStream stream = client.GetStream();
                var lenBuf = new byte[4];
                while (_running)
                {
                    if (!ReadFully(stream, lenBuf, 4)) break;
                    int len = (lenBuf[0] << 24) | (lenBuf[1] << 16) | (lenBuf[2] << 8) | lenBuf[3];
                    if (len < 0 || len > (16 << 20)) break; // 16 MB sanity cap
                    var payload = new byte[len];
                    if (!ReadFully(stream, payload, len)) break;
                    Incoming.Enqueue(Encoding.UTF8.GetString(payload));
                }
            }
            catch { /* client dropped */ }
            finally
            {
                lock (_clientsLock) _clients.Remove(client);
                try { client.Close(); } catch { /* ignore */ }
                Log("client disconnected");
            }
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
        /// Broadcast a framed message to every connected client. Called on the game
        /// main thread. Writes are synchronous; payloads are localhost + a few KB so
        /// this is fine for the MVP. If you ever see turn-stutter, move sends to a
        /// background writer thread fed by a queue (see README, PERF).
        /// </summary>
        public void Publish(byte[] frame)
        {
            lock (_clientsLock)
            {
                for (int i = _clients.Count - 1; i >= 0; i--)
                {
                    try { _clients[i].GetStream().Write(frame, 0, frame.Length); }
                    catch
                    {
                        try { _clients[i].Close(); } catch { /* ignore */ }
                        _clients.RemoveAt(i);
                    }
                }
            }
        }
    }
}

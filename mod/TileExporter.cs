using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;

namespace RavesOfQud
{
    /// <summary>
    /// Engine-assisted tile export — QUEUE side (turn-thread safe).
    ///
    /// CRITICAL THREADING: Qud runs turn logic (EndTurnEvent → our Tick) on a
    /// DEDICATED BACKGROUND THREAD, not Unity's main/render thread. Any Unity
    /// graphics call off that thread → "Graphics device is null" → a hard native
    /// crash that try/catch cannot catch (learned the hard way).
    ///
    /// Therefore this class does NO Unity work. <see cref="Ensure"/> — called from
    /// the turn thread while building a snapshot — only records tile paths. The
    /// actual atlas readback + PNG write happens on the Unity main thread in
    /// TileExportPump.cs, which drains <see cref="Pending"/>.
    /// </summary>
    public static class TileExporter
    {
        private static readonly HashSet<string> _seen = new HashSet<string>();  // turn thread only
        public static readonly ConcurrentQueue<string> Pending = new ConcurrentQueue<string>();
        private static string _dir;

        /// <summary>Shared output dir; also sent to Godot in each snapshot. (File IO only — thread safe.)</summary>
        public static string Dir
        {
            get
            {
                if (_dir == null)
                {
                    string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    _dir = Path.Combine(home, "Library", "Application Support", "RavesOfQud", "tiles");
                    Directory.CreateDirectory(_dir);
                }
                return _dir;
            }
        }

        /// <summary>tile path → flat filename (must match the Godot side).</summary>
        public static string FileFor(string tilePath) =>
            tilePath.Replace('/', '_').Replace('\\', '_').Replace(':', '_');

        /// <summary>Turn-thread safe: record a tile to export later. NO Unity calls.</summary>
        public static void Ensure(string tilePath)
        {
            if (string.IsNullOrEmpty(tilePath) || !_seen.Add(tilePath)) return;
            Pending.Enqueue(tilePath);
        }
    }
}

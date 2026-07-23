using System;
using System.Collections.Generic;
using System.IO;

namespace RavesOfQud
{
    /// <summary>
    /// Engine-assisted tile export — dispatch side (game-thread safe).
    ///
    /// THREADING: Qud runs turn logic on a background thread; Unity graphics there
    /// crashes ("Graphics device is null"), and Harmony patching is blocked on
    /// macOS. The escape hatch is Qud's own cross-thread primitive: GameManager
    /// has a <c>uiQueue</c> (QupKit.ThreadTaskQueue) drained on the UI/main thread.
    /// <see cref="Ensure"/> (called while building a snapshot on the turn thread)
    /// does NO graphics — it just marshals the actual readback onto uiQueue via
    /// queueTask, so <see cref="TileExportPump.Export"/> runs on the main thread.
    /// </summary>
    public static class TileExporter
    {
        private static readonly HashSet<string> _seen = new HashSet<string>();  // turn thread only
        private static string _dir;

        /// <summary>Shared output dir; also sent to Godot in each snapshot. (File IO only.)</summary>
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

        /// <summary>
        /// Turn-thread safe: queue this tile's export onto Unity's main thread.
        /// No Unity graphics here — only enqueue. If GameManager isn't ready yet we
        /// return WITHOUT marking it seen, so it's retried on a later turn.
        /// </summary>
        public static void Ensure(string tilePath)
        {
            if (string.IsNullOrEmpty(tilePath) || _seen.Contains(tilePath)) return;

            GameManager gm = GameManager.Instance;
            if (gm == null || gm.uiQueue == null) return;

            _seen.Add(tilePath);
            string path = tilePath; // capture for the main-thread closure
            gm.uiQueue.queueTask(() => TileExportPump.Export(path), 0);
        }
    }
}

using System;
using System.Text;

namespace RavesOfQud
{
    /// <summary>
    /// Wire protocol shared by both ends. Pure .NET — no Qud types here.
    ///
    /// Framing: every message is [4-byte big-endian length][UTF-8 JSON payload].
    /// Server -> client: { "type":"snapshot", ... }   (see docs/protocol.md)
    /// client -> server: { "type":"command", "name":"move", "dir":"N" }
    /// </summary>
    public static class Protocol
    {
        /// <summary>
        /// Which build of the mod is actually running. Mod .cs only compiles at
        /// Qud startup, so a deploy does nothing until a restart — and there was
        /// no way to tell from the outside whether the running code included a
        /// given fix. Every snapshot now says. Bump this when changing the mod.
        /// </summary>
        public const string Build = "2026-07-23k family-dedup";

        // Arbitrary high port; keep in sync with godot/BridgeClient.gd (PORT).
        public const int DefaultPort = 48710;

        public const string TypeSnapshot = "snapshot";
        public const string TypeCommand  = "command";

        /// <summary>Length-prefix a JSON string into a ready-to-send frame.</summary>
        public static byte[] Frame(string json)
        {
            byte[] payload = Encoding.UTF8.GetBytes(json);
            int len = payload.Length;
            byte[] frame = new byte[4 + len];
            frame[0] = (byte)((len >> 24) & 0xFF);
            frame[1] = (byte)((len >> 16) & 0xFF);
            frame[2] = (byte)((len >> 8) & 0xFF);
            frame[3] = (byte)(len & 0xFF);
            Buffer.BlockCopy(payload, 0, frame, 4, len);
            return frame;
        }
    }
}

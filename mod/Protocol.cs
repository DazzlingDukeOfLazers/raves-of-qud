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
        public const string Build = "2026-08-04 inventory-u";

        /// <summary>
        /// Monotonic WIRE version — bump whenever a change to the snapshot format makes a newer client
        /// DEPEND on a newer mod (a field the client now needs). The client knows the minimum it requires
        /// (godot/MainFrame.gd MIN_MOD_PROTOCOL) and warns in the message log when the running mod is older
        /// — so a forgotten "restart Caves of Qud after a mod change" can't silently ship stale behaviour
        /// (which is exactly what hid the liquid fix until a restart). History:
        ///   1  baseline (pre-handshake)
        ///   2  adds per-object `liquid` flag (static-signature fix) + this `protocol` field
        ///   3  adds per-object `onFire` flag (daytime campfire flame + smoke)
        /// </summary>
        public const int Version = 3;

        // Arbitrary high port; keep in sync with godot/BridgeClient.gd (PORT).
        public const int DefaultPort = 48710;

        public const string TypeSnapshot = "snapshot";
        public const string TypeCommand  = "command";
        public const string TypePopup    = "popup";   // server->client: a live Qud modal mirrored to Raves

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

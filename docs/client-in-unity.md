# How to build a Raves client in Unity

Raves of Qud is two halves joined by one seam:

```
  Caves of Qud + bridge mod  ──frames──▶  a client that renders + sends input
        (engine-agnostic)                    (Godot today; Unity here)
```

The mod (`mod/*.cs`) and the **wire protocol** ([docs/protocol.md](protocol.md)) are the
product. The Godot project in `godot/` is *one* consumer of that protocol — a reference
implementation, not the API. Nothing about the bridge is Godot-specific: it is framed JSON
over a localhost TCP socket. **Any engine that can open a socket and draw a textured quad can
be a Raves client.** This page is the Unity port.

> You do **not** touch the mod to write a Unity client. Deploy the existing mod to your Qud
> install exactly as the README describes, then point Unity at `127.0.0.1:48710`.

---

## The contract you must honour

Everything a client must do is fixed by the protocol. Read [docs/protocol.md](protocol.md)
first; this section is the checklist a Unity client implements.

| # | Responsibility | Protocol source |
|---|---|---|
| 1 | Connect to `127.0.0.1:48710`, retry ~1/s until Qud is listening | mod opens the socket on the first turn |
| 2 | Read frames: `[4-byte big-endian length][UTF-8 JSON]` | `mod/Protocol.cs` |
| 3 | On connect, send one `wait` command to prime the first snapshot | see "priming" below |
| 4 | **Coalesce** queued snapshots — render only the newest | snapshots are full state, not deltas |
| 5 | Check the version handshake (`mod` string + `protocol` int) | §"Version handshake" |
| 6 | Load tiles from `tilesDir`, slashes→underscores, glyph fallback + retry | §"tilesDir" |
| 7 | Classify each object: wall → prism, `layer ≤ 2` → ground quad, else billboard | §"render classification" |
| 8 | Resolve colours (`fgHex`/`bgHex` when present, else Qud colour strings via `palette`) | §"Colours" |
| 9 | Recess actors in liquid (`wade`/`swim`), unless `bridge` | §"Water & bridges" |
| 10 | Map input → `command` frames (`move`/`wait`/`key`/`shot`) | §"Client → server" |

Points 4–9 are **engine-agnostic logic** — the same rules the Godot client runs. Only *how*
you draw and marshal threads is Unity-specific.

---

## Project shape

A minimal Unity client is four MonoBehaviours plus a couple of plain C# classes:

```
Assets/Raves/
  BridgeClient.cs     TCP framing, reconnect, snapshot queue, command send   (port of BridgeClient.gd)
  Snapshot.cs         POCOs + JSON parse (Newtonsoft or System.Text.Json)
  ZoneRenderer.cs     snapshot -> GameObjects: walls / floors / billboards   (port of ZoneRenderer.gd)
  TileCache.cs        tilesDir path mapping + Texture2D load + glyph fallback
  QudColor.cs         colour-string / palette resolution                     (port of _qud_color)
  CameraRig.cs        orbit/pan/zoom + input -> command                      (port of Main.gd + CameraRig.gd)
```

Use **Unity 2022 LTS+** and either the built-in or URP render pipeline. Newtonsoft
(`com.unity.nuget.newtonsoft-json`) is strongly recommended — Unity's built-in `JsonUtility`
cannot deserialize the snapshot's nested arrays-of-heterogeneous-objects.

---

## 1. The socket — background thread, main-thread hand-off

**Unity's API is main-thread-only.** Read the socket on a background thread, parse there, and
hand the finished snapshot object to the main thread through a `ConcurrentQueue` drained in
`Update()`. This mirrors the Godot client's single-frame coalescing, and it is the same
threading rule the mod side lives by (see the playbook's "threading is the trap").

```csharp
// BridgeClient.cs
using System;
using System.Collections.Concurrent;
using System.Net.Sockets;
using System.Threading;
using UnityEngine;

public class BridgeClient : MonoBehaviour
{
    public const string Host = "127.0.0.1";
    public const int Port = 48710;                 // == mod/Protocol.cs DefaultPort

    public event Action<Snapshot> OnSnapshot;      // fired on the MAIN thread
    public event Action OnConnected;

    readonly ConcurrentQueue<Snapshot> _inbox = new();
    readonly ConcurrentQueue<byte[]> _outbox = new();
    volatile bool _connected;
    Thread _worker;
    volatile bool _run = true;

    void Start() { _worker = new Thread(Loop) { IsBackground = true }; _worker.Start(); }
    void OnDestroy() { _run = false; }

    void Loop()
    {
        while (_run)
        {
            try
            {
                using var tcp = new TcpClient();
                tcp.Connect(Host, Port);           // throws until Qud is listening
                var stream = tcp.GetStream();
                _connected = true;
                _inbox.Enqueue(Snapshot.ConnectedMarker);   // let main thread send the priming wait

                var len = new byte[4];
                while (_run && tcp.Connected)
                {
                    // flush queued commands
                    while (_outbox.TryDequeue(out var frame)) stream.Write(frame, 0, frame.Length);

                    if (!stream.DataAvailable) { Thread.Sleep(4); continue; }
                    ReadExact(stream, len, 4);
                    int n = (len[0] << 24) | (len[1] << 16) | (len[2] << 8) | len[3];
                    var payload = new byte[n];
                    ReadExact(stream, payload, n);
                    var snap = Snapshot.Parse(System.Text.Encoding.UTF8.GetString(payload));
                    if (snap != null) _inbox.Enqueue(snap);
                }
            }
            catch { /* not up yet / dropped */ }
            _connected = false;
            Thread.Sleep(1000);                    // retry ~once per second
        }
    }

    static void ReadExact(NetworkStream s, byte[] buf, int n)
    {
        int off = 0;
        while (off < n) { int r = s.Read(buf, off, n - off); if (r <= 0) throw new Exception("eof"); off += r; }
    }

    void Update()
    {
        // Coalesce: drain the whole queue, render only the newest snapshot this frame.
        // Snapshots are full state, so older ones are stale the instant a newer exists.
        // (The Godot client learned this the hard way — emitting each queued snapshot ran
        //  N heavy zone rebuilds back-to-back and hard-crashed the Metal allocator.)
        Snapshot latest = null; int dropped = 0;
        while (_inbox.TryDequeue(out var s))
        {
            if (ReferenceEquals(s, Snapshot.ConnectedMarker)) { OnConnected?.Invoke(); SendCommand("wait"); continue; }
            if (latest != null) dropped++;
            latest = s;
        }
        if (dropped > 0) Debug.Log($"Raves: coalesced {dropped} stale snapshot(s)");
        if (latest != null) OnSnapshot?.Invoke(latest);
    }

    public void SendCommand(string name, params (string k, object v)[] extra)
    {
        if (!_connected) return;
        var sb = new System.Text.StringBuilder();
        sb.Append("{\"type\":\"command\",\"name\":").Append(JsonStr(name));
        foreach (var (k, v) in extra)
            sb.Append(',').Append(JsonStr(k)).Append(':').Append(v is string vs ? JsonStr(vs) : v);
        sb.Append('}');
        var payload = System.Text.Encoding.UTF8.GetBytes(sb.ToString());
        int len = payload.Length;
        var frame = new byte[4 + len];
        frame[0] = (byte)(len >> 24); frame[1] = (byte)(len >> 16);
        frame[2] = (byte)(len >> 8);  frame[3] = (byte)len;
        Buffer.BlockCopy(payload, 0, frame, 4, len);
        _outbox.Enqueue(frame);
    }

    static string JsonStr(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
}
```

**Priming.** The mod only publishes when something changes, so a freshly connected client can
sit on a black screen. The Godot client sends one `wait` on (re)connect to force the first
snapshot; do the same (shown above, on the `ConnectedMarker`).

---

## 2. Parsing the snapshot

Define POCOs matching [docs/protocol.md](protocol.md) and parse with Newtonsoft. The one
subtlety is `objs`: a list of objects with **optional, heterogeneous** fields (a ground layer
has `ground:true` and no `glyph`; a creature has `sinks:true`). Model every field as nullable
and default-absent.

```csharp
// Snapshot.cs (abridged — add fields from docs/protocol.md as you consume them)
using System.Collections.Generic;
using Newtonsoft.Json;

public class Snapshot
{
    public static readonly Snapshot ConnectedMarker = new();
    public string type;
    public string mod;            // Protocol.Build  — human build id
    public int protocol;          // Protocol.Version — monotonic int
    public string tilesDir;
    public ZoneInfo zone;
    public Vec2 player;
    public List<Cell> cells;
    public Dictionary<string, string> palette;   // colour char -> "#rrggbb"

    public static Snapshot Parse(string json)
    {
        var s = JsonConvert.DeserializeObject<Snapshot>(json);
        return s != null && s.type == "snapshot" ? s : null;
    }
}
public class ZoneInfo { public string id; public int width, height; }
public class Vec2 { public int x, y; }
public class Cell
{
    public int x, y;
    public bool bridge, wade, swim;
    public int nHeld, nRendered, nSent;
    public int? light;
    public List<Obj> objs;
}
public class Obj
{
    public string name, display, glyph, tile, color, tilecolor, detail;
    public string fgHex, bgHex, detailHex;    // present only when RenderTile fired
    public bool? hflip, vflip;
    public int layer;
    public bool ground, wall, sinks, bridge, liquid, onFire;
    public float? lightRadius;
}
```

---

## 3. The version handshake

Do exactly what `MainFrame.gd` does: compare the snapshot's `protocol` int against constants
you bump when your client starts depending on a new field, and show a one-line status.

```csharp
const int ClientProtocol = 3;      // newest field this client uses (see protocol.md history)
const int MinModProtocol = 3;      // oldest mod build this client tolerates

// on first snapshot:
if (snap.protocol < MinModProtocol)  Status("restart Caves of Qud (mod too old)", red);
else if (ClientProtocol < snap.protocol) Status("re-export Raves (client too old)", yellow);
else Status($"up to date — {snap.mod}", green);
```

A mod `.cs` only compiles at Qud startup, so "deployed but not restarted" silently serves old
behaviour. This handshake is the only thing that tells you which code is actually running.

---

## 4. Tiles — `tilesDir` path mapping + glyph fallback

`tilesDir` is an absolute path the mod writes PNGs into. A tile string like
`Creatures/sw_bearman.png` maps to `tilesDir/Creatures_sw_bearman.png` (**slashes →
underscores**). Files export on-demand, so a tile can be missing on the frame you first ask
for it — fall back to the glyph and retry on a later snapshot.

```csharp
// TileCache.cs
Texture2D Load(string tilesDir, string tile)
{
    if (string.IsNullOrEmpty(tile)) return null;
    if (_cache.TryGetValue(tile, out var t)) return t;               // may be null == "known missing"
    var path = System.IO.Path.Combine(tilesDir, tile.Replace('/', '_'));
    if (!System.IO.File.Exists(path)) { _cache[tile] = null; return null; }  // retry next zone build
    var tex = new Texture2D(2, 2, TextureFormat.RGBA32, false) { filterMode = FilterMode.Point };
    tex.LoadImage(System.IO.File.ReadAllBytes(path));               // PNG/BMP autodetected
    _cache[tile] = tex;
    return tex;
}
```

Use **point filtering** — these are pixel-art tiles. The **static-layer self-heal race** from
the Godot client applies here too: the dynamic (creature) layer rebuilds every turn so it
retries for free, but a frozen static wall/fence built before its tile exported would bake a
permanent glyph. Flag any missing tile during a static build and rebuild that zone on a later
snapshot (bounded, like `STATIC_RETRY_MAX`) so first-sight scenery self-heals without a
zone re-entry.

---

## 5. Render classification

The rule (from [docs/protocol.md](protocol.md), calibrated layers): walls are 3D prisms,
low layers lie flat as ground, everything else stands up as a camera-facing billboard.

```csharp
enum Kind { Wall, Ground, Billboard }
Kind Classify(Obj o) =>
    o.wall            ? Kind.Wall :
    o.layer <= 2      ? Kind.Ground :
                        Kind.Billboard;
// calibration: layer 0 = ground clutter, 3 = trees, 7 = rock walls, 10 = creatures.
```

Unity primitives for each:

- **Wall** → a unit `Cube` (or, for parity with Godot's greedy mesh, merge all wall cells in a
  zone into one mesh via `Mesh.CombineMeshes` for draw-call sanity). Place at cell `(x, 0, y)`.
- **Ground** → a `Quad` rotated flat on the XZ plane (`Quaternion.Euler(90,0,0)`), at `y≈0`.
- **Billboard** → a `Quad` that faces the camera. Cheapest is a URP/Unlit material with a
  billboard vertex mode, or a tiny `LateUpdate` `transform.forward = camera.forward`. Recess by
  the water fraction (§7).

Build the zone **once per zone entry** (static: walls, floors, scenery) and rebuild only the
**dynamic** layer (creatures, `liquid`, `onFire`) each turn — same static/dynamic split as
`ZoneRenderer.gd`. This is what keeps a world-map burst from re-meshing 2000 cells per step.

Set per-instance colour with a `MaterialPropertyBlock` (`_BaseColor`) so every quad shares one
material and one draw path.

---

## 6. Colours

Colours arrive as **raw Qud strings** like `&Y` (foreground) `^B` (background). Prefer the
already-resolved `fgHex`/`bgHex`/`detailHex` when present (they ride along only when the mod's
`RenderTile` path fired — rare); otherwise resolve the colour char through the snapshot's
`palette` map, or key off the trailing letter as `ZoneRenderer._qud_color` does.

```csharp
// QudColor.cs
Color Resolve(string qud, Dictionary<string,string> palette, string fgHex)
{
    if (!string.IsNullOrEmpty(fgHex)) return Hex(fgHex);
    char c = LastColorChar(qud);                     // 'Y' from "&Y", "&b^B" -> foreground 'b'
    if (palette != null && palette.TryGetValue(c.ToString(), out var hex)) return Hex(hex);
    return Color.magenta;                            // loud fallback so gaps are visible
}
```

Two facts worth pinning: **`k` is `#0f3b3a` (dark teal), the colour of the Qud world — not
black**, and Qud's letters are not web names (`Y`=white, `y`=gray, `W`=gold, `w`=brown). The
`palette` map in every snapshot is authoritative; use it rather than hardcoding.

---

## 7. Water & bridges

Per the protocol: **the water stays flat, the actor recesses.** Turn a cell's `wade`/`swim`
into a fraction of the sprite height to sink, cancel it when the cell has a `bridge` (you cross
at full height), and only sink objects flagged `sinks` (creatures that aren't flying); scenery
and flyers keep their height.

```csharp
float SinkFraction(Cell c, Obj o)
{
    if (c.bridge || !o.sinks) return 0f;
    if (c.swim) return 0.6f;      // tune to taste; Godot hides a fraction of the art
    if (c.wade) return 0.3f;
    return 0f;
}
// billboard.localPosition.y -= SinkFraction(cell, obj) * spriteWorldHeight;
```

A `bridge` **object** is drawn as a flat opaque quad (fill the art's transparent field with
ground colour) lifted above the water it spans.

---

## 8. Input → commands

Map Unity input to `command` frames. The Godot client's bindings (`Main.gd`): numpad/arrows →
`move` with a compass `dir`, Shift+Space → `wait`, S/D → `key` (so Qud runs whatever the player
bound them to). The sim resolves the whole turn; new state returns as the next snapshot.

```csharp
void Update()
{
    if (Input.GetKeyDown(KeyCode.Keypad8)) _bridge.SendCommand("move", ("dir", "N"));
    if (Input.GetKeyDown(KeyCode.Keypad2)) _bridge.SendCommand("move", ("dir", "S"));
    if (Input.GetKeyDown(KeyCode.Keypad4)) _bridge.SendCommand("move", ("dir", "W"));
    if (Input.GetKeyDown(KeyCode.Keypad6)) _bridge.SendCommand("move", ("dir", "E"));
    // NE/NW/SE/SW on 9/7/3/1 …
    if (Input.GetKeyDown(KeyCode.Space) && Input.GetKey(KeyCode.LeftShift)) _bridge.SendCommand("wait");
    if (Input.GetKeyDown(KeyCode.F12)) _bridge.SendCommand("shot");   // Qud screenshots itself
}
```

Valid `dir` values: `N S E W NE NW SE SW`. Extend `name` with `command`/`itemaction`/`key`
exactly as the Godot client does — the mod dispatches by `name`.

---

## Validate like the Godot client does

You cannot eyeball a socket. Reuse the repo's Python tools (`tools/capture/snap.py`) to read
raw snapshots straight off the wire and confirm your parser and classification agree with the
reference before trusting the Unity render. The geometry/colour rules are validated in Python
first *precisely* so a new client can check itself without a human staring at the viewport —
see the "Python-first" note in the README and [docs/tools.md](tools.md).

---

## What you are *not* porting

The mod, the protocol, the tile-export pipeline, worldgen, AI, saves — all of that stays in
Qud + the existing mod. A Unity client is only planes-2-and-3 of the
[legacy-integration-playbook](legacy-integration-playbook.md): render the state and send input.
If you find yourself reimplementing game logic, stop — that belongs behind the socket.

See [migrating-clients.md](migrating-clients.md) for the portable-vs-engine-specific split and a
port checklist, and [client-in-unreal.md](client-in-unreal.md) for the Unreal equivalent.

# Migrating a Raves client between engines

Raves of Qud's value is a **stable seam**: an in-game mod publishes structured state and accepts
commands over a localhost socket, and *anything* on the other end can render it. The Godot
client in `godot/` is a reference implementation, not the API. This page is for porting a client
between engines — Godot → Unity, Godot → Unreal, or a fresh client in something else — and for
the "original devs or any other devs" who want reference code without adopting Godot.

Engine-specific how-tos: [client-in-unity.md](client-in-unity.md),
[client-in-unreal.md](client-in-unreal.md). This page is the map above them.

---

## The seam: what is fixed vs. what is yours

```
      ┌───────────────────────────── FIXED (the product) ─────────────────────────────┐
      │  Caves of Qud  +  mod/*.cs  ──[4-byte len][UTF-8 JSON] on TCP 48710──┐         │
      │  worldgen · AI · saves · tile export · turn resolution               │         │
      └──────────────────────────────────────────────────────────────────────┼─────────┘
                                                                             ▼
      ┌──────────────────────────── YOURS (the client) ─────────────────────────────────┐
      │  socket + framing · JSON parse · classification · colour · water math · input    │
      │  ── all PORTABLE LOGIC, identical across engines ──                              │
      │  mesh/material/camera/texture-upload/thread-marshal ── ENGINE-SPECIFIC ──        │
      └──────────────────────────────────────────────────────────────────────────────────┘
```

**Never edit the mod to satisfy a client.** If a field is missing, add it to the snapshot and
bump `Protocol.Version` (see below) — that serves every client at once. A client that changes
the mod for its own convenience forks the ecosystem.

---

## Portable vs. engine-specific — the line item view

| Concern | Portable (copy the rule verbatim) | Engine-specific (rewrite) |
|---|---|---|
| Framing | `[4-byte big-endian length][UTF-8 JSON]` | socket API (`StreamPeerTCP` / `TcpClient` / `FSocket`) |
| Threading | read off-thread, **render on main/game thread** | the marshal primitive (queue / `AsyncTask` / `call_deferred`) |
| Snapshot handling | **coalesce to newest per frame** (full state, not deltas) | — |
| Handshake | compare `protocol` int; `ClientProtocol`/`MinModProtocol` | status-line UI |
| Tile path | `tile.replace('/','_')` under `tilesDir`; glyph fallback + retry | PNG→texture upload; point/nearest filter |
| Self-heal race | flag missing static tiles, rebuild zone (bounded) | — |
| Classification | wall→prism, `layer≤2`→ground, else billboard | cube / quad / ISM / procedural mesh |
| Static/dynamic split | build zone once; rebuild creatures+`liquid`+`onFire` per turn | scene-graph node types |
| Colour | `fgHex` else `palette[char]`; `k`=`#0f3b3a` | `Color` / `FLinearColor` types |
| Water | actor recesses by `wade`/`swim` fraction, `bridge` cancels, only `sinks` | transform offset; axis (Y-up vs Z-up) |
| Input | `move`+`dir`, `wait`, `key`, `shot` | input system bindings |
| Validation | `tools/capture/*.py` read snapshots off the wire | — |

The left column is the same in every client — much of it is a line-for-line transcription of
`BridgeClient.gd` and `ZoneRenderer.gd`. The right column is the only real work.

---

## Concept crosswalk

| Godot (reference) | Unity | Unreal | Notes |
|---|---|---|---|
| `StreamPeerTCP` | `System.Net.Sockets.TcpClient` | `FSocket` (Sockets module) | all blocking-read on a worker thread |
| `_process(dt)` coalesce | `Update()` drain `ConcurrentQueue` | `Tick` drain locked buffer | render newest only |
| `call_deferred` / signals | `ConcurrentQueue` → main | `AsyncTask(GameThread,…)` | main-thread hand-off |
| `JSON.parse_string` | Newtonsoft / `System.Text.Json` | `FJsonObjectConverter` | Unity `JsonUtility` can't do it |
| `Image.load` + `ImageTexture` | `Texture2D.LoadImage` | `IImageWrapper` → `UTexture2D` | nearest/point filter |
| `BoxMesh` prism (greedy mesh) | `Cube` + `CombineMeshes` | `UInstancedStaticMeshComponent` | one draw call per zone |
| billboard `QuadMesh` | quad + billboard shader | plane + WPO billboard material | camera-facing |
| `StandardMaterial3D` + modulate | `MaterialPropertyBlock` | Dynamic Material Instance / `PerInstanceCustomData` | per-object tint |
| Y-up, metres | Y-up, metres | **Z-up, centimetres** | pick one grid basis, keep it central |
| `Input` → `send_command` | `Input` → `SendCommand` | Enhanced Input → `SendCommand` | same `command` frames |

---

## Port order (do it in this sequence)

Each step is verifiable before the next, so you never debug two unknowns at once:

1. **Socket + framing + handshake.** Connect, read frames, print `mod`/`protocol`. Success =
   your status line matches `tools/capture/snap.py`'s. No rendering yet.
2. **Priming + coalescing.** Send `wait` on connect; confirm you receive a snapshot and that a
   burst renders once, not N times. (Skip this and a zone-transition burst will stutter or crash.)
3. **Parse + dump.** Deserialize into your structs; log zone id, player, cell count. Compare to
   `snap.py summary`.
4. **Ground + walls (static).** Render the `layer≤2` and `wall` objects for one zone. This is the
   "does the world have a floor" milestone — the painted ground layer is the thing most likely to
   be silently missing (see [protocol.md](protocol.md#the-painted-ground-layer--read-this-first)).
5. **Tiles + colour.** Wire `tilesDir` loading and the palette; walls/floors get their art. Turn
   on the self-heal retry.
6. **Billboards + dynamic layer.** Stand up creatures/scenery; rebuild them per turn.
7. **Water + input.** Recess actors; bind movement → `move`. Now it's playable.
8. **Version discipline.** Set `ClientProtocol`/`MinModProtocol`; wire the status colours.

---

## Protocol versioning across clients

Every snapshot carries `mod` (human build string) and `protocol` (monotonic int). The rule that
keeps multiple clients honest:

- **Bump `Protocol.Version` in the mod whenever a client comes to depend on a new field**, and
  raise each client's `MIN_MOD_PROTOCOL` to match.
- History: `1` baseline · `2` `liquid` flag · `3` `onFire` flag.
- A mod `.cs` compiles only at Qud **startup** — a redeploy is inert until a restart. The
  handshake (green "up to date" / red "restart Caves of Qud" / yellow "re-export client") is the
  *only* signal that tells you which mod build is actually running. Every client must implement
  it, or you will debug code that isn't live.

New clients should target the **current** `Protocol.Version` and degrade gracefully on absent
optional fields (model them nullable/defaulted) rather than hard-failing — that way an older mod
build still renders, just without the newest flag.

---

## Gotchas that bite every port

These cost real days on the reference client; inherit the fixes for free.

- **Snapshots are full state, not deltas.** Rendering every queued snapshot instead of the
  newest reran heavy zone rebuilds back-to-back and **hard-crashed Godot's Metal allocator**.
  Coalesce to the latest per frame — step 2 above.
- **The painted ground layer is not an object.** ~55% of cells in a Joppa zone have *no
  GameObject* — Qud composites a ground tile onto them, emitted as a `RenderLayer 0` floor with
  `ground:true`, first in `objs`. Miss it and the world has no grass/dirt, and *querying objects
  won't reveal why* (there genuinely are none). This is the classic "my port renders a void" bug.
- **Engine API is main-thread-only.** Reading the socket on a worker is fine; touching
  scene/mesh/texture objects off the main/game thread is a silent no-op or a crash. Marshal.
- **Tile export is on-demand and races the static build.** First-sight walls/fences can bake a
  glyph if built before their PNG exists. Flag + bounded-rebuild (`STATIC_RETRY_MAX`).
- **Axis + scale.** Godot Y-up metres → Unreal Z-up centimetres is the top source of "everything
  is sideways / a thousand times too big." Centralize the grid basis.
- **`k` is dark teal (`#0f3b3a`), the Qud world colour — not black.** Hardcoding black for `k`
  paints the sky/void wrong. Always resolve through the snapshot `palette`.

---

## Working across the two dev machines

Client work is cross-platform and lives in engine projects, not behind the `plat_win.py` /
`plat_mac.py` OS seam — so a Unity or Unreal client can be developed on either the Mac or the PC
against the same mod. The mod itself currently runs on the Mac Qud install (README "Running
it"); a client on the PC just needs the socket reachable (same machine, or forward `48710`).
Keep the protocol constants (`DefaultPort`, `Protocol.Version`) as the single source of truth
both clients read.

---

## The one-paragraph pitch for the original devs

If you make a moddable turn-based game, this pattern gives you a **zero-risk external renderer**:
a ~600-line mod publishes what the player sees as JSON and accepts the same command tokens a
keypress makes, and a client in *any* engine renders it without ever forking your simulation.
The game stays authoritative for worldgen, AI, combat, and saves; the client is pure
presentation. Swap Godot for Unity or Unreal and nothing on the game side changes. That
separation — [the three planes](legacy-integration-playbook.md) — is the whole idea.

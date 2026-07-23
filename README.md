# Raves of Qud

A **2.5D / 3D augmentation layer for [Caves of Qud](https://www.cavesofqud.com/)**. It does
*not* reimplement the game. A real, paid, modded copy of Qud runs as the authoritative
simulation; an in-game C# mod publishes what the player sees each turn over a localhost
socket, and a Godot 4 client renders it as a lit 3D scene (greedy-meshed walls, billboarded
sprites, oriented fences) with an orbit/pan/zoom camera. Input round-trips back to Qud, which
resolves every turn.

> Requires your own paid copy of Caves of Qud. Ships **no** game assets — tiles are extracted
> at runtime from your own install into a local, git-ignored folder.

```
┌─────────────┐   command frames (TCP 48710)   ┌────────────────────────┐
│   Godot 4   │ ─────────────────────────────▶ │  Caves of Qud (real)   │
│ 2.5D client │                                │  + Raves bridge mod    │
│  (view)     │ ◀───────────────────────────── │  = authoritative sim   │
└─────────────┘   snapshot frames (per turn)    └────────────────────────┘
```

Qud owns worldgen, AI, combat, items, saves, tiles — everything. This repo owns two mappings:
Godot input → Qud command, and Qud zone state → 3D scene.

---

## Table of contents
1. [Repo layout](#repo-layout)
2. [Running it](#running-it)
3. [Architecture & the threading model](#architecture--the-threading-model)
4. [Hard-won platform constraints](#hard-won-platform-constraints) ← read this first
5. [The tile system](#the-tile-system-engine-assisted-extraction)
6. [Wire protocol (the snapshot)](#wire-protocol-the-snapshot)
7. [Qud data model & mappings](#qud-data-model--mappings) ← the "datatypes" reference
8. [Godot rendering model](#godot-rendering-model)
9. [The investigation toolkit](#the-investigation-toolkit)
10. [Verified Qud API reference](#verified-qud-api-reference)
11. [Open problems / next steps](#open-problems--next-steps)

---

## Repo layout

```
mod/                 Caves of Qud C# scripting mod (the bridge / server)
  Protocol.cs, Json.cs, MiniJson.cs, BridgeServer.cs   pure .NET — no Qud types, unit-testable
  Bridge.cs          per-turn tick: apply queued commands, publish snapshot
  BridgePart.cs      IPart on the player; fires on EndTurnEvent
  PlayerBridgeMutator.cs   [PlayerMutator] attaches BridgePart at game start
  ZoneSnapshot.cs    serialize the active zone -> snapshot JSON
  TileExporter.cs    QUEUE side (turn thread): record tile paths to export, no Unity calls
  TileExportPump.cs  MAIN-thread export via GameManager.uiQueue: atlas readback -> PNG
  RavesOfQudBridge.csproj   DEV-TIME compile harness (see toolkit)
  manifest.json
godot/               Godot 4.x client (GDScript)
  BridgeClient.gd    TCP framing, reconnect, snapshot signal, command send
  ZoneRenderer.gd    the renderer — walls/floors/sprites/fences, colour model  ← the meat
  Main.gd            scene wiring, orbit/pan/zoom camera, input -> CmdMove*
docs/protocol.md     wire format
tools/tiletool/      AssetsTools.NET inspector used to reverse the tile storage (diagnostic only)
```

Exported tiles live **outside** the repo: `~/Library/Application Support/RavesOfQud/tiles/`.

---

## Running it

### Environment (macOS, this is where it was built)
- Game install: `~/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app`
  (native macOS **IL2CPP** build). Runtime C# mods compile in-process via the game's bundled
  Roslyn, so **no Windows/PC build is needed** — it all runs on the Mac.
- Mods folder: `~/Library/Application Support/com.FreeholdGames.CavesOfQud/Mods/`
- Assembly: `CoQ.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll`
  (retains source-file path metadata → clean, navigable ILSpy).
- Moddable XML: `CoQ.app/Contents/Resources/Data/StreamingAssets/Base/`
  (`Commands.xml`, `Colors.xml` are real; **`ObjectBlueprints.xml` on disk is a 67-byte stub** —
  the real blueprint/tile data lives in the packed Unity bundles).
- `.NET SDK` via Homebrew: `dotnet` at `/opt/homebrew/bin` (may need
  `export PATH="/opt/homebrew/bin:$PATH"` in non-login shells).
- Crash log: `~/Library/Logs/Freehold Games/CavesOfQud/Player.log`

### Deploy the mod
```bash
cp mod/*.cs mod/manifest.json \
  ~/Library/Application\ Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/
```
In-game: enable the mod and **allow local C# scripting mods**. Qud auto-applies mod code.
**Changing a mod `.cs` requires a full Qud restart** (mods compile at startup). Changing a
Godot `.gd` only needs re-running the scene.

### Run the client
Open `godot/` in Godot 4.x and press play. It auto-connects to `127.0.0.1:48710` and retries
once a second until Qud is listening (the mod opens the socket on the first turn).

### The live loop
Qud runs (backgrounded is fine) as the server. Godot is the only window you need to watch.
Move with arrows/numpad in **either** — commands round-trip through Qud so the sim resolves
combat/doors/AI exactly as a keypress would.

---

## Architecture & the threading model

The single most important thing to internalise, because it dictates everything:

**Qud runs its turn logic on a dedicated BACKGROUND thread** (`XRLCore._ThreadStart` →
`RunGame` → `ProcessSingleTurn`), *not* Unity's main/render thread.

- **Reading game state** (Zone, Cell, Render, GameObject) is safe on that turn thread — that's
  where the objects live. `EndTurnEvent`, and thus `Bridge.Tick`, fire there.
- **Any Unity graphics call** on the turn thread (`Texture2D` ctor, `Graphics.Blit`,
  `ReadPixels`, `SpriteManager.GetUnitySprite`) → **"Graphics device is null" → an uncatchable
  native crash.** (Learned by crashing.)

So the mod is split by thread:
- **Turn thread** (`Bridge.Tick` via `EndTurnEvent`): read the zone, serialize JSON, enqueue
  tile-export requests, publish over the socket. No Unity graphics, ever.
- **Main thread**: tile export runs here via `GameManager.Instance.uiQueue.queueTask(...)`
  (see below), the only place graphics calls are legal.

The socket server itself (`BridgeServer.cs`) is pure .NET on its own background threads;
inbound commands land in a `ConcurrentQueue` and are applied on the turn thread.

---

## Hard-won platform constraints

These cost real time to discover. Save yourself:

| Constraint | Consequence |
|---|---|
| **Turn logic is off Unity's main thread** | Graphics on the turn thread crashes hard. Marshal to main thread. |
| **Harmony is blocked on Apple Silicon macOS** (`mprotect EACCES`) | Runtime method-patching doesn't work. Can't patch `GameManager.LateUpdate` etc. Use Qud's own events. |
| **Qud's whole event system runs on the turn thread** | Even `BeforeRenderEvent` fires there, not the main thread (verified with a `UnitySynchronizationContext` probe). No event hook reaches the main thread. |
| **`GameManager.Instance.uiQueue`** is the escape hatch | `QupKit.ThreadTaskQueue.queueTask(Action, delay)` — drained on the UI/main thread. This is how graphics work gets onto the main thread. Confirmed working. |
| **`SynchronizationContext.Current is UnitySynchronizationContext` only on the main thread** | Cheap, crash-proof main-thread guard if you're unsure what thread you're on. |
| **Tiles are packed in Unity 6 atlases, not loose PNGs** | Can't point Godot at files on disk. Extract via the running game (below). |
| **Exported tile files are PNG content even when named `.bmp`** | Godot's `Image.load_from_file` picks the loader by extension and fails. Read bytes and `load_png_from_buffer`. |
| **`string`-grepping `Assembly-CSharp.dll` lies about casing** | It reported Render fields lowercase; they're capitalized. Reflect with `MetadataLoadContext` for ground truth. |

---

## The tile system (engine-assisted extraction)

Qud has **~44,525 tiles** packed into a few dozen Unity-6 atlas pages, with a path→rect lookup
baked into a MonoBehaviour. Decoding atlases + reversing that manifest offline is fragile — so
we don't. **The running game already has the atlas loaded; the mod asks it for pixels:**

1. Turn thread (`TileExporter.Ensure`): dedupe + enqueue the tile path. **No Unity calls.**
2. Main thread (`TileExportPump.Export`, via `uiQueue`):
   `Kobold.SpriteManager.GetUnitySprite(path)` → `sprite.texture` (atlas) + `sprite.textureRect`
   → scaled `Graphics.Blit` of just that rect into a small `RenderTexture` → `ReadPixels` →
   `EncodeToPNG` → write to `~/Library/Application Support/RavesOfQud/tiles/`.
3. On-demand (per distinct tile seen), cached, resumable. The snapshot carries `tilesDir` so
   Godot knows where to load.

You can **force-export tiles that never occur naturally** (e.g. the isolated wall variant used
for a fully-bordered top) with `TileExporter.Ensure("Assets/Content/Textures/Tiles/wall_rock-00000000.bmp")`
— the atlas has all 256 autotile variants regardless of what's placed in a zone.

Tile path → filename: replace `/ \ :` with `_`. Content is always PNG.

---

## Wire protocol (the snapshot)

localhost TCP **48710**. Every message: `[4-byte big-endian length][UTF-8 JSON]`.

**Server → client (once per turn):**
```json
{
  "type": "snapshot",
  "tilesDir": "/Users/you/Library/Application Support/RavesOfQud/tiles",
  "zone":   { "id": "JoppaWorld.11.22.1.1.10", "width": 80, "height": 25 },
  "player": { "x": 40, "y": 12 },
  "cells": [
    { "x": 41, "y": 12, "objs": [
        { "glyph":".", "tile":"...deep-00100010.png", "color":"&b^B", "tilecolor":"&b",
          "detail":"B", "layer":2, "wall":false, "solid":false, "occluding":false },
        ... bottom→top of the cell stack ...
    ]}
  ]
}
```
Only **non-empty** cells are sent. Snapshots only fire on a **turn** (the player must act) —
capture scripts get nothing until you take a step.

**Client → server:** `{ "type":"command", "name":"move", "dir":"N" }` — `dir` ∈
`N S E W NE NW SE SW`. Applied on the turn thread; the sim resolves the whole turn.

---

## Qud data model & mappings

This is the reference the project was reverse-engineered into. **All verified against the
live 1.0 build (Unity `6000.0.77f1`) by reflection + live capture, not from memory.**

### Per-object fields (from `XRL.World.Parts.Render` + `GameObject`)
| snapshot field | Qud source | notes |
|---|---|---|
| `glyph` | `Render.RenderString` | ASCII char |
| `tile` | `Render.Tile` | atlas path, e.g. `Assets/Content/Textures/Tiles/wall_rock-11111111.bmp` |
| `color` | `Render.ColorString` | **full** string, `&fg^bg` |
| `tilecolor` | `Render.TileColor` | the tile's foreground colour |
| `detail` | `Render.DetailColor` | the tile's detail/highlight colour |
| `layer` | `Render.RenderLayer` | draw order → drives flat/vertical classification |
| `wall` | `GameObject.IsWall()` | true for solid tagged walls (rock/metal/brinestalk) |
| `solid` | `Physics.Solid` | impassable |
| `occluding` | `Render.Occluding` | blocks line of sight → the prism-vs-sprite discriminator |

### Colour model (this bit is subtle and non-obvious)
Qud `ColorString` = `&X^Y`: `&X` = **foreground**, `^Y` = **background**. Tiles are 2-colour
masks recoloured on the CPU:
- **black** mask pixels → foreground (`TileColor`)
- **white** mask pixels → detail (`DetailColor`)
- **transparent** → the cell **background** (Qud's dark-green world background). Do **not** flood
  gaps with the object's `^X` — for e.g. metal (`&r^C`) the cyan belongs to the *detail/border*
  pixels, not the gap fill. Gaps read as the world green.

**Palette (single letters, from `Colors.xml`) — note the counter-intuitive ones:**
| | | | | | | | |
|---|---|---|---|---|---|---|---|
| `Y`=**white** | `y`=gray | `K`=black | `W`=**gold** | `w`=**brown** | `O`/`o`=orange | | |
| `r`/`R`=dark red/red | `g`/`G`=dark green/green | `b`/`B`=dark blue/blue | `c`/`C`=dark cyan/cyan | `m`/`M`=dark magenta/magenta | | | |

`_qud_color()` in `ZoneRenderer.gd` keys off the **trailing letter** of a colour code.

### Tile geometry: the 2.5D convention
Tiles are **16×24**. The vertical split matters:
- **top 16×16** = the top-down body (what you see looking down).
- **bottom 16×8** = the **south front-face** (the elevation you see looking north at a wall).

North faces are *never drawn* — Qud only draws south faces in its top-down view. Directional
tiles (fences) are drawn as a **front elevation** when perpendicular to view (E-W) and
**top-down** when parallel (N-S). Content can be vertically padded/centred inside the 24px
frame — crop to the opaque rows to seat things on the ground.

### Autotiling suffixes
- **Walls & water** (`wall_rock-XXXXXXXX`, `wall_brinestalk-XXXXXXXX`, `deep-XXXXXXXX`): an
  **8-bit neighbour bitmask** (`-11111111` = fully surrounded interior; `-00000000` = isolated,
  bordered on all sides). In 3D you mostly *discard* the autotiling for faces (real geometry
  supplies connectivity) but *reuse* the bitmask idea for face culling.
- **Fences/pipes** (`fence_ns`, `ironfence_ew`, `pipe_ne`, bare `fence_`): the suffix after the
  last `_` is the **connection set** ⊆ `{n,s,e,w}`. `_connector_dirs()` parses it.

### RenderLayer → classification (calibrated from live data)
| layer | contents | 3D treatment |
|---|---|---|
| 0 | ground clutter (`sw_ground_dots`, `*`) | flat floor |
| 2 | liquids (`deep-*` water) | flat floor |
| 3 | trees, plants, watervines | upright billboard |
| 5 | small stones | upright billboard |
| 6 | furniture, torches | upright billboard |
| 7 | walls, fences, doors, tents | prism / oriented panel |
| 10 | creatures | upright billboard |
| 100 | special NPCs | upright billboard |

**Classification rules (in `ZoneRenderer.gd`):**
- **prism** (3D box): `wall && occluding` → rock/metal/brinestalk. `occluding` is what
  separates real walls (occlude) from **fences** (don't).
- **deck** (flat + opaque): the object carries the `Bridge` int-property (see below).
  Checked *before* layer, because bridges are RenderLayer 3.
- **flat floor**: `layer <= FLOOR_LAYER_MAX (2)`.
- **directional connector** (oriented standing panels): wall-flagged tile matching
  `family_<dirs>` (fences, pipes).
- **upright billboard**: everything else.

### Water depth & bridges
Both are **first-class Qud concepts** — don't infer them from tile names.

- **Depth** is `LiquidVolume.Volume` (`Base/ObjectBlueprints/PhysicalPhenomena.xml`: puddle 500 →
  deep pool 4000 → extra-deep 8000), surfaced as `Cell.HasWadingDepthLiquid()` /
  `HasSwimmingDepthLiquid()`. The `deep-`/`shallow-`/`puddle_N` tile family is *chosen from*
  volume by the `PaintedLiquidAtlas` system, so it's a symptom, not the source of truth.
  **Confirmed on live data** (`JoppaWorld.11.22.1.1.10`): `wade` correlated 1:1 with `deep-*`
  tiles — 52 cells, 52 `deep-*`, zero `shallow-`/`puddle_N`. So wading depth *is* "deep water",
  and you don't get ankle-deep in puddles. Watervines sit in cells that are **not** wading depth.
- **Bridges** are `<intproperty Name="Bridge" Value="1" />` on the blueprint —
  `Walkway`, `Bridge`, `BrineBridge`, `WoodFloor`, `MarbleFloor` in `ZoneTerrain.xml`.
  `Cell.HasBridge()` for the cell; `GameObject.HasIntProperty("Bridge")` for the object.
- **Tile shape gotcha**: bridge art (`Tiles/sw_floor_brickb1-4.bmp`) is **line-work on a fully
  transparent field** — only ~25% of pixels are opaque. Rendered as-is it does *not* hide the
  water beneath it. Recolour it with `fill = true` so the transparent field becomes ground colour.
  Water tiles (`Liquids/Water/deep-*`) are the opposite: **100% opaque** noise masks.
- **A bridge cell's stack**, straight off the wire — the water is a separate object *below* the
  deck, so the deck has to out-Y it rather than replace it:
  ```
  (66,6) wade=true swim=false
     idx=0  layer=2  bridge=false  Liquids/Water/deep-00100010.png  &b^B
     idx=1  layer=3  bridge=true   Tiles/sw_floor_brickb3.bmp       &w    <- BrineBridge
  ```
- **Tile paths mix separators**: creature tiles arrive with **backslashes**
  (`creatures\sw_glowfish.bmp`), most others with `/`. `_mask()`/`TileExporter.FileFor` normalise
  both to `_`. Anything new that parses a tile path must handle both — note `_connector_dirs()`
  uses `get_file()`, which splits on `/` only.

**The rendering rule: keep the water flat, recess the actor.** Water renders as an ordinary floor
quad. A creature standing in it (`sinks` = `IsCreature && !IsFlying`) is drawn with its sprite
**cropped at the waterline** rather than lowered — the water is a flat quad with no volume, so a
lowered sprite would just poke out beneath it as soon as the camera tilts. The crop is measured
against the tile's **opaque band** (`_opaque_v`), not the 16×24 frame, because the art is padded
inside the frame. A bridge sets `sink = 0`: you cross at full height over an opaque deck.

---

## Godot rendering model

`ZoneRenderer.gd` rebuilds per snapshot. Pools nodes (sprites, floors, labels, fences); walls
are rebuilt meshes.

- **Walls → greedy-meshed prisms, one mesh per wall TYPE** (family + fg + detail + bg). Top faces
  greedy-merged into maximal rectangles; side faces emitted only where **exposed**; per-face
  **baked vertex-colour shading** (unshaded material) so the carved form reads without depending
  on scene lighting (which was unreliable — the win was `ambient_light_source = COLOR`, but the
  vertex-colour bake is what made it robust).
  - Wall **top** = framed checker (real border from the isolated `-00000000` tile if exported,
    else a synthetic frame) — tiled per cell so borders form a stone grid.
  - Wall **side** = the front-face strip (bottom 16×8) of a south-open variant.
- **Floors** = flat `PlaneMesh` quads, textured (or a small coloured dot for glyph-only floors).
- **Ground** = one big `WORLD_BG` (dark-green) plane under everything, so the world isn't a
  black void between dots.
- **Fences/pipes** = **per-connection half-panels**: each connected direction gets an upright
  `QuadMesh` half (centre→edge), so neighbours meet at the shared edge (continuous runs) and
  corners form a clean L. Every segment uses the family's **E-W elevation art** (rotated per
  axis), UV-cropped to the opaque rows so it sits flush on the ground.
- **Camera** (`Main.gd`): left-drag orbit, right/middle-drag pan (persistent offset), wheel zoom.

---

## The investigation toolkit

The workflow that made blind, untestable-by-the-agent changes tractable:

- **Compile harness** — `mod/RavesOfQudBridge.csproj` references the game's own
  `Managed/*.dll`, so `dotnet build mod/RavesOfQudBridge.csproj` type-checks the mod against the
  **real API**. Dev-time only; Qud compiles the shipped `.cs` at runtime. Target **netstandard2.1**
  (Unity 6). This is how you catch API mismatches before a game restart.
- **Reflection probe** — a throwaway `dotnet` console using `System.Reflection.MetadataLoadContext`
  to read exact type/member signatures out of `Assembly-CSharp.dll` **without running it**. This
  is the *authoritative* API source (string-grepping the DLL misled on field casing). Load all of
  `Managed/*.dll` + the runtime dir into a `PathAssemblyResolver`; core assembly `mscorlib`.
- **Capture scripts** — small Python sockets to `127.0.0.1:48710` that read framed snapshots and
  aggregate (layer histograms, wall families, colour strings, occluding/solid). Remember: a frame
  only arrives on a **turn**, so you must take a step in-game. Beware `python … &` inside a
  backgrounded shell call — the `&` detaches it from the task wrapper.
- **Decode tiles** — a minimal pure-Python PNG decoder (no Pillow) to inspect a tile's pixels /
  opaque-row band / colours; recolour + upscale to preview how a tile will render.
- **Player.log** — the mod's `[raves] …` lines and any native crash stack land here:
  `~/Library/Logs/Freehold Games/CavesOfQud/Player.log`.

---

## Verified Qud API reference

Namespaces and signatures confirmed by reflection against `6000.0.77f1`. **Not a stable public
API — re-verify after a Qud update with the reflection probe.**

```
XRL.The.ActiveZone : Zone            XRL.The.Player : GameObject
XRL.IEventRegistrar                  XRL.IPlayerMutator.mutate(GameObject)   [PlayerMutator] attr
XRL.World.IPart:
    Register(GameObject, IEventRegistrar) ; FireEvent(Event)
    WantEvent(int ID, int cascade)  ;  HandleEvent(EndTurnEvent) / HandleEvent(BeforeRenderEvent)
XRL.World.EndTurnEvent  (pooled; static .ID)      per-turn hook, fires on the TURN thread
XRL.World.BeforeRenderEvent (static .ID)          also fires on the TURN thread, NOT main
XRL.World.Zone:      fields Width, Height (int) ; prop ZoneID (string) ; GetCell(int,int) -> Cell
XRL.World.Cell:      X, Y, Objects, ParentZone
XRL.World.GameObject:
    GetPart<T>() ; HasPart<T>() ; AddPart(IPart) ; CurrentCell (prop) ; Physics (field)
    IsWall() ; IsOpenLiquidVolume() ; IsWadingDepthLiquid()
XRL.World.Parts.Render (fields CAPITALIZED):
    RenderString, ColorString, TileColor, DetailColor, Tile (string), RenderLayer (int)
    Visible (bool prop), Occluding (bool prop)
XRL.World.Parts.Physics:  Solid (bool prop)
XRL.World.CommandEvent.Send(GameObject actor, string cmd, GameObject target, Cell cell,
    int standoff, bool forced, bool silent, GameObject handler)     // no 2-arg overload
    // movement command IDs: CmdMoveN/S/E/W/NE/NW/SE/SW  (Commands.xml)
Kobold.SpriteManager (static):
    GetUnitySprite(string) -> UnityEngine.Sprite
    GetTextureInfo(string, bool) ; TryGetTextureInfo(string, out exTextureInfo) ; HasTextureInfo(string)
GameManager (global namespace):
    static Instance (field) ; uiQueue, gameQueue (QupKit.ThreadTaskQueue) ; MainCamera
QupKit.ThreadTaskQueue:
    queueTask(Action, int delay) ; queueSingletonTask(...) ; executeTasks() ; HasTask() ; awaitTask(Action)
```

---

## Open problems / next steps

- **Water depth tuning**: `SINK_WADE` / `SINK_SWIM` in `ZoneRenderer.gd` are eyeballed fractions.
  There's no swim animation or waterline ripple yet, and the cut edge is hard.
- **Tents** occlude, so they're currently prisms; probably want them as sprites (special-case).
- **Non-rock wall tops/sides**: the top-16×16 / bottom-16×8 split is rock-specific; brinestalk/metal
  tiles are structured differently, so their tops/sides are approximate (colours are correct).
- **Neighbour-zone streaming** (the original day-one goal): the 3×3 parasang, so you can see
  adjacent zones "over the horizon." Not started. The map hierarchy: world 80×25 parasangs;
  parasang = 3×3 zones; zone = 80×25 cells; plus Z-strata.
- **Exact world background colour**: `WORLD_BG` is an estimate of Qud's dark-green cell background.
- **Perf**: full re-render per snapshot; cell-level diffing and MultiMesh are the obvious wins if
  neighbour-zones multiply the payload.

### Working style that paid off
Ground every change in real data (reflect the DLL, capture a live snapshot, decode a tile) rather
than guessing; the agent can't see the Godot viewport, so the loop is **compile-harness →
deploy → user re-runs → capture/screenshot → adjust**. Keep the Qud-coupled surface small and
isolated so a Qud update is a quick re-verify, not a rewrite.
```

**License:** MIT (see `LICENSE`). Requires a separately-purchased copy of Caves of Qud; Caves of
Qud and its assets are © Freehold Games.

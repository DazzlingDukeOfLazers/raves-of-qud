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
8b. [The feedback loop (cell inspector)](#the-feedback-loop-cell-inspector)
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

### ⚠️ The single most important thing: a cell is NOT just its objects

**Qud draws a painted ground layer that is not in the object model.** In a Joppa zone,
**1103 of 2000 cells contain no `GameObject` at all** — and Qud still paints dirt and grass
on them:

```
object-free cells whose compositor still yields a tile: 1103
   1,0 = Tiles/tile-dirt1.png        3,0 = Terrain/sw_grass2.bmp
   2,0 = Terrain/sw_grass1.bmp       4,0 = assets_content_textures_tiles_tile-grass1.png
```

`Cell.Render()` composites it and returns a `RenderEvent` carrying `Tile`, `ColorString`,
`DetailColor`, `BackgroundString`, `RenderString`, `HFlip`/`VFlip`. **Iterating `Cell.Objects`
alone gives you a world with no ground cover.** `ZoneSnapshot` emits this as a RenderLayer 0
floor at the bottom of every cell's stack.

> **Cost of not knowing this:** the missing grass survived *six* wrong hypotheses and four
> shipped fixes (`RenderTile`, the `Render` accessors, a tile-only filter, `GetObjects()`) —
> every one of which operated on the object path and was therefore **inert by construction**.
> "There is no grass blueprint in this zone" was true and useless: grass is not a blueprint.
>
> What broke it was **measuring instead of hypothesising**. The mod started emitting, per cell,
> `nHeld` (`GetObjectCount`), `nRendered` (`RenderedObjectsCount`) and `nSent`. They came back
> `1001 == 1001 == 1001`, which proved nothing was being dropped and eliminated the entire
> object path in one step — leaving only "Qud draws it from somewhere else." **When a search
> keeps failing, stop refining the search and verify the dataset is complete.**

### Accessors vs fields — `getTile()`, not `.Tile`
`Render.Tile` / `Render.RenderString` are the **blueprint's static values** and are empty for
anything that picks its art at runtime (`PickRandomTile`, `RandomTileOnMove`, harvestable
states). The `Render` part has accessors that resolve what is actually drawn:
`getTile()`, `getRenderString()`, `getTileColor()`, `getTileOrRenderColor()`, `GetRenderColor()`.

`GameObject.RenderTile(ConsoleChar)` is the **override hook** for parts that paint themselves.
In a whole Joppa zone it fired for **zero** objects — don't rely on it, but when it does fire
its `ConsoleChar` carries already-resolved RGB (`TileForeground`/`TileBackground`/`Detail`).

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

**Palette — don't hand-estimate it. `Base/Colors.xml` names the 16 colours but contains
NO RGB**; the values live in code. The mod reads them out of
`ConsoleLib.Console.ColorUtility.colorFromChar(char)` (a static dictionary lookup returning a
struct — no graphics calls, safe on the turn thread) and ships them in every snapshot as
`palette`. Measured values:

| | | | |
|---|---|---|---|
| `k` **#0f3b3a** | `K` #155352 | `y` #b1c9c3 | `Y` #ffffff |
| `w` #98875f | `W` #cfc041 | `g` #009403 | `G` #00c420 |
| `b` #0048bd | `B` #0096ff | `c` #40a4b9 | `C` #77bfcf |

> **`k` is not black — it is `#0f3b3a`, a dark teal, and it IS the colour of the Qud world.**
> Guessing it as near-black is what made the 3D view render on a black void instead of Qud's
> field, and flattened wall-vs-floor contrast. `WORLD_BG` derives from `palette["k"]`.
>
> Also: `ColorUtility.CAMERA_BACKGROUND` is **not** the field colour despite the name — it's
> the alias `"camera background"` → `#40a4b9`, plain cyan. Trusting it painted the entire world
> turquoise. Verify a value before believing a field name.

`_qud_color()` in `ZoneRenderer.gd` takes the **foreground** — the half *before* the `^` — and
prefers the shipped `palette` over the hand-estimated fallback table.

> A ColorString is `&FG^BG`. Keying off the **trailing letter** returns the BACKGROUND whenever
> one is present. The player is `&y^k`, so it read as `k` — `#0f3b3a`, the world's own dark
> teal — and a pale grey figure rendered dark-teal-on-dark-teal, with only its red detail
> pixels visible. Objects carrying a `TileColor` were unaffected (that field has no `^`), which
> is why walls and water looked correct and the bug stayed hidden.

### Tile geometry: the 2.5D convention
Tiles are **16×24**, packing two views into one image:
- the **top-down cap** (what you see looking down)
- below it, the **south front-face** (the elevation you see looking north at a wall)

**The boundary is NOT at row 16, and is not the same for every family.** Measured from the
isolated (`-00000000`) tiles:

All three wall families share the same structure — the face is the **last 10 rows**:

```
row 13   #o............o#     cap's bottom rim (matches the interior pattern)
row 14   #oooo##oo##oooo#     the wall's TOP LIP — belongs to the FACE
row 15+  #o###o####o###o#     face proper
```

| family | cap | separator | face |
|---|---|---|---|
| `wall_rock-00000000` | rows 0–13 | none | rows 14–23 |
| `wall_brinestalk-00000000` | rows 0–13 | none | rows 14–23 |
| `wall_metal-00000000` | rows 0–13 | none | rows 14–23 |
| `wall_metal-10100010` | rows 0–12 | **row 13 blank** | rows 14–23 |

Two guesses were wrong before this: the tile **width** (16), and **9 rows** (face at 15). Both
leave row 14 — the wall's lip — sitting on the roof, which reads as a stray band of wall texture
along the roof's front edge. `_wall_split()` honours an explicit transparent separator when the
art has one, else takes the last `WALL_FACE_ROWS` (10) rows.

> Getting this from the `-11111111` interior tile is impossible — it has no borders. Always
> measure against the **isolated `-00000000`** variant, where every edge is drawn.

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

**Roofs use each cell's own autotile variant.** A wall's `-XXXXXXXX` suffix says which of its
8 neighbours are also walls, and Qud's art omits the border on those edges. Canonicalising every
wall to `-11111111` and capping it with the isolated `-00000000` tile draws all four borders on
every cell, so a run of wall reads as a **grid of separate framed squares** instead of one
continuous roof. `_rebuild_walls` groups roof cells **by variant** — one mesh per variant — so
shared edges join seamlessly. Sides stay greedy-merged; only the cap needs per-cell art.

**Classification rules (in `ZoneRenderer.gd`):**
- **prism** (3D box): `wall && occluding` **and the tile is not a `family_<dirs>` set** →
  rock/metal/brinestalk.
- **deck** (flat + opaque): the object carries the `Bridge` int-property (see below).
  Checked *before* layer, because bridges are RenderLayer 3.
- **flat floor**: `layer <= FLOOR_LAYER_MAX (2)`.
- **directional connector** (oriented standing panels): any tile matching `family_<dirs>` —
  fences, pipes, tent walls, **and axles**. See the gate note below.
- **upright billboard**: everything else.

**User verdicts override everything.** Some facts are not in Qud's data at all: a water wheel
runs east–west, but nothing in `sw_waterwheel_1` says so — no suffix, no blueprint flag. Inspect
a tile, use the form in the lower right, and the verdict is written to
`RavesOfQud/reports/<zone>_<x>-<y>_<tile>_v<n>.md`. `ZoneRenderer._load_overrides()` re-reads
that directory every snapshot and keys verdicts by **tile family**, so one report covers every
variant (`sw_waterwheel_1` and `_3`; every `wall_rock-XXXXXXXX`). Verdicts apply live — file one,
take a turn, see it. Verdicts come on **two independent axes**, and a tile can carry one of each:

| axis | verdicts | effect |
|---|---|---|
| **shape** | wall · panel N–S · panel E–W · billboard · flat · not-drawn | what geometry gets built |
| **fill** | fill MORE · gaps BACKGROUND · gaps TRANSPARENT · whole tile OPAQUE | how the art's transparent pixels are treated |

`fill the holes with BACKGROUND` (`Fill.SPAN`) is the **union of three** rules — enclosed gaps
(`INTERIOR`), row-spans and column-spans. Each catches holes the others miss, and none is a
superset: a water wheel's paddle bottoms fill only by row-span; a millstone's side notches only by
enclosure; the pinched neck joining a millstone's cap to its body only by column-span. So "fill it
in" is all three. It always fills ≥ the default and never squares off the silhouette — that's
`ALL`. Wheel 130→141, millstone 76→96 (the cap now reads as one solid stone with the body).

Colour, height, position and duplicated remain notes for a human. Fill is its own axis because
the geometric rules genuinely cannot settle it — whether a water wheel's paddle compartments
should read as background or as see-through is a judgement about the picture, not a property
of it.

> Mind the axis wording: **running E–W means the faces point N/S.** The form labels say both.

**What counts as a directional connector.** The `family_<dirs>` suffix alone is too weak — an
item or creature tile ending `_e`/`_ne` would match by accident. This was originally gated on the
**wall** flag, which was safe but too narrow: axles (`sw_axle_2_ew`) are machinery, not walls, so
they fell through to a billboard and lay *across* their run instead of along it. The gate now is:
wall-flagged qualifies outright; anything else must **also have its family's `_ew` sibling on
disk**, which a real directional family ships and an accidental name collision does not.

**Panel height scales with the art.** `PANEL_REF_ROWS` (10) is a standard fence's opaque band, and
`FENCE_H` is calibrated to it, so a fence still lands at exactly 0.6 while an axle's 2-row shaft
gets 0.12 instead of being smeared up to fence height. Sight-blocking connectors (tents) still
take `WALL_H` outright.

**Painted ground vegetation stands up.** The painted layer is flat by default — dirt, gravel —
but grass is cover you stand among, not a texture you walk on, so it routes to the billboard
path and is seated on the ground like any plant. The test is `UPRIGHT_GROUND` in
`ZoneRenderer.gd`, matched against the tile name. **This is a name heuristic**, which this
codebase otherwise avoids in favour of Qud's own predicates — but the painted layer comes from
`Cell.Render()` with no GameObject or blueprint behind it, so the tile path is the only signal
there is. Extend the list as new cover appears.

**`occluding` sets a panel's HEIGHT, not its shape.** This is the subtle one. A tent wall
is a fence at full height: its art is `tent_nw`/`tent_ew`/`tent_ns` — the same connection-set
naming as `fence_`/`pipe_` — but it *occludes*. Testing `wall && occluding` first claimed
tents as blocks before they could reach the connector path. So the directional-family test
comes first, and `occluding` only chooses `WALL_H` (tents) vs `FENCE_H` (pickets, pipes).
Real walls are safe because `wall_rock-11111111` / `wall_brinestalk-*` / `wall_metal-*` are
**autotile bitmasks**, which don't parse as a connection set.

Verify a rule change with `python3 tools/capture/snap.py classify`, which buckets every
object in the live zone by outcome. After the tent change: `panel(tall)` = 13, all `tent_*`;
`prism` = 186, only `wall_brinestalk-*` and `wall_metal-*`; `panel(low)` = 28, all `fence_*`.
Note it *reimplements* the renderer's rules in Python, so it's a cross-check, not proof —
the authoritative answer is the `RENDERED` line from `CellInspector`.

### Water depth & bridges
Both are **first-class Qud concepts** — don't infer them from tile names.

- **Depth** is `LiquidVolume.Volume` (`Base/ObjectBlueprints/PhysicalPhenomena.xml`: puddle 500 →
  deep pool 4000 → extra-deep 8000), surfaced as `Cell.HasWadingDepthLiquid()` /
  `HasSwimmingDepthLiquid()`. The `deep-`/`shallow-`/`puddle_N` tile family is *chosen from*
  volume by the `PaintedLiquidAtlas` system, so it's a symptom, not the source of truth.
  **Confirmed against a control** (`JoppaWorld.11.22.1.1.10`, `snap.py water`): in a frame that
  contains *all three* water families, `wade` holds all 52 `deep-*` and the `dry` bucket holds
  all 13 `shallow-*` and all 4 `puddle_*`. So wading depth **is** deep water, and you don't
  sink in puddles. Watervines also sit in non-wading cells, so they keep full height.

  > Methodology note worth repeating: the *first* capture of this zone happened to contain no
  > shallow water at all, and "no shallow tiles in a wade cell" looked like proof. It wasn't —
  > it was absence of evidence. The claim only became real once a frame contained shallow water
  > that could have been flagged wading and wasn't. When a correlation here looks perfect, check
  > that the negative case is actually present in the sample.
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

## The feedback loop (cell inspector)

Claude cannot see the Godot viewport, and describing a render in prose is the slowest and
least reliable channel in this project. So the client reports on itself.

**Ctrl/Cmd+click a tile, or hover and press `I`.** The report goes to an on-screen panel, the
clipboard, and `~/Library/Application Support/RavesOfQud/selection.txt` (plus an append-only
`selections.log`). Nothing needs transcribing — read the file.

It pairs the two things that can disagree:

```
mod build: 2026-07-23h painted-ground        <- WHICH BUILD produced this
 [1] 'brinestalk' Brinestalk
     layer=3  glyph=''
     tile     'assets_content_textures_tiles_tile-brinestalk.png'
     png      ...png  16x24  opaque rows 2..21     <- art on disk, or MISSING
     colour   color='&w' tilecolor='' detail='g'
     flags    wall=0 occluding=1 solid=0 bridge=0 sinks=0
     RENDERED billboard, 24 px enclosed gap -> bg  y=0.31   <- what the renderer DID
```

- **`mod build:`** — mod `.cs` only compiles at Qud startup, so a deploy does nothing until a
  restart. Without this line you cannot tell whether the running code contains your fix.
  Several rounds of this project's debugging were spent reasoning over the wrong build.
- **`RENDERED`** — recorded by `ZoneRenderer` itself (`_note`/`placements_at`), not re-derived,
  so it cannot drift from what actually drew. It names its failure modes out loud:
  `skipped(no tile — not drawn by Qud)`, `skipped(under wall)`, `RENDERED (nothing — dropped)`.
- **An empty pick lists the nearest occupied tiles**, because bare ground is common and
  correct in Qud, so "EMPTY" alone cannot distinguish a mis-click from nothing-being-there.
- **Sprite preview** (upper right): the *real* billboard texture turning over a checkerboard.
  Transparency is invisible against dark ground — a filled gap and a see-through one look
  identical — so this is the only way to actually see the fill rules working.

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

- **Snapshot payload roughly doubled** — the painted ground layer adds ~1100 objects per
  frame. Cell-level diffing is now the obvious win, and becomes necessary before
  neighbour-zone streaming multiplies it again.
- **Ground drawn twice?** `DirtPath`/`DirtFloor` objects (the tan dots) sit on cells that now
  also carry a painted ground tile. Both are RenderLayer 0. Check for z-fighting or
  double-drawn floors, and whether the dots are redundant with the painted layer.
- **`RenderTile` fires for essentially nothing**, so `fgHex`/`detailHex` almost never arrive and
  the colour path is still the `ColorString` + palette route. If exact colours matter, the
  `RenderEvent` from `Cell.Render()` carries resolved values for the ground layer already.
- **Water depth tuning**: `SINK_WADE` / `SINK_SWIM` in `ZoneRenderer.gd` are eyeballed fractions.
  There's no swim animation or waterline ripple yet, and the cut edge is hard.
- **Tents** occlude, so they're currently prisms; probably want them as sprites (special-case).

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

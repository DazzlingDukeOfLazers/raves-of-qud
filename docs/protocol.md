# Raves of Qud — bridge protocol

localhost TCP, default port **48710** (`mod/Protocol.cs` `DefaultPort` ==
`godot/BridgeClient.gd` `PORT`).

> **Security:** the bridge binds to **localhost only** and has **no application-layer authentication** —
> any local process that connects is trusted. Do **not** expose port 48710 to a LAN or the internet. To
> reach it from another machine, tunnel over SSH (never bind it publicly).

Every message is a frame:

```
[ 4 bytes: payload length, big-endian ][ payload: UTF-8 JSON ]
```

## Version handshake

A mod `.cs` only compiles at Qud startup, so "deployed but not restarted" silently runs old behaviour.
Every snapshot carries `mod` (human string, `Protocol.Build`) **and** `protocol` (int, `Protocol.Version`,
monotonic). The client (`MainFrame.gd` `MIN_MOD_PROTOCOL` / `CLIENT_PROTOCOL`) compares and pins a
message-log line: green "up to date", red "restart Caves of Qud" (mod too old), or yellow "re-export
Raves" (client too old). **Bump `Protocol.Version` whenever the client comes to depend on a new field**,
and raise `MIN_MOD_PROTOCOL` to match. History: `1` baseline · `2` `liquid` flag · `3` `onFire` flag.

## Server → client: `snapshot` (per turn, throttled — see "publish cadence" below)

```json
{
  "type": "snapshot",
  "tilesDir": "/Users/you/Library/Application Support/RavesOfQud/tiles",
  "zone":   { "id": "JoppaWorld.53.3.1.0.10", "width": 80, "height": 25 },
  "player": { "x": 40, "y": 12 },
  "cells": [
    {
      "x": 41, "y": 12,
      "bridge": false, "wade": true, "swim": false,
      "nHeld": 2, "nRendered": 2, "nSent": 3,
      "objs": [
        { "name": "[painted ground]", "display": "ground", "ground": true,
          "tile": "Terrain/sw_grass1.bmp", "color": "&g", "detail": "G", "layer": 0 },
        { "name": "Pond", "display": "pond", "glyph": "~",
          "tile": "Liquids/Water/deep-11111111.png", "color": "&b^B", "layer": 2 },
        { "glyph": "@", "tile": "Creatures/sw_humanoid.png", "color": "&Y", "tilecolor": "&Y", "detail": "y", "layer": 8, "sinks": true }
      ]
    }
  ]
}
```

- `tilesDir` is where the mod writes exported tile PNGs (see below). The client
  loads `tilesDir/<tile-with-slashes-as-underscores>` — e.g. tile
  `Creatures/sw_bearman.png` → `tilesDir/Creatures_sw_bearman.png`. Missing files
  fall back to the glyph and are retried on later frames (export is on-demand).
  The dynamic (creature) layer rebuilds every turn, so it retries for free; the
  **frozen static layer** is built once per zone entry, so a tile that exports a
  beat *after* its cell was statically built would bake a permanent glyph. To close
  that race the live static build flags any missing tile and rebuilds itself on a
  later snapshot (bounded by `STATIC_RETRY_MAX`), so a first-sight fence/wall
  self-heals without a zone re-entry. See `ZoneRenderer._static_saw_missing`.
- A cell is sent if it has objects **or** a painted ground tile; only truly blank cells are
  omitted. Objects are ordered bottom→top, with the painted ground first.
- Fields come from `XRL.World.Parts.Render`, but via its **accessors**, not its fields:
  `glyph`=`getRenderString()`, `tile`=`getTile()` (the `Tile`/`RenderString` *fields* are
  static blueprint values, empty for runtime-chosen art). `color`=`ColorString`,
  `tilecolor`=`TileColor`, `detail`=`DetailColor`, `layer`=`RenderLayer`,
  `wall`=`GameObject.IsWall()`.
- Client render classification: `wall` → BoxMesh prism; else `layer` ≤ 2 → flat
  ground quad; else → upright billboard. (Calibrated: layer 0 = ground clutter,
  3 = trees, 7 = rock walls, 10 = creatures.)

### The painted ground layer  ← read this first

**A cell is not just its objects.** Qud composites a ground layer onto cells that hold **no `GameObject` at all** — in a Joppa zone, 1103 of 2000 cells. `Cell.Render()` returns a
`RenderEvent` with the tile, colours and flip flags; the mod emits it as a `RenderLayer 0`
floor, **first in `objs`**, tagged `"ground": true`.

Without it you get a world with no grass or dirt — and no amount of querying the objects will
reveal the problem, because the objects genuinely aren't there.

### Per-cell accounting

| field | source | why |
|---|---|---|
| `nHeld` | `Cell.GetObjectCount()` | what Qud says the cell contains |
| `nRendered` | `Cell.RenderedObjectsCount` | what Qud considers renderable |
| `nSent` | count actually emitted | what reached the wire (incl. the ground layer) |

`nHeld > nSent` means **we are dropping objects** and the number says where. These exist
because "the client shows nothing here" and "the mod sent nothing here" were previously
indistinguishable — which is exactly how the missing ground cover hid through six rounds of
debugging.

### Identity and build

| field | source | why |
|---|---|---|
| `mod` (top level) | `Protocol.Build` | **which mod build produced this frame.** Mod `.cs` only compiles at Qud startup, so a deploy is inert until a restart. Bump the constant when changing the mod. |
| `name` | `GameObject.Blueprint` | an object with no tile is otherwise unidentifiable |
| `display` | `GameObject.DisplayNameOnly` | read defensively — the getter runs Qud's markup pipeline |

### Server cost & publish cadence — read before touching `Bridge.Tick`

The mod runs inside Qud, so wasted work here slows **the game itself**, not just Raves. Hard-won
rules (the "overworld was unplayable" saga):

- **Do nothing without a client.** `Bridge.Tick` (EndTurnEvent) returns immediately when
  `server.ClientCount == 0`. It otherwise built a full snapshot + recomposited Qud's map on *every*
  turn even with Raves closed — so plain solo Qud lagged on every move.
- **Throttle publishing.** A single world-map step **auto-advances a burst of turns**, and building a
  2000-cell snapshot per intermediate turn published ~60–100/sec (each ~10ms) — pinning Qud's turn
  thread *and* flooding Godot so its frame loop starved (day/night lighting visibly crawled). `Tick`
  now marks state dirty and publishes at most once per `PublishThrottleMs` (~15/sec); `TickRender`
  flushes the last coalesced state right after the burst, so the final position is never stale. A
  *driven* command still publishes immediately. Normal play (turns seconds apart) is unchanged.
- **A zone change always publishes NOW, bypassing the throttle.** The throttle's trailing-edge flush
  lives in `TickRender` (`BeforeRenderEvent`), which does **not** fire while Qud is backgrounded — the
  normal "watching Raves" case — so a coalesced final frame could strand until the next input. That
  showed as *"Raves needs a couple of extra inputs to start"* and *"the world-map↔surface transition
  needs a few more inputs to load."* `Tick` compares the player's `Zone.ZoneID` to the last published
  one (`_lastPublishedZone`, set in `PublishNow`) and force-publishes on any change: startup (null →
  first zone) and every z-transition appear immediately. Same-zone bursts still throttle.
- **`RenderBase` is skipped on the world map** (`z < 0`) — recompositing Qud's own console every turn
  is wasted while you watch Raves, and the map barely changes step to step. Normal zones keep it.
- **`ResolveGround` (Qud's `Cell.Render()`) only on EMPTY cells.** On an occupied cell it returns the
  top object's tile, which is always deduped away — so it was pure waste (plus a per-cell `HashSet`).
  The world map is 2000 occupied cells, so that alone was most of the build time.

Two timing fields ride in every snapshot so this is measurable, not guessed: `serverUs`
(`ZoneSnapshot.BuildJson` time, previous turn) and `renderBaseUs` (this turn's `RenderBase`, 0 if
skipped). Watch the **publish rate** too — snapshots arriving 10ms apart mean a burst is flooding.

### Colours

`palette` (top level) maps each colour char to `#rrggbb`, read from
`ConsoleLib.Console.ColorUtility.colorFromChar`. **`Base/Colors.xml` names the colours but
contains no RGB** — the values live in code. Notably **`k` is `#0f3b3a`, a dark teal, and is
the colour of the Qud world**, not black.

When `RenderTile` paints an object, `fgHex`/`bgHex`/`detailHex` carry already-resolved RGB and
`hflip`/`vflip` carry Qud's sprite flipping; the client prefers those over the palette. In
practice `RenderTile` fires for almost nothing, so most objects use the `ColorString` path.

The colour chars → measured RGB (shipped live in `palette`, so the client never hardcodes them — this
table is reference; `WORLD_BG` derives from `k`):

| | | | |
|---|---|---|---|
| `k` **#0f3b3a** | `K` #155352 | `y` #b1c9c3 | `Y` #ffffff |
| `w` #98875f | `W` #cfc041 | `g` #009403 | `G` #00c420 |
| `b` #0048bd | `B` #0096ff | `c` #40a4b9 | `C` #77bfcf |

`ColorUtility.CAMERA_BACKGROUND` is **not** the field colour despite the name — it's `#40a4b9`, plain
cyan. Verify a value before believing a field name.

### RenderLayer values (the `layer` field → 3D treatment)

Calibrated from live capture; classification off `layer` + `wall`/`occluding` is in
[`rendering.md`](rendering.md) §1.

| layer | contents | 3D treatment |
|---|---|---|
| 0 | ground clutter (`sw_ground_dots`) | flat floor |
| 2 | liquids (`deep-*` water) | flat floor |
| 3 | trees, plants, watervines | upright billboard |
| 5 | small stones | upright billboard |
| 6 | furniture, torches | upright billboard |
| 7 | walls, fences, doors, tents | prism / oriented panel |
| 10 | creatures | upright billboard |
| 100 | special NPCs | upright billboard |

### Water & bridges

Per **cell** (all from first-class Qud predicates, no heuristics):

| field    | source                          | meaning                                    |
|----------|---------------------------------|--------------------------------------------|
| `bridge` | `Cell.HasBridge()`              | something decks over this cell              |
| `wade`   | `Cell.HasWadingDepthLiquid()`   | liquid deep enough to wade through          |
| `swim`   | `Cell.HasSwimmingDepthLiquid()` | liquid deep enough to swim in               |
| `light`  | `(int)Cell.GetLight()`          | Qud's `LightLevel` byte (Blackout=0, None=1 … Light=200 …); the client falls off to black away from sources **underground** |

Per **object**:

| field    | source                              | meaning                                       |
|----------|-------------------------------------|-----------------------------------------------|
| `bridge` | `GameObject.HasIntProperty("Bridge")` | this object *is* the deck surface           |
| `sinks`  | `IsCreature && !IsFlying`           | submerge this one; scenery/flyers keep height |
| `lightRadius` | `LightSource.Radius` (only when `Lit`) | client places an additive glow-pool + flame of this radius |
| `liquid` | `GameObject.LiquidVolume != null` (only when true) | a liquid pool — VOLATILE. Client **excludes it from the frozen-zone static signature**, else a wet player's wading sloshes water onto every cell and rebuilds the zone each step ("tiles vanish while walking") |
| `onFire` | `HasPart("AnimatedMaterialFire")` (only when true) | Qud draws the flame procedurally, so the tile is flameless (a campfire's `sw_campfire_noflame.png`). Client draws a daytime-visible flame + smoke for these (the additive torch flame fades out by day) |

The client's rule: **the water stays flat, the actor recesses.** `_cell_sink()`
turns `wade`/`swim` into a fraction of the sprite's art to hide, and `bridge`
cancels it — you cross at full height. A `bridge` object is drawn as a flat
opaque quad (`fill = true`, so the brick line-art's transparent field becomes
ground colour) lifted above the water it spans.
- Colors are **raw Qud strings** (e.g. `&Y`); the client resolves them. Godot's
  MVP renderer keys off the trailing letter — see `ZoneRenderer._qud_color`.
  Remember Qud's palette: `Y`=white, `y`=gray, `W`=gold, `w`=brown.

### Deferred (v2)
- FOV / fog-of-war flags (currently every object with a Render is sent;
  `Render.Visible` is available for this).
- HP / stats / message-log mirror (the "copy the rest of the window" chrome)
- neighbor-zone payloads for over-the-horizon streaming (the 3×3 parasang)

## Client → server: `command`

```json
{ "type": "command", "name": "move", "dir": "N" }
{ "type": "command", "name": "wait" }
{ "type": "command", "name": "shot" }
```

Implemented commands:

| `name` | effect | notes |
|---|---|---|
| `move` | one step in `dir` (`N S E W NE NW SE SW`) | injected on the socket thread via `Keyboard.PushCommand("CmdMove"+dir)`, so it wakes an unfocused game |
| `wait` | wait one turn (`CmdWait`) | **passes a turn.** Godot sends one on (re)connect to prime the first render, and Shift+Space is a manual passthrough. A no-turn "republish snapshot" command will replace the on-connect wait later. |
| `key` | inject a raw key press (`{"key":"s"}`) | Routed through Qud's **keymap** via `Keyboard.PushKey(new XRLKeyEvent(code), bAllowMap:true)`, so it fires whatever the player has that key **bound** to (e.g. soar/descend) rather than a fixed command id. Letters/digits only; the char casts straight to `UnityEngine.KeyCode` (`'a'`==`KeyCode.A`==97). Wakes an unfocused game like `move`. Raves forwards **S/D** this way (they no longer pan the camera). |
| `shot` | Qud screenshots itself → `qud_shot.png` | main-thread only (marshalled via `Bridge.Apply` → `uiQueue`) |

- `move`/`wait` are applied on the socket thread (they can drive an unfocused game); other
  commands route through `Bridge.Apply` on the main thread. The sim resolves the full turn
  (combat, doors, NPC actions) exactly as a keypress would; new state returns as the next
  `snapshot`.
- Extend `name` with `activate`, `getUp`, … the same way.

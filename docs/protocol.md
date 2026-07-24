# Raves of Qud — bridge protocol

localhost TCP, default port **48710** (`mod/Protocol.cs` `DefaultPort` ==
`godot/BridgeClient.gd` `PORT`).

Every message is a frame:

```
[ 4 bytes: payload length, big-endian ][ payload: UTF-8 JSON ]
```

## Server → client: `snapshot` (once per turn)

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
- Only **non-empty** cells are sent. Objects are ordered bottom→top of the cell stack.
- Fields map directly to `XRL.World.Parts.Render`: `glyph`=`RenderString`,
  `tile`=`Tile`, `color`=`ColorString`, `tilecolor`=`TileColor`,
  `detail`=`DetailColor`, `layer`=`RenderLayer`. Plus `wall`=`GameObject.IsWall()`.
- Client render classification: `wall` → BoxMesh prism; else `layer` ≤ 2 → flat
  ground quad; else → upright billboard. (Calibrated: layer 0 = ground clutter,
  3 = trees, 7 = rock walls, 10 = creatures.)

### The painted ground layer  ← read this first

**A cell is not just its objects.** Qud composites a ground layer onto cells that hold **no
`GameObject` at all` — in a Joppa zone, 1103 of 2000 cells. `Cell.Render()` returns a
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

### Colours

`palette` (top level) maps each colour char to `#rrggbb`, read from
`ConsoleLib.Console.ColorUtility.colorFromChar`. **`Base/Colors.xml` names the colours but
contains no RGB** — the values live in code. Notably **`k` is `#0f3b3a`, a dark teal, and is
the colour of the Qud world**, not black.

When `RenderTile` paints an object, `fgHex`/`bgHex`/`detailHex` carry already-resolved RGB and
`hflip`/`vflip` carry Qud's sprite flipping; the client prefers those over the palette. In
practice `RenderTile` fires for almost nothing, so most objects use the `ColorString` path.

### Water & bridges

Per **cell** (all from first-class Qud predicates, no heuristics):

| field    | source                          | meaning                                    |
|----------|---------------------------------|--------------------------------------------|
| `bridge` | `Cell.HasBridge()`              | something decks over this cell              |
| `wade`   | `Cell.HasWadingDepthLiquid()`   | liquid deep enough to wade through          |
| `swim`   | `Cell.HasSwimmingDepthLiquid()` | liquid deep enough to swim in               |

Per **object**:

| field    | source                              | meaning                                       |
|----------|-------------------------------------|-----------------------------------------------|
| `bridge` | `GameObject.HasIntProperty("Bridge")` | this object *is* the deck surface           |
| `sinks`  | `IsCreature && !IsFlying`           | submerge this one; scenery/flyers keep height |

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
```

- `dir` is one of the 8 Qud compass strings: `N S E W NE NW SE SW`.
- Applied on Qud's main thread; the sim resolves the full turn (combat, doors,
  NPC actions) exactly as a keypress would. New state comes back as the next
  `snapshot`.
- Extend `name` with `activate`, `wait`, `getUp`, … each routed through Qud in
  `Bridge.Apply`.

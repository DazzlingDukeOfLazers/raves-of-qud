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
      "objs": [
        { "glyph": "~", "tile": "Liquids/Water/deep-11111111.png", "color": "&b^B", "layer": 2 },
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

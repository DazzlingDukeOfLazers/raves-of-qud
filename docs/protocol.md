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
  "zone":   { "id": "JoppaWorld.53.3.1.0.10", "width": 80, "height": 25 },
  "player": { "x": 40, "y": 12 },
  "cells": [
    {
      "x": 41, "y": 12,
      "objs": [
        { "glyph": ".", "color": "&y", "detail": "k" },
        { "glyph": "@", "color": "&Y", "detail": "y" }
      ]
    }
  ]
}
```

- Only **non-empty** cells are sent. Objects are ordered bottom→top of the cell stack.
- `glyph` is the ASCII render char (Qud `Render.renderString`).
- Colors are **raw Qud strings** (e.g. `&Y`); the client resolves them. Godot's
  MVP renderer keys off the trailing letter — see `ZoneRenderer._qud_color`.
  Remember Qud's palette: `Y`=white, `y`=gray, `W`=gold, `w`=brown.

### Deferred (v2)
- `tile` / `tilecolor` / `layer` — the sprite-path fields on `Render` weren't
  resolvable from DLL string metadata; add them once confirmed in ILSpy. The MVP
  renders glyphs, so they aren't needed yet.
- FOV / fog-of-war flags (currently every object with a Render is sent)
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

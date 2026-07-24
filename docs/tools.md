# Tools & workflow

Two kinds of tooling: **Python** (inspection & verification, in `tools/capture/`) and the
**in-viewer** Godot tools (the human's feedback channel). GDScript is the product; Python exists
to check it.

---

## The Python-first rule (read this)

Claude cannot see the Godot viewport. Historically that meant render/geometry code was written
straight into GDScript and verified only by the human's screenshots — slow, and it hid bugs (an
off voxel depth order survived a full round-trip). So:

> **Prototype and verify any geometry or pixel algorithm in Python first, then port to GDScript.**

The Python mirrors the GDScript algorithm exactly and renders inspectable output (ASCII maps,
oblique PNGs, tables). What Python **can** verify: which pixel gets which height, which gaps fill,
colour rankings, tile geometry, wire contents. What it **cannot**: lighting, shadow, and final
appearance — those still need a screenshot (F12 in the viewer, read from disk). The rule is not
optional; it is how the depth-order bug was caught before it hit the renderer.

Everything Python here is pure-stdlib (a hand-rolled PNG decoder in `tile.py`, no Pillow).

---

## Python: wire inspection — `snap.py`

Reads one snapshot off the bridge (`127.0.0.1:48710`) and reports. **Blocks until the player
takes a turn** (a frame is only published on a turn) and reconnects on EOF (a Qud restart drops
the socket).

| command | shows |
|---|---|
| `snap.py summary` | object counts, layers, flags, cells with no tile |
| `snap.py cell X Y` | full object stack of one cell |
| `snap.py ident X Y` / `ident <name>` | blueprint + display + colours, by coord or name |
| `snap.py families` | tile family × layer × flags |
| `snap.py classify` | what the renderer will DO with each object (mirrors its rules) |
| `snap.py water` | depth flags vs water tile families; bridge stacks; submerged actors |
| `snap.py time` | the parsed day/night clock |
| `snap.py find <substr>` | locate objects by tile/glyph (matches the meaningful name tail) |
| `snap.py raw` | the whole snapshot as JSON |

Gotcha baked in: match the **meaningful name tail**, never the raw path — nearly every tile is
under `Assets_Content_Textures_`, so "tent" would hit "Content".

## Python: tile inspection — `tile.py`

Decodes an exported tile PNG (pure-stdlib) and prints its pixels, opaque-row band, and
transparency %.

```
python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp
python3 tools/capture/tile.py --list water
```

Legend: `#` opaque-dark → main · `o` opaque-light → detail · `.` transparent → bg. Flags line-art
(mostly transparent → needs fill) and the 16×24 wall/floor split.

## Python: algorithm prototyping — `fill.py`, `voxel.py`

These mirror GDScript algorithms so they can be verified without a screenshot.

### `fill.py`
A/B's the interior-fill rules (`column AND row`, `row only`, `AND + narrow slots`) side-by-side as
ASCII, with filled-pixel counts. This is how the chest/dromad/basket fill rule was chosen — and
how to check any change to `Fill.SPAN`/`INTERIOR` before touching `_interior`/`_fill_holes`.

### `voxel.py`
Mirrors `ZoneRenderer._rank_levels`. Recolours a tile and maps each pixel to a voxel height.
Two rules: `--rule luma` (**the shipping rule** — height ∝ Rec.601 luminance, bg pinned deepest,
`--gamma <1` spikes the bright detail) and `--rule count` (the retired frequency-rank, kept for
comparison). `--smooth N` box-blurs the height field. Prints:
- the **colour → luma/count → level** table (with `<- filled bg / main / detail` tags),
- an **ASCII height map** (0 = base/deepest),
- an **oblique preview PNG** (`/tmp/voxel_preview.png`) so the relief is visible.

```
python3 tools/capture/voxel.py wall_metal-00000000 --rule luma
python3 tools/capture/voxel.py wall_metal-00000000 --rule luma --gamma 0.45   # detail ridges
python3 tools/capture/voxel.py sw_chest --main '#98875f' --detail '#b1c9c3'
```

This tool **measured the fact that decides the whole subsystem**: every sampled tile is a 2-bit
mask (≤3 colours ⇒ ≤3 heights), so a smarter height *rule* can't add relief — see
[rendering.md §4](rendering.md#4-voxel-walls--the-active-area). **Any change to the height rule
goes here first**, then into `ZoneRenderer._rank_levels` — keep the two identical.

---

## In-viewer: the cell inspector

The human's primary feedback channel. **Ctrl/Cmd+click a tile, or hover + `I`.** Writes a report
to `~/Library/Application Support/RavesOfQud/selection.txt` (+ `selections.log` history), copies it
to the clipboard, and shows a panel. Claude reads the file — no transcription.

The report pairs **WIRE** (what Qud sent) with **RENDERED** (what `ZoneRenderer` actually did, and
at what Y — recorded by the renderer itself via `_note`/`placements_at`, so it can't drift). It
also shows the tile's exported PNG dimensions/opaque band, any active `OVERRIDE`, and the running
**mod build** (mod `.cs` only compiles at Qud startup — this line tells you whether your fix is
live). An empty pick lists the nearest occupied tiles. A sprite preview (upper right) shows the
real billboard texture turning over a checkerboard, since transparency is invisible against the
dark ground.

Keys: `I` inspect · `-`/`=` resize text · `Esc` dismiss.

## In-viewer: the report form

Lower-right panel, opens on inspect. For things **not derivable from Qud's data**. Pick a subject
(which object), a verdict, add notes, submit. Routes by verdict type into two lifecycles:

- **Standing rules** (shape / fill / position) → `overrides.json`, keyed by tile family. **Config
  — persists until changed.** The `☰` hamburger's *Clear rules* removes a tile's entry (the undo).
- **One-off notes** (colour / position / free text) → dated `.md` under `reports/`, with the full
  inspector capture attached. **Tickets — safe to delete.**

Splitting them fixed the trap where deleting a "resolved" ticket reverted the render, because the
ticket *was* the override. See [rendering.md §7](rendering.md#7-user-overrides).

## In-viewer: screenshots

`screencapture` is blocked (no Screen Recording permission), so both apps capture themselves:

- **F12** → `RavesOfQud/shot.png` (Godot viewport) + asks the mod for `qud_shot.png` (Qud's own
  window, via `UnityEngine.ScreenCapture` marshalled to the main thread).
- **Ctrl/Cmd+right-click** → inspect a tile **and** photograph both, with the report hidden and the
  3D marker kept. One gesture → coordinates + wire data + picture.

Claude reads both PNGs from disk. This replaces manual screenshot-and-paste.

---

## Diagnostic (not part of the loop)

`tools/tiletool/` — an AssetsTools.NET C# inspector used once to reverse how tiles are packed in
the Unity atlases. Kept for reference; not needed for normal work.

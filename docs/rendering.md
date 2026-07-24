# Rendering model

How `godot/ZoneRenderer.gd` (and `Main.gd`) turn a per-turn snapshot into the 3D scene.
Everything here is in **GDScript** — Python is only for *verifying* the algorithms
(see [tools.md](tools.md) and the Python-first note at the bottom).

---

## 1. Object classification

For each object in a cell, in this order (first match wins), from `_place_nonwall` /
`_is_prism`:

| result | test | notes |
|---|---|---|
| **user override** | `overrides.json` has a shape verdict for the tile family | wall / panel / billboard / flat / deck / not-drawn. See [overrides](#7-user-overrides). |
| **prism (wall)** | `wall && occluding` **and** the tile is *not* a `family_<dirs>` set | rock / metal / brinestalk. Rendered as **voxel** geometry (§4). |
| **deck** | object has the `Bridge` int-property | flat opaque surface; lifted over water, flat on ground. |
| **oriented panel** | tile matches `family_<dirs>` (`fence_ew`, `pipe_ne`, `tent_nw`, `sw_axle_2_ew`) | half-panels meeting at edges; `occluding` sets height (`WALL_H` tent vs `FENCE_H` fence). |
| **flat floor** | `layer <= FLOOR_LAYER_MAX (2)` | ground dots, water, cracks. Stacked by `RenderLayer`, not array order. |
| **billboard** | everything else | creatures, plants, furniture, items. Seated on the ground (`_seat`). |
| **glyph label** | tile not exported yet | transient; tiles export on sight. |

`family_<dirs>` = the suffix after the last `_` is ⊆ `{n,s,e,w}` (`_connector_dirs`).
The **`occluding` flag decides HEIGHT, not shape** — a tent wall is a fence at full height.

---

## 2. The painted ground layer

**A cell is not just its objects.** Qud composites dirt/grass onto cells that hold *no
GameObject* (1103 of 2000 in a Joppa zone). The mod sends it as a RenderLayer-0 floor first
in `objs`, tagged `ground:true`. See [protocol.md](protocol.md#the-painted-ground-layer--read-this-first).
Ground-layer **vegetation stands up** as a billboard (`UPRIGHT_GROUND` name list) rather than
lying flat.

---

## 3. Colour & tiles

- Tiles are **2-colour masks**: black → `TileColor` (main), white → `DetailColor` (detail),
  recoloured on the CPU (`_recolor_rgb`, lerp by luminance). Transparent → the cell background.
- `_qud_color` takes the **foreground** half of a `&FG^BG` code (the half *before* the `^`),
  and prefers the shipped `palette` (real RGB from the mod) over the fallback table.
- When Qud paints a tile via `RenderTile`, the object carries resolved `fgHex`/`detailHex` and
  `hflip`/`vflip` — the client uses those directly. In practice this fires for almost nothing.
- **Fill modes** (`enum Fill`) — how a tile's transparent pixels are treated:
  - `NONE` see-through · `ALL` filled rectangle · `INTERIOR` enclosed gaps only ·
    `SPAN` "fill the holes" = union of enclosed + row-span + column-span.
  - Which one is default depends on the path; a user FILL verdict overrides it (`_fill_for`).
  - Geometric rules can't tell a hub-gap-to-fill from a see-through basket; that's why FILL is
    a user verdict axis.

### Tile geometry (16×24)
Top-down **cap** above a south **front-face**. The split is NOT at row 16 and varies by family;
`_wall_split` finds it (a transparent separator row if present, else the last 10 rows). Measure
from the isolated **`-00000000`** variant — the `-11111111` interior tile has no borders.

---

## 4. Voxel walls  ← the active area

Walls are **voxel relief geometry**, not flat boxes. Each pixel of the wall art becomes a column
whose height is a colour rank, so the sun rakes across real relief and casts pixel-level shadows.

### The height algorithm — `_rank_levels(img)`
1. Count pixels per colour in the (recoloured) image.
2. **The transparent/background fill colour is forced to level 0 (deepest).** Background is
   scenery you look past — it recesses, it does not stand proud just because it is common.
3. The remaining colours rank **by count descending** above it: commonest → level 1, rarest →
   highest. So the thin border/detail stands proudest.
4. Each pixel's level × step = its height.

> **Verify this in Python before changing it:** `python3 tools/capture/voxel.py <tile>` prints the
> colour→count→level table, an ASCII height map, and an oblique preview PNG. The bg-deepest rule
> was found there: the cap uses the isolated tile, where `main` is more common than the bg, so
> pure count-ranking wrongly raised the background. See [tools.md](tools.md#voxelpy).

### The three pieces per wall cell
- **Cap** (`_voxel_cap_mesh`) — the top-down art, columns rising **up** from `WALL_H` by
  `level × VOXEL_STEP` (0.075). Cached per variant+colour, instanced per cell.
- **Sides** (`_side_voxel_mesh`) — the south front-face art, extruded **outward** from the cell
  edge by `level × SIDE_STEP` (0.06). Qud uses that one face on all four sides, so a single cached
  mesh (facing +Z) is instanced and **rotated** onto each exposed edge (S/E/N/W = 0/90/180/270°).
  "Exposed" = the orthogonal neighbour isn't this wall (`cells.has(...)`).
- **Solid core** (`_wall_core_material`) — a `BoxMesh` (0.96 × WALL_H × 0.96) filling the cell
  just inside the skin, coloured a *darker shade of the wall's darkest colour*. Without it you see
  straight through the gaps between columns into the empty cell; with it, recesses read as deep
  shadow.

Each column emits a top/front face plus **step faces** toward any *shallower* neighbour (or the
base at a grid edge), so protrusions show their sides. Normals are set explicitly (up for tops,
outward for steps); material is `CULL_DISABLED` so nothing depends on winding.

### Constants to tune
`VOXEL_STEP` (cap height/level) · `SIDE_STEP` (side protrusion/level) · the core inset (0.96) ·
`SHADED_WORLD` (flip to the flat unshaded look).

### Ideas / next steps for voxels
- Match cap and side height scales so the transition at the top edge is seamless.
- Cell-seam grooves: sides drop to base at every cell edge; could match the neighbour instead.
- `MultiMesh` per (variant, mesh, rotation) if draw calls (≈5/cell) ever hitch.
- A height rule other than colour-rank (luminance; or force detail highest) — prototype in
  `voxel.py` first.

---

## 5. Lighting — everything is FAKED because the world is UNSHADED

Materials are `SHADING_MODE_UNSHADED` by default so tiles show exact colours; a real light does
nothing to them. `SHADED_WORLD = true` switches **walls and the ground** to `PER_PIXEL` so they
receive the sun and cast shadows (ambient raised ~0.72 so tiles keep colour in shadow; baked
vertex shade dropped so it doesn't double). Billboards/floors stay unshaded.

- **Torch/fire light** (`_place_light`): the mod sends `lightRadius` (from `LightSource`); the
  client draws an additive warm **ground-glow** + a flickering **flame** billboard (both
  `BLEND_MODE_ADD`), flickered in `_process`. Qud's flame is procedural — there is no tile.
- **Day/night** (`Main._grade`): a full-screen **MULTIPLY** ColorRect on CanvasLayer 0 (below the
  UI) tints the whole viewport by the hour. Night cool blue, dawn/dusk warm, midday neutral.
- **Sky** (`Main._env.background_color`): follows the hour too — the void behind the world.
- **Sun & moon** (`Main._sun/_moon`): disc billboards on a tilted arc set by the hour; sun tracks
  day, moon the night span, cross-fading at the boundaries.
- **Sun light** (`Main._sun_light`): a `DirectionalLight3D` aimed down the sun's arc, energy fading
  with daylight — this is what casts the wall shadows when `SHADED_WORLD`.

Time comes from `The.Game.Turns`/`Calendar` as **day-segments** (a day = `TurnsPerDay×10` = 12000;
`StartOfDay`=3250=6:30, `StartOfNight`=10000=20:00). **Qud has no moon phase** (the only "moon" is
the Moonstair location), so none is sent or invented.

---

## 6. Billboards, water, bridges

- `_seat` seats a sprite on the ground by its **opaque band** (art is padded inside the 24-row
  frame), or floats it at cell mid-height under a `POS: float` override.
- **Deep water stays flat; the actor recesses.** A creature in wading/swimming depth (`sinks`
  and the cell's `wade`/`swim`) is drawn **cropped at the waterline** (`_seat` with `sink`),
  never lowered — the water is a flat quad, so a sunk sprite would poke out under it.
- A **bridge** decks over the water (opaque, lifted); anything on it is at full height.

---

## 7. User overrides

Things not derivable from Qud's data (a water wheel runs E–W, an axle floats) live in
`~/Library/Application Support/RavesOfQud/overrides.json`, keyed by **tile family**
(`ZoneRenderer.tile_family` — strips variant numbers, autotile bitmasks, and direction suffixes,
so `sw_axle_2_ew` and `sw_axle_3_ew` share `sw_axle`). Three independent axes:

| axis | verdicts | applied in |
|---|---|---|
| **shape** | wall / panel N–S / panel E–W / billboard / flat / not-drawn | `_is_prism`, `_place_nonwall` |
| **fill** | fill-holes / enclosed / transparent / opaque | `_fill_for` |
| **position** | float / ground | `_seat`, panel y-centre |

`_load_overrides` re-reads the file every frame (diffed to skip re-parse). The **cell inspector**
prints `OVERRIDE shape=… fill=… pos=…` for any tile with an entry, so a rule that didn't take is
visible, not silent. The report form writes these — see [tools.md](tools.md#in-viewer-the-report-form).

---

## Python-first for geometry

Claude can't see the viewport, so geometry algorithms (voxel heights, fill rules) are **prototyped
and verified in Python first**, then ported to GDScript. `tools/capture/voxel.py` and `fill.py`
mirror the GDScript algorithms exactly and render inspectable output. Lighting/shadow *appearance*
still needs a screenshot (F12 in the viewer); the *algorithm* does not. This is not optional — it
is how the depth-order bug was caught without a round-trip.

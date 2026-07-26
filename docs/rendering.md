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

## 4. Voxel walls — flush surface + carved gaps

Walls are **relief geometry** built per-pixel from the wall art, so the sun rakes across real depth
and casts pixel-level shadows. The model is **flush-and-carve**: the solid material sits flush at
the cell boundary and only the background gaps recess.

### The 2-bit constraint that decided the model
Qud wall tiles are **2-bit masks** (measured — 60/60 sampled tiles are black + white + transparent,
*no* anti-aliasing). After recolour a cell holds **at most 3 colours** (bg, main, detail), so a
colour→height *ranking* could only ever make ≤3 heights, and the interior "egg-crate" is the
**grating the art literally draws**, not noise to smooth. That measurement — made in
`tools/capture/voxel.py`, which prototyped an abandoned luminance-ranking rule — is *why* height
isn't ranked at all now: with so little to rank, a **binary** surface-vs-gap carve reads better and
is what shipped.

### The rule: flush non-bg, carve the bg
Every **non-background** pixel — red `main` AND bright `detail` — sits at ONE flush depth; they are
coplanar, no colour stands proud of another. Only **background** pixels (the gaps / rivet holes)
recess. Consequences: the highlight sits at the same depth as the body, and **corners meet** — the
flush skin lands exactly on the cell boundary, so a face's edge column and the perpendicular face's
edge column share the corner line.

### The pieces per wall cell
| piece | fn | geometry |
|---|---|---|
| **Cap** | `_voxel_cap_mesh` | top-down art. Non-bg flush at `WALL_H`; bg carves DOWN by `CAP_CARVE`, its floor drawn in the recess colour. |
| **Sides** | `_side_voxel_mesh` | south front-face art, flush at the cell edge (`z=0.5`); bg carves INWARD by `SIDE_CARVE`, bottoming on the core. One cached mesh (facing +Z), instanced and **rotated** onto each exposed edge (S/E/N/W). "Exposed" = the orthogonal neighbour isn't wall. |
| **Core** | `_wall_core_material` | a `BoxMesh` (`(0.5−SIDE_CARVE)·2` wide) filling the cell just behind the skins, so side gaps bottom out on it. Its top sits just below the cap's gap floor (`WALL_H−CAP_CARVE`) so it can't poke up through a roof gap. |

`_wall_recess_color()` is shared by the cap gap floors and the core: the wall's own `main`, darkened
and nudged ~12% toward the scene ambient — a recess *in the material*, not a foreign hole.

### Carve walls & the cell-seam fix (`_vc_step` / `_side_step`)
A carved gap draws its trench walls toward any lower/deeper neighbour — the higher (flush) pixel
owns the wall, so it's drawn once. At a **cell boundary** the art's checker runs to the edge, so an
edge pixel can be a gap whose flush neighbour lives in the *next cell's mesh*, which can't see it and
won't close it. Left unhandled that opened the pit sideways onto the dark background — the dark
grooves that showed along roof seams. **Fix:** when a pixel IS the gap at a boundary, it closes its
own wall up to the neighbour's (assumed flush) surface, in the material colour so it matches the
in-cell walls. Applied to both cap and sides. Normals are explicit; material is `CULL_DISABLED`.

### Colour is sRGB (a gotcha)
The wall meshes bake colour into **vertices**, so `_voxel_material` sets `vertex_color_is_srgb =
true`. Godot defaults that to `false` and treats vertex colours as linear, which desaturated the
palette reds into a pale tan (measured #805840 sat 0.50 vs palette #993326 sat 0.75). Tiles that use
an albedo *texture* are unaffected. See CLAUDE.md's debugging rules.

### Constants to tune
`CAP_CARVE` (roof gap depth) · `SIDE_CARVE` (face gap depth) · the core sizing (half-width
`0.5−SIDE_CARVE`, top at `WALL_H−CAP_CARVE`) · the recess mix in `_wall_recess_color` ·
`SHADED_WORLD` (flip to the flat unshaded look).

### Ideas / next steps
- Cell-seam phase: if a faint seam still shows, adjacent autotile variants' checker phase may differ
  across the boundary; chase it with the neighbour data from `snap.py`.
- `MultiMesh` per (variant, mesh, rotation) if per-cell instance counts ever hitch at render radius.
- The abandoned luminance rule still lives in `voxel.py` (`--rule luma`) as the tool that *measured*
  the 2-bit fact — it is **not** what the renderer uses; the renderer is binary flush-and-carve.

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

**Underground has no sky.** The day/night grade is a *surface* phenomenon — a cave at noon must
not be lit like the surface. The mod sends `zone.z` (Qud's stratum; surface is `Z==10`, deeper is
higher). When `_depth > SURFACE_Z`, `_update_time` skips the clock, calls `_apply_cave_lighting`
(sky/fog → near-black `CAVE_SKY`, sun/moon/sun-light off, label `Cavern -N`), and holds the global
grade at a **near-neutral** `CAVE_TINT` — deliberately NOT dark, because the darkness is done
per-cell instead (see below). Coming back up restores the clock.

**Per-cell light — caverns AND the surface at night.** A single global multiply can't do "black +
bright light pools" (in LDR it dims the additive torch-glows too). So the mod sends each cell's
`light` (`(int)Cell.GetLight()`, a `LightLevel` byte) for *every* zone, and `_build_darkness` runs
everywhere, self-gating on the data: fully-lit cells emit nothing, so **midday and lit caves pay
zero**, while **caverns and the night surface fall off to black** around light sources. It works on
the surface at night because Qud's `Daylight` part adds a daylight radius of **0** after dusk (and
floods the whole zone at noon), so `GetLight` genuinely goes dark at night. The one coupling: the
day/night grade must **not** also darken at night (`NIGHT_TINT` is a bright moonlit cast, not a dim)
or it would double-dark and kill the pools — same reason `CAVE_TINT` is near-neutral.

Mechanically, the mod sends each cell's `light` and `ZoneRenderer._build_darkness`
lays a **per-cell darkness overlay** — one vertex-coloured MIX-black mesh, a quad over each cell's
floor (and roof, for wall cells) whose alpha is `(1 - lightFrac) * DARK_MAX`. Built into
`_dynamic_root` every turn, so it tracks Qud's live light as sources/the player move. `_light_frac`
maps the byte (None=1 → 0 dark, Light=200 → 1 full). Creatures dim via `Sprite3D.modulate` by their
cell's light (the flat overlay can't cover a standing sprite); the additive torch/glow geometry
draws bright on top, so lit pools read against the black. Fully-lit cells add nothing to the mesh,
so on the surface it's free.

Coverage: an **open** cell darkens its floor by its own light; a **wall** cell darkens its roof
(own light) and each **exposed vertical face** — a face by the light of the *open* cell it faces
(what would light it), so rock beside a torch stays lit while rock in the dark goes black. Interior
(wall-to-wall) faces are skipped, like `_place_side`. Standing sprites use `modulate`.

`_build_darkness(cells, parent)` serves both passes: the live zone bakes into `_dynamic_root`
(rebuilt each turn, tracks moving light); each **remembered neighbour** (and stacked deeper level)
bakes one into its own frozen subtree in `_sync_neighbors`, from that zone's *stored* light — so a
dark cavern or night surface stays dark in memory instead of rendering fully lit. Frozen is fine:
remembered light is stale by design.

---

## 6. Billboards, water, bridges

- `_seat` seats a sprite on the ground by its **opaque band** (art is padded inside the 24-row
  frame), or floats it at cell mid-height under a `POS: float` override.
- **Deep water stays flat; the actor recesses.** A creature in wading/swimming depth (`sinks`
  and the cell's `wade`/`swim`) is drawn **cropped at the waterline** (`_seat` with `sink`),
  never lowered — the water is a flat quad, so a sunk sprite would poke out under it.
- A **bridge** decks over the water (opaque, lifted); anything on it is at full height.

### 6a. Why "just make the water tile transparent" doesn't reveal a submerged actor

This has bitten us, so it's written down. In **Qud (2D)** a cell is a paint stack: the water
tile is composited *on top of* the creature, so making the water tile semi-transparent would
let the creature show through. That mental model is correct **for Qud**.

In **Raves (3D) it does not map**, for two coupled reasons:

1. **The water is a flat floor quad near the ground, not an overlay.** It lies roughly in the
   ground plane (`FLOOR_Y + layer*LAYER_LIFT`), a near-horizontal sheet. It never sits *in front
   of* the vertical creature billboard the way a 2D tile does, so its opacity has almost nothing
   to do with whether you can see the actor.
2. **The submerged part of the actor is never drawn.** "Submerged" is faked by **cropping** the
   billboard at the waterline (`_seat` with `sink` — see above), not by lowering it. The pixels
   below the waterline don't exist in the scene. So even a fully transparent water tile reveals
   *nothing*: there is no geometry behind it to show.

Corollary: **transparency belongs to the water, submersion belongs to the crop, and neither one
alone gets you "see the fish under the water."** An earlier attempt layered transparency onto the
*creature* (a veil) and drew it uncropped; that both put the effect on the wrong object and
destroyed the half-submerged read. Reverted.

### 6b. If we do want "see the submerged part through the water" (future)

It's a real rendering change, not a tile tweak. The honest version:

- **Give deep water genuine vertical depth.** Model a deep-water cell as a *basin*: the floor sits
  below the surface, and the **surface** is a translucent quad raised to a consistent water height
  (shared across the pool, or it reads as a floating pane over one cell).
- **Draw the actor uncropped, standing on the basin floor**, so its lower part is genuinely *below*
  the raised translucent surface and shows through it; its top stays above, clear.
- Watch the **occluders**: the world's big opaque ground plane (`y ≈ -0.02`) will hide anything
  drawn below it, so the basin floor and actor feet have to stay above it (or the ground plane must
  be cut out under deep water).
- This touches shorelines (deep water meeting land/bridges/wading), so design it deliberately with
  screenshots at each step — don't hack it live per-cell.

Until then, deep water stays **opaque flat quad + cropped actor** (§6), which reads correctly as
"mostly submerged, top poking out."

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
| **stairDir** | north / south / east / west | `_stair_dir_deg` (see §8) |

`_load_overrides` re-reads the file every frame (diffed to skip re-parse). The **cell inspector**
prints `OVERRIDE shape=… fill=… pos=…` for any tile with an entry, so a rule that didn't take is
visible, not silent. The report form writes these — see [tools.md](tools.md#in-viewer-the-report-form).

---

## 8. Stairs down — framed floor tile

A `StairsDown` (tile `Tiles2/sw_stairsdown`, layer 7) would otherwise render as an upright
billboard glyph — a "0"-looking mark floating on the floor. `_place_nonwall` intercepts it
(`_is_stairs_down`, matched on the blueprint name *or* the tile, so a not-yet-exported tile
still gets the marker) and builds:

- **The stair art laid FLAT** inside the frame, filled (`Fill.ALL`) so the transparent field
  becomes an opaque base the light `>` staircase sits on — exactly as Qud shows it, and readable
  from any camera angle or time of day.
- **A raised rectangular lip** (`STAIR_FRAME_*`) around the cell perimeter — "the top of the
  stair" — four bars, inner edge flush with the tile.
- The cell's own floor quad is suppressed (`stair_cell` flag through `_place_nonwall`) so it can't
  z-fight the stair tile.

**A descending voxel shaft was tried first** (prototyped in `tools/capture/stairs.py`: a flight of
solid columns stepping one cell deep, framed by the lip) and **rejected after measuring it**: a
one-cell pit is too small and dark to read from the low game camera, and it vanished completely in
dim light (the near-black shaft blended into Qud's dark-teal `k` background). The measure-don't-guess
rule applied to a whole feature — the screenshot killed the fancy version. The Python prototype is
kept as the record.

**Direction.** Qud's `StairsDown` is a vertical connector with **no lateral facing** (down-stairs
meet up-stairs at the same x,y one level below), so there is usually nothing to rotate to.
`_stair_dir_deg` resolves, in order: an explicit `stairDir` data field (if the mod ever sends one)
→ a user **override** (`stairDir: north|south|east|west`, §7) → the **guess** (`STAIR_GUESS_DEG`,
face +Z/south). `deg` rotates the whole group (glyph + frame) by yaw like `_place_side`
(S→E→N→W clockwise from above), so a facing is one edit or override away.

---

## 9. Vertical level stacking

The `WorldStore` remembers every visited zone with its `stratum` (Qud's `Z`). `_neighbor_zones`
(Main.gd) feeds the renderer the live zone's **same-stratum** neighbours (`dz==0`, the horizontal
remembered zones) **plus deeper levels** (`dz>0`) up to `LEVEL_KEEP_DOWN` strata. `_sync_neighbors`
drops each by `dz * renderer.level_height`, so deeper levels stack **below** the current one with a
user-set gap (the "level height (Z gap)" slider, 0 = coplanar; persisted).

- **Shallower levels (`dz<0`) are never rendered** — hung above, a level's solid terrain would form
  a ceiling that occludes the current level from top-down and high cameras. So as you descend, the
  levels you leave turn off.
- **Deeper levels beyond `LEVEL_KEEP_DOWN` cull off** — a bound on cost and clutter.
- Only *visited* levels exist in the store, so a stack appears as you actually explore down; it is
  not an x-ray of unseen strata.

---

## Python-first for geometry

Claude can't see the viewport, so geometry algorithms (voxel heights, fill rules) are **prototyped
and verified in Python first**, then ported to GDScript. `tools/capture/voxel.py` and `fill.py`
mirror the GDScript algorithms exactly and render inspectable output. Lighting/shadow *appearance*
still needs a screenshot (F12 in the viewer); the *algorithm* does not. This is not optional — it
is how the depth-order bug was caught without a round-trip.

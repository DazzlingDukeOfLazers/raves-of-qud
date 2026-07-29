# Rendering model

How `godot/ZoneRenderer.gd` (and `Main.gd`) turn a per-turn snapshot into the 3D scene.
Everything here is in **GDScript** — Python is only for *verifying* the algorithms
(see [tools.md](tools.md) and the Python-first note at the bottom).

## The mental model (read first)

A snapshot becomes the scene through a fixed pipeline, and each section below is one stage of it:

```
snapshot → classify each object → build geometry → colour + fill → lighting/darkness → freeze (static) / rebuild (dynamic)
```

Every object lands in one of **five visual layers**: (1) **painted ground** (dirt/grass, drawn even where
no GameObject exists), (2) **flat/deck surfaces** (floors, bridges), (3) **wall geometry** (the voxel
walls), (4) **upright sprites/panels** (creatures, items, fences), (5) **lighting/darkness overlays**.
Classification (§1) picks the layer; the later sections explain each layer's geometry, colour, and
lifecycle. A quick glossary of the terms used throughout is at the [bottom](#glossary).

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

## 5. Lighting — exact-colour art, optional shaded geometry, simulated light effects

World geometry follows the `SHADED_WORLD` constant (**currently `true`** → per-pixel shaded; flip it
`false` for the flat, fully-unshaded look). Under the unshaded path, tiles show exact colours and a real light does
nothing to them. `SHADED_WORLD = true` switches **walls and the ground** to `PER_PIXEL` so they
receive the sun and cast shadows (ambient raised ~0.72 so tiles keep colour in shadow; baked
vertex shade dropped so it doesn't double). Billboards/floors stay unshaded.

- **Torch/fire light** (`_place_light`): the mod sends `lightRadius` (from `LightSource`); the
  client draws an additive warm **ground-glow** + a flickering **flame** billboard (both
  `BLEND_MODE_ADD`), flickered in `_process`. Qud's flame is procedural — there is no tile.
- **Fire vs torch by day** (`onFire`): a torch's tile shows its own flame, so the additive flame is
  faded to zero at midday (`_flame_mul`). But a CAMPFIRE's tile is flameless (`sw_campfire_noflame.png`
  — the flame is procedural), so for `onFire` objects the client draws an **alpha-blended flame SHAPE**
  (`_fire_tex`, kept visible day + night — additive washes out on a bright background) and emits
  **smoke day + night**; the ground light-pool is gated to real darkness (`_fire_glow_mul`, off by day —
  you can't see fire-light in daylight, and that blown-out pool read as a "second light"). The flame
  texture was prototyped as a PNG in Python (temperature gradient, convex silhouette) before porting.
- **Day/night** (`SkyGrade.gd`): a full-screen **MULTIPLY** ColorRect on a CanvasLayer tints the whole
  viewport by the hour. Night cool blue, dawn/dusk warm, midday neutral. Sky colour, sun/moon disc
  billboards on a tilted arc, and a sun `DirectionalLight3D` (energy fading with daylight, casts the wall
  shadows under `SHADED_WORLD`) all live in SkyGrade too, fed each snapshot from `time` + the stratum.

Time comes from `The.Game.Turns`/`Calendar` as **day-segments** (a day = `TurnsPerDay×10` = 12000;
`StartOfDay`=3250=6:30, `StartOfNight`=10000=20:00). **Qud has no moon phase** (the only "moon" is
the Moonstair location), so none is sent or invented.

---

## 5a. Dark zones — per-cell light from Qud's own map

Caverns and the night surface should be black except around light sources, falling off to nothing —
the way Qud shows them. This is a separate system from the day/night grade above, and the two must
not fight.

**Why not just dim the grade.** The grade is a single full-screen MULTIPLY. In the LDR pipeline it
darkens the *whole* composite — including the additive torch-glows — and LDR clamps those glows to
1.0 *before* the multiply, so "black cave + bright pools" is impossible that way: crank the grade
dark and the pools die with everything else. Darkness has to be applied **per cell, before** the
additive lights, not as a global post-multiply.

**The data.** The mod sends each cell's `light` = `(int)Cell.GetLight()` (a `LightLevel` byte:
`Blackout`=0, `None`=1 … `Light`=200 …) for *every* zone. `_light_frac` maps it to 0..1 (None → 0
dark, Light → 1 full). This is Qud's real, occlusion-aware light map, so we render exactly what the
game computes — no re-simulating light client-side.

**When it's dark.** Driven purely by the data, so it needs no mode flag:
- **Underground** (`zone.z > SURFACE_Z`, surface is `Z==10`): `Main._apply_cave_lighting` drops the
  clock — near-black `CAVE_SKY` void, sun/moon/sun-light off, label `Cavern -N`.
- **Surface at night**: Qud's `Daylight` part (confirmed by decompile) adds a daylight radius from
  `Calendar.CurrentDaySegment` that is **0 after dusk** and floods the whole zone at noon, so
  `GetLight` genuinely goes dark at night — the same overlay just works.
- **Daytime / lit cells** emit nothing (frac ≈ 1), so midday and lit caves cost zero.

**The overlay** (`ZoneRenderer._build_darkness`). One vertex-coloured **MIX-black** mesh; each cell
contributes quads with alpha `(1 - lightFrac) * DARK_MAX`:
- **open cell** → a floor quad (its own light);
- **wall cell** → a roof quad (own light) + a dark quad on each **exposed vertical face**, that face
  dimmed by the light of the *open* cell it faces (what would light it) — so rock beside a torch
  keeps a lit face while rock in the dark goes black. Interior (wall-to-wall) faces are skipped, the
  same edge test as `_place_side`.
- **standing sprites** — creatures **and** static plants/scenery (trees, brinestalks) — can't be
  covered by a flat overlay, so they dim via `Sprite3D.modulate` by their cell's light. Creatures
  get it in the dynamic pass; static billboards are tracked (`_lit_sprites`) and re-lit every turn
  by `_relight_static_sprites` (a modulate write, no rebuild), so a forest goes dark at night with
  the ground under it. Frozen neighbours bake it once from stored light. Glowing sprites (glowpad,
  bioluminescence) are left bright — they emit light.
- **connector panels** (fences, pipes, axles) are `MeshInstance3D`, which has no `modulate`, so each
  gets a per-instance material (a shallow dup of the cached one — texture shared) and dims via
  `albedo_color`. Tracked in `_lit_meshes` and re-lit by the same `_relight_static_sprites`; frozen
  neighbours bake it in. Without this a fence stays "globally illuminated" while the scene darkens.

The additive torch/glow geometry draws bright *on top* of the darkened tiles, so lit pools read
against the black.

**Two passes, one function.** `_build_darkness(cells, parent, clear_player)`:
- the **live** zone bakes into `_dynamic_root`, rebuilt every turn, so it tracks Qud's light as
  sources and the player move;
- each **remembered neighbour** (and stacked deeper level) bakes one into its own frozen subtree in
  `_sync_neighbors`, from that zone's *stored* light — so a zone you've left stays dark in memory
  instead of snapping back to full brightness. Meta-guarded (`dark_baked`) to bake exactly once,
  including the zone you *just* left (already in `_static_zones` from being live, its per-turn
  darkness gone with `_dynamic_root`). Frozen is fine — remembered light is stale by design.

**The departed player's sight-disc.** Qud lights a ~5-tile disc of `Light` around the player so they
can see, even with no carried light source, and it *follows* them — so a zone they've left keeps a
cropped lit disc where they crossed out. When baking a frozen zone, `_sync_neighbors` passes the
zone's stored player cell (`clear_player`, carried through `_neighbor_zones` as `px`/`py`, and kept
in the `WorldStore` record — which otherwise trims `player` away) and `_build_darkness` blanks the
light in a `FROZEN_LIGHT_CLEAR_R` disc around it. It sits at the zone edge (a crossing), so it
essentially never overlaps a real fixed light. The live zone passes no `clear_player` — its disc is
you, and real.

**The grade coupling.** Because darkness is per-cell now, the global grade must stay **bright** where
the overlay is active or it double-darkens and kills the pools: `CAVE_TINT` is near-neutral (a faint
cool cast) and `NIGHT_TINT` is a bright moonlit cast, *not* a dim. The overlay does the dimming; the
grade only sets mood.

**Tuning knobs:** `DARK_MAX` (deepest darkening, <1 so unlit keeps a faint memory), `CAVE_TINT` /
`NIGHT_TINT` (mood, must stay bright), `FROZEN_LIGHT_CLEAR_R` (sight-disc erase radius). Not yet
dimmed: **wall side faces of the live player's own cell region** are fine, but a character with a
sight radius > `FROZEN_LIGHT_CLEAR_R` could leave a faint ring in a frozen zone (raise the constant,
or have the mod send the real sight radius).

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

## 10. Performance — the world map, and keeping per-turn cheap

The **world map** (the parasang overview, `zone.z < 0`) is the stress case: ~2000 cells, every one
an occupied terrain tile, fully lit, no walls. It exposed costs that also bite big lit zones:

- **Big zones build INCREMENTALLY — read this before touching `_build_static`.** Building a whole
  ~2000-cell zone in one frame creates a large batch of *distinct* GPU resources at once (recoloured
  terrain textures, materials, floor batches — the world map has a different terrain type per cell),
  and that single-frame spike **overran the Metal buffer allocator and hard-crashed** (`SIGBUS` in
  `memmove`). Note the surface is the same *cell* count but has few distinct floor types, so it never
  crashed — the trigger is distinct-resources-per-frame, not raw volume. So any zone over
  `IB_THRESHOLD` cells builds across frames: `_group_wall_cells` (cheap, no GPU) up front, then
  `IB_CHUNK` cells per frame in `_ib_step` (driven from `_process`), flushing each chunk's floors as
  it goes. `_build_zone` is split into `_group_wall_cells` + `_place_cell` so the sync (neighbour) and
  chunked (live) paths share the per-cell logic. Lifecycle: `_ib_finish()` completes the departing
  zone before a transition rebuild (so it's a valid remembered neighbour); `_ib_abort()` bails if the
  subtree is being freed; the export-race retry is suppressed mid-build. This also removed the 1–3s
  transition freeze — the zone now fills in progressively. Diagnosed from the user's own bisection
  (surface-start fine, world-map-start crashes), after two wrong guesses (MultiMesh billboards, then
  the card feature) that a real windowed run disproved and `--headless` could not (dummy renderer).
- **Floors are batched.** Each floor was one `MeshInstance3D` → ~2000 draw calls a frame, a
  continuously low framerate. `_place_nonwall` now queues floor quads by material and
  `_flush_floor_batch` emits **one `MultiMesh` per tile type** at the end of each static/neighbour
  build — a handful of draw calls instead of thousands. Floors are static, so it's free per frame.
- **Fully-lit zones skip the lighting loops.** A cheap `any_dark` scan (early-breaks on the first
  dim cell) gates `_build_darkness` + `_relight_static_sprites`; a fully-lit zone (world map, daytime
  surface) does none of it. A dark→lit transition un-dims tracked sprites once (`_reset_static_light`).
- **The cutaway is bounded** to `CUTAWAY_RADIUS` tiles of the player and only the LIVE zone's walls
  carry the fade-capable (`ALPHA_DEPTH_PRE_PASS`) material — neighbours (many, on a far surface view)
  are plain opaque. See [cameras.md](cameras.md).
- **No torch glows on the world map** (`_world_map`, `_place_light` early-returns). A world tile that
  emits light (a glowfish parasang) otherwise got a flame that `_process` re-randomizes every frame —
  a light **oscillating** on an idle overview. Flicker is per-frame and client-side, so it shows even
  with no snapshots arriving.
- **World-map tiles stand UP as cards.** Laid flat they read edge-on under the tilted compass camera.
  `_place_nonwall` intercepts every static world-map tile (`_world_map`, has a texture, not a creature)
  and stands it up as a **plain `Sprite3D`** — the same proven billboard path as every creature/plant,
  seated by `_seat`, tagged `wm_tile`. `_wm_sprite_billboard` is the orientation: `BILLBOARD_FIXED_Y`
  (follow the camera, default), `BILLBOARD_DISABLED` (fixed EW panel facing N/S, key `B`), or
  `BILLBOARD_ENABLED` (flat — top-down wins, since an upright card is edge-on/invisible from straight
  overhead). `set_wm_face_ns` / `set_top_down` re-orient the `wm_tile` group in place — instant, no
  rebuild. Missing tiles self-heal via the same `_static_saw_missing` retry as floors.
  - **Why plain sprites, not a batched `MultiMesh`** (2000 tiles → 2000 draw calls, so batching is
    tempting): a `MultiMesh` whose material set `billboard_mode` **hard-crashed the Metal driver**
    (`SIGBUS` in `memmove` on the instance-buffer upload — per-instance billboard in a `MultiMesh` is
    a fragile GPU path). `--headless` renders with a dummy driver and never touches Metal, so it
    can't catch this class of bug — only a real windowed run does. The sprites are alpha-scissored
    (opaque pass, no transparency sort), so the draw-call cost is tolerable; batch later only via a
    path verified on-GPU.
- **The world-map player draws on top.** The `@` keeps its normal dynamic-pass sprite, but on the map
  (`_placing_player`, its cell = `_player_cell`) it gets `no_depth_test` + a high `render_priority`, so
  it's always the topmost "you are here" — closest to the overhead camera in top-down, never buried
  behind a taller terrain card in the angled views. Reset for every other sprite in `_take_sprite`.

The mod side of the same saga (idle-gate, publish throttle, `RenderBase`/`Cell.Render()` skips, the
`serverUs`/`renderBaseUs` timers) is in [protocol.md](protocol.md#server-cost--publish-cadence).

---

## Python-first for geometry

Claude can't see the viewport, so geometry algorithms (voxel heights, fill rules) are **prototyped
and verified in Python first**, then ported to GDScript. `tools/capture/voxel.py` and `fill.py`
mirror the GDScript algorithms exactly and render inspectable output. Lighting/shadow *appearance*
still needs a screenshot (F12 in the Holodeck); the *algorithm* does not. This is not optional — it
is how the depth-order bug was caught without a round-trip.

---

## Glossary

Terms used throughout this page:

- **cap / face / core** — parts of a voxel **wall**: the top **cap** (drawn from the tile's top edge), the
  vertical **face(s)** the camera sees, and the solid **core** between them.
- **live zone** — the zone the player is currently in, rebuilt from the snapshot each turn.
- **frozen neighbor** — an adjacent zone's static geometry kept in memory but not rebuilt each turn (only
  the live zone's creatures rebuild per step; static geometry is frozen per zone — see §on freezing).
- **grade** — the full-screen day/night **MULTIPLY** tint (`Main._grade`) over the whole viewport.
- **darkness overlay** — the per-cell MIX-black layer (`_build_darkness`) that does the actual dimming
  underground / at night, falling off to black around light sources (the grade stays near-neutral so it
  doesn't double-dark the light pools).
- **additive glow** — a `BLEND_MODE_ADD` quad/billboard that brightens whatever's behind it without scene
  lighting (how "lights" are faked in the unshaded path).
- **override** — a standing per-tile-family rule (shape/fill) in `overrides.json`, read live each frame.

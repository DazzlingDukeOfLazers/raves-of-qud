extends Node3D
class_name ZoneRenderer

## Renders a zone snapshot:
##   layer <= FLOOR_LAYER_MAX -> flat quad on the ground (shale *, dirt, water)
##   wall (IsWall)            -> merged into ONE greedy-meshed rock mesh per zone
##   otherwise                -> upright billboard sprite (plants, creatures, items)
## Walls are greedy-meshed: adjacent wall cells become a single mesh with merged
## top faces, only exposed side faces, and real normals — so a lit material makes
## the rock read as carved 3D instead of flat cubes. Tiles are 2-colour masks
## (black = TileColor, white = DetailColor) recoloured on the CPU.

const CELL := 1.0
const FLOOR_LAYER_MAX := 2
const WALL_H := 1.2
# When true, walls and the ground use SHADED materials lit by the sun so they
# cast/receive directional shadows. When false, everything is UNSHADED (exact tile
# colours, no shadows) -- the original look. Flip this to compare.
const SHADED_WORLD := true
const WALL_NORMAL_SCALE := 4.0   # strength of the tile-derived wall relief (cranked to confirm it applies)
const FENCE_H := 0.6  # standing height of fence/pipe panels (content, sat on ground)
const FLOAT_Y := WALL_H * 0.5  # cell mid-height, where a "float" verdict centres a tile
const PIXEL_SIZE := 0.042
const FLOOR_Y := 0.02
const LAYER_STEP := 0.02
# Floor quads stack by RenderLayer, NOT by their order in the cell's object
# array — Qud sends objects in cell-stack order, which is not render order. A
# crack (layer 1) arriving after the water (layer 2) would otherwise be drawn on
# top of it, showing through a pool that hides it completely in-game.
const LAYER_LIFT := 0.004
const TIEBREAK := 0.0005   # separates equal-layer floors without reordering them

# --- water & bridges --------------------------------------------------------
# Deep water stays FLAT at floor level; we recess the actor, not the water. A
# creature standing in it is drawn cropped at the waterline so it reads as
# half-submerged. A bridge cancels that: it's an opaque deck laid over the water.
const BRIDGE_Y := 0.08     # deck height — clears every floor quad below it
const WATER_LINE_Y := 0.05 # where a submerged sprite gets cut off
const SINK_WADE := 0.45    # fraction of the sprite's art hidden (wading depth)
const SINK_SWIM := 0.72    # legacy swimming depth; superseded by deep_water_depth (live-tunable)
# Deep-water submersion, 0 (rides on the surface) .. 1 (a full tile under). Live-tunable via
# the ` debug-menu slider. Default rides swimmers ~12% higher than the old 0.72 so they read
# as "in the water" without being buried.
var deep_water_depth := 0.6

# Vertical gap between stacked Z-levels, in world units. A remembered zone `dz` strata
# below the live one is dropped by dz * level_height (see _sync_neighbors), so deeper
# levels stack under the current one. Live-tunable via the ` debug-menu slider; 0 lays
# every level coplanar (the pre-stacking behaviour).
var level_height := 4.0

# Cavern lighting. Underground (zone.z > SURFACE_Z) there is no sky, so instead of the
# global day/night dimmer we darken PER CELL from Qud's own light map (each cell sends
# `light`, a LightLevel byte: Blackout=0, None=1 .. Light=200). Away from any source the
# cell falls toward black; the additive torch/glow geometry is then the only light. Built
# fresh each turn in the dynamic pass, so it follows moving light. See _build_darkness.
var _underground := false
var _world_map := false           # zone.z < 0: the parasang overview — flat & lit, no torch glows
const SURFACE_Z := 10
const DARK_MAX := 0.94          # deepest per-cell darkening (never pure black — faint memory)
## How bright REMEMBERED ground stays. MEASURED OFF QUD, not chosen: Qud barely darkens remembered
## ground at all, because its memory is a PALETTE SWAP of the glyphs (&K/k) and a cell is ~99.7%
## background (tile-dirt1.png is 1 opaque pixel in 384) — so the background it swaps nothing about
## dominates. Native captures of the same zone: lit field rgb(17,53,52), remembered rgb(15,45,44),
## a ratio of 0.85. This value is that ratio through the overlay: alpha = (1-f)*DARK_MAX = 0.15.
##
## It was 0.35 (alpha 0.61, near-black ground) on the strength of screenshots taken while Raves was
## stuck in 1:1 mode, where _build_darkness returns before doing anything — so every reading that
## drove it, including the request to go darker, described a render this constant never touched.
const MEMORY_GROUND := 0.84

## How bright NEVER-SEEN ground stays — the fog of war. Qud's own answer is "no darkening at all":
## a histogram of its playfield contains 0.00% near-black pixels (max channel < 12), because Qud
## paints CAMERA_BACKGROUND across the whole 80x25 stage and simply draws no glyphs on cells you
## have not seen. Its darkest real ground is rgb(11,33,33) — still the field family, and that floor
## is its LIGHT gradient, which Raves models separately through this same overlay.
##
## So the fog is not a colour of its own, it is the field seen dimmer. This sits a little under
## MEMORY_GROUND so the frontier is still legible in 3D, where the camera shows far more of the
## world at once than Qud's stage does; 1.0 would be literal Qud. Raves drew it at black (f = 0.0,
## alpha 0.94) before, which is the one thing Qud never does.
const FOG_GROUND := 0.70

## THE ZONE YOU LEFT, fading with distance. Daniel: "the zone you left ... shaded as if they were
## no longer in the line of sight ... the edge row a little dim and fully dark by 4 tiles in. It's
## the same as if a building or something is in the way."
##
## The ramp is measured from the LIVE zone's boundary, not from the player: what matters is how far
## past the edge of what you can see a cell sits. FROZEN_EDGE_DIM is the row butted against the live
## zone, and the darkness reaches full by FROZEN_DARK_IN tiles in.
const FROZEN_EDGE_DIM := 0.18   # alpha on the row touching the live zone — just off clear
## RADIUS in tiles, and STEPS PER TILE, both from Settings so they can be tuned and preset without
## a rebuild (the committed `penumbra-3x1` fixture is the tile-resolution baseline).
##   radius     3 -> the fade spans 3 tiles and is fully dark on the 4th
##   divisions  1 -> one flat step per tile. Higher subdivides WITHIN the tile; 16 puts a step on
##              every pixel column of Qud's 16x24 art, which is as fine as the tile can render.
## Subdivision is AXIS-AWARE: a cell in an edge band only varies along one axis, so it costs D
## sub-quads rather than D squared. At D=16 that is 23k quads for a zone's band instead of 231k —
## the difference between a knob you can turn and the overdraw crash this file already documents.
var penumbra_radius := 3
var penumbra_divisions := 1
## ...and the LIVE zone fades toward its own edges, so the world does not simply stop at a hard
## line. Daniel: "the current zone should always fade out in all cardinal directions." The
## outermost row lands on FROZEN_EDGE_DIM — the same value the neighbour's first row carries — so
## the two halves meet at one brightness and the seam reads as one continuous fade rather than two
## ramps that happen to be adjacent. Clear again LIVE_EDGE_FADE tiles in.
const LIVE_EDGE_FADE := 4

## THE TWO RAMPS ABOVE ARE OFF, and stay off. They were the first design for the boundary — the
## "bib" — and what killed them is worth keeping, because it is not a tuning story.
##
## Both land on FROZEN_EDGE_DIM at the shared boundary, which was meant to make the two halves meet
## at one brightness. They meet at one ALPHA. That is not the same thing: each side applies that
## alpha over a DIFFERENT BASE. Measured at the Joppa north boundary at night, straight down a
## column of open ground —
##
##     the frozen side ramps  (0,1,2) -> (9,32,40)   brightest at the row touching the live zone
##     the live side is flat            (5,23,28)
##
## — so the two rows meant to be equal differ by 1.8/1.45/1.48, a different factor per channel. No
## single alpha produces that, because darkening cannot reconcile two different bases: the live
## floor is painted-ground tile art under the night grade, the frozen side is remembered art, and
## past a loaded neighbour it was the bare field plane. Three materials, one ramp.
##
## MEASURE AT NIGHT. The daylight check that once said the seam matched could not have failed —
## in full daylight there is barely a penumbra to get wrong.
const ZONE_RAMPS_ON := false
## THE REPLACEMENT, and it is on: the surround band in _build_unexplored, which stops computing a
## colour for the ground outside the zone and repeats the edge cells' own ground quads outward,
## darkening from each edge cell's own tone. Base and alpha both matched per-cell, by construction.
## Read the note on _build_unexplored for how it works; this is the switch that turns it off.
##
## It replaces the ramps rather than joining them. The live zone must NOT also fade toward its own
## edges: the band already starts at the edge cell's brightness, so an inward fade on top would
## darken the zone you are standing in for nothing — which is the "(0,24) my character seems to be
## in discovered fog-of-war" report that gated _live_edge_light on line of sight in the first place.
const SURROUND_BAND_ON := true
## A DEPARTED ZONE IS NEVER BRIGHTER THAN THE ZONE YOU ARE STANDING IN.
##
## Qud's memory is a palette swap that ignores the time of day, so a remembered zone renders at a
## flat MEMORY_GROUND however dark it is where you are. In Qud that is invisible -- you only ever
## see one zone -- but Raves draws the neighbours, and at night the live zone is darker than
## MEMORY_GROUND, so every departed zone became a bright halo around a dark one. Measured on the
## Joppa north boundary at night: the neighbour at (9,33,41) against the live zone at (5,24,29).
## Daniel: "the start color of the penumbra bib ramp is much lighter than the tile I'm standing in."
##
## The old ramp could not fix this and no darkness overlay can: going outward the brightness has to
## INCREASE, and alpha only darkens. So the answer is not a ramp at all -- it is a ceiling. The
## remembered tone becomes max(1 - MEMORY_GROUND, ambient), which leaves memory alone whenever the
## world is at least as bright as it (daylight, a lit interior) and clamps it when the world is
## darker. Applied to the TONE, so it composes by the same "neither one can LIGHTEN the other" max
## rule as everything else in pass 1 rather than as another layer on top.
## UNCONFIRMED ON GLASS. The tone changes and the bake fires with it — the probe reports the live
## zone at 0.2820 and the departed zone moving 0.1600 -> 0.3969, `dark_cap` updated, one darkness
## mesh present — and the rendered pixels of the departed zone do not move: byte-identical crops
## between cap 0.2820 and 0.3969, where a 16% brightness change was owed. So something downstream
## of the tone is deciding a remembered cell's brightness, and this constant is not it.
##
## Where the trail ended, for whoever picks it up: a remembered cell is drawn as the memory WASH
## (_world_bg at REMEMBER_COVER = 0.92, near-opaque) with the darkness quad over it, both in the
## one blended mesh, wash emitted first. The wash is not scaled by the tone at all — so if it is
## the wash that is being seen, the tone can be anything and the cell will not move. That is the
## first thing to test: scale the wash's own colour by the cap and see if the pixels follow.
##
## Do not trust a broad-region median to answer it either. The zone used for these measurements is
## a waterlogged tunnel, and its neighbour crop is water- and wall-dominated: two earlier readings
## off that crop compared different terrain and read as a brightness difference that was really a
## content difference. Sample the probe cells (zonereport) on open ground of the same kind.
const DEPARTED_CAP_ON := true
## How coarsely the cap is quantised for the re-bake guard. A neighbour's darkness is baked once
## per relationship, so the cap has to join the key or it goes stale the moment dusk falls while
## you stand still -- and it must NOT be continuous, or a value that drifts every turn re-bakes all
## eight neighbours every turn, which is the crossing cost this file spent a session flattening.
## 1/16 gives a handful of re-bakes across a whole night and none at all while the light holds.
const CAP_QUANT := 16.0

## Above this alpha a darkness quad is drawn OPAQUE instead of blended. Not cosmetic — it is what
## makes the frozen-zone ramp affordable. A full sheet of alpha-blended quads over every neighbour
## is the thing that crashed in _platform_memmove (see _build_darkness), and the ramp would be
## exactly that if its solid interior blended too. Past the ramp every cell is FULLY dark, and
## "fully dark" needs no blending — it is a black surface. So the blended fill stays capped at the
## FROZEN_DARK_IN-deep band along the shared edge whatever the zone's size.
const DARK_SOLID_A := 0.995
## Alpha difference across a cell below which subdividing it cannot change the picture: a vertex
## colour is 8-bit, so anything under 1/255 quantises to the same byte. The gate that turns a
## 256-quad gradient back into one quad (see _veil_bounds).
const FLAT_ALPHA := 1.0 / 255.0
## THE MEMORY WASH. A remembered cell is not "the floor, dimmed" — in Qud it is the FIELD, because
## a cell is ~99.7% background and memory only repaints the sparse glyph in K/k. Measured on Qud at
## dusk: its playfield is the field colour throughout, with water showing only as a lighter teal
## stipple, never as blue. Painting the field colour gets there without touching the floor batches,
## which are MultiMeshes keyed by material — a per-cell swap would mean splitting and rebuilding
## them every turn as sight changes. This is the overlay quad that was already being emitted, in a
## different colour, with the ordinary darkness still laid over it for the remembered dimming.
##
## How completely the memory wash covers a remembered cell. Not 1.0: a trace of the real floor
## showing through is what keeps a remembered river reading as a river-shaped thing rather than
## flat ground, which is also what Qud's sparse K/k glyphs do.
const REMEMBER_COVER := 0.92
const DARK_FLOOR_Y := 0.07      # darkness quad sits just above the floor tiles
const DARK_ROOF_Y := WALL_H + 0.02   # and just above wall roofs, to dun unlit rock tops
## FULLY-DARK ground sits at FLOOR height, like every other darkness quad.
##
## Raising it above the sprites was tried, to stop trees and grass glowing out of a region that is
## meant to be unseen, and it works — but it trades one artifact for a worse one: an opaque plane a
## metre off the ground can be seen UNDER, and at any oblique angle a bright strip of untouched
## ground plane appears along the whole boundary. Measured at both WALL_H + 0.6 and WALL_H + 0.02;
## the strip is there either way, because the camera does not have to be far off the horizontal to
## get beneath it.
##
## So the unexplored surround (which has no assets to expose — those zones are never loaded) is
## clean at floor height, and a VISITED zone's far side still shows its plants through the dark.
## Fixing that needs the sprites hidden rather than covered, which is per-cell work on a frozen
## subtree that nothing currently tracks.
const DARK_SOLID_Y := DARK_FLOOR_Y
var _dark_mat: StandardMaterial3D

# How a tile's TRANSPARENT pixels are treated when recolouring.
#   NONE     leave see-through (fences, floors)
#   ALL      paint every one with the cell background (wall faces, decks, tents)
#   INTERIOR paint only the gaps enclosed by the art (billboards) — so a chest's
#            lock reads as background but the world still shows past its outline
## How a tile's TRANSPARENT pixels are treated.
##   NONE      leave see-through (fences, floors)
##   ALL       paint every one — including outside the art, so the tile becomes a
##             filled rectangle (wall faces, decks, tents)
##   INTERIOR  only gaps ENCLOSED by the art (default for billboards)
##   SPAN      "fill the holes": INTERIOR's enclosed gaps UNION every gap spanned
##             within a row. Neither alone is a superset — a wheel's open paddle
##             bottoms fill only by row-span, a millstone's pinched notches only by
##             enclosure — so the "more fill" mode is both. Always >= INTERIOR.
enum Fill { NONE, ALL, INTERIOR, SPAN, POCKETS }

# Widest horizontal transparent run still treated as a seam in the art rather
# than a genuine opening. Tuned against sw_chest (1px channels beside its bands,
# must fill) vs sw_dromad (10px gap between its legs, must not).
const MAX_SLOT_PX := 2

# User verdicts from RavesOfQud/reports/, keyed by TILE FAMILY. Some things are
# simply not in Qud's data — a water wheel runs east-west, but nothing in
# `sw_waterwheel_1` says so. This is how a human supplies what cannot be derived,
# and it applies live: file a report, take a turn, see it.
var _overrides := {}        # tile family -> shape verdict
var _fill_overrides := {}   # tile family -> Fill mode
var _position_overrides := {} # tile family -> "float" (default is ground-seated)
var _glow_overrides := {}   # tile family -> true (user tagged it bioluminescent GLOW)
var _cutout_overrides := {} # family -> true: the darker of main/detail renders TRANSPARENT
var _recolor_overrides := {} # family -> {source colour code: replacement code}
var _stairdir_overrides := {} # tile family -> "n"/"e"/"s"/"w" (descent the user picked)
var _core_overrides := {}   # tile family -> Color: the wall recess/core colour (voxel editor)
var _overrides_raw := "?"   # last overrides.json text, to skip re-parsing
var _overrides_dirty := false  # overrides.json changed -> frozen static needs a rebuild
# Export race: the mod exports tiles ON SIGHT (a frame after the snapshot that first
# references them), but the live static geometry is built ONCE per zone entry and frozen.
# So a not-yet-exported tile bakes a glyph fallback that never retries. When the live
# build hits a missing/unreadable tile we flag it and rebuild the static on a later
# snapshot (once the tile has landed), bounded so a genuinely-absent tile doesn't loop.
var _static_saw_missing := false   # live build referenced a tile not yet on disk
var _static_retry_pending := false # rebuild the live static next snapshot
var _static_retry := 0             # consecutive retries for the current zone
const STATIC_RETRY_MAX := 4

var _palette := {}          # colour char -> "#rrggbb", from the mod (authoritative)
var _tiles_dir := ""
var _mask_cache := {}       # fname -> Image
var _interior_cache := {}   # fname -> Array[Array[bool]]
var _tex_cache := {}        # "tile|main|detail|fill" -> ImageTexture
var _texmat_cache := {}     # key -> StandardMaterial3D (floors)
var _colmat_cache := {}     # color html -> StandardMaterial3D
var _wallmat_cache := {}    # "kind|tile|main|detail|bg" -> ImageTexture (wall face art)

var _plane: PlaneMesh
var _fence_quad: QuadMesh          # unit quad; scaled per fence half-panel
var _fence_pool: Array[MeshInstance3D] = []
var _fencemat_cache := {}          # "ewtile|main|detail|half" -> StandardMaterial3D
# Rebuilt per snapshot. Wall TYPES only group the build (_rebuild_walls walks type by type so
# each cell's voxel volume is carved under its own colours); what lands here is one MeshInstance
# PER CELL, positioned at (k.x, 0, k.y), plus that cell's seam fills and carve closures. Per-cell
# is what lets the camera cutaway fade individual walls and the fog hide or ghost them —
# see _track_wall, which registers every one of those meshes under its cell in _wall_cutaway.
var _wall_root: Node3D

# set per wall-type while building that type's mesh
var _wall_tile := ""
var _wall_main := ""
var _wall_detail := ""
var _wall_bg := ""       # background colour code (the ^X in the ColorString)

# What Qud paints behind the world. WORLD_BG_FALLBACK is a hand-estimate; the mod
# sends the real ColorUtility.CAMERA_BACKGROUND and _world_bg takes over. Ours read
# black next to Qud's dark teal, which flattened the whole scene.
const WORLD_BG_FALLBACK := Color("#0f3b3a")  # Qud's 'k'; only used pre-palette
var _world_bg := WORLD_BG_FALLBACK
var _ground_mat: StandardMaterial3D

# What the renderer actually DID with each object, keyed by cell. The wire data
# says what Qud sent; this says how it was classified and where it landed — the
# gap between those two is where every rendering bug so far has lived.
# Read by CellInspector; rebuilt each snapshot.
var _placed := {}   # Vector2i -> Array[{idx, kind, y}]  (static build: walls, floors, sprites)
var _dyn_placed := {}   # same, for the live DYNAMIC pass (creatures) — cleared every turn, so
                        # the inspector reports a creature's real render instead of "dropped"
var _dyn_noting := false

# Torch/fire light. The world uses UNSHADED materials, so a real Godot light
# does nothing. Instead each lit object gets an ADDITIVE warm ground-glow plus a
# small flickering flame — brightening the flat tiles the way an additive decal
# would, and reading correctly in the top-down 2.5D view.
var _light_root: Node3D
var _remembered_root: Node3D    # parent of the frozen per-zone neighbour subtrees
var _static_zones := {}         # zoneId -> Node3D (that zone's frozen static geometry)
var _dynamic_root: Node3D       # the live zone's creatures, rebuilt every step
var _live_static_id := ""       # which zone's static is currently built as "live"
var _live_static_sig := 0       # signature of the live zone's static objects; a change (e.g. a placed
								# campfire, a dug wall) forces a static rebuild within the same zone
var _bank: Node3D = null        # non-null while building a zone's geometry INTO it
## True ONLY while building a REMEMBERED NEIGHBOUR's geometry — a zone the player is not in, whose
## art is drawn in Qud's memory pair. Explicit, because the two flags nearby do not say this and
## every way of deriving it from them is wrong in a way that ships:
##   _live_build  is false during the DYNAMICS pass too, so keying off it ghosted every creature —
##                the player included, who then stood in his own lit zone looking fogged.
##   _bank        is non-null for the LIVE zone's static build as well, so keying off that would
##                ghost the zone you are standing in.
## The pair `_bank != null and not _live_build` is correct and unreadable; this is that, named.
var _remembered_build := false
var _noting := true             # whether _note records (off during dynamic-only rebuilds)
var _live_build := false        # true only while building the LIVE zone's static (its
                                # torches register for the _process flicker; neighbours don't)
var _hidden_cell := Vector2i(-9999, -9999)   # a live cell whose creature is not drawn (first-person: the player)
var _player_cell := Vector2i(-9999, -9999)   # the player's cell this snapshot (from data.player), for the world-map "on top" rule
var _placing_player := false                 # true while placing the player's own sprite in the dynamic pass

## The visual layer the PLAYER'S OWN CELL is drawn on, so a camera can drop it without anything
## else having to change.
##
## First person used to hide the player by SKIPPING placement of that cell (see _hidden_cell), and
## that cannot work once more than one camera looks at the same world: multiview renders seven
## panes out of ONE World3D, so skipping hid the player from all seven, and not skipping stood him
## in front of the first-person camera. Daniel: "first person seems to have moved the player in
## front of the camera on occasion. Like right now." Neither is a placement question -- it is a
## per-camera one, and Godot answers it with layers and cull_mask.
const PLAYER_LAYER := 1 << 9

## Put every VisualInstance3D in a subtree on a layer (bit OR'd in, so it keeps rendering to

## Put everything standing on the player's own cell onto PLAYER_LAYER, so a first-person camera
## can drop it. Runs after the dynamic pass, over the whole per-turn subtree.
func _tag_player_cell() -> void:
	if _dynamic_root == null:
		return
	var px := float(_player_cell.x)
	var pz := float(_player_cell.y)
	for c in _dynamic_root.get_children():
		var n3 := c as Node3D
		if n3 == null:
			continue
		# half a cell either way: a billboard is seated on the cell centre, and its children
		# (glow quads, particle emitters) sit within it.
		if absf(n3.position.x - px) <= 0.5 and absf(n3.position.z - pz) <= 0.5:
			_tag_layer(n3, PLAYER_LAYER)

## cameras that do not cull it).
func _tag_layer(n: Node, bit: int) -> void:
	if n is VisualInstance3D:
		# MOVE it, do not ADD it. `layers |= bit` left the node on layer 1 as well, and a camera
		# that drops PLAYER_LAYER still sees layer 1 — so the cull did nothing at all and the
		# mechanism only ever LOOKED right, because the player is usually out of frame in the
		# first-person pane anyway. It stopped looking right the moment Daniel caught fire: the
		# flame and smoke emitters sit on his own cell, which is exactly where that camera is, and
		# the pane filled with smoke. Every other camera's cull_mask includes PLAYER_LAYER by
		# default, so moving the node changes nothing for them.
		(n as VisualInstance3D).layers = bit
	for c in n.get_children():
		_tag_layer(c, bit)

func set_hidden_cell(c: Vector2i) -> void:
	_hidden_cell = c

## Parent for freshly-spawned nodes: the frozen bank when building a remembered
## zone, else the renderer itself (live zone, pooled).
func _spawn_parent() -> Node:
	return _bank if _bank != null else self

## Track a live node for pooling next frame. Remembered nodes persist in _bank, so
## they are never pooled.
func _track(n: Node) -> void:
	if _bank == null:
		_active.append(n)

## Parent for wall meshes: the frozen bank when building a remembered zone, else
## the per-turn _wall_root.
func _wall_parent() -> Node:
	return _bank if _bank != null else _wall_root
var _glow_tex: Texture2D
var _flame_tex: Texture2D
var _fire_tex: Texture2D          # a drawn flame SHAPE (alpha-blended) for on-fire objects (campfires) — reads by day
var _smoke_pm: ParticleProcessMaterial   # shared across every sconce's smoke emitter
var _smoke_mesh: QuadMesh                 # shared grey square, billboarded
var _fire_pm: ParticleProcessMaterial     # particle FIRE (torch), the smoke's sibling rig
var _fire_pm_big: ParticleProcessMaterial # campfire variant: wider base
var _fire_mesh: QuadMesh                  # shared fire square, billboarded, additive
var _mote_tex: Texture2D                  # small glowing dot for glowfish orbiters
var _glow_shader: Shader                  # crisp bioluminescent bloom over the fish silhouette
var _lights: Array = []           # [{glow, flame, smoke, energy}]
# Live zone's STATIC upright billboards (trees, brinestalks, scenery) with their cell, so
# they can be dimmed by the cell's light EACH TURN like creatures — they'd otherwise stay
# lit at night while the ground around them goes dark. [{s: Sprite3D, cell: Vector2i}]
var _lit_sprites: Array = []
# Same idea for connector panels (fences, pipes, axles): they are MeshInstance3D, not
# Sprite3D, so they dim via a per-instance material's albedo_color, not modulate.
var _lit_meshes: Array = []       # [{mi: MeshInstance3D, cell: Vector2i}]
# Floor batching: accumulate this build's floor quads by MATERIAL, then flush one MultiMesh
# per material (one draw call per tile type, instead of one MeshInstance3D per cell — 2000 of
# them tanked the world map). Material -> Array[Transform3D]. Flushed per static/neighbour build.
var _floor_batch := {}
## THE LIVE ZONE'S OUTERMOST RING OF GROUND QUADS, kept so the surround band can repeat them.
## Vector2i -> [material, scale, y], captured where the quad is batched (see _place_nonwall).
## Materials are shared, not copied: repeating one outward adds MultiMesh instances to a batch
## that already exists, so a band costs transforms, not textures.
var _edge_floor := {}
## ...and that ring's TONE, so the band's ramp can START at the darkness of the cell it abuts
## instead of at a constant. Per-cell, not a mean: the ring crosses lit and unlit stretches, and
## a mean is exactly what made the old ramp meet a lit edge too dark and an unlit edge too light.
var _edge_tone := {}
## What the last _build_unexplored actually did, for the `zonereport` probe. Reading this off a
## screenshot is guesswork -- a band cell and a frozen neighbour's memory-toned ground are similar
## colours, and I burned a round assuming a slot was unvisited when it was loaded. Ask the builder.
var _band_stats := {}
## THE LIVE ZONE'S AMBIENT DARKNESS this turn — the MEDIAN tone over its cells, and the ceiling on
## how bright a departed zone may render (see DEPARTED_CAP_ON). Median, not mean and not per-cell:
## it has to be a property of the zone's ambient light, steady while you walk. A torch, a campfire
## or the player's own light touches a handful of cells and the median steps over all of them,
## where a mean would drift with every step and a per-cell cap would make the whole remembered
## neighbourhood ripple as the light moved along the shared edge.
var _ambient_tone := 0.0
## ...and the luminance of its ground art, so the cap can be stated in what the two zones actually
## RENDER as rather than in the alphas they store. Capping the alpha alone does not work: a departed
## zone's floor is recoloured to Qud's flat memory pair (K, #155352 — a bright teal) while the live
## zone's is real art under the night grade, so equal alphas still came out 2.8/1.92/1.96 apart.
## Measured underground with both zones dark and both tones at 0.2820. Same trap as the old bib:
## the alpha was never the part that was wrong.
var _live_lum := 0.0
# World-map cards: on the parasang map (z < 0) each terrain tile stands UP as a card instead of
# lying flat, so the tilted compass camera reads the art face-on. Placed as plain Sprite3D
# billboards (the proven path — a MultiMesh with a billboard material faulted the Metal driver),
# tagged "wm_tile" so the orientation toggle can retarget them live. Follow-camera by default;
# set_wm_face_ns(true) locks them all as EW panels facing N/S; top-down lays them flat.
var _wm_face_ns := false               # false = cards follow the camera; true = locked EW (facing N/S)
# World-map tiles stand up as cards (true) vs flat batched floors (false). This was flipped off
# to isolate a Metal crash on world-map<->surface transitions; the real cause was the single-frame
# GPU-resource spike, now fixed by the incremental build (see _build_static / _ib_step), so the
# cards are safe again — their ~2000 sprites are created a chunk per frame, not all at once.
const WM_STANDING_CARDS := true
# Camera cutaway: the LIVE zone's wall nodes keyed by cell, so a wall between the camera
# and the player can fade out of the way. Faded via GeometryInstance3D.transparency with
# the wall material in ALPHA_HASH mode (screen-door dither), so it stays in the opaque pass
# — no transparent-sort artifacts. [Vector2i -> Array[MeshInstance3D]]
var _wall_cutaway := {}
const CUTAWAY_MAX := 0.88         # deepest fade for a wall right on the line of sight
const CUTAWAY_LERP := 9.0         # per-second ease, so walls fade in/out smoothly
const CUTAWAY_LIT_MIN := 0.25     # only LIT walls fade; dark ones (already near-invisible) stay
const CUTAWAY_RADIUS := 11.0      # only fade walls within this many tiles of the player (perf +
                                  # sanity: the overworld is all lit, so an unbounded rule would
                                  # try to fade the whole zone)
const NEIGHBORS8 := [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1),
	Vector2i(1,1), Vector2i(1,-1), Vector2i(-1,1), Vector2i(-1,-1)]
var _cell_light := {}             # Vector2i -> light frac this turn, for the cutaway's lit test
var _was_dark := false            # last turn had dark cells (so a lit turn knows to un-dim once)
var _orbiters: Array = []         # glowfish "bugs": [{root, motes:[{s, ...orbit params}]}]

# Torches are ADDITIVE — they brighten whatever is behind them by a fixed amount
# regardless of time of day. That reads great at night but blows out the already-bright
# daytime scene (the glow ends up brighter than the environment). So fade torch intensity
# with daylight: full at night, a faint ember at noon. Fed by Main._update_sky via
# set_daylight(sun_a), where sun_a is 0 at night .. 1 at midday.
var _daylight := 0.0
const GLOW_DAY_MIN := 0.0     # ground light-pool: fully gone at midday (no darkness to fill)
const FLAME_DAY_MIN := 0.0    # flame ball: fully gone at midday; the sconce post carries the tile

## Multiplier for the ground glow / the flame, given the current daylight. Both are 1.0
## at night and fall to their *_DAY_MIN floor at midday.
func _glow_mul() -> float:
	return lerpf(GLOW_DAY_MIN, 1.0, 1.0 - _daylight)
func _flame_mul() -> float:
	return lerpf(FLAME_DAY_MIN, 1.0, 1.0 - _daylight)
## A FIRE's ground light-pool is only visible in real darkness (you can't see fire-light by day — that
## additive blob was the "second light"). Full at night, gone by early dawn; the flame is the daytime cue.
const FIRE_GLOW_DARK := 0.25   # daylight level above which a fire's ground-pool is fully off
func _fire_glow_mul() -> float:
	return clampf((FIRE_GLOW_DARK - _daylight) / FIRE_GLOW_DARK, 0.0, 1.0)

## Push the current daylight strength (0 night .. 1 midday) so torches fade in daylight.
## Cheap: the live zone applies it per-frame in _process; static/neighbour lights bake it
## in at build time (they don't flicker), which is fine since they're distant and fogged.
func set_daylight(sun_a: float) -> void:
	_daylight = clampf(sun_a, 0.0, 1.0)
	# Smoke is night-only: toggle every live sconce's emitter with the time of day. Setting
	# emitting=false lets the puffs already aloft finish rising and fade (~lifetime), so the
	# plume tapers off at dawn rather than vanishing.
	var on := _smoke_on()
	for L in _lights:
		if L.has("smoke"):
			# a real fire burns day + night, so its smoke keeps emitting; a torch's smoke is night-only
			(L["smoke"] as GPUParticles3D).emitting = true if L.get("fire_smoke", false) else on

var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _floor_pool: Array[MeshInstance3D] = []
var _label_pool: Array[Label3D] = []
var _top_down := false   # top-down camera modes: tile billboards lie flat to face up
# 2D mode: lay the WHOLE world flat. Every tile — terrain, scenery, fences, walls, world-map cards,
# creatures — routes through the flat floor-quad path instead of standing up as a billboard/prism.
# A true "classic 2D map" on any stratum, at any camera angle (the compass view then reads as 2.5D).
# Toggled from Main (O key / the corner button); forces a static rebuild via set_flat_2d().
var _flat_2d := false

# Live zone dimensions (cells), read off each snapshot — neighbours on a stratum share them, so they
# size the distance cull below. Defaults are the standard surface/cavern zone (80x25).
var _live_w := 80.0
var _live_h := 25.0

# Distance cull for remembered neighbours: a zone whose NEAREST point is past this (world units) is
# fully swallowed by the distance fog (Main's env.fog_depth_end ~= 240) yet Godot still draws it —
# pure cost when you rotate to look across many explored zones. Hide those; it's beyond the fog, so
# there's no visible change. Margin (~one zone diagonal) keeps a zone that the player could be near
# the far edge of from popping. Frustum culling already skips OFF-screen zones; this skips the
# in-frustum-but-fully-fogged ones it can't.
const NEIGHBOR_CULL_DIST := 330.0

## Flip the whole world between 3D (upright billboards + wall prisms) and 2D (everything flat on the
## floor). Frozen static geometry was built for the old mode, so drop it; Main re-renders the current
## snapshot right after, which rebuilds the live zone (and neighbours) in the new mode.
func set_flat_2d(on: bool) -> void:
	if on == _flat_2d:
		return
	_flat_2d = on
	_drop_all_static()

func flat_2d() -> bool:
	return _flat_2d

# 1:1 (parity) LIGHTING — Qud's rectangular model, measured off the wire + captures:
# the light byte is BINARY in practice (Light=200 in the sight/source discs, None=1
# everywhere else; no gradient), unexplored cells draw NOTHING (the field colour shows),
# explored-but-dark cells draw the terrain DIMMED (Qud's memory look; creatures are
# never drawn out of sight), and there are no glows/flames/smoke/sun — the lit cells
# themselves are the lighting. User mode keeps the full 3D stack; these are hard gates
# so none of it is even LOADED in 1:1.
var _one_to_one := false
var _ground: MeshInstance3D          # the field plane (clipped to the stage in 1:1)
var _ground_plane: PlaneMesh

# Qud's stage field as actually RENDERED (measured off native captures — palette 'k' plus Qud's
# own output transform). The user-mode ground keeps the palette-true colour + shading.
const QUD_FIELD_1TO1 := Color8(17, 52, 51)

func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	# The ground plane IS Qud's field in 1:1: at the measured field colour, and CLIPPED to the stage
	# rect — Qud's field exists only inside the 80x25 stage; the letterbox around it is the AREA
	# colour (17,33,38), which the env clear provides (see SkyGrade). User mode restores the huge
	# palette-k ground. Only the COLOUR and the SIZE differ now; both modes are unshaded (see _ready).
	if _ground_mat != null:
		_ground_mat.albedo_color = QUD_FIELD_1TO1 if on else _world_bg
	if _ground_plane != null and _ground != null:
		if on:
			_ground_plane.size = Vector2(80, 25)          # exactly the zone footprint
			_ground.position = Vector3(39.5, -0.02, 12.0) # cells span x[-0.5,79.5] z[-0.5,24.5]
		else:
			_ground_plane.size = Vector2(400, 400)
			_ground.position = Vector3(40, -0.02, 12)
	_drop_all_static()   # Main re-renders right after (same contract as set_flat_2d)

func _ready() -> void:
	_plane = PlaneMesh.new()
	_plane.size = Vector2(CELL, CELL)
	_fence_quad = QuadMesh.new()
	_fence_quad.size = Vector2(1, 1)  # scaled per instance
	_wall_root = Node3D.new()
	add_child(_wall_root)
	_landmarks_root = Node3D.new()   # parasang-scale surface landmarks (Spindle, Red Rock)
	add_child(_landmarks_root)

	# Qud-green ground surface under everything, so the world reads as ground
	# (the dark-green cell background) instead of a black void between the dots.
	var ground := MeshInstance3D.new()
	var gpm := PlaneMesh.new()
	gpm.size = Vector2(400, 400)
	ground.mesh = gpm
	ground.position = Vector3(40, -0.02, 12)  # big enough to cover any zone
	_ground = ground
	_ground_plane = gpm
	var gm := StandardMaterial3D.new()
	# UNSHADED IN BOTH MODES. The field is Qud's flat background colour, and the per-cell darkness
	# overlay is what encodes Qud's light model — running the plane through SHADED_WORLD as well
	# dimmed it a second time by a constant ambient (it is one flat horizontal plane, so shading
	# adds no variation, only that factor). Measured in user mode: palette k #0f3b3a came out
	# rgb(5,17,15) against Qud's own rgb(17,53,52) — the whole world three times too dark, lit
	# cells included. Nothing is lost: SkyGrade's sun sits at light_energy 0 unless the FX toggle
	# is on, and it exists as the hook for shadows once WALLS move to a shaded material.
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = _world_bg
	_ground_mat = gm
	ground.material_override = gm
	add_child(ground)

	_light_root = Node3D.new()
	add_child(_light_root)

	# Frozen static geometry (walls + floors + static sprites + lights) for every zone
	# — the live one AND remembered neighbours — each its own subtree, built once and
	# only repositioned. Only creatures rebuild per step, into _dynamic_root.
	_remembered_root = Node3D.new()
	add_child(_remembered_root)
	_dynamic_root = Node3D.new()
	add_child(_dynamic_root)
	_glow_tex = _make_radial(64, Color(1.0, 0.62, 0.25), 1.0)   # warm pool of light
	_flame_tex = _make_radial(32, Color(1.0, 0.80, 0.35), 1.6)  # tighter, brighter core (additive torch flame)
	_fire_tex = _make_flame_tex(64)                             # a drawn flame SHAPE for daytime campfires (alpha)
	_mote_tex = _make_radial(16, Color(0.65, 1.0, 0.85), 1.5)   # glowfish bioluminescent mote (cyan-green)
	_build_smoke_resources()
	_build_glow_shader()

# A radial gradient: opaque tint at the centre fading to transparent, `power`
# shapes the falloff. Used additively for both the glow and the flame core.
func _make_radial(n: int, tint: Color, power: float) -> Texture2D:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in n:
		for x in n:
			var d: float = Vector2(x - c, y - c).length() / c
			var a2: float = clampf(1.0 - d, 0.0, 1.0)
			a2 = pow(a2, power)
			img.set_pixel(x, y, Color(tint.r, tint.g, tint.b, a2))
	return ImageTexture.create_from_image(img)

## A drawn flame SHAPE: a teardrop, pointed at the top, bulbous at the base — white-yellow core to orange
## edge, softer at the tip. Alpha-blended (NOT additive) so it reads as an actual flame on a bright
## daytime background, where the additive torch flame washes out. `y=0` is the top of the sprite.
## Prototyped + tuned in Python (an inspectable PNG) before porting — see the project's "pixel algorithms
## in Python first" rule. SILHOUETTE: rounded base, bulbous CONVEX body widest in the lower third, a
## tapering tip that licks subtly to one side (the billboard also flicker-scales, so the texture stays
## clean). COLOUR: a temperature gradient — hot yellow-white core low-centre -> orange body -> deep red
## rim/tip. Alpha-blended (drawn), so it reads on a bright daytime background.
func _make_flame_tex(n: int) -> Texture2D:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var cx: float = (n - 1) * 0.5
	var W: float = n * 0.40
	var c_core := Color(1.0, 0.93, 0.62)
	var c_body := Color(1.0, 0.55, 0.15)
	var c_edge := Color(0.78, 0.15, 0.04)
	for y in n:
		var b: float = 1.0 - float(y) / float(n - 1)     # 0 base .. 1 tip
		var hw: float
		if b < 0.28:
			hw = W * (0.62 + 0.38 * (b / 0.28))          # rounded base -> widest at ~1/3 up
		else:
			hw = W * pow(clampf((1.0 - b) / 0.72, 0.0, 1.0), 0.7)   # convex taper to the tip
		var ctr: float = cx + (n * 0.09) * smoothstep(0.55, 1.0, b)  # only the upper flame licks aside
		var hw_i: float = hw * 0.5
		for x in n:
			var dx: float = float(x) - ctr
			if hw <= 0.5 or absf(dx) > hw:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var t: float = absf(dx) / hw                 # 0 centre .. 1 rim
			var col := c_core.lerp(c_body, clampf(0.20 + b * 0.75, 0.0, 1.0))   # cool with height
			col = col.lerp(c_edge, smoothstep(0.55, 1.0, t))                    # red at the rim
			var core_amt: float = clampf(1.0 - absf(dx) / maxf(hw_i, 0.5), 0.0, 1.0) * clampf(1.0 - b / 0.65, 0.0, 1.0)
			col = col.lerp(c_core, 0.72 * core_amt)      # brighter inner lobe, low-centre, no hard seam
			var a: float = (1.0 - smoothstep(0.72, 1.0, t)) * clampf(1.1 - b * 0.9, 0.15, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)

## Render the live zone (`data`) plus any remembered neighbours. Each neighbour is
## {cells: Array, offset: Vector2i} — its cells shifted into place relative to the
## live zone. Neighbours render full-fidelity but static-only (no creatures).
## A cheap order-independent signature of the LIVE zone's STATIC objects (everything that isn't ground
## or a creature — walls, furniture, sprites, placed items). Stable between steps (creatures excluded),
## so it only changes when static content is added/removed — the cue to rebuild the frozen static.
func _static_signature(cells: Array) -> int:
	var h := 0
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)) or bool(obj.get("creature", false)):
				continue
			# Liquids are volatile: a wet player's wading SLOSHES water pools onto every cell they cross,
			# so including them churns the signature every step and rebuilds the frozen zone mid-walk
			# (the "foreground tiles vanish while walking" bug). Structures (campfire, dug wall) are not
			# liquids, so excluding liquids keeps the placed-object detection this signature exists for.
			if bool(obj.get("liquid", false)):
				continue
			# Include lightRadius: a static object can gain its light a snapshot AFTER it appears (a
			# just-placed campfire lights up next tick), and the glow is placed only on a static rebuild —
			# so the light state must be part of the signature or the campfire renders unlit.
			h ^= hash("%d,%d,%s,%d" % [cx, cy, String(obj.get("name", "")), int(obj.get("lightRadius", 0))])
	return h

func render_snapshot(data: Dictionary, neighbors: Array = []) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))

	# Current combat target (for the 1:1 target-highlight blink). Captured before the
	# dynamics rebuild consumes it; pos + disposition colour letter from the mod.
	var tgt: Dictionary = data.get("target", {})
	if bool(tgt.get("present", false)) and tgt.has("x") and tgt.has("y"):
		_anim_target = {"pos": Vector2i(int(tgt.get("x", 0)), int(tgt.get("y", 0))),
			"color": String(tgt.get("tcolor", "g"))}
	else:
		_anim_target = {}

	# Qud's real palette, sent by the mod. Base/Colors.xml names the colours but
	# has no RGB, so COLORS below is a hand-estimate kept only as a fallback for
	# an older mod build. Changing the palette invalidates every recoloured tile.
	# The field colour is Qud's 'k'. Not a guess and not CAMERA_BACKGROUND (that
	# is the alias "camera background" -> #40a4b9, plain cyan, which painted the
	# whole world turquoise when trusted). Qud's "black" is #0f3b3a, a dark teal —
	# which is exactly the field you see in game. The palette had the answer.

	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty() and pal != _palette:
		_palette = pal
		if pal.has("k"):
			_world_bg = Color(String(pal["k"]))
			if _ground_mat != null:
				_ground_mat.albedo_color = _world_bg
		_tex_cache.clear()
		_texmat_cache.clear()
		_fencemat_cache.clear()
		_wallmat_cache.clear()
		_colmat_cache.clear()
		_drop_all_static()   # frozen geometry holds recoloured textures; rebuild it

	_load_overrides()
	if _overrides_dirty:
		# A standing rule was just edited. Frozen static geometry (walls + floors +
		# static sprites) was built under the OLD rules and isn't rebuilt within a
		# zone, so drop it all — the live zone rebuilds below and neighbours rebuild
		# in _sync_neighbors, both under the new verdict. This is what makes the report
		# form's "live next turn" true again after the static/dynamic freeze split.
		_overrides_dirty = false
		_drop_all_static()   # also resets _live_static_id, forcing the rebuild below

	var live_id := String(data.get("zone", {}).get("id", ""))
	var cells: Array = data.get("cells", [])
	var _zz := int(data.get("zone", {}).get("z", SURFACE_Z))
	_underground = _zz > SURFACE_Z
	# WORLD MAP = Qud's own IsWorldMap(): a ZoneID with NO dot ("JoppaWorld" vs
	# "JoppaWorld.11.22.1.1.10"). The old `z < 0` test could never fire —
	# ZoneRequest assigns world zones Z = 10, the same as the surface (verified
	# in both of its world-zone branches), so this whole render mode (standing
	# cards, flat-and-lit, no torch glows) has never actually run.
	_world_map = live_id != "" and not live_id.contains(".")
	var pc: Dictionary = data.get("player", {})
	_player_cell = Vector2i(int(pc.get("x", -9999)), int(pc.get("y", -9999))) if not pc.is_empty() else Vector2i(-9999, -9999)

	# LIVE STATIC — walls + floors + static sprites + lights. Rebuilt only when you
	# ENTER a new zone (fresh Qud data), then frozen while you step within it. This
	# is what took ~69ms EVERY step before; now it is paid once per zone.
	Profiler.begin("render.static")
	var zone_changed := live_id != _live_static_id
	# Static geometry is frozen within a zone, but a STATIC object can appear mid-zone (place a campfire,
	# dig a wall). Detect it with a cheap signature of the static objects and rebuild when it changes.
	# Skipped on the world map (thousands of cells, and its static doesn't change under the player).
	var static_sig := 0 if _world_map else _static_signature(cells)
	var static_changed := (not zone_changed) and (not _world_map) and static_sig != _live_static_sig
	if zone_changed:
		_static_retry = 0              # fresh zone: reset the export-race retry budget
	if zone_changed or _static_retry_pending or static_changed:
		# A transition arrived while a big zone was still building incrementally: finish it now so
		# the departing zone's subtree is complete (a valid remembered neighbour) before we move on.
		if _ib_active:
			_ib_finish()
		_static_retry_pending = false
		_placed.clear()
		_lights.clear()                # the old live zone's torches stop flickering
		_lit_sprites.clear()           # the old zone's plant/scenery sprites, re-lit each turn
		_anim_sprites.clear()          # and its multi-frame sprites — cleared here because
		                               # _build_static follows immediately and re-registers them
		_lit_meshes.clear()            # and its connector panels (fences/pipes)
		_wall_cutaway.clear()          # and its wall nodes tracked for camera cutaway
		# DROP THE ZONE WE ARE LEAVING, so it is rebuilt as a REMEMBERED one. Its subtree was
		# built with _live_build true — full colour, because you were standing in it — and
		# _sync_neighbors only builds a zone it does not already have, so left in place it stayed
		# at full brightness for as long as it remained a neighbour. Daniel: "the zone I moved out
		# of (north) shows most of the sprites at full brightness."
		#
		# The ramp hides this at first glance: the rows nearest the boundary are only 18% dark, so
		# a full-colour zone reads as merely bright rather than as wrong, which is why it survived
		# several crossings before it was obvious.
		if _live_static_id != "" and _live_static_id != live_id:
			_drop_static(_live_static_id)
		_drop_static(live_id)          # replace any stale (neighbour-built) copy
		_noting = true
		_static_saw_missing = false
		_build_static(live_id, cells)
		_live_static_id = live_id
		_live_static_sig = static_sig
		# A tile was still missing at build time (the mod exports on sight, usually the
		# frame after this snapshot referenced it). Rebuild on a later snapshot so the
		# now-exported tile replaces its glyph — bounded, so a truly-absent tile that
		# never exports stops retrying and keeps the honest "NO TILE EXPORTED" fallback.
		# (Skip the export-race retry while an incremental build is still in flight — "saw missing"
		# is premature until it finishes, and a re-entry would just restart it. Big zones' tiles are
		# normally already exported; a first-sight glyph self-heals on the next real zone entry.)
		if not _ib_active and _static_saw_missing and _static_retry < STATIC_RETRY_MAX:
			_static_retry += 1
			_static_retry_pending = true
	if _static_zones.has(live_id):
		_static_zones[live_id].position = Vector3.ZERO
	Profiler.done("render.static")

	# LIVE DYNAMICS — creatures only, every step. The sole per-step render cost now.
	Profiler.begin("render.live")
	_rebuild_dynamics(cells)
	Profiler.done("render.live")

	# NEIGHBOURS — frozen per-zone subtrees, repositioned by transform (Step A).
	# Remembered neighbours are FROZEN per-zone subtrees: each built ONCE, then only
	# repositioned by a cheap transform when the live zone shifts. A crossing no longer
	# rebuilds every neighbour (that was the ~1.1s hitch) — it just moves them and
	# builds the one newly-remembered zone. (This was accidentally called TWICE, doubling the
	# neighbour build/free churn every snapshot — a prime suspect for the Metal buffer crash on
	# rapid transitions. One call.)
	Profiler.begin("render.remembered")
	_sync_neighbors(neighbors)
	Profiler.done("render.remembered")

	# Parasang-scale surface landmarks (giant Spindle / Red Rock) at their world offset.
	_rebuild_landmarks(data.get("zone", {}))

## Build one zone's STATIC geometry (walls + non-creature nonwalls + lights) into the
## current bank, cells shifted by `offset`. `skip_creatures` drops mobile actors —
## always true here; creatures render separately in _rebuild_dynamics. Inspector
## notes are gated by the `_noting` flag (true only for the live static build).
func _build_zone(cells: Array, offset: Vector2i, skip_creatures: bool, wall_types: Dictionary) -> void:
	var wall_cells := {}
	_group_wall_cells(cells, offset, wall_types, wall_cells)   # pass 1
	for cell in cells:                                         # pass 2
		_place_cell(cell, offset, wall_cells, skip_creatures)

## Pass 1 — group wall cells by TYPE (family + colours + background). Cheap: dict-building only,
## no geometry/GPU, so the incremental live build runs this whole pass up front.
func _group_wall_cells(cells: Array, offset: Vector2i, wall_types: Dictionary, wall_cells: Dictionary) -> void:
	for cell in cells:
		var cx := int(cell.get("x", 0)) + offset.x
		var cy := int(cell.get("y", 0)) + offset.y
		var widx := -1
		for obj in cell.get("objs", []):
			widx += 1
			# Only solid, sight-blocking walls become prisms. Non-occluding "walls"
			# (fences) fall through to the sprite path below.
			if not _is_prism(obj):
				continue
			_note(cx, cy, widx, "prism", WALL_H)
			var tile := _canon_wall_tile(String(obj.get("tile", "")))
			var main_c := _pick_color_string(obj)   # compound beats tilecolor (the shared rule)
			var detail_c := String(obj.get("detail", ""))
			# Gap-fill bg comes from the EFFECTIVE tile colour: TILECOLOR when
			# set, else ColorString — exactly how Qud seeds its render event.
			# (The old "never ColorString" rule held only because its counter-
			# examples all HAD a TileColor, which masks ColorString entirely —
			# the metal wall's '&c' vs its noisy ColorString '^R'. An object
			# with NO TileColor really is painted from ColorString, ^ and all:
			# the Jilted Lover's '&g^w' tan field.)
			var bg := _parse_bg(_bg_source(obj))
			var key := "%s|%s|%s|%s" % [tile, main_c, detail_c, bg]
			if not wall_types.has(key):
				wall_types[key] = {"cells": {}, "tile": tile, "main": main_c, "detail": detail_c, "bg": bg}
			# store the cell's REAL autotile variant, not just "occupied". The
			# variant encodes which neighbours are walls, which is exactly what
			# decides whether the roof draws a border on each edge.
			wall_types[key]["cells"][Vector2i(cx, cy)] = String(obj.get("tile", ""))
			# the VARIANT TILE, not just true: the floor pass asks whether this
			# wall's custom art hard-carves its bottom row (ground shows through)
			wall_cells[Vector2i(cx, cy)] = String(obj.get("tile", ""))

## Pass 2 for ONE cell — floors + verticals (skip walls). This is the heavy, GPU-touching part
## (texture recolour, sprites, floor-batch entries); the incremental build calls it in chunks.
func _place_cell(cell: Dictionary, offset: Vector2i, wall_cells: Dictionary, skip_creatures: bool) -> void:
	# 1:1 renders EVERYTHING per turn in the dynamic pass (like Qud renders per frame): a
	# frozen ghost bake went stale whenever a liquid sloshed or objects changed (the
	# "Qud shows a watervine, Raves shows water" bug — the bake predated the vine's cell
	# state). Statics contribute nothing in 1:1.
	if _one_to_one:
		return
	_zone_wall_cells = wall_cells   # doors orient by it; gearboxes ask what they back onto
	var cx := int(cell.get("x", 0)) + offset.x
	var cy := int(cell.get("y", 0)) + offset.y
	var in_wall: bool = wall_cells.has(Vector2i(cx, cy))
	# a wall whose custom art hard-carves its BOTTOM ROW shows the ground through
	# the openings (Daniel: "carve those out too") — its cell floor renders after
	# all, sitting under the wall volume like anywhere else
	var ground_show: bool = in_wall and _wall_bottom_open_at(Vector2i(cx, cy), wall_cells)
	var sink := _cell_sink(cell)
	var wet: bool = bool(cell.get("wade", false)) or bool(cell.get("swim", false))
	# A stair-down cell's own floor/ground quad would cap the shaft from above, so
	# it is suppressed (the frame lip provides the ring of floor around the opening).
	var stair_cell := _cell_has_stairs_down(cell)
	# Bake the cell's light into upright billboards. For the LIVE zone this is just an
	# initial value (the per-turn _relight_static_sprites keeps it fresh); for a FROZEN
	# neighbour it's the final value — that zone's plants stay dark in memory.
	var lf := _light_frac(cell)
	# Qud's render rule (Cell.Render, decompiled): a cell renders FULL colours only when
	# VISIBLE (line of sight — independent of light; the wire's `visible`, default true)
	# AND lit above None. Anything else that still draws (RenderIfDark objects) is
	# recoloured to the K/k GHOST — fg 'K', detail 'k' — Qud's "partially lit" look.
	if _one_to_one:
		lf = 1.0   # no per-sprite dim in 1:1 — the ghost recolour IS the memory look
	var ranks := _stack_ranks(cell)
	var idx := 0
	for obj in cell.get("objs", []):
		var o: Dictionary = obj
		if not _is_prism(o):
			var rk: Dictionary = ranks.get(idx, {})
			_place_nonwall(o, cx, cy, idx, in_wall, sink, wet, skip_creatures, stair_cell, lf,
				int(rk.get("rank", -1)), int(rk.get("below", 0)), ground_show)
		# Creature lights are placed in the DYNAMIC pass so they follow the creature;
		# here (static) we only place fixed lights (sconces, braziers, lit terrain).
		# A torch wearing its NOFIRE tile is Qud saying "unlit" — daytime
		# aboveground torches get NO rig at all: no fire, no smoke, no pool
		# (Daniel: "Torches aboveground should not have fire or smoke during
		# the day"). First-party: underground torches never wear nofire, and
		# campfires (onFire) always burn — you cook in the daytime.
		if o.has("lightRadius") and not (skip_creatures and _is_creature(o)) \
				and not String(o.get("tile", "")).contains("nofire"):
			_place_light(cx, cy, float(o["lightRadius"]), not _is_creature(o), bool(o.get("onFire", false)))
		idx += 1

# Small lift for the dynamic pass's full-colour floor quads so they cover the static ghost
# quads at the same cell (statics and dynamics share the layer-height scheme otherwise).
var _dyn_lift_1to1 := 0.0
var _plane_up: QuadMesh = null    # the standing (billboarded) overlay quad — user mode only
## Height of a standing overlay's CENTRE above the floor. A billboard's art occupies roughly the
## first world unit above its cell, so half of that puts the flash over the body rather than at
## the feet or above the head.
const OVERLAY_STAND_Y := 0.5

# --- 1:1 animation pass (Qud's per-frame render programs, emulated on wall clock) ---
# Rebuilt every dynamics pass; overlay nodes are children of _dynamic_root, so the
# rebuild's free() reclaims them — these arrays only hold references for the animator.
# Phases won't match Qud's frame counter (unsyncable), but duty cycles and periods do.
var _anim_items: Array = []        # [{kind:"smear"|"blink", node} | {kind:"cycle", nodes:[...]}]
var _anim_pool_cells: Array = []   # [{cx, cy, tile, key, y}] — sparkle candidates (liquid winners)
var _anim_target: Dictionary = {}  # {pos: Vector2i, color: letter} from the snapshot's target block
var _anim_tnode: MeshInstance3D = null   # the target-highlight bg quad (blinks)
var _sparkle_pool: Array = []      # reusable one-frame white-flash quads
var _sparkle_lit: Array = []       # sparkles shown this frame; hidden next tick
const DYN_LIFT_1TO1 := 0.02

## An object's K/k ghost variant — Qud's out-of-sight recolour (Cell.Render's final block:
## ColorString "&K", DetailColor "k" in tiles mode). Applied to EVERY drawn object in a
## non-visible/unlit 1:1 cell: walls, furniture, items, the painted ground alike.
func _ghost_obj(obj: Dictionary) -> Dictionary:
	var o: Dictionary = obj.duplicate()
	o["color"] = "&K"
	o["tilecolor"] = "&K"
	o["detail"] = "k"
	o.erase("fgHex")       # painted-colour overrides would beat the ghost in the recolour path
	o.erase("detailHex")
	return o

## Build the live zone's static geometry into its own frozen subtree (once per zone
## entry). Creatures are excluded — they render per step in _rebuild_dynamics.
##
## A big zone (the ~2000-cell world map, a full surface) creates a large batch of GPU resources
## — recoloured textures, sprites, floor MultiMeshes — and doing it all in ONE frame overran the
## Metal buffer allocator and hard-crashed (SIGBUS in memmove). So above IB_THRESHOLD cells we
## build INCREMENTALLY: pass 1 (cheap wall grouping) up front, then a chunk of cells per frame in
## _ib_step, flushing each chunk's floors as we go. Also removes the 1–3s transition freeze.
func _build_static(id: String, cells: Array) -> void:
	_cell_top_static.clear()   # sprites die with the old subtree; live cell coords collide across zones
	_door_static.clear()       # same story for the static door registry
	var sub := Node3D.new()
	_remembered_root.add_child(sub)
	_static_zones[id] = sub
	if INCREMENTAL_BUILD and cells.size() > IB_THRESHOLD:
		_ib_id = id
		_ib_sub = sub
		_ib_cells = cells
		_ib_idx = 0
		_ib_wall_types = {}
		_ib_wall_cells = {}
		_bank = sub
		_live_build = true
		_group_wall_cells(cells, Vector2i.ZERO, _ib_wall_types, _ib_wall_cells)  # pass 1 (no GPU)
		_bank = null
		_live_build = false
		_ib_active = true
		_ib_step()              # build the first chunk now, so the zone starts appearing at once
		return
	_bank = sub
	_live_build = true          # this zone's torches get the flicker (see _place_light)
	var wt := {}
	_build_zone(cells, Vector2i.ZERO, true, wt)
	_rebuild_walls(wt)
	_flush_floor_batch()        # emit this zone's floors as batched MultiMeshes
	_live_build = false
	_bank = null

# --- incremental live static build (spread a big zone across frames) --------
const INCREMENTAL_BUILD := true
const IB_THRESHOLD := 400   # cells; zones bigger than this build across frames, smaller in one
const IB_CHUNK := 100       # cells built per frame (kept small — the crash was a per-frame GPU
                            # resource spike and we don't know its exact threshold; ~20 frames for
                            # a 2000-cell zone is still well under a quarter-second)
var _ib_active := false
var _ib_id := ""
var _ib_sub: Node3D = null
var _ib_cells: Array = []
var _ib_idx := 0
var _ib_wall_types := {}
var _ib_wall_cells := {}

## Build the next chunk of the in-progress live static zone. Driven once per frame from _process.
## Each chunk places its cells and flushes its own floors, so the GPU work is spread out; walls
## (grouped in pass 1) are meshed once the last chunk lands.
func _ib_step() -> void:
	if not _ib_active:
		return
	_bank = _ib_sub
	_live_build = true
	_noting = true
	var end: int = min(_ib_idx + IB_CHUNK, _ib_cells.size())
	for i in range(_ib_idx, end):
		_place_cell(_ib_cells[i], Vector2i.ZERO, _ib_wall_cells, true)
	_ib_idx = end
	_flush_floor_batch()        # this chunk's floors -> their own MultiMeshes (spreads the spike)
	if _ib_idx >= _ib_cells.size():
		_rebuild_walls(_ib_wall_types)   # walls last; empty/cheap on the world map
		_ib_active = false
		_ib_cells = []                   # release the snapshot cells
	_bank = null
	_live_build = false
	_noting = false

## Finish the in-progress build synchronously (all remaining chunks now). Called before a genuine
## zone change so the departing zone's subtree is complete when it becomes a remembered neighbour.
func _ib_finish() -> void:
	while _ib_active:
		_ib_step()

## Abandon the in-progress build WITHOUT completing it — for when its subtree is about to be freed
## (_drop_static / _drop_all_static). Leaves no dangling _ib_sub for _process to build into.
func _ib_abort() -> void:
	_ib_active = false
	_ib_cells = []
	_ib_sub = null

## Re-place ONLY the live zone's creatures, every step, into _dynamic_root (cleared
## first). Few objects, so this is the cheap per-step cost that replaced the ~69ms
## full rebuild. Not noted (the inspector's _placed holds the static zone).
## Multi-frame STATIC billboards (millstone, water wheel). Deliberately NOT in
## _anim_items: that list is cleared by _rebuild_dynamics every turn because its nodes
## are _dynamic_root children, and a static sprite is not — registering there meant the
## millstone animated until the first turn and then stopped dead. Cleared with the other
## static registries when the zone rebuilds.
var _anim_sprites: Array = []

var _occupied := {}   # creature cells this turn (Vector2i -> true), for the winner rule

func _rebuild_dynamics(cells: Array) -> void:
	_occupied.clear()
	for c in _dynamic_root.get_children():
		c.free()
	_orbiters.clear()           # those orbiter roots were children of _dynamic_root (just freed)
	_anim_items.clear()         # animator registries: nodes were _dynamic_root children (freed above)
	_anim_pool_cells.clear()
	_anim_tnode = null
	_sparkle_pool.clear()
	_sparkle_lit.clear()
	_bank = _dynamic_root
	_noting = false
	_dyn_placed.clear()         # record this turn's creatures for the inspector
	_dyn_noting = true
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		# NO LONGER SKIPPED. The player's cell is placed like any other and tagged after the pass
		# (see the PLAYER_LAYER walk below), so a first-person camera can cull it while the other
		# six panes still show him.
		var sink := _cell_sink(cell)
		var wet: bool = bool(cell.get("wade", false)) or bool(cell.get("swim", false))
		var lf: float = _light_frac(cell)   # dim creatures in the dark (night or cavern)
		# 1:1 draws the WHOLE cell state fresh each turn (statics are empty in 1:1): an
		# unexplored cell draws nothing; a visible+lit cell draws every object full-colour;
		# anything else draws its RenderIfDark objects as the K/k ghost. No frozen bake, so
		# nothing to go stale when liquids slosh or objects change.
		if _one_to_one and not bool(cell.get("explored", true)):
			continue
		var full_1to1: bool = _one_to_one and bool(cell.get("visible", true)) and int(cell.get("light", 200)) > 1
		if _one_to_one:
			lf = 1.0   # no modulate dim in 1:1 — the ghost recolour is the whole memory look
		# On the world map the player's card must always read as "you are here" — drawn over
		# the terrain tiles, never buried behind a hill card. _place_nonwall picks that up.
		_placing_player = _world_map and Vector2i(cx, cy) == _player_cell
		if _one_to_one:
			# Qud renders ONE object per cell: among the eligible objects — all of
			# them when the cell is visible+lit, only the RenderIfDark ones otherwise — the
			# highest RenderLayer wins. TIES go to the EARLIER object in the cell's list:
			# classic Cell.Render compares with `>=` (last-wins), but the MODERN tile stage
			# we mirror draws first-wins — measured on the CaverCorpse spill (corpse idx 0 +
			# unexamined trinket idx 5, both layer 6: Qud shows the corpse; `>=` here showed
			# the trinket and the checker caught the divergence). The vine-over-deep-water
			# rule is unaffected — that's a strict layer difference, not a tie.
			var win: Dictionary = {}
			var win_layer := -INF
			for obj in cell.get("objs", []):
				var wd: Dictionary = obj
				if not full_1to1 and bool(wd.get("hideDark", false)):
					continue   # Qud never draws these out of sight (Render.RenderIfDark false)
				var lay := float(wd.get("layer", 0))
				if lay > win_layer:
					win = wd
					win_layer = lay
			if not win.is_empty():
				if not full_1to1:
					win = _ghost_obj(win)
				elif Vector2i(cx, cy) == _player_cell and String(win.get("tilecolor", "")) == "":
					# The avatar-colour gotcha (see the HUD portrait fix): the player's ColorString
					# '&y' is the GLYPH colour; Qud draws the player's TILE white main + data detail.
					win = win.duplicate()
					win["fgHex"] = "#ffffff"
				# 1:1's copy, hung off the cell WINNER because that is 1:1's model: one tile
				# per cell. User mode has no winner -- it places every object as its own
				# billboard -- so it registers per object further down instead.
				_register_anim(win, cx, cy)
				if full_1to1 and win.has("aquaBg"):
					# Qud's Swimming effect: an aquatic-limited creature (eel, glowfish) renders
					# over its supporting liquid's background colour, not the bare floor.
					# (NB: a '^bg' in the winner's own colour string does NOT fill the cell in
					# Qud's tile mode — measured on the luminous-salt puddle '&Y^y&C', whose
					# cell stays field-coloured behind the art. Only the Swimming bg fills.)
					_floor_batch_add(_color_material(_qud_color("&" + String(win["aquaBg"]))),
						Transform3D(Basis(), Vector3(cx, FLOOR_Y + 0.5 * LAYER_LIFT, cy)))
				_place_nonwall(win, cx, cy, 0, false, sink, wet, false, false, lf)
			continue
		var idx := 0
		var lit_here := false
		for obj in cell.get("objs", []):
			var od: Dictionary = obj
			# ON FIRE: any object in the cell, not just the creature and not just the top layer —
			# Qud flickers whatever is burning, whichever draws. Once per cell; two burning things
			# on one tile is one fire.
			#
			# THIS IS THE SECOND TIME THIS EXACT MISTAKE WAS MADE IN ONE SESSION, so it is worth
			# the ink: the natural-looking place for a per-cell check, up beside the winner
			# selection, is inside `if _one_to_one:`. That block is 1:1's whole model (one tile
			# per cell) and user mode never enters it. Code put there reads as running in both
			# modes and runs in neither. If a check belongs to user mode, it goes in THIS loop,
			# the one that actually places user mode's objects.
			if not lit_here and _is_burning(od):
				_place_burning(cx, cy)
				lit_here = true
			if not _is_prism(od) and _is_door(String(od.get("tile", ""))):
				# doors are stateful statics: hide the baked one, draw the
				# CURRENT state fresh (open art after a bump, closed after)
				for n in _door_static.get(Vector2i(cx, cy), []):
					if is_instance_valid(n):
						(n as Node3D).visible = false
				_place_nonwall(od, cx, cy, idx, false, sink, wet, false, false, lf)
				idx += 1
				continue
			if not _is_prism(od) and _is_creature(od):
				_occupied[Vector2i(cx, cy)] = true
				_place_nonwall(od, cx, cy, idx, false, sink, wet, false, false, lf)
				# QUD'S PER-FRAME RENDER PROGRAMS, IN USER MODE TOO. What a thing DOES is part
				# of what it IS: a burning creature flickers, a sleeping one is washed, a
				# wormhole re-rolls. All of it was gated to 1:1 -- and not by the `if full_1to1`
				# around the call, which was the obvious suspect and the wrong one. That call
				# sits inside the WINNER block, which is 1:1's whole model (one tile per cell)
				# and ends in a `continue` user mode never reaches. Removing the gate changed
				# nothing and the log proved it: zero registrations. The winner is also the
				# wrong hook here for a second reason -- user mode SKIPS hideDark objects when
				# picking one, and the dawnglider that exposed this is hideDark, so it could
				# never have been the winner however the gate was written.
				_register_anim(od, cx, cy)
				# A lit creature (NPC with a torch/glowsphere) carries its light with it —
				# placed here every step so it tracks the creature. No smoke: a moving torch
				# shouldn't trail a plume. (_live_build is false during dynamics, so this doesn't
				# register for the flicker or leak into _lights, freed only on a static rebuild.)
				# Glowfish are excluded: their glow will come from a shader on the fish texture,
				# not the sconce-style pool+flame; they get the orbiting motes instead.
				if od.has("lightRadius") and not _should_glow(od):
					_place_light(cx, cy, float(od["lightRadius"]), false)   # glow-critters use the bloom, not a pool
				if _is_glowfish(od):
					_make_orbiters(cx, cy)     # bioluminescent bugs circling the fish
			idx += 1
	# TAG BY POSITION, not by which children are new. Sprites come from a POOL, so the player's
	# billboard is usually an EXISTING child of _dynamic_root that got re-seated this turn --
	# a "children added since we started this cell" range misses exactly the node that matters,
	# which is how the player kept appearing in front of the first-person camera after the first
	# fix. Where a node IS cannot be faked by pooling.
	_tag_player_cell()
	_placing_player = false
	# Winner rule, dynamic half: a creature is its cell's face — the static winner under
	# it hides for the turn and pops back the turn the creature moves off. No rebuilds.
	for c in _cell_top_static:
		var sp: Sprite3D = _cell_top_static[c]
		if is_instance_valid(sp):
			sp.visible = not _occupied.has(c)
	# Target-highlight blink: a bg fill under the current combat target's cell, toggled by the
	# animator in Qud's ~250ms windows (Cell.RenderTarget; colour = disposition, from the wire).
	if _one_to_one and not _anim_target.is_empty():
		var tp: Vector2i = _anim_target["pos"]
		_anim_tnode = _overlay_quad(null, tp.x, tp.y, FLOOR_Y + 0.25 * LAYER_LIFT, false,
			_qud_color("&" + String(_anim_target["color"])))
	if _flat_2d:
		_flush_floor_batch()   # 2D: creatures went to floor quads this turn — emit them into _dynamic_root
	_dyn_noting = false
	_noting = true
	_bank = null
	# Per-cell darkness is driven by Qud's light map (also dark on the surface at night). But
	# a fully-lit zone — the world MAP (2000 tiles, all Light), or the daytime surface — has
	# nothing to darken or dim, and running the overlay/relight/light-map loops over 2000
	# cells EVERY step was the overworld's sluggishness. So first a cheap scan: is anything
	# dark? If not, skip it all (and un-dim once, in case we just came out of the dark).
	var any_dark := false
	for cell in cells:
		# ALSO the fog: a fully-lit zone still needs the pass if any cell is unexplored or out
		# of sight, or the fog would never be applied on a bright surface zone at midday.
		if int(cell.get("light", 200)) < 199 or not _cell_explored(cell) or not _cell_seen(cell):
			any_dark = true
			break
	# THE SURROUND IS NOT GATED ON any_dark, and that is not an oversight. any_dark asks whether
	# THIS zone has a dark, unexplored or unseen cell in it — a question about the zone you are
	# standing in, which says nothing about the world outside it. Gated, the never-visited ground
	# stopped being drawn the moment a zone happened to be wholly lit and wholly seen, and the bare
	# ground plane came back at full field colour. Daniel: "walking from 77,0 to 76,0, the
	# unexplored area changes colour from dark to Qud default colour ... and the opposite
	# direction" — one step either way across the threshold where the last unseen cell appears or
	# disappears. Outside the zone is always unvisited; it always needs its darkness.
	# The band starts at the edge ring's own tone, so that has to be measured before it is built —
	# and NOT inside _build_darkness, which is skipped entirely when the zone has nothing dark in it.
	_tally_edge_tone(cells, bool(Settings.get_value("lit_floor", false)))
	_build_unexplored(_dynamic_root)
	if any_dark:
		_build_darkness(cells, _dynamic_root)          # fall off to black around light sources
		if not _one_to_one:
			_relight_static_sprites(cells)             # dim trees/brinestalks/fences by cell light
	elif _was_dark:
		_reset_static_light()                          # dark -> lit: restore full brightness, once
	_was_dark = any_dark
	# The cutaway's lit test needs this map — but only if there are walls to fade (the world
	# map has none, so it's skipped there entirely).
	if not _wall_cutaway.is_empty():
		_cell_light.clear()
		for cell in cells:
			_cell_light[Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))] = _light_frac(cell)

## Dim the live zone's STATIC upright billboards (trees, brinestalks, scenery) by their
## cell's light this turn, so they fall dark at night with the ground instead of staying
## lit. Cheap — a modulate write per tracked sprite, no geometry rebuild. Mirrors the
## creature modulate; the flat darkness overlay can't cover a standing sprite.
func _relight_static_sprites(cells: Array) -> void:
	if _lit_sprites.is_empty() and _lit_meshes.is_empty() and _wall_cutaway.is_empty():
		return
	var lit := {}
	var tint := {}
	var seen := {}
	var known := {}
	for cell in cells:
		var k := Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
		lit[k] = _light_frac(cell)
		tint[k] = _view_tint(cell)
		seen[k] = _cell_seen(cell)
		known[k] = _cell_explored(cell)
	for e in _lit_sprites:
		var s = e["s"]
		if is_instance_valid(s):
			var k1: Vector2i = e["cell"]
			var vis: bool = bool(seen.get(k1, true))
			# HIDE VIA ALPHA, never via `visible`: the dynamic pass already toggles a static
			# winner's visibility under creatures, and two writers of one flag fight. Alpha 0
			# multiplies the texture to nothing and the alpha-scissor discards it.
			# NEVER SEEN, or a RenderIfDark object out of sight: not drawn at all, as Qud
			# does not draw either. Alpha, not `visible` — the winner rule owns that flag.
			if not bool(known.get(k1, true)) or (bool(e.get("hide_dark", false)) and not vis):
				s.modulate = Color(0, 0, 0, 0)
				continue
			# the SWAP is the memory; the modulate is only the cell's light
			var gt = e.get("ghost", null)
			var ghosted := false
			if gt != null:
				var want: Texture2D = (e["live"] if vis else gt)
				if s.texture != want:
					s.texture = want
				ghosted = not vis
			if ghosted:
				# THE GHOST TEXTURE IS THE WHOLE MEMORY LOOK — do not then dim it by the cell's
				# light. Qud's memory is a PALETTE SWAP and it does not follow the time of day
				# (docs/gotchas.md): what you remember is the thing, not how lit it was. The swap
				# above already redraws the tile in K/k, and multiplying THAT by the light of an
				# unlit cell drags a flat #155352 down toward black — so a remembered watervine
				# standing in shadow inside the live zone came out darker, and a different colour,
				# from the identical watervine one zone over, which is built in the same pair and
				# never dimmed. Daniel: "the shadowed watervine in my zone should be the same
				# colour as the watervine outside my zone -- that's the closest to the way Qud
				# shows watervine in darkness."
				#
				# Same rule the mesh branch below has always had via _view_tint, and the same one
				# _wall_cutaway follows by swapping a ghost MESH and never modulating it. This
				# path was the one that still multiplied.
				s.modulate = Color.WHITE
			else:
				var lf: float = float(lit.get(k1, 1.0))
				s.modulate = Color(lf, lf, lf) if lf < 0.999 else Color.WHITE
	for e in _lit_meshes:
		var mi = e["mi"]
		if is_instance_valid(mi) and mi.material_override != null:
			# Nothing else drives their visibility, so the flag is safe on these.
			mi.visible = bool(known.get(e["cell"], true))
			# A VERTEX-COLOURED SOLID GETS WHAT WALLS AND SPRITES GET: a ghost variant swapped in
			# whole, not a tint. "No texture to swap" -- which is what this comment used to say --
			# is true and was the wrong conclusion: the colour is in the MESH, exactly as a wall's
			# is, so _ghost_wall_mesh remaps it. The same argument that built that function applies
			# here, brown times MEMORY_TINT is a darker brown and never #155352, so a remembered
			# voxel object kept its own hue while the sprite beside it went flat teal. Daniel, on
			# the shadowed watervine: "this is probably an everything thing, not just watervine."
			# Cached on the instance, built once on first remembering -- the wall path's shape.
			var mvis: bool = bool(seen.get(e["cell"], true))
			var vc: bool = bool(mi.material_override.vertex_color_use_as_albedo)
			if vc and mi.mesh != null and not mvis:
				if not mi.has_meta("live_mesh"):
					mi.set_meta("live_mesh", mi.mesh)
				if not mi.has_meta("ghost_mesh"):
					mi.set_meta("ghost_mesh", _ghost_wall_mesh(mi.get_meta("live_mesh")))
				var gm: Mesh = mi.get_meta("ghost_mesh")
				if mi.mesh != gm:
					mi.mesh = gm
				mi.material_override.albedo_color = Color.WHITE   # the mesh IS the memory look
				continue
			if vc and mi.has_meta("live_mesh"):
				var lm: Mesh = mi.get_meta("live_mesh")
				if mi.mesh != lm:
					mi.mesh = lm                                  # back in sight: restore the art
			mi.material_override.albedo_color = tint.get(e["cell"], Color.WHITE)
	# VOXEL WALLS. They are in neither list: walls are built per cell straight into
	# _wall_cutaway, which is already the per-cell registry of EVERY mesh a wall owns — body,
	# seam fills and carve closures alike, all three creation sites call _track_wall — so reuse
	# it rather than keep a fourth. Untracked, walls were drawn at full colour whatever the
	# player knew: of 199 wall cells in Joppa only 15 were in sight, so 122 unexplored buildings
	# Qud draws NOTHING for, and 62 it ghosts, were all shown solid and brown. That is the
	# largest single reason more of the zone reads as visible here than in Qud.
	#
	# `visible` is safe on these (the winner rule governs static SPRITES, not walls) and the
	# camera cutaway writes `transparency`, a different channel.
	for k in _wall_cutaway:
		var kn: bool = bool(known.get(k, true))
		var wvis: bool = bool(seen.get(k, true))
		for wmi in _wall_cutaway[k]:
			if not is_instance_valid(wmi):
				continue
			wmi.visible = kn
			if not kn:
				continue
			# has_meta FIRST. `get_meta(name, null)` does NOT quietly return the default:
			# Godot treats a null default as "no default given" and pushes an error, so the
			# absent-on-first-visit case — which is EVERY wall, on its first relight — spat two
			# error lines per mesh per turn into raves.log. It still worked, which is why only
			# a FULL run caught it: the log was drowning while the render was fine.
			if not wmi.has_meta("live_mesh"):
				wmi.set_meta("live_mesh", wmi.mesh)
			var live_m: Mesh = wmi.get_meta("live_mesh")
			var want: Mesh = live_m
			if not wvis:
				if not wmi.has_meta("ghost_mesh"):
					wmi.set_meta("ghost_mesh", _ghost_wall_mesh(live_m))   # once, on first remembering
				want = wmi.get_meta("ghost_mesh")
			if wmi.mesh != want:
				wmi.mesh = want

## The remembered form of a wall mesh — Qud's memory is a PALETTE SWAP, and a vertex-coloured
## voxel wall cannot reach one by multiplying: brown times any tint is a darker brown, never
## #155352. So walls get what sprites get, a GHOST VARIANT swapped in whole (see _ghost_obj).
##
## Built by remapping the finished mesh's vertex colours onto Qud's 'K' while keeping each
## vertex's RELATIVE brightness, so the baked face shades (1.00 broad / 0.92 top / 0.72 rim /
## 0.50 underside) survive as relief instead of flattening to a teal silhouette. Qud's own ghost
## is two-tone, K over k, for the same reason: the structure still has to read.
func _ghost_wall_mesh(src: Mesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	var gc := _qud_color("K")
	for si in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(si)
		var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		if cols.is_empty():
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			continue
		var vmax := 0.0
		for c in cols:
			vmax = maxf(vmax, maxf(c.r, maxf(c.g, c.b)))
		if vmax <= 0.0:
			vmax = 1.0
		var ng := PackedColorArray()
		ng.resize(cols.size())
		for i in cols.size():
			var v: float = maxf(cols[i].r, maxf(cols[i].g, cols[i].b)) / vmax
			ng[i] = Color(gc.r * v, gc.g * v, gc.b * v, cols[i].a)
		arr[Mesh.ARRAY_COLOR] = ng
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out

## Restore full brightness to the tracked static sprites/meshes — called once when a zone
## goes from having dark cells to fully lit (e.g. dawn), since _relight is then skipped.
func _reset_static_light() -> void:
	for e in _lit_sprites:
		if is_instance_valid(e["s"]):
			e["s"].modulate = Color.WHITE
	for e in _lit_meshes:
		if is_instance_valid(e["mi"]) and e["mi"].material_override != null:
			e["mi"].material_override.albedo_color = Color.WHITE
	# Walls back to live art and shown. Safe to do unconditionally: this runs only when EVERY
	# cell is lit, explored and in sight (see the any_dark scan), which is exactly the state in
	# which no wall should be hidden or ghosted.
	for k in _wall_cutaway:
		for wmi in _wall_cutaway[k]:
			if not is_instance_valid(wmi):
				continue
			wmi.visible = true
			if not wmi.has_meta("live_mesh"):
				continue          # never ghosted, so its mesh is already the live one
			var live_m: Mesh = wmi.get_meta("live_mesh")
			if wmi.mesh != live_m:
				wmi.mesh = live_m

## Qud LightLevel byte (per cell) -> 0..1 brightness. None(1)/Blackout(0) -> 0 (dark);
## Light(200)+ -> 1 (full). The low senses (darkvision 10 .. safelight 30) map to a dim
## sliver, so an unlit cavern falls toward black — sources are the only real light.
func _light_frac(cell: Dictionary) -> float:
	var lv := int(cell.get("light", 200))   # default full: surface, or an older mod w/o the field
	return clampf(float(lv - 1) / 199.0, 0.0, 1.0)

## FOG OF WAR, in USER mode. Qud shows an unexplored cell as black and an explored-but-unseen
## one as a grey memory ghost; Raves drew both at full colour, which is why more of the zone was
## visible here than in Qud. All three gates for this existed already but sat inside `if
## _one_to_one:` blocks, because 1:1 redraws every cell each turn while user mode bakes statics.
## They fit user mode anyway: _relight_static_sprites already walks every tracked sprite each
## turn, so this is the same per-turn write and nothing goes stale.
##
## Qud's ghost is a flat dim TEAL (its K/k pair, #155352/#0f3b3a) regardless of an object's own
## colour. A neutral dim came out darker than Qud AND kept every hue, so it read wrong twice
## over. A modulate cannot desaturate, but a TINTED multiply can lean everything the same way:
## crush red, keep most of green and blue, and the result lands close to Qud's memory without
## costing more than the write already being made. Scaled by the cell's own light besides, so a
## dark unseen cell does not come out brighter than it is today.
const MEMORY_TINT := Color(0.32, 0.58, 0.55)

## NOT USED AS A GATE, deliberately. `c.IsExplored()` reports 356 of Joppa's 2000 cells
## unexplored, but Qud DRAWS terrain in that same region — so hiding on this flag blacks out
## bands Qud shows as memory, which is over-hiding rather than parity. Kept because the field is
## real and the discrepancy is worth chasing; the fog currently rests on `visible` alone.
func _cell_explored(cell: Dictionary) -> bool:
	return bool(cell.get("explored", true))

## Currently in the player's sight AND lit. Mirrors 1:1's `full_1to1` exactly.
func _cell_seen(cell: Dictionary) -> bool:
	# the mod omits `visible` when it is TRUE, so an absent key means seen — never read it as false
	return bool(cell.get("visible", true)) and int(cell.get("light", 200)) > 1

## The same decision as a COLOUR, for anything that takes a modulate: out of sight leans teal.
func _view_tint(cell: Dictionary) -> Color:
	if not _cell_seen(cell):
		# FLAT — memory does not dim with the cell's current light. You remember the room; the
		# room is not dark in your head. Seen cells still take the light, because you really
		# cannot see into an unlit cell you are looking at.
		return MEMORY_TINT
	var f := _light_frac(cell)
	return Color(f, f, f)

## Per-cell darkness overlay (cavern lighting). ONE vertex-coloured MIX-black mesh: a quad
## over each cell's floor (and its roof, for wall cells) whose ALPHA is how DARK the cell is
## (1 - light). Built into _dynamic_root each turn, so it tracks Qud's live light map as
## sources/player move. Cheap — one mesh, and fully-lit cells contribute nothing. The
## additive torch/glow geometry draws bright on top, so lit pools read against the black.
## `parent` is where the one darkness mesh lands: _dynamic_root for the live zone (rebuilt
## each turn, tracks moving light) or a neighbour's frozen subtree (baked once from that
## zone's remembered light, so remembered zones darken to match instead of staying lit).
##
## THERE IS NO SIGHT-DISC CLEAR. A zone the player had left used to force f = 0.0 for every cell
## within FROZEN_LIGHT_CLEAR_R = 7 of the departure point, meaning to erase the bright pool Qud
## lights around the player — which would otherwise hang in a departed zone as a cropped light.
## But f = 0.0 is not "no light", it is FULL DARKNESS (alpha 0.94 of black), so it erased that
## hanging light by punching a hole in the exact shape of it. Daniel: "when you leave a zone,
## there is a negative light cone where you had a positive light cone." 6.3% of the playfield
## near-black across one crossing; 0.0% once removed.
##
## DO NOT re-solve the leftover bright pool with an `if frozen: f = minf(f, MEMORY_GROUND)` here.
## It is the obvious next move and it CRASHES: every neighbour zone then carries a full sheet of
## alpha-blended quads, and zooming out with several on screen dies in _platform_memmove, 3 runs
## of 3. Run-length merging the quads does not help — it cuts vertices, not blended fill — which
## is the tell that this is the overdraw failure mode in CLAUDE.md. A frozen zone's memory look
## has to be baked into its OWN geometry, the way walls get _ghost_wall_mesh, not laid over it.
## `frozen_off`: for a zone the player has LEFT, its cell offset from the live zone. Turns on the
## distance ramp (see FROZEN_EDGE_DIM). Left at the sentinel for the live zone, which has no
## boundary to fade from.
const NOT_FROZEN := Vector2i(-99999, -99999)
func _build_darkness(cells: Array, parent: Node, frozen_off := NOT_FROZEN) -> void:
	var frozen: bool = frozen_off != NOT_FROZEN
	penumbra_radius = maxi(1, int(Settings.get_value("penumbra_radius", penumbra_radius)))
	penumbra_divisions = clampi(int(Settings.get_value("penumbra_divisions", penumbra_divisions)), 1, 16)
	var lit_floor: bool = bool(Settings.get_value("lit_floor", false))
	# A ZONE WHOLLY PAST THE RAMP IS ONE RECTANGLE. Every cell in it is fully opaque, so the 2000
	# per-cell quads (or, at divisions=16, the 512,000 sub-quads) all carry the same black. Emitting
	# them was most of what made a zone crossing hitch: every neighbour re-bakes when its offset
	# changes, i.e. on every crossing, and a 21-zone walk was rebuilding 10.7 MILLION quads for one
	# step — profiler render.remembered max 18,759ms. Daniel: "the zones are taking longer and
	# longer to load when you transition." One quad carries the identical picture.
	if frozen and not _one_to_one and _zone_beyond_ramp(frozen_off):
		var sfar := SurfaceTool.new()
		sfar.begin(Mesh.PRIMITIVE_TRIANGLES)
		_dark_rect(sfar, 0, 0, int(_live_w), int(_live_h), DARK_SOLID_Y)
		var mfar := MeshInstance3D.new()
		mfar.mesh = sfar.commit()
		mfar.material_override = _dark_solid_material()
		mfar.set_meta("is_darkness", true)
		parent.add_child(mfar)
		return
	# PASS 1 — TWO INDEPENDENT ANSWERS PER CELL, never one value they have to fight over.
	#
	# THE RESTRUCTURE THIS BLOCK EXISTS TO REMEMBER. Each cell is asked two questions that have
	# nothing to do with each other:
	#
	#   TONE — what the cell IS. Never seen / remembered / in sight. A fact about the player's
	#          KNOWLEDGE, uniform across the tile.
	#   VEIL — how far past the edge of the visible the cell SITS. A DISTANCE to a boundary, so it
	#          varies across the tile, which is what earns the subdivision.
	#
	# They used to be folded into one light fraction `f` by a mix of `minf` and plain assignment,
	# so every new case had to guess which of the two won — and it guessed wrong FOUR times in one
	# session (the penumbra swamped by dusk, a departed zone keeping live art, the live map
	# rendering black, a remembered pool still blue). Each was the same shape: a value meant to
	# GUARANTEE something, wired as an alternative or a floor, so it never applied. Kept apart they
	# compose by one rule with no special cases at all:
	#
	#     alpha = max(TONE, VEIL) * amax          neither one can LIGHTEN the other
	#
	# and that single max reproduces every branch the old if-chain spelled out by hand. Before
	# adding a case here, ask which of the two questions it answers; if it seems to answer both,
	# it is two cases.
	var tone := {}          # k -> darkness alpha from what the cell IS
	var veil := {}          # k -> darkness alpha from how far past the edge it sits (0 = none)
	var dark := {}          # k -> the composed max(tone, veil), pre-amax
	var veil_kind := {}     # k -> 1 frozen ramp, 2 live edge fade; absent = flat, no resampling
	var wash := {}          # k -> paint the FIELD colour under the darkness (see REMEMBER_COVER)
	var walls := {}
	for cell in cells:
		var k := Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
		# --- TONE: what the cell IS --- (see _live_cell_tone; the surround band reads it too)
		var t: float
		if not _cell_explored(cell):
			t = 1.0 - FOG_GROUND      # NEVER SEEN — see FOG_GROUND; NOT black, Qud has no black
		elif not frozen:
			# The live zone's rule lives in _live_cell_tone, because the SURROUND BAND has to start
			# at exactly this value and a second copy of it would drift. Only the wash bookkeeping
			# stays here — that is pass 1's own, not part of the tone.
			t = _live_cell_tone(cell, lit_floor)
			if not _cell_seen(cell) and not lit_floor:
				wash[k] = true
		else:
			# REMEMBERED — a DEPARTED zone, every explored cell of it. (The live zone's own
			# out-of-sight cells take the same value, one branch up, inside _live_cell_tone.)
			# Qud's memory of a place is a PALETTE SWAP, not a dim, so it does not follow the time
			# of day (docs/gotchas.md): what you remember is the map, not how lit it was. Hence a
			# flat MEMORY_GROUND rather than the cell's stored light, because you left, so nothing
			# in it is in sight now whatever it was when you walked out.
			#
			# Reading the stored light here is the "shadow overwriting the penumbra" bug: at dusk a
			# departed zone's cells report light=1, i.e. 0.94 of black, which swamps an 0.18 ramp and
			# takes the boundary straight to black. As a FLOOR it fails the other way — an explored
			# cell you cannot see is usually unlit, so minf(0, MEMORY_GROUND) is 0 and 1836 of a
			# zone's 2000 cells render as though never seen. It is neither; it is the answer.
			# ...but never brighter than the zone the player is actually in (see DEPARTED_CAP_ON).
			t = maxf(1.0 - MEMORY_GROUND, _departed_cap())
			wash[k] = true
		# --- VEIL: how far past the edge of the visible it sits ---
		var v := 0.0
		if not ZONE_RAMPS_ON:
			pass                                 # both old ramps are off; a zone renders flat
		elif frozen:
			v = 1.0 - _frozen_light(k, frozen_off)   # ramp from the shared boundary, FROZEN_EDGE_DIM
		elif not _cell_seen(cell):
			# THE LIVE ZONE'S EDGE FADE ONLY DIMS WHAT YOU CANNOT SEE. It blends the zone into the
			# dark beyond it, and that is an OUT-OF-SIGHT effect: applied to cells in line of sight it
			# dims the ground you are standing on, and at the zone's edge it dims YOU. Daniel: "my
			# character seems to be in discovered fog-of-war", reported from (0,24), where it is
			# deepest. Gating on _cell_seen also makes the seam self-correcting — the fade retreats
			# ahead of your line of sight, which is what a fade into the unknown should do anyway.
			v = 1.0 - _live_edge_light(k)
		# SUBDIVIDE ONLY WHERE THE VEIL CAN ACTUALLY WIN. A cell whose tone is the darker answer
		# everywhere inside it renders as one flat step whatever the division count, so cutting it
		# into D x D identical sub-quads buys nothing and costs real fill: the live zone's band is
		# ~600 cells, ~450 of them tone-dominated, which at 16 divisions is ~115k quads for zero
		# visual difference — squarely the overdraw failure mode in CLAUDE.md. `v` is sampled at the
		# cell centre and the ramp keeps climbing across the tile, so allow one tile's worth of rise
		# before ruling the veil out, or the cell where the two cross would step instead of ramp.
		if v > 0.0 and v + _veil_step(frozen) >= t:
			veil_kind[k] = 1 if frozen else 2
		tone[k] = t
		veil[k] = v
		dark[k] = maxf(t, v)
		# A wall the player has never seen is HIDDEN now (see _relight_static_sprites), so it must
		# not be treated as a wall here either: its darkness would be a roof quad at WALL_H and a
		# ring of side faces, left hanging in the air over nothing. Unexplored wall cells fall
		# through to the open-cell branch and darken the ground, which is what you can actually see.
		if not _cell_explored(cell):
			continue
		for obj in cell.get("objs", []):
			if _is_prism(obj):
				walls[k] = true
				break
	# pass 2: emit dark quads. An OPEN cell darkens its floor by its own light. A WALL
	# cell darkens its roof (own light) and each EXPOSED vertical face — a face by the
	# light of the OPEN cell it faces, since that's what would light it. So rock beside a
	# torch stays lit while rock in the dark goes black. Interior faces (wall-to-wall) and
	# fully-lit cells emit nothing.
	var sides := [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# TWO meshes, split by alpha. Anything at DARK_SOLID_A or above goes in the OPAQUE one: at full
	# darkness there is nothing to blend, and this is what keeps the frozen ramp affordable — the
	# blended half stays a FROZEN_DARK_IN-deep band along the shared edge however big the zone is.
	# A full sheet of blended quads per neighbour is the thing that crashed (see the note above).
	var sto := SurfaceTool.new()
	sto.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var any_solid := false
	# A departed zone is allowed to reach FULL black; the live zone keeps DARK_MAX's faint floor
	# ("never pure black"), which is what makes its unlit corners read as gloom rather than a hole.
	var amax: float = 1.0 if frozen else DARK_MAX
	# 1:1: Qud's model needs no overlay — the K/k ghost recolour at place time is the
	# whole memory look (see _ghost_obj); unexplored cells draw nothing at all.
	if _one_to_one:
		return   # 1:1 uses NO overlay at all: unexplored cells draw nothing, and every
		         # non-visible/unlit cell's objects are K/k ghost-RECOLOURED at place time
		         # (Cell.Render's model — the ghost is a palette swap, not a black film).
	for cell in cells:
		var k := Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
		var cx := float(k.x)
		var cy := float(k.y)
		if walls.has(k):
			var a := float(dark[k]) * amax
			if a >= DARK_SOLID_A:
				_dark_quad(sto, cx, cy, DARK_SOLID_Y, 1.0); any_solid = true
			elif a >= 0.02:
				_dark_quad(st, cx, cy, DARK_ROOF_Y, a); any = true
			for d in sides:
				if walls.has(k + d):
					continue                       # interior face: not visible
				var sa := float(dark.get(k + d, dark[k])) * amax
				if sa >= DARK_SOLID_A:
					_dark_side(sto, cx, cy, d, 1.0); any_solid = true
				elif sa >= 0.02:
					_dark_side(st, cx, cy, d, sa); any = true
		else:
			# BOTH ANSWERS APPLY, AND IN THIS ORDER. The wash says what the cell IS and goes down
			# first; the darkness says how dark it ends up and lies over it. The wash was once an
			# `elif` under the fade branch, so a remembered cell that ALSO sat in the edge band got
			# the fade INSTEAD — thin black over the real floor, which is how a remembered pool one
			# tile from the boundary still rendered bright blue (cell 34,1: explored, not visible,
			# inside the band). Two questions, two layers.
			if wash.has(k):
				_dark_quad_col(st, cx, cy, DARK_FLOOR_Y - 0.005,
					Color(_world_bg.r, _world_bg.g, _world_bg.b, REMEMBER_COVER))
				any = true
			var a := float(dark[k]) * amax
			if penumbra_divisions > 1 and veil_kind.has(k):
				# SUBDIVIDE ONLY A CELL THAT IS ACTUALLY A GRADIENT. Part of this cell's darkness is
				# a DISTANCE, so it CAN be resampled inside the tile — but "can" is not "must", and
				# assuming it must was costing whole seconds per zone crossing. Beyond the ramp a
				# frozen zone is uniformly opaque, so all D x D samples come back identical and get
				# emitted as identical stacked quads: at divisions=16 that is 256 quads per cell,
				# 512,000 per zone, and every neighbour is re-baked on every crossing because its
				# offset changed. 21 zones deep into a walk that was 10.7 MILLION quads for one step
				# — profiler render.remembered avg 557ms, max 18,759ms. Daniel: "the zones are taking
				# longer and longer to load when you transition."
				#
				# The ramp is monotone in distance to a rectangle, so the cell's CORNERS bracket
				# every sample inside it. If that bracket is already opaque, or flat to within what
				# an 8-bit alpha can even represent, one quad carries the same picture.
				var b := _veil_bounds(k, int(veil_kind[k]), frozen_off)
				var t_k := float(tone[k])
				var a_lo: float = maxf(t_k, b.x) * amax
				var a_hi: float = maxf(t_k, b.y) * amax
				if a_lo >= DARK_SOLID_A:
					_dark_quad(sto, cx, cy, DARK_SOLID_Y, 1.0); any_solid = true   # uniformly opaque
				elif a_hi - a_lo <= FLAT_ALPHA:
					if a_hi >= 0.02:
						_dark_quad(st, cx, cy, DARK_FLOOR_Y, a_hi); any = true     # uniform, one step
				else:
					# a real gradient: the tone rides along as a floor, so a sub-quad is never
					# lighter than what the cell IS — the same max, evaluated per sample.
					var res: Array = _emit_fade_cell(st, sto, k, int(veil_kind[k]), frozen_off, amax,
						t_k)
					any = any or bool(res[0])
					any_solid = any_solid or bool(res[1])
			elif a >= DARK_SOLID_A:
				_dark_quad(sto, cx, cy, DARK_SOLID_Y, 1.0); any_solid = true
			elif a >= 0.02:
				_dark_quad(st, cx, cy, DARK_FLOOR_Y, a); any = true
	if any:
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = _dark_material()
		mi.set_meta("is_darkness", true)      # so a re-bake can find and drop it
		parent.add_child(mi)
	if any_solid:
		var mo := MeshInstance3D.new()
		mo.mesh = sto.commit()
		mo.material_override = _dark_solid_material()
		mo.set_meta("is_darkness", true)
		parent.add_child(mo)

## The distance ramp for a departed zone: how LIT a cell is allowed to stay, by how far past the
## live zone's boundary it sits. Chebyshev distance to the live rect, so the row butted against it
## is 1 and a diagonal neighbour fades from its corner the same way an edge one fades from its edge.
## Returns a light fraction (1 = untouched), so the caller can min() it against the cell's own.
## The ramp at a FLOAT world position — the sub-tile form of _frozen_light, for sampling inside a
## cell when divisions > 1. Distance is measured to the live rect's OUTER edge (-0.5 / +size-0.5)
## How much the veil ramp rises across ONE tile — the margin for the subdivision gate above.
## Mirrors the two ramps exactly: _frozen_light spreads (1 - FROZEN_EDGE_DIM) over penumbra_radius
## Is this whole zone past the end of the distance ramp, at the given offset?
##
## Minimum Chebyshev distance from ANY of its cells to the live rect. The ramp saturates at
## penumbra_radius, so past that every cell is fully opaque and the zone is one flat black
## rectangle — no gradient anywhere in it, and nothing about that depends on WHICH direction or
## how far away it sits. Both facts are load-bearing: it collapses to one quad, and it never needs
## re-baking when the player moves (see _sync_neighbors).
func _zone_beyond_ramp(off: Vector2i) -> bool:
	var zw := int(_live_w)
	var zh := int(_live_h)
	var dx := 0
	if off.x + zw - 1 < 0:
		dx = -(off.x + zw - 1)          # entirely west: nearest cell is its east column
	elif off.x > zw - 1:
		dx = off.x - (zw - 1)           # entirely east: nearest is its west column
	var dy := 0
	if off.y + zh - 1 < 0:
		dy = -(off.y + zh - 1)
	elif off.y > zh - 1:
		dy = off.y - (zh - 1)
	return maxi(dx, dy) >= penumbra_radius + 1

## tiles, _live_edge_light spreads FROZEN_EDGE_DIM over penumbra_radius + 1.
func _veil_step(frozen: bool) -> float:
	if frozen:
		return (1.0 - FROZEN_EDGE_DIM) / float(maxi(1, penumbra_radius))
	return FROZEN_EDGE_DIM / float(maxi(1, penumbra_radius + 1))

## so a position half a tile past the boundary reads as half a tile, not a whole one.
func _frozen_light_at(wx: float, wy: float) -> float:
	var dx: float = maxf(0.0, maxf(-0.5 - wx, wx - (_live_w - 0.5)))
	var dy: float = maxf(0.0, maxf(-0.5 - wy, wy - (_live_h - 0.5)))
	var d: float = maxf(dx, dy)
	if d <= 0.0:
		return 1.0
	var t: float = clampf(d / float(maxi(1, penumbra_radius)), 0.0, 1.0)
	return 1.0 - lerpf(FROZEN_EDGE_DIM, 1.0, t)

func _frozen_light(k: Vector2i, off: Vector2i) -> float:
	var wx: int = k.x + off.x
	var wy: int = k.y + off.y
	var dx: int = maxi(0, maxi(-wx, wx - int(_live_w - 1.0)))
	var dy: int = maxi(0, maxi(-wy, wy - int(_live_h - 1.0)))
	var d: int = maxi(dx, dy)
	if d <= 0:
		return 1.0                                  # inside the live rect: not ours to dim
	# d = 1 is the edge row -> a little dim; d = FROZEN_DARK_IN -> fully dark.
	var t: float = clampf(float(d - 1) / float(maxi(1, penumbra_radius)), 0.0, 1.0)
	var a: float = lerpf(FROZEN_EDGE_DIM, 1.0, t)   # alpha
	return 1.0 - a                                  # ...as a light fraction


## THE LIVE ZONE'S TONE RULE, alone, so the surround band can start its ramp at exactly the
## darkness of the cell it abuts. Pass 1 calls this; so does _tally_edge_tone. Two copies of it
## drifting apart is precisely how the old bib came to meet the zone at a different brightness.
func _live_cell_tone(cell: Dictionary, lit_floor: bool) -> float:
	if not _cell_explored(cell):
		return 1.0 - FOG_GROUND
	if not _cell_seen(cell):
		return 0.0 if lit_floor else 1.0 - MEMORY_GROUND
	return 1.0 - _light_frac(cell)

## Is (cx,cy) on the live zone's OUTERMOST ring? Those are the only cells the band ever repeats:
## a surround cell clamps to the nearest cell inside the rect, and every clamp lands on the ring.
func _on_edge_ring(cx: int, cy: int) -> bool:
	var w := int(_live_w)
	var h := int(_live_h)
	if cx < 0 or cy < 0 or cx >= w or cy >= h:
		return false
	return cx == 0 or cy == 0 or cx == w - 1 or cy == h - 1

## Remember the edge ring's tone for this turn. Cheap — the ring, not the zone.
func _tally_edge_tone(cells: Array, lit_floor: bool) -> void:
	_edge_tone.clear()
	var all_tones: Array = []
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var t: float = _live_cell_tone(cell, lit_floor)
		all_tones.append(t)
		if _on_edge_ring(cx, cy):
			_edge_tone[Vector2i(cx, cy)] = t
	# ...and the ambient, from the same pass. Over EVERY cell rather than the ring: the ring is 206
	# cells and a lit stretch along one edge can carry it, while the zone's own median cannot be
	# moved by anything short of the whole zone changing, which is exactly when the cap should move.
	if all_tones.is_empty():
		_ambient_tone = 0.0
	else:
		all_tones.sort()
		_ambient_tone = float(all_tones[all_tones.size() / 2])
	_live_lum = _modal_ground_luminance(cells)

## The live zone's ground LUMINANCE — the modal painted-ground colour, as one number.
##
## An earlier version of this tally was used as a COLOUR, to paint the ground outside the zone, and
## it was measurably wrong: what renders is the tile ART tinted by the colour string, and the art's
## own luminance moves the result (reds came out 2.4x high). As a LUMINANCE RATIO against another
## colour derived the same way it is far more forgiving — both sides carry the same bias and it
## divides out, which is the only thing it is asked for here.
##
## Modal rather than mean: a zone is one terrain with a few oddities in it, and averaging a green
## field with a red splash gives a colour that is in neither.
func _modal_ground_luminance(cells: Array) -> float:
	var tally := {}
	for cell in cells:
		for obj in cell.get("objs", []):
			if float(obj.get("layer", 99)) > 0.5:
				continue                       # ground sits at layer 0
			var cs := String(obj.get("color", ""))
			if cs != "":
				tally[cs] = int(tally.get(cs, 0)) + 1
	var best := ""
	var best_n := 0
	for k in tally:
		if int(tally[k]) > best_n:
			best_n = int(tally[k])
			best = String(k)
	if best == "":
		return 0.0
	return _luminance(_qud_color(best))

## Rec.709 luminance. The scalar the cap compares brightnesses with, because "brighter" is one
## question and three channels cannot answer it — and a per-channel cap would tint the memory.
func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## The ceiling on a departed zone's darkness, as a frozen-pass TONE. Scaled by DARK_MAX because the
## live zone renders its tone at amax = DARK_MAX while a frozen zone renders at amax = 1.0 — the cap
## has to match what the live zone LOOKS like, not the number it stores.
func _departed_cap() -> float:
	if not DEPARTED_CAP_ON:
		return 0.0
	# MEMORY DIMS WITH THE WORLD, by composition rather than by estimation.
	#
	# The obvious form of this — work out what each side RENDERS as and solve for the alpha that
	# equalises them — needs the live ground's luminance, and that cannot be got from the wire. The
	# modal colour string overstates it badly, because what renders is dark line-work tinted by that
	# string and mostly not covered by it: predicted 0.2578 against an actual 0.0789, a 3.3x bias.
	# Worse, the bias does NOT divide out against the memory side (1.5x there), because the memory
	# recolour lerps toward k by the ART's own luminance. That is the same wall the bib hit and the
	# same lesson: stop computing the colour.
	#
	# So compose instead. Memory keeps its own brightness — MEMORY_GROUND, Qud's palette swap — and
	# then takes the live zone's ambient darkening on top, multiplicatively. It needs no knowledge
	# of either side's art, it is exact in the only place that matters (at full darkness the world
	# goes black and memory goes with it), and it is monotone: the darker where you stand, the
	# darker what you remember. What it is NOT is a proven ceiling — see DEPARTED_CAP_ON.
	var amb: float = clampf(_ambient_tone * DARK_MAX, 0.0, 1.0)
	return clampf(1.0 - MEMORY_GROUND * (1.0 - amb), 0.0, 1.0)

## The cap quantised for the re-bake guard — see CAP_QUANT.
func _departed_cap_step() -> int:
	return int(round(_departed_cap() * CAP_QUANT))

## The live cell a surround cell extends: the nearest one inside the rect. Clamping BOTH axes is
## what makes the corners work — a cell off the north-west corner clamps to (0,0) and repeats that
## one cell's ground, which is the only honest answer when there is no data in either direction.
func _band_src(wx: int, wy: int) -> Vector2i:
	return Vector2i(clampi(wx, 0, int(_live_w) - 1), clampi(wy, 0, int(_live_h) - 1))

## How far outside the live rect, in tiles. 0 inside; 1 is the first surround row. Chebyshev, so
## the band is a rectangular ring and a corner is as deep as the sides that meet there.
func _band_depth(wx: int, wy: int) -> int:
	var dx: int = maxi(0, maxi(-wx, wx - (int(_live_w) - 1)))
	var dy: int = maxi(0, maxi(-wy, wy - (int(_live_h) - 1)))
	return maxi(dx, dy)

## The band's darkness at depth d over a source cell of tone `t0`: starts AT that cell's own tone
## and reaches full dark at penumbra_radius + 1. d = 1 returns t0 exactly, which is the whole
## point — the first surround row is the edge cell's brightness, over the edge cell's own art.
func _band_alpha(d: int, t0: float) -> float:
	var f: float = clampf(float(d - 1) / float(maxi(1, penumbra_radius)), 0.0, 1.0)
	return clampf(lerpf(t0, 1.0, f), 0.0, 1.0)

## A solid rect with a hole cut for the ramp band: the parts of [x,y,w,h) that fall OUTSIDE the
## rect [ex0,ey0)-(ex1,ey1). Up to four pieces — left, right, then the top and bottom of what is
## left in between. Keeps the gradient visible instead of burying it under an opaque slab.
func _dark_rect_minus(st: SurfaceTool, x: int, y: int, w: int, h: int,
		ex0: int, ey0: int, ex1: int, ey1: int, yy: float) -> void:
	var x1 := x + w
	var y1 := y + h
	if x >= ex1 or x1 <= ex0 or y >= ey1 or y1 <= ey0:
		_dark_rect(st, x, y, w, h, yy)          # no overlap at all
		return
	var mx0: int = maxi(x, ex0)
	var mx1: int = mini(x1, ex1)
	_dark_rect(st, x, y, mx0 - x, h, yy)                    # left of the band
	_dark_rect(st, mx1, y, x1 - mx1, h, yy)                 # right of it
	var my0: int = maxi(y, ey0)
	var my1: int = mini(y1, ey1)
	_dark_rect(st, mx0, y, mx1 - mx0, my0 - y, yy)          # above, within the x-overlap
	_dark_rect(st, mx0, my1, mx1 - mx0, y1 - my1, yy)       # and below

## The edge cell whose ground the band should repeat at `src` — `src` itself when it has one, else
## the nearest cell ALONG THE SAME EDGE that does.
##
## Not every ring cell has a ground quad to lend: a cell under a wall skips its floor, so does a
## stair cell, and some hold no ground object at all. Measured on Joppa at 80x25, 25 of the ring's
## 206 cells came up empty. Without this the band over those 25 draws its ramp on nothing and the
## bare field plane shows through — which is the exact failure the whole rebuild is meant to end,
## just narrowed from the whole boundary to a quarter of it. Walking the edge (rather than giving
## up, or reaching into the zone's interior) keeps the substitute a cell the boundary actually runs
## through, so it is the same terrain the gap is in.
func _edge_floor_for(src: Vector2i) -> Array:
	if _edge_floor.has(src):
		return _edge_floor[src]
	var w := int(_live_w)
	var h := int(_live_h)
	var along_x: bool = src.y == 0 or src.y == h - 1
	var lim: int = maxi(w, h)
	for step in range(1, lim):
		for sgn in [-1, 1]:
			var c: Vector2i = Vector2i(src.x + step * sgn, src.y) if along_x \
				else Vector2i(src.x, src.y + step * sgn)
			if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
				continue
			if _edge_floor.has(c):
				return _edge_floor[c]
	return []

## THE WORLD YOU HAVE NEVER BEEN TO — and the band that hands the live zone over to it.
##
## Everything outside the zones you have visited is otherwise the ground plane at full field
## colour, a bright expanse running to the horizon: the one part of the view that does not answer
## to the fog. Daniel: "change the unexplored zones to be the same dark colour as unexplored tiles
## ... but don't expose any of the unexplored zone's assets." Nothing here draws a zone — the
## unexplored ones are not loaded and this does not load them.
##
## THE BAND EXTENDS THE EDGE CELLS' OWN GROUND QUADS OUTWARD, which is the rebuild of the "bib"
## after the first design was removed. The old one painted a black ramp over whatever happened to
## be underneath — the bare field plane out here, painted-ground tile art inside the zone. Two
## different bases under one alpha, so the row that was supposed to match the zone's edge came out
## 1.8/1.45/1.48 brighter, a different factor per channel, and no amount of tuning the alpha could
## reconcile it (see ZONE_RAMPS_ON for the measurements).
##
## So the band stops computing a colour. Each surround cell clamps to the nearest cell inside the
## rect and repeats THAT cell's finished floor material (_edge_floor, captured where the quad is
## batched) at its own position, then darkens from THAT cell's tone (_edge_tone). Both halves of
## the match are by construction and both are per-cell, so the hand-over holds where the edge runs
## from sand into water, and at every hour, without a constant anywhere in it. Repeating a material
## costs a MultiMesh transform, not a texture.
##
## Beyond the band it is solid and opaque (see DARK_SOLID_A) — a handful of big rects with the
## band's footprint cut out of them. A loaded neighbour draws its own zone AND its own darkness, so
## its slot is skipped entirely: where there is real data, show real data.
func _build_unexplored(parent: Node) -> void:
	if _one_to_one or _world_map:
		return
	var zw := int(_live_w)
	var zh := int(_live_h)
	# Grid slots something visited already covers: the live zone at (0,0), plus each neighbour.
	var taken := {Vector2i(0, 0): true}
	for id in _static_zones:
		var zn: Node3D = _static_zones[id]
		if zn.has_meta("dark_off"):
			var o: Vector2i = zn.get_meta("dark_off")
			taken[Vector2i(int(round(float(o.x) / float(zw))), int(round(float(o.y) / float(zh))))] = true
	var st := SurfaceTool.new()          # the band: blended
	var sto := SurfaceTool.new()         # everything at full darkness: opaque
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	sto.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_blend := false
	var any_solid := false
	var n_band := 0
	var n_ground := 0
	var n_skipped_taken := 0
	var n_borrowed := 0
	var n_bare := 0
	# --- the band ---
	var band: int = penumbra_radius + 1
	var bx0 := -band
	var by0 := -band
	var bx1 := zw + band
	var by1 := zh + band
	if SURROUND_BAND_ON:
		for wy in range(by0, by1):
			for wx in range(bx0, bx1):
				var d := _band_depth(wx, wy)
				if d <= 0 or d > band:
					continue                     # inside the live zone, or past the ramp
				# A visited neighbour owns this ground and renders it for real.
				if taken.has(Vector2i(int(floor(float(wx) / float(zw))), int(floor(float(wy) / float(zh))))):
					n_skipped_taken += 1
					continue
				var src := _band_src(wx, wy)
				var t0: float = float(_edge_tone.get(src, 1.0 - FOG_GROUND))
				var a := _band_alpha(d, t0)
				# Repeat the edge cell's ground under the ramp, but only where the ramp is not
				# already opaque -- under full darkness the quad cannot be seen and is pure fill.
				n_band += 1
				if a < DARK_SOLID_A:
					var fe: Array = _edge_floor_for(src)
					if not fe.is_empty():
						_floor_batch_add(fe[0], Transform3D(Basis().scaled(fe[1]), Vector3(wx, float(fe[2]), wy)))
						n_ground += 1
						if not _edge_floor.has(src):
							n_borrowed += 1
					else:
						n_bare += 1
				if a >= DARK_SOLID_A:
					_dark_quad(sto, wx, wy, DARK_SOLID_Y, 1.0)
					any_solid = true
				elif a >= 0.02:
					_dark_quad(st, wx, wy, DARK_FLOOR_Y, a)
					any_blend = true
	# --- solid dark everywhere else ---
	# Unvisited slots of the 3x3, with the band's footprint cut out so the gradient stays visible
	# instead of being buried under an opaque slab.
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			if taken.has(Vector2i(sx, sy)):
				continue
			if SURROUND_BAND_ON:
				_dark_rect_minus(sto, sx * zw, sy * zh, zw, zh, bx0, by0, bx1, by1, DARK_SOLID_Y)
			else:
				_dark_rect(sto, sx * zw, sy * zh, zw, zh, DARK_SOLID_Y)
			any_solid = true
	# ...and the frame beyond the 3x3, reaching past the neighbour cull so a culled zone never
	# uncovers bare ground plane at the horizon.
	var far := int(NEIGHBOR_CULL_DIST) + maxi(zw, zh) + 40
	_dark_rect(sto, -far, -far, far * 2 + zw, far - zh, DARK_SOLID_Y)
	_dark_rect(sto, -far, 2 * zh, far * 2 + zw, far, DARK_SOLID_Y)
	_dark_rect(sto, -far, -zh, far - zw, 3 * zh, DARK_SOLID_Y)
	_dark_rect(sto, 2 * zw, -zh, far, 3 * zh, DARK_SOLID_Y)
	any_solid = true
	if any_solid:
		var mo := MeshInstance3D.new()
		mo.mesh = sto.commit()
		mo.material_override = _dark_solid_material()
		mo.set_meta("is_darkness", true)
		parent.add_child(mo)
	if any_blend:
		var mb := MeshInstance3D.new()
		mb.mesh = st.commit()
		mb.material_override = _dark_material()
		mb.set_meta("is_darkness", true)
		parent.add_child(mb)
	# The band's ground quads went into the shared batch; emit them into the PARENT (the per-turn
	# dynamic root), not _spawn_parent()'s `self`, which nothing clears.
	_flush_floor_batch(parent)
	_band_stats = {
		"on": SURROUND_BAND_ON, "zone": "%dx%d" % [zw, zh], "radius": penumbra_radius,
		"band_cells": n_band, "ground_repeated": n_ground, "skipped_loaded_neighbour": n_skipped_taken,
		"edge_floor_known": _edge_floor.size(), "edge_tone_known": _edge_tone.size(),
		"ground_borrowed_along_edge": n_borrowed, "ground_BARE_none_found": n_bare,
		"slots_taken": taken.keys().size(),
	}

## Which zone slot a world coordinate falls in, flooring toward negative so -1 is the slot BEFORE 0
## rather than 0 itself (integer division truncates toward zero and would merge them).
func _slot(v: int, size: int) -> int:
	return int(floor(float(v) / float(size)))

## One solid quad over a rect of cells, in cell coordinates (x,y = its corner cell).
func _dark_rect(st: SurfaceTool, x: int, y: int, w: int, h: int, yy: float) -> void:
	if w <= 0 or h <= 0:
		return
	var c := Color(0, 0, 0, 1)
	var l := float(x) - 0.5
	var rr := float(x + w) - 0.5
	var t := float(y) - 0.5
	var b := float(y + h) - 0.5
	for p in [Vector3(l, yy, t), Vector3(rr, yy, t), Vector3(rr, yy, b),
			Vector3(l, yy, t), Vector3(rr, yy, b), Vector3(l, yy, b)]:
		st.set_color(c)
		st.add_vertex(p)

## The LIVE zone's own edge fade: how lit a cell stays by how far it is from the nearest zone edge.
## Mirrors _frozen_light across the boundary — the outermost row sits at FROZEN_EDGE_DIM, matching
## the neighbour's first row, and clears penumbra_radius + 1 tiles inward. Cardinal by construction: it
## takes the nearest of the four edges, so all four fade and a corner fades from both at once.
## Float form of _live_edge_light, for sampling inside a tile when divisions > 1.
func _live_edge_light_at(wx: float, wy: float) -> float:
	var din: float = minf(minf(wx + 0.5, (_live_w - 0.5) - wx),
		minf(wy + 0.5, (_live_h - 0.5) - wy))
	var lim: float = float(penumbra_radius + 1)
	if din >= lim:
		return 1.0
	return 1.0 - lerpf(FROZEN_EDGE_DIM, 0.0, clampf(din / lim, 0.0, 1.0))

func _live_edge_light(k: Vector2i) -> float:
	var din: int = mini(mini(k.x, int(_live_w - 1.0) - k.x), mini(k.y, int(_live_h - 1.0) - k.y))
	if din >= penumbra_radius + 1:
		return 1.0
	var t: float = clampf(float(din) / float(maxi(1, penumbra_radius + 1)), 0.0, 1.0)
	return 1.0 - lerpf(FROZEN_EDGE_DIM, 0.0, t)

## One fade cell of a ZONE (frozen ramp or the live zone's edge), resampled per division. Same
## axis-aware trick: only the axes that actually vary get cut.
## `tone_floor`: the cell's TONE as a darkness alpha (see _build_darkness pass 1). The veil is
## resampled per sub-quad; the tone is uniform across the tile, so it rides along as a floor and
## the same max(tone, veil) rule holds at every sample. Without it a subdivided cell would come
## Veil alpha range [min, max] across ONE cell, sampled at its four corners.
##
## Both ramps are monotone in a distance to a rectangle, so the corners BRACKET every sample inside
## the tile — which is what lets the caller decide whether a cell is a gradient worth subdividing or
## a flat step that one quad renders identically. Cheap: four evaluations against 256.
func _veil_bounds(k: Vector2i, kind: int, off: Vector2i) -> Vector2:
	var lo := 1.0
	var hi := 0.0
	for dy in [-0.5, 0.5]:
		for dx in [-0.5, 0.5]:
			var lf: float
			if kind == 1:
				lf = _frozen_light_at(float(k.x) + dx + float(off.x), float(k.y) + dy + float(off.y))
			else:
				lf = _live_edge_light_at(float(k.x) + dx, float(k.y) + dy)
			var v := 1.0 - lf
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return Vector2(lo, hi)

## out LIGHTER than the same cell unsubdivided wherever the tone is the darker of the two.
func _emit_fade_cell(st: SurfaceTool, sto: SurfaceTool, k: Vector2i, kind: int,
		off: Vector2i, amax: float, tone_floor := 0.0) -> Array:
	var d: int = maxi(1, penumbra_divisions)
	var blended := false
	var solid := false
	var sw := 1.0 / float(d)
	for iy in d:
		for ix in d:
			var x0 := float(k.x) - 0.5 + float(ix) * sw
			var y0 := float(k.y) - 0.5 + float(iy) * sw
			var lf: float
			if kind == 1:
				lf = _frozen_light_at(x0 + sw * 0.5 + float(off.x), y0 + sw * 0.5 + float(off.y))
			else:
				lf = _live_edge_light_at(x0 + sw * 0.5, y0 + sw * 0.5)
			var a: float = maxf(tone_floor, 1.0 - lf) * amax
			if a >= DARK_SOLID_A:
				_dark_quad_xy(sto, x0, y0, x0 + sw, y0 + sw, DARK_SOLID_Y, 1.0)
				solid = true
			elif a >= 0.02:
				_dark_quad_xy(st, x0, y0, x0 + sw, y0 + sw, DARK_FLOOR_Y, a)
				blended = true
	return [blended, solid]

## A black quad over an arbitrary rect in cell coordinates (edges, not centres).
func _dark_quad_xy(st: SurfaceTool, x0: float, y0: float, x1: float, y1: float,
		yy: float, a: float) -> void:
	var c := Color(0, 0, 0, a)
	for p in [Vector3(x0, yy, y0), Vector3(x1, yy, y0), Vector3(x1, yy, y1),
			Vector3(x0, yy, y0), Vector3(x1, yy, y1), Vector3(x0, yy, y1)]:
		st.set_color(c)
		st.add_vertex(p)

## One quad over cell (cx,cy) in an ARBITRARY colour — the memory wash uses it to paint the field
## colour over a remembered cell instead of veiling the real floor in black.
func _dark_quad_col(st: SurfaceTool, cx: float, cy: float, y: float, col: Color) -> void:
	for p in [Vector3(cx - 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy + 0.5),
			Vector3(cx - 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy + 0.5), Vector3(cx - 0.5, y, cy + 0.5)]:
		st.set_color(col)
		st.add_vertex(p)

## One black quad (two tris) over cell (cx,cy) at height y, vertex alpha = a.
func _dark_quad(st: SurfaceTool, cx: float, cy: float, y: float, a: float) -> void:
	var c := Color(0, 0, 0, a)
	for p in [Vector3(cx - 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy + 0.5),
			Vector3(cx - 0.5, y, cy - 0.5), Vector3(cx + 0.5, y, cy + 0.5), Vector3(cx - 0.5, y, cy + 0.5)]:
		st.set_color(c)
		st.add_vertex(p)

## A vertical dark quad on cell (cx,cy)'s face toward d (full cell width, 0..WALL_H),
## nudged just OUTSIDE the wall face so it darkens it from the open side without z-fight.
func _dark_side(st: SurfaceTool, cx: float, cy: float, d: Vector2i, a: float) -> void:
	var c := Color(0, 0, 0, a)
	var e := 0.01
	var v: Array
	if d.x != 0:
		var x := cx + (0.5 + e) * float(d.x)
		v = [Vector3(x, 0.0, cy - 0.5), Vector3(x, 0.0, cy + 0.5),
			Vector3(x, WALL_H, cy + 0.5), Vector3(x, WALL_H, cy - 0.5)]
	else:
		var z := cy + (0.5 + e) * float(d.y)
		v = [Vector3(cx - 0.5, 0.0, z), Vector3(cx + 0.5, 0.0, z),
			Vector3(cx + 0.5, WALL_H, z), Vector3(cx - 0.5, WALL_H, z)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_color(c)
		st.add_vertex(v[i])

## The OPAQUE twin of _dark_material, for quads at full darkness. Same look at alpha 1, none of the
## blending cost, and it writes depth — so it also hides what it covers instead of tinting it.
var _dark_solid_mat: StandardMaterial3D
func _dark_solid_material() -> StandardMaterial3D:
	if _dark_solid_mat != null:
		return _dark_solid_mat
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0, 0, 0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_dark_solid_mat = m
	return m

func _dark_material() -> StandardMaterial3D:
	if _dark_mat != null:
		return _dark_mat
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX        # alpha-black OVER the scene = darken
	m.vertex_color_use_as_albedo = true                # per-cell vertex alpha drives darkness
	# REQUIRED now that the vertex colour is not always black. Godot reads vertex colour as
	# LINEAR without this, so #155352 was converted up to a bright turquoise — the overlay
	# glowed instead of dimming. Black hid the omission for as long as black was all it carried:
	# 0 is 0 in either space. Same trap as the palette meshes (docs/gotchas.md).
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED   # overlay: test depth but don't write
	_dark_mat = m
	return m

func _drop_static(id: String) -> void:
	if _ib_active and id == _ib_id:
		_ib_abort()             # its subtree is about to be freed; don't build into a dangling node
	if _static_zones.has(id):
		_static_zones[id].free()
		_static_zones.erase(id)

func _drop_all_static() -> void:
	_cell_top_static.clear()
	if _ib_active:
		_ib_abort()             # every subtree is about to be freed
	for id in _static_zones:
		_static_zones[id].free()
	_static_zones.clear()
	_live_static_id = ""
	for c in _dynamic_root.get_children():
		c.free()

## Sync the remembered-neighbour subtrees to the wanted set. Each neighbour is its
## own frozen Node3D under _remembered_root, built ONCE (at local cell coords) and
## thereafter only repositioned by a transform. So a step touches nothing here, and
## a crossing just moves the existing subtrees + builds the one new zone — instead
## of rebuilding all of them. Each `nb` is {id, cells, offset}.
func _sync_neighbors(neighbors: Array) -> void:
	var want := {}
	for nb in neighbors:
		want[String(nb.get("id", ""))] = nb
	# drop subtrees for zones that are no longer neighbours — but NEVER the live
	# zone's static (it isn't in `neighbors`; render_snapshot owns its lifetime).
	for id in _static_zones.keys():
		if id != _live_static_id and not want.has(id):
			_static_zones[id].queue_free()
			_static_zones.erase(id)
	# ensure each wanted neighbour is built once, then position it by its offset
	for id in want:
		var nb: Dictionary = want[id]
		# DO NOT BUILD WHAT NOTHING CAN SHOW. A same-stratum zone past the ramp is exactly a zone
		# outside the 3x3, and _build_unexplored's far frame already covers that ground edge to
		# edge — so its art is assembled, banked and hidden, every sprite of it invisible. That is
		# the half of a crossing that kept GROWING: the darkness bake is bounded at nine zones now,
		# but the art build was still paid once for every zone the player had ever walked through,
		# ~300ms each, and it is all discarded. Deeper strata are exempt: they hang BELOW the live
		# level, where the frame does not reach.
		#
		# Lazy, not permanent — walk back toward one and it falls through to the normal path and
		# builds then, which is also why the node stays in _static_zones once created.
		if int(nb.get("dz", 0)) == 0 and _zone_beyond_ramp(Vector2i(nb.get("offset", Vector2i.ZERO))):
			if _static_zones.has(id):
				_static_zones[id].visible = false
			continue
		if not _static_zones.has(id):
			var sub := Node3D.new()
			_remembered_root.add_child(sub)
			_static_zones[id] = sub
			_bank = sub
			_noting = false     # neighbours aren't inspected; don't touch _placed
			_remembered_build = true    # ...and its art is drawn in Qud's memory pair
			var wt := {}
			Profiler.begin("remembered.art")
			_build_zone(nb.get("cells", []), Vector2i.ZERO, true, wt)   # local coords
			_rebuild_walls(wt)     # _bank set -> into the subtree, no clear
			_flush_floor_batch()   # batched floor MultiMeshes into the neighbour subtree
			Profiler.done("remembered.art")
			_remembered_build = false
			_noting = true
			_bank = null
		# Bake this remembered zone's darkness from its stored light, so a dark cavern or
		# night surface stays dark in memory instead of rendering fully lit. Meta-guarded
		# to bake exactly ONCE — and done OUTSIDE the build block above so a zone that just
		# stopped being LIVE gets it too: its subtree already exists (built as the live
		# static, no darkness), and its per-turn darkness vanished with _dynamic_root. On
		# re-entry _drop_static frees the subtree + meta, so it re-bakes as a neighbour.
		var znode: Node3D = _static_zones[id]
		# RE-BAKE WHEN THE RELATIONSHIP CHANGES, not once per subtree. The ramp is measured from
		# the LIVE zone, so a neighbour's correct fade depends on where it sits RELATIVE to the
		# zone you are standing in — and that changes as you walk. Baking once meant a zone kept
		# whichever orientation it happened to have when first seen: walk SE -> S -> N and the SE
		# zone still wore the ramp it earned as an EAST neighbour of S, a lit band down a whole
		# edge, when as a DIAGONAL neighbour of Joppa centre it should fade only from its corner.
		# Daniel: "the SE zone is showing a light all around the zone, when it should just be the
		# corner." Keying the guard on the OFFSET re-bakes exactly when it matters and never
		# otherwise — a zone you walk past without changing its relation is left alone.
		var nb_off := Vector2i(nb.get("offset", Vector2i.ZERO))
		# FAR STAYS FAR: a zone past the ramp bakes to one offset-independent rectangle, so when it
		# was already beyond it and still is, the mesh a re-bake would produce is byte-for-byte the
		# one already hanging there. Record the new offset and move on. This is what stops the cost
		# of a crossing growing with everywhere you have ever been: only the zones actually touching
		# the live one — at most eight — do any work.
		var was_far: bool = znode.has_meta("dark_off") \
				and _zone_beyond_ramp(Vector2i(znode.get_meta("dark_off")))
		# THE CAP IS PART OF THE RELATIONSHIP TOO. A departed zone's tone is clamped to the live
		# zone's ambient (DEPARTED_CAP_ON), and that changes without anyone moving — dusk falls
		# while you stand still and every neighbour is left wearing the brightness of an hour ago.
		# Quantised (CAP_QUANT), so it re-keys a handful of times across a night rather than every
		# turn: a cap that drifted continuously would re-bake all eight neighbours per step, which
		# is precisely the crossing cost this guard exists to bound.
		var cap_step: int = _departed_cap_step()
		var cap_stale: bool = not znode.has_meta("dark_cap") \
				or int(znode.get_meta("dark_cap")) != cap_step
		if was_far and _zone_beyond_ramp(nb_off):
			znode.set_meta("dark_off", nb_off)
			# A zone past the ramp bakes to one flat rectangle whatever the cap says, so it is
			# exempt: re-baking it would produce the same mesh. Record the step and move on.
			znode.set_meta("dark_cap", cap_step)
		elif not znode.has_meta("dark_off") or Vector2i(znode.get_meta("dark_off")) != nb_off \
				or cap_stale:
			znode.set_meta("dark_off", nb_off)
			znode.set_meta("dark_cap", cap_step)
			for old_dark in znode.get_children():
				if old_dark.has_meta("is_darkness"):
					old_dark.queue_free()          # drop the previous orientation's mesh
			# No sight-disc clear: see _build_darkness for the hole that one punched into
			# every zone the player left. The OFFSET turns on the distance ramp — this zone is
			# behind you now, so it fades from its shared edge the way anything out of sight does.
			Profiler.begin("remembered.dark")
			_build_darkness(nb.get("cells", []), znode, nb_off)
			Profiler.done("remembered.dark")
			# ONE LINE PER RE-BAKE, which is once per zone per change of relationship — not per
			# turn, not per frame. It is what tools/capture/zonewalk.py asserts against: the ramp
			# a neighbour is WEARING, so a stale orientation is visible in the log instead of only
			# on the glass, where "a lit band down one edge" and "a corner fade" look alike until
			# you know which one you are owed.
			print("[zonefade] %s off=(%d,%d) cap=%d/%d" % [str(id), nb_off.x, nb_off.y,
				cap_step, int(CAP_QUANT)])
		# Vertical stacking: a neighbour `dz` strata below the live zone drops by
		# dz * level_height, so deeper levels sit under the current one with an
		# arbitrary, user-set gap. Same-stratum neighbours (dz==0) stay coplanar.
		var o: Vector2i = nb.get("offset", Vector2i.ZERO)
		var dz: int = int(nb.get("dz", 0))
		_static_zones[id].position = Vector3(o.x, -float(dz) * level_height, o.y)
		# Hide neighbours the fog fully hides anyway: the gap between the live zone's cell BOX
		# and this neighbour's, plus the vertical level gap.
		#
		# BOX TO BOX, NOT CORNER TO BOX. This measured from the live zone's ORIGIN CORNER (0,0),
		# which is its north-west corner — so a west neighbour got its whole width for free and an
		# east one was charged for it. A zone five west read 320 and stayed; the SAME zone five
		# east read 400 and was culled. Walking one zone east therefore made distant remembered
		# zones wink out, and walking back west brought them in — Daniel: "when I walk back west,
		# the lighting returns. When I go back east, the lighting disappears." Same story for
		# north over south, one zone-height's worth.
		var gx: float = maxf(0.0, maxf(float(o.x) - _live_w, -(float(o.x) + _live_w)))
		var gy: float = maxf(0.0, maxf(float(o.y) - _live_h, -(float(o.y) + _live_h)))
		var vgap: float = absf(float(dz) * level_height)
		var near: float = sqrt(gx * gx + gy * gy + vgap * vgap)
		_static_zones[id].visible = near <= NEIGHBOR_CULL_DIST

# --- introspection (for CellInspector) --------------------------------------

func _note(cx: int, cy: int, idx: int, kind: String, y: float) -> void:
	var target: Dictionary
	if _noting:
		target = _placed          # static build (walls, floors, static sprites)
	elif _dyn_noting:
		target = _dyn_placed      # live dynamic pass (creatures), cleared each turn
	else:
		return                    # neighbour builds etc.: not inspected
	var k := Vector2i(cx, cy)
	if not target.has(k):
		target[k] = []
	target[k].append({"idx": idx, "kind": kind, "y": y})

## The WHOLE zone's placement map, "x,y" -> [{idx, kind, y}, ...] — the same
## per-object verdicts CellInspector shows for one cell, for every cell at once.
## Rung 6a (docs/pc-zone-plan.md) diffs this against the wire's cell list to
## answer "did we draw everything the zone sent us?" with no pixels involved.
func placement_census() -> Dictionary:
	var out := {}
	for src in [_placed, _dyn_placed]:
		for k in src:
			var key := "%d,%d" % [k.x, k.y]
			if not out.has(key):
				out[key] = []
			out[key].append_array(src[k])
	return out

## What the renderer did with cell (cx, cy): [{idx, kind, y}, ...]
func placements_at(cx: int, cy: int) -> Array:
	var k := Vector2i(cx, cy)
	return _placed.get(k, []) + _dyn_placed.get(k, [])

## The decoded tile mask for a tile path, or null if it hasn't been exported yet.
func tile_image(tile: String) -> Image:
	return _mask(tile)

## The exact texture a billboard would use — recoloured, with enclosed gaps
## filled. What CellInspector previews, so you inspect what actually renders
## rather than a separate rendering of the same idea.
func billboard_texture(tile: String, main_c: String, detail_c: String) -> ImageTexture:
	return _colored_tex(tile, main_c, detail_c, Fill.INTERIOR)

## (offset, height) of the tile's opaque rows, as fractions of its height.
func tile_opaque_band(tile: String) -> Vector2:
	return _opaque_v(_mask(tile))

## How many transparent pixels a given fill mode would repaint as background.
## Reports the mode ACTUALLY applied (a filed verdict changes it), so the inspector
## no longer says "76 px" while 96 are filled.
func tile_fill_px(tile: String, mode: int) -> int:
	var mask
	match mode:
		Fill.INTERIOR: mask = _interior(tile)
		Fill.SPAN:     mask = _fill_holes(tile)
		Fill.POCKETS:  mask = _pockets(tile)
		_: return 0
	var n := 0
	for row in mask:
		for v in row:
			if v: n += 1
	return n

## The on-disk filename a tile path maps to under tilesDir.
# ── CUSTOM TILE ART (Daniel, 2026-08-13: "select a tile, save a png locally, and
# then upload the replacement") ─────────────────────────────────────────────────────
# Drop a file into <support>/RavesOfQud/tiles_custom/ under the tile's FLATTENED name
# (as shown in the inspector's `png` line, e.g. Creatures_npc-mehmet.bmp — png bytes
# regardless of extension, same as the export cache). It replaces the art AND renders
# AS-AUTHORED: full colour, no main/detail recolouring — what you paint is what you
# get. Alpha still drives seating, fill machinery and the depth pipeline. Ignored in
# 1:1 (parity measures Qud's art, not ours). Edits hot-reload: caches key on mtime
# and the overrides poll watches the directory, forcing a static rebuild on change.
var _custom_sig := ""

func _custom_dir() -> String:
	return "" if _tiles_dir == "" else _tiles_dir.get_base_dir().path_join("tiles_custom")

func _custom_tile_path(tile: String) -> String:
	if _one_to_one or tile == "" or _tiles_dir == "":
		return ""
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	var path := _custom_dir().path_join(fname)
	return path if FileAccess.file_exists(path) else ""

func tile_filename(tile: String) -> String:
	return tile.replace("/", "_").replace("\\", "_").replace(":", "_")

func tiles_dir() -> String:
	return _tiles_dir

## Public form of the sink rule, so the inspector reports the same number the
## renderer used rather than recomputing it and risking drift.
func cell_sink(cell: Dictionary) -> float:
	return _cell_sink(cell)

# How far an actor standing in this cell sinks, as a fraction of its art height.
# A bridge decks over the water, so you walk across at full height.
func _cell_sink(cell: Dictionary) -> float:
	if bool(cell.get("bridge", false)):
		return 0.0
	if bool(cell.get("swim", false)):
		return clampf(deep_water_depth, 0.0, 1.0)
	if bool(cell.get("wade", false)):
		return SINK_WADE
	return 0.0

# --- user overrides ----------------------------------------------------------

## A tile path reduced to its family, so one verdict covers every variant:
## `sw_waterwheel_1` and `_3`, `wall_rock-10100010` and every other bitmask.
func tile_family(tile: String) -> String:
	var t := tile.replace("\\", "/").get_file().get_basename().to_lower()
	# 0) boilerplate asset prefix: some tiles have a slash path (Items/sw_...) and
	# some are one flat filename (Assets_Content_Textures_Tiles_sw_axle...). Strip
	# the prefix so both yield the same clean family (sw_axle, not
	# assets_content_textures_tiles_sw_axle) -- otherwise keys drift by tile source.
	for pre in ["assets_content_textures_tiles_", "assets_content_textures_walls_",
			"assets_content_textures_creatures_", "assets_content_textures_"]:
		if t.begins_with(pre):
			t = t.substr(pre.length())
			break
	# 1) trailing autotile bitmask: wall_rock-11111111 -> wall_rock
	var dash := t.rfind("-")
	if dash > 0 and _is_binary(t.substr(dash + 1)):
		t = t.substr(0, dash)
	# 2) trailing direction suffix: fence_ew, sw_axle_2_EW -> drop the _<dirs>.
	# Overrides are never direction-specific (a "float" or "wall" verdict applies to
	# every orientation), so all directions of one family share a key.
	var us := t.rfind("_")
	if us > 0:
		var suf := t.substr(us + 1)
		if suf.length() >= 1 and suf.length() <= 4 and _all_dirs(suf):
			t = t.substr(0, us)
	# 3) trailing variant number: sw_waterwheel_1, sw_axle_2 -> strip the digits (+_)
	var end := t.length()
	while end > 0 and t[end - 1] >= "0" and t[end - 1] <= "9":
		end -= 1
	if end > 0 and end < t.length() and t[end - 1] == "_":
		end -= 1
	return t.substr(0, end) if end > 0 else t

func _all_dirs(suf: String) -> bool:
	for c in suf:
		if not "nsew".contains(c):
			return false
	return true

## Phrase -> renderer behaviour. Matched as substrings of the filed verdict, so
## the wording in TileReport.VERDICTS can be reworded without breaking this.
## Verdict phrase -> behaviour. Matched as substrings, so TileReport's wording can
## be edited without breaking already-filed reports.
##
## SHAPE verdicts (what geometry to build) and FILL verdicts (how to treat the
## art's transparent pixels) are independent axes — a tile can carry one of each.
const VERDICT_KEYS := [
	["waterwheel", "waterwheel"],
	["wall", "wall"],
	["n–s", "panel_ns"],
	["e–w", "panel_ew"],
	["billboard", "billboard"],
	["signpost", "signpost"],
	["tent", "tentwall"],
	["door", "door"],
	["flat", "floor"],
	["not be drawn", "skip"],
]

## Matched case-insensitively as substrings of the filed verdict, so old reports
## keep parsing and TileReport's wording can change freely. Order matters where one
## phrase contains another: "enclosed" is checked before "background".
const FILL_KEYS := [
	["small pockets", Fill.POCKETS],   # keep tiny weave/shadow gaps, open the big arches
	["enclosed", Fill.INTERIOR],       # the conservative option, if asked for by name
	["background", Fill.SPAN],         # "fill the holes" — the common intent
	["fill the holes", Fill.SPAN],
	["fill more", Fill.SPAN],
	["transparent", Fill.NONE],
	["see-through", Fill.NONE],
	["opaque", Fill.ALL],
	["solid block", Fill.ALL],
]

## Read the standing overrides — one JSON file the report form maintains, keyed by
## tile family. Replaces scanning reports/*.md: those files were doing double duty
## as both complaint tickets and live config, and deleting a "resolved" ticket
## silently reverted the render. reports/ now holds one-off notes only.
##
## Verdicts are stored as the raw phrase and interpreted here through the same
## matchers the form used to write them, so wording can change without a migration.
func _load_overrides() -> void:
	if _tiles_dir == "":
		return
	var path := _tiles_dir.get_base_dir().path_join("overrides.json")
	var text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	# custom tile art: a changed/added/removed file forces the same static rebuild the
	# overrides use — textures self-invalidate via mtime keys, but baked statics don't.
	var csig := ""
	var cd := DirAccess.open(_custom_dir())
	if cd != null:
		for f2 in cd.get_files():
			csig += "%s|%d;" % [f2, FileAccess.get_modified_time(_custom_dir().path_join(f2))]
	if csig != _custom_sig:
		_custom_sig = csig
		_overrides_dirty = true
		_wall_caches_clear()        # wall textures/gaps/meshes bake custom art in
	if text == _overrides_raw:
		return                      # unchanged since last frame — skip the re-parse
	_overrides_raw = text
	_overrides_dirty = true         # rules changed -> force a static rebuild (see render_snapshot)
	_wall_caches_clear()            # the core colour rule bakes into cached wall meshes
	_overrides.clear()
	_fill_overrides.clear()
	_core_overrides.clear()
	_cutout_overrides.clear()
	_recolor_overrides.clear()
	_position_overrides.clear()
	_glow_overrides.clear()
	_stairdir_overrides.clear()
	if text == "":
		return
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var tiles = data.get("tiles", {})
	if typeof(tiles) != TYPE_DICTIONARY:
		return
	for fam in tiles:
		var entry = tiles[fam]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var shape := _match_shape(String(entry.get("shape", "")))
		if shape != "":
			_overrides[fam] = shape
		var fill := _match_fill(String(entry.get("fill", "")))
		if fill >= 0:
			_fill_overrides[fam] = fill
		var pos := _match_position(String(entry.get("position", "")))
		if pos != "":
			_position_overrides[fam] = pos
		if String(entry.get("effect", "")).to_lower().contains("glow"):
			_glow_overrides[fam] = true
		# "cutout": drop OPAQUE pixels of the tile's darker colour to transparent —
		# the opposite axis from "fill" (which paints transparent pixels opaque).
		if String(entry.get("cutout", "")).to_lower().contains("darkest"):
			_cutout_overrides[fam] = true
		# "recolor": {"K": "y"} — swap one Qud colour code for another on this family. Keyed by
		# the SOURCE code, which is what lets it separate two objects that SHARE a tile: salt-
		# encrusted watervines and plain ones are the same sw_watervine art and differ only in
		# their detail code (K against g), so a K->y rule reaches the salted ones alone. A
		# family-keyed rule with no source test could not tell them apart at all.
		var rc = entry.get("recolor", null)
		if typeof(rc) == TYPE_DICTIONARY and not (rc as Dictionary).is_empty():
			var map := {}
			for k in rc:
				map[_fg_letter(String(k))] = _fg_letter(String(rc[k]))
			_recolor_overrides[fam] = map
		var sd := _match_stairdir(String(entry.get("stairDir", "")))
		if sd != "":
			_stairdir_overrides[fam] = sd
		# "core": "#rrggbb" — the wall recess/core colour (set from the voxel editor)
		var core := String(entry.get("core", ""))
		if core.begins_with("#") and core.length() >= 7:
			_core_overrides[fam] = Color.html(core)

## Verdict phrase -> shape key, or "" if none matches.
func _match_shape(verdict: String) -> String:
	var v := verdict.to_lower()
	for pair in VERDICT_KEYS:
		if v.contains(pair[0]):
			return pair[1]
	return ""

## Verdict phrase -> Fill mode, or -1 if none matches.
func _match_fill(verdict: String) -> int:
	var v := verdict.to_lower()
	for pair in FILL_KEYS:
		if v.contains(pair[0]):
			return pair[1]
	return -1

## Vertical placement verdicts. "ground" is the default (seated), so only "float"
## is stored; matching "ground" explicitly lets a verdict UNDO a float.
const POSITION_KEYS := [["float", "float"], ["ground", "ground"]]

func _match_position(verdict: String) -> String:
	var v := verdict.to_lower()
	for pair in POSITION_KEYS:
		if v.contains(pair[0]):
			return pair[1]
	return ""

## Stair-descent verdict -> cardinal letter, or "" if none. Accepts a bare cardinal
## ("south"), or the phrase the report form emits ("descend south"/"down toward south").
func _match_stairdir(verdict: String) -> String:
	var v := verdict.to_lower()
	if v == "":
		return ""
	for pair in [["north", "n"], ["south", "s"], ["east", "e"], ["west", "w"]]:
		if v.contains(pair[0]):
			return pair[1]
	if v in ["n", "s", "e", "w"]:
		return v
	return ""

## "float" if this tile is verdict-floated, else "" (ground-seated default).
func position_for(tile: String) -> String:
	if _position_overrides.is_empty() or tile == "":
		return ""
	var p := String(_position_overrides.get(tile_family(tile), ""))
	return p if p == "float" else ""

## The fill mode a billboard of this tile would use — the inspector previews with it.
func fill_mode_for(tile: String) -> int:
	return _fill_for(tile, Fill.INTERIOR)

## A filed FILL verdict for this tile if there is one, else the caller's default.
func _fill_for(tile: String, fallback: int) -> int:
	if _fill_overrides.is_empty() or tile == "":
		return fallback
	return int(_fill_overrides.get(tile_family(tile), fallback))

## Active standing rules on a tile, as text — so the inspector can show whether a
## filed rule actually took. A key that doesn\'t match returns "", which reads as
## "no override" and makes a typo'd overrides.json entry visible instead of silent.
func override_summary(tile: String) -> String:
	var fam := tile_family(tile)
	var parts := []
	if _overrides.has(fam):
		parts.append("shape=" + String(_overrides[fam]))
	if _fill_overrides.has(fam):
		var names := ["none", "all", "interior", "fill-holes", "pockets"]
		var m := int(_fill_overrides[fam])
		parts.append("fill=" + (names[m] if m < names.size() else str(m)))
	if _position_overrides.has(fam):
		parts.append("pos=" + String(_position_overrides[fam]))
	if _glow_overrides.has(fam):
		parts.append("effect=glow")
	if _cutout_overrides.has(fam):
		parts.append("cutout=darkest")
	if _recolor_overrides.has(fam):
		var rm: Dictionary = _recolor_overrides[fam]
		for k in rm:
			parts.append("recolor=%s->%s" % [k, rm[k]])
	return "" if parts.is_empty() else "  ".join(parts)

## Does this tile family drop its darker colour to transparent? (Daniel, watervines:
## "all the darkest squares should be transparent".)
func _cutout_for(tile: String) -> bool:
	return not _cutout_overrides.is_empty() and tile != "" and _cutout_overrides.has(tile_family(tile))

func _override_for(tile: String) -> String:
	if _overrides.is_empty() or tile == "":
		return ""
	return String(_overrides.get(tile_family(tile), ""))

# --- torch / fire light ------------------------------------------------------

## An additive warm glow on the ground (the "light") plus a small flickering flame
## Is this object ON FIRE, read off Qud's own render animation?
##
## Qud has no "burning" flag on the wire, but it does not need one: a Flaming object's
## RenderEvent flickers, and the mod sweeps 60 frames of that into `animSched` already (see
## AnimFrameSweep). Burning comes through as a COLOUR-ONLY schedule — no tile ever changes —
## whose entries pair a fire foreground with a flashing cell BACKGROUND:
##
##     60|0=;&r^k;|1=;;|2=;&r^k;|7=;&r^W;|11=;&r^W;|12=;&r^k;|...
##
## which is red-on-black alternating with red-on-white and plain frames between. Reading the
## animation rather than adding a flag means this works for EVERY burning thing Qud renders, not
## just the player — the Mechanimist pilgrim who catches light beside you smokes too — and needs
## no mod rebuild, which matters because deploying one costs a full Qud restart.
##
## Deliberately narrow. `^` alone is not fire: Asleep floods `^c` behind its art the same way. The
## foreground has to be a flame colour AND a background has to flash, and it has to happen on at
## least two distinct frames, or a single steady tint would qualify.
## THE FLICKER IS IN THE BACKGROUND, NOT THE FOREGROUND. This first read the foreground for a
## flame colour, which worked on two characters and silently failed on a third: the foreground is
## the CREATURE'S OWN colour and has nothing to do with being on fire. Three real captures, all
## burning —
##     &r^k / &r^W     a Wanderer
##     &Y^k / &Y^W     the same character later
##     &G^k / &G^W     a level-44 character, and the one that exposed it
## — vary in the foreground and agree exactly in the background: Qud flashes the CELL white and
## back as the thing burns. So the test is the background alternating W and k, and the foreground
## is not looked at at all.
const FIRE_BG_FLASH := "W"      # the flash
const FIRE_BG_BASE := "K"       # ...and what it flashes back to (matched case-insensitively)
func _is_burning(obj: Dictionary) -> bool:
	var spec := String(obj.get("animSched", ""))
	if spec == "" or spec.find("^") < 0:
		return false
	var parts := spec.split("|")
	var seen := {}
	for i in range(1, parts.size()):
		var kv := parts[i].split("=")
		if kv.size() != 2:
			continue
		var axes := String(kv[1]).split(";")
		if axes.size() != 3:
			continue
		if axes[0] != "":
			return false          # a tile swap: some other animation (the dawnglider's flying icon)
		var col := String(axes[1])
		var cut := col.find("^")
		if cut < 0:
			continue
		var bg := col.substr(cut + 1)
		if bg.length() != 1:
			continue
		seen[bg.to_upper()] = true
	# Both halves of the flicker must be present. One alone is a steady tint — Asleep floods a
	# single ^c behind its art the same way, and a thing that is merely tinted must not catch fire.
	return seen.has(FIRE_BG_FLASH) and seen.has(FIRE_BG_BASE)

## A BODY ON FIRE IS NOT A TORCH. The sconce rig emits from a 0.05-unit box at one point, which on
## a creature reads as a single flame stuck to one spot; and its smoke is sized for ambience over a
## wall bracket. Daniel: "the fire is only in one place on the body, let's spread it around" and
## "the smoke should be bigger and spread much higher/wider -- when you're on fire, we make it more
## dramatic." So burning gets its own numbers rather than sharing the torch's.
const BURN_FIRE_AMOUNT := 44        # against a torch's 12 — the whole body alight, not one tongue
const BURN_FIRE_SQUARE := 0.07      # SMALLER than a torch's 0.075: fine tongues, not blobs
const BURN_FIRE_LIFETIME := 0.95    # a little longer alive, so a tongue reaches further up
const BURN_FIRE_RISE := 2.1         # 0.85 -> 1.25 -> here; flames SHOOT up rather than drift
## Tongues are drawn TALLER than they are wide. A square particle reads as an ember; the same
## quad stretched vertically reads as flame, and it costs nothing — the billboard keeps facing
## the camera either way. Daniel: "can we make the particles flame vertically a little more?"
const BURN_FIRE_TALL := 1.7
## Emission volume: roughly a body. The Y extent is what spreads flame UP the creature instead of
## pooling it at the feet — the emitter sits at BURN_FIRE_Y, so tongues start anywhere in the box
## around it rather than all from one point.
## Tighter than it was (0.30 cubed). The wide box spread flame across the whole tile, which read
## as a bonfire the creature happened to stand in rather than a body alight. Narrow in X and Z so
## the tongues hug the torso; the Y extent is the one that stays generous, because that is what
## puts flame UP the body instead of pooling it at the feet. Daniel: "the flames are great, but
## can we tighten them up?"
const BURN_FIRE_BOX := Vector3(0.15, 0.26, 0.15)
const BURN_FIRE_Y := 0.40
## DENSITY IS WHAT MAKES IT ONE COLUMN. Coherent launch speeds stopped the plume tearing apart,
## and it still read as a string of separate puffs — because 80 particles spread over a five-second
## climb simply leaves gaps between them. The fix is more of them over a SHORTER climb: the same
## column, filled in. (Shorter life also keeps the total on screen sane at this count.)
const BURN_SMOKE_AMOUNT := 150      # against a sconce's 14
const BURN_SMOKE_SQUARE := 0.36     # against 0.16 — big soft billows, not a thin wisp
const BURN_SMOKE_LIFETIME := 3.4    # shorter than 5.0 on purpose — see BURN_SMOKE_AMOUNT
const BURN_SMOKE_RISE := 5.2        # 0.95 -> 1.6 -> 3.4 -> here; it LEAVES, it does not seep
## AND IT KEEPS GOING. There was a brake here — damping that switched on once a particle had
## climbed four tiles, so the plume slowed at the top. It measured exactly as designed (density
## piled up across tiles 1-4 and fell off a cliff above) and looked wrong doing it: decelerating
## particles bunch, and a bunch reads as a lid on the column rather than smoke thinning out.
## Daniel: "let's make the smoke particles keep rising, the slowdown looks not good." Rising all
## the way and fading on the colour ramp's alpha is what smoke does — it does not stop, it stops
## being visible.
const BURN_SMOKE_SWAY := 0.75       # against 0.28 — it spreads WIDE as it climbs
## Tight. A column reads as ONE plume off one body only while the particles stay grouped; born
## across a wide footprint they read as several small fires. Narrow here and narrow in `spread`
## below — the width the plume does gain should come from the wind carrying it, which is coherent,
## rather than from scatter at birth, which is not. Daniel: "make the smoke rise faster and group
## tighter."
const BURN_SMOKE_BOX := Vector3(0.11, 0.07, 0.11)
const BURN_SMOKE_Y := 0.95
## STANDING WIND, blowing to the NORTH-EAST. A cell's north is (0,-1) and its east is (1,0)
## (see the `step` table), and a cell maps to world as Vector3(x, h, y) — so north-east is +X, -Z.
##
## Applied as the particle system's GRAVITY, which is otherwise zero for smoke. That gives a
## constant sideways ACCELERATION, and against the plume's damping it settles into a steady lean:
## the column still leaves the body vertically and bends downwind as it climbs, which is how smoke
## actually behaves. A fixed velocity offset would shear the whole plume sideways from the first
## frame instead, wind-sock rather than smoke.
##
## Constant for now, by request — real weather syncing comes later, and when it does this is the
## one value to drive: point it wherever the zone's wind blows and everything downstream follows.
const BURN_WIND := Vector3(0.42, 0.0, -0.42)
var _burn_fire_mesh: QuadMesh = null
var _burn_smoke_mesh: QuadMesh = null
var _burn_fire_pm: ParticleProcessMaterial = null
var _burn_smoke_pm: ParticleProcessMaterial = null

## Build the burning variants ONCE, from the sconce rigs so the look stays in the same family —
## same materials, same colour ramps, opened up.
func _build_burn_resources() -> void:
	if _burn_smoke_pm != null:
		return
	if _fire_pm == null:
		_build_fire_resources()
	_burn_fire_mesh = QuadMesh.new()
	_burn_fire_mesh.size = Vector2(BURN_FIRE_SQUARE, BURN_FIRE_SQUARE * BURN_FIRE_TALL)
	_burn_fire_mesh.material = _fire_mesh.material
	_burn_smoke_mesh = QuadMesh.new()
	_burn_smoke_mesh.size = Vector2(BURN_SMOKE_SQUARE, BURN_SMOKE_SQUARE)
	# SOFT-EDGED, because SIZE IS WHAT EXPOSES A BARE QUAD. A sconce's particle is 0.16 across and
	# reads as a speck of soot whatever its shape; at 0.36 the same untextured quad is unmistakably a
	# grey SLAB, and forty of them look like falling debris rather than smoke. A radial alpha falloff
	# is what the rest of Raves' FX already use (the glow pool, the torch flame), so this stays in
	# the same family. The colour ramp still drives hue and alpha -- the texture only shapes the edge.
	var bmat: StandardMaterial3D = (_smoke_mesh.material as StandardMaterial3D).duplicate()
	bmat.albedo_texture = _make_radial(48, Color(1, 1, 1), 1.25)
	bmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_burn_smoke_mesh.material = bmat
	_burn_fire_pm = _fire_pm.duplicate()
	_burn_fire_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_burn_fire_pm.emission_box_extents = BURN_FIRE_BOX
	_burn_fire_pm.initial_velocity_min = BURN_FIRE_RISE * 0.7
	_burn_fire_pm.initial_velocity_max = BURN_FIRE_RISE * 1.25
	_burn_fire_pm.spread = 4.0                       # near-vertical; the little width comes from the box
	_burn_smoke_pm = _smoke_pm.duplicate()
	_burn_smoke_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_burn_smoke_pm.emission_box_extents = BURN_SMOKE_BOX
	# ONE COLUMN MEANS ONE SPEED. The sconce rig launches over a 0.75-1.2 range, which is right
	# for a lazy plume off a wall bracket and is what was tearing this one apart: at 5.2 units/s
	# over a 5s life the slowest and fastest particles end up ELEVEN TILES apart, so what leaves
	# the body as a column arrives as a scatter of separate puffs. Daniel: "make the smoke hold
	# together as one column." Nearly-equal launch speeds keep the plume coherent; the width it
	# gains on the way up should come from the wind and the growth curve, both of which act on
	# every particle alike, rather than from a lottery at birth.
	_burn_smoke_pm.initial_velocity_min = BURN_SMOKE_RISE * 0.94
	_burn_smoke_pm.initial_velocity_max = BURN_SMOKE_RISE * 1.06
	_burn_smoke_pm.direction = Vector3(0, 1, 0)      # leaves the body VERTICALLY...
	_burn_smoke_pm.spread = 2.5                      # a column, not a cone
	_burn_smoke_pm.gravity = BURN_WIND               # ...and leans downwind as it climbs
	_burn_smoke_pm.turbulence_noise_strength = BURN_SMOKE_SWAY
	# Strong sway, but MODERATE influence: the plume has to climb more than it wanders. Cranking
	# both spread it through the ground plane instead, which under this camera reads as smoke
	# drifting sideways and DOWN rather than a column going up.
	# Turbulence keeps its STRENGTH (the billows still churn) but takes much less INFLUENCE, so
	# the churn happens inside a tight column instead of walking particles out of it.
	_burn_smoke_pm.turbulence_influence_min = 0.03
	_burn_smoke_pm.turbulence_influence_max = 0.08
	# NO BRAKE. The sconce rig damps a little so its thin plume eases off near the top; a body on
	# fire should climb the whole way and thin out on the ramp's alpha instead. Explicitly zero
	# rather than inherited, so it cannot drift back in from the material this was duplicated from.
	_burn_smoke_pm.damping_min = 0.0
	_burn_smoke_pm.damping_max = 0.0
	_burn_smoke_pm.damping_curve = null
	# grows as it climbs, harder than the sconce's — a billow, not a thread
	# Grows, but not so much that neighbours stop overlapping and start reading as separate
	# billows — the column has to stay one thing.
	var bc := Curve.new()
	bc.add_point(Vector2(0.0, 0.8))
	bc.add_point(Vector2(1.0, 1.9))
	var bct := CurveTexture.new()
	bct.curve = bc
	_burn_smoke_pm.scale_curve = bct

## Fire and a smoke plume on a BURNING creature's cell, for the turn it is burning.
##
## The emitters are the sconce/campfire rig — same _make_fire / _make_smoke, so a creature alight
## reads like the other fires in the world rather than a second, unrelated effect. They go into
## _bank, which during the dynamic pass IS _dynamic_root, so they are freed with everything else
## next turn: a creature that stops burning, dies or walks out of sight takes its fire with it and
## there is nothing to track. That is also why this does not register in _lights — that list is for
## the STATIC zone's flicker driver, and a dynamic entry in it would outlive the node it names.
##
## Unconditional, not behind the particles ambience toggle: _smoke_on's own rule is that a real
## fire smokes whether or not the viewer opted into ambience. 1:1 renders Qud's flicker instead
## (see _register_anim) and must not grow a 3D flame.
func _place_burning(cx: int, cy: int) -> void:
	if _one_to_one or _world_map:
		return
	var lp: Node = _bank if _bank != null else _dynamic_root
	if lp == null:
		return
	_build_burn_resources()
	var pf := GPUParticles3D.new()
	pf.amount = BURN_FIRE_AMOUNT
	pf.lifetime = BURN_FIRE_LIFETIME
	pf.preprocess = BURN_FIRE_LIFETIME               # already burning, not just lit
	pf.randomness = 0.7
	pf.process_material = _burn_fire_pm
	pf.draw_pass_1 = _burn_fire_mesh
	pf.local_coords = false
	pf.visibility_aabb = AABB(Vector3(-1.2, -0.6, -1.2), Vector3(2.4, 3.0, 2.4))
	pf.position = Vector3(cx, BURN_FIRE_Y, cy)
	lp.add_child(pf)
	var sm := GPUParticles3D.new()
	sm.amount = BURN_SMOKE_AMOUNT
	sm.lifetime = BURN_SMOKE_LIFETIME
	sm.preprocess = BURN_SMOKE_LIFETIME              # a column already standing, not starting empty
	# Randomness re-rolls lifetime and velocity per particle; at 0.6 it undoes the tight launch
	# range above. Low enough to keep the plume from looking mechanical, not enough to shred it.
	sm.randomness = 0.15
	sm.process_material = _burn_smoke_pm
	sm.draw_pass_1 = _burn_smoke_mesh
	sm.local_coords = false
	# tall and wide enough that the column is not culled when the burning cell leaves the frustum
	sm.visibility_aabb = AABB(Vector3(-4.0, -1.0, -4.0),
		Vector3(8.0, BURN_SMOKE_RISE * BURN_SMOKE_LIFETIME + 3.0, 8.0))
	sm.position = Vector3(cx, BURN_SMOKE_Y, cy)
	sm.emitting = true
	lp.add_child(sm)
	# ONE LINE PER BURNING CELL PER TURN, the way [zonefade] reports a re-bake. Fire is rare and
	# short: the flame that prompted this was beaten out by hand two turns after it was seen, before
	# a build finished. A log line means the next one confirms the path fired without anybody having
	# to be watching the glass at the right moment.
	print("[burning] cell (%d,%d)" % [cx, cy])

## above the sconce. Qud's radius is in cells; 1 cell == 1 world unit.
func _place_light(cx: int, cy: int, radius: float, smokes := true, on_fire := false) -> void:
	if _one_to_one:
		return   # 1:1: Qud has no glow pools / flames / smoke — the rectangular lit cells ARE
		         # the light. Hard gate so none of this geometry is even created.
	if _world_map:
		return   # the parasang overview is flat and fully lit; a flickering torch glow on a
		         # world tile (e.g. a glowfish parasang) just oscillates distractingly — skip it.
	# `smokes` is false for creature lights (e.g. a bioluminescent glowfish) — they glow
	# but are not fire, so no plume. `on_fire` (campfires) draws a real flame SHAPE, alpha-blended so
	# it reads in daylight (the additive torch flame fades out by day, which is fine for a torch whose
	# TILE shows flame, but a campfire's tile is flameless). All torch nodes live in their zone's frozen
	# subtree (the bank). Only the LIVE zone's register in _lights for the _process flicker.
	var lp: Node = _bank if _bank != null else _light_root
	var glow := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	# A fire's ground-pool is kept TIGHT (a halo at the flame's foot) so it reads as one campfire, not a
	# separate flat disc under a standing flame; a torch/sconce pools wider. Both fade out by day anyway.
	var d: float = maxf(1.6, radius * 0.7) if on_fire else maxf(2.0, radius * 1.6)
	gm.size = Vector2(d, d)
	glow.mesh = gm
	glow.position = Vector3(cx, FLOOR_Y + 0.01, cy)
	glow.material_override = _fx_material(_glow_tex)
	lp.add_child(glow)

	# THE FLAME. Live zone: PARTICLE FIRE (Daniel: the drawn flame was "not
	# on-theme" — this is the 1:1 fire program's 3D voice, the smoke's
	# sibling rig). Remembered zones keep the old drawn sprite: emitters are
	# live-zone-only (the bounded-particle doctrine), and a frozen memory
	# with a baked flame reads better than one with no fire at all.
	# Glow-critters (smokes=false, not on_fire) also keep the faint sprite —
	# a glowfish must not literally catch fire.
	var flame: Node3D
	var particle_fire: bool = _live_build and (smokes or on_fire)
	if particle_fire:
		var pf := _make_fire(on_fire)
		pf.position = Vector3(cx, 0.42 if on_fire else 0.62, cy)   # tongues rise from the base
		lp.add_child(pf)
		flame = pf
	else:
		var fsp := Sprite3D.new()
		fsp.texture = _fire_tex if on_fire else _flame_tex
		fsp.pixel_size = 0.006 if on_fire else 0.03       # small drawn flame (~0.4 tile)
		fsp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		fsp.shaded = false
		fsp.transparent = true
		# on-fire: ALPHA (reads on any background); else ADDITIVE (a glowing torch core).
		fsp.material_override = _fx_material_alpha(fsp.texture) if on_fire else _fx_material(_flame_tex)
		fsp.position = Vector3(cx, 0.55 if on_fire else 0.7, cy)
		lp.add_child(fsp)
		flame = fsp

	# Rising smoke plume. Only the LIVE zone gets emitters (keeps the particle count bounded). A torch's
	# smoke is a NIGHT effect (its flame fades by day). A FIRE (campfire) burns day + night, so its smoke
	# emits always — `fire_smoke` tells set_daylight not to switch it off at dawn.
	if _live_build:
		var entry := {"glow": glow, "flame": flame, "energy": 1.0, "on_fire": on_fire,
			"particle_fire": particle_fire}
		if smokes:
			var smoke := _make_smoke()
			smoke.position = Vector3(cx, 0.85, cy)   # just above the flame
			smoke.emitting = true if on_fire else _smoke_on()
			lp.add_child(smoke)
			entry["smoke"] = smoke
			entry["fire_smoke"] = on_fire
		_lights.append(entry)
	else:
		# Neighbour/static lights don't flicker in _process, so bake the current daylight dimming now.
		glow.transparency = clampf(1.0 - (_fire_glow_mul() if on_fire else _glow_mul()) * 0.6, 0.0, 1.0)
		# NB: a Sprite3D's `modulate` is IGNORED once material_override is set, so dim via transparency.
		# A drawn fire flame stays fully visible (it's the only fire cue by day); a torch flame fades.
		(flame as Sprite3D).transparency = 0.0 if on_fire else clampf(1.0 - _flame_mul(), 0.0, 1.0)

## Unshaded + additive: brightens whatever is behind it, no scene lighting needed.
func _fx_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if tex != null:
		m.albedo_texture = tex
	return m

## Unshaded + ALPHA (normal) blend: draws the texture as a solid sprite over the scene, so a warm flame
## reads on a bright daytime background where the additive variant would wash out. For on-fire flames.
func _fx_material_alpha(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	if tex != null:
		m.albedo_texture = tex
	return m

# --- smoke ------------------------------------------------------------------

# Tunables for the sconce smoke plume (Qud: grey squares, oscillating x, ~3 tiles high).
const SMOKE_AMOUNT := 14        # particles alive per sconce
const SMOKE_LIFETIME := 3.4     # seconds; rise-height ≈ velocity * lifetime
const SMOKE_RISE := 0.95        # upward velocity (world units/s); ~3 tiles over the lifetime
const SMOKE_SQUARE := 0.16      # edge of a smoke square (world units), before per-particle scale
const SMOKE_SWAY := 0.28        # turbulence strength -> the oscillating horizontal drift
const SMOKE_OFF_SUN := 0.5      # emit only when sun_a is below this; 0.5 == the dawn boundary,
                                # so smoke switches off at Harvest Dawn and back on at nightfall

## Should the sconce smoke be emitting right now? It's a night-only effect (the flame
## fully fades by day), so it runs only in full night and stops once day breaks.
func _smoke_on() -> bool:
	# The `particles` QoL feature (fx_particles folded in, like fx_lighting before it). This gate
	# covers the NIGHT plumes on sconces and standing torches; an on-fire object's smoke emits
	# unconditionally (see _place_light) and travels with the tiles3d bundle instead -- a real fire
	# smokes whether or not the viewer opted into ambience.
	return not Settings.qud_shape("particles") and _daylight < SMOKE_OFF_SUN

## Build the shared draw-mesh + process material once; every sconce's emitter reuses them
## (each GPUParticles3D still has its own seed, so plumes aren't in lockstep).
func _build_smoke_resources() -> void:
	# A flat grey square, billboarded — matches Qud's pixel smoke rather than a soft puff.
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX        # smoke tints, does NOT brighten (unlike the flame)
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.billboard_keep_scale = true
	sm.vertex_color_use_as_albedo = true                # let the color-ramp (below) drive colour+alpha
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Draw AFTER the walls, always. The live wall skin is ALPHA_DEPTH_PRE_PASS (the
	# cutaway fade), which puts the whole zone-sized merged wall mesh in the
	# transparent queue — and transparent-vs-transparent sort against a mesh that
	# big flips per frame, so smoke popped behind/in front of wall faces at block
	# corners ("flickering around the corners/edges"; measured: zero wall flicker
	# with particles off). A fixed priority makes the order deterministic; the
	# wall's pre-pass depth still occludes smoke that is genuinely behind it.
	sm.render_priority = 2
	_smoke_mesh = QuadMesh.new()
	_smoke_mesh.size = Vector2(SMOKE_SQUARE, SMOKE_SQUARE)
	_smoke_mesh.material = sm

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 6.0
	pm.initial_velocity_min = SMOKE_RISE * 0.8
	pm.initial_velocity_max = SMOKE_RISE * 1.15
	pm.gravity = Vector3.ZERO                            # no fall; the initial velocity carries it up
	pm.damping_min = 0.05
	pm.damping_max = 0.15                                # eases off near the top, like real smoke
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	# grow a little as it rises and thins
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.7))
	sc.add_point(Vector2(1.0, 1.6))
	var sct := CurveTexture.new(); sct.curve = sc
	pm.scale_curve = sct
	# oscillating x: noise-based turbulence gives an organic side-to-side sway
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = SMOKE_SWAY
	pm.turbulence_noise_scale = 1.2
	pm.turbulence_influence_min = 0.1
	pm.turbulence_influence_max = 0.25
	# grey, fading in from nothing and back out to nothing over the life
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.15, 0.7, 1.0])
	grad.colors = PackedColorArray([
		Color(0.72, 0.72, 0.75, 0.0),
		Color(0.68, 0.68, 0.72, 0.40),
		Color(0.55, 0.55, 0.60, 0.22),
		Color(0.45, 0.45, 0.50, 0.0)])
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	_smoke_pm = pm

const FIRE_AMOUNT := 12         # tongues alive per torch
const FIRE_AMOUNT_BIG := 22     # per campfire (wider base, same particle size)
const FIRE_LIFETIME := 0.65
const FIRE_RISE := 0.55
const FIRE_SQUARE := 0.075      # smaller squares than the smoke: pixel tongues

## PARTICLE FIRE — the smoke's sibling (Daniel: the drawn flame is "not
## on-theme... restore/port the particle fire from 1:1 mode; the smoke is
## great"). Same square-particle language as the smoke, but ADDITIVE on
## Qud's fire ramp: white-hot at birth, orange, red, gone — tongues taper
## as they rise. The 1:1 fire program (red embers / yellow tongues / grey
## smoke overlay quads) is top-down flatland; this is its 3D voice.
func _build_fire_resources() -> void:
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD        # fire BRIGHTENS (unlike the smoke)
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fm.billboard_keep_scale = true
	fm.vertex_color_use_as_albedo = true
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.render_priority = 2                               # after the walls (the smoke-sort rule)
	_fire_mesh = QuadMesh.new()
	_fire_mesh.size = Vector2(FIRE_SQUARE, FIRE_SQUARE)
	_fire_mesh.material = fm

	for big in [false, true]:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 8.0
		pm.initial_velocity_min = FIRE_RISE * 0.75
		pm.initial_velocity_max = FIRE_RISE * 1.2
		pm.gravity = Vector3.ZERO
		pm.damping_min = 0.1
		pm.damping_max = 0.3
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.14, 0.02, 0.14) if big else Vector3(0.05, 0.02, 0.05)
		pm.scale_min = 0.7
		pm.scale_max = 1.25
		var sc := Curve.new()                            # tongues TAPER as they rise
		sc.add_point(Vector2(0.0, 1.0))
		sc.add_point(Vector2(0.6, 0.7))
		sc.add_point(Vector2(1.0, 0.25))
		var sct := CurveTexture.new(); sct.curve = sc
		pm.scale_curve = sct
		pm.turbulence_enabled = true                     # a little lick, less than the smoke's sway
		pm.turbulence_noise_strength = 0.35
		pm.turbulence_noise_scale = 1.6
		pm.turbulence_influence_min = 0.05
		pm.turbulence_influence_max = 0.15
		var grad := Gradient.new()                       # Qud's fire ramp: W -> O -> r -> out
		grad.offsets = PackedFloat32Array([0.0, 0.22, 0.6, 1.0])
		grad.colors = PackedColorArray([
			Color(1.0, 0.92, 0.45, 0.95),
			Color(1.0, 0.55, 0.10, 0.85),
			Color(0.85, 0.16, 0.05, 0.55),
			Color(0.40, 0.05, 0.02, 0.0)])
		var gt := GradientTexture1D.new(); gt.gradient = grad
		pm.color_ramp = gt
		if big:
			_fire_pm_big = pm
		else:
			_fire_pm = pm

## One light's fire emitter (shares the resources above).
func _make_fire(big: bool) -> GPUParticles3D:
	if _fire_pm == null:
		_build_fire_resources()
	var p := GPUParticles3D.new()
	p.amount = FIRE_AMOUNT_BIG if big else FIRE_AMOUNT
	p.lifetime = FIRE_LIFETIME
	p.preprocess = FIRE_LIFETIME     # born mid-burn, not from a cold start
	p.randomness = 0.6
	p.process_material = _fire_pm_big if big else _fire_pm
	p.draw_pass_1 = _fire_mesh
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-0.6, -0.3, -0.6), Vector3(1.2, FIRE_RISE * FIRE_LIFETIME + 1.0, 1.2))
	return p

## One sconce's smoke emitter (shares the resources built above).
func _make_smoke() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = SMOKE_AMOUNT
	p.lifetime = SMOKE_LIFETIME
	p.preprocess = SMOKE_LIFETIME    # start mid-plume, not from an empty column
	p.randomness = 0.5
	p.process_material = _smoke_pm
	p.draw_pass_1 = _smoke_mesh
	p.local_coords = false           # particles keep rising in world space, not dragged by the node
	# a tall AABB so the plume isn't culled when the sconce base leaves the frustum
	p.visibility_aabb = AABB(Vector3(-1.0, -0.5, -1.0), Vector3(2.0, SMOKE_RISE * SMOKE_LIFETIME + 1.5, 2.0))
	return p

# --- glowfish orbiters ("bugs") ---------------------------------------------

const ORBIT_COUNT := 4          # motes per glowfish
const ORBIT_CENTER_Y := 0.5     # orbit centre height above the cell floor
const ORBIT_BASE_SPEED := 0.26  # rad/s; each mote's speed is this times a distinct prime
const ORBIT_PRIMES := [2, 3, 5, 7, 11, 13]   # prime speed ratios -> the cluster is slow to repeat

## Deterministic 0..1 from a glowfish cell + slot, so a fish's orbit params are stable
## across the per-step rebuilds (only changing when it actually swims to a new cell).
## Paired with a global-time angle in _process, this makes the rebuild invisible.
func _fish_rand(cx: int, cy: int, i: int, salt: int) -> float:
	return float(hash("%d,%d,%d,%d" % [cx, cy, i, salt]) % 100000) / 100000.0

## A cluster of glowing motes on tilted, elliptical, varied-speed orbits — "bugs circling
## in weird orbits". Positions are animated in _process; here we just spawn + seed them.
var _mote_mat: ShaderMaterial
var _mote_mesh: SphereMesh

## The motes are 3D ORBS, not flat billboards (Daniel: "I was hoping we could
## make them 3d orbs"). An unshaded sphere would read as a disc, so the form
## comes from two cues in the shader: limb darkening (bright core falling to
## a dim rim by NORMAL·VIEW) and a small specular highlight from the fixed
## interior sun — the same light the wall pockets use. Additive keeps the
## bioluminescent glow.
func _mote_material() -> ShaderMaterial:
	if _mote_mat != null:
		return _mote_mat
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never;
uniform vec3 core_col = vec3(0.65, 1.0, 0.85);
uniform vec3 rim_col = vec3(0.10, 0.45, 0.40);
void fragment() {
	float nd = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float core = pow(nd, 1.5);
	float hi = pow(clamp(dot(NORMAL, normalize(vec3(0.45, 0.8, 0.35))), 0.0, 1.0), 10.0);
	ALBEDO = mix(rim_col, core_col, core) + vec3(0.9) * hi * 0.5;
	ALPHA = 0.13 + 0.22 * core;   // ghostly: the water and fish read through the orb
}
"""
	_mote_mat = ShaderMaterial.new()
	_mote_mat.shader = sh
	return _mote_mat

func _make_orbiters(cx: int, cy: int) -> void:
	if _one_to_one:
		return   # 1:1: no particle motes — Qud draws only the glowfish tile
	if _mote_mesh == null:
		_mote_mesh = SphereMesh.new()
		_mote_mesh.radius = 0.028
		_mote_mesh.height = 0.056
		_mote_mesh.radial_segments = 12   # tiny orbs; no need for the default 64
		_mote_mesh.rings = 6
	var root := Node3D.new()
	root.position = Vector3(cx, ORBIT_CENTER_Y, cy)
	var motes: Array = []
	var fish_rot: float = _fish_rand(cx, cy, 0, 9) * TAU   # whole-cluster rotation, varies per fish
	for i in ORBIT_COUNT:
		var s := MeshInstance3D.new()
		s.mesh = _mote_mesh
		s.material_override = _mote_material()
		root.add_child(s)
		var prime: int = ORBIT_PRIMES[i % ORBIT_PRIMES.size()]
		motes.append({
			"s": s,
			"phase":  _fish_rand(cx, cy, i, 1) * TAU,
			# prime-ratio speeds: no two motes share a period, so the cluster is slow to repeat
			"speed":  ORBIT_BASE_SPEED * prime,
			"radius": 0.26 + _fish_rand(cx, cy, i, 3) * 0.20,
			"ellip":  0.35 + _fish_rand(cx, cy, i, 4) * 0.55,        # squash -> ellipse
			# each mote's orbit plane is rotated a distinct step apart (+ per-fish offset)
			"tilt":   fish_rot + float(i) * TAU / float(ORBIT_COUNT),
			"yamp":   0.10 + _fish_rand(cx, cy, i, 6) * 0.20,        # vertical bob amplitude
			"dir":    1.0,                                           # same sense; primes do the varying
		})
	_bank.add_child(root)   # into _dynamic_root (freed + rebuilt each step)
	_orbiters.append({"root": root, "motes": motes})

# --- glowfish bioluminescent glow -------------------------------------------

const GLOW_PAD := 1.5   # quad is this x the fish region, leaving a margin for the bloom

## The glow is an ADDITIVE billboarded quad over the fish. Its shader samples the fish
## texture (region-remapped so it matches the cropped sprite exactly) and outputs a cyan
## bloom: the fish body glows, plus a dilated halo around the silhouette, pulsing on TIME.
func _build_glow_shader() -> void:
	_glow_shader = Shader.new()
	_glow_shader.code = """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;
uniform sampler2D fish_tex : source_color, filter_nearest;
uniform vec2 uv_min = vec2(0.0);
uniform vec2 uv_size = vec2(1.0);
uniform float pad = 1.5;
uniform vec3 glow_color = vec3(0.4, 1.0, 0.85);
uniform float body_amt = 0.4;
uniform float body_tint = 0.22;
uniform float halo_amt = 1.0;
uniform float water_v = 1.0;
uniform float under_amt = 0.9;
uniform float flat_mode = 0.0;
uniform float halo_uv = 0.12;
uniform float strength = 1.3;
uniform float pulse_speed = 2.5;
uniform float y_lock = 1.0;
void vertex() {
	// billboard EXACTLY like the sprite this quad glows for: Y-LOCKED when the
	// sprite is (normal cameras), FULL in top-down. A full-billboard quad over
	// a Y-locked sprite gave two planes meeting on a horizontal line through
	// the shared centre — the far half lost the depth test against the
	// depth-writing sprite (Daniel's "cropped effect": glow below the line,
	// bare art above; a fixed nudge only MOVED the line, confirming the
	// mechanism). Parallel planes + a 4cm camera-ward tie-break = the whole
	// silhouette glows at every pitch; walls still occlude normally.
	mat4 sc = mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			   vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			   vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			   vec4(0.0, 0.0, 0.0, 1.0));
	if (flat_mode > 0.5) {
		// the flat underwater projection LIES on the water — no billboard
	} else if (y_lock > 0.5) {
		vec3 fwd = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
		vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
		MODELVIEW_MATRIX = VIEW_MATRIX
			* mat4(vec4(side, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(fwd, 0.0),
				   MODEL_MATRIX[3]) * sc;
	} else {
		MODELVIEW_MATRIX = VIEW_MATRIX
			* mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
				   MODEL_MATRIX[3]) * sc;
	}
	MODELVIEW_MATRIX[3].z += 0.04;
}
float fish_a(vec2 f) {
	if (f.x < 0.0 || f.x > 1.0 || f.y < 0.0 || f.y > 1.0) return 0.0;
	return texture(fish_tex, uv_min + f * uv_size).a;
}
void fragment() {
	vec2 f = (UV - vec2(0.5)) * pad + vec2(0.5);   // fish centred, margin for bloom
	float here = fish_a(f);
	vec3 fish_rgb = vec3(0.0);
	if (here > 0.0) fish_rgb = texture(fish_tex, uv_min + f * uv_size).rgb;
	float around = 0.0;
	for (int i = 0; i < 8; i++) {
		float ang = float(i) / 8.0 * 6.2831853;
		vec2 d = vec2(cos(ang), sin(ang)) * halo_uv;
		around += fish_a(f + d);
		around += fish_a(f + d * 0.5);
	}
	around /= 16.0;
	float halo = clamp(around - here, 0.0, 1.0);
	float pulse = 0.65 + 0.35 * sin(TIME * pulse_speed);
	// body: the fish's own colour boosted PLUS the glow-colour wash over the whole
	// silhouette (Daniel: the watery-glow look must cover the entire fish — without
	// the tint, only the part washed by the flat light POOL glowed, and the pool's
	// edge cut a camera-dependent line across the body). Additive keeps the art
	// readable underneath; halo: the crisp cyan outline. BELOW the waterline
	// (f.y > water_v) the sprite is submersion-cropped away — render the body
	// there as a DIFFUSE additive ghost (the dilated average, no crisp pixels):
	// the underwater half seen through the water instead of amputated.
	vec3 col;
	float a;
	if (flat_mode > 0.5) {
		// the submerged BODY projected flat on the water surface: the fish's
		// own pixels dimmed + a soft glow edge — readable through the water
		col = (fish_rgb * here * 0.85 + glow_color * around * 0.35) * under_amt;
		a = pulse * 0.8;
	} else if (f.y > water_v) {
		// the billboard stops at the waterline; the flat projection takes
		// over below it (a vertical quad under the terrain plane is occluded
		// by the ground — the first "diffuse ghost" was invisibly thin)
		col = vec3(0.0);
		a = 0.0;
	} else {
		col = fish_rgb * here * body_amt + glow_color * here * body_tint
			+ glow_color * halo * halo_amt;
		a = pulse;
	}
	ALBEDO = col * strength;
	ALPHA = a;
}
"""

## Hang the glow bloom over a glowfish sprite `s`, matched to its cropped region so the
## glowing shape lines up with the fish exactly.
func _add_glow(s: Sprite3D, tex: Texture2D, tile := "") -> void:
	# REPLACE, never stack: the sprite is pooled and re-seated across turns —
	# a bloom built for an earlier seat carries that seat's region (measured:
	# a full-band window twice the height of the submerged crop, the "cropped
	# effect" Daniel chased across three rounds). One bloom per placement,
	# always the placement's own geometry.
	for c in s.get_children():
		c.queue_free()
	var rr := s.region_rect if s.region_enabled else Rect2(0, 0, tex.get_width(), tex.get_height())
	# the quad covers the FULL art band even when the sprite is submersion-
	# cropped: the part below the waterline renders as a DIFFUSE glow ghost
	# seen through the water (Daniel: "we should see the bottom with a more
	# diffuse glow" — the crop amputated it). Bands align at the TOP (the crop
	# keeps the band's top rows), so the quad shifts down by half the cut.
	var full := rr
	if tile != "":
		var m := _mask(tile)
		if m != null:
			var vr := _opaque_v(m)
			var h := float(tex.get_height())
			full = Rect2(rr.position.x, vr.x * h, rr.size.x, maxf(vr.y * h, rr.size.y))
	var water_v: float = clampf(rr.size.y / full.size.y, 0.0, 1.0)
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	var mat := ShaderMaterial.new()
	mat.shader = _glow_shader
	mat.set_shader_parameter("fish_tex", tex)
	mat.set_shader_parameter("uv_min", Vector2(full.position.x / tw, full.position.y / th))
	mat.set_shader_parameter("uv_size", Vector2(full.size.x / tw, full.size.y / th))
	mat.set_shader_parameter("pad", GLOW_PAD)
	mat.set_shader_parameter("y_lock", 0.0 if _top_down else 1.0)
	mat.set_shader_parameter("water_v", water_v)
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(full.size.x * s.pixel_size, full.size.y * s.pixel_size) * GLOW_PAD
	q.mesh = qm
	q.material_override = mat
	# CHILD of the sprite, local origin: alignment BY CONSTRUCTION. A detached
	# quad snapshotting s.position drifted ~4 art rows below the fish (Daniel's
	# sharp horizontal line: sprite + offset bloom-copy overlapped below the
	# line, pale ghost past the tail) — sprites are POOLED and re-seated, and
	# any position applied after the snapshot leaves the quad behind. As a
	# child it follows every later move; _take_sprite clears it on reuse.
	q.position = Vector3(0.0, -(full.size.y - rr.size.y) * 0.5 * s.pixel_size, 0.0)
	s.add_child(q)
	# the submerged body, PROJECTED FLAT on the water like a refracted image
	# (Daniel: "I still can't see the bottom of the glowfish through the
	# water") — a horizontal quad just above the surface carrying the art
	# rows below the waterline. A vertical ghost cannot work: below the
	# waterline is below the TERRAIN plane in this flat-water model, so the
	# opaque depths quad swallowed it within half an art row.
	if water_v < 1.0:
		var under_h := full.size.y - rr.size.y
		var fmat2 := ShaderMaterial.new()
		fmat2.shader = _glow_shader
		fmat2.set_shader_parameter("fish_tex", tex)
		fmat2.set_shader_parameter("uv_min",
			Vector2(full.position.x / tw, (full.position.y + rr.size.y) / th))
		fmat2.set_shader_parameter("uv_size",
			Vector2(full.size.x / tw, under_h / th))
		fmat2.set_shader_parameter("pad", GLOW_PAD)
		fmat2.set_shader_parameter("flat_mode", 1.0)
		var fq := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(full.size.x * s.pixel_size, under_h * s.pixel_size) * GLOW_PAD
		fq.mesh = pm
		fq.material_override = fmat2
		# centred under the fish, a hair above the water surface (the sprite's
		# base IS the waterline: half the crop below the sprite centre)
		fq.position = Vector3(0.0, -rr.size.y * 0.5 * s.pixel_size + 0.012, 0.0)
		s.add_child(fq)

## Flicker: jitter each light's brightness a little every frame, so torches read
## as fire rather than steady lamps. Cheap — modulate the additive quads' alpha.
func _process(_dt: float) -> void:
	# The driver runs in BOTH modes, on BOTH registries. It was 1:1-only once, and then
	# ran in user mode over _anim_sprites alone — because _register_anim, which fills
	# _anim_items, was still gated to full_1to1. That gate is gone (see _rebuild_dynamics),
	# so user mode now has Qud's flashes, blinks, cycles and frame schedules as well, and
	# the condition has to notice the list they land in. Daniel: "let's fix the animations
	# in user mode", having watched himself burn in Qud while the Holodeck stood still.
	if _one_to_one or not _anim_sprites.is_empty() or not _anim_items.is_empty():
		_animate_1to1()          # Qud's per-frame render programs (blinks, flashes, sparkles)
	if _ib_active:
		_ib_step()               # advance the incremental live-static build one chunk per frame
	var gmul := _glow_mul()      # daylight dimming, recomputed once per frame
	var fmul := _flame_mul()
	for L in _lights:
		var e: float = 0.75 + randf() * 0.4        # 0.75..1.15
		L["energy"] = lerpf(L["energy"], e, 0.35)   # smoothed, so it shimmers not strobes
		var a: float = L["energy"]
		# a fire's pool is darkness-gated (off by day); a torch's follows the general daylight fade
		var g: float = _fire_glow_mul() if L.get("on_fire", false) else gmul
		(L["glow"] as MeshInstance3D).transparency = clampf(1.0 - a * g * 0.6, 0.0, 1.0)
		var fs: float = 0.9 + a * 0.25
		if L.get("particle_fire", false):
			# particle fire flickers through emission: speed jitters with the
			# energy, and daylight thins the tongue count (a campfire burns
			# full day + night — it's the daytime fire cue).
			var pf := L["flame"] as GPUParticles3D
			pf.speed_scale = 0.85 + a * 0.35
			var ratio: float = 1.0 if L.get("on_fire", false) else clampf(a * fmul, 0.0, 1.0)
			pf.amount_ratio = ratio
			pf.emitting = ratio > 0.03
		else:
			var flame := L["flame"] as Sprite3D
			flame.scale = Vector3(fs, fs * (0.95 + randf() * 0.2), fs)
			# transparency, NOT modulate: modulate is ignored under material_override (which the
			# flame has, for additive blend), so the flicker/daylight fade never reached the ball.
			# A drawn fire flame (alpha) stays fully visible day + night — it's the only daytime fire cue;
			# a torch flame (additive) still fades out by day.
			flame.transparency = 0.0 if L.get("on_fire", false) else clampf(1.0 - a * fmul, 0.0, 1.0)

	# Glowfish "bugs": drive each mote's local position from GLOBAL time, so a per-step
	# dynamic rebuild resumes the orbit exactly where it should be (no reset flicker).
	if not _orbiters.is_empty():
		var t := Time.get_ticks_msec() / 1000.0
		for O in _orbiters:
			for m in O["motes"]:
				var ang: float = t * m["speed"] * m["dir"] + m["phase"]
				var x: float = m["radius"] * cos(ang)
				var z: float = m["radius"] * m["ellip"] * sin(ang)
				var y: float = m["yamp"] * sin(ang * 2.0 + m["phase"])   # figure-8 bob -> "weird"
				var ct: float = cos(m["tilt"]); var st: float = sin(m["tilt"])
				(m["s"] as Node3D).position = Vector3(x * ct - z * st, y, x * st + z * ct)


func _is_prism(obj: Dictionary) -> bool:
	if _flat_2d:
		return false          # 2D: no 3D wall blocks — walls fall through to flat floor tiles
	# a user verdict wins outright — that's the point of filing one
	var ov := _override_for(String(obj.get("tile", "")))
	if ov == "wall":
		return true
	if ov != "":
		return false          # any other verdict means "not a block"
	# a solid, sight-blocking wall -> render as a 3D prism (rock, metal, brinestalk).
	if not (bool(obj.get("wall", false)) and bool(obj.get("occluding", false))):
		return false
	# ... UNLESS its art is a directional family (family_<dirs>). Tent walls are
	# `tent_nw`/`tent_ew` — the same connection-set naming as fences and pipes —
	# and they read as oriented panels, not blocks. They just happen to occlude.
	# So `occluding` doesn't decide panel-vs-prism; it decides the panel's HEIGHT.
	return _connector_dirs(String(obj.get("tile", ""))) == null

# Panel height: a tent wall is a fence at full height. Sight-blocking connectors
# stand wall-tall, see-through ones (picket fences, pipes) stay low.
## Is this object part of a directional family that should be laid along its axis?
##
## The `family_<dirs>` suffix alone is too weak a test on its own — a creature or
## item tile ending in `_e`/`_ne` would match by accident. This used to be gated on
## the WALL flag, which was safe but too narrow: axles (`sw_axle_2_ew`) are
## machinery, not walls, so they fell through to a billboard and lay across their
## own run instead of along it.
##
## Wall-flagged objects still qualify outright. Anything else must ALSO have its
## family's east-west sibling on disk — a real directional family ships one, an
## incidental name collision does not.
func _is_connector(obj: Dictionary, tile: String) -> bool:
	if _connector_dirs(tile) == null:
		return false
	if bool(obj.get("wall", false)):
		return true
	return _mask(_family_ew(tile)) != null

## Rows of art a standard fence panel occupies; FENCE_H is calibrated to this, so
## thinner families scale down from it rather than stretching to fill it.
const PANEL_REF_ROWS := 10.0

func _panel_height(obj: Dictionary, tile: String) -> float:
	if bool(obj.get("occluding", false)):
		return WALL_H          # sight-blocking: tent walls stand full height
	# Scale to the art. An axle is 2 opaque rows; stretching that to a fence's
	# 0.6 would smear a thin shaft into a tall band.
	var img := _mask(_panel_art(tile))
	if img == null:
		return FENCE_H
	var rows: float = _opaque_v(img).y * img.get_height()
	if rows <= 0.0:
		return FENCE_H
	return maxf(0.05, FENCE_H * rows / PANEL_REF_ROWS)

## The art a panel should actually draw.
##
## Directional families (fence_ns, pipe_ne, tent_nw) all use their `_ew` elevation
## so every segment of a run reads consistently. But a tile forced onto the panel
## path by a USER VERDICT need not belong to such a family at all: `sw_waterwheel_1`
## has no `sw_waterwheel_ew` sibling, so asking for one yielded a null mask and the
## material fell back to a solid colour — a flat rectangle where the wheel should
## be. Fall back to the tile's own art when the family variant doesn't exist.
func _panel_art(tile: String) -> String:
	var ew := _family_ew(tile)
	return ew if _mask(ew) != null else tile

# A "family_<dirs>" tile (fence_ns, ironfence_ew, pipe_ne, bare fence_) is a
# directional connector. Returns the dirs string ("", "ns", "ew", "ne"...) or null.
func _connector_dirs(tile: String):
	var base := tile.get_file()
	var dot := base.rfind(".")
	if dot >= 0:
		base = base.substr(0, dot)
	var us := base.rfind("_")
	if us < 0:
		return null
	var suf := base.substr(us + 1)
	if suf.length() > 4:
		return null
	for ch in suf:
		if not "nsew".contains(ch):
			return null
	return suf

# The family's east-west (elevation) variant, used for every orientation so all
# segments read as consistent standing panels (option 1).
func _family_ew(tile: String) -> String:
	var us := tile.rfind("_")
	var dot := tile.rfind(".")
	if us < 0 or dot < 0 or dot < us:
		return tile
	return tile.substr(0, us + 1) + "ew" + tile.substr(dot)

const DOOR_DEPTH_PX := 3.0    # slab thickness in art pixels (Daniel's spec)
const DOOR_JAMB_PX := 1.0     # wall continuing into the doorway at each end
var _zone_wall_cells := {}    # cell -> wall variant, stashed per static build
# cell -> the STATIC door's nodes. Doors change state (open/close) but bake
# into the static pass — the live zone's dynamic pass hides the static pair
# and redraws the door from the CURRENT wire state each turn (Daniel: "you
# can walk through it, but it looks closed" — the bake predated the open).
# Same pattern as the creature winner-visibility registry.
var _door_static := {}

## Is this tile a door? Family-name test (sw_door_*, security doors, ...);
## the report form's "door" verdict can force or override it per family.
func _is_door(tile: String) -> bool:
	return tile_family(tile).contains("door")

## Which way does a door span? The axis with MORE adjacent walls wins: a
## door in an E-W run has walls east+west and spans E-W (its faces look
## N/S). Pairs beat singles, singles beat none, and ties go E-W — a door
## continues its run, whatever its art claims.
func _door_span_ew(cx: int, cy: int) -> bool:
	var e := int(_zone_wall_cells.has(Vector2i(cx + 1, cy)))
	var w := int(_zone_wall_cells.has(Vector2i(cx - 1, cy)))
	var n := int(_zone_wall_cells.has(Vector2i(cx, cy - 1)))
	var s := int(_zone_wall_cells.has(Vector2i(cx, cy + 1)))
	return e + w >= n + s

## A door as a voxel slab set into its wall run: a 14px panel, DOOR_DEPTH_PX
## deep, wearing the door art on BOTH faces (each reading unmirrored — the
## twin-slab rule), edge/top trim + 1px full-depth jambs in the art's own
## frame colour (the signpost edge-sampling pattern). Height = WALL_H: a
## derived shape that REPLACES a wall sizes against the wall, not art px.
func _place_door(tile: String, main_c: String, detail_c: String, cx: int, cy: int, idx: int, light_frac: float, closed := false) -> void:
	# ONE door, two poses (Daniel: "the open door [is] the same as the closed
	# door, but the door rotates on the hinge"): the slab always wears the
	# CLOSED art, opaque (the _open art is a hole — we want the door ITSELF).
	# Closed: in the wall plane. Open: the same slab swung 90 degrees on its
	# hinge jamb, standing perpendicular to the frame; the jambs stay put.
	var art_tile := tile
	if not closed:
		var ct := tile.replace("_open", "")
		if _mask(ct) != null:
			art_tile = ct
	var btex := _colored_tex(art_tile, main_c, detail_c, Fill.ALL)
	var mask := _mask(art_tile)
	if btex == null or mask == null:
		return
	var img := btex.get_image()
	var vr := _opaque_v(mask)
	var ew := _door_span_ew(cx, cy)
	var ps := 1.0 / 16.0
	var hw := (8.0 - DOOR_JAMB_PX) * ps          # panel half-width: 14px span
	var hd := DOOR_DEPTH_PX * 0.5 * ps
	# panel pose: closed lies along the wall span, centred; open lies along
	# the PERPENDICULAR axis, hinged at the span-negative jamb and swinging
	# to the positive side (south of an E-W wall, east of an N-S wall)
	var pew := ew if closed else not ew
	var poff := Vector3.ZERO
	if not closed:
		# hinged INSIDE the jamb: the slab sits flush against the jamb's inner
		# face (+hd inward), never crossing the cell edge into the neighbour
		# wall (Daniel: "the open door is overlapping the tile wall next to it")
		poff = Vector3(-hw + hd, 0.0, hw) if ew else Vector3(hw, 0.0, -hw + hd)
	var u0 := 1.0 / 16.0                          # art cols 1..14 on the panel;
	var u1 := 15.0 / 16.0                         # the edge columns live in the jambs
	var v0: float = vr.x
	var v1: float = vr.x + vr.y
	var lf := clampf(light_frac, 0.0, 1.0)
	var midv := int(clampf((v0 + v1) * 0.5, 0.0, 0.999) * img.get_height())
	var edge := img.get_pixel(0, midv)
	if edge.a < 0.5:
		edge = _qud_color(main_c).darkened(0.2)
	var trim_c := Color(edge.r * lf, edge.g * lf, edge.b * lf)

	# textured faces: both sides of the slab, art unmirrored on each
	var stf := SurfaceTool.new()
	stf.begin(Mesh.PRIMITIVE_TRIANGLES)
	# a: along the span (x for EW, z for NS); d: across the depth
	var face_quads := [[+1, false], [-1, true]]   # [depth sign, u reversed]
	var face_corners: Array = [[0, 0], [1, 0], [1, 1], [0, 0], [1, 1], [0, 1]]
	for fq in face_quads:
		var dsign: int = fq[0]
		var urev: bool = fq[1]
		for i in 6:
			var corner: Array = face_corners[i]
			var ua: float = float(corner[0])       # 0..1 along the span
			var vy: float = float(corner[1])       # 0..1 up the door
			var a: float = lerpf(-hw, hw, ua if dsign > 0 else 1.0 - ua)
			var y: float = vy * WALL_H
			var p := (Vector3(a, y, dsign * hd) if pew else Vector3(dsign * hd, y, a)) + poff
			var un := lerpf(u0, u1, (1.0 - ua) if urev else ua)
			stf.set_normal((Vector3(0, 0, dsign) if pew else Vector3(dsign, 0, 0)))
			stf.set_uv(Vector2(un, lerpf(v1, v0, vy)))
			stf.add_vertex(p)
	var fmesh := ArrayMesh.new()
	stf.commit(fmesh)
	var fmi := MeshInstance3D.new()
	fmi.mesh = fmesh
	var fmat: StandardMaterial3D = _mesh_material(art_tile, main_c, detail_c, btex).duplicate()
	fmat.albedo_color = Color(lf, lf, lf)         # per-instance dim (the fence idiom)
	fmi.material_override = fmat
	fmi.position = Vector3(cx, 0, cy)
	_spawn_parent().add_child(fmi)
	_track(fmi)

	# trim: panel end strips + top cap + the two jambs (vertex-coloured)
	var stt := SurfaceTool.new()
	stt.begin(Mesh.PRIMITIVE_TRIANGLES)
	var boxes := [
		# [a0, a1, d0, d1, y0, y1] in the PANEL's span/depth/up space
		[-hw, -hw, -hd, hd, 0.0, WALL_H, -1],     # panel-end strip (plane)
		[hw, hw, -hd, hd, 0.0, WALL_H, 1],        # other end strip
		[-hw, hw, -hd, hd, WALL_H, WALL_H, 0],    # top cap (plane)
	]
	for b in boxes:
		_door_trim_quad(stt, b, pew, trim_c, poff)   # trim follows the panel's pose
	for js in [-1, 1]:
		# jamb: 1px along the span, IN the frame's plane (same 3px depth),
		# reaching the cell edge — the door extends planarly to its walls,
		# never a perpendicular full-depth cap (Daniel's report). Jambs stay
		# in the WALL plane in both poses; only the panel swings.
		var a0: float = js * hw
		var a1: float = js * 0.5
		_door_trim_box(stt, a0, a1, -hd, hd, 0.0, WALL_H, ew, trim_c)
	var tmesh := ArrayMesh.new()
	stt.commit(tmesh)
	var tmi := MeshInstance3D.new()
	tmi.mesh = tmesh
	tmi.material_override = _wall_skin_material()
	tmi.position = Vector3(cx, 0, cy)
	_spawn_parent().add_child(tmi)
	_track(tmi)
	if _live_build:
		_door_static[Vector2i(cx, cy)] = [fmi, tmi]   # dynamics hide + redraw per turn
	_note(cx, cy, idx, "door slab %s (%dpx deep, %dpx jambs) walls e%d w%d n%d s%d" % [
		"E-W" if ew else "N-S", int(DOOR_DEPTH_PX), int(DOOR_JAMB_PX),
		int(_zone_wall_cells.has(Vector2i(cx + 1, cy))),
		int(_zone_wall_cells.has(Vector2i(cx - 1, cy))),
		int(_zone_wall_cells.has(Vector2i(cx, cy - 1))),
		int(_zone_wall_cells.has(Vector2i(cx, cy + 1)))], WALL_H * 0.5)

func _door_trim_quad(st: SurfaceTool, b: Array, ew: bool, c: Color, off := Vector3.ZERO) -> void:
	# one plane: a-extent [b0,b1], depth [b2,b3], y [b4,b5]; b6 = normal hint
	var quads := []
	if b[4] == b[5]:      # horizontal cap
		quads = [[Vector3(b[0], b[4], b[2]), Vector3(b[1], b[4], b[2]),
			Vector3(b[1], b[4], b[3]), Vector3(b[0], b[4], b[3])]]
	else:                 # vertical end strip at a = b0 (== b1)
		quads = [[Vector3(b[0], b[4], b[2]), Vector3(b[0], b[4], b[3]),
			Vector3(b[0], b[5], b[3]), Vector3(b[0], b[5], b[2])]]
	for q in quads:
		for i in [0, 1, 2, 0, 2, 3]:
			var p: Vector3 = q[i]
			if not ew:
				p = Vector3(p.z, p.y, p.x)
			st.set_color(c)
			st.set_normal(Vector3.UP)
			st.add_vertex(p + off)

func _door_trim_box(st: SurfaceTool, a0: float, a1: float, d0: float, d1: float, y0: float, y1: float, ew: bool, c: Color) -> void:
	# a box in span/depth/up space: 4 sides + top (bottom sits on the ground)
	var lo := minf(a0, a1)
	var hi := maxf(a0, a1)
	var corners := [
		[Vector3(lo, y0, d0), Vector3(hi, y0, d0), Vector3(hi, y1, d0), Vector3(lo, y1, d0)],
		[Vector3(hi, y0, d1), Vector3(lo, y0, d1), Vector3(lo, y1, d1), Vector3(hi, y1, d1)],
		[Vector3(lo, y0, d1), Vector3(lo, y0, d0), Vector3(lo, y1, d0), Vector3(lo, y1, d1)],
		[Vector3(hi, y0, d0), Vector3(hi, y0, d1), Vector3(hi, y1, d1), Vector3(hi, y1, d0)],
		[Vector3(lo, y1, d0), Vector3(hi, y1, d0), Vector3(hi, y1, d1), Vector3(lo, y1, d1)],
	]
	for q in corners:
		for i in [0, 1, 2, 0, 2, 3]:
			var p: Vector3 = q[i]
			if not ew:
				p = Vector3(p.z, p.y, p.x)
			st.set_color(c)
			st.set_normal(Vector3.UP)
			st.add_vertex(p)

func _place_connector(tile: String, main_c: String, detail_c: String, cx: int, cy: int, dirs: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0, light_frac := 1.0, anim := "") -> void:
	# A JUNCTION in a shaft family is a gearbox, not two shafts crossing: Qud's _se art is a
	# housing (rows 6-12) with stubs leaving east and south, not an L of bare axle. Straight
	# runs stay shafts; anything that turns or branches gets the box.
	if _connector_is_prism(tile) and _conduit_is_junction(dirs):
		_place_conduit_box(tile, main_c, detail_c, cx, cy, dirs, fill, y_center, light_frac, anim)
		return
	if dirs == "":
		_fence_half(cx, cy, "post", tile, main_c, detail_c, h, fill, y_center, light_frac, anim)
		return
	for d in dirs:
		_fence_half(cx, cy, d, tile, main_c, detail_c, h, fill, y_center, light_frac, anim)

# One upright half-panel from the cell centre out to the edge in direction d, using
# the family's E-W elevation art. Adjacent cells' halves meet at the shared edge,
# so runs are continuous and corners form a clean L. Used for every directional
# family: picket fences, pipes, and tent walls (which differ only in height).
func _fence_half(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0, light_frac := 1.0, anim := "") -> void:
	if _connector_is_prism(tile):
		_fence_half_prism(cx, cy, d, tile, main_c, detail_c, h, fill, y_center, light_frac, anim)
		return
	var vox_d := _connector_vox_depth(tile)
	if vox_d > 0:
		_fence_half_vox(cx, cy, d, tile, main_c, detail_c, h, fill, y_center, light_frac, vox_d)
		return
	var mi := _take_fence()
	var half := "r" if (d == "e" or d == "s") else "l"
	# Per-INSTANCE material (a shallow dup — texture is shared) so this panel can be dimmed
	# by its cell's light without touching the cached one every fence shares. albedo_color
	# multiplies the texture, so Color(lf,lf,lf) darkens it. Re-lit each turn for the live
	# zone (tracked below); baked once for frozen neighbours.
	var fm: StandardMaterial3D = _fence_material(_panel_art(tile), main_c, detail_c, half, fill).duplicate()
	fm.albedo_color = Color(light_frac, light_frac, light_frac)
	mi.material_override = fm
	if _live_build:
		_lit_meshes.append({"mi": mi, "cell": Vector2i(cx, cy)})
		# A multi-frame PANEL (Joppa's water wheel: shape=ORIENTED PANEL, so it never
		# touches the billboard path _register_sprite_anim hooks). Only the texture
		# swaps — the material keeps its own uv1 crop and the half's offset, so the
		# frame lands in exactly the same window as the base.
		_register_panel_anim(anim, fm, _panel_art(tile), main_c, detail_c, fill)
	mi.scale = Vector3(0.5, h, 1.0)
	var pos := Vector3(cx, (y_center if y_center >= 0.0 else h * 0.5), cy)
	var rot := 0.0
	match d:
		"e": pos.x += 0.25
		"w": pos.x -= 0.25
		"n":
			pos.z -= 0.25
			rot = 90.0
		"s":
			pos.z += 0.25
			rot = 90.0
		_: pass  # post: centred, faces south
	mi.rotation_degrees = Vector3(0, rot, 0)
	mi.position = pos
	mi.visible = true
	_track(mi)

## Which connector families build as VOXELS, and HOW THICK. Not one predicate, because
## the families are not one shape: a wire is a CABLE and gets ONE block, where a fence or
## a pipe gets two. Measured off the art before widening this (tools/capture/voxpreview.py
## renders the volume straight from a tile): a wire half is 32 voxels in EIGHT
## face-disconnected pieces — the art is a dashed zigzag that only reads continuous in 2D —
## and at two blocks deep it comes out a chain of dice rather than a cable. Axles stay on
## the quad path; nobody has asked and their art is three bare bars.
const VOX_CONNECTORS := {"fence": 2, "pipe": 2, "wire": 1}

## What the inspector should SAY this connector was built as. The report is the only
## first-party account of what the renderer did, so it has to track the builder: the tent
## note still read "pole cylinder + skin half-slabs" for a whole session after the tents
## became voxels, which is a comment that lies with extra steps.
func _connector_note(tile: String) -> String:
	var d := _connector_vox_depth(tile)
	return "voxel %d deep" % d if d > 0 else "flat quad"


## Blocks of thickness for this connector, or 0 to keep the flat quad.
func _connector_vox_depth(tile: String) -> int:
	if _one_to_one or _flat_2d or _world_map:
		return 0
	for k in VOX_CONNECTORS:
		if tile.contains(k):
			return int(VOX_CONNECTORS[k])
	return 0


## One connector half-panel as VOXELS: a block per opaque art pixel, `depth` blocks
## deep, faces only where the neighbour block is absent (_vox_block). It keeps every
## convention of the quad path it replaces, which is what makes runs still line up:
## cell A's "e" half carries art columns 8..15 and B's "w" half carries 0..7, so a run
## reproduces the full 16-wide elevation across the shared edge and the two halves abut
## with their facing blocks BURIED — the seam closes itself, exactly as the tent's does.
## Light stays live: the face shade is baked into the vertex colours, but light_frac
## rides on a per-instance material's albedo_color (which multiplies vertex colour), so
## the panel re-lights per turn through _lit_meshes like the quads did.
func _fence_half_vox(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String,
		h: float, fill: int, y_center: float, light_frac: float, depth: int) -> void:
	var art := _panel_art(tile)
	var mask := _mask(art)
	if mask == null:
		return
	var tex := _colored_tex(art, main_c, detail_c, fill)
	if tex == null:
		return
	var img := tex.get_image()
	var w := mask.get_width()
	var mh := mask.get_height()
	if w < 2 or mh < 1:
		return
	var sx: float = img.get_width() / float(w)
	var sy: float = img.get_height() / float(mh)
	# Vertical crop to the RAW mask's opaque band. Measured on the mask, not the
	# coloured texture, for the same reason the quad path does it: under Fill.ALL every
	# pixel is opaque and the art's empty padding would become slab.
	var top := -1
	var bot := -1
	for y in mh:
		var any_px := false
		for x in w:
			if mask.get_pixel(x, y).a >= 0.5:
				any_px = true
				break
		if any_px:
			if top < 0:
				top = y
			bot = y
	if top < 0:
		return
	var hw: int = w / 2
	var ny: int = bot - top + 1
	var pw: float = 0.5 / float(hw)          # one art px along the run
	var phh: float = h / float(ny)
	var yc: float = y_center if y_center >= 0.0 else h * 0.5
	var y0: float = yc - h * 0.5
	# Which half of the elevation, and where its first column sits — the quad path's
	# convention (E-half for e AND s, W-half for w AND n) so corners join as an L.
	var is_ew: bool = d == "e" or d == "w"
	var is_ns: bool = d == "n" or d == "s"
	var right_half: bool = d == "e" or d == "s"
	var u0: int = hw if right_half else 0
	var a0: float = 0.0 if right_half else -0.5
	if not is_ew and not is_ns:
		u0 = 0                                # a lone POST: centred, art's left half
		a0 = -0.25
	var solid := {}
	for j in range(top, bot + 1):
		for k in hw:
			var c := img.get_pixel(int((u0 + k + 0.5) * sx), int((j + 0.5) * sy))
			if c.a < 0.5:
				continue
			for dz in depth:
				solid[Vector3i(k, j, dz)] = c
	if solid.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_d: float = depth * pw * 0.5
	for key in solid:
		var v: Vector3i = key
		var a: float = a0 + v.x * pw                    # along the run, from the cell centre
		var yy: float = y0 + (bot - v.y) * phh          # world +Y is the PREVIOUS art row
		var dep: float = -half_d + v.z * pw             # across it
		var o: Vector3
		if is_ns:
			o = Vector3(cx + dep, yy, cy + a)
		else:
			o = Vector3(cx + a, yy, cy + dep)
		var size := Vector3(pw, phh, pw)   # square section: one art px each way
		# neighbours: the run axis is X for e/w/post and Z for n/s, so the -X/+X flags
		# follow the ART columns and the -Z/+Z flags follow depth (and swap for N-S).
		var oa := not solid.has(v + Vector3i(-1, 0, 0))
		var ob := not solid.has(v + Vector3i(1, 0, 0))
		var oy0 := not solid.has(v + Vector3i(0, 1, 0))
		var oy1 := not solid.has(v + Vector3i(0, -1, 0))
		var od0 := not solid.has(v + Vector3i(0, 0, -1))
		var od1 := not solid.has(v + Vector3i(0, 0, 1))
		if is_ns:
			_vox_block(st, o, size, solid[key], [od0, od1, oy0, oy1, oa, ob])
		else:
			_vox_block(st, o, size, solid[key], [oa, ob, oy0, oy1, od0, od1])
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var fm: StandardMaterial3D = _vox_skin_material().duplicate()
	fm.albedo_color = Color(light_frac, light_frac, light_frac)
	mi.material_override = fm
	_spawn_parent().add_child(mi)
	if _live_build:
		_lit_meshes.append({"mi": mi, "cell": Vector2i(cx, cy)})
	_track(mi)


## Frame-swap registration for a connector PANEL. Same schedule and same clock as
## _register_sprite_anim; the difference is where the frame goes — a panel is a quad
## wearing a material, so the frame is the material's albedo_texture, not a sprite's
## texture. Swapping only the texture keeps the material's uv1_scale/offset, which is
## what crops the art to the opaque band and picks the left/right half.
func _register_panel_anim(anim: String, fm: StandardMaterial3D, base_tile: String,
		main_c: String, detail_c: String, fill: int, phase := 0) -> void:
	if anim == "" or fm == null:
		return
	var parts := anim.split("|")
	if parts.size() < 3:
		return
	var alen := maxi(int(parts[0]), 1)
	var sched: Array = []
	var any_tile := false
	for i in range(1, parts.size()):
		var kv := parts[i].split("=")
		if kv.size() != 2:
			continue
		var axes := String(kv[1]).split(";")
		var ftile := String(axes[0]) if axes.size() > 0 else ""
		var tex: Texture2D = fm.albedo_texture
		if ftile != "" and ftile != base_tile:
			var ft := _colored_tex(ftile, main_c, detail_c, fill)
			if ft != null:
				tex = ft
				any_tile = true
		sched.append({"f": int(kv[0]), "tex": tex})
	if any_tile and sched.size() > 1:
		_anim_sprites.append({"mat": fm, "len": alen, "sched": sched, "phase": phase})


## The same tile with its frame digit swapped ("…sw_axle_1_ew.png" -> _2_, _3_). Qud builds
## these names in a StringBuilder from tags; substituting the digit is how the mod finds the
## cycle too, and it keeps both sides agreeing on what a frame is called.
func _conduit_frame_tile(tile: String, digit: int) -> String:
	var at := -1
	for i in range(tile.length() - 1):
		if tile[i] == "_" and tile[i + 1] >= "1" and tile[i + 1] <= "9" \
				and (i + 2 >= tile.length() or not (tile[i + 2] >= "0" and tile[i + 2] <= "9")):
			at = i + 1
	if at < 0:
		return tile
	return tile.substr(0, at) + str(digit) + tile.substr(at + 1)


## Rows of housing carried above the axle opening, so the gearbox is not just a collar.
const BOX_ABOVE := 3

## Voxels the housing is pulled in on each cardinal side, past the lip-matching width
## (Daniel: "Pull the gearbox in by 1px in all cardinal directions"). Deliberately makes the
## side lip one column narrower than the top lip: the side faces are seen at a slant, so a
## lip that measures equal reads heavier than the top one.
const BOX_INSET := 1

## The housing's footprint in voxels for a shaft of `srows` section. ONE definition, because
## two things need it and they must agree: the gearbox sizes itself by it, and the SHAFT
## works out from it how far to reach so its end lands inside the recess rather than stopping
## at the cell boundary. `jw` is the art's width in columns.
func _gearbox_span(srows: int, jw: int) -> int:
	var vlen: float = 1.0 / float(jw)
	var hole_w: int = mini(srows * 2, jw - 2)
	# top lip and side lip matched in WORLD units (a row is PIXEL_SIZE, a column is 1/jw),
	# then pulled in by BOX_INSET
	var lip: int = maxi(1, int(round(BOX_ABOVE * PIXEL_SIZE / vlen)) - BOX_INSET)
	return hole_w + 2 * lip

## How much SLOWER the beam turns than Qud steps its frames. Qud's cadence is a revolution a
## second, which is right for three flat frames flicking past and far too fast for a solid
## beam actually turning — the eye reads the frames as texture, the rotation as a machine
## (Daniel: "slow down the axle spin rate by 10"). One turn per ten seconds.
const AXLE_SPIN_SLOW := 10.0

## The ROOF VANE's slow factor — half the shafts', and not a taste call. The vane is a LINE,
## and a line has 180-degree symmetry, so one trip through the art's three frames is half a
## revolution rather than a whole one. Slowing it by the shafts' factor therefore spun it at
## half their rate (Daniel: "I would double the speed"); halving the factor puts every moving
## part of the machine on the same rotational speed.
const VANE_SPIN_SLOW := AXLE_SPIN_SLOW * 0.5


## Is this connector a junction — anything that is not a straight run? "ew"/"ns" carry
## straight through and stay shafts; a corner, tee or cross is a gearbox.
func _conduit_is_junction(dirs: String) -> bool:
	if dirs.length() < 2:
		return false
	var has_ew: bool = dirs.contains("e") or dirs.contains("w")
	var has_ns: bool = dirs.contains("n") or dirs.contains("s")
	if dirs.length() == 2 and ((dirs.contains("e") and dirs.contains("w")) or (dirs.contains("n") and dirs.contains("s"))):
		return false
	return has_ew and has_ns or dirs.length() > 2


## The vane's 3x3 grid, MEASURED off the art: the line's own width at the housing's centre
## row, scaled from the art's housing width onto the voxel footprint. Returns (cell, offset).
##
## Splitting the footprint into equal thirds instead — which is the obvious thing to write and
## is wrong — gives a vane twice the width the art draws and leaves it no margin at all. The
## art's line is 2 of the housing's 10 columns and its three positions cover 6 of them, so the
## grid is 6 wide inside a 10-wide roof with 2 columns spare on each side. Daniel's structure
## (a 3x3 with the pattern rotating around it) was right; the cell size had to come from the
## art, not from dividing by three.
func _vane_grid(ftile: String, btop: int, bbot: int, x0: int, x1: int, n: int) -> Vector2i:
	var cell := 1
	var m := _mask(ftile)
	if m != null:
		var rc: int = int((btop + bbot) * 0.5)
		var wid := 0
		for x in range(x0, x1 + 1):
			if m.get_pixel(x, rc).a < 0.5:
				wid += 1
		if wid > 0:
			cell = maxi(1, int(round(float(wid) * float(n) / float(x1 - x0 + 1))))
	cell = mini(cell, maxi(1, n / 3))
	return Vector2i(cell, int((n - 3 * cell) / 2))


## Which way the roof's vane lies in THIS frame, read off the art rather than assumed: the mean
## column of the transparent line one row above centre versus one row below. +1 leans the way
## the art's "\" does (column grows with row, i.e. x grows with z), -1 the other, 0 straight
## along z. The art shows 3 of the 4 orientations a line can take on a 3x3 — never the
## horizontal — so this reports what is drawn and invents no fourth frame.
func _gearbox_vane_dir(ftile: String, btop: int, bbot: int, x0: int, x1: int) -> int:
	var m := _mask(ftile)
	if m == null:
		return 0
	var rc: int = int((btop + bbot) * 0.5)
	var mean := []
	for r in [rc - 1, rc + 1]:
		if r < 0 or r >= m.get_height():
			return 0
		var tot := 0.0
		var n := 0
		for x in range(x0, x1 + 1):
			if m.get_pixel(x, r).a < 0.5:
				tot += x
				n += 1
		if n == 0:
			return 0
		mean.append(tot / float(n))
	var d: float = float(mean[1]) - float(mean[0])
	if absf(d) < 0.5:
		return 0
	return 1 if d > 0.0 else -1


## The footprint voxels the vane covers, as a set of (ax, az) — the centre band cell plus the
## two opposite corner/edge cells its orientation picks out of the 3x3.
func _vane_cells(vdir: int, cell: int, off: int) -> Dictionary:
	var pairs: Array = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)]
	if vdir > 0:
		pairs = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]
	elif vdir < 0:
		pairs = [Vector2i(2, 0), Vector2i(1, 1), Vector2i(0, 2)]
	var out := {}
	for pr in pairs:
		var bc: Vector2i = pr
		for ax in range(off + bc.x * cell, off + (bc.x + 1) * cell):
			for az in range(off + bc.y * cell, off + (bc.y + 1) * cell):
				out[Vector2i(ax, az)] = true
	return out


## The gearbox at a shaft junction: a solid brown prism spanning the cell, with a HOLE in
## each face a shaft arrives at (Daniel: "a brown rectangular prism with a 'hole' on the
## south and east sides. The hole is just 1 layer of the face cutout and the core is the
## default background color. It will appear as if the axels are going into darkness").
##
## The hole is exactly that: the outer layer of voxels inside the shaft's cross-section is
## omitted, and the layer behind it is painted the cell background, so the opening reads as
## depth rather than as a dark decal. The box spans the FULL cell so the neighbouring
## half-shafts — which run to the shared edge — meet its face with no gap, the same
## abutment rule the shafts themselves now follow.
##
## Footprint is on the CELL's scale and thickness on the ART's, matching _fence_half_prism.
## The housing's height comes from the junction art's own box band. The spinny interior is
## not modelled yet; this is the basic geometry.
func _place_conduit_box(tile: String, main_c: String, detail_c: String, cx: int, cy: int,
		dirs: String, fill: int, y_center: float, light_frac: float, anim: String) -> void:
	var art := _panel_art(tile)
	var jmask := _mask(tile)          # the JUNCTION art, not the straight canon
	if jmask == null:
		return
	var jw := jmask.get_width()
	var jh := jmask.get_height()
	# the housing = the widest contiguous run of rows (the stubs are narrow)
	var wide := int(ceil(jw * 0.5))
	var btop := -1
	var bbot := -1
	for y in jh:
		var n := 0
		for x in jw:
			if jmask.get_pixel(x, y).a >= 0.5:
				n += 1
		if n >= wide:
			if btop < 0:
				btop = y
			bbot = y
		elif btop >= 0:
			break
	if btop < 0:
		return
	# the housing's column span — the window the vane is read from, and solid across row btop
	var hx0 := -1
	var hx1 := -1
	for x in jw:
		if jmask.get_pixel(x, btop).a >= 0.5:
			if hx0 < 0:
				hx0 = x
			hx1 = x
	# the shaft's own section, from the straight canon — the hole must match what arrives
	# The hole must match the shaft that ARRIVES, and the straight variant's frames are not
	# all the same height (_2 is a 2-row band where _1 and _3 are 4). Reading whichever one
	# _panel_art resolves to gave a 2x2 hole in a 16-wide face — invisible. Take the WIDEST
	# band across the cycle's frames, which is the section _fence_half_prism actually builds.
	# Third time this canonical-frame rule has bitten; it is in docs/gotchas.md now.
	var srows := 0
	for dgt in range(1, 10):
		var cand := _conduit_frame_tile(art, dgt)
		var cmask := _mask(cand)
		if cmask == null:
			continue
		var ct := -1
		var cb := -1
		for y in cmask.get_height():
			for x in cmask.get_width():
				if cmask.get_pixel(x, y).a >= 0.5:
					if ct < 0:
						ct = y
					cb = y
					break
		if ct >= 0:
			srows = maxi(srows, cb - ct + 1)
	if srows <= 0:
		srows = 4
	var tex := _colored_tex(tile, main_c, detail_c, Fill.ALL)
	if tex == null:
		return
	var img := tex.get_image()
	var sxr: float = img.get_width() / float(jw)
	var syr: float = img.get_height() / float(jh)
	var brown := img.get_pixel(int((jw * 0.5) * sxr), int((btop + 0.5) * syr))
	# The darkness inside the hole is the SAME background Fill.ALL paints, taken from the
	# texture itself (a corner pixel lies outside the art, so it is pure fill). Asking
	# _wall_bg_color() instead returns the wall gap-fill colour, which is a different
	# question and came back close enough to the wood that the recess was invisible.
	var dark := img.get_pixel(0, 0)
	if dark.a < 0.5:
		dark = Color(0.06, 0.12, 0.12)
	var vlen: float = 1.0 / float(jw)       # a voxel is one art column of the cell
	var vs: float = PIXEL_SIZE
	var yc: float = _mill_y(y_center)
	# The opening is WIDER than the shaft that enters it — Daniel: "the hole is deep
	# enough, it's not wide enough. it has to be at least 2x the size of the axle endcap".
	# A hole the same size as the endcap reads as the shaft simply stopping; twice the
	# section leaves a visible margin of darkness around it, which is what sells the shaft
	# running on into the housing.
	#
	# The housing itself runs from the GROUND up past that opening — Daniel: "make the
	# entire gearbox a little taller above the hole and extend the box to the ground". It
	# was a slab floating at the shaft's height, which read as hanging in the air; now it
	# stands on the floor like the machine it is. So the rows are counted from the ground
	# (row 0 sits on the floor), the hole is centred on the SHAFT's line wherever that
	# falls, and BOX_ABOVE rows of housing carry on over it.
	var hole_w: int = mini(srows * 2, jw - 2)
	var hcen: int = int(round(yc / vs))                # the shaft's centre, in rows off the floor
	var hole_h: int = mini(srows * 2, maxi(2, hcen - 1))   # keep at least a one-row sill
	var vlo: int = maxi(1, hcen - int(floor(hole_h * 0.5)))
	var vhi: int = vlo + hole_h - 1
	var n_rows: int = vhi + 1 + BOX_ABOVE
	# THE SIDES ARE PULLED IN so the lip beside the opening matches the lip above it —
	# Daniel: "I'd like the lip at the sides of the hole to match the lip at the top of the
	# hole. However much you pull-in the n/s faces, make the symmetrical change on the
	# east-west walls."
	#
	# The two lips are measured in different units, which is why they looked unequal: a row
	# is PIXEL_SIZE tall (0.042) and a column is a sixteenth of a cell wide (0.0625). Match
	# them in WORLD units — the top lip is BOX_ABOVE rows, so the side lip is however many
	# columns come nearest that same distance — and the box is then hole + two lips across,
	# no longer the full cell. Applied to BOTH horizontal axes so the housing stays square.
	var n_h: int = _gearbox_span(srows, jw)            # box width in voxels, both axes
	var lo: int = int((n_h - hole_w) / 2)              # centred on the face by construction
	var hi: int = lo + hole_w - 1
	# THE ROOF'S TURNING VANE. This tile is a PLAN, not an elevation — the east stub runs right
	# and the south stub runs down — so the housing's interior is the roof seen from above, and
	# the transparent line pivoting about its centre is a vane turning (Daniel: "It's a 3x3 grid
	# of 3 pixel wide cells. The pattern rotates around the cell"). Transparent means the cell
	# background shows through, so the vane is cut as a GROOVE with darkness at the bottom of
	# it: the shaft opening's trick, one surface up.
	#
	# One whole housing per frame, stepped by visibility, because a groove is grid-aligned
	# geometry — unlike the shafts, which rotate continuously, a roof that spun off its own
	# lattice would poke out past the housing's edges.
	var frames := _anim_frame_tiles(anim, tile)
	var grid := _vane_grid(String(frames[0]), btop, bbot, hx0, hx1, n_h)
	var roof: Array = []
	for fi in frames.size():
		var groove := _vane_cells(_gearbox_vane_dir(String(frames[fi]), btop, bbot, hx0, hx1),
			grid.x, grid.y)
		var solid := {}
		for ax in n_h:
			for vy in n_rows:
				for az in n_h:
					var in_hole_e: bool = dirs.contains("e") and ax == n_h - 1 and az >= lo and az <= hi and vy >= vlo and vy <= vhi
					var in_hole_w: bool = dirs.contains("w") and ax == 0 and az >= lo and az <= hi and vy >= vlo and vy <= vhi
					var in_hole_s: bool = dirs.contains("s") and az == n_h - 1 and ax >= lo and ax <= hi and vy >= vlo and vy <= vhi
					var in_hole_n: bool = dirs.contains("n") and az == 0 and ax >= lo and ax <= hi and vy >= vlo and vy <= vhi
					if in_hole_e or in_hole_w or in_hole_s or in_hole_n:
						continue                # the cut-away outer layer
					var in_vane: bool = groove.has(Vector2i(ax, az))
					if vy == n_rows - 1 and in_vane:
						continue                # the groove itself
					# the layer directly behind a hole is the darkness you see into
					var behind: bool = (dirs.contains("e") and ax == n_h - 2 and az >= lo and az <= hi and vy >= vlo and vy <= vhi) \
						or (dirs.contains("w") and ax == 1 and az >= lo and az <= hi and vy >= vlo and vy <= vhi) \
						or (dirs.contains("s") and az == n_h - 2 and ax >= lo and ax <= hi and vy >= vlo and vy <= vhi) \
						or (dirs.contains("n") and az == 1 and ax >= lo and ax <= hi and vy >= vlo and vy <= vhi) \
						or (vy == n_rows - 2 and in_vane)
					solid[Vector3i(ax, vy, az)] = dark if behind else brown
		if solid.is_empty():
			return
		var stool := SurfaceTool.new()
		stool.begin(Mesh.PRIMITIVE_TRIANGLES)
		for key in solid:
			var v: Vector3i = key
			# centred in the cell now that the sides are pulled in; row 0 still on the floor
			var half_w: float = n_h * vlen * 0.5
			var o := Vector3(cx - half_w + v.x * vlen, v.y * vs, cy - half_w + v.z * vlen)
			_vox_block(stool, o, Vector3(vlen, vs, vlen), solid[key],
				[not solid.has(v + Vector3i(-1, 0, 0)), not solid.has(v + Vector3i(1, 0, 0)),
				 not solid.has(v + Vector3i(0, -1, 0)), not solid.has(v + Vector3i(0, 1, 0)),
				 not solid.has(v + Vector3i(0, 0, -1)), not solid.has(v + Vector3i(0, 0, 1))])
		var mesh := ArrayMesh.new()
		stool.commit(mesh)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var bm: StandardMaterial3D = _vox_skin_material().duplicate()
		bm.albedo_color = Color(light_frac, light_frac, light_frac)
		mi.material_override = bm
		mi.visible = fi == 0
		_spawn_parent().add_child(mi)
		if _live_build:
			_lit_meshes.append({"mi": mi, "cell": Vector2i(cx, cy)})
		roof.append(mi)
		_track(mi)
	# _anim_marks already hands back the driver's sched shape, parallel to _anim_frame_tiles
	var marks := _anim_marks(anim)
	if _live_build and roof.size() > 1 and marks.size() == roof.size():
		# SLOWED, for the same reason the shafts were: Qud steps this cycle three times a
		# second, which reads as texture on a flat tile and as a flicker on solid geometry.
		# The vane and the shafts are one machine and must turn like it — see VANE_SPIN_SLOW
		# for why that means half the shafts' factor, not the same one.
		var rsched: Array = []
		for mk in marks:
			rsched.append({"f": int(round(float(mk["f"]) * VANE_SPIN_SLOW))})
		_anim_sprites.append({"nodes": roof, "sched": rsched,
			"len": int(maxi(_anim_len(anim), 1) * VANE_SPIN_SLOW)})

	# A HOLE WITH NOTHING IN IT. The housing's connection set says a shaft leaves in every
	# direction of `dirs`, but only a neighbouring axle OBJECT ever drew one — and at the
	# Joppa mill the gearbox's south neighbour is a brinestalk wall, so that opening stared
	# out at nothing (Daniel: "add another rotating i-beam coming from the gearbox to the
	# wall block. N-S"). The gearbox grows the missing beam itself.
	#
	# ONLY where the neighbour is a wall, which is the whole point of the test: a wall cell
	# never draws a shaft, while an axle neighbour already reaches into this recess. Emit in
	# both cases and the two beams would occupy the same opening, z-fighting AND turning out
	# of phase with each other, since nothing locks their clocks together.
	var svs: float = srows * PIXEL_SIZE / 3.0     # the section _fence_half_prism builds
	var half_w2: float = n_h * vlen * 0.5
	var hy: float = (vlo + hole_h * 0.5) * vs     # dead centre of the opening, not merely near it
	for d in dirs:
		var step := Vector2i(1 if d == "e" else (-1 if d == "w" else 0),
			1 if d == "s" else (-1 if d == "n" else 0))
		if step == Vector2i.ZERO or not _zone_wall_cells.has(Vector2i(cx, cy) + step):
			continue
		# from the darkness behind the opening out to the cell edge, then one voxel INTO the
		# wall, so the end cap is buried instead of showing as a disc stuck on the wall's face
		var s0: float = half_w2 - vlen
		var s1: float = 0.5 + vlen
		var smi := MeshInstance3D.new()
		smi.mesh = _ibeam_mesh(s1 - s0, svs, brown, dark)
		var sm: StandardMaterial3D = _vox_skin_material().duplicate()
		sm.albedo_color = Color(light_frac, light_frac, light_frac)
		smi.material_override = sm
		var shoriz: bool = d == "e" or d == "w"
		var sb := Basis(Vector3.UP, 0.0 if shoriz else -PI * 0.5)
		var mid: float = (s0 + s1) * 0.5 * (1.0 if (d == "e" or d == "s") else -1.0)
		smi.transform = Transform3D(sb, Vector3(cx, hy, cy)
			+ (Vector3(mid, 0.0, 0.0) if shoriz else Vector3(0.0, 0.0, mid)))
		_spawn_parent().add_child(smi)
		if _live_build:
			_lit_meshes.append({"mi": smi, "cell": Vector2i(cx, cy)})
			if anim != "":
				_anim_sprites.append({"spin": smi, "base": sb,
					"period": maxf(0.1, _anim_len(anim) / 60.0) * AXLE_SPIN_SLOW})
		_track(smi)


## The waterwheel: a 12-PANEL cylinder turning on an east-west axle.
##
## Daniel: "The waterwheel is a cylinder with the faces going east-west ... let's try and make
## the UV map for the sides and faces" / "12 panels sounds great".
##
## THE MILL FIXES THE AXIS before the art gets a vote: the E-W axle run at (3,7)..(5,7) ends at
## the wheel's cell (6,7), and a wheel drives the axle along its OWN axis. The old standing rule
## ("ORIENTED PANEL running E-W (faces N/S)") is 90 degrees off — a guess from before there was
## a mill to check it against.
##
## So the tile is the wheel seen EDGE-ON, which is why its wood pattern TRANSLATES vertically
## between frames rather than rotating about a centre. That single observation decides which of
## the two maps is real: the art hands us the TREAD directly and says nothing whatever about the
## END, so the face is built from the tread's own colour and panel count. Columns split the tile
## three ways — 1..8 wood only (the wheel, half a cell thick), 9..12 every detail pixel (water
## falling off the east side, NOT wheel surface, not modelled here), 13..14 the far frame.
##
## tools/capture/wheelmap.py is the same derivation with a preview sheet; change one, change both.
const WHEEL_PANELS := 12

## Profile radii, as fractions of the disc: the hub the radial lines cross at, and the inner
## edge of the rim hoop. The filled slices live between them.
## Angular widths inside one slice, as fractions of it: the radial wall, the water lying on it,
## and the lip that retains the water. Daniel: "add a layer of blue water on the spokes. In the
## direction of rotation, the layer would lay flat on the spoke. Also, try and add a lip counter
## to the direction of motion to 'hold the water in'." Spoke + water + lip is a BUCKET: the wall
## is its floor, the lip its outer wall, and the water sits between them.
const WHEEL_SPOKE_W := 0.30
const WHEEL_WATER_W := 0.22
const WHEEL_LIP_W := 0.10
const WHEEL_LIP_R := 0.55      # the lip stands from this radius out to the rim

## The endcap ring is DASHED — six arcs with background between them (Daniel: "add Qud bg color
## to the blue ring at intervals to divide the blue ring into 6 sections. Like a dashed line
## perimeter."). Six divides the twelve vanes, so a gap lands on every other one instead of
## drifting against the structure. It also gives the face 6-fold symmetry where a continuous
## ring had rotational INVARIANCE — which is what makes the wheel look like it is turning again
## when you are square on to it.
const WHEEL_RING_DASHES := 6.0
const WHEEL_RING_GAP := 0.16   # fraction of each arc that is background

const WHEEL_HUB := 0.16
const WHEEL_RIM := 0.86

## Half again what the tile measures. A wheel derived at its art size is 0.92 of a cell across,
## so hung on the axle line its lowest point sits ABOVE the surface and the thing spins dry
## (Daniel: "otherwise it won't dip into the water"). 2.0 put 18% of the wheel under; 1.5 —
## where Daniel settled it — puts the lowest 7% under, so it still breaks the surface but reads
## a good deal less monumental.
const WHEEL_SCALE := 1.3

## How far the whole mill assembly hangs below FLOAT_Y. Daniel: "drop the height of the
## waterwheel, the axels, the hole in the gearbox. I'd like the wheel to dip into the water,
## but it's already at aesthetically max size" — so the dip comes from lowering the axle line
## rather than from growing the wheel again.
##
## Applied to EVERY part of the machine, which is the only way it can be applied: wheel, shafts
## and the gearbox's opening share one line, and dropping the wheel alone would pull its hub off
## the shaft it turns. 0.2 puts the wheel's lowest 17% under water at 1.3x — the submersion 2.0x
## used to give, at the size Daniel wants.
const MILL_DROP := 0.2

## The mill's axle line. Floored just above the ground so a shallower cell can never bury it.
func _mill_y(y_center: float) -> float:
	return maxf(0.05, (y_center if y_center >= 0.0 else FLOAT_Y) - MILL_DROP)

## One revolution in the time the shafts take. The wheel and the axle run are ONE shaft, direct
## drive with no gearing between them, so they turn at the same rate or the machine reads as
## broken. Qud has the wheel at ~35s and the shafts at 1s, which is fine for two flat tiles
## animating independently and wrong for one turning assembly.
const WHEEL_REV_SEC := AXLE_SPIN_SLOW

## The wheel's own columns: opaque, and carrying NO detail pixels. That is what separates wood
## from the falling water rather than a hardcoded column range, so a repainted tile still splits.
func _wheel_cols(mask: Image) -> Vector2i:
	var lo := -1
	var hi := -1
	for x in mask.get_width():
		var opaque := false
		var detail := false
		for y in mask.get_height():
			var px := mask.get_pixel(x, y)
			if px.a < 0.5:
				continue
			opaque = true
			if px.r >= 0.5:
				detail = true
		if opaque and not detail:
			if lo < 0:
				lo = x
			elif x > hi + 1 and hi >= 0:
				break            # a second wood run (the far frame) — stop at the first
			hi = x
		elif lo >= 0:
			break
	return Vector2i(lo, hi)

func _place_waterwheel(obj: Dictionary, tile: String, cx: int, cy: int, light_frac: float) -> bool:
	var mask := _mask(tile)
	if mask == null:
		return false
	var wc := _wheel_cols(mask)
	if wc.x < 0 or wc.y <= wc.x:
		return false
	var top := -1
	var bot := -1
	for y in mask.get_height():
		for x in range(wc.x, wc.y + 1):
			if mask.get_pixel(x, y).a >= 0.5:
				if top < 0:
					top = y
				bot = y
				break
	if top < 0:
		return false
	# colour STRINGS here — _colored_tex parses them; _colored_tex_rgb is the one taking Colors
	var tex := _colored_tex(tile, _pick_color_string(obj), String(obj.get("detail", "")), Fill.NONE)
	if tex == null:
		return false
	var img := tex.get_image()
	var sx: float = img.get_width() / float(mask.get_width())
	var sy: float = img.get_height() / float(mask.get_height())
	# the wood, sampled from a wheel column rather than the tile centre (which is water)
	var wood := img.get_pixel(int((wc.x + 0.5) * sx), int(((top + bot) * 0.5) * sy))
	# DIAMETER runs on the ART's scale (rows) and THICKNESS on the CELL's (columns) — the same
	# split every shape here uses, and the one that has cost the most when conflated.
	var r: float = (bot - top + 1) * PIXEL_SIZE * 0.5 * WHEEL_SCALE
	var thick: float = (wc.y - wc.x + 1) / float(mask.get_width()) * WHEEL_SCALE
	# ON THE AXLE LINE, and deliberately NOT clamped above the ground. This was maxf(r, FLOAT_Y),
	# which is invisible at the art's own size (r < FLOAT_Y) and silently defeats the whole point
	# at double: it would LIFT the wheel until its lowest point rested on the surface, leaving it
	# dry AND pulling the hub off the shaft it is supposed to share. The dip IS the part below
	# the surface, so the centre stays where the axle is and the bottom goes under.
	var yc: float = _mill_y(-1.0)
	var root := Node3D.new()
	root.transform = Transform3D(Basis(), Vector3(cx, yc, cy))
	# The CROSS-SECTION: WHEEL_PANELS spokes, a hub and a rim band, in the wood's colour. It was
	# the end cap of a cylinder; it is now the profile the whole wheel is extruded from.
	# TWO profiles, because only one of them runs the whole length (Daniel: "keep the entire
	# circle on the waterwheel endcaps ... only extrude the radial lines ... like two pizzas held
	# together by 6 intersecting walls"). `face` is the whole disc and lives at the ends only;
	# `spok` is the radial lines plus the hub they cross at, and that is what spans the middle.
	# WHEEL_PANELS is 12 spokes, which is 6 diameters — Daniel's six walls.
	# THE SLICES ARE FILLED now (Daniel: "From the outer edge, inward, in each 'pizza slice', add
	# one row of the default background color, one row of light blue, and the rest the background
	# color. Keep the brown radial lines."). Rings are counted inward from the slice's OUTER edge,
	# so the blue sits one row in — which is where water would stand in a bucket, held by the rim.
	# Read as ADDITIVE: the rim hoop and the radial lines stay brown and the fill goes in the gaps
	# between them, since "fill in" and "keep the brown radial lines" both point that way.
	#
	# Both colours are Qud's own: k (#0f3b3a) is the default background — Daniel's "dark green"
	# from the I-beam web — and B (#0096ff) is the light blue.
	# TWO blues, because they are two different things. The endcap ring is LIGHT blue (Daniel:
	# "turn the blue on the endcaps to light blue") — C, #77bfcf; the water carried on the spokes
	# is blue proper — B, #0096ff. k (#0f3b3a) is Qud's default background.
	var bg := _qud_color("k")
	var lblue := _qud_color("C")
	var wblue := _qud_color("B")
	var fs: int = bot - top + 1
	var face := Image.create(fs, fs, false, Image.FORMAT_RGBA8)
	var spok := Image.create(fs, fs, false, Image.FORMAT_RGBA8)
	var inner := Image.create(fs, fs, false, Image.FORMAT_RGBA8)
	var c: float = (fs - 1) * 0.5
	for py in fs:
		for px in fs:
			var dx: float = px - c
			var dy: float = py - c
			var d: float = sqrt(dx * dx + dy * dy)
			var radial: bool = false
			var col := Color(0, 0, 0, 0)         # what the ENDCAP shows
			var mid := Color(0, 0, 0, 0)         # what runs BETWEEN the two endcaps
			if d <= c:
				var ang: float = (atan2(dy, dx) + PI) / TAU
				# MIRRORED (Daniel: "Move the blue water to the other side of the waterwheel
				# cutout/channel. It's currently 'floating' against the waterwheel panels.
				# Roughly the equivalent of flipping it 180 and rotating the opposite
				# direction"). Negating the phase swings water and lip onto the other face of
				# every vane, so the buckets open the other way round the wheel — the same
				# result reversing the spin would give, done in the profile instead.
				var ph: float = fposmod(-ang * WHEEL_PANELS, 1.0)
				var hub: bool = d < c * WHEEL_HUB
				var rim: bool = d > c * WHEEL_RIM
				radial = hub or ph < WHEEL_SPOKE_W
				var wet: bool = not rim and not hub \
					and ph >= WHEEL_SPOKE_W and ph < WHEEL_SPOKE_W + WHEEL_WATER_W
				var lip: bool = not rim and not hub and d > c * WHEEL_LIP_R \
					and ph >= WHEEL_SPOKE_W + WHEEL_WATER_W \
					and ph < WHEEL_SPOKE_W + WHEEL_WATER_W + WHEEL_LIP_W
				# THE OUTWARD FACE IS BACKGROUND but for two rings (Daniel: "The outer 1px wood
				# ring stays. The light blue stays. Change the rest of the brown on the wheel to
				# qud bg color."). Wall, hub and lip still EXIST here — same geometry, still
				# split so the span keeps its own timber — they just stop being drawn in wood on
				# the face.
				#
				# The wooden hoop is ONE voxel now, counted from the disc's own edge rather than
				# from WHEEL_RIM, which was giving it closer to two. The blue stays exactly where
				# it sat, two rings further in, still broken into WHEEL_RING_DASHES arcs.
				if int(floor(c - d)) == 0:
					col = wood
				elif int(floor(c * WHEEL_RIM - d)) == 1:
					col = bg if fposmod(-ang * WHEEL_RING_DASHES, 1.0) < WHEEL_RING_GAP else lblue
				else:
					col = bg
				# BETWEEN the discs: the walls and lip keep their wood, and the water goes to
				# background (Daniel: "Change the light blue inside the waterwheel column to Qud
				# bg color") — so the bucket still has its shape and its shading, but no colour.
				mid = wood if (radial or lip) else (bg if wet else Color(0, 0, 0, 0))
			face.set_pixel(px, py, col)
			spok.set_pixel(px, py, mid)
			# THE INNER SURFACES — the two disc faces that look at each other across the span
			# (Daniel: "change just the inside of the pizzas, the sides facing each other ...
			# change the outer 1px border to brown"). Background but for one voxel of timber at
			# the rim, so the span is bounded by a wooden edge at each end. A THIRD profile
			# rather than a rule inside the mesher: every colour decision for this shape belongs
			# here beside the other two, and the mesher stays a mesher.
			if d <= c:
				inner.set_pixel(px, py, wood if int(floor(c - d)) == 0 else bg)
	var mi := MeshInstance3D.new()
	mi.mesh = _wheel_extrude_mesh(face, spok, inner, r, thick)
	var wm: StandardMaterial3D = _vox_skin_material().duplicate()
	wm.albedo_color = Color(light_frac, light_frac, light_frac)
	mi.material_override = wm
	root.add_child(mi)
	_spawn_parent().add_child(root)
	_wheel_spill(obj, tile, mask, img, top, bot, r, thick, cx, cy)
	if _live_build:
		_anim_sprites.append({"spin": root, "base": Basis(), "period": WHEEL_REV_SEC})
	_track(root)
	return true

## The water the wheel throws off — the fire and smoke rigs' sibling.
##
## Columns 9..12 of the tile are the one part that is neither wheel nor frame: a vertical
## curtain immediately EAST of the rim, running from near the top down to the surface. Every
## detail (white) pixel in the file lives there. It is emphatically NOT wheel surface, which is
## why the cylinder ignores those columns and this reads them instead.
const SPILL_AMOUNT := 70        # droplets alive in the curtain
const SPILL_LIFETIME := 1.1     # seconds; gravity is solved so the fall lands on the surface
const SPILL_SQUARE := 0.075     # edge of one droplet square, before per-particle scale
const SPILL_FALL := 0.5         # initial downward speed; gravity supplies the rest
const SPILL_HEIGHT := 0.375     # of the run the art draws: halved, then three quarters of that
const SPLASH_AMOUNT := 26       # droplets alive in the burst where the column lands
const SPLASH_LIFETIME := 0.55

func _wheel_spill(obj: Dictionary, tile: String, mask: Image, img: Image, top: int, bot: int,
		r: float, thick: float, cx: int, cy: int) -> void:
	if Settings.qud_shape("particles"):
		return
	# The curtain is the UNION of the detail pixels over EVERY frame, not whichever phase the
	# object is wearing. Qud animates the droplets DOWN the column, so any single frame covers
	# only part of the run — the canonical-frame rule, which has now bitten in four shapes.
	var wx0 := 9999
	var wx1 := -1
	var wy0 := 9999
	var wy1 := -1
	for ft in _anim_frame_tiles(String(obj.get("animSched", "")), tile):
		var fm := _mask(String(ft))
		if fm == null:
			continue
		for y in fm.get_height():
			for x in fm.get_width():
				var px := fm.get_pixel(x, y)
				if px.a >= 0.5 and px.r >= 0.5:      # opaque AND detail — the water
					wx0 = mini(wx0, x)
					wx1 = maxi(wx1, x)
					wy0 = mini(wy0, y)
					wy1 = maxi(wy1, y)
	if wx1 < 0:
		return
	var rows: float = float(bot - top + 1)
	var dia: float = 2.0 * r
	var wheel_top: float = FLOAT_Y + r
	var y_top: float = wheel_top - (wy0 - top) / rows * dia
	var y_bot: float = wheel_top - (wy1 - top + 1) / rows * dia
	# SHORTENED TWICE OVER, from the top, with the landing point fixed: halved first (Daniel:
	# "Lower the falling water by half"), then taken to three quarters of that ("Move the falling
	# water height down to 0.75 it's current height"). 0.375 of the run the art draws.
	y_top = y_bot + (y_top - y_bot) * SPILL_HEIGHT
	var fall: float = maxf(0.15, y_top - y_bot)
	# WIDTH stays on the art's own scale — the spill is water, not wheel, so WHEEL_SCALE has no
	# business here; it hangs just clear of the east face wherever that face ended up.
	var wwide: float = (wx1 - wx0 + 1) / float(mask.get_width())
	# Sample a pixel that IS water in the BASE frame. The union's corner need not be one —
	# it was not, so this silently fell through to the colour fallback every time.
	var sxr: float = img.get_width() / float(mask.get_width())
	var syr: float = img.get_height() / float(mask.get_height())
	var wcol := _qud_color(String(obj.get("detail", "")))
	for y in mask.get_height():
		var hit := false
		for x in mask.get_width():
			var mp := mask.get_pixel(x, y)
			if mp.a >= 0.5 and mp.r >= 0.5:
				var c2 := img.get_pixel(int((x + 0.5) * sxr), int((y + 0.5) * syr))
				if c2.a >= 0.5:
					wcol = c2
					hit = true
					break
		if hit:
			break
	var qm := QuadMesh.new()
	qm.size = Vector2(SPILL_SQUARE, SPILL_SQUARE)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX        # water TINTS; it is not a light source
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.billboard_keep_scale = true
	dm.vertex_color_use_as_albedo = true
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	dm.render_priority = 2                               # after the walls (the smoke-sort rule)
	qm.material = dm
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 5.0
	pm.initial_velocity_min = SPILL_FALL * 0.7
	pm.initial_velocity_max = SPILL_FALL * 1.3
	# solved so a droplet covers exactly the drawn run in one lifetime: fall = v*t + g*t*t/2
	var g: float = maxf(0.5, 2.0 * (fall - SPILL_FALL * SPILL_LIFETIME) / (SPILL_LIFETIME * SPILL_LIFETIME))
	pm.gravity = Vector3(0, -g, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# A STREAM, not a sheet. The art draws the water as a narrow column four art columns wide,
	# and spreading it across half the wheel's span turned it into scattered specks seen through
	# the spokes instead of falling water. Widths stay near the drawn one; the LONGER of the two
	# now runs east-west, across the viewer, since the curtain faces south.
	pm.emission_box_extents = Vector3(wwide * 0.9, 0.03, wwide * 0.5)
	pm.scale_min = 0.6
	pm.scale_max = 1.35
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	grad.colors = PackedColorArray([
		Color(wcol.r, wcol.g, wcol.b, 0.95),
		Color(wcol.r, wcol.g, wcol.b, 0.7),
		Color(wcol.r, wcol.g, wcol.b, 0.0)])            # fades out as it reaches the surface
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	var pt := GPUParticles3D.new()
	pt.amount = SPILL_AMOUNT
	pt.lifetime = SPILL_LIFETIME
	pt.preprocess = SPILL_LIFETIME    # a curtain already falling, not one starting dry
	pt.randomness = 0.5
	pt.process_material = pm
	pt.draw_pass_1 = qm
	pt.local_coords = false
	pt.visibility_aabb = AABB(Vector3(-1.0, -fall - 0.5, -1.0), Vector3(2.0, fall + 1.5, 2.0))
	# NOT a child of the wheel root — that node SPINS, and water dragged round with the rim
	# would orbit instead of fall. It hangs off the spawn parent at the cell instead.
	#
	# ON THE SOUTH SIDE (Daniel: "move the waterfall to the south face of the waterwheel"). The
	# tile draws it EAST of the wheel, which is where it started, and east is the one place the
	# default north-looking camera cannot see it — the wheel's own body is in the way. South is
	# the wheel's southern tangent, z = cy + r, so the water leaves the rim at its widest point
	# and falls clear, in front of the wheel from the usual view.
	pt.position = Vector3(cx, y_top, cy + r)
	_spawn_parent().add_child(pt)
	_track(pt)

	# THE SPLASH where the column lands (Daniel: "Add the splash"). Same colour, same droplet,
	# opposite sign: a short burst thrown UP and OUT of the surface rather than a long fall, so
	# the water breaks on arrival instead of just fading out as it did before.
	var spm := ParticleProcessMaterial.new()
	spm.direction = Vector3(0, 1, 0)
	spm.spread = 70.0
	spm.initial_velocity_min = SPILL_FALL * 0.45
	spm.initial_velocity_max = SPILL_FALL * 1.3
	spm.gravity = Vector3(0, -g * 1.6, 0)     # falls back faster than it rose
	spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	spm.emission_box_extents = Vector3(wwide * 0.7, 0.02, wwide * 0.7)
	spm.scale_min = 0.35
	spm.scale_max = 0.85
	spm.color_ramp = gt
	var sp := GPUParticles3D.new()
	sp.amount = SPLASH_AMOUNT
	sp.lifetime = SPLASH_LIFETIME
	sp.preprocess = SPLASH_LIFETIME
	sp.randomness = 0.75
	sp.process_material = spm
	sp.draw_pass_1 = qm
	sp.local_coords = false
	sp.visibility_aabb = AABB(Vector3(-1.0, -0.5, -1.0), Vector3(2.0, 2.0, 2.0))
	sp.position = Vector3(cx, y_bot, cy + r)
	_spawn_parent().add_child(sp)
	_track(sp)


## The wheel as TWO END DISCS held apart by its radial walls.
##
## Daniel: "keep the entire circle on the waterwheel endcaps. Let's only extrude the radial
## lines. That means the circle is only present at the endcaps. Like two pizzas held together
## by 6 intersecting walls."
##
## So a pixel on a radial line (a spoke, or the hub they all cross at) becomes ONE box running
## the whole thickness, and every other disc pixel — the rim band above all — becomes two thin
## slabs, one at each end, with open air between them. The rim therefore reads as a hoop at each
## face rather than a drum, which is the whole point: the cylinder's round side is gone and what
## is left is the drawing, twice, with structure between.
##
## Culling: a full-depth box tests its in-plane neighbours against the RADIAL profile and an end
## slab tests against the WHOLE disc. That pairing is what keeps it hole-free — an end slab
## beside a spoke is correctly buried (the spoke's box covers that depth), while a spoke beside
## a rim-only pixel still draws its long side, of which only the slab's depth is hidden.
func _wheel_extrude_mesh(face: Image, spok: Image, inner: Image, r: float, thick: float) -> ArrayMesh:
	var fs := face.get_width()
	var step: float = 2.0 * r / float(fs)
	var cap: float = minf(step, thick * 0.4)      # each end disc is one profile voxel deep
	var disc := {}
	var rad := {}
	for py in fs:
		for px in fs:
			var cf := face.get_pixel(px, py)
			if cf.a >= 0.5:
				disc[Vector2i(px, py)] = cf
			# THE SPAN WEARS `spok`'S OWN COLOUR, not the face's. This read `cf` — so the two
			# profiles agreed on WHERE the middle was solid and the face silently decided what
			# colour it was. That is how the light blue got into the span: wherever a full-depth
			# voxel happened to sit on the endcap's ring radius, the ring's colour was extruded
			# the whole way through the wheel.
			var cs := spok.get_pixel(px, py)
			if cs.a >= 0.5:
				rad[Vector2i(px, py)] = cs
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid: float = (fs - 1) * 0.5
	for key in disc:
		var k: Vector2i = key
		# image +y runs DOWN and world +y runs UP, so the row flips; the column maps to z as is
		var wy: float = -(k.y - mid) * step - step * 0.5
		var wz: float = (k.x - mid) * step - step * 0.5
		var half: float = cap * 0.5
		var nb := [not disc.has(k + Vector2i(0, 1)), not disc.has(k + Vector2i(0, -1)),
			not disc.has(k + Vector2i(-1, 0)), not disc.has(k + Vector2i(1, 0))]
		# EVERY column is face-colour at the two ends and span-colour in between. A single
		# full-depth box cannot serve both: it reaches the very ends, so it IS the face where it
		# sits, and a wall painted for the span turned the endcap back into a brown lattice —
		# undoing "change the brown voxels inside the outer ring to Qud background color".
		# Splitting is what lets the face be a dark disc while the span keeps its timber.
		_vox_block(st, Vector3(-thick * 0.5, wy, wz), Vector3(half, step, step), disc[k],
			[true, true, nb[0], nb[1], nb[2], nb[3]])
		_vox_block(st, Vector3(thick * 0.5 - half, wy, wz), Vector3(half, step, step), disc[k],
			[true, true, nb[0], nb[1], nb[2], nb[3]])
		if rad.has(k):
			# the bucket's timber and its water, running the span between the two discs
			_vox_block(st, Vector3(-thick * 0.5 + half, wy, wz),
				Vector3(thick - 2.0 * half, step, step), rad[k],
				[true, true,
				 not rad.has(k + Vector2i(0, 1)), not rad.has(k + Vector2i(0, -1)),
				 not rad.has(k + Vector2i(-1, 0)), not rad.has(k + Vector2i(1, 0))])
		else:
			# no structure here, so each disc gets its INNER lining: without it the ring and
			# the hoop would be read from within the span as well as from outside
			var lin := inner.get_pixel(k.x, k.y)
			for x0 in [-thick * 0.5 + half, thick * 0.5 - cap]:
				_vox_block(st, Vector3(x0, wy, wz), Vector3(half, step, step), lin,
					[true, true, nb[0], nb[1], nb[2], nb[3]])
	var m := ArrayMesh.new()
	st.commit(m)
	return m


## Connector families built as a turning PRISM rather than a flat panel. Axles only:
## Qud draws a shaft as a 4-row band whose lit rows shift between frames — surface
## markings at three rotation phases — and a flat quad can only slide those markings
## sideways. Daniel: "let's use the animation cycles to build the UV map. It's basically
## a rectangular prism."
const PRISM_CONNECTORS := ["axle"]

func _connector_is_prism(tile: String) -> bool:
	if _one_to_one or _flat_2d or _world_map:
		return false
	for k in PRISM_CONNECTORS:
		if tile.contains(k):
			return true
	return false


## The I-beam solid itself: a run of length `seg` with the section
##
##     b b b      flanges, `brown`
##       D        the web, `dark` — and AIR in the two notches
##     b b b
##
## Built in SHAFT-LOCAL space centred on the origin with local +x along the run, which is
## what lets the caller yaw it onto a cell axis and the driver spin it about local +x. Both
## ends are capped: a shaft's ends are buried in the recess it enters, and a gearbox stub's
## far end is buried in the wall, so a cap is never the thing you see.
func _ibeam_mesh(seg: float, vs: float, brown: Color, dark: Color) -> ArrayMesh:
	var sec := {}
	for col in 3:
		sec[Vector2i(0, col)] = brown
		sec[Vector2i(2, col)] = brown
	sec[Vector2i(1, 1)] = dark
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for key in sec:
		var rc: Vector2i = key
		var o := Vector3(-seg * 0.5, (rc.x - 1.5) * vs, (rc.y - 1.5) * vs)
		_vox_block(st, o, Vector3(seg, vs, vs), sec[key],
			[true, true,
			 not sec.has(rc + Vector2i(-1, 0)), not sec.has(rc + Vector2i(1, 0)),
			 not sec.has(rc + Vector2i(0, -1)), not sec.has(rc + Vector2i(0, 1))])
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


## One half-shaft as an I-BEAM of voxel blocks, spun about its own axis.
##
## Daniel: "Can we make them I-beams made out of voxel blocks? Then we just rotate the whole
## axis. b=brown D=the default background color of Qud."
##
##     b b b      flanges, the shaft's own wood colour
##       D        the web, painted the cell background
##     b b b      and AIR in the two notches
##
## That replaces three baked meshes swapped on a schedule with ONE mesh turned continuously,
## which is what the art was depicting all along: Qud's frames are a cylinder's markings at
## three phases, and a section that is not rotationally symmetric gives real rotation for
## free. The notches are what make the turn legible — a square prism spinning looks static.
##
## The web takes the background colour rather than a darker wood, so the beam reads as open
## between its flanges, matching the gearbox's recess trick.
##
## Built in SHAFT-LOCAL space, centred on the origin, so the driver can spin it by writing a
## basis; length runs on the CELL's scale (a half spans half a cell and meets its neighbour),
## thickness on the ART's, which is the same split the flat shaft used.
func _fence_half_prism(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String,
		h: float, fill: int, y_center: float, light_frac: float, anim: String) -> void:
	var art := _panel_art(tile)
	var frames := _anim_frame_tiles(anim, art)
	# thickness from the WIDEST frame's band, so the beam keeps the weight the flat shaft
	# had and does not change with whichever frame the object is wearing
	var band := 0
	for ft in frames:
		var fmask := _mask(String(ft))
		if fmask == null:
			continue
		var t0 := -1
		var b0 := -1
		for y in fmask.get_height():
			for x in fmask.get_width():
				if fmask.get_pixel(x, y).a >= 0.5:
					if t0 < 0:
						t0 = y
					b0 = y
					break
		if t0 >= 0:
			band = maxi(band, b0 - t0 + 1)
	if band <= 0:
		band = 4
	var tex := _colored_tex(art, main_c, detail_c, Fill.ALL)
	if tex == null:
		return
	var img := tex.get_image()
	var brown := img.get_pixel(int(img.get_width() * 0.5), int(img.get_height() * 0.5))
	var dark := img.get_pixel(0, 0)
	if dark.a < 0.5:
		dark = Color(0.06, 0.12, 0.12)
	var vs: float = band * PIXEL_SIZE / 3.0        # three voxels across, same total thickness
	var horiz: bool = d == "e" or d == "w"
	var yc: float = _mill_y(y_center)
	# REACH INTO THE RECESS. A half used to stop dead on the cell boundary, which was right
	# when the housing spanned the whole cell and wrong now that it is pulled in: the beam
	# ended in mid-air an eighth of a cell short of the face it is supposed to enter
	# (Daniel: "extend the shaft into the recess"). Reach the housing's inset plus one voxel,
	# so the end sits inside the opening. Where the neighbour is another shaft rather than a
	# gearbox the two simply overlap, and the buried end caps are never seen.
	var amask := _mask(art)
	var jw2: int = amask.get_width() if amask != null else 16
	var reach: float = (1.0 - _gearbox_span(band, jw2) / float(jw2)) * 0.5 + 1.0 / float(jw2)
	var seg: float = 0.5 + reach
	var mi := MeshInstance3D.new()
	mi.mesh = _ibeam_mesh(seg, vs, brown, dark)
	var fm: StandardMaterial3D = _vox_skin_material().duplicate()
	fm.albedo_color = Color(light_frac, light_frac, light_frac)
	mi.material_override = fm
	# local +x runs along the shaft; yaw turns that onto the cell's axis
	var yaw: float = 0.0 if horiz else -PI * 0.5
	var B := Basis(Vector3.UP, yaw)
	var lead: float = seg * 0.5 if (d == "e" or d == "s") else -seg * 0.5
	var centre := Vector3(cx, yc, cy) + (Vector3(lead, 0.0, 0.0) if horiz else Vector3(0.0, 0.0, lead))
	mi.transform = Transform3D(B, centre)
	_spawn_parent().add_child(mi)
	if _live_build:
		_lit_meshes.append({"mi": mi, "cell": Vector2i(cx, cy)})
		if anim != "":
			# one revolution per animation cycle — the cadence Qud steps its frames at
			_anim_sprites.append({"spin": mi, "base": B,
				"period": maxf(0.1, _anim_len(anim) / 60.0) * AXLE_SPIN_SLOW})
	_track(mi)


## The cycle's tile list, in order, from an animSched — or just the base tile when the
## object has no schedule (a lone unpowered axle still wants its solid prism).
func _anim_frame_tiles(anim: String, base_tile: String) -> Array:
	if anim == "":
		return [base_tile]
	var out: Array = []
	var parts := anim.split("|")
	for i in range(1, parts.size()):
		var kv := parts[i].split("=")
		if kv.size() != 2:
			continue
		var ftile := String(String(kv[1]).split(";")[0])
		out.append(ftile if ftile != "" else base_tile)
	return out if not out.is_empty() else [base_tile]

func _anim_len(anim: String) -> int:
	if anim == "":
		return 60
	return maxi(int(anim.split("|")[0]), 1)

## The cycle's thresholds, parallel to _anim_frame_tiles.
func _anim_marks(anim: String) -> Array:
	var out: Array = []
	if anim == "":
		return [{"f": 0}]
	var parts := anim.split("|")
	for i in range(1, parts.size()):
		var kv := parts[i].split("=")
		if kv.size() == 2:
			out.append({"f": int(kv[0])})
	return out if not out.is_empty() else [{"f": 0}]


func _take_fence() -> MeshInstance3D:
	if _bank == null and _fence_pool.size() > 0:
		return _fence_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _fence_quad
	_spawn_parent().add_child(mi)
	return mi

# `fill`: paint the art's transparent pixels with the Qud cell background (the
# dark green) instead of leaving them see-through. A sight-blocking panel — a
# tent wall — should read as solid; a picket fence should not, so this rides on
# the same `occluding` flag that picks the height.
func _fence_material(ew_tile: String, main_c: String, detail_c: String, half: String, fill := Fill.NONE) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s|%d" % [ew_tile, main_c, detail_c, half, fill]
	if _fencemat_cache.has(key):
		return _fencemat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var tex := _colored_tex(ew_tile, main_c, detail_c, fill)
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		# Only Fill.ALL makes every pixel opaque. INTERIOR and SPAN leave everything
		# OUTSIDE the art transparent, so the material still needs alpha — without
		# it those pixels are Color(0,0,0,0) drawn opaquely, i.e. BLACK, which put
		# a black rim around the water wheel.
		if fill != Fill.ALL:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		# crop V to the opaque content band so the panel sits flush on the ground
		# (the art is vertically centred with empty padding). Measured on the RAW
		# mask, so filling doesn't turn the padding into a green slab.
		var vr := _opaque_v(_mask(ew_tile))
		m.uv1_scale = Vector3(0.5, vr.y, 1)
		m.uv1_offset = Vector3(0.5 if half == "r" else 0.0, vr.x, 0)
	else:
		m.albedo_color = _qud_color(main_c)
	_fencemat_cache[key] = m
	return m

# (offset, scale) in V covering the opaque rows of an image — used to trim the
# vertical padding from a directional tile so its content sits on the ground.
func _opaque_v(img: Image) -> Vector2:
	if img == null:
		return Vector2(0, 1)
	var w := img.get_width()
	var h := img.get_height()
	var first := -1
	var last := -1
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a >= 0.5:
				if first < 0: first = y
				last = y
				break
	if first < 0:
		return Vector2(0, 1)
	return Vector2(float(first) / h, float(last - first + 1) / h)

## Ground-layer tiles that should stand up rather than lie flat.
##
## This is a NAME heuristic, which the rest of this codebase deliberately avoids
## in favour of Qud's own predicates — but the painted ground layer comes from
## Cell.Render() and has no GameObject or blueprint behind it to ask. The tile
## path is the only signal available. Extend the list as new cover turns up.
const UPRIGHT_GROUND := ["grass", "weed", "flower", "shrub", "moss", "fern",
	"plant", "vine", "sapling", "reed", "cactus", "bush", "brush", "mushroom", "sprout"]

## Ground cover that reads better standing up than painted flat. Qud composites
## vegetation into its painted-ground layer (obj.ground == true); we route that to
## the billboard path so plants you stand *among* aren't a floor texture. Two signals:
##   - tile under Creatures/ — where Qud keeps plants (scrub brush sw_plant3,
##     dreadroot, ...); genuine terrain/dirt lives under Terrain/, so this never
##     catches real ground. Robust for plant tiles not yet exported/word-listed.
##   - a vegetation word in the name — catches plants pathed elsewhere (e.g. the
##     aquatic sw_watervine, which sits at the Textures root, not under Creatures/).
func _is_vegetation(tile: String) -> bool:
	var path := tile.replace("\\", "/").to_lower()
	if path.begins_with("creatures/") or path.contains("/creatures/"):
		return true
	var name := path.get_file()
	for word in UPRIGHT_GROUND:
		if name.contains(word):
			return true
	return false

## World-map water families (svylake, river/lake, duskwaters, marsh). On the parasang map these
## have no real liquid flags — the cells are abstractions — so we key off the tile family. Water
## stays FLAT (see the world-map card branch): a standing blue card reads as a wall. Mangrove is
## excluded: it's trees standing IN water, so it keeps the upright card.
const WM_WATER_KEYS := ["river", "lake", "water", "ocean", "marsh", "duskwater"]
## A standalone splash (Liquids/<kind>/puddle_N) rather than an AUTOTILED body of water, whose
## deep-/shallow- name carries an 8-bit neighbour signature. The distinction is the whole reason
## one can be dropped under a cell winner and the other cannot.
## DEEP water — a body you look INTO — as against a shallow film or a standalone puddle, which
## lie ON the ground. Only the deep kind gets the dark depths plate beneath its surface.
func _is_deep_liquid(tile: String) -> bool:
	return tile.replace("\\", "/").to_lower().get_file().begins_with("deep")

func _is_standalone_puddle(tile: String) -> bool:
	return tile.replace("\\", "/").to_lower().get_file().begins_with("puddle")

func _is_world_water(tile: String) -> bool:
	var name := tile.replace("\\", "/").to_lower().get_file()
	if name.contains("mangrove"):
		return false
	for k in WM_WATER_KEYS:
		if name.contains(k):
			return true
	return false

func _is_spindle(tile: String) -> bool:
	return tile.to_lower().contains("spindle")

## Build the Spindle as a tall vertical tower at its base cell: the flared bottom tile seated on the
## ground, SPINDLE_MID_SEGMENTS repeatable shaft tiles stacked one tile-height apart, then the needle
## top. Each is a FULL (uncropped) sprite so the thin shaft columns line up into one continuous pipe.
## The mid/top tile paths are derived from the bottom's so the directory/case matches exactly. All
## join the "wm_tile" group, so the B toggle and top-down flip reach them like any world-map card.
const SPINDLE_MID_SEGMENTS := 18
func _place_spindle_tower(bottom_tile: String, main_c: String, detail_c: String, cx: int, cy: int) -> void:
	var mid_tile := bottom_tile.replace("bottom", "mid")
	var top_tile := bottom_tile.replace("bottom", "top")
	var seg_h := 24.0 * PIXEL_SIZE     # one 24px tile tall (~1 unit); segments stack at this pitch
	_spindle_seg(bottom_tile, main_c, detail_c, cx, cy, 0.5 * seg_h)          # base on the ground
	for i in range(1, SPINDLE_MID_SEGMENTS + 1):
		_spindle_seg(mid_tile, main_c, detail_c, cx, cy, (i + 0.5) * seg_h)   # climbing shaft
	_spindle_seg(top_tile, main_c, detail_c, cx, cy, (SPINDLE_MID_SEGMENTS + 1.5) * seg_h)  # needle

## One full-tile sprite of the tower, centred at y_center (so its 24px art spans y_center ± seg_h/2).
func _spindle_seg(tile: String, main_c: String, detail_c: String, cx: int, cy: int, y_center: float) -> void:
	var t := _colored_tex(tile, main_c, detail_c, Fill.NONE)
	if t == null:
		return
	var s := _take_sprite()
	s.texture = t
	s.region_enabled = false           # full tile, NOT cropped to its opaque band (columns must align)
	s.position = Vector3(cx, y_center, cy)
	s.visible = true
	s.add_to_group("wm_tile")
	_apply_wm_orient_to(s)
	_track(s)

# --- parasang-scale surface landmarks (the Spindle, Red Rock) ---------------
# On the SURFACE, world-map landmarks are drawn ENORMOUS at the world offset of their parasang, so a
# colossal Spindle / Red Rock looms on the horizon and grows as you walk toward it. Positioned via
# World.global_coord: a landmark at parasang (wx,wy) sits at its global-cell centre minus this zone's
# cell (0,0) global, 1 cell = 1 unit. Geometry is built ONCE at local origin, then each snapshot just
# repositions the node — so ~130 nodes never hit the per-snapshot churn. Fog fades the top into the
# sky; the camera far-plane was lifted to 8000 for them. `pixel` sets scale: a 16px tile -> 16*pixel
# units wide (15 ≈ a parasang / 240, 5 ≈ a zone / 80).
var _landmarks_root: Node3D
var _landmark_built := false
var _landmark_ok := true               # cleared during a build if a needed tile isn't exported yet -> retry
var _landmark_nodes: Array = []        # [{node, wx, wy}] built once, repositioned each snapshot
var _rock_mat: StandardMaterial3D      # shared solid-red-rock material for the Red Rock voxels
const LANDMARK_SPINDLE_SEGMENTS := 8   # shaft tiles between base and needle
const LANDMARK_BRIGHT := Color(1.6, 2.3, 2.7)  # HDR modulate for the Spindle: > glow_hdr_threshold, so it blooms
const RENDER_ROCK_LANDMARK := false  # Red Rock landmark temporarily OFF — flip to true to restore
const ROCK_WALL_TILE := "Assets/Content/Textures/Tiles/wall_rock-11111111.bmp"  # solid rock face, no borders
const LANDMARKS := [
	{"kind": "spindle", "wx": 53, "wy": 3,  "tile": "terrain/sw_spindle_bottom.bmp", "main": "&C^k", "detail": "Y", "pixel": 15.0},
	{"kind": "rock",    "wx": 11, "wy": 20, "tile": "terrain/tile_location7.bmp",     "main": "&r^k", "detail": "R", "pixel": 5.0},
]

## Reposition the (build-once) landmarks for the player's current zone. Surface only — the world map
## draws its own miniature tiles; underground has no sky.
# Landmarks were a GPU-hang source (bisected: off = stable; no crash report -> fillrate, not memory).
# The cause was screen-filling ADDITIVE glow quads. The glow is now done via HDR-bright sprites +
# environment bloom (see Main env.glow_* and LANDMARK_BRIGHT) — a cheap post-process, no per-object
# additive overdraw. LANDMARKS_ENABLED stays as a kill-switch.
const LANDMARKS_ENABLED := true
func _rebuild_landmarks(zone: Dictionary) -> void:
	if not LANDMARKS_ENABLED or _world_map or _underground:
		_landmarks_root.visible = false
		return
	_landmarks_root.visible = true
	if not _landmark_built:
		# Tiles export on sight, so a needed one (esp. the rock wall) may be absent on first build.
		# Retry each snapshot until every tile resolves, THEN freeze (build-once). Cheap + bounded.
		_landmark_built = _build_landmarks()
	var origin := World.global_coord(zone, 0, 0)   # this zone's cell (0,0) in global cells
	for e in _landmark_nodes:
		# centre of the landmark's parasang, in global cells (middle zone zx=zy=1, cell centre)
		var gx: int = (int(e["wx"]) * World.PARASANG + 1) * World.ZONE_W + int(World.ZONE_W / 2.0)
		var gy: int = (int(e["wy"]) * World.PARASANG + 1) * World.ZONE_H + int(World.ZONE_H / 2.0)
		(e["node"] as Node3D).position = Vector3(gx - origin.x, 0.0, gy - origin.y)

## Build each landmark's geometry into its own node at local origin. Returns true when every tile
## resolved; a missing (not-yet-exported) tile clears _landmark_ok so the caller retries next time.
func _build_landmarks() -> bool:
	for c in _landmarks_root.get_children():
		c.queue_free()
	_landmark_nodes.clear()
	_landmark_ok = true
	for lm in LANDMARKS:
		if lm["kind"] == "rock" and not RENDER_ROCK_LANDMARK:
			continue                       # Red Rock temporarily disabled (RENDER_ROCK_LANDMARK)
		var node := Node3D.new()
		_landmarks_root.add_child(node)
		_landmark_nodes.append({"node": node, "wx": int(lm["wx"]), "wy": int(lm["wy"])})
		var px: float = float(lm.get("pixel", 15.0))
		if lm["kind"] == "spindle":
			var seg_h := 24.0 * px
			var bottom := String(lm["tile"])
			# bottom tile is full-height, so centring at seg_h/2 seats its art on the ground; mids/top
			# stack by a full tile each so the shaft columns line up.
			_landmark_sprite(bottom, lm["main"], lm["detail"], Vector3(0, 0.5 * seg_h, 0), px, node, true)
			for i in range(1, LANDMARK_SPINDLE_SEGMENTS + 1):
				_landmark_sprite(bottom.replace("bottom", "mid"), lm["main"], lm["detail"], Vector3(0, (i + 0.5) * seg_h, 0), px, node, true)
			_landmark_sprite(bottom.replace("bottom", "top"), lm["main"], lm["detail"], Vector3(0, (LANDMARK_SPINDLE_SEGMENTS + 1.5) * seg_h, 0), px, node, true)
		elif lm["kind"] == "rock":
			_build_rock_outline(lm, node, px)
	return _landmark_ok

## Red Rock as an EXTRUDED OUTLINE: read the world-map tile's silhouette mask and, for each column,
## stack red rock-wall voxels from the ground up to that column's TOP opaque row — so the mound's top
## profile matches the Red Rock outline. Voxels are square QuadMeshes sharing one solid-red-rock
## material (wall_rock recoloured, filled). No glow — a rock is a mass, not a beacon.
func _build_rock_outline(lm: Dictionary, parent: Node, px: float) -> void:
	var mask := _mask(String(lm["tile"]))
	if mask == null:
		_landmark_ok = false          # silhouette tile not exported yet — retry
		return
	var mat := _rock_voxel_material(lm["main"], lm["detail"])
	if mat == null:
		# rock-wall tile not exported yet: show a flat card for now, and retry to upgrade to voxels.
		_landmark_sprite(String(lm["tile"]), lm["main"], lm["detail"], Vector3(0, 12.0 * px, 0), px, parent, false)
		_landmark_ok = false
		return
	var w := mask.get_width()
	var h := mask.get_height()
	# ground line = the lowest opaque row anywhere (the base of the silhouette)
	var base_row := 0
	for x in w:
		for y in range(h - 1, -1, -1):
			if mask.get_pixel(x, y).a > 0.0:
				base_row = maxi(base_row, y)
				break
	var vox := px                                  # one tile-column wide/tall in world units
	# ONE shared QuadMesh for every voxel — creating a separate mesh per voxel meant ~100+ GPU
	# mesh-buffer allocations in a single frame, which overran the Metal allocator and crashed.
	var quad := QuadMesh.new()
	quad.size = Vector2(vox, vox)
	for x in w:
		var top := -1
		for y in h:
			if mask.get_pixel(x, y).a > 0.0:
				top = y
				break
		if top < 0:
			continue                               # empty column
		var vx := (float(x) - (w - 1) * 0.5) * vox # centre the columns on the node origin
		for row in range(top, base_row + 1):       # fill from the outline top down to the ground
			var vy := float(base_row - row) * vox + vox * 0.5
			var m := MeshInstance3D.new()
			m.mesh = quad                          # shared — one buffer, not one per voxel
			m.material_override = mat
			m.position = Vector3(vx, vy, 0)
			parent.add_child(m)

func _rock_voxel_material(main_c: String, detail_c: String) -> StandardMaterial3D:
	if _rock_mat != null:
		return _rock_mat
	var tex := _colored_tex(ROCK_WALL_TILE, main_c, detail_c, Fill.ALL)   # solid red rock face
	if tex == null:
		return null
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y   # the mound turns to face the camera
	m.billboard_keep_scale = true
	_rock_mat = m
	return m

## One giant landmark sprite at local `pos` under `parent`, billboarded upright. `glow` adds an
## ADDITIVE copy so it reads as a luminous beacon (the Spindle) rather than a thin dim thread.
func _landmark_sprite(tile: String, main_c: String, detail_c: String, pos: Vector3, px: float, parent: Node, glow: bool) -> void:
	var t := _colored_tex(tile, main_c, detail_c, Fill.NONE)
	if t == null:
		_landmark_ok = false          # tile not exported yet — caller retries
		return
	var s := Sprite3D.new()
	s.texture = t
	s.pixel_size = px
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.transparent = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y    # upright, turns to face the camera
	s.position = pos
	if glow:
		# HDR-bright, so the environment bloom haloes it into a luminous beacon. The sprite is
		# alpha-scissored to the thin shaft, so this costs almost no fill — unlike the old additive
		# quad (full 240x360, 10 of them, overlapping) that hung the GPU.
		s.modulate = LANDMARK_BRIGHT
	parent.add_child(s)

## True if this object is a mobile creature. Prefers the mod's `creature` flag,
## falls back to `sinks` (IsCreature && !IsFlying) for a snapshot from a mod build
## that predates the flag.
func _is_creature(obj: Dictionary) -> bool:
	return bool(obj.get("creature", obj.get("sinks", false)))

## Glowfish specifically: the orbiting "bug" motes are theirs alone (that's what the fish
## do in Qud). Keyed on the tile name — the blueprint isn't always in the per-object payload.
func _is_glowfish(obj: Dictionary) -> bool:
	return String(obj.get("tile", "")).to_lower().contains("glowfish")

## Should this object get the bioluminescent GLOW bloom? True for built-in glow-* tiles
## (glowfish, glowpad, glowmoth, …) and for any tile the user tagged "glow" via the report
## form (an `effect` override). Purely visual — separate from the motes above.
func _should_glow(obj: Dictionary) -> bool:
	var tile := String(obj.get("tile", "")).to_lower()
	if tile.contains("glow"):
		return true
	return _glow_overrides.has(tile_family(tile))

# ── TENT WALL (Daniel, 2026-08-12: "These textures are a mixture of tent poles and
# animal skins. Let's turn the vertical rectangles into cylinders and the animal skin
# into a slab.") ────────────────────────────────────────────────────────────────────
# The tent_<dirs> family (Tam's canvas walls) uses connection-set naming like fences.
# Per tile: ONE pole — the narrow full-band vertical run in the art — becomes a
# CYLINDER at the cell centre; each connected direction grows a HALF-SLAB of skin from
# the pole to that cell edge. E/W half-slabs carry the art's own side panels (each is
# exactly 6px = half a cell); N/S runs have no face art in the tile, so they get a
# plain canvas-coloured slab sampled from the art. Heights come from the art's band.
## Panel bboxes + colour image for a tent tile variant — used for the tile itself and,
## when a variant's art lacks the opposite panel (tent_e has no W half), for the
## family's _ew variant, which always carries both. {} on failure.
func _tent_panels_of(tile: String, obj: Dictionary) -> Dictionary:
	var mask := _mask(tile)
	var ctex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj))
	if mask == null or ctex == null:
		return {}
	var w := mask.get_width()
	var h := mask.get_height()
	var top := -1
	var bottom := -1
	for y in h:
		for x in w:
			if mask.get_pixel(x, y).a >= 0.5:
				bottom = y
				if top < 0:
					top = y
				break
	if bottom < 0:
		return {}
	var band := bottom - top + 1
	var runs := []
	var rs := -1
	var need_h := int(ceil(band * 0.8))
	for x in w:
		var n := 0
		for y in range(top, bottom + 1):
			if mask.get_pixel(x, y).a >= 0.5:
				n += 1
		if n >= need_h:
			if rs < 0:
				rs = x
		else:
			if rs >= 0:
				runs.append([rs, x - 1])
				rs = -1
	if rs >= 0:
		runs.append([rs, w - 1])
	var px0 := -1
	var px1 := -1
	var bestd := 1e9
	for r in runs:
		if r[1] - r[0] + 1 <= 3:
			var dc: float = absf((r[0] + r[1]) * 0.5 - w * 0.5)
			if dc < bestd:
				bestd = dc
				px0 = r[0]
				px1 = r[1]
	var panels := {}
	if px0 >= 1:
		var r := _opaque_bbox(mask, 0, px0 - 2, top, bottom)
		if r.size.x > 0:
			panels["w"] = r
	if px1 >= 0 and px1 + 2 < w:
		var r2 := _opaque_bbox(mask, px1 + 2, w - 1, top, bottom)
		if r2.size.x > 0:
			panels["e"] = r2
	return {"img": ctex.get_image(), "sx": ctex.get_width() / float(w), "sy": ctex.get_height() / float(h),
		"top": top, "bottom": bottom, "band": band, "px0": px0, "px1": px1, "panels": panels}

func _place_tentwall(obj: Dictionary, tile: String, cx: int, cy: int, light_frac: float) -> bool:
	var dirs = _connector_dirs(tile)
	if dirs == null:
		return false
	# ALL geometry derives from the family's _ew variant — the canonical elevation.
	# Variant art bands include the OTHER arm drawn edge-on (tent_sw's pole column
	# runs rows 7-22 vs tent_ew's 7-16), which skewed vscale per variant: corner
	# fabric hems hung at different heights than their neighbours ("we need to fix
	# corners"). One canon = every variant renders identical proportions, differing
	# only in which directions exist.
	var ew_tile := tile.replace("_" + String(dirs) + ".", "_ew.")
	var canon := _tent_panels_of(ew_tile, obj)
	if canon.is_empty():
		canon = _tent_panels_of(tile, obj)
	if canon.is_empty():
		return false
	var img: Image = canon["img"]
	var sx: float = canon["sx"]
	var sy: float = canon["sy"]
	var top: int = canon["top"]
	var bottom: int = canon["bottom"]
	var band: int = canon["band"]
	var pole_x0: int = canon["px0"]
	var pole_x1: int = canon["px1"]
	var panels: Dictionary = canon["panels"]
	var ps := PIXEL_SIZE
	var lfc := Color(light_frac, light_frac, light_frac)
	var base := Vector3(cx, 0.0, cy)
	# As tall as the wall blocks around them: the POLE tops out at WALL_H, everything
	# else keeps its art-derived proportion through vscale.
	var wall_h := WALL_H / 1.12
	var vscale: float = wall_h / float(band)
	var skin_c := Color(0.75, 0.65, 0.5)
	var pole_c := Color(0.45, 0.35, 0.25)
	if pole_x0 >= 0:
		pole_c = img.get_pixel(int((pole_x0 + 0.5) * sx), int((top + band * 0.5) * sy))
		skin_c = pole_c
	if panels.has("w"):
		skin_c = img.get_pixel(int((panels["w"].position.x + panels["w"].size.x * 0.5) * sx),
			int((panels["w"].position.y + panels["w"].size.y * 0.5) * sy))
	elif panels.has("e"):
		skin_c = img.get_pixel(int((panels["e"].position.x + panels["e"].size.x * 0.5) * sx),
			int((panels["e"].position.y + panels["e"].size.y * 0.5) * sy))
	# THE POLE: body + CAP in the art's own top colour (the cap is the run of rows
	# from the pole top whose colour matches the top pixel — Qud: "poles have a red top").
	var pole_w: float = (pole_x1 - pole_x0 + 1) * ps if pole_x0 >= 0 else 2.0 * ps
	var pole_h: float = wall_h * 1.12
	var cap_px := 0
	var cap_c := pole_c
	if pole_x0 >= 0:
		var pcx := int((pole_x0 + 0.5) * sx)
		cap_c = img.get_pixel(pcx, int((top + 0.5) * sy))
		for y in range(top, bottom + 1):
			var c := img.get_pixel(pcx, int((y + 0.5) * sy))
			if c.is_equal_approx(cap_c) or (abs(c.r - cap_c.r) + abs(c.g - cap_c.g) + abs(c.b - cap_c.b)) < 0.12:
				cap_px += 1
			else:
				break
		if cap_px >= band:
			cap_px = 0
		pole_c = img.get_pixel(pcx, int((top + cap_px + 1.0) * sy)) if cap_px > 0 else pole_c
	var cap_h: float = cap_px * vscale
	# THE POLE: a 2x2x24 voxel column, not a cylinder (Daniel: "turn the cylinder
	# poles into a 2x2x24 voxel pole. Same colors — it fits better with the
	# aesthetic — it should help generalize the algorithm"). 24 stacked voxels span
	# the height the cylinder had (pole_h == WALL_H), matching the walls' 24 rows;
	# the cross-section is the art's own pole COLUMNS at PIXEL_SIZE, the scale the
	# fabric uses, so the pole stays exactly as thick and tall as before and only
	# its section changes. (The wall lattice is 24 rows too but its footprint fills
	# the 1-unit cell, not 16 art px — the two agree vertically, not across.) A
	# family with a 3px pole builds 3x3 with no change here, and the art's red top
	# becomes the top run of voxels.
	var pn: int = maxi(1, pole_x1 - pole_x0 + 1) if pole_x0 >= 0 else 2
	var vh: float = pole_h / 24.0
	var cap_v: int = clampi(int(round(cap_h / vh)), 0, 24)
	var pst := SurfaceTool.new()
	pst.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vy in 24:
		var vc: Color = cap_c if vy >= 24 - cap_v else pole_c
		for vx in pn:
			for vz in pn:
				_vox_block(pst,
					base + Vector3((vx - pn * 0.5) * ps, vy * vh, (vz - pn * 0.5) * ps),
					Vector3(ps, vh, ps), vc * lfc,
					[vx == 0, vx == pn - 1, vy == 0, vy == 23, vz == 0, vz == pn - 1])
	var pmesh := ArrayMesh.new()
	pst.commit(pmesh)
	var cmi := MeshInstance3D.new()
	cmi.mesh = pmesh
	cmi.material_override = _vox_skin_material()
	_spawn_parent().add_child(cmi)
	_track(cmi)
	# FABRIC: hung (art bbox through vscale = the ground gap), off the pole (one art
	# px gap), spanning to the cell edge.
	var gapw := 0.5 / 8.0
	var fab_y0 := vscale * 1.0
	var fab_h: float = wall_h - fab_y0
	var fref: Rect2i = panels["w"] if panels.has("w") else (panels["e"] if panels.has("e") else Rect2i(0, 0, 0, 0))
	if fref.size.y > 0:
		fab_y0 = (bottom + 1 - (fref.position.y + fref.size.y)) * vscale
		fab_h = fref.size.y * vscale
	var fab_len: float = 0.5 - pole_w * 0.5 - gapw
	var skin_mat := _color_material(skin_c * lfc)
	for d in dirs:
		var horiz: bool = d == "e" or d == "w"
		var fmid: float = pole_w * 0.5 + gapw + fab_len * 0.5
		var off := Vector3.ZERO
		match d:
			"e": off = Vector3(fmid, 0, 0)
			"w": off = Vector3(-fmid, 0, 0)
			"n": off = Vector3(0, 0, -fmid)
			"s": off = Vector3(0, 0, fmid)
		# Half-assignment: the fence path's convention (E-half for e AND s, W-half
		# for w AND n; see _fence_half) — runs compose and corners join cleanly.
		var ad: String = "e" if (d == "e" or d == "s") else "w"
		if not panels.has(ad):
			# canon without that panel (family has no _ew art at all): plain slab
			var slab := BoxMesh.new()
			slab.size = Vector3(fab_len, fab_h, 1.5 * ps) if horiz else Vector3(1.5 * ps, fab_h, fab_len)
			var smi := MeshInstance3D.new()
			smi.mesh = slab
			smi.material_override = skin_mat
			smi.position = base + off + Vector3(0.0, fab_y0 + fab_h * 0.5, 0.0)
			_spawn_parent().add_child(smi)
			_track(smi)
			continue
		# VOXEL FABRIC (Daniel: "would it be easier to construct these as
		# 'minecraft' blocks ... trying to construct geometric areas to cover the
		# edges of the rectangular prisms"). One block per opaque art pixel, one
		# art px deep, and a face wherever the neighbouring block is absent.
		# Watertight by construction — the silhouette, the hem holes and the recess
		# beside the pole all close themselves — so there is no rule about WHICH
		# edges to cap. Four hand-written rules got that wrong in a row, each
		# guessing at the art (the halves are not mirror images: tent_ew holds its
		# east panel 2px off the pole at rows 10-14 where the west panel is flush).
		# The seam needs no rule either: at a join the neighbour tent's blocks abut
		# in the same plane, so those faces are buried, and at the end of a run they
		# are exposed and the run caps itself.
		var rfr: Rect2i = panels[ad]
		var fsub := img.get_region(Rect2i(int(rfr.position.x * sx), int(rfr.position.y * sy),
			int(rfr.size.x * sx), int(rfr.size.y * sy)))
		var nx: int = rfr.size.x
		var ny: int = rfr.size.y
		if nx <= 0 or ny <= 0:
			continue
		var pw: float = fab_len / float(nx)
		var phh: float = fab_h / float(ny)
		var hd: float = 0.75 * ps
		var stw := SurfaceTool.new()
		stw.begin(Mesh.PRIMITIVE_TRIANGLES)
		for j in ny:
			for i in nx:
				var c := fsub.get_pixel(int((i + 0.5) * sx), int((j + 0.5) * sy))
				if c.a < 0.5:
					continue
				var a0: float = i * pw
				var a1: float = a0 + pw
				var y1f: float = fab_h - j * phh
				var y0f: float = y1f - phh
				# [shade, the face's 4 corners in (a, y, d)]. The sheet is ONE block
				# deep, so both broad faces always show; the four rims are neighbour-gated.
				var faces: Array = [
					[1.00, [[a0, y0f, hd], [a1, y0f, hd], [a1, y1f, hd], [a0, y1f, hd]]],
					[1.00, [[a1, y0f, -hd], [a0, y0f, -hd], [a0, y1f, -hd], [a1, y1f, -hd]]],
				]
				if not _tent_px(fsub, sx, sy, i - 1, j, nx, ny):
					faces.append([0.72, [[a0, y0f, -hd], [a0, y0f, hd], [a0, y1f, hd], [a0, y1f, -hd]]])
				if not _tent_px(fsub, sx, sy, i + 1, j, nx, ny):
					faces.append([0.72, [[a1, y0f, hd], [a1, y0f, -hd], [a1, y1f, -hd], [a1, y1f, hd]]])
				if not _tent_px(fsub, sx, sy, i, j - 1, nx, ny):
					faces.append([0.92, [[a0, y1f, hd], [a1, y1f, hd], [a1, y1f, -hd], [a0, y1f, -hd]]])
				if not _tent_px(fsub, sx, sy, i, j + 1, nx, ny):
					faces.append([0.50, [[a0, y0f, -hd], [a1, y0f, -hd], [a1, y0f, hd], [a0, y0f, hd]]])
				for fdef in faces:
					var shade: float = fdef[0]
					var wc := Color(c.r * shade, c.g * shade, c.b * shade) * lfc
					var q4: Array = fdef[1]
					for k in [0, 1, 2, 0, 2, 3]:
						var v: Array = q4[k]
						var p3: Vector3
						if horiz:
							p3 = base + off + Vector3(v[0] - fab_len * 0.5, fab_y0 + v[1], v[2])
						else:
							p3 = base + off + Vector3(v[2], fab_y0 + v[1], v[0] - fab_len * 0.5)
						stw.set_color(wc)
						stw.set_normal(Vector3.UP)
						stw.add_vertex(p3)
		var fmesh := ArrayMesh.new()
		stw.commit(fmesh)
		var fmi := MeshInstance3D.new()
		fmi.mesh = fmesh
		fmi.material_override = _vox_skin_material()
		_spawn_parent().add_child(fmi)
		_track(fmi)
	return true

## Is the art pixel at panel-grid (i, j) opaque? Out of bounds = transparent
## (the silhouette edge gets a wall).
func _tent_px(sub: Image, sxs: float, sys_: float, i: int, j: int, nx: int, ny: int) -> bool:
	if i < 0 or j < 0 or i >= nx or j >= ny:
		return false
	return sub.get_pixel(int((i + 0.5) * sxs), int((j + 0.5) * sys_)).a >= 0.5

## Raw-opaque bounding box within a column range, as a Rect2i (size.x == 0 when empty).
func _opaque_bbox(mask: Image, x0: int, x1: int, y0: int, y1: int) -> Rect2i:
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := Vector2i(-1, -1)
	for y in range(y0, y1 + 1):
		for x in range(maxi(x0, 0), x1 + 1):
			if mask.get_pixel(x, y).a >= 0.5:
				lo.x = mini(lo.x, x)
				lo.y = mini(lo.y, y)
				hi.x = maxi(hi.x, x)
				hi.y = maxi(hi.y, y)
	if hi.x < 0:
		return Rect2i(0, 0, 0, 0)
	return Rect2i(lo.x, lo.y, hi.x - lo.x + 1, hi.y - lo.y + 1)

# ── SIGNPOST (Daniel, 2026-08-12: "turn the selected sign into voxels. Two posts and
# then a slab for the pboard") ──────────────────────────────────────────────────────
# A tile-derived 3D shape, verdict "signpost" in overrides.json. Geometry comes from
# the MASK, not constants: the BOARD is the contiguous band of rows whose opaque width
# is >= 60% of the tile, the POSTS are the opaque column-runs in the rows outside that
# band, running ground to the posts' topmost row. The slab is a solid box (frame
# colour sampled from the art) with the recoloured board art on front and back quads —
# transparent lettering pixels punch through to the box face a millimetre behind, so
# letters read as carved, not as holes. Faces N-S (the panel verdicts' convention).
func _place_signpost(obj: Dictionary, tile: String, cx: int, cy: int, light_frac: float) -> bool:
	var mask := _mask(tile)
	# The FILLED texture, same as the billboard path: this art's board face is mostly
	# TRANSPARENT (a frame plus lettering), and an unfilled quad under alpha-scissor
	# discards the face down to red slats (measured). Interior fill gives the solid
	# board the billboard always had; the fill override channel still applies.
	var ctex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj),
		_fill_for(tile, Fill.INTERIOR))
	if mask == null or ctex == null:
		return false
	var w := mask.get_width()
	var h := mask.get_height()
	# Board rows are detected by raw row SPAN (first..last opaque), not opaque count
	# and not the filled mask. Count fails on lettering-over-frame faces (five slats,
	# one per letter stroke); the filled mask fails the other way — the slot pass
	# bridges the gap BETWEEN the post tops, those rows read wide, and the slab
	# stretched to the full art height (Daniel: "crop the sign to the rectangular
	# sign-part"). The board's frame runs edge to edge on every one of its rows; the
	# posts never span more than ~60%. 70% of the tile width splits them cleanly.
	var widths := []   # per-row SPAN in px
	var bottom := -1
	var top := -1
	for y in h:
		var lo_x := -1
		var hi_x := -1
		for x in w:
			if mask.get_pixel(x, y).a >= 0.5:
				if lo_x < 0:
					lo_x = x
				hi_x = x
		widths.append(0 if lo_x < 0 else hi_x - lo_x + 1)
		if lo_x >= 0:
			bottom = y
			if top < 0:
				top = y
	if bottom < 0:
		return false
	# board = the longest contiguous run of wide-SPAN rows
	var need := int(ceil(w * 0.7))
	var b0 := -1; var b1 := -1; var r0 := -1
	for y in h + 1:
		var wide: bool = y < h and widths[y] >= need
		if wide and r0 < 0:
			r0 = y
		if not wide and r0 >= 0:
			if b0 < 0 or (y - r0) > (b1 - b0 + 1):
				b0 = r0; b1 = y - 1
			r0 = -1
	if b0 < 0:
		return false
	# posts = column-run GROUPS across every raw-opaque row below the board (falling
	# back to the rows above it): runs that overlap in x merge into one post, so a
	# 1px ankle row and a 2px foot row make one 2px post, not two.
	var post_rows := []
	for y in range(b1 + 1, bottom + 1):
		post_rows.append(y)
	if post_rows.is_empty():
		for y in range(top, b0):
			post_rows.append(y)
	var posts := []   # [ [x_start, x_end] ]
	var probe := -1
	for y in post_rows:
		probe = y   # colour sample row: the last real post row
		var x := 0
		while x < w:
			if mask.get_pixel(x, y).a >= 0.5:
				var run := x
				while run < w and mask.get_pixel(run, y).a >= 0.5:
					run += 1
				var merged := false
				for pr in posts:
					if x <= pr[1] + 1 and run - 1 >= pr[0] - 1:
						pr[0] = mini(pr[0], x)
						pr[1] = maxi(pr[1], run - 1)
						merged = true
						break
				if not merged:
					posts.append([x, run - 1])
				x = run
			else:
				x += 1
	var img := ctex.get_image()
	# The recoloured texture may be UPSCALED from the 16x24 art — every pixel sample and
	# the atlas region below must map mask coords through this scale, or the quad shows
	# a stretched corner window of the art (measured: red slats + letter strokes).
	var sx := ctex.get_width() / float(w)
	var sy := ctex.get_height() / float(h)
	var lfc := Color(light_frac, light_frac, light_frac)
	var ps := PIXEL_SIZE
	var base := Vector3(cx, 0.0, cy)
	# Board rect + the board's own frame colour (sampled from the first raw-opaque
	# pixel; a fixed corner probe used to land on transparent and fall back to
	# near-black — Daniel: sides should be the same brown as the front).
	var lo := w
	var hi := -1
	for y in range(b0, b1 + 1):
		for x in w:
			if mask.get_pixel(x, y).a >= 0.5:
				lo = mini(lo, x)
				hi = maxi(hi, x)
	if hi < lo:
		return false
	var slab_c := Color(0.45, 0.25, 0.2)
	var sc_found := false
	for y in range(b0, b1 + 1):
		for x in range(lo, hi + 1):
			if mask.get_pixel(x, y).a >= 0.5:
				slab_c = img.get_pixel(int((x + 0.5) * sx), int((y + 0.5) * sy))
				sc_found = true
				break
		if sc_found:
			break
	# VOXEL BUILD (Daniel: "let's voxelize the signpost the same way"). One block per
	# art pixel over a 4px depth — [face][core][core][face] — so the two boards still
	# sandwich the posts exactly as the box build did, and _vox_block culls every
	# interior face. Two things fall out that the box build had to fake:
	#  · pixels the raw mask leaves TRANSPARENT inside the board keep only the CORE
	#    layers, so the lettering is carved 1px into both faces and its walls and floor
	#    are real geometry. The box build painted an alpha-scissor quad over a backing
	#    box a millimetre behind to imply the same thing.
	#  · posts occupy the core layers only, which is what put them "behind the slab"
	#    before — now it is the same lattice rather than a hand-placed z offset.
	# Row y sits at world (bottom - y) * ps, so the art's own baseline lands on the
	# ground and the board keeps the height the slab had.
	var post_c := Color(0.3, 0.25, 0.2)
	if probe >= 0 and not posts.is_empty():
		var ppx: int = int((posts[0][0] + posts[0][1]) / 2.0)
		post_c = img.get_pixel(int((ppx + 0.5) * sx), int((probe + 0.5) * sy))
	var solid := {}
	for y in range(top, bottom + 1):
		for x in w:
			var in_board: bool = y >= b0 and y <= b1 and x >= lo and x <= hi
			var in_post := false
			for pr in posts:
				if x >= pr[0] and x <= pr[1]:
					in_post = true
					break
			if not in_board and not in_post:
				continue
			var c := img.get_pixel(int((x + 0.5) * sx), int((y + 0.5) * sy))
			if c.a < 0.5:
				c = post_c if not in_board else slab_c
			var faced: bool = in_board and mask.get_pixel(x, y).a >= 0.5
			for k in ([0, 1, 2, 3] if faced else [1, 2]):
				solid[Vector3i(x, y, k)] = c
	if solid.is_empty():
		return false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for key in solid:
		var v: Vector3i = key
		# world +Y is the PREVIOUS art row, so the up/down neighbours are y-1 / y+1
		_vox_block(st,
			base + Vector3((v.x - w * 0.5) * ps, (bottom - v.y) * ps, (v.z - 0.5) * ps),
			Vector3(ps, ps, ps), solid[key] * lfc,
			[not solid.has(v + Vector3i(-1, 0, 0)), not solid.has(v + Vector3i(1, 0, 0)),
			 not solid.has(v + Vector3i(0, 1, 0)), not solid.has(v + Vector3i(0, -1, 0)),
			 not solid.has(v + Vector3i(0, 0, -1)), not solid.has(v + Vector3i(0, 0, 1))])
	var smesh := ArrayMesh.new()
	st.commit(smesh)
	var smi := MeshInstance3D.new()
	smi.mesh = smesh
	smi.material_override = _vox_skin_material()
	_spawn_parent().add_child(smi)
	_track(smi)
	return true

# ── WINNER PER CELL (Daniel, 2026-08-12): "stop fighting and just do what Qud does.
# Hide the items underneath the top item (NPC > pretty much everything else)." ──────
# Qud renders ONE object per cell; user mode now does the same instead of stacking
# billboards. Two halves, because statics build once and creatures move every turn:
#  - The STATIC pass ranks the cell's non-creature billboards (layer, wire idx) and
#    places only the winner; everything beneath it notes HIDDEN and never spawns.
#    Creatures are deliberately NOT in these ranks — a static decision based on a
#    creature goes stale the moment it walks away (the cushion would stay invisible).
#  - The DYNAMIC pass draws creatures over that static winner, and hides/reveals the
#    winner AT RUNTIME per turn: occupied cell -> static winner invisible (the NPC is
#    the cell's face), creature leaves -> winner pops back. No rebuilds involved.
# Connectors (fences, pipes) and prisms are architecture, outside the contest.
func _stack_ranks(cell: Dictionary) -> Dictionary:
	var members := []
	var i := 0
	for obj in cell.get("objs", []):
		var o: Dictionary = obj
		if float(o.get("layer", 0)) >= 1.0 and not _is_prism(o) and not _is_creature(o) \
				and not _is_connector(o, String(o.get("tile", ""))):
			members.append({"i": i, "l": float(o.get("layer", 0))})
		i += 1
	members.sort_custom(func(a, b):
		if a["l"] != b["l"]: return a["l"] < b["l"]
		return a["i"] < b["i"])
	var out := {}
	for r in members.size():
		out[members[r]["i"]] = {"rank": r, "below": members.size() - 1 - r}
	return out

## LIVE zone's static winner sprite per cell, so the dynamic pass can hide it under a
## creature and reveal it again — cleared with every live static (re)build: live-zone
## cell coords collide across zones, and the sprites die with the subtree anyway.
var _cell_top_static := {}   # Vector2i -> Sprite3D

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool, sink := 0.0, wet := false, skip_creatures := false, stair_cell := false, light_frac := 1.0, rank := -1, below := 0, ground_show := false) -> void:
	# Static builds exclude creatures (they render per step in _rebuild_dynamics);
	# remembered zones drop them entirely (they've wandered off since last live).
	if skip_creatures and _is_creature(obj):
		return
	var tile := String(obj.get("tile", ""))
	# Per-object gap-fill bg: the ^X of the EFFECTIVE tile colour — TILECOLOR
	# when set (Starship '^W' gold, HangarWall '^Y'), else ColorString (the
	# creepers' '^w' tan lives there; Qud seeds its render event the same way).
	_wall_bg = _parse_bg(_bg_source(obj))

	# No tile means GLYPH MODE: Qud draws the RenderString in the console font
	# (base blueprints like MountedFurniture render a pale '?', NephilimShrine
	# its sigil). The mod only ships tile-less objects that HAVE a glyph —
	# invisible bookkeeping widgets (DaylightWidget, ZoneMusic, Landmark*) are
	# filtered mod-side on Render.Visible, so "skip everything without a tile"
	# now skipped real renders (checker: the '?' cluster drew a bare field).
	if tile == "":
		var g := String(obj.get("glyph", ""))
		if g == "":
			_note(cx, cy, idx, "skipped(no tile, no glyph — not drawn by Qud)", 0.0)
			return
		var gl := _take_label()
		gl.text = _cp437(g)
		gl.modulate = _qud_color(String(obj.get("color", "")))
		# Qud fills most of the cell with the glyph and seats it high (measured
		# off the checker's '?'/'Σ' probes); default label size read ~2/3 scale
		# and centred low.
		gl.font_size = 88
		gl.position = Vector3(cx, 0.5 + idx * LAYER_STEP, cy - 0.05)
		gl.visible = true
		_track(gl)
		_note(cx, cy, idx, "label(glyph-mode — Qud draws RenderString)", gl.position.y)
		return

	# THE shared precedence rule (compound colour beats tilecolor) — this string ALSO keys
	# the material cache, so the old tilecolor-first derivation made a tarry soup pool
	# ('&c^C&K', fg K) collide with a plain soup pool ('&c') and serve the wrong material.
	var main_c := _pick_color_string(obj)
	var detail_c := String(obj.get("detail", ""))
	# The COLOUR-STRING pair, ghosted for a zone you are not in — the string counterpart of
	# _art_colors. The water surface builds its material from these rather than from the texture,
	# so without this a pool one step over the border stayed frankly blue while everything around
	# it had gone to memory. "K"/"k" are Qud's own memory pair, the same two _art_colors uses.
	if _remembered_build:
		main_c = "K"
		detail_c = "k"
	var layer := int(obj.get("layer", 99))

	# Anything flagged Bridge (bridge, walkway, hut floor) is a DECK, not scenery:
	# flat and OPAQUE. The brick art is line-work on a transparent field, so it
	# only hides what's beneath once the gaps are filled with the ground colour.
	# Only a deck spanning water gets lifted to bridge height; a hut floor stays
	# down with the other floor quads so its edges don't step up off the ground.
	if bool(obj.get("bridge", false)) and not in_wall:
		var deck := _colored_tex(tile, main_c, detail_c, Fill.ALL)
		if deck != null:
			var d := _take_floor()
			d.material_override = _deck_material(tile, main_c, detail_c, deck)
			d.scale = Vector3.ONE
			var y := (BRIDGE_Y + idx * TIEBREAK) if wet else (FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK + _dyn_lift_1to1)
			d.position = Vector3(cx, y, cy)
			d.visible = true
			_track(d)
			_note(cx, cy, idx, "deck(over water)" if wet else "deck(on ground)", y)
			return

	# A filed FILL verdict applies to the tile's texture everywhere it draws (the fill axis is
	# independent of shape): fill-holes turns the water wheel's see-through slats opaque in the
	# FLAT path too — Qud shows them solid, and the old 3D panel path was the only place the
	# verdict used to reach. Unfiled tiles keep Fill.NONE (transparent as-loaded) —
	# EXCEPT when TILECOLOR carries a ^X background: Qud paints that behind the
	# art for EVERY object, wall or not (Starship '^W' gold frames, HangarWall
	# '^Y', the creepers' '^w' tan field — Jilted Lover / Livid Creeper read
	# 63/53 on a bare teal cell before this). The old occluding-only gate
	# survived 391 ^ carriers because most are ^k/^K — the field colour itself,
	# a visual no-op — or full-coverage art. Plain no-^ tiles keep transparent
	# gaps: their Qud render shows the terrain through, and 213 bright-baseline
	# walls pass on exactly that behaviour.
	var wall_fill := Fill.ALL if _wall_bg != "" else Fill.NONE
	# THE ONE PLACE A NEIGHBOUR'S COLOURS ARE DECIDED. Everything _place_cell builds for a zone you
	# are not standing in — floors, water surfaces, derived meshes, billboards — is recoloured to
	# Qud's memory pair here, so the whole zone reads as out of sight rather than only its sprites.
	# Doing it at the TEXTURE is what catches the batched floors: they are MultiMeshes keyed by
	# material, so there is no per-cell node to tint afterwards. A water tile one step over the
	# border was the tell — still frankly blue under a ramp that had only dimmed it 18%.
	var ac: Array = _art_colors(obj)
	var tex := _colored_tex_rgb(tile, ac[0], ac[1], ac[2], _fill_for(tile, wall_fill))

	# A filed verdict overrides everything below it. This is how facts that are not
	# in Qud's data get in: nothing in `sw_waterwheel_1` says the wheel runs
	# east-west, so a human says it and this honours it.
	var verdict := _override_for(tile)
	if verdict == "skip":
		_note(cx, cy, idx, "skipped(user verdict: not drawn)", 0.0)
		return
	# Flat (1:1 / 2D) mode: an UPRIGHT panel is edge-on — invisible — under the straight-down
	# camera (the "water wheel not showing up" bug: its panel_ew override stood it up). The
	# verdict's orientation is a 3D fact; in flat mode the object falls through to the floor
	# path and draws as its plain tile, exactly as Qud does.
	if (verdict == "panel_ew" or verdict == "panel_ns") and not _flat_2d:
		var vtex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj))
		if vtex != null:
			var axis := "ew" if verdict == "panel_ew" else "ns"
			var vh := _panel_height(obj, tile)
			_place_connector(tile, main_c, detail_c, cx, cy, axis, vh,
				_fill_for(tile, Fill.ALL if bool(obj.get("occluding", false)) else Fill.NONE), -1.0, light_frac,
				String(obj.get("animSched", "")))
			_note(cx, cy, idx, "connector panels [%s] h=%.2f %s (user verdict)" % [axis, vh, _connector_note(tile)], vh * 0.5)
			return

	if verdict == "signpost" and not _flat_2d and not _one_to_one:
		if _place_signpost(obj, tile, cx, cy, light_frac):
			_note(cx, cy, idx, "signpost(voxel: board 4 deep, lettering carved, posts in the core, user verdict)", 0.5)
			return
		# fall through to the billboard path if the art defeats the mesh derivation

	if verdict == "waterwheel" and not _flat_2d and not _one_to_one:
		if _place_waterwheel(obj, tile, cx, cy, light_frac):
			_note(cx, cy, idx, "waterwheel(%d-spoke profile EXTRUDED along an E-W axle, voxel, user verdict)" % WHEEL_PANELS, 0.5)
			return
		# fall through to the billboard path if the art defeats the derivation

	if verdict == "tentwall" and not _flat_2d and not _one_to_one:
		if _place_tentwall(obj, tile, cx, cy, light_frac):
			_note(cx, cy, idx, "tentwall(voxel: fabric 1 block deep + 2x2x24 pole columns, user verdict)", 0.4)
			return
		# fall through (connector panels) if the art defeats the derivation

	# Stairs down: a shaft into the level below, not a flat tile. Qud's StairsDown is
	# a vertical connector with no lateral facing, so unless a direction is supplied
	# (data field or a user override) we GUESS the descent axis. Build a framed
	# opening + a descending voxel flight in place of the sprite. Skipped if the user
	# filed a verdict that forces the normal floor/billboard path.
	if _is_stairs_down(obj, tile) and verdict != "billboard" and verdict != "floor" and not in_wall and not _flat_2d:
		var deg := _stair_dir_deg(obj, tile)
		_place_stairs_down(cx, cy, obj, tile, main_c, detail_c, deg)
		_note(cx, cy, idx, "stairs-down (framed floor tile, face %s)" % _deg_cardinal(deg), STAIR_FRAME_H)
		return

	# Stairs up: just the tile laid FLAT on the floor (Qud's '<' on the ground). No frame
	# or shaft — you ascend, there's nothing to see below. Its layer (7) would otherwise
	# make it an upright billboard, so intercept and route to the floor. Filled so the
	# glyph sits on an opaque base like the down-stairs.
	if _is_stairs_up(obj, tile) and verdict != "billboard" and not in_wall:
		var utex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj), Fill.ALL)
		if utex != null:
			var uf := _take_floor()
			uf.material_override = _mesh_material(tile, main_c, detail_c, utex)
			uf.scale = Vector3.ONE
			uf.position = Vector3(cx, FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK + _dyn_lift_1to1, cy)
			uf.visible = true
			_track(uf)
			_note(cx, cy, idx, "stairs-up (flat floor tile)", uf.position.y)
			return

	# The parasang world map is a top-down mosaic of terrain tiles. Laid flat, the compass camera
	# sees them edge-on and foreshortened; standing each one UP as a card reads far better. BUT this
	# is currently DISABLED (WM_STANDING_CARDS = false) while we isolate a Metal driver crash on
	# repeated world-map<->surface transitions — with the flag off the map falls through to the
	# known-good flat batched-floor path (the baseline that never crashed), a clean bisection. The
	# card is a plain Sprite3D tagged "wm_tile" (set_wm_face_ns / set_top_down retarget it live).
	# The Spindle — the great spire, a main-quest landmark — is 3 stacked map tiles (bottom / mid /
	# shaft / top). Flat cards make it a smear; instead build ONE tall vertical tower at the base
	# cell: the flared bottom on the ground, a run of repeatable mid segments climbing up, capped by
	# the needle top. The mid/top map cells are absorbed into that tower (rendered as nothing).
	if WM_STANDING_CARDS and _world_map and not in_wall and not _flat_2d and _is_spindle(tile):
		if tile.to_lower().contains("bottom"):
			_place_spindle_tower(tile, main_c, detail_c, cx, cy)
			_note(cx, cy, idx, "Spindle tower (%d segments up)" % (SPINDLE_MID_SEGMENTS + 2), 0.0)
		else:
			_note(cx, cy, idx, "Spindle (absorbed into the base tower)", 0.0)
		return

	# Water reads as a wall when stood up, so world-map water stays FLAT: skip the card here and
	# fall through to the ordinary floor path (terrain is layer 1 <= FLOOR_LAYER_MAX). It ends up
	# a flat floor quad — an ocean/lake surface, not a blue billboard.
	# User verdicts (report form) override the automatic choice per tile: "floor" forces flat even
	# for land, "billboard" forces a standing card even over water. Otherwise water auto-flattens.
	var wm_card: bool = verdict != "floor" and (verdict == "billboard" or not _is_world_water(tile))
	if WM_STANDING_CARDS and _world_map and not in_wall and not _flat_2d and tex != null and not _is_creature(obj) and wm_card:
		var wtex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj),
			_color_key(obj), _fill_for(tile, Fill.INTERIOR))
		if wtex == null:
			wtex = tex
		var ws := _take_sprite()
		ws.texture = wtex
		ws.flip_h = bool(obj.get("hflip", false))
		ws.flip_v = bool(obj.get("vflip", false))
		_seat(ws, wtex, tile, cx, cy, 0.0, false)   # band bottom on the ground, standing up
		ws.visible = true
		ws.add_to_group("wm_tile")
		_apply_wm_orient_to(ws)                      # follow-camera / EW / flat-in-top-down
		_track(ws)
		_note(cx, cy, idx, "world-map card (%s)" % _wm_orient_name(), ws.position.y)
		return

	# A directional connector (fence / pipe / tent / axle: a `family_<dirs>` tile) must STAND as an
	# oriented panel — never lie flat. It arrives here as a non-prism "wall", but its inherited
	# RenderLayer can be low enough to trip the floor path below, which buries it in the ground and
	# makes it invisible from a low angle (the "fences don't show up in Raves" bug — an IronFence
	# reported RENDERED floor). Decide it HERE, ahead of the floor test, so a fence always stands.
	# An explicit user verdict still wins: with a verdict filed we fall through to its own handling
	# (the panel_ns/ew verdict path above already returned; floor/billboard/skip are honoured below).
	if tex != null and not in_wall and verdict == "" and not _flat_2d and _is_connector(obj, tile):
		var cd = _connector_dirs(tile)
		var csolid := bool(obj.get("occluding", false))
		var cph := _panel_height(obj, tile)
		var cyc: float = FLOAT_Y if position_for(tile) == "float" else cph * 0.5
		_place_connector(tile, main_c, detail_c, cx, cy, cd, cph,
			Fill.ALL if csolid else Fill.NONE, cyc, light_frac, String(obj.get("animSched", "")))
		_note(cx, cy, idx, "connector panels [%s] h=%.2f %s (stood up)" % [
			"post" if cd == "" else cd, cph, _connector_note(tile)], cyc)
		return

	# Qud's painted ground layer is flat by default — dirt, gravel, cracked earth.
	# But vegetation in that layer is cover you stand among, not a texture you walk
	# on, so it reads far better standing up. Route it to the billboard path.
	var upright_ground: bool = bool(obj.get("ground", false)) and _is_vegetation(tile)
	if verdict == "billboard":
		upright_ground = true        # force it off the floor path
	var as_floor: bool = _flat_2d or (layer <= FLOOR_LAYER_MAX and not upright_ground) or verdict == "floor"

	if as_floor:
		if in_wall and not ground_show:
			_note(cx, cy, idx, "skipped(under wall)", 0.0)
			return  # hidden under a wall; don't bother
		if stair_cell:
			_note(cx, cy, idx, "skipped(floor over stair opening)", 0.0)
			return  # would cap the shaft; the frame lip is the floor here
		# A STANDALONE PUDDLE OBEYS THE WINNER RULE. Qud draws one thing per cell, so the puddle
		# under the watervine at (8,5) is not on screen there at all — Raves drew both, because
		# floors are exempt from the contest, and that is where the "extra puddles" came from.
		#
		# AUTOTILED water keeps the exemption. deep-/shallow- carry an 8-bit neighbour signature:
		# they are a connected body you stand IN, and dropping the river under a bridge, under
		# the mill's axles, or under a submerged glowfish would look broken — that exemption was
		# put there for exactly those. puddle_N has no neighbours and is precisely the detail Qud
		# discards. 9 of 60 liquid cells in Joppa are covered; only 2 are standalone puddles.
		if below > 0 and not _one_to_one and not _flat_2d and _is_standalone_puddle(tile):
			_note(cx, cy, idx, "puddle HIDDEN beneath the cell's winner (Qud winner rule)", 0.0)
			return
		# Floors were one MeshInstance3D per cell — 2000 draw calls on the world map, which
		# tanked the framerate. Batch them by material into a MultiMesh instead (flushed at the
		# end of the build): one draw call per tile type. Floors are static, so this is free.
		var y := FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK + _dyn_lift_1to1
		var fmat: Material
		var fscale := Vector3.ONE
		var fkind := "floor"
		if tex != null:
			fmat = _mesh_material(tile, main_c, detail_c, tex)
			# WATER reads as a surface you can see INTO, not a painted floor:
			# genuinely translucent over an opaque near-black depths backing
			# (Daniel: "if the fish below the waterline is visible, then the
			# water-floor is too opaque" — the submerged glow ghost implies
			# translucency, so the surface must honour it). USER mode only:
			# 1:1 and flat-2D keep the opaque floor Qud parity is measured on.
			#
			# THE TEST IS THE WIRE'S OWN `liquid` FLAG, not the tile name. It used to be
			# _is_world_water(), which lowercases the FILE NAME and looks for "water" — but a
			# zone liquid is Liquids/Water/deep-00100010.png, whose file name is
			# "deep-00100010.png". The word lives in the DIRECTORY, and get_file() throws that
			# away, so this whole branch was dead for every river and every puddle in the game
			# and only ever fired for world-map cards. Qud marks liquids outright; ask it, per
			# the standing rule about Qud predicates over tile-name inference. The world-map
			# test stays OR'd in so those cards keep the treatment they already had.
			# DEEP water only. The backing below is the opaque plate the translucent surface
			# composites against, and it is _world_bg -- WHAT QUD PAINTS BEHIND EVERYTHING. It was
			# a hand-picked near-black (0.03, 0.10, 0.10) meant to read as depth under a river, and
			# it drew a black halo a half-cell wide around every pool: the water tile does not reach
			# its cell edges, so the PLATE, not the field, was what showed there. Measured on this
			# build: ring rgb(4,15,15) against lit ground rgb(9,33,32). Daniel: "I'm standing in
			# water and there is a dark border around it. It should be the background color." Depth
			# is the SURFACE material's job (_water_surface_material); the backing only has to be the
			# colour a cell is when nothing covers it. (It was already wrong under a puddle of
			# dilute salt, which lies on the ground and looked like a black hole in it.) shallow-
			# and puddle_ keep the plain opaque floor they had before zone liquids reached this
			# branch at all — over-reach on my part when the liquid test was fixed.
			if ((bool(obj.get("liquid", false)) and _is_deep_liquid(tile)) or _is_world_water(tile)) \
					and not _one_to_one and not _flat_2d and not _world_map:
				fmat = _water_surface_material(tile, main_c, detail_c, tex)
				_floor_batch_add(_color_material(_world_bg),
					Transform3D(Basis(), Vector3(cx, y - 0.012, cy)))
				fkind = "floor(water surface, translucent over field-colour backing)"
		else:
			fmat = _color_material(_qud_color(String(obj.get("color", ""))))
			fscale = Vector3(0.5, 1.0, 0.5)
			fkind = "floor(no tile: flat colour dot)"
		if bool(obj.get("hflip", false)):
			# Sprite facing (the display-flip gotcha) reaches the batched floor path as a
			# mirrored basis — the quad is cell-centred, and floor materials cull-disable,
			# so the negative winding still draws.
			fscale.x = -fscale.x
			fkind += " hflip"
		_floor_batch_add(fmat, Transform3D(Basis().scaled(fscale), Vector3(cx, y, cy)))
		# THE EDGE RING FEEDS THE SURROUND BAND. A cell on the live zone's outermost ring keeps
		# its finished floor material, so _build_unexplored can repeat THIS quad outward instead
		# of inventing a colour for the ground beyond the zone. That is the whole fix for the old
		# bib: the band's base is the edge cell's own art, matched by construction rather than
		# tallied and then found to be off by a different factor per channel.
		if not _remembered_build and _on_edge_ring(cx, cy):
			_edge_floor[Vector2i(cx, cy)] = [fmat, fscale, y]
		_note(cx, cy, idx, fkind, y)
	elif tex != null:
		# DOORS become voxel slabs set into their wall run (Daniel's spec: a
		# 3px-deep panel with 1px of wall jamb either side — the door-shaped
		# cousin of the 14-inside-16 roof invariant), oriented by the walls
		# around them. USER mode only; an explicit verdict still wins.
		if (verdict == "door" or (verdict == "" and _is_door(tile))) \
				and not _one_to_one and not _flat_2d and not _world_map and not in_wall:
			_place_door(tile, main_c, detail_c, cx, cy, idx, light_frac,
				bool(obj.get("occluding", false)))
			return
		# directional connectors (fences, pipes, axles: family_<dirs>) ->
		# orientation-locked standing panels, not billboards.
		var dirs = _connector_dirs(tile) if _is_connector(obj, tile) else null
		if dirs != null:
			# sight-blocking connectors stand tall AND read as solid (background
			# filled); see-through ones stay low and open.
			var solid := bool(obj.get("occluding", false))
			var pfill: int = Fill.ALL if solid else Fill.NONE
			var ph := _panel_height(obj, tile)
			var floated: bool = position_for(tile) == "float"
			var yc: float = FLOAT_Y if floated else ph * 0.5
			_place_connector(tile, main_c, detail_c, cx, cy, dirs, ph, pfill, yc, light_frac,
				String(obj.get("animSched", "")))
			_note(cx, cy, idx, "connector panels [%s] h=%.2f %s%s%s" % [
				"post" if dirs == "" else dirs, ph, _connector_note(tile),
				" filled-bg" if solid else "", "  floated" if floated else ""], yc)
		else:
			# Qud's winner rule (user mode): a BILLBOARD beneath its cell's top never
			# renders. Only billboards contest — floors, water, decks, connectors and
			# stairs always place, so a hidden vine never punches a hole in its river.
			if below > 0 and not _one_to_one:
				_note(cx, cy, idx, "HIDDEN beneath the cell's top object (Qud winner rule)", 0.0)
				return
			# Gaps *enclosed* by the art read as the cell background, the way Qud
			# draws them; everything outside the silhouette stays see-through.
			var bac: Array = _art_colors(obj)
			var btex := _colored_tex_rgb(tile, bac[0], bac[1], bac[2],
				_fill_for(tile, Fill.INTERIOR), _cutout_for(tile))
			if btex == null:
				btex = tex
			var s := _take_sprite()
			s.pixel_size = PIXEL_SIZE * _tree_scale(tile)
			s.texture = btex
			s.flip_h = bool(obj.get("hflip", false))
			s.flip_v = bool(obj.get("vflip", false))
			# Underground, a creature in an unlit cell dims toward black with the cell's
			# light (the floor overlay can't cover a standing sprite). Sprite3D.modulate
			# works here since there's no material_override — unless it glows, and a
			# bioluminescent thing should stay bright anyway.
			s.modulate = Color(light_frac, light_frac, light_frac) if light_frac < 0.999 else Color.WHITE
			var submerged: bool = sink > 0.0 and bool(obj.get("sinks", false))
			_seat(s, btex, tile, cx, cy, sink if submerged else 0.0, position_for(tile) == "float")
			if not _one_to_one:
				_register_sprite_anim(obj, s, tile, btex)
			# STACK ORDER: same-cell billboards seat at the same (x,z), so a pile's quads are
			# COPLANAR — their depths tie per pixel and the winner flips with every camera nudge
			# (measured: residual 7-13px shimmer after each lerp settle; reads as items "trading
			# z-height"). A deterministic sub-art-pixel offset per stack index fixes the order:
			# mostly vertical (invisible — one art pixel is ~62mm — but it IS the view axis in
			# flat/top-down and dominates any pitched camera), plus a small unequal x/z diagonal
			# so a near-horizontal first-person view still sees distinct depths from any heading.
			# NOT in 1:1: it renders one winner per cell (no stacks) and its pixels are
			# parity-measured against Qud.
			# Creatures draw over the cell's static winner from a hair above it — vertical
			# only, safe for every camera pitch; there is exactly one static billboard per
			# cell now, so same-cell coplanar stacks (the z-flicker source) no longer exist.
			if not _one_to_one and _is_creature(obj):
				s.position.y += 0.02
			s.visible = true
			if _placing_player and WM_STANDING_CARDS:
				# "You are here": the player card ignores depth and sorts last, so it's always the
				# topmost thing on the map — closest to the overhead camera in top-down, and never
				# hidden behind a taller terrain card in the angled views. (Reset in _take_sprite.)
				# Gated with the card feature while we isolate the Metal crash — a render-state
				# change on the per-turn player sprite is a (long-shot) suspect; off = plain sprite.
				s.no_depth_test = true
				s.render_priority = 20
			var glowing: bool = _should_glow(obj)
			if glowing:
				_add_glow(s, btex, tile)        # crisp bioluminescent bloom (glowfish, glowpad, tagged tiles)
			_track(s)
			# STATIC plant/scenery billboard (tree, brinestalk): register it to be dimmed by
			# its cell's light EACH TURN (creatures get modulate directly; static sprites don't,
			# so they'd stay lit at night). Glowing things emit light — leave them bright.
			# A ZONE YOU ARE NOT IN IS OUT OF SIGHT, ALL OF IT. A neighbour's sprites used to keep
			# whatever look they had when that zone was last live — ghosted if they happened to be
			# out of LOS at the moment you left, full colour if they were not — so a departed zone
			# showed a mix, and the lit half read as though you could still see it. Daniel: "the
			# zone to the west has some objects out of the line of sight and some items (watervine)
			# that are visible. Anything in a zone you're not in should be dark like it's out of
			# line of sight." Ghosted at BUILD time, not per turn: while a zone is frozen this
			# cannot change, so there is nothing to track and nothing to re-apply.
			#
			# GLOWING included, deliberately. In the live zone a glowing thing stays bright because
			# it emits its own light, but you are not standing in this zone to see it glow.
			# (A neighbour's sprite is ALREADY ghosted — its texture was built from the memory
			# pair at the choke point above — so there is nothing to register or swap here.)
			if _live_build and not glowing:
				# QUD'S MEMORY IS A PALETTE SWAP, not a dim: out of sight it redraws the tile in
				# K/k (#155352 / #0f3b3a), the same pair _ghost_obj uses for 1:1 and the same
				# one the wire reports as memColor for every painted-ground cell. A modulate can
				# only MULTIPLY, so it could never land on that flat colour — it gave every
				# remembered object its own dark hue instead. Build the ghost texture once (the
				# recolour cache keeps it) and swap the pointer each turn.
				# FLAT K, NOT K-TO-k. _recolor_rgb lerps main->detail by the SOURCE ART'S
				# LUMINANCE, so with detail = k the brightest pixels of a remembered thing land
				# exactly on _world_bg — which IS k — and the plant is painted the colour of the
				# ground it stands on. Measured on Daniel's selected watervine at (3,15): its
				# brightest pixel sat at 0.85 of its own ground where Qud puts it at 1.40.
				# Qud does not lerp: memory draws the GLYPH in K on a field of k, one flat colour
				# each, and the 1.40 between them is the whole look. So both ends are K here and
				# the field supplies the contrast.
				var gtex := _colored_tex_rgb(tile, _qud_color("K"), _qud_color("K"),
					_color_key(obj) + "~ghost", _fill_for(tile, Fill.INTERIOR), _cutout_for(tile))
				_lit_sprites.append({"s": s, "cell": Vector2i(cx, cy),
					"hide_dark": bool(obj.get("hideDark", false)),
					"live": btex, "ghost": gtex})
			var fmode := _fill_for(tile, Fill.INTERIOR)
			var gaps := tile_fill_px(tile, fmode)
			var kind := "billboard"
			if submerged:
				kind = "billboard(submerged %d%%)" % roundi(sink * 100.0)
			elif upright_ground:
				kind = "billboard(painted cover, stood up)"
			var names := ["none", "all", "interior", "fill-holes", "pockets"]
			var fname: String = names[fmode] if fmode < names.size() else str(fmode)
			var stk := ""
			if rank >= 0 and below == 0 and rank > 0:
				stk = "  cell winner (%d hidden beneath)" % rank
			if _live_build and rank >= 0 and below == 0 and not _one_to_one:
				_cell_top_static[Vector2i(cx, cy)] = s   # the dynamic pass hides this under a creature
			_note(cx, cy, idx, "%s, fill=%s %dpx%s" % [kind, fname, gaps, stk], s.position.y)
	else:
		var l := _take_label()
		l.text = _cp437(String(obj.get("glyph", "?")))
		l.font_size = 64   # pooled labels may carry the glyph path's 96
		l.modulate = _qud_color(String(obj.get("color", "")))
		l.position = Vector3(cx, 0.5 + idx * LAYER_STEP, cy)
		l.visible = true
		_track(l)
		_note(cx, cy, idx, "label(NO TILE EXPORTED — glyph fallback)", l.position.y)

# Seat a billboard on the ground, showing only its art.
#
# Everything here is measured against the tile's OPAQUE BAND, not the 16x24
# frame. Qud pads its art inside the frame — the chest occupies rows 6..17, so
# drawing the whole frame with its bottom edge on the ground leaves 6 rows of
# nothing underneath and the chest hovers. Cropping to the band and sitting THAT
# on the ground is what puts objects on the floor.
#
# `sink` > 0 (standing in deep water) trims the bottom of the band and rests the
# cut edge at the waterline. Cropping beats lowering the sprite: the water is a
# flat quad with no volume, so a sunk sprite would just poke out underneath it
# as soon as the camera tilts.
func _seat(s: Sprite3D, tex: ImageTexture, tile: String, cx: int, cy: int, sink: float, float_center := false) -> void:
	var h := tex.get_height()
	var vr := _opaque_v(_mask(tile))
	var top := vr.x * h
	var shown: float = max(1.0, vr.y * h * (1.0 - sink))
	s.region_enabled = true
	s.region_rect = Rect2(0, top, tex.get_width(), shown)
	# ground-seated: band bottom on the floor (or the waterline when submerged).
	# floated: band CENTRE at cell mid-height, e.g. an axle shaft crossing the cell.
	var cy_center: float
	if float_center:
		cy_center = FLOAT_Y
	else:
		# s.pixel_size, NOT the constant: a scaled sprite (see _tree_scale) must still
		# seat its band's BOTTOM on the floor, or it grows down through the ground.
		cy_center = (WATER_LINE_Y if sink > 0.0 else 0.0) + s.pixel_size * shown * 0.5
	s.position = Vector3(cx, cy_center, cy)

# --- greedy-meshed walls ----------------------------------------------------

## The colour string whose ^X paints this object's cell background:
## TileColor when set (it masks ColorString entirely in tile mode), else
## ColorString — mirroring how Qud seeds RenderEvent.ColorString.
func _bg_source(obj: Dictionary) -> String:
	var tc := String(obj.get("tilecolor", ""))
	return tc if tc != "" else String(obj.get("color", ""))

func _parse_bg(color: String) -> String:
	# "&r^w" -> "w"  (the background colour); "" if no ^ component. Qud's rule
	# (GetBackgroundColorChar) takes the LAST '^' — matters for compound strings.
	var i := color.rfind("^")
	if i >= 0 and i + 1 < color.length():
		return color.substr(i + 1, 1)
	return ""

func _wall_bg_color() -> Color:
	# Gap fill = the ^X component of TILECOLOR when present, else the world bg.
	# BOTH prior measurements were right and are reconciled by WHICH FIELD the ^
	# came from: metal walls flooded cyan because the old code read COLORSTRING's
	# '^R' (glyph-mode noise — their TileColor '&y' has no ^), while the Starship
	# family genuinely fills gold — TileColor '&y^W' — and Qud paints it
	# (checker evidence: StarshipGeometricWallGrey_goldframe_*). ColorString
	# compounds stay glyph-only, exactly like the salt-puddle measurement.
	if _wall_bg != "":
		return _qud_color("&" + _wall_bg)
	return _world_bg

## The cap band's GAP pattern for a variant tile — true where the RECOLOURED cap
## pixel equals the wall background: the exact predicate _wall_cell_mesh carves by.
## (The first version tested art ALPHA — wall art is fully opaque, so no gap ever
## registered, no seam wall was ever emitted, and every carved edge opened into the
## hollow behind the skin: the "Escher" build.) Requires the TYPE's colour context
## (_wall_main/_wall_bg set), so callers compute it inside the type loop; cached by
## the same key ingredients as the cap texture.
var _cap_gap_cache := {}
func _cap_gaps(variant_tile: String) -> Array:
	var key := "gaps|%s|%s|%s|%s" % [variant_tile, _wall_main, _wall_detail, _wall_bg]
	if _cap_gap_cache.has(key):
		return _cap_gap_cache[key]
	var tex := _cap_tex(variant_tile)
	if tex == null:
		return []
	var img := tex.get_image()
	if img == null:
		return []
	var bg := _wall_bg_color().to_html(false)
	var out := []
	for y in img.get_height():
		var row := []
		for x in img.get_width():
			row.append(img.get_pixel(x, y).to_html(false) == bg)
		out.append(row)
	_cap_gap_cache[key] = out
	return out

## SEAM WALLS between adjacent wall cells, emitted ONCE per seam by the FLUSH side —
## the same higher-pixel-owns rule the in-cell cap steps use, applied across the
## boundary with the REAL neighbour's edge pattern (its own variant art, any type).
## Where both edges are gaps the pit continues and no wall belongs there at all —
## which is exactly the doubled "flat plane perpendicular to the wall" this replaces.
func _emit_seam_walls(k: Vector2i, variant_tile: String, all_wall_cells: Dictionary) -> void:
	var g_my: Array = all_wall_cells.get(k, [])
	if g_my.is_empty():
		return
	var w: int = (g_my[0] as Array).size()
	var hh: int = g_my.size()
	var ps := 1.0 / w
	var lo := WALL_H - CAP_CARVE
	var st: SurfaceTool = null
	# the closing wall wears MY edge voxel's block colour at the in-cell
	# interior shade — a boundary pit wall must be indistinguishable from an
	# in-cell one (Daniel: "the roof seam is using different shading than the
	# central checkerboard"; flat unshaded main-colour read as a seam).
	var capt := _cap_tex(variant_tile)
	if capt == null:
		return
	var capim := capt.get_image()
	if capim == null:
		return
	for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var n := Vector2i(k.x + d[0], k.y + d[1])
		if not all_wall_cells.has(n):
			continue
		var g_nb: Array = all_wall_cells[n]
		if g_nb.is_empty():
			continue
		# grids can differ in size ACROSS cells — cap band heights vary per
		# VARIANT (a couple of opaque frame pixels in the separator row push
		# _wall_split to its fallback: metal 00100000 is 14 rows to 00000000's
		# 13) and per FAMILY (brinestalk 15). Indexing the neighbour's edge with
		# MY row count walked off the end: a runtime error that aborted the
		# seam pass mid-cell and left a HOLE in the wall at the boundary
		# (Daniel's report at Joppa (8,17)). Sample the neighbour's edge by
		# SCALED index instead — same normalization the cap az mapping uses.
		var nb_h: int = g_nb.size()
		var nb_w: int = (g_nb[0] as Array).size()
		# iterate VOXEL rows/columns and map each into the two cells' art
		# grids (band heights differ per variant and family): the gap test
		# and the emitted span then stay exactly aligned with the carve
		# mapping (_cap_az's 14x14-interior invariant) on BOTH sides.
		for i in w:
			var my_gap: bool
			var nb_gap: bool
			var mr: int = _cap_az(i, hh, w)
			var nr: int = _cap_az(i, nb_h, w)
			var ni_w: int = mini(nb_w - 1, i * nb_w / w)
			if d == [1, 0]:      my_gap = g_my[mr][w - 1]; nb_gap = g_nb[nr][0]
			elif d == [-1, 0]:   my_gap = g_my[mr][0];     nb_gap = g_nb[nr][nb_w - 1]
			elif d == [0, 1]:    my_gap = g_my[_cap_az(w - 1, hh, w)][i]; nb_gap = g_nb[_cap_az(0, nb_h, w)][ni_w]
			else:                my_gap = g_my[_cap_az(0, hh, w)][i];      nb_gap = g_nb[_cap_az(w - 1, nb_h, w)][ni_w]
			# I own the seam wall only when I am flush and the neighbour is carved.
			if my_gap or not nb_gap:
				continue
			if st == null:
				st = SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var a: Vector3
			var b: Vector3
			if d == [1, 0]:
				a = Vector3(k.x + 0.5, 0, k.y - 0.5 + i * ps)
				b = Vector3(k.x + 0.5, 0, k.y - 0.5 + (i + 1) * ps)
			elif d == [-1, 0]:
				a = Vector3(k.x - 0.5, 0, k.y - 0.5 + (i + 1) * ps)
				b = Vector3(k.x - 0.5, 0, k.y - 0.5 + i * ps)
			elif d == [0, 1]:
				a = Vector3(k.x - 0.5 + (i + 1) * ps, 0, k.y + 0.5)
				b = Vector3(k.x - 0.5 + i * ps, 0, k.y + 0.5)
			else:
				a = Vector3(k.x - 0.5 + i * ps, 0, k.y - 0.5)
				b = Vector3(k.x - 0.5 + (i + 1) * ps, 0, k.y - 0.5)
			var nrm := Vector3(d[0], 0, d[1])
			var at := Vector3(a.x, WALL_H, a.z)
			var bt := Vector3(b.x, WALL_H, b.z)
			var ab := Vector3(a.x, lo, a.z)
			var bb := Vector3(b.x, lo, b.z)
			var ac: int
			var ar: int
			if d[0] != 0:
				ac = (w - 1) if d == [1, 0] else 0
				ar = mr
			else:
				ac = i
				ar = _cap_az(w - 1, hh, w) if d == [0, 1] else _cap_az(0, hh, w)
			var px := capim.get_pixel(ac, ar)
			var sh := _interior_shade(nrm)
			var segc := Color(px.r * sh, px.g * sh, px.b * sh, 1.0)
			for pv in [ab, bt, at, ab, bb, bt]:
				st.set_normal(nrm)
				st.set_color(segc)
				st.add_vertex(pv)
	if st != null:
		var mesh := ArrayMesh.new()
		st.commit(mesh)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _wall_skin_material()
		_wall_parent().add_child(mi)
		_track_wall(k, mi)

## The variant name matching a cell's ACTUAL wall neighbourhood — any family counts.
## Cross-cell closure walls for HARD carves at wall-to-wall boundaries,
## emitted by the CARVED side only where the neighbour's matching edge voxel is
## SOLID — a pocket continuing through the seam stays open (Daniel's carved
## slot grew a plane mesh when each side closed it blindly). Rows and columns
## pair by scaled index (grids differ per family); the cap row belongs to the
## seam pass. Returns world-space quads per cell.
func _carve_closure_quads(cells: Dictionary) -> Dictionary:
	var opp := {"e": "w", "w": "e", "s": "n", "n": "s"}
	var step := {"e": Vector2i(1, 0), "w": Vector2i(-1, 0),
		"s": Vector2i(0, 1), "n": Vector2i(0, -1)}
	var out := {}
	for k in cells:
		var me: Dictionary = cells[k]
		var W: int = me["W"]
		var planes: Array = me["planes"]
		var R: int = planes.size() - 1
		var ps := 1.0 / W
		var quads := []
		for d in ["e", "w", "s", "n"]:
			var nk: Vector2i = k + step[d]
			if not cells.has(nk):
				continue
			var nb: Dictionary = cells[nk]
			var nprof: PackedByteArray = nb["prof"][opp[d]]
			var nW: int = nb["W"]
			var nR: int = (nb["planes"] as Array).size() - 1
			var mprof: PackedByteArray = me["prof"][d]
			for r in range(1, R):
				var yb: float = planes[r + 1]
				var yt: float = planes[r]
				for a in W:
					if mprof[r * W + a] == 1:
						continue          # my edge solid: nothing to close
					var nr: int = mini(nR - 1, r * nR / R)
					var na: int = mini(nW - 1, a * nW / W)
					if nprof[nr * nW + na] == 0:
						continue          # both carved: the pocket continues
					var pa: Vector3
					var pb: Vector3
					var nrm: Vector3
					match String(d):
						"s":
							pa = Vector3(k.x - 0.5 + a * ps, yb, k.y + 0.5)
							pb = Vector3(k.x - 0.5 + (a + 1) * ps, yb, k.y + 0.5)
							nrm = Vector3(0, 0, -1)
						"n":
							pa = Vector3(k.x - 0.5 + a * ps, yb, k.y - 0.5)
							pb = Vector3(k.x - 0.5 + (a + 1) * ps, yb, k.y - 0.5)
							nrm = Vector3(0, 0, 1)
						"e":
							pa = Vector3(k.x + 0.5, yb, k.y - 0.5 + a * ps)
							pb = Vector3(k.x + 0.5, yb, k.y - 0.5 + (a + 1) * ps)
							nrm = Vector3(-1, 0, 0)
						_:
							pa = Vector3(k.x - 0.5, yb, k.y - 0.5 + a * ps)
							pb = Vector3(k.x - 0.5, yb, k.y - 0.5 + (a + 1) * ps)
							nrm = Vector3(1, 0, 0)
					# a closure plane is a SIDE WALL of the pocket: it wears
					# the SOLID neighbour's edge ART pixel (cyan where the
					# design is cyan) with the same orientation shading as any
					# in-cell side — seam sides are pixel-identical to native
					# ones (Daniel's green-vs-pink pockets).
					var nec: PackedColorArray = nb["ecol"][opp[d]]
					var nc: Color = nec[nr * nW + na]
					var sh := _interior_shade(nrm)
					quads.append({"q": [pa, pb, Vector3(pb.x, yt, pb.z), Vector3(pa.x, yt, pa.z)],
						"n": nrm, "c": Color(nc.r * sh, nc.g * sh, nc.b * sh, 1.0),
						"m": {"k": "closure-side(%s)" % d, "edge_a": a, "row": r, "cell": k}})
		if not quads.is_empty():
			out[k] = quads
	return out

func _emit_carve_closures(cells: Dictionary) -> void:
	var per := _carve_closure_quads(cells)
	for k in per:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in per[k]:
			var q: Array = f["q"]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_normal(f["n"])
				st.set_color(f["c"])
				st.add_vertex(q[idx])
		var mesh := ArrayMesh.new()
		st.commit(mesh)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _wall_skin_material()
		_wall_parent().add_child(mi)
		_track_wall(k, mi)

## Side art for ONE exposed face. Only the along-face continuation matters: the variant
## keeps its own face OPEN (the art's S bit 0) and sets just the art-E/art-W bits — one
## of the four horizontal-run tiles, whose band below _wall_split is always a genuine
## elevation. Choosing a single per-cell "effective" variant from the full neighbourhood
## picked mostly-checker interior art for well-connected cells, and _wall_split cropped
## that checker into the side band: "some of the walls look like the ceiling"
## (2026-08-13). Bit order [N,NE,E,SE,S,SW,W,NW], verified against live data
## (00101000 = E+S at (3,17), 00000110 = SW+W at (4,17)). Falls back to the cell's own
## Qud variant when the family lacks the run tiles.
func _face_variant(tile: String, e_on: bool, w_on: bool) -> String:
	var dash := tile.rfind("-")
	var dot := tile.rfind(".")
	if dash < 0 or dot < dash:
		return tile
	var bits := "00" + ("1" if e_on else "0") + "000" + ("1" if w_on else "0") + "0"
	var cand := tile.substr(0, dash) + "-" + bits + tile.substr(dot)
	if _mask(cand) != null:
		return cand
	return tile

func _rebuild_walls(wall_types: Dictionary) -> void:
	# Live rebuild clears _wall_root; when banking into a fresh neighbour subtree
	# (_sync_neighbors), there is nothing to clear, so don't wipe it mid-build.
	if _bank == null:
		for c in _wall_root.get_children():
			c.queue_free()
	# The union of EVERY type's cells, for the side-face neighbour test below. Each
	# type builds separately, and testing "is my neighbour this wall" against only
	# the type's own cells emitted BOTH sides of every boundary between two wall
	# types — two coplanar skins on the shared plane, z-fighting under any camera
	# motion (Daniel: "the meshes in the wall are fighting"). A neighbour of ANY
	# wall type makes the seam interior; no side belongs there at all.
	var all_wall_cells := {}
	for key in wall_types:
		var t0 = wall_types[key]
		_wall_tile = t0["tile"]; _wall_main = t0["main"]; _wall_detail = t0["detail"]; _wall_bg = t0["bg"]
		for k in t0["cells"]:
			# each cell's gap pattern, computed under ITS OWN type's colours — the
			# seam pass then compares patterns directly, across types and families
			all_wall_cells[k] = _cap_gaps(String(t0["cells"][k]))
	var closure_cells := {}
	for key in wall_types:
		var t = wall_types[key]
		_wall_tile = t["tile"]; _wall_main = t["main"]; _wall_detail = t["detail"]; _wall_bg = t["bg"]
		if _remembered_build:
			# BUILT in the memory pair rather than re-cut afterwards. _ghost_wall_mesh exists for
			# the LIVE zone, where a wall has to switch between live and remembered art per turn
			# and the mesh already exists — it takes a finished mesh apart and puts it back. Doing
			# that for every wall of every neighbour was array surgery per wall per zone, and at a
			# deep zoom with several zones loaded it died in _platform_memmove, the same overdraw/
			# churn signature as before. A remembered zone never switches back, so its walls can
			# simply be BUILT in K/k: same result, no surgery, nothing to allocate twice.
			_wall_main = "K"; _wall_detail = "k"
		var cells: Dictionary = t["cells"]

		# ONE WATERTIGHT VOXEL VOLUME PER CELL (Daniel: "like a minecraft creation,
		# made of blocks. The facade and roof are defined by the artwork and there's
		# a solid core"). Full solid block; the CAP art carves the roof down by
		# CAP_CARVE where it is background; each EXPOSED face's art carves inward by
		# SIDE_CARVE_PX pixels; wall-to-wall boundaries below the cap row never
		# carve, so adjacent cells tile flush-solid. Faces exist only where solid
		# meets air, emitted once — the see-through channels of the old hybrid
		# (inset core + floating skins) cannot exist by construction. Cap-row
		# boundary gaps are still closed by the seam pass (flush side owns).
		# Algorithm PROVEN in tools/capture/voxwall.py — run it before changing this.
		for k in cells:
			var v := String(cells[k])
			var wn := all_wall_cells.has(Vector2i(k.x, k.y - 1))
			var ws := all_wall_cells.has(Vector2i(k.x, k.y + 1))
			var we := all_wall_cells.has(Vector2i(k.x + 1, k.y))
			var ww := all_wall_cells.has(Vector2i(k.x - 1, k.y))
			# face art per EXPOSED direction ("" = wall neighbour there): the
			# run-tile whose along-face continuation matches. The art WRAPS the
			# building in one direction (clockwise from above), so the art's +x
			# axis is S=world E, E=world N, N=world W, W=world S — the
			# continuation bits follow the face's own axis, not world E/W.
			var fv := {
				"s": "" if ws else _face_variant(v, we, ww),
				"e": "" if we else _face_variant(v, wn, ws),
				"n": "" if wn else _face_variant(v, ww, we),
				"w": "" if ww else _face_variant(v, ws, wn),
			}
			var entry := _wall_cell_mesh(v, fv)
			if not entry.is_empty():
				var mi := MeshInstance3D.new()
				# Same rule as the sprites: a wall in a zone you are not in is out of sight, so it
				# is built ghosted rather than left at full colour. The live zone's walls swap to
				# this per turn through _wall_cutaway; a frozen one cannot change while frozen, so
				# it is baked once here.
				mi.mesh = entry["mesh"]    # already in K/k when this is a remembered zone
				mi.material_override = _wall_skin_material()
				mi.position = Vector3(k.x, 0.0, k.y)
				_wall_parent().add_child(mi)
				_track_wall(k, mi)
				closure_cells[k] = {"prof": entry["prof"], "ecol": entry["ecol"],
					"planes": entry["planes"], "W": entry["W"]}
			_emit_seam_walls(k, v, all_wall_cells)
	_emit_carve_closures(closure_cells)

## Register a live-zone wall node under its cell so the camera cutaway can fade it. Only
## the LIVE zone (_live_build) — neighbours are far/dim and never between you and the camera.
func _track_wall(k: Vector2i, mi: MeshInstance3D) -> void:
	if not _live_build:
		return
	if not _wall_cutaway.has(k):
		_wall_cutaway[k] = []
	_wall_cutaway[k].append(mi)

## Is this wall lit enough to be worth fading? A wall is "visible" when its face onto an
## adjacent OPEN cell is lit, so take the max of its own and its 4 neighbours' light. Dark
## rock (already near-invisible under the darkness overlay) stays solid and isn't cut away.
func _wall_lit(cell: Vector2i) -> bool:
	var f: float = _cell_light.get(cell, 0.0)
	f = maxf(f, _cell_light.get(cell + Vector2i(1, 0), 0.0))
	f = maxf(f, _cell_light.get(cell + Vector2i(-1, 0), 0.0))
	f = maxf(f, _cell_light.get(cell + Vector2i(0, 1), 0.0))
	f = maxf(f, _cell_light.get(cell + Vector2i(0, -1), 0.0))
	return f > CUTAWAY_LIT_MIN

## Fade walls between the camera (`eye`) and the player (`focus`) so rock doesn't block the
## view — screen-door dither via each node's `transparency` (the wall material is ALPHA_HASH,
## so it stays in the opaque pass). A wall cell fades by how close its centre is to the line
## of sight AND how clearly it sits BETWEEN the two; eased so it melts in/out. `enabled=false`
## eases everything back solid (top-down / first-person, where nothing is in the way). Called
## every frame by Main. Cheap: settled cells (the vast majority) skip the write.
func apply_cutaway(eye: Vector3, focus: Vector3, dt: float, enabled := true) -> void:
	if _wall_cutaway.is_empty():
		return
	# A lit wall fades when it HIDES A LIT OPEN SPACE behind it (from the camera) — so you
	# see the lit contents (loot, a lit room, the player) instead of the rock fronting them.
	# Occlusion is judged on the ground plane (XZ): a lit, open neighbour that's FURTHER from
	# the camera than the wall means the wall is between the camera and that space.
	# BOUNDED to a disc around the player: without it the OVERWORLD (all lit by day) fades
	# nearly every wall at once — a flood of transparent overdraw that tanks the framerate.
	# Only rock near you needs to get out of the way, so far walls are skipped cheaply.
	var e2 := Vector2(eye.x, eye.z)
	var p2 := Vector2(focus.x, focus.z)
	var ease := clampf(dt * CUTAWAY_LERP, 0.0, 1.0)
	for cell in _wall_cutaway:
		var target := 0.0
		if enabled and (Vector2(cell.x, cell.y) - p2).length_squared() <= CUTAWAY_RADIUS * CUTAWAY_RADIUS \
				and _wall_lit(cell):
			var wd := (Vector2(cell.x, cell.y) - e2).length()
			for off in NEIGHBORS8:
				var b: Vector2i = cell + off
				if _wall_cutaway.has(b):
					continue                          # neighbour is also wall — not an open space
				if _cell_light.get(b, 0.0) > CUTAWAY_LIT_MIN \
						and (Vector2(b.x, b.y) - e2).length() > wd + 0.3:  # lit & open & behind
					target = CUTAWAY_MAX
					break
		for mi in _wall_cutaway[cell]:
			if is_instance_valid(mi):
				var cur: float = mi.transparency
				if absf(cur - target) > 0.003:
					mi.transparency = lerpf(cur, target, ease)

# --- stairs down: framed opening + descending voxel flight ------------------

const STAIR_FRAME_W   := 0.10  # width of the raised lip framing the opening
const STAIR_FRAME_H   := 0.05  # how far that lip stands proud of the floor
const STAIR_GUESS_DEG := 0.0   # default facing when nothing says otherwise: +Z (south)

## Is this object a downward staircase? Matched on the blueprint name OR the tile
## (Tiles2/sw_stairsdown) — a purely visual marker keys off what's drawn, and either
## signal alone is enough, so a missing tile PNG (export race) still gets stairs.
func _is_stairs_down(obj: Dictionary, tile: String) -> bool:
	var n := String(obj.get("name", "")).to_lower()
	if n.contains("stair") and n.contains("down"):
		return true
	var t := tile.to_lower()
	return t.contains("stairsdown") or t.contains("stairs_down") or t.contains("stairdown")

## A downward staircase's twin: matched the same way (name or tile).
func _is_stairs_up(obj: Dictionary, tile: String) -> bool:
	var n := String(obj.get("name", "")).to_lower()
	if n.contains("stair") and n.contains("up"):
		return true
	var t := tile.to_lower()
	return t.contains("stairsup") or t.contains("stairs_up") or t.contains("stairup")

## Does any object in this cell make it a stairs-down cell? Used to suppress the
## cell's floor quad so the shaft isn't capped from above.
func _cell_has_stairs_down(cell: Dictionary) -> bool:
	for obj in cell.get("objs", []):
		if _is_stairs_down(obj, String(obj.get("tile", ""))):
			return true
	return false

## Yaw (degrees) for the descent. Priority: an explicit data field, then a user
## override, then the guess. Cardinal -> yaw like _place_side: canonical descent is
## +Z (south) at 0deg, rotation running S->E->N->W (clockwise viewed from above).
func _stair_dir_deg(obj: Dictionary, tile: String) -> float:
	var d := _match_stairdir(String(obj.get("stairDir", "")))    # data, if the mod ever sends it
	if d == "" and not _stairdir_overrides.is_empty():
		d = String(_stairdir_overrides.get(tile_family(tile), ""))
	match d:
		"s": return 0.0
		"e": return 90.0
		"n": return 180.0
		"w": return 270.0
	return STAIR_GUESS_DEG

func _deg_cardinal(deg: float) -> String:
	match int(round(deg)) % 360:
		90: return "E"
		180: return "N"
		270: return "W"
	return "S"

## Build the stairs marker into the current static bank, centred on cell (cx,cy).
## A descending voxel shaft was tried first (tools/capture/stairs.py) but proved
## invisible: a one-cell pit is too small and dark to read from the game camera,
## and it vanished entirely in dim light. So the reliable form is the stair art laid
## FLAT on the floor (as Qud draws it), ringed by a raised rectangular lip = "the top
## of the stair". `deg` rotates the whole thing so a facing (data or override) turns
## the glyph; the guess leaves it unrotated.
func _place_stairs_down(cx: int, cy: int, obj: Dictionary, tile: String, main_c: String, detail_c: String, deg: float) -> void:
	var grp := Node3D.new()
	grp.position = Vector3(cx, 0.0, cy)
	grp.rotation = Vector3(0, deg_to_rad(deg), 0)
	_wall_parent().add_child(grp)

	var hi := 0.5 - STAIR_FRAME_W

	# The stair glyph laid flat inside the frame. Filled (Fill.ALL) so the tile's
	# transparent field becomes an opaque base the light staircase sits on, the way
	# Qud shows a bright '>' on the dark floor — readable from any angle or light.
	var ftex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj), Fill.ALL)
	if ftex != null:
		var f := MeshInstance3D.new()
		f.mesh = _plane
		f.material_override = _mesh_material(tile, main_c, detail_c, ftex)
		f.scale = Vector3(2.0 * hi, 1.0, 2.0 * hi)   # fill the opening inside the lip
		f.position = Vector3(0, STAIR_FRAME_H * 0.6, 0)
		grp.add_child(f)

	# Raised rectangular lip = "the top of the stair". Four bars around the perimeter,
	# inner edge flush with the tile (+/-hi), outer edge at the cell boundary.
	var o := 0.5
	var fy := STAIR_FRAME_H
	var fmat := _color_material(_qud_color(detail_c if detail_c != "" else main_c).lightened(0.15))
	_stair_bar(grp, fmat, Vector3(2.0 * o, fy, STAIR_FRAME_W), Vector3(0, fy * 0.5, -(o - STAIR_FRAME_W * 0.5)))  # far
	_stair_bar(grp, fmat, Vector3(2.0 * o, fy, STAIR_FRAME_W), Vector3(0, fy * 0.5,  (o - STAIR_FRAME_W * 0.5)))  # near
	_stair_bar(grp, fmat, Vector3(STAIR_FRAME_W, fy, 2.0 * hi), Vector3( (o - STAIR_FRAME_W * 0.5), fy * 0.5, 0)) # right
	_stair_bar(grp, fmat, Vector3(STAIR_FRAME_W, fy, 2.0 * hi), Vector3(-(o - STAIR_FRAME_W * 0.5), fy * 0.5, 0)) # left

func _stair_bar(grp: Node3D, mat: Material, size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	grp.add_child(mi)

# --- voxel walls ------------------------------------------------------------

const CAP_CARVE := 0.10     # how deep a background gap recesses DOWN into the roof
const SIDE_CARVE_PX := 2    # facade recess depth, in ART pixels (~0.13 cells at 16px art)
var _voxel_cache := {}      # cell-mesh key -> {mesh, prof, planes}
var _voxel_mat: StandardMaterial3D
var _last_faces_prof := {}          # stashed by _wall_cell_faces for the cache
var _last_faces_ecol := {}          # boundary voxels' art colours, per dir
var _last_faces_planes: Array[float] = []

## ONE cell's wall as a watertight voxel volume ("minecraft" walls; algorithm and
## its proofs live in tools/capture/voxwall.py — keep the two in step).
##
##   - full solid block over the whole cell footprint, 0..WALL_H;
##   - row 0 is the cap layer [WALL_H-CAP_CARVE, WALL_H], carved where the CAP art
##     is background (the same _cap_gaps grid the seam pass reads);
##   - rows below map to the face art's rows; each EXPOSED direction carves its
##     art's background pixels inward by SIDE_CARVE_PX, never entering the
##     SIDE_CARVE_PX shell beside a wall neighbour (a gap column running to the
##     tile edge must not hollow the flush boundary the neighbour relies on);
##   - faces are emitted only between solid and air, from the solid side, once.
##     Wall-to-wall boundaries below the cap row are flush-solid on both sides, so
##     nothing is emitted there; cap-row boundary gaps are closed by the seam pass.
##
## The interior can never open: carves are at most SIDE_CARVE_PX deep on a 16px
## cell, so a solid core survives every combination — the see-through sightlines
## of the old core+skins hybrid are impossible by construction.
##
## `fv` maps direction -> face-variant tile for EXPOSED directions, "" where a
## wall neighbour sits. The volume/emission lives in _wall_cell_faces (shared
## with the voxel editor's preview); this wrapper meshes it, cached per
## (variant, faces, colours) so cells sharing a neighbourhood share the mesh.
func _wall_cell_mesh(variant_tile: String, fv: Dictionary) -> Dictionary:
	var key := "cell|%s|%s|%s|%s|%s|%s|%s|%s" % [variant_tile, fv["s"], fv["e"],
		fv["n"], fv["w"], _wall_main, _wall_detail, _wall_bg]
	if _voxel_cache.has(key):
		return _voxel_cache[key]
	var inp := _wall_cell_inputs(variant_tile, fv, null, "")
	if inp.is_empty():
		return {}
	var faces: Array = _wall_cell_faces(inp)
	if faces.is_empty():
		return {}
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in faces:
		var q: Array = f["q"]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_normal(f["n"])
			st.set_color(f["c"])
			st.add_vertex(q[idx])
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	var entry := {"mesh": mesh, "prof": _last_faces_prof, "ecol": _last_faces_ecol,
		"planes": _last_faces_planes, "W": (inp["cap"] as Image).get_width()}
	_voxel_cache[key] = entry
	return entry

## The art inputs for one cell's volume: recoloured cap image + its gap grid and
## the face image per exposed direction. `edit_img` (with `edit_variant`)
## substitutes UNSAVED voxel-editor art for that variant — the preview path;
## the game build passes null and gets the cached textures. `face_overrides`
## (face tile name -> band Image) substitutes unsaved FAMILY-WIDE face edits —
## faces render from only the four run variants, so the editor previews its
## one face surface by overriding those four.
func _wall_cell_inputs(variant_tile: String, fv: Dictionary, edit_img: Image, edit_variant: String, face_overrides := {}) -> Dictionary:
	var editing := edit_img != null and variant_tile == edit_variant
	var cap_img: Image = null
	if editing:
		var region := edit_img.get_region(Rect2i(0, 0, edit_img.get_width(), _wall_layout(edit_img).x))
		cap_img = _as_authored(region).get_image()
	else:
		var t := _cap_tex(variant_tile)
		if t != null:
			cap_img = t.get_image()
	if cap_img == null:
		return {}
	var gaps := []
	if editing:
		var bg := _wall_bg_color().to_html(false)
		for y in cap_img.get_height():
			var row := []
			for x in cap_img.get_width():
				row.append(cap_img.get_pixel(x, y).to_html(false) == bg)
			gaps.append(row)
	else:
		gaps = _cap_gaps(variant_tile)
	var f_img := {}
	var f_hard := {}
	for d in ["s", "e", "n", "w"]:
		if String(fv[d]) == "":
			continue
		var im: Image = null
		var hard_src: Image = null
		if face_overrides.has(String(fv[d])):
			hard_src = face_overrides[String(fv[d])]
			im = _as_authored(hard_src).get_image()
		elif edit_img != null and String(fv[d]) == edit_variant:
			var sp := _wall_layout(edit_img)
			if sp.y < edit_img.get_height():
				var region2 := edit_img.get_region(Rect2i(0, sp.y,
					edit_img.get_width(), edit_img.get_height() - sp.y))
				hard_src = region2
				im = _as_authored(region2).get_image()
		else:
			var t2 := _wall_region_tex("side", String(fv[d]))
			if t2 != null:
				im = t2.get_image()
			# HARD gaps exist only in CUSTOM art: an alpha-erased pixel means
			# "remove the voxel, I mean it" (Daniel) and carves straight through
			# the protected zones. Stock art (and bg-COLOURED custom pixels)
			# stays soft — the protections exist for those accidents.
			if _custom_tile_path(String(fv[d])) != "":
				var m := _mask(String(fv[d]))
				if m != null:
					var sp2 := _wall_layout(m)
					if sp2.y < m.get_height():
						hard_src = m.get_region(Rect2i(0, sp2.y,
							m.get_width(), m.get_height() - sp2.y))
		if im != null:
			f_img[d] = im
			if hard_src != null:
				f_hard[d] = _alpha_grid(hard_src)
	return {"cap": cap_img, "gaps": gaps, "faces": f_img, "fv": fv, "hard": f_hard}

## Boolean grid of a band's alpha-erased pixels (true = deliberately removed).
func _alpha_grid(img: Image) -> Array:
	var out := []
	for y in img.get_height():
		var row := []
		for x in img.get_width():
			row.append(img.get_pixel(x, y).a < 0.5)
		out.append(row)
	return out

## Volume + emission for one cell, cell-local coords. Returns face quads
## [{q: [4 Vector3], n: Vector3, c: Color}] — meshed by _wall_cell_mesh, drawn
## directly by the voxel editor's preview. ONE implementation for both.
func _wall_cell_faces(inp: Dictionary) -> Array:
	var cap_img: Image = inp["cap"]
	var gaps: Array = inp["gaps"]
	var f_img: Dictionary = inp["faces"]
	var fv: Dictionary = inp["fv"]
	var W := cap_img.get_width()
	var caph := cap_img.get_height()
	var bg := _wall_bg_color().to_html(false)
	var F := WALL_FACE_ROWS
	for d in f_img:
		F = (f_img[d] as Image).get_height()
	# y planes, descending: WALL_H, the cap floor, then the face-row boundaries
	# below it, ending at 0. Row r spans planes[r+1]..planes[r].
	var rh := WALL_H / float(F)
	var planes: Array[float] = [WALL_H, WALL_H - CAP_CARVE]
	for i in range(1, F + 1):
		var yy := WALL_H - i * rh
		if yy < WALL_H - CAP_CARVE - 0.0001:
			planes.append(maxf(yy, 0.0))
	if planes[planes.size() - 1] > 0.0001:
		planes.append(0.0)
	var R := planes.size() - 1

	var solid := PackedByteArray()
	solid.resize(R * W * W)
	solid.fill(1)
	# which face(s) CARVED each empty voxel (bitmask by dir_names index): the
	# back-vs-side verdict follows the carver, not the nearest face — a south
	# wall closing an EAST-carved pocket is that pocket's SIDE (Daniel's
	# corner picks: "dark red, not darker red")
	var carver := PackedByteArray()
	carver.resize(R * W * W)
	# cap carve (row 0). The outermost ring beside an EXPOSED face never
	# carves: cap-art gaps on the perimeter notched the face's top edge into
	# an alternating "zipper" (Daniel) — the wall's rim stays a solid line and
	# roof relief starts one pixel in, like the foundation and corner rules.
	for z in W:
		var az := _cap_az(z, caph, W)
		for x in W:
			if not bool(gaps[az][x]):
				continue
			var rim: bool = (String(fv["s"]) != "" and z == W - 1) \
				or (String(fv["n"]) != "" and z == 0) \
				or (String(fv["e"]) != "" and x == W - 1) \
				or (String(fv["w"]) != "" and x == 0)
			if not rim:
				solid[z * W + x] = 0
	# the no-carve shell beside every wall neighbour
	var prot := PackedByteArray()
	prot.resize(W * W)
	for d in ["s", "e", "n", "w"]:
		if String(fv[d]) != "":
			continue
		for depth in SIDE_CARVE_PX:
			for a in W:
				match d:
					"s": prot[(W - 1 - depth) * W + a] = 1
					"n": prot[depth * W + a] = 1
					"e": prot[a * W + (W - 1 - depth)] = 1
					"w": prot[a * W + depth] = 1
	# CORNERS where two EXPOSED faces meet keep their solid edge. The wrap puts
	# the SAME art column on both corner faces, so an edge gap column would
	# carve from both directions and delete the whole corner column — a chunk
	# bitten out of the building edge (Daniel's report). Relief starts one
	# shell in from the corner, like a real block edge.
	for pair in [["n", "e"], ["e", "s"], ["s", "w"], ["w", "n"]]:
		if String(fv[pair[0]]) == "" or String(fv[pair[1]]) == "":
			continue
		for i in SIDE_CARVE_PX:
			for j in SIDE_CARVE_PX:
				var pz: int = i if pair.has("n") else W - 1 - i
				var px: int = j if pair.has("w") else W - 1 - j
				prot[pz * W + px] = 1
	# facade carves. The art WRAPS the building in ONE direction — wallpaper
	# applied clockwise seen from above (Daniel: "let the single design wrap
	# around the whole building in one direction"). S reads W->E, E continues
	# S->N, N reads E->W, W continues N->S; every face shows the art UNMIRRORED
	# left-to-right from outside, and every corner is a col15|col0 joint —
	# exactly the same joint as the seam between two cells along a run, so
	# tileable art turns corners seamlessly.
	# The BOTTOM voxel row is FOUNDATION and never carves: floors are skipped
	# under walls and pockets have no floor of their own, so a base-row carve
	# was open underneath — sconce light from the far side leaked through the
	# wall's ground line as bright dashes ("missing voxels", Daniel at Joppa
	# (3,17)). The art's bottom-row gaps stay surface colour instead.
	for d in f_img:
		var im: Image = f_img[d]
		var fh := im.get_height()
		var hard: Array = (inp.get("hard", {}) as Dictionary).get(d, [])
		var dbit: int = 1 << ["s", "e", "n", "w"].find(String(d))
		for r in R:
			var mid := (planes[r] + planes[r + 1]) * 0.5
			var fr := clampi(int((WALL_H - mid) / rh), 0, fh - 1)
			for a in W:
				var ax: int = a if (d == "s" or d == "w") else W - 1 - a
				var axc := mini(ax, im.get_width() - 1)
				# HARD gap (alpha-erased custom pixel): "remove the voxel, I
				# mean it" — carves every row (cap band, foundation) and every
				# protected zone. SOFT gap (bg colour): rows 1..R-2, protected.
				var is_hard: bool = not hard.is_empty() and fr < hard.size() \
					and bool(hard[fr][axc])
				if not is_hard:
					if r == 0 or r == R - 1:
						continue
					if im.get_pixel(axc, fr).to_html(false) != bg:
						continue
				for depth in SIDE_CARVE_PX:
					var cz: int
					var cx: int
					match d:
						"s": cz = W - 1 - depth; cx = a
						"n": cz = depth; cx = a
						"e": cz = a; cx = W - 1 - depth
						_: cz = a; cx = depth
					if is_hard or prot[cz * W + cx] == 0:
						solid[(r * W + cz) * W + cx] = 0
						carver[(r * W + cz) * W + cx] |= dbit

	# OWNERSHIP: in the corner overlap a column sits in TWO exposed shells and
	# every colour heuristic turns ambiguous — which art to wear, what counts
	# as a back, who paints the roof ring (Daniel's corner cluster). Each
	# column has ONE owning face: the exposed dir it is SHALLOWEST in
	# (ties break s,e,n,w). All colour rules key off the owner.
	var dir_names := ["s", "e", "n", "w"]
	var own_dir := PackedInt32Array()
	own_dir.resize(W * W)
	for z in W:
		for x in W:
			var best := -1
			var bestd := SIDE_CARVE_PX
			for di in 4:
				if String(fv[dir_names[di]]) == "":
					continue
				var dep: int
				match di:
					0: dep = W - 1 - z
					1: dep = W - 1 - x
					2: dep = z
					_: dep = x
				if dep < bestd:
					bestd = dep
					best = di
			own_dir[z * W + x] = best

	# A SKIN voxel wears its art pixel on EVERY face it shows — outer skin,
	# step sides, pocket-floor top, roof edge (Daniel: "blue on the face, but
	# not on the side (nor the top)"). Precompute each shell voxel's art colour
	# PER OWNING FACE. ring_col is the depth-0 skin only (the roof's outermost
	# ring follows it), written by each column's OWNER alone.
	var shell_col := {"s": {}, "n": {}, "e": {}, "w": {}}
	var ring_col := {}
	for d in f_img:
		var im: Image = f_img[d]
		var fh := im.get_height()
		for r in R:
			var midy := (planes[r] + planes[r + 1]) * 0.5
			var frr := clampi(int((WALL_H - midy) / rh), 0, fh - 1)
			for a in W:
				var ax: int = a if (d == "s" or d == "w") else W - 1 - a
				var pc := im.get_pixel(mini(ax, im.get_width() - 1), frr)
				if pc.to_html(false) == bg:
					continue
				for depth in SIDE_CARVE_PX:
					var cz: int
					var cx: int
					match String(d):
						"s": cz = W - 1 - depth; cx = a
						"n": cz = depth; cx = a
						"e": cz = a; cx = W - 1 - depth
						_: cz = a; cx = depth
					shell_col[d][Vector3i(cx, cz, r)] = pc
					if depth == 0 and r == 0 and own_dir[cz * W + cx] == dir_names.find(String(d)):
						ring_col[Vector2i(cx, cz)] = pc

	# emission: every solid voxel face against air, once
	var recess := _wall_recess_color()
	var backc := _wall_back_color()
	var mainc := _qud_color(_wall_main)
	var out := []
	var ps := 1.0 / W
	for r in R:
		var yb: float = planes[r + 1]
		var yt: float = planes[r]
		for z in W:
			var az := _cap_az(z, caph, W)
			var z0 := -0.5 + z * ps
			var z1 := z0 + ps
			for x in W:
				if solid[(r * W + z) * W + x] == 0:
					continue
				var x0 := -0.5 + x * ps
				var x1 := x0 + ps
				var capc := cap_img.get_pixel(x, az)
				# +Y: the cap surface, a carved pocket's floor — or a skin
				# voxel's TOP: the roof's outermost ring follows the face art
				# ("the blue voxels on the top row should have blue tops"), and
				# a pocket floor on a skin voxel keeps that voxel's colour.
				if r == 0 or solid[((r - 1) * W + z) * W + x] == 0:
					var tc := recess
					var tk := "recess-floor"
					if r == 0:
						tk = "ring-top" if ring_col.has(Vector2i(x, z)) else "cap-top"
						tc = ring_col.get(Vector2i(x, z), capc)
					else:
						# owner art ONLY under FACE-carved voids (a skin
						# voxel's top in a face pocket). A void carved from
						# the ROOF gets a pit floor — recess — even inside a
						# face's shell: Daniel's edge channel floors wore
						# north-face art ("red and blue, not black").
						var above := ((r - 1) * W + z) * W + x
						var oi := own_dir[z * W + x]
						if carver[above] != 0 and oi >= 0 \
								and shell_col[dir_names[oi]].has(Vector3i(x, z, r)):
							tc = (shell_col[dir_names[oi]][Vector3i(x, z, r)] as Color).darkened(0.1)
							tk = "pocket-top(%s)" % dir_names[oi]
					out.append({"q": [Vector3(x0, yt, z0), Vector3(x1, yt, z0),
						Vector3(x1, yt, z1), Vector3(x0, yt, z1)],
						"n": Vector3.UP, "c": tc,
						"m": {"k": tk, "v": Vector3i(x, z, r)}})
				# -Y: underside over a pocket below (rare; reads as shadow)
				if r + 1 < R and solid[((r + 1) * W + z) * W + x] == 0:
					out.append({"q": [Vector3(x0, yb, z0), Vector3(x0, yb, z1),
						Vector3(x1, yb, z1), Vector3(x1, yb, z0)],
						"n": Vector3.DOWN, "c": recess,
						"m": {"k": "underside", "v": Vector3i(x, z, r)}})
				# laterals: skip toward wall neighbours (flush below the cap; the
				# seam pass owns the cap row), emit toward carved pockets and the
				# exposed outside
				for s in [[0, 1, "s"], [0, -1, "n"], [1, 0, "e"], [-1, 0, "w"]]:
					var nx: int = x + s[0]
					var nz: int = z + s[1]
					var dirname := String(s[2])
					var outside: bool = nx < 0 or nx >= W or nz < 0 or nz >= W
					if outside:
						if String(fv[dirname]) == "":
							continue          # wall neighbour: flush / seam-owned
					elif solid[(r * W + nz) * W + nx] == 1:
						continue
					var col := mainc
					var fkind := "side"
					var fmeta := {}
					if outside:
						fkind = "skin(%s)" % dirname
						# flush skin on the exposed plane: the face art pixel.
						# The CAP ROW's outer faces sample it too (art row 0) —
						# colouring them from the cap art painted the top tenth
						# of every face body-red, leaving only a sliver of the
						# art's top row visible ("the rest of the top row is
						# just red"). The art's top row now runs full height.
						var im2: Image = f_img.get(dirname)
						if im2 != null:
							var mid2 := (yt + yb) * 0.5
							var fr2 := clampi(int((WALL_H - mid2) / rh), 0, im2.get_height() - 1)
							var a2: int = x if s[1] != 0 else z
							var ax2: int = a2 if (dirname == "s" or dirname == "w") else W - 1 - a2
							var pc := im2.get_pixel(mini(ax2, im2.get_width() - 1), fr2)
							fmeta = {"ax": mini(ax2, im2.get_width() - 1), "fr": fr2}
							# a SOLID voxel where the art says CAVITY exists only
							# in the no-carve zones (cap band, foundation row,
							# corners, neighbour shells). Painting it the wall
							# main read as flush red where Daniel had ERASED —
							# the recess colour reads as the cavity's mouth.
							col = pc if pc.to_html(false) != bg else recess
					elif r == 0:
						# a cap-row voxel's lateral wears its BLOCK colour: for
						# RING voxels that is the face-art row-0 pixel (what
						# the ring top and skin show), not the cap art — a
						# blue ring block is blue on its inner lip too
						# (Daniel's lip picks: ring top blue, lip red).
						fkind = "roof-trench"
						var bc0: Color = ring_col.get(Vector2i(x, z), capc)
						var shade0 := _interior_shade(Vector3(s[0], 0, s[1]))
						col = Color(bc0.r * shade0, bc0.g * shade0, bc0.b * shade0, 1.0)
					elif (carver[(r * W + nz) * W + nx] & (1 << dir_names.find(dirname))) != 0 \
							and own_dir[nz * W + nx] == dir_names.find(dirname):
						# a DEEP BACK is a pocket receding into its OWN face:
						# the empty was carved by dirname AND positionally
						# belongs to dirname's shell. An east-carved slot
						# running along the SOUTH skin is south-face relief —
						# its end wall grades as a SIDE (Daniel's make-1-like-2
						# pick pair: back(e) #502416 vs side(owner=s) #883d26).
						fkind = "back(%s)" % dirname
						col = backc
					else:
						# the SIDE of a relief step: the owning voxel's own
						# surface colour, shadowed — a blue voxel is blue on
						# its sides too, and the baked shading gives the relief
						# its depth. A ±X side belongs to the s/n relief, a ±Z
						# side to e/w — the axis-consistent shell owns the face.
						var key := Vector3i(x, z, r)
						var sc := Color(0, 0, 0, 0)
						var oi2 := own_dir[z * W + x]
						fkind = "side(owner=%s)" % (dir_names[oi2] if oi2 >= 0 else "none")
						if oi2 >= 0 and shell_col[dir_names[oi2]].has(key):
							sc = shell_col[dir_names[oi2]][key]
						var base := sc if sc.a > 0.0 else mainc
						var shade := _interior_shade(Vector3(s[0], 0, s[1]))
						col = Color(base.r * shade, base.g * shade, base.b * shade, 1.0)
					var nrm := Vector3(s[0], 0, s[1])
					var pa: Vector3
					var pb: Vector3
					if s[0] > 0:      pa = Vector3(x1, yb, z0); pb = Vector3(x1, yb, z1)
					elif s[0] < 0:    pa = Vector3(x0, yb, z1); pb = Vector3(x0, yb, z0)
					elif s[1] > 0:    pa = Vector3(x0, yb, z1); pb = Vector3(x1, yb, z1)
					else:             pa = Vector3(x1, yb, z0); pb = Vector3(x0, yb, z0)
					var fm := {"k": fkind, "v": Vector3i(x, z, r)}
					for mk in fmeta:
						fm[mk] = fmeta[mk]
					out.append({"q": [pa, pb, Vector3(pb.x, yt, pb.z), Vector3(pa.x, yt, pa.z)],
						"n": nrm, "c": col, "m": fm})
	# Boundary CLOSURES for hard carves are cross-cell: a pocket stopping at a
	# flush neighbour needs its back wall, but a pocket CONTINUING through the
	# seam (both sides carved — Daniel's slot) must stay open. A cached
	# per-cell mesh cannot know the neighbour's edge, so faces() only STASHES
	# this cell's boundary-solidity profile; _emit_carve_closures pairs the two
	# cells' profiles after every cell is built.
	var prof := {}
	var ecol := {}
	for d2 in ["s", "n", "e", "w"]:
		var pb := PackedByteArray()
		pb.resize(R * W)
		var pc := PackedColorArray()
		pc.resize(R * W)
		# a boundary voxel's visible SIDE colour comes from the perpendicular
		# exposed face's shell art — same rule as in-cell sides
		var perp: Array = ["s", "n"] if (d2 == "e" or d2 == "w") else ["e", "w"]
		for r in R:
			for a in W:
				var cz: int
				var cx: int
				match String(d2):
					"s": cz = W - 1; cx = a
					"n": cz = 0; cx = a
					"e": cz = a; cx = W - 1
					_: cz = a; cx = 0
				pb[r * W + a] = solid[(r * W + cz) * W + cx]
				var c := mainc
				for d3 in perp:
					if shell_col[d3].has(Vector3i(cx, cz, r)):
						c = shell_col[d3][Vector3i(cx, cz, r)]
						break
				pc[r * W + a] = c
		prof[d2] = pb
		ecol[d2] = pc
	_last_faces_prof = prof
	_last_faces_ecol = ecol
	_last_faces_planes = planes
	return out

## Faces for an ARRANGEMENT of same-family wall cells — the voxel editor's
## preview, built by the SAME volume rules as the game. `layout` is an Array of
## Vector2i cell coords; `obj` supplies the colour context exactly as
## _rebuild_walls derives it. `edit_img` (16x24 or null) substitutes unsaved
## editor art wherever the arrangement resolves to `edit_variant` — cap AND
## face bands. `face_overrides` (face tile -> band Image) substitutes the
## editor's family-wide face surface on the four run variants every face
## renders from. Returns [{q: [4 world-space Vector3], n: Vector3, c: Color}].
func wall_preview_arrangement(sel_tile: String, obj: Dictionary, layout: Array,
		edit_img: Image, edit_variant: String, face_overrides := {}) -> Array:
	_wall_tile = _canon_wall_tile(sel_tile)
	_wall_main = _pick_color_string(obj)
	_wall_detail = String(obj.get("detail", ""))
	_wall_bg = _parse_bg(_bg_source(obj))
	var cells := {}
	for k in layout:
		cells[k] = true
	var offs := [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]
	var out := []
	var closure_cells := {}
	for k in layout:
		var bits := ""
		for o in offs:
			bits += "1" if cells.has(k + o) else "0"
		var v := _variant_for_bits(_wall_tile, bits)
		var wn: bool = cells.has(k + Vector2i(0, -1))
		var ws: bool = cells.has(k + Vector2i(0, 1))
		var we: bool = cells.has(k + Vector2i(1, 0))
		var ww: bool = cells.has(k + Vector2i(-1, 0))
		var fv := {
			"s": "" if ws else _face_variant(v, we, ww),
			"e": "" if we else _face_variant(v, wn, ws),
			"n": "" if wn else _face_variant(v, ww, we),
			"w": "" if ww else _face_variant(v, ws, wn),
		}
		var inp := _wall_cell_inputs(v, fv, edit_img, edit_variant, face_overrides)
		if inp.is_empty():
			continue
		for f in _wall_cell_faces(inp):
			var q := []
			for p in f["q"]:
				q.append(p + Vector3(k.x, 0.0, k.y))
			var fm2: Dictionary = (f.get("m", {}) as Dictionary).duplicate()
			fm2["cell"] = k
			fm2["variant"] = v
			out.append({"q": q, "n": f["n"], "c": f["c"], "m": fm2})
		closure_cells[k] = {"prof": _last_faces_prof, "ecol": _last_faces_ecol,
			"planes": _last_faces_planes, "W": (inp["cap"] as Image).get_width()}
	for quads in _carve_closure_quads(closure_cells).values():
		for f in quads:
			out.append(f)
	return out

## Public face of the wall-art layout for the voxel editor: where a 16x24
## wall art's cap band ends and its face band begins. The editor authors
## CANONICAL layout (14-row cap over 10-row face) — never the stock scan —
## so a saved variant can't drift out of layout with its family.
func wall_art_split(img: Image) -> Vector2i:
	return _wall_layout(img)

## The exported variant name matching an autotile bit pattern: exact art, else
## cardinals-only, else the tile unchanged.
func _variant_for_bits(tile: String, bits: String) -> String:
	var dash := tile.rfind("-")
	var dot := tile.rfind(".")
	if dash < 0 or dot < dash:
		return tile
	var base := tile.substr(0, dash)
	var ext := tile.substr(dot)
	var cand := base + "-" + bits + ext
	if _mask(cand) != null:
		return cand
	var card := ""
	for i in bits.length():
		card += bits[i] if i % 2 == 0 else "0"
	cand = base + "-" + card + ext
	if _mask(cand) != null:
		return cand
	return tile

## Shared material for voxel caps:

## The core seen through the carved gaps. Art theory: a recess reads as a darker,
## slightly ambient-tinted shade of the material ITSELF, not a foreign colour. So
## take the wall's MAIN (the "red"), darken it, and nudge it toward the scene
## background (the teal ambient) — a colour between the red and the world bg, as
## requested — so gaps read as deep shadow in the material rather than a teal hole.
## Colour of a recess (carved gap floor, solid core): the wall's own red, darkened,
## with only a faint ambient nudge — reads as the material in shadow, not a foreign
## hole. Shared by the carved pocket floors and backs so they match.
## Colour of a carved pocket's BACK wall (parallel to the wall face): the
## material in DEEP shadow — clearly darker than any perpendicular side, so
## the pocket's form reads (Daniel: "the back section is the same color as
## the section perpendicular"). A family's explicit core override still wins.
func _wall_back_color() -> Color:
	var fam := tile_family(_wall_tile)
	if _core_overrides.has(fam):
		return _core_overrides[fam]
	return _qud_color(_wall_main).darkened(0.52)

## Baked light for INTERIOR faces (pocket sides, roof trenches): a fixed sun
## from the upper south-east, so differently-oriented surfaces always separate
## even under flat scene lighting — the same trick the editor preview uses.
func _interior_shade(n: Vector3) -> float:
	if n.x > 0.5:
		return 0.82
	if n.z > 0.5:
		return 0.76
	if n.x < -0.5:
		return 0.66
	return 0.60

func _wall_recess_color() -> Color:
	var fam := tile_family(_wall_tile)
	if _core_overrides.has(fam):
		return _core_overrides[fam]
	return _qud_color(_wall_main).darkened(0.5).lerp(_world_bg, 0.12)

## Clear every cache that bakes wall art or the core colour into textures/meshes.
## Called when tiles_custom changes or overrides.json is re-parsed.
func _wall_caches_clear() -> void:
	_wallmat_cache.clear()
	_cap_gap_cache.clear()
	_voxel_cache.clear()
	_bottom_open_cache.clear()

## Does this wall cell's custom art hard-carve its BOTTOM row on any exposed
## face? If so the ground shows through the openings and the floor pass renders
## the cell's ground instead of skipping it (and the wall emits no closure
## floors — the real ground is the floor). Cached per (variant, neighbourhood).
var _bottom_open_cache := {}
func _wall_bottom_open_at(k: Vector2i, wall_cells: Dictionary) -> bool:
	var tile := String(wall_cells.get(k, ""))
	if tile == "":
		return false
	var wn := wall_cells.has(Vector2i(k.x, k.y - 1))
	var ws := wall_cells.has(Vector2i(k.x, k.y + 1))
	var we := wall_cells.has(Vector2i(k.x + 1, k.y))
	var ww := wall_cells.has(Vector2i(k.x - 1, k.y))
	var key := "%s|%s%s%s%s" % [tile, wn, ws, we, ww]
	if _bottom_open_cache.has(key):
		return _bottom_open_cache[key]
	var fvs := []
	if not ws: fvs.append(_face_variant(tile, we, ww))
	if not we: fvs.append(_face_variant(tile, wn, ws))
	if not wn: fvs.append(_face_variant(tile, ww, we))
	if not ww: fvs.append(_face_variant(tile, ws, wn))
	var open := false
	for t in fvs:
		if _custom_tile_path(String(t)) == "":
			continue
		var m := _mask(String(t))
		if m == null:
			continue
		var sp := _wall_layout(m)
		if sp.y >= m.get_height():
			continue
		var by := m.get_height() - 1
		for x in m.get_width():
			if m.get_pixel(x, by).a < 0.5:
				open = true
				break
		if open:
			break
	_bottom_open_cache[key] = open
	return open

func _voxel_material() -> StandardMaterial3D:
	if _voxel_mat != null:
		return _voxel_mat
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	# The vertex colours ARE sRGB (from _qud_color / the recoloured tile). Godot
	# defaults vertex_color_is_srgb=false, treating them as linear, which skips the
	# sRGB->linear step and lifts the dark green/blue channels — the wall reds came
	# out a pale, desaturated tan. Flag them sRGB so they're converted correctly and
	# the brick red keeps its saturation. (Other tiles look right because they use an
	# albedo TEXTURE, which is already sRGB-flagged; only the vertex-coloured walls
	# were affected.)
	m.vertex_color_is_srgb = true
	m.roughness = 0.85
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if SHADED_WORLD:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	else:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_voxel_mat = m
	return m

## Voxel skin material for the LIVE zone only — same as _voxel_material but ALPHA_DEPTH_PRE_PASS
## so those walls can smoothly blend for the camera cutaway (GeometryInstance3D.transparency). At
## transparency 0 the depth pre-pass keeps it sorting like solid opaque; as it rises it blends out.
## Neighbour zones use the plain OPAQUE _voxel_material — they never fade, and there are MANY of them
## on the surface, so routing them through the transparent pipeline was what made the overworld crawl.
var _voxel_mat_live: StandardMaterial3D
func _voxel_material_live() -> StandardMaterial3D:
	if _voxel_mat_live == null:
		_voxel_mat_live = _voxel_material().duplicate()
		_voxel_mat_live.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	return _voxel_mat_live

## The skin material for the wall currently being built: the fade-capable one for the live zone,
## plain opaque for neighbours (keyed off _live_build, set only during the live static build).
func _wall_skin_material() -> StandardMaterial3D:
	return _voxel_material_live() if _live_build else _voxel_material()


## The top-down cap of ONE autotile variant, recoloured. Borders appear only on
## the edges that variant says are exposed, so adjacent cells join seamlessly.
## The variant whose CAP art a cell renders: the exact (Qud-reported) name
## when it has CUSTOM art, else the cardinal projection when THAT does — the
## platonic derivation covers all 16 cardinal signatures, but Qud reports
## DIAGONAL-flavoured names (00100011, 01100010) that would silently fall
## back to STOCK art (Daniel: "6,21 has 2 neighbors that should match it").
## Stock stays stock: with no custom family the exact variant is correct.
func _cap_variant(tile: String) -> String:
	if _custom_tile_path(tile) != "":
		return tile
	var dash := tile.rfind("-")
	var dot := tile.rfind(".")
	if dash < 0 or dot < dash:
		return tile
	var bits := tile.substr(dash + 1, dot - dash - 1)
	var card := ""
	for i in bits.length():
		card += bits[i] if i % 2 == 0 else "0"
	var cand := tile.substr(0, dash) + "-" + card + tile.substr(dot)
	if _custom_tile_path(cand) != "":
		return cand
	return tile

func _cap_tex(tile: String) -> ImageTexture:
	tile = _cap_variant(tile)
	var key := "cap|%s|%s|%s|%s" % [tile, _wall_main, _wall_detail, _wall_bg]
	if _wallmat_cache.has(key):
		return _wallmat_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return _wall_top_material_tex()      # fall back to the isolated tile
	var region := mask.get_region(Rect2i(0, 0, mask.get_width(), _wall_split_for(tile, mask).x))
	# custom art renders AS-AUTHORED (polychrome); the mask recolour would crush it
	var tex := _as_authored(region) if _custom_tile_path(tile) != "" \
		else _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
	_wallmat_cache[key] = tex
	return tex

## A custom-art band, as painted: opaque pixels keep their colour, transparent
## pixels become the wall background — which is exactly the carve predicate
## (_cap_gaps tests px == bg), so painting transparent means "carve here".
func _as_authored(img: Image) -> ImageTexture:
	var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	var bg := _wall_bg_color()
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			out.set_pixel(x, y, p if p.a >= 0.5 else bg)
	return ImageTexture.create_from_image(out)

func _wall_top_material_tex() -> ImageTexture:
	return _wall_region_tex("top")

## Sides only — roofs are built per-cell in _rebuild_walls so each keeps its own
## autotile variant.
func _build_wall_mesh(wall_set: Dictionary) -> ArrayMesh:
	var st_side := SurfaceTool.new(); st_side.begin(Mesh.PRIMITIVE_TRIANGLES)

	var minx := 1 << 30; var maxx := -(1 << 30)
	var minz := 1 << 30; var maxz := -(1 << 30)
	for k in wall_set:
		minx = min(minx, k.x); maxx = max(maxx, k.x)
		minz = min(minz, k.y); maxz = max(maxz, k.y)

	# side faces: exposed edges merged into runs
	_sides_x(st_side, wall_set, minx, maxx, minz, maxz, 1)
	_sides_x(st_side, wall_set, minx, maxx, minz, maxz, -1)
	_sides_z(st_side, wall_set, minx, maxx, minz, maxz, 1)
	_sides_z(st_side, wall_set, minx, maxx, minz, maxz, -1)

	st_side.generate_tangents()      # normal mapping needs a tangent frame
	var mesh := ArrayMesh.new()
	st_side.commit(mesh)
	return mesh

# Baked directional shade per face (multiplies albedo via vertex colour), so the
# carved form reads without depending on scene lighting. Fake sun from +X/+Z.
const SHADE_TOP := 1.0
const SHADE := {1: {"x": 0.72, "z": 0.86}, -1: {"x": 0.52, "z": 0.44}}

func _v(st: SurfaceTool, p: Vector3, n: Vector3, uv: Vector2, s: float) -> void:
	st.set_normal(n)
	st.set_color(Color(s, s, s))
	st.set_uv(uv)
	st.add_vertex(p)

func _quad_top(st: SurfaceTool, x0: int, x1: int, z0: int, z1: int) -> void:
	var ax := x0 - 0.5; var bx := x1 + 0.5
	var az := z0 - 0.5; var bz := z1 + 0.5
	var y := WALL_H
	var uu := float(x1 - x0 + 1); var vv := float(z1 - z0 + 1)
	var n := Vector3.UP
	var s := SHADE_TOP
	_v(st, Vector3(ax, y, az), n, Vector2(0, 0), s)
	_v(st, Vector3(bx, y, bz), n, Vector2(uu, vv), s)
	_v(st, Vector3(bx, y, az), n, Vector2(uu, 0), s)
	_v(st, Vector3(ax, y, az), n, Vector2(0, 0), s)
	_v(st, Vector3(ax, y, bz), n, Vector2(0, vv), s)
	_v(st, Vector3(bx, y, bz), n, Vector2(uu, vv), s)

func _sides_x(st: SurfaceTool, wall_set: Dictionary, minx: int, maxx: int, minz: int, maxz: int, dir: int) -> void:
	var n := Vector3(dir, 0, 0)
	var s: float = SHADE[dir]["x"]
	for x in range(minx, maxx + 1):
		var z := minz
		while z <= maxz:
			if not (wall_set.has(Vector2i(x, z)) and not wall_set.has(Vector2i(x + dir, z))):
				z += 1
				continue
			var z1 := z
			while z1 + 1 <= maxz and wall_set.has(Vector2i(x, z1 + 1)) and not wall_set.has(Vector2i(x + dir, z1 + 1)):
				z1 += 1
			var px := (x + 0.5) if dir > 0 else (x - 0.5)
			_quad_side(st, Vector3(px, 0, z - 0.5), Vector3(px, 0, z1 + 0.5), n, float(z1 - z + 1), s)
			z = z1 + 1

func _sides_z(st: SurfaceTool, wall_set: Dictionary, minx: int, maxx: int, minz: int, maxz: int, dir: int) -> void:
	var n := Vector3(0, 0, dir)
	var s: float = SHADE[dir]["z"]
	for z in range(minz, maxz + 1):
		var x := minx
		while x <= maxx:
			if not (wall_set.has(Vector2i(x, z)) and not wall_set.has(Vector2i(x, z + dir))):
				x += 1
				continue
			var x1 := x
			while x1 + 1 <= maxx and wall_set.has(Vector2i(x1 + 1, z)) and not wall_set.has(Vector2i(x1 + 1, z + dir)):
				x1 += 1
			var pz := (z + 0.5) if dir > 0 else (z - 0.5)
			_quad_side(st, Vector3(x - 0.5, 0, pz), Vector3(x1 + 0.5, 0, pz), n, float(x1 - x + 1), s)
			x = x1 + 1

# a vertical quad from base a..b (y=0) up to WALL_H; `ulen` cells wide for UV tiling
func _quad_side(st: SurfaceTool, a: Vector3, b: Vector3, n: Vector3, ulen: float, s: float) -> void:
	var top_a := a + Vector3(0, WALL_H, 0)
	var top_b := b + Vector3(0, WALL_H, 0)
	# u tiles one front-face per cell; v stretches one face over the wall height
	_v(st, a, n, Vector2(0, 1), s)
	_v(st, top_b, n, Vector2(ulen, 0), s)
	_v(st, top_a, n, Vector2(0, 0), s)
	_v(st, a, n, Vector2(0, 1), s)
	_v(st, b, n, Vector2(ulen, 1), s)
	_v(st, top_b, n, Vector2(ulen, 0), s)

# A Qud wall tile is 16x24: the top w×w square is the top-down body, the bottom
# w×(h-w) strip is the south front-face. Tops use the body from the interior tile
# (-11111111); sides use the front-face from a south-open variant (-11100000).
func _wall_top_material() -> Material:
	return _wall_mat_from_tex(_wall_region_tex("top"))

func _wall_side_material() -> Material:
	var tex := _wall_region_tex("side")
	if tex == null:
		tex = _wall_region_tex("top")  # fallback: body on sides if no face variant
	return _wall_mat_from_tex(tex)

# Height of a wall tile's south face. Measured across rock, brinestalk and metal —
# all three share the same structure:
#
#   row 13   #o............o#     cap's bottom rim (matches the interior)
#   row 14   #oooo##oo##oooo#     the wall's TOP LIP — belongs to the FACE
#   row 15+  #o###o####o###o#     face proper
#
# So the face is the last TEN rows, starting at 14. Two earlier guesses were
# wrong: the tile WIDTH (16), and 9 rows (starting at 15) — the latter left row
# 14, the wall's lip, sitting on the roof. Metal's `-10100010` variant confirms
# the boundary independently with a fully transparent row at 13.
const WALL_FACE_ROWS := 10

## Where a wall tile's top-down cap ends and its south face begins: (capRows, faceStart).
##
## Qud packs both into one image and the boundary is NOT at a fixed row. Rock and
## brinestalk butt them together at 15; metal separates them with a fully
## transparent row (13), so its cap is shorter and its face taller. Honour a real
## separator when one exists, else fall back to the last WALL_FACE_ROWS rows.
func _wall_split(img: Image) -> Vector2i:
	var w := img.get_width()
	var h := img.get_height()
	for y in range(int(h / 2), h):
		var blank := true
		for x in w:
			if img.get_pixel(x, y).a >= 0.5:
				blank = false
				break
		if blank:
			return Vector2i(y, y + 1)      # cap ends above it, face starts below
	var start: int = maxi(1, h - WALL_FACE_ROWS)
	return Vector2i(start, start)

## The CANONICAL layout for wall art WE author (the voxel editor's world):
## the roof is ALWAYS a 14x14 interior inside the 16x16 base (Daniel's
## invariant), so the cap band is everything above the face band — fixed, no
## content sniffing. Stock Qud art keeps the _wall_split SCAN: its layouts
## genuinely vary (metal 13 rows, brinestalk 15), and a blank separator row
## swallowed into a cap band would carve a trench across the roof.
func _wall_layout(img: Image) -> Vector2i:
	var start: int = maxi(1, img.get_height() - WALL_FACE_ROWS)
	return Vector2i(start, start)

## The split for a NAMED tile: canonical for our own (custom) art, scanned
## for stock — so a custom variant with an accidentally blank row can never
## fall out of layout with its family.
func _wall_split_for(tile: String, img: Image) -> Vector2i:
	if _custom_tile_path(tile) != "":
		return _wall_layout(img)
	return _wall_split(img)

## Cap-art row for a voxel row: the band maps 1:1 onto the 14x14 roof
## INTERIOR (z 1..W-2). The ring rows carry no cap art of their own — their
## identity is the FACE art — and REFLECT into the band (second /
## second-to-last row) rather than clamp: clamping duplicates the edge
## row's parity, which broke a period-2 pattern at every N/S wall-to-wall
## seam (Daniel's continuous-checkerboard round); reflection continues the
## alternation outward and stays local for arbitrary art. A 14-row band on
## the 16 grid is IDENTITY — no resampling, no doubled checker row; other
## heights scale over the interior only (13: one doubled row; 15: one skip).
func _cap_az(z: int, caph: int, W: int) -> int:
	var iz: int = z - 1
	if iz < 0:
		iz = mini(1, W - 3)
	elif iz > W - 3:
		iz = maxi(W - 4, 0)
	return mini(caph - 1, iz * caph / (W - 2))

func _wall_region_tex(kind: String, face_variant := "") -> ImageTexture:
	if _wall_tile == "":
		return null
	var key := "%s|%s|%s|%s|%s|%s" % [kind, _wall_tile, _wall_main, _wall_detail, _wall_bg, face_variant]
	if _wallmat_cache.has(key):
		return _wallmat_cache[key]
	var iso := _wall_tile.replace("-11111111", "-00000000")  # isolated wall: real border on all 4 sides
	var tex: ImageTexture = null
	if kind == "top":
		var iso_mask := _mask(iso)
		if iso_mask != null:
			# REAL fully-framed tile — recolor its top square as-is (real crenellated border)
			var w := iso_mask.get_width()
			var region := iso_mask.get_region(Rect2i(0, 0, w, _wall_split_for(iso, iso_mask).x))
			tex = _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
		else:
			var mask := _mask(_wall_tile)  # fallback: synthetic frame on the interior checker
			if mask != null:
				var w := mask.get_width()
				var region := mask.get_region(Rect2i(0, 0, w, _wall_split_for(_wall_tile, mask).x))
				tex = _framed_top(region)
	else:
		# front-face strip: the EFFECTIVE variant's face when given (its art drops the
		# frame columns on connected edges — the per-cell fix for the thin vertical
		# seam channels Daniel spotted along mixed-family runs), else the isolated
		# tile's framed face, else a south-open variant.
		var face_tile := iso
		if face_variant != "" and _mask(face_variant) != null:
			face_tile = face_variant
		var mask := _mask(face_tile)
		if mask == null:
			face_tile = _wall_tile.replace("-11111111", "-11100000")
			mask = _mask(face_tile)
		if mask != null:
			var w := mask.get_width()
			var h := mask.get_height()
			var split := _wall_split_for(face_tile, mask)
			if split.y < h:
				var region := mask.get_region(Rect2i(0, split.y, w, h - split.y))
				tex = _as_authored(region) if _custom_tile_path(face_tile) != "" \
					else _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
	if tex != null:
		_wallmat_cache[key] = tex
	return tex

# Build the framed wall-top tile the sprite shows: a tan border around a
# red/dark checker (from the -11111111 body mask). Tiled per cell on the mesh
# tops, so the tan frames form the stone-block grid.
func _framed_top(src: Image) -> ImageTexture:
	var w := src.get_width()
	var h := src.get_height()
	var main := _qud_color(_wall_main)                                    # rock foreground
	var bg := _wall_bg_color()                                            # cell background (^X or world green)
	var tan := _qud_color(_wall_detail).lerp(Color(1.0, 0.92, 0.6), 0.45) # cap/frame
	var border := 2
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			if x < border or x >= w - border or y < border or y >= h - border:
				img.set_pixel(x, y, tan)
			else:
				var p := src.get_pixel(x, y)
				var lit: bool = p.a >= 0.5 and (p.r + p.g + p.b) / 3.0 < 0.5
				img.set_pixel(x, y, main if lit else bg)
	return ImageTexture.create_from_image(img)

func _wall_mat_from_tex(tex: ImageTexture) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if SHADED_WORLD:
		# real lighting shades faces by their normals and lets them receive the sun's
		# shadow. Drop the baked per-face vertex shade so it doesn't double up.
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.vertex_color_use_as_albedo = false
		# CULL_DISABLED, not CULL_BACK: the greedy side quads don't all wind the same
		# way, so back-culling made walls vanish from some angles. Showing both faces
		# is cheap here and every face we can see should draw.
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		# per-pixel RELIEF without geometry: a normal map derived from the tile's own
		# brightness (bright detail = raised, filled background = deep) makes the sun
		# rake across the wall's surface pattern, and it shifts as the sun moves.
		if tex != null:
			var nm := _normal_from_tex(tex)
			if nm != null:
				m.normal_enabled = true
				m.normal_texture = nm
				m.normal_scale = WALL_NORMAL_SCALE
			m.roughness = 0.7    # a little specular so raked light reads as form
	else:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true   # baked per-face shade multiplies the rock
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		m.albedo_color = _qud_color(_wall_main)
	return m

## A tangent-space normal map from a texture's luminance: bright pixels read as
## raised, dark as recessed (the recolour makes the filled background dark, so it
## sits deepest — matching "transparent is the most deep"). Sobel gradient of the
## height, encoded as a normal. This is the cheap depth: no extra geometry, and
## because it feeds real lighting the relief tracks the day/night sun.
var _normal_cache := {}
func _normal_from_tex(tex: ImageTexture) -> ImageTexture:
	var img := tex.get_image()
	if img == null:
		return null
	var w := img.get_width()
	var h := img.get_height()
	var key := "%dx%d:%d" % [w, h, hash(img.get_data())]
	if _normal_cache.has(key):
		return _normal_cache[key]
	var lum := []
	for y in h:
		var row := []
		for x in w:
			var p := img.get_pixel(x, y)
			row.append((p.r + p.g + p.b) / 3.0)
		lum.append(row)
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var xl: float = lum[y][maxi(x - 1, 0)]
			var xr: float = lum[y][mini(x + 1, w - 1)]
			var yu: float = lum[maxi(y - 1, 0)][x]
			var yd: float = lum[mini(y + 1, h - 1)][x]
			var n := Vector3(-(xr - xl), -(yd - yu), 1.0).normalized()
			out.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	var t := ImageTexture.create_from_image(out)
	_normal_cache[key] = t
	return t

# --- textures & materials (floors/sprites) ----------------------------------

func _colored_tex(tile: String, main_c: String, detail_c: String, fill := Fill.NONE) -> ImageTexture:
	return _colored_tex_rgb(tile, _qud_color(main_c), _qud_color(detail_c),
		"%s|%s" % [main_c, detail_c], fill)

## Same, but with colours already resolved (the painted-ConsoleChar path).
func _colored_tex_rgb(tile: String, main: Color, detail: Color, ckey: String, fill := Fill.NONE, cutout := false) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	# _wall_bg keys the FILL colour (gap pixels paint _wall_bg_color()), so it
	# must key the cache too — a gold-fill Starship texture must not be served
	# for a world-fill wall that shares tile+colours.
	var key := "%s|%s|%d|%s|%d" % [tile, ckey, fill, _wall_bg, 1 if cutout else 0]
	# Custom art renders AS-AUTHORED: full colour straight from the file, no recolour,
	# no fill, no cutout. mtime in the key = edits invalidate themselves.
	var custom := _custom_tile_path(tile)
	if custom != "":
		key = "%s|custom|%d" % [key, FileAccess.get_modified_time(custom)]
		if _tex_cache.has(key):
			return _tex_cache[key]
		var cimg := _mask(tile)   # _mask already loads the custom file
		if cimg == null:
			return null
		var ctex2 := ImageTexture.create_from_image(cimg)
		_tex_cache[key] = ctex2
		return ctex2
	if _tex_cache.has(key):
		return _tex_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return null
	# Text/<code>.bmp glyph sprites invert the tile convention: they're an
	# OPAQUE black field with a white glyph, and Qud paints white = foreground
	# colour, black = cell background. The dark/light=main/detail lerp painted
	# the whole cell main-colour (checker: '?' probes jumped to ~113). Paint
	# glyph pixels with MAIN and turn luminance into alpha instead.
	if tile.begins_with("Text/"):
		var tw := mask.get_width()
		var th := mask.get_height()
		var timg := Image.create(tw, th, false, Image.FORMAT_RGBA8)
		# A ^X in the object's TileColor is the glyph cell's BACKGROUND (the
		# Wormhole's "&B^k" draws on a black field, not the world teal) —
		# composite fg over it opaquely; without one, luminance becomes alpha.
		var tbg := _wall_bg_color() if _wall_bg != "" else Color(0, 0, 0, 0)
		for ty in th:
			for tx in tw:
				var tp := mask.get_pixel(tx, ty)
				var tlum := (tp.r + tp.g + tp.b) / 3.0
				if _wall_bg != "":
					timg.set_pixel(tx, ty, Color(tbg.lerp(main, tlum * tp.a), 1.0))
				else:
					timg.set_pixel(tx, ty, Color(main.r, main.g, main.b, tlum * tp.a))
		var ttex := ImageTexture.create_from_image(timg)
		_tex_cache[key] = ttex
		return ttex
	var inner = null
	if fill == Fill.INTERIOR:
		inner = _interior(tile)
	elif fill == Fill.SPAN:
		inner = _fill_holes(tile)
	var tex := _recolor_rgb(mask, main, detail, fill, inner)
	# CUTOUT: the darker of the two tile colours goes TRANSPARENT (stricter than the
	# art's own alpha). The bmp is a 2-colour mask — black px paint MAIN, white px
	# DETAIL — so membership comes from the mask, not from comparing painted pixels.
	if cutout and tex != null:
		var lm := main.r * 0.299 + main.g * 0.587 + main.b * 0.114
		var ld := detail.r * 0.299 + detail.g * 0.587 + detail.b * 0.114
		var drop_main := lm <= ld
		var ci := tex.get_image()
		for cy2 in mask.get_height():
			for cx2 in mask.get_width():
				var mp := mask.get_pixel(cx2, cy2)
				if mp.a < 0.5:
					continue
				var is_main := (mp.r + mp.g + mp.b) / 3.0 <= 0.5
				if is_main == drop_main:
					# clear the WHOLE texture block this mask px maps to (the texture
					# may be upscaled; a centre-only clear would leave a lattice)
					var bx0 := cx2 * ci.get_width() / mask.get_width()
					var bx1 := (cx2 + 1) * ci.get_width() / mask.get_width()
					var by0 := cy2 * ci.get_height() / mask.get_height()
					var by1 := (cy2 + 1) * ci.get_height() / mask.get_height()
					for scy in range(by0, by1):
						for scx in range(bx0, bx1):
							var pc := ci.get_pixel(scx, scy)
							ci.set_pixel(scx, scy, Color(pc.r, pc.g, pc.b, 0.0))
		tex = ImageTexture.create_from_image(ci)
	_tex_cache[key] = tex
	return tex

# Which transparent pixels are INSIDE the art rather than around it.
#
# The tile itself can't tell us: alpha is strictly binary, and the RGB left under
# transparent pixels is atlas bleed from neighbouring tiles (it appears in rows
# entirely outside the sprite, and visually identical gaps carry different
# colours). So the test is geometric — a pixel is interior when the art spans it
# BOTH vertically in its column and horizontally in its row.
#
# Why not a border flood fill, the textbook answer? Qud art often has a
# transparent separator line that reaches the tile edge — the chest has one under
# its lid — and a flood fill drains the whole interior out through it, leaving
# you seeing the world through the middle of the chest. Span testing never asks
# about connectivity, so a leak can't propagate.
#
# Known limit: a sprite whose interior SHOULD stay see-through (a basket you look
# into) is geometrically indistinguishable from one that shouldn't. No rule here
# separates them. Note Qud's own 2D view shows the cell background through that
# interior too, so filling it matches the game.
func _interior(tile: String) -> Array:
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	if _interior_cache.has(fname):
		return _interior_cache[fname]
	var mask := _mask(tile)
	var out := []
	if mask == null:
		return out
	var w := mask.get_width()
	var h := mask.get_height()
	var solid := []
	for y in h:
		var row := []
		for x in w:
			row.append(mask.get_pixel(x, y).a >= 0.5)
		solid.append(row)
	# first/last opaque pixel per column and per row
	var col_lo := []; var col_hi := []
	for x in w:
		var lo := -1; var hi := -1
		for y in h:
			if solid[y][x]:
				if lo < 0: lo = y
				hi = y
		col_lo.append(lo); col_hi.append(hi)
	for y in h:
		var lo := -1; var hi := -1
		for x in w:
			if solid[y][x]:
				if lo < 0: lo = x
				hi = x
		var row := []
		for x in w:
			row.append(not solid[y][x] and lo >= 0 and x > lo and x < hi
				and col_lo[x] >= 0 and y > col_lo[x] and y < col_hi[x])
		# ...plus any NARROW horizontal slot inside the row's span. The chest's
		# side bands are separated from its body by 1px channels running the
		# sprite's full height; nothing is opaque below them, so the column test
		# rejects them and daylight shows through the chest. Relaxing to "row
		# alone" over-fills instead — it webs the gaps between a dromad's legs.
		# Width separates the two: a 1-2px slot is a seam in the art, a 10px
		# opening is the world showing through.
		if lo >= 0:
			var x := lo + 1
			while x < hi:
				if solid[y][x]:
					x += 1
					continue
				var run := x
				while run < hi and not solid[y][run]:
					run += 1
				if run - x <= MAX_SLOT_PX:
					for k in range(x, run):
						row[k] = true
				x = run
		out.append(row)

	# the same slot test VERTICALLY: the chest has a 1px-tall separator under its
	# lid, and that row's own span covers only the middle, so the part crossing
	# the side bands would stay a slit of daylight.
	for x in w:
		var top: int = col_lo[x]
		var bot: int = col_hi[x]
		if top < 0:
			continue
		var y: int = top + 1
		while y < bot:
			if solid[y][x]:
				y += 1
				continue
			var run: int = y
			while run < bot and not solid[run][x]:
				run += 1
			if run - y <= MAX_SLOT_PX:
				for k in range(y, run):
					out[k][x] = true
			y = run

	_close_pinholes(w, h, solid, out)
	_interior_cache[fname] = out
	return out

# Fill any transparent pixel whose 4 neighbours are all opaque-or-filled, to
# stability. The slot passes leave single-pixel holes where a horizontal and a
# vertical gap cross; this closes them generically rather than by special case.
# It cannot leak into open space — a real opening's boundary always touches a
# genuinely outside pixel, so the fill has nowhere to start.
## "Fill the holes" — the UNION of enclosed gaps, row-spans and column-spans. Each
## catches holes the others miss: a wheel\'s open paddle bottoms (row), a millstone\'s
## side notches (enclosure) and the pinched neck between its cap and body (column).
## None is a superset of the others, so "fill it in more" is all three. Always fills
## at least as much as INTERIOR, never less. Squares nothing off — that\'s Fill.ALL.
const POCKET_MAX_PX := 8   # an enclosed region bigger than this reads as an opening, not a shadow

## "Small pockets only" — the INTERIOR fill minus its LARGE regions. A 1-2px enclosed
## gap is a shadow drawn into the art (a basket's weave); a ~60px enclosed arch is the
## world showing through (Daniel, 2026-08-12: the basket hoop's arch goes clear, the
## weave shadows stay). Connected components over POCKET_MAX_PX are dropped.
func _pockets(tile: String) -> Array:
	var fname := tile_filename(tile) + "|pockets"
	if _interior_cache.has(fname):
		return _interior_cache[fname]
	var inner := _interior(tile)
	var out := []
	for row in inner:
		out.append((row as Array).duplicate())
	var h := out.size()
	var w: int = 0 if h == 0 else (out[0] as Array).size()
	var seen := {}
	for y in h:
		for x in w:
			if out[y][x] and not seen.has(Vector2i(x, y)):
				var comp := [Vector2i(x, y)]
				seen[Vector2i(x, y)] = true
				var qi := 0
				while qi < comp.size():
					var c: Vector2i = comp[qi]
					qi += 1
					for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var n: Vector2i = c + d
						if n.x >= 0 and n.x < w and n.y >= 0 and n.y < h \
								and out[n.y][n.x] and not seen.has(n):
							seen[n] = true
							comp.append(n)
				if comp.size() > POCKET_MAX_PX:
					for c2 in comp:
						out[c2.y][c2.x] = false
	_interior_cache[fname] = out
	return out

func _fill_holes(tile: String) -> Array:
	var fname := tile_filename(tile) + "|holes"
	if _interior_cache.has(fname):
		return _interior_cache[fname]
	var a := _interior(tile)
	var b := _row_span(tile)
	var col := _col_span(tile)
	var out := []
	for y in a.size():
		var row := []
		for x in a[y].size():
			row.append(bool(a[y][x])
				or (y < b.size() and x < b[y].size() and bool(b[y][x]))
				or (y < col.size() and x < col[y].size() and bool(col[y][x])))
		out.append(row)
	_interior_cache[fname] = out
	return out

## Vertical counterpart to _row_span: every transparent pixel between the first and
## last opaque pixel in its COLUMN. This is what reconnects a shape pinched into two
## lobes — a millstone's cap floats above its body joined only by a thin neck, and
## column-span fills the neck's flanks so the two read as one solid stone.
func _col_span(tile: String) -> Array:
	var fname := tile_filename(tile) + "|col"
	if _interior_cache.has(fname):
		return _interior_cache[fname]
	var mask := _mask(tile)
	var out := []
	if mask == null:
		return out
	var w := mask.get_width()
	var h := mask.get_height()
	var col_lo := []
	var col_hi := []
	for x in w:
		var lo := -1
		var hi := -1
		for y in h:
			if mask.get_pixel(x, y).a >= 0.5:
				if lo < 0: lo = y
				hi = y
		col_lo.append(lo); col_hi.append(hi)
	for y in h:
		var row := []
		for x in w:
			row.append(col_lo[x] >= 0 and y > col_lo[x] and y < col_hi[x]
				and mask.get_pixel(x, y).a < 0.5)
		out.append(row)
	_interior_cache[fname] = out
	return out

## Every transparent pixel between the first and last opaque pixel in its row.
## Open at the bottom (a wheel\'s paddle compartments) still fills; outside the
## silhouette stays clear. A component of _fill_holes, not used directly.
func _row_span(tile: String) -> Array:
	var fname := tile_filename(tile) + "|span"
	if _interior_cache.has(fname):
		return _interior_cache[fname]
	var mask := _mask(tile)
	var out := []
	if mask == null:
		return out
	var w := mask.get_width()
	var h := mask.get_height()
	for y in h:
		var lo := -1
		var hi := -1
		for x in w:
			if mask.get_pixel(x, y).a >= 0.5:
				if lo < 0: lo = x
				hi = x
		var row := []
		for x in w:
			row.append(lo >= 0 and x > lo and x < hi and mask.get_pixel(x, y).a < 0.5)
		out.append(row)
	_interior_cache[fname] = out
	return out

func _close_pinholes(w: int, h: int, solid: Array, inner: Array) -> void:
	var changed := true
	while changed:
		changed = false
		for y in h:
			for x in w:
				if solid[y][x] or inner[y][x]:
					continue
				if (_filled(w, h, solid, inner, x - 1, y)
					and _filled(w, h, solid, inner, x + 1, y)
					and _filled(w, h, solid, inner, x, y - 1)
					and _filled(w, h, solid, inner, x, y + 1)):
					inner[y][x] = true
					changed = true

func _filled(w: int, h: int, solid: Array, inner: Array, x: int, y: int) -> bool:
	# off the tile counts as OPEN, not enclosed — otherwise art touching the
	# image edge would seal itself against the border
	if x < 0 or y < 0 or x >= w or y >= h:
		return false
	return solid[y][x] or inner[y][x]

# Recolour a 2-colour mask Image: black -> main, white -> detail. Transparent
# pixels become the cell background per `fill` (see the Fill enum).
func _recolor_image(mask: Image, main_c: String, detail_c: String, fill: int, inner = null) -> ImageTexture:
	return _recolor_rgb(mask, _qud_color(main_c), _qud_color(detail_c), fill, inner)

func _recolor_rgb(mask: Image, main: Color, detail: Color, fill: int, inner = null) -> ImageTexture:
	var w := mask.get_width()
	var h := mask.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var p := mask.get_pixel(x, y)
			if p.a < 0.5:
				# transparent = the cell/object BACKGROUND (world dark-green)
				var paint: bool = fill == Fill.ALL or (inner != null
					and y < inner.size() and bool(inner[y][x]))
				img.set_pixel(x, y, _wall_bg_color() if paint else Color(0, 0, 0, 0))
			else:
				var lum := (p.r + p.g + p.b) / 3.0
				var c := main.lerp(detail, lum)
				img.set_pixel(x, y, Color(c.r, c.g, c.b, p.a))
	return ImageTexture.create_from_image(img)

func _canon_wall_tile(tile: String) -> String:
	var dot := tile.rfind(".")
	var base := tile if dot < 0 else tile.substr(0, dot)
	var ext := "" if dot < 0 else tile.substr(dot)
	var dash := base.rfind("-")
	if dash >= 0:
		var suffix := base.substr(dash + 1)
		if suffix.length() == 8 and _is_binary(suffix):
			return base.substr(0, dash) + "-11111111" + ext
	return tile

func _is_binary(s: String) -> bool:
	for ch in s:
		if ch != "0" and ch != "1":
			return false
	return true

func _mask(tile: String) -> Image:
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	var custom := _custom_tile_path(tile)
	if custom != "":
		fname = "%s|custom|%d" % [fname, FileAccess.get_modified_time(custom)]
	if _mask_cache.has(fname):
		return _mask_cache[fname]
	var path := custom if custom != "" else _tiles_dir.path_join(tile.replace("/", "_").replace("\\", "_").replace(":", "_"))
	if not FileAccess.file_exists(path):
		if _live_build: _static_saw_missing = true   # export race — retry the static build later
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		if _live_build: _static_saw_missing = true   # file mid-write (export in progress)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		# Qud names some PNGs .bmp, so PNG is the norm — but an EXTERNAL tool
		# writing tiles_custom can honour the extension and produce a real BMP
		# (PIL did: the four face sources silently failed to load and every
		# wall face fell back to its own stock checker band — "roof pattern on
		# the side"). Accept genuine BMP bytes rather than failing silently.
		if img.load_bmp_from_buffer(bytes) != OK:
			if _live_build: _static_saw_missing = true   # partial file mid-export
			return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mask_cache[fname] = img
	return img

func _mesh_material(tile: String, main_c: String, detail_c: String, tex: ImageTexture) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [tile, main_c, detail_c]
	if _texmat_cache.has(key):
		return _texmat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_texmat_cache[key] = m
	return m

## Water surface (USER mode): the floor art alpha-blended so the depths
## backing and any submerged glow read through it. Separate cache key from
## the opaque floor material — 1:1 keeps that one.
func _water_surface_material(tile: String, main_c: String, detail_c: String, tex: ImageTexture) -> StandardMaterial3D:
	var key := "water|%s|%s|%s" % [tile, main_c, detail_c]
	if _texmat_cache.has(key):
		return _texmat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.albedo_color = Color(1, 1, 1, 0.72)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = -2   # the surface draws before other transparents (glow ghosts add on top)
	_texmat_cache[key] = m
	return m

# Bridge deck: same as a floor, but fully opaque so nothing shows through.
func _deck_material(tile: String, main_c: String, detail_c: String, tex: ImageTexture) -> StandardMaterial3D:
	var key := "deck|%s|%s|%s" % [tile, main_c, detail_c]
	if _texmat_cache.has(key):
		return _texmat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_texmat_cache[key] = m
	return m

## ONE voxel's exposed faces, for tile-derived solids built on the wall lattice.
## `open` flags the six neighbours in order -X, +X, -Y, +Y, -Z, +Z; a face is emitted
## only where its neighbour is absent, so a volume built by calling this per cell is
## watertight and carries no interior geometry. Shades match the tent fabric's table
## (1.00 on Z, 0.72 on X, 0.92 top, 0.50 underside) so a pole and the sheet it holds
## up agree, and they are BAKED into the vertex colour — see _vox_skin_material.
func _vox_block(st: SurfaceTool, o: Vector3, s: Vector3, col: Color, open: Array) -> void:
	var x0: float = o.x
	var x1: float = o.x + s.x
	var y0: float = o.y
	var y1: float = o.y + s.y
	var z0: float = o.z
	var z1: float = o.z + s.z
	var faces: Array = [
		[0.72, [Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0)]],
		[0.72, [Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1)]],
		[0.50, [Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1)]],
		[0.92, [Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0)]],
		[1.00, [Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0)]],
		[1.00, [Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1)]],
	]
	for fi in faces.size():
		if not bool(open[fi]):
			continue
		var fdef: Array = faces[fi]
		var sh: float = fdef[0]
		var fc := Color(col.r * sh, col.g * sh, col.b * sh, col.a)
		var quad: Array = fdef[1]
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_color(fc)
			st.set_normal(Vector3.UP)
			st.add_vertex(quad[k])


## Vertex-coloured and UNSHADED, for every tile-derived solid built out of _vox_block;
## they bake their own shading into the vertex colours (the face table: 1.00 broad, 0.92 top, 0.72
## rim, 0.50 underside). The voxel-WALL material is SHADED_WORLD-lit, and lighting a
## flat sheet by orientation made an east-west tent read darker than a north-south one
## for no reason the player can see (Daniel). The fabric's old art quads were unshaded
## too, so a tent looked the same whichever way it ran; per-cell light still lands via
## the light_frac the vertex colours are multiplied by.
var _vox_skin_mat: StandardMaterial3D

func _vox_skin_material() -> StandardMaterial3D:
	if _vox_skin_mat != null:
		return _vox_skin_mat
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true      # same sRGB caveat as _voxel_material
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_vox_skin_mat = m
	return m


func _color_material(col: Color) -> StandardMaterial3D:
	var key := col.to_html()
	if _colmat_cache.has(key):
		return _colmat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_colmat_cache[key] = m
	return m

# --- node pools -------------------------------------------------------------

## Lay tile billboards flat so a straight-down (true top-down) camera sees the art
## instead of its edge, or stand them upright again (FIXED_Y) for the angled views.
## Applies to sprites already on screen and, via _take_sprite, to any built later.
## Flames, glyph labels and fence quads are separate nodes and stay as they are —
## only _take_sprite billboards join the "tile_sprite" group. (Fences render as
## upright quads, so they read edge-on from directly overhead; a minor v1 limit.)
func set_top_down(on: bool) -> void:
	if on == _top_down:
		return
	_top_down = on
	var mode := BaseMaterial3D.BILLBOARD_ENABLED if on else BaseMaterial3D.BILLBOARD_FIXED_Y
	for n in get_tree().get_nodes_in_group("tile_sprite"):
		if is_instance_valid(n):
			(n as Sprite3D).billboard = mode
			# a glow bloom child mirrors its sprite's billboard mode live
			for c in n.get_children():
				var mi := c as MeshInstance3D
				if mi != null and mi.material_override is ShaderMaterial:
					(mi.material_override as ShaderMaterial).set_shader_parameter(
						"y_lock", 0.0 if on else 1.0)
	_apply_wm_orient()   # world-map cards lie flat in top-down, stand up again otherwise (wins over the loop above)

## How much to enlarge this tile's billboard. Trees only, and only in the 3D user view:
## Qud draws a tree inside one cell because a grid has nowhere else to put it, and at 1x a
## 3D tree reads as a shrub beside a wall that is a whole cell tall. Gated OUT of 1:1 (its
## pixels are parity-measured against Qud), flat-2D (the tile grid) and the world map.
## Matching on "tree" covers the whole set — fattree1-3, talltree1-2, starappletree
## (Daniel's strapple), tree_bulbs, tree_crystal, plastic_tree — and nothing else.
## _seat reads s.pixel_size, so a scaled tree still stands ON the ground rather than
## sinking half its trunk.
const TREE_SCALE := 2.0

func _tree_scale(tile: String) -> float:
	if _one_to_one or _flat_2d or _world_map:
		return 1.0
	if not tile.to_lower().contains("tree"):
		return 1.0
	return TREE_SCALE if Settings.qol_on("bigtrees") else 1.0


func _take_sprite() -> Sprite3D:
	var s: Sprite3D
	if _bank == null and _sprite_pool.size() > 0:
		s = _sprite_pool.pop_back()
	else:
		s = Sprite3D.new()
		s.pixel_size = PIXEL_SIZE
		s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		s.shaded = false
		s.transparent = true
		s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		s.add_to_group("tile_sprite")   # so set_top_down() can find every tile billboard
		_spawn_parent().add_child(s)
	# reset per take — fence panels and submerged actors override these, normal
	# sprites need the defaults back. In top-down the tile faces up (full billboard).
	for c in s.get_children():
		c.queue_free()          # a glow bloom from the sprite's previous user
	s.pixel_size = PIXEL_SIZE   # a TREE's 2x scale must not ride the pool into a rock
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED if _top_down else BaseMaterial3D.BILLBOARD_FIXED_Y
	s.rotation = Vector3.ZERO
	s.region_enabled = false
	s.flip_h = false
	s.flip_v = false
	s.no_depth_test = false   # only the world-map player overrides these (draw-on-top)
	s.render_priority = 0
	return s

func _take_floor() -> MeshInstance3D:
	if _bank == null and _floor_pool.size() > 0: return _floor_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _plane
	_spawn_parent().add_child(mi)
	return mi

## Queue a floor quad (its full transform) under its material for this build's batch.
func _floor_batch_add(mat: Material, xform: Transform3D) -> void:
	if not _floor_batch.has(mat):
		_floor_batch[mat] = []
	_floor_batch[mat].append(xform)

## Emit the queued floors as one MultiMesh per material into the current bank, then clear.
## Called at the end of each static/neighbour build (while _bank is still set).
# --- 1:1 animator ------------------------------------------------------------------
## Register the placed winner's animation programs (called from the 1:1 winner path,
## visible+lit cells only). Overlays are individual quads over the batched steady base.
## USER-MODE tile animation. The 1:1 animator below drives OVERLAY QUADS laid flat over
## a tile, which means nothing to a 3D billboard — and it is called only under full_1to1,
## so in the user view NOTHING animated at all. Daniel, on Joppa's millstone: "in Qud the
## millstone is a multi-frame animation. Can we capture all the frames and animate the
## sprite in Raves?" A billboard wants the simpler thing: swap the Sprite3D's own texture
## on Qud's schedule.
##
## The wire already carries everything needed — the mod ships "len|f=tile;colour;detail|…"
## with the thresholds pre-scaled to a plain 60fps clock and the part's condition ladder
## already evaluated, and it calls TileExporter.Ensure on every frame tile, so the art is
## on disk. Millstone: "176|0=;;|59=Items/sw_millstone_2.bmp;;|118=Items/sw_millstone_3.bmp;;"
## — three frames of a 300-tick cycle at SpeedMultiplier 1.7, about 0.98s each.
##
## COLOUR-only schedules are skipped: that is the torch flicker, and user mode already
## gives torches particle fire, so modulating the sprite would fight the per-cell light.
## The sprite keeps the BASE tile's region_rect, so a frame whose opaque band differs
## swaps art without the billboard jumping on its seat.
func _register_sprite_anim(obj: Dictionary, s: Sprite3D, tile: String, base_tex: Texture2D) -> void:
	# STATIC pass only. The dynamic pass re-places creatures every turn, so registering
	# from there both churns the registry and points it at pooled sprites that get reused
	# under it. Static scenery — millstone, water wheel, box grill — is what has a
	# multi-frame tile schedule worth driving.
	if not _live_build:
		return
	var spec := String(obj.get("animSched", ""))
	if spec == "":
		return
	var parts := spec.split("|")
	if parts.size() < 3:
		return
	var alen := maxi(int(parts[0]), 1)
	var sched: Array = []
	var any_tile := false
	for i in range(1, parts.size()):
		var kv := parts[i].split("=")
		if kv.size() != 2:
			continue
		var axes := String(kv[1]).split(";")
		var ftile := String(axes[0]) if axes.size() > 0 else ""
		var tex: Texture2D = base_tex
		if ftile != "" and ftile != tile:
			var ft := _colored_tex_rgb(ftile, _obj_main(obj), _obj_detail(obj),
				"animspr~" + ftile + "~" + _color_key(obj), _fill_for(ftile, Fill.INTERIOR))
			if ft != null:
				tex = ft
				any_tile = true
		sched.append({"f": int(kv[0]), "tex": tex})
	if any_tile and sched.size() > 1:
		_anim_sprites.append({"sprite": s, "len": alen, "sched": sched})


func _register_anim(win: Dictionary, cx: int, cy: int) -> void:
	var tile := String(win.get("tile", ""))
	if tile == "":
		return
	var y_over := FLOOR_Y + float(win.get("layer", 0)) * LAYER_LIFT + LAYER_LIFT * 0.5 + _dyn_lift_1to1
	var flip := bool(win.get("hflip", false))
	# Smear flash: liquid-covered objects flash the covering liquid's colour 9 frames in 60
	# (convalessence '&C', protean gunk '&c' — RenderSmearPrimary; water's smear is a no-op).
	var sm := String(win.get("animSmear", ""))
	if sm != "":
		var fc := _qud_color("&" + sm)
		var tex := _colored_tex_rgb(tile, fc, fc, "anim~s" + sm + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
		if tex != null:
			_anim_items.append({"kind": "smear", "node": _overlay_quad(tex, cx, cy, y_over, flip)})
	# Sludge programs (SoupSludge.Render): hero = 240ms component-colour / 240ms base blink;
	# multi-liquid non-hero = 240ms-per-colour cycle (mono non-hero is steady — wired, no overlay).
	var cyc := String(win.get("animCycle", ""))
	if cyc != "":
		var letters := cyc.split(",")
		if bool(win.get("animHero", false)):
			var fch := _qud_color("&" + String(letters[0]))
			var texh := _colored_tex_rgb(tile, fch, _obj_detail(win), "anim~h" + String(letters[0]) + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
			if texh != null:
				_anim_items.append({"kind": "blink", "node": _overlay_quad(texh, cx, cy, y_over, flip)})
		elif letters.size() > 1:
			var nodes: Array = []
			for L in letters:
				var fcl := _qud_color("&" + String(L))
				var texl := _colored_tex_rgb(tile, fcl, _obj_detail(win), "anim~c" + String(L) + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
				if texl != null:
					nodes.append(_overlay_quad(texl, cx, cy, y_over, flip))
			if not nodes.is_empty():
				_anim_items.append({"kind": "cycle", "nodes": nodes})
	# AnimatedMaterialGeneric & subclasses (data-driven cycler — Phasic Screw's
	# helix, the powered-device blink family, the Force Projector detail cycle):
	# the wire ships ONE merged schedule "len|f=tile;color;detail|..." with
	# thresholds pre-scaled to a plain 60fps clock and the part's condition
	# ladder already evaluated at export. Empty fields = the object's base
	# art/colours. A fully-empty entry is the BASE state: no overlay at all.
	# A REPLACEMENT tile is built opaque (Fill.ALL): Qud swaps the whole tile,
	# so the frame must mask the steady base underneath (the power-cut icon
	# floats on the bare field, not on the computer's art).
	var af := String(win.get("animSched", ""))
	if af != "":
		var fparts := af.split("|")
		var alen := maxi(int(fparts[0]), 1)
		var sched: Array = []
		for fi in range(1, fparts.size()):
			var kv := fparts[fi].split("=")
			if kv.size() != 2:
				continue
			var axes := String(kv[1]).split(";")
			if axes.size() != 3:
				continue
			var node: MeshInstance3D = null
			# A COLOUR-ONLY FRAME MUST NOT BECOME A SECOND BILLBOARD. With no tile of its own a
			# frame re-tints the object's OWN tile, which in 1:1 lands exactly over the flat cell
			# it modifies -- that IS the cell, recoloured. Stood up in user mode it is a whole
			# extra copy of the creature hanging beside itself, flashing. Daniel, on his burning
			# character: "Raves is displaying a second image of the player. The second image has
			# the flashing light. Let's get rid of both." In user mode the fire itself carries
			# what the flash was for, so only frames that genuinely SWAP A TILE (the dawnglider's
			# flying icon) earn an overlay.
			var swaps_tile: bool = axes[0] != "" and String(axes[0]) != tile
			var want_node: bool = (axes[0] != "" or axes[1] != "" or axes[2] != "") \
					if _one_to_one else swaps_tile
			if want_node:
				var stile := String(axes[0]) if axes[0] != "" else tile
				var smain := _qud_color(String(axes[1])) if axes[1] != "" else _obj_main(win)
				var sdet: Color = _qud_color("&" + String(axes[2])) if axes[2] != "" else _obj_detail(win)
				# An entry colour's ^X is that FRAME's cell background (Asleep
				# floods ^c behind the art) — swap _wall_bg for this build, and
				# force the fill on: with Fill.NONE the background never paints
				# and a bg-only flash renders identical to the base (measured:
				# the sleeping chromeling stayed static).
				var kept_bg := _wall_bg
				if axes[1] != "":
					_wall_bg = _parse_bg(String(axes[1]))
				var sfill: int = Fill.ALL if ((axes[0] != "" and String(axes[0]) != tile) or _wall_bg != "") else Fill.NONE
				var ftex := _colored_tex_rgb(stile, smain, sdet,
					"anim~S" + String(kv[1]) + "~" + _color_key(win), _fill_for(stile, sfill))
				_wall_bg = kept_bg
				if ftex != null:
					node = _overlay_quad(ftex, cx, cy, y_over, flip)
			sched.append({"f": int(kv[0]), "node": node})
		if sched.size() > 1:
			_anim_items.append({"kind": "frames", "len": alen, "sched": sched})
	# Wormhole shimmer: Qud re-rolls a RANDOM colour+glyph combo on every
	# repaint (Wormhole.Render — no cycle to schedule). The wire ships the
	# combo tables "period|glyphcodes|colors"; prebuild every combo's Text
	# tile (each on its own ^X background) and re-roll on our own cadence.
	var ash := String(win.get("animShimmer", ""))
	if ash != "":
		var sparts := ash.split("|")
		if sparts.size() == 3:
			var speriod := maxi(int(sparts[0]), 6)
			var snodes: Array = []
			var saved_bg := _wall_bg
			for code in sparts[1].split(","):
				for scol in sparts[2].split(","):
					var stile := "Text/%d.bmp" % int(code)
					_wall_bg = _parse_bg(String(scol))
					var smain := _qud_color(String(scol))
					var stex := _colored_tex_rgb(stile, smain, smain,
						"anim~W" + String(code) + String(scol), Fill.NONE)
					if stex != null:
						snodes.append(_overlay_quad(stex, cx, cy, y_over, false))
			_wall_bg = saved_bg
			if snodes.size() > 1:
				_anim_items.append({"kind": "shimmer", "nodes": snodes,
					"period": speriod, "last": -1, "cur": 0})
	# PrefabImposter effects: Unity particle prefabs the wire can only NAME.
	# TreeGlow (Chavvah chimes) is a full-cell moonlight wash the art draws
	# OVER — colour sampled off native captures (state crops, corner mean
	# ~(197,181,212), breathing ±7). The wash quad sits UNDER the sprite and
	# its transparency pulses (continuous states, like the measured 11).
	var imp := String(win.get("imposter", ""))
	if imp == "TreeGlow":
		var wcol := Color8(197, 181, 212)
		var wnode := _overlay_quad(null, cx, cy, y_over - LAYER_LIFT * 0.5, false, wcol)
		# Drifting MOTES give the wash the particle system's spatial churn: a
		# brightness pulse alone tops out at ~4 distinguishable states (merge
		# radius eats a 1-D range), while Qud's glow reads continuous because
		# the sparkle POSITIONS move. Three small bright quads, orbits driven
		# by incommensurate frequencies.
		var motes: Array = []
		for mi2 in 3:
			var mq := _overlay_quad(null, cx, cy, y_over - LAYER_LIFT * 0.4, false,
				Color8(222, 207, 236))
			mq.scale = Vector3(0.22, 1, 0.22)
			motes.append(mq)
		_anim_items.append({"kind": "glowpulse", "node": wnode, "base": wcol,
			"motes": motes, "cx": cx, "cy": cy})
	# HologramMaterial weighted shimmer: "period|col~det~weight|..." — the
	# part's clock RANDOM-WALKS (FrameOffset += Random(0,20) every render),
	# so its palette is a distribution, not a cycle: mostly the steady mode
	# (which the wire's base colours already carry), with brief flashes of
	# the early entries (Eater Sign's &W blink). Re-roll by weight.
	var ah := String(win.get("animHolo", ""))
	if ah != "":
		var hparts := ah.split("|")
		if hparts.size() > 2:
			var hperiod := maxi(int(hparts[0]), 6)
			var hnodes: Array = []
			var hweights: Array = []
			var htotal := 0
			for hi in range(1, hparts.size()):
				var hkv := hparts[hi].split("~")
				if hkv.size() != 3:
					continue
				var hmain := _qud_color(String(hkv[0]))
				var hdet: Color = _qud_color("&" + String(hkv[1])) if hkv[1] != "" else _obj_detail(win)
				var htex := _colored_tex_rgb(tile, hmain, hdet,
					"anim~H" + String(hkv[0]) + String(hkv[1]) + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
				if htex != null:
					hnodes.append(_overlay_quad(htex, cx, cy, y_over, flip))
					var hwt := maxi(int(hkv[2]), 1)
					hweights.append(hwt)
					htotal += hwt
			if hnodes.size() > 1:
				_anim_items.append({"kind": "holo", "nodes": hnodes, "weights": hweights,
					"total": htotal, "period": hperiod, "last": -1, "cur": 0})
	# Gas swirl (Qud's Gas.Render): a 4-tile cycle — Tiles2/gas_0..3.png at 15 frames
	# (250ms) per step, in the gas type's colour. Always exactly one frame visible, so
	# the overlay fully replaces the steady base (which shows frame 0).
	var gcol := String(win.get("animGas", ""))
	if gcol != "":
		var gc := _qud_color(gcol)
		var gnodes: Array = []
		for gi in 4:
			var gtile := "Tiles2/gas_%d.png" % gi
			var gtex := _colored_tex_rgb(gtile, gc, gc, "anim~g" + gcol + "~" + str(gi), _fill_for(gtile, Fill.NONE))
			if gtex != null:
				gnodes.append(_overlay_quad(gtex, cx, cy, y_over, false))
		if not gnodes.is_empty():
			# per-cloud random phase, like Qud's per-gas FrameOffset (clouds don't step in unison)
			_anim_items.append({"kind": "gas", "nodes": gnodes, "off": randi() % 60})
	# Fire (AnimatedMaterialFire — the wire's onFire flag is exactly that part): Qud tints
	# the flameless tile's fg through &R / &W / &r / &W in 15-frame windows with a RANDOM-
	# WALKING phase (FrameOffset += 1..5 per frame — chaotic flicker, not a pulse), and its
	# particle layer dances ~20 pure-red pixels above the fire. Overlays: 3 tint variants +
	# 3 tiny rising ember quads.
	if bool(win.get("onFire", false)):
		var fnodes: Array = []
		for L in ["R", "W", "r"]:
			var fcf := _qud_color("&" + String(L))
			var ftex := _colored_tex_rgb(tile, fcf, _obj_detail(win), "anim~f" + String(L) + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
			if ftex != null:
				fnodes.append(_overlay_quad(ftex, cx, cy, y_over, flip))
		if fnodes.size() == 3:
			# Three particle layers (Daniel's spec): RED embers with a raised floor, YELLOW
			# tongues at the wood base expiring at half the red column, and GREY smoke that
			# alphas out while rising two tiles. +dz = screen-south (toward the wood).
			var embers: Array = []
			for _e in 3:
				var eq := _overlay_quad(null, cx, cy, y_over + LAYER_LIFT * 0.25, false, Color(1, 0, 0))
				eq.scale = Vector3(0.10, 1.0, 0.14)
				eq.visible = true
				embers.append({"node": eq, "t": "red", "dx": randf_range(-0.18, 0.18), "dz": randf_range(0.10, 0.28)})
			for _e in 2:
				var yq := _overlay_quad(null, cx, cy, y_over + LAYER_LIFT * 0.2, false, Color(1.0, 0.85, 0.1))
				yq.scale = Vector3(0.09, 1.0, 0.12)
				yq.visible = true
				embers.append({"node": yq, "t": "yellow", "dx": randf_range(-0.16, 0.16), "dz": randf_range(0.10, 0.28)})
			for _e in 3:
				var sq := _overlay_quad(null, cx, cy, y_over + LAYER_LIFT * 0.3, false, Color(0.45, 0.45, 0.45, 0.55))
				var smat := sq.material_override as StandardMaterial3D
				if smat != null:
					smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				sq.scale = Vector3(0.16, 1.0, 0.18)
				sq.visible = true
				embers.append({"node": sq, "t": "smoke", "dx": randf_range(-0.2, 0.2), "dz": randf_range(-0.05, 0.10)})
			_anim_items.append({"kind": "fire", "nodes": fnodes, "off": randi() % 60,
				"embers": embers, "cx": cx, "cy": cy, "lfoPhase": randf() * TAU})
	# Engulfed (Engulfed.Render): the swallowed winner shows its ENGULFER's tile+colours
	# for frames 0-30 of every 60 — the half-second predator/prey alternation (the dacca
	# that ate a prism perch). One overlay, visible the first half of each second.
	var etile := String(win.get("engTile", ""))
	if etile != "":
		var etex := _colored_tex_rgb(etile, _qud_color(String(win.get("engColor", ""))),
			_qud_color(String(win.get("engDetail", ""))),
			"anim~e" + String(win.get("engColor", "")) + "~" + String(win.get("engDetail", "")) + "~" + etile,
			_fill_for(etile, Fill.NONE))
		if etex != null:
			_anim_items.append({"kind": "engulf", "node": _overlay_quad(etex, cx, cy, y_over, false)})
	# ConcealedHologramMaterial (Moon Stair "virtual" assets): normal from afar; when the
	# PLAYER IS ADJACENT it flickers hologram tints on a 200-frame wheel — 12 frames of
	# C/c -> b/C -> c/b windows, plus a rare white blip (approximates Qud's glyph sputter).
	if bool(win.get("animCHolo", false)):
		var cnodes: Array = []
		for pair in [["C", "c"], ["b", "C"], ["c", "b"], ["Y", "y"]]:
			var cfg := _qud_color("&" + String(pair[0]))
			var cdt := _qud_color("&" + String(pair[1]))
			var ctex := _colored_tex_rgb(tile, cfg, cdt, "anim~ch" + String(pair[0]) + String(pair[1]) + "~" + _color_key(win), _fill_for(tile, Fill.NONE))
			if ctex != null:
				cnodes.append(_overlay_quad(ctex, cx, cy, y_over, flip))
		if cnodes.size() == 4:
			_anim_items.append({"kind": "cholo", "nodes": cnodes, "off": randi() % 200,
				"cx": cx, "cy": cy})
	# Pool sparkle candidate: a liquid winning its cell rolls Qud's 1/600 flash — WHITE for
	# water-family pools ('&Y'), CYAN for protean gunk ('&c', its own program: near-invisible
	# on the cyan soup, exactly Qud's look — the soup does NOT glitter like water).
	if bool(win.get("liquid", false)):
		var spark := "c" if tile.contains("Gunk") else "Y"
		_anim_pool_cells.append({"cx": cx, "cy": cy, "tile": tile, "key": _color_key(win), "y": y_over, "spark": spark})

## One unbatched cell-sized quad for the animator (hidden until its program shows it).
## tex null + col set = a flat colour fill (the target highlight).
func _overlay_quad(tex: Texture2D, cx: int, cy: int, y: float, flip := false, col := Color(0, 0, 0, 0)) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _plane
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	elif col.a > 0.0:
		m.albedo_color = col
	# STAND IT UP IN USER MODE. 1:1 is a flat top-down stage where a cell IS a quad on the
	# floor, so an overlay lying in the ground plane covers exactly the art it modifies. User
	# mode stands its art up as billboards, and the same floor quad would lie in front of a
	# creature's feet flashing at the dirt. Same mesh cell-for-cell, turned to face the camera
	# and lifted to the billboard's own height, so a flash covers the thing it belongs to.
	if not _one_to_one:
		if _plane_up == null:
			_plane_up = QuadMesh.new()
			_plane_up.size = Vector2(1, 1)
		mi.mesh = _plane_up
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
		mi.material_override = m
		mi.position = Vector3(cx, FLOOR_Y + OVERLAY_STAND_Y, cy)
		if flip:
			mi.scale = Vector3(-1, 1, 1)
		mi.visible = false
		_dynamic_root.add_child(mi)
		return mi
	mi.material_override = m
	mi.position = Vector3(cx, y, cy)
	if flip:
		mi.scale = Vector3(-1, 1, 1)
	mi.visible = false
	_dynamic_root.add_child(mi)
	return mi

## Per-frame driver (from _process, 1:1 only). qf emulates Qud's CurrentFrame (60/s wrap);
## phases can't sync with Qud's counter, but every duty cycle and period matches.
func _animate_1to1() -> void:
	var ms := Time.get_ticks_msec()
	# STATIC multi-frame billboards, in BOTH modes. Same step rule and same 60fps clock
	# as the "frames" kind below; the difference is that the frame IS the sprite's own
	# texture, not an overlay quad laid over a flat tile.
	for a in _anim_sprites:
		var spin = a.get("spin", null)
		if spin != null:
			var smi := spin as Node3D
			if is_instance_valid(smi):
				# turn about the shaft's own axis; local +x is the run, so the spin is
				# applied INSIDE the yaw that put the beam on its cell axis
				var ang: float = TAU * fposmod(ms / 1000.0 / float(a["period"]), 1.0)
				smi.basis = (a["base"] as Basis) * Basis(Vector3.RIGHT, ang)
			continue
		var anodes = a.get("nodes", null)
		if anodes != null:
			# one whole MESH per frame (the voxel axle): step visibility, not texture
			var nf := int(ms * 0.06) % int(a["len"])
			var nsched: Array = a["sched"]
			var nact := 0
			for si in nsched.size():
				if nf >= int(nsched[si]["f"]):
					nact = si
			for si in (anodes as Array).size():
				var nn = (anodes as Array)[si]
				if is_instance_valid(nn):
					nn.visible = si == nact
			continue
		var sp: Sprite3D = a.get("sprite", null) as Sprite3D
		var fmat: StandardMaterial3D = a.get("mat", null) as StandardMaterial3D
		if sp != null and not is_instance_valid(sp):
			continue
		if sp == null and fmat == null:
			continue
		var tf := int(ms * 0.06) % int(a["len"])
		var tsched: Array = a["sched"]
		var tact := 0
		for si in tsched.size():
			if tf >= int(tsched[si]["f"]):
				tact = si
		# A prism face is a QUARTER TURN around the shaft from its neighbour, so it shows
		# the cycle a step further on — that phase offset is what makes four static quads
		# read as one turning axle (see _fence_half_prism).
		tact = (tact + int(a.get("phase", 0))) % tsched.size()
		var want: Texture2D = tsched[tact]["tex"]
		if sp != null:
			if sp.texture != want:
				sp.texture = want
		elif fmat.albedo_texture != want:
			fmat.albedo_texture = want
	var qf := int(ms * 0.06) % 60
	if _anim_tnode != null and is_instance_valid(_anim_tnode):
		_anim_tnode.visible = (qf < 15) or (qf >= 30 and qf < 45)   # RenderTarget's blink windows
	for it in _anim_items:
		var kind := String(it["kind"])
		if kind == "smear":
			var n := it["node"] as MeshInstance3D
			if is_instance_valid(n):
				n.visible = qf > 5 and qf < 15
		elif kind == "blink":
			var n2 := it["node"] as MeshInstance3D
			if is_instance_valid(n2):
				n2.visible = (ms % 480) < 240
		elif kind == "cycle":
			var nodes: Array = it["nodes"]
			if not nodes.is_empty():
				var idx := int(ms / 240.0) % nodes.size()
				for i in nodes.size():
					var nn := nodes[i] as MeshInstance3D
					if is_instance_valid(nn):
						nn.visible = i == idx
		elif kind == "frames":
			# AnimatedMaterialGeneric: the ACTIVE entry is the last whose
			# threshold <= the clock (Qud's own step rule). Before the first
			# threshold, and on base-state entries (null node), every overlay
			# hides and the steady base shows through.
			var ff := int(ms * 0.06) % int(it["len"])
			var sched: Array = it["sched"]
			var active := -1
			for si in sched.size():
				if ff >= int(sched[si]["f"]):
					active = si
			for si in sched.size():
				var fn := sched[si]["node"] as MeshInstance3D
				if fn != null and is_instance_valid(fn):
					fn.visible = si == active
		elif kind == "glowpulse":
			# TreeGlow breathing: two incommensurate sines so the pulse never
			# phase-locks with the capture cadence (measured amplitude ~±3%).
			# Overlay quads spawn INVISIBLE (the toggle programs own that);
			# a fading program must show its node itself.
			var gn := it["node"] as MeshInstance3D
			if is_instance_valid(gn):
				gn.visible = true
				# Pulse the wash's BRIGHTNESS, not its alpha: transparency fades
				# compressed to ±2/channel on screen and dimmed the field off the
				# measured colour. Albedo swing ±~4% = the captures' ±7/channel.
				# Three incommensurate sines (fastest sub-capture-period) so
				# consecutive samples decorrelate like the particle system's.
				var osc := 1.0 + 0.016 * sin(ms * 0.0013) + 0.014 * sin(ms * 0.0071) + 0.012 * sin(ms * 0.0173)
				var wb: Color = it["base"]
				var wm := gn.material_override as StandardMaterial3D
				if wm != null:
					wm.albedo_color = Color(wb.r * osc, wb.g * osc, wb.b * osc)
				var motes: Array = it["motes"]
				for mi3 in motes.size():
					var mq := motes[mi3] as MeshInstance3D
					if is_instance_valid(mq):
						mq.visible = true
						var ph := float(mi3) * 2.1
						mq.position = Vector3(
							float(it["cx"]) + 0.3 * sin(ms * 0.0009 + ph) + 0.08 * sin(ms * 0.0047 + ph),
							mq.position.y,
							float(it["cy"]) + 0.34 * cos(ms * 0.0011 + ph * 1.7) + 0.08 * cos(ms * 0.0053 + ph))
		elif kind == "shimmer":
			# Wormhole: pick a RANDOM combo each period (repeats allowed —
			# Qud's own re-roll can land on the same face twice).
			var sstep := int(ms * 0.06 / float(it["period"]))
			if sstep != int(it["last"]):
				it["last"] = sstep
				it["cur"] = randi() % (it["nodes"] as Array).size()
			var snodes: Array = it["nodes"]
			for si in snodes.size():
				var sn := snodes[si] as MeshInstance3D
				if is_instance_valid(sn):
					sn.visible = si == int(it["cur"])
		elif kind == "holo":
			# HologramMaterial: weighted re-roll each period (the steady mode
			# dominates; flashes carry their measured share of the 200-space).
			var hstep := int(ms * 0.06 / float(it["period"]))
			if hstep != int(it["last"]):
				it["last"] = hstep
				var hr := randi() % int(it["total"])
				var hws: Array = it["weights"]
				var hacc := 0
				for wi in hws.size():
					hacc += int(hws[wi])
					if hr < hacc:
						it["cur"] = wi
						break
			var hn: Array = it["nodes"]
			for ni in hn.size():
				var hnn := hn[ni] as MeshInstance3D
				if is_instance_valid(hnn):
					hnn.visible = ni == int(it["cur"])
		elif kind == "cholo":
			var chn: Array = it["nodes"]
			if chn.size() == 4:
				# proximity gate: the glitch only shows with the player ADJACENT (Chebyshev <= 1)
				var adj: bool = maxi(absi(int(it["cx"]) - _player_cell.x), absi(int(it["cy"]) - _player_cell.y)) <= 1
				var cidx := -1
				if adj:
					it["off"] = int(it.get("off", 0)) + (randi() % 21)   # Qud: FrameOffset += 0..20/frame
					var w200 := (qf + int(it["off"])) % 200
					if w200 < 4: cidx = 0        # &C/c
					elif w200 < 8: cidx = 1      # &b/C
					elif w200 < 12: cidx = 2     # &c/b
					elif randi() % 400 == 0: cidx = 3   # the rare &Y/y blip (glyph-sputter stand-in)
				for i in chn.size():
					var cn := chn[i] as MeshInstance3D
					if is_instance_valid(cn):
						cn.visible = i == cidx
		elif kind == "engulf":
			var en2 := it["node"] as MeshInstance3D
			if is_instance_valid(en2):
				en2.visible = qf <= 30   # Engulfed.Render: engulfer shown frames 0-30 of 60
		elif kind == "gas":
			var gn: Array = it["nodes"]
			if not gn.is_empty():
				var gidx := ((qf + int(it.get("off", 0))) / 15) % gn.size()   # Gas.Render: 250ms/tile, per-cloud phase
				for i in gn.size():
					var g := gn[i] as MeshInstance3D
					if is_instance_valid(g):
						g.visible = i == gidx
		elif kind == "fire":
			var fn: Array = it["nodes"]
			if fn.size() == 3:
				# Qud's random-walk phase: FrameOffset += 1..5 EVERY frame
				it["off"] = int(it.get("off", 0)) + 1 + (randi() % 5)
				var fw: int = ((qf + int(it["off"])) % 60) / 15
				var fidx: int = [0, 1, 2, 1][fw]   # windows: &R, &W, &r, &W
				for i in fn.size():
					var f := fn[i] as MeshInstance3D
					if is_instance_valid(f):
						f.visible = i == fidx
				# Layered fire physics: red floor raised (+0.28..+0.10 -> top +0.02); yellow
				# tongues spawn at the wood base (+0.45..+0.32) and expire at half the red
				# column (+0.24); smoke rises TWO tiles (to dz -1.9) fading alpha to zero.
				var fcx := int(it.get("cx", 0))
				var fcy := int(it.get("cy", 0))
				for e in it.get("embers", []):
					var en := e["node"] as MeshInstance3D
					if not is_instance_valid(en):
						continue
					var et := String(e.get("t", "red"))
					if et == "red":
						e["dz"] = float(e["dz"]) - (0.015 + randf() * 0.01)   # half speed
						e["dx"] = clampf(float(e["dx"]) + randf_range(-0.03, 0.03), -0.22, 0.22)
						if float(e["dz"]) < 0.02:
							e["dz"] = randf_range(0.10, 0.28)
							e["dx"] = randf_range(-0.18, 0.18)
					elif et == "yellow":
						# same band + ceiling as the red now, at half speed
						e["dz"] = float(e["dz"]) - (0.0125 + randf() * 0.01)
						e["dx"] = clampf(float(e["dx"]) + randf_range(-0.025, 0.025), -0.2, 0.2)
						if float(e["dz"]) < 0.02:
							e["dz"] = randf_range(0.10, 0.28)
							e["dx"] = randf_range(-0.16, 0.16)
					else:
						e["dz"] = float(e["dz"]) - (0.02 + randf() * 0.015)
						e["dx"] = clampf(float(e["dx"]) + randf_range(-0.02, 0.02), -0.35, 0.35)
						var prog := clampf((0.10 - float(e["dz"])) / 2.0, 0.0, 1.0)
						var sm := en.material_override as StandardMaterial3D
						if sm != null:
							sm.albedo_color = Color(0.45, 0.45, 0.45, 0.55 * (1.0 - prog))
						if float(e["dz"]) < -1.9:
							e["dz"] = randf_range(-0.05, 0.10)
							# LFO on the spawn x: the smoke column sways slowly (~4.2s period,
							# amplitude 0.22 cells, per-fire phase) instead of spawning centred.
							var lfo := sin(float(ms) * 0.0015 + float(it.get("lfoPhase", 0.0))) * 0.22
							e["dx"] = lfo + randf_range(-0.06, 0.06)
					en.position.x = fcx + float(e["dx"])
					en.position.z = fcy + float(e["dz"])
	# Pool sparkles: expected fires/frame = cells/600 (Qud's per-cell 1/600 roll), one-frame white.
	for s in _sparkle_lit:
		if is_instance_valid(s):
			(s as MeshInstance3D).visible = false
	_sparkle_lit.clear()
	var n3 := _anim_pool_cells.size()
	if n3 > 0:
		var expect := n3 / 600.0
		var fires := int(expect) + (1 if randf() < expect - floorf(expect) else 0)
		fires = mini(fires, 4)
		for _i in fires:
			var pc: Dictionary = _anim_pool_cells[randi() % n3]
			var tw := String(pc["tile"])
			var sl := String(pc.get("spark", "Y"))
			var fcw := _qud_color("&" + sl)
			var texw := _colored_tex_rgb(tw, fcw, fcw, "anim~" + sl + "~" + String(pc["key"]), _fill_for(tw, Fill.NONE))
			if texw == null:
				continue
			var q := _take_sparkle()
			(q.material_override as StandardMaterial3D).albedo_texture = texw
			(q.material_override as StandardMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			(q.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			q.position = Vector3(int(pc["cx"]), float(pc["y"]) + LAYER_LIFT * 0.25, int(pc["cy"]))
			q.visible = true
			_sparkle_lit.append(q)

func _take_sparkle() -> MeshInstance3D:
	for s in _sparkle_pool:
		if is_instance_valid(s) and not (s as MeshInstance3D).visible:
			return s
	var q := _overlay_quad(null, 0, 0, 0.0)
	_sparkle_pool.append(q)
	return q

## `into` overrides where the MultiMeshes land. It matters for anything rebuilt EVERY TURN: the
## default _spawn_parent() is `self`, which is never cleared, so a per-turn caller that took the
## default would add its quads again on every step and never drop the last lot. The surround band
## is exactly that caller — 904 quads a turn, accumulating.
func _flush_floor_batch(into: Node = null) -> void:
	for mat in _floor_batch:
		var xforms: Array = _floor_batch[mat]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _plane
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		(into if into != null else _spawn_parent()).add_child(mmi)
	_floor_batch.clear()

## The Sprite3D billboard mode a world-map card should use right now. Top-down wins: a straight-
## down camera sees an upright card edge-on (invisible), so lay them flat to face up (full
## billboard). Otherwise it's the EW toggle — DISABLED (a fixed panel facing N/S) or FIXED_Y
## (upright, spinning around Y to face the camera).
func _wm_sprite_billboard() -> int:
	if _top_down:
		return BaseMaterial3D.BILLBOARD_ENABLED
	return BaseMaterial3D.BILLBOARD_DISABLED if _wm_face_ns else BaseMaterial3D.BILLBOARD_FIXED_Y

func _wm_orient_name() -> String:
	if _top_down:
		return "flat (top-down)"
	return "EW facing N/S" if _wm_face_ns else "follows camera"

## Point one world-map card sprite at the current orientation. DISABLED faces +Z (an EW panel
## facing N/S); the billboard modes ignore rotation, so zero it either way.
func _apply_wm_orient_to(s: Sprite3D) -> void:
	s.billboard = _wm_sprite_billboard()
	s.rotation = Vector3.ZERO

## Re-orient every world-map card (called when top-down or the EW toggle changes). Instant — no
## rebuild. set_top_down's own tile_sprite loop runs first, so this re-asserts the wm-specific mode.
func _apply_wm_orient() -> void:
	for n in get_tree().get_nodes_in_group("wm_tile"):
		if is_instance_valid(n):
			_apply_wm_orient_to(n as Sprite3D)

## Toggle every world-map card between following the camera and standing as a fixed EW panel
## facing N/S. Re-orients the live sprites in place — instant, no rebuild.
func set_wm_face_ns(on: bool) -> void:
	if on == _wm_face_ns:
		return
	_wm_face_ns = on
	_apply_wm_orient()   # no-op visually while top-down (that mode wins), applied on exit

func _take_label() -> Label3D:
	if _bank == null and _label_pool.size() > 0: return _label_pool.pop_back()
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = 0.02
	l.font_size = 64
	# Qud's map glyphs: Source Code Pro, no outline (checker: the default
	# Label3D outline read as a black ring Qud never draws).
	l.font = load("res://fonts/SourceCodePro-Regular.ttf")
	l.outline_size = 0
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_spawn_parent().add_child(l)
	return l

# Qud RenderStrings are CODEPAGE-437 codes carried as raw chars (blueprint
# RenderString="228" means Σ, the sigil the shrine draws; read as Unicode it's
# "ä"). Map through the classic table; codes past 255 pass through untouched.
const CP437 := " ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼ !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~⌂ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "

func _cp437(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		out += CP437[c] if c < 256 else s[i]
	return out

# FALLBACK ONLY — hand-estimated, and measurably wrong: Qud's 'k' is #0f3b3a
# (a dark teal, the colour of the world itself), NOT the near-black guessed here.
# The mod sends the real table out of ConsoleLib (see _palette); this is used
# only if an older mod build is loaded. Base/Colors.xml names the colours but
# carries no RGB, which is what made the guessing necessary.
const COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),
}

## Foreground/detail for an object. When Qud painted the tile it hands us the
## RESOLVED rgb, which needs no palette lookup and no &X^Y parsing — prefer it.
## Which colour string an object's tile recolours from — Qud's tiles rule (Cell.Render) is
## TileColor over ColorString, EXCEPT a custom render (liquids) writes a COMPOUND back into
## ColorString ('&Y^y&b') that overrides the static TileColor at draw time. A compound is
## recognisable by its second '&'.
func _pick_color_string(obj: Dictionary) -> String:
	var full := String(obj.get("color", ""))
	if full.count("&") >= 2:
		return full
	var c := String(obj.get("tilecolor", ""))
	return c if c != "" else full

## Apply a family's "recolor" rule to one colour code. Returns the code unchanged when no rule
## names it, so this is safe to wrap every colour lookup in.
func _recolor(obj: Dictionary, code: String) -> String:
	if _recolor_overrides.is_empty() or code == "":
		return code
	var m = _recolor_overrides.get(tile_family(String(obj.get("tile", ""))), null)
	if m == null:
		return code
	return String((m as Dictionary).get(code, code))

## An object's (main, detail, cache-key) — ALREADY SWAPPED to Qud's memory pair when this is a zone
## the player is not standing in. Every path that colours a cell's art goes through here, because
## the alternative is remembering to do it at each one: the floors and the billboards build their
## textures SEPARATELY, and fixing only the floors left a departed zone with dark ground and
## full-colour plants standing on it — which is the bug this was meant to fix.
func _art_colors(obj: Dictionary) -> Array:
	if not _remembered_build:
		return [_obj_main(obj), _obj_detail(obj), _color_key(obj)]
	# BOTH ends K — see the ghost texture in _build_zone. _recolor_rgb lerps by the art's
	# luminance, and k is the field colour, so a K->k ghost paints its own brightest pixels the
	# colour of the ground. Qud's memory is a flat glyph colour on a flat field colour.
	return [_qud_color("K"), _qud_color("K"), _color_key(obj) + "~ghost"]

func _obj_main(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	return _qud_color(_recolor(obj, _fg_letter(_pick_color_string(obj))))

func _obj_detail(obj: Dictionary) -> Color:
	var hex := String(obj.get("detailHex", ""))
	if hex != "":
		return Color(hex)
	var d := String(obj.get("detail", "")).strip_edges()
	if d == "":
		# Qud renders the detail-mask pixels in the FG colour when DetailColor is empty
		# (measured on painted-ground flowers: Qud draws the whole sprite fg; the white
		# came from our fallback). Keep the copies in sync: QudTiles.detail_color.
		return _obj_main(obj)
	return _qud_color(_recolor(obj, _fg_letter(d)))

## Cache key for an object's colours — the painted rgb when present, else the
## colour codes. Must distinguish the two, or a painted and an unpainted object
## sharing a tile would collide in the texture cache.
func _color_key(obj: Dictionary) -> String:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return "%s~%s" % [hex, String(obj.get("detailHex", ""))]
	return "%s|%s" % [_pick_color_string(obj), String(obj.get("detail", ""))]

## The FOREGROUND letter of a Qud colour code.
##
## A ColorString is `&FG^BG`. Taking the trailing letter — which this used to do —
## silently returns the BACKGROUND whenever one is present. The player is `&y^k`:
## that read as 'k', the world's own dark teal, so a pale grey figure rendered
## dark-teal-on-dark-teal and only its red detail pixels were visible.
##
## Objects with a TileColor were unaffected (that field has no `^`), which is why
## walls and water looked right and this stayed hidden.
func _fg_letter(code: String) -> String:
	# QUD'S OWN RULE (RenderEvent.GetForegroundColor): the char after the LAST '&' anywhere in
	# the string — '^' sets the background and does NOT stop the search. A liquid's custom
	# render writes compounds like '&Y^y&b': Qud draws that fg 'b' (the blue puddle), and the
	# old first-caret truncation read 'Y' instead. A bare letter code stays itself.
	var c := code.strip_edges()
	var amp := c.rfind("&")
	if amp >= 0:
		return c.substr(amp + 1, 1) if amp + 1 < c.length() else ""
	var caret := c.find("^")
	if caret >= 0:
		c = c.substr(0, caret)
	if c.is_empty():
		return ""
	return c.substr(c.length() - 1, 1)

## The live Qud palette colour for a bare letter (the editor's swatches) — the same
## map sprites recolour with: Qud's wire palette first, COLORS as fallback.
func qud_palette_color(ch: String) -> Color:
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

## A COPY of the tile's image as it displays for this object — the custom art if
## one exists, else the mask recoloured with the object's own colours. The editor
## paints on this (reverting to "Qud art" must show the recoloured render, not the
## raw black/white mask).
func tile_display_image(tile: String, obj: Dictionary) -> Image:
	var tex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj))
	if tex == null:
		return null
	var img := tex.get_image()
	return img.duplicate() if img != null else null

func _qud_color(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return Color.WHITE
	# prefer the palette Qud actually sent; COLORS is only a fallback
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

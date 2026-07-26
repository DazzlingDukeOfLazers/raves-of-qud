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
const SURFACE_Z := 10
const DARK_MAX := 0.94          # deepest per-cell darkening (never pure black — faint memory)
const DARK_FLOOR_Y := 0.07      # darkness quad sits just above the floor tiles
const DARK_ROOF_Y := WALL_H + 0.02   # and just above wall roofs, to dun unlit rock tops
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
enum Fill { NONE, ALL, INTERIOR, SPAN }

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
var _stairdir_overrides := {} # tile family -> "n"/"e"/"s"/"w" (descent the user picked)
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
var _wall_root: Node3D   # one MeshInstance per wall TYPE, rebuilt per snapshot

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
var _placed := {}   # Vector2i -> Array[{idx, kind, y}]

# Torch/fire light. The world uses UNSHADED materials, so a real Godot light
# does nothing. Instead each lit object gets an ADDITIVE warm ground-glow plus a
# small flickering flame — brightening the flat tiles the way an additive decal
# would, and reading correctly in the top-down 2.5D view.
var _light_root: Node3D
var _remembered_root: Node3D    # parent of the frozen per-zone neighbour subtrees
var _static_zones := {}         # zoneId -> Node3D (that zone's frozen static geometry)
var _dynamic_root: Node3D       # the live zone's creatures, rebuilt every step
var _live_static_id := ""       # which zone's static is currently built as "live"
var _bank: Node3D = null        # non-null while building a zone's geometry INTO it
var _noting := true             # whether _note records (off during dynamic-only rebuilds)
var _live_build := false        # true only while building the LIVE zone's static (its
                                # torches register for the _process flicker; neighbours don't)
var _hidden_cell := Vector2i(-9999, -9999)   # a live cell whose creature is not drawn (first-person: the player)

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
var _smoke_pm: ParticleProcessMaterial   # shared across every sconce's smoke emitter
var _smoke_mesh: QuadMesh                 # shared grey square, billboarded
var _mote_tex: Texture2D                  # small glowing dot for glowfish orbiters
var _glow_shader: Shader                  # crisp bioluminescent bloom over the fish silhouette
var _lights: Array = []           # [{glow, flame, smoke, energy}]
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
			(L["smoke"] as GPUParticles3D).emitting = on

var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _floor_pool: Array[MeshInstance3D] = []
var _label_pool: Array[Label3D] = []
var _top_down := false   # top-down camera modes: tile billboards lie flat to face up

func _ready() -> void:
	_plane = PlaneMesh.new()
	_plane.size = Vector2(CELL, CELL)
	_fence_quad = QuadMesh.new()
	_fence_quad.size = Vector2(1, 1)  # scaled per instance
	_wall_root = Node3D.new()
	add_child(_wall_root)

	# Qud-green ground surface under everything, so the world reads as ground
	# (the dark-green cell background) instead of a black void between the dots.
	var ground := MeshInstance3D.new()
	var gpm := PlaneMesh.new()
	gpm.size = Vector2(400, 400)
	ground.mesh = gpm
	ground.position = Vector3(40, -0.02, 12)  # big enough to cover any zone
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if SHADED_WORLD else BaseMaterial3D.SHADING_MODE_UNSHADED
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
	_flame_tex = _make_radial(32, Color(1.0, 0.80, 0.35), 1.6)  # tighter, brighter core
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

## Render the live zone (`data`) plus any remembered neighbours. Each neighbour is
## {cells: Array, offset: Vector2i} — its cells shifted into place relative to the
## live zone. Neighbours render full-fidelity but static-only (no creatures).
func render_snapshot(data: Dictionary, neighbors: Array = []) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))

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
	_underground = int(data.get("zone", {}).get("z", SURFACE_Z)) > SURFACE_Z

	# LIVE STATIC — walls + floors + static sprites + lights. Rebuilt only when you
	# ENTER a new zone (fresh Qud data), then frozen while you step within it. This
	# is what took ~69ms EVERY step before; now it is paid once per zone.
	Profiler.begin("render.static")
	var zone_changed := live_id != _live_static_id
	if zone_changed:
		_static_retry = 0              # fresh zone: reset the export-race retry budget
	if zone_changed or _static_retry_pending:
		_static_retry_pending = false
		_placed.clear()
		_lights.clear()                # the old live zone's torches stop flickering
		_drop_static(live_id)          # replace any stale (neighbour-built) copy
		_noting = true
		_static_saw_missing = false
		_build_static(live_id, cells)
		_live_static_id = live_id
		# A tile was still missing at build time (the mod exports on sight, usually the
		# frame after this snapshot referenced it). Rebuild on a later snapshot so the
		# now-exported tile replaces its glyph — bounded, so a truly-absent tile that
		# never exports stops retrying and keeps the honest "NO TILE EXPORTED" fallback.
		if _static_saw_missing and _static_retry < STATIC_RETRY_MAX:
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
	Profiler.begin("render.remembered")
	_sync_neighbors(neighbors)
	Profiler.done("render.remembered")

	# Remembered neighbours are FROZEN per-zone subtrees: each built ONCE, then only
	# repositioned by a cheap transform when the live zone shifts. A crossing no longer
	# rebuilds every neighbour (that was the ~1.1s hitch) — it just moves them and
	# builds the one newly-remembered zone.
	Profiler.begin("render.remembered")
	_sync_neighbors(neighbors)
	Profiler.done("render.remembered")

## Build one zone's STATIC geometry (walls + non-creature nonwalls + lights) into the
## current bank, cells shifted by `offset`. `skip_creatures` drops mobile actors —
## always true here; creatures render separately in _rebuild_dynamics. Inspector
## notes are gated by the `_noting` flag (true only for the live static build).
func _build_zone(cells: Array, offset: Vector2i, skip_creatures: bool, wall_types: Dictionary) -> void:
	# pass 1: group wall cells by TYPE (family + colours + background)
	var wall_cells := {}
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
			var main_c := String(obj.get("tilecolor", ""))
			if main_c == "": main_c = String(obj.get("color", ""))
			var detail_c := String(obj.get("detail", ""))
			var bg := _parse_bg(String(obj.get("color", "")))
			var key := "%s|%s|%s|%s" % [tile, main_c, detail_c, bg]
			if not wall_types.has(key):
				wall_types[key] = {"cells": {}, "tile": tile, "main": main_c, "detail": detail_c, "bg": bg}
			# store the cell's REAL autotile variant, not just "occupied". The
			# variant encodes which neighbours are walls, which is exactly what
			# decides whether the roof draws a border on each edge.
			wall_types[key]["cells"][Vector2i(cx, cy)] = String(obj.get("tile", ""))
			wall_cells[Vector2i(cx, cy)] = true

	# pass 2: floors + verticals (skip walls)
	for cell in cells:
		var cx := int(cell.get("x", 0)) + offset.x
		var cy := int(cell.get("y", 0)) + offset.y
		var in_wall: bool = wall_cells.has(Vector2i(cx, cy))
		var sink := _cell_sink(cell)
		var wet: bool = bool(cell.get("wade", false)) or bool(cell.get("swim", false))
		# A stair-down cell's own floor/ground quad would cap the shaft from above, so
		# it is suppressed (the frame lip provides the ring of floor around the opening).
		var stair_cell := _cell_has_stairs_down(cell)
		var idx := 0
		for obj in cell.get("objs", []):
			if not _is_prism(obj):
				_place_nonwall(obj, cx, cy, idx, in_wall, sink, wet, skip_creatures, stair_cell)
			# Creature lights are placed in the DYNAMIC pass so they follow the creature;
			# here (static) we only place fixed lights (sconces, braziers, lit terrain).
			if obj.has("lightRadius") and not (skip_creatures and _is_creature(obj)):
				_place_light(cx, cy, float(obj["lightRadius"]), not _is_creature(obj))
			idx += 1

## Build the live zone's static geometry into its own frozen subtree (once per zone
## entry). Creatures are excluded — they render per step in _rebuild_dynamics.
func _build_static(id: String, cells: Array) -> void:
	var sub := Node3D.new()
	_remembered_root.add_child(sub)
	_static_zones[id] = sub
	_bank = sub
	_live_build = true          # this zone's torches get the flicker (see _place_light)
	var wt := {}
	_build_zone(cells, Vector2i.ZERO, true, wt)
	_rebuild_walls(wt)
	_live_build = false
	_bank = null

## Re-place ONLY the live zone's creatures, every step, into _dynamic_root (cleared
## first). Few objects, so this is the cheap per-step cost that replaced the ~69ms
## full rebuild. Not noted (the inspector's _placed holds the static zone).
func _rebuild_dynamics(cells: Array) -> void:
	for c in _dynamic_root.get_children():
		c.free()
	_orbiters.clear()           # those orbiter roots were children of _dynamic_root (just freed)
	_bank = _dynamic_root
	_noting = false
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		if Vector2i(cx, cy) == _hidden_cell:
			continue     # first-person hides the player (the camera sits on this cell)
		var sink := _cell_sink(cell)
		var wet: bool = bool(cell.get("wade", false)) or bool(cell.get("swim", false))
		var lf: float = _light_frac(cell)   # dim creatures in the dark (night or cavern)
		var idx := 0
		for obj in cell.get("objs", []):
			if not _is_prism(obj) and _is_creature(obj):
				_place_nonwall(obj, cx, cy, idx, false, sink, wet, false, false, lf)
				# A lit creature (NPC with a torch/glowsphere) carries its light with it —
				# placed here every step so it tracks the creature. No smoke: a moving torch
				# shouldn't trail a plume. (_live_build is false during dynamics, so this doesn't
				# register for the flicker or leak into _lights, freed only on a static rebuild.)
				# Glowfish are excluded: their glow will come from a shader on the fish texture,
				# not the sconce-style pool+flame; they get the orbiting motes instead.
				if obj.has("lightRadius") and not _should_glow(obj):
					_place_light(cx, cy, float(obj["lightRadius"]), false)   # glow-critters use the bloom, not a pool
				if _is_glowfish(obj):
					_make_orbiters(cx, cy)     # bioluminescent bugs circling the fish
			idx += 1
	_noting = true
	_bank = null
	# Per-cell darkness runs EVERYWHERE, not just underground: it is driven purely by
	# Qud's light map, which also falls dark on the surface at night (the Daylight part
	# adds a daylight radius of 0 after dusk). Fully-lit cells emit nothing, so daytime
	# and lit caves pay nothing; night and caverns fall off to black around light sources.
	_build_darkness(cells, _dynamic_root)

## Qud LightLevel byte (per cell) -> 0..1 brightness. None(1)/Blackout(0) -> 0 (dark);
## Light(200)+ -> 1 (full). The low senses (darkvision 10 .. safelight 30) map to a dim
## sliver, so an unlit cavern falls toward black — sources are the only real light.
func _light_frac(cell: Dictionary) -> float:
	var lv := int(cell.get("light", 200))   # default full: surface, or an older mod w/o the field
	return clampf(float(lv - 1) / 199.0, 0.0, 1.0)

## Per-cell darkness overlay (cavern lighting). ONE vertex-coloured MIX-black mesh: a quad
## over each cell's floor (and its roof, for wall cells) whose ALPHA is how DARK the cell is
## (1 - light). Built into _dynamic_root each turn, so it tracks Qud's live light map as
## sources/player move. Cheap — one mesh, and fully-lit cells contribute nothing. The
## additive torch/glow geometry draws bright on top, so lit pools read against the black.
## `parent` is where the one darkness mesh lands: _dynamic_root for the live zone (rebuilt
## each turn, tracks moving light) or a neighbour's frozen subtree (baked once from that
## zone's remembered light, so remembered zones darken to match instead of staying lit).
## `clear_player`: for a FROZEN zone, the cell the player stood on when it was last live.
## Qud lights a disc around the player so they can see; that disc follows the player, so in
## a zone they've LEFT it must be erased or it hangs there as a cropped light. Left invalid
## (default) for the live zone, whose player disc is real and should stay.
const FROZEN_LIGHT_CLEAR_R := 7.0    # radius of player sight-disc to blank out in frozen zones
func _build_darkness(cells: Array, parent: Node, clear_player := Vector2i(-9999, -9999)) -> void:
	var clearing: bool = clear_player.x > -9000
	var cpf := Vector2(clear_player)
	# pass 1: per-cell light fraction + which cells are walls (to find exposed faces).
	var frac := {}
	var walls := {}
	for cell in cells:
		var k := Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
		var f := _light_frac(cell)
		if clearing and (Vector2(k) - cpf).length() <= FROZEN_LIGHT_CLEAR_R:
			f = 0.0                      # erase the departed player's sight-disc
		frac[k] = f
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
	var any := false
	for cell in cells:
		var k := Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))
		var cx := float(k.x)
		var cy := float(k.y)
		if walls.has(k):
			var a := (1.0 - float(frac[k])) * DARK_MAX
			if a >= 0.02:
				_dark_quad(st, cx, cy, DARK_ROOF_Y, a); any = true
			for d in sides:
				if walls.has(k + d):
					continue                       # interior face: not visible
				var sa := (1.0 - float(frac.get(k + d, frac[k]))) * DARK_MAX
				if sa >= 0.02:
					_dark_side(st, cx, cy, d, sa); any = true
		else:
			var a := (1.0 - float(frac[k])) * DARK_MAX
			if a >= 0.02:
				_dark_quad(st, cx, cy, DARK_FLOOR_Y, a); any = true
	if not any:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _dark_material()
	parent.add_child(mi)

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

func _dark_material() -> StandardMaterial3D:
	if _dark_mat != null:
		return _dark_mat
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX        # alpha-black OVER the scene = darken
	m.vertex_color_use_as_albedo = true                # per-cell vertex alpha drives darkness
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED   # overlay: test depth but don't write
	_dark_mat = m
	return m

func _drop_static(id: String) -> void:
	if _static_zones.has(id):
		_static_zones[id].free()
		_static_zones.erase(id)

func _drop_all_static() -> void:
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
		if not _static_zones.has(id):
			var sub := Node3D.new()
			_remembered_root.add_child(sub)
			_static_zones[id] = sub
			_bank = sub
			_noting = false     # neighbours aren't inspected; don't touch _placed
			var wt := {}
			_build_zone(nb.get("cells", []), Vector2i.ZERO, true, wt)   # local coords
			_rebuild_walls(wt)     # _bank set -> into the subtree, no clear
			_noting = true
			_bank = null
		# Bake this remembered zone's darkness from its stored light, so a dark cavern or
		# night surface stays dark in memory instead of rendering fully lit. Meta-guarded
		# to bake exactly ONCE — and done OUTSIDE the build block above so a zone that just
		# stopped being LIVE gets it too: its subtree already exists (built as the live
		# static, no darkness), and its per-turn darkness vanished with _dynamic_root. On
		# re-entry _drop_static frees the subtree + meta, so it re-bakes as a neighbour.
		var znode: Node3D = _static_zones[id]
		if not znode.has_meta("dark_baked"):
			znode.set_meta("dark_baked", true)
			# erase the player's sight-disc: they've left this zone (its stored player
			# position is where they crossed out, at the edge)
			var pp := Vector2i(int(nb.get("px", -9999)), int(nb.get("py", -9999)))
			_build_darkness(nb.get("cells", []), znode, pp)
		# Vertical stacking: a neighbour `dz` strata below the live zone drops by
		# dz * level_height, so deeper levels sit under the current one with an
		# arbitrary, user-set gap. Same-stratum neighbours (dz==0) stay coplanar.
		var o: Vector2i = nb.get("offset", Vector2i.ZERO)
		var dz: int = int(nb.get("dz", 0))
		_static_zones[id].position = Vector3(o.x, -float(dz) * level_height, o.y)

# --- introspection (for CellInspector) --------------------------------------

func _note(cx: int, cy: int, idx: int, kind: String, y: float) -> void:
	if not _noting:
		return   # dynamic-only (creature) rebuilds don't record; _placed holds the static zone
	var k := Vector2i(cx, cy)
	if not _placed.has(k):
		_placed[k] = []
	_placed[k].append({"idx": idx, "kind": kind, "y": y})

## What the renderer did with cell (cx, cy): [{idx, kind, y}, ...]
func placements_at(cx: int, cy: int) -> Array:
	return _placed.get(Vector2i(cx, cy), [])

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
		_: return 0
	var n := 0
	for row in mask:
		for v in row:
			if v: n += 1
	return n

## The on-disk filename a tile path maps to under tilesDir.
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
	["wall", "wall"],
	["n–s", "panel_ns"],
	["e–w", "panel_ew"],
	["billboard", "billboard"],
	["flat", "floor"],
	["not be drawn", "skip"],
]

## Matched case-insensitively as substrings of the filed verdict, so old reports
## keep parsing and TileReport's wording can change freely. Order matters where one
## phrase contains another: "enclosed" is checked before "background".
const FILL_KEYS := [
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
	if text == _overrides_raw:
		return                      # unchanged since last frame — skip the re-parse
	_overrides_raw = text
	_overrides_dirty = true         # rules changed -> force a static rebuild (see render_snapshot)
	_overrides.clear()
	_fill_overrides.clear()
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
		var sd := _match_stairdir(String(entry.get("stairDir", "")))
		if sd != "":
			_stairdir_overrides[fam] = sd

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
		var names := ["none", "all", "interior", "fill-holes"]
		var m := int(_fill_overrides[fam])
		parts.append("fill=" + (names[m] if m < names.size() else str(m)))
	if _position_overrides.has(fam):
		parts.append("pos=" + String(_position_overrides[fam]))
	if _glow_overrides.has(fam):
		parts.append("effect=glow")
	return "" if parts.is_empty() else "  ".join(parts)

func _override_for(tile: String) -> String:
	if _overrides.is_empty() or tile == "":
		return ""
	return String(_overrides.get(tile_family(tile), ""))

# --- torch / fire light ------------------------------------------------------

## An additive warm glow on the ground (the "light") plus a small flickering flame
## above the sconce. Qud's radius is in cells; 1 cell == 1 world unit.
func _place_light(cx: int, cy: int, radius: float, smokes := true) -> void:
	# `smokes` is false for creature lights (e.g. a bioluminescent glowfish) — they glow
	# but are not fire, so no plume. All torch nodes live in their zone's frozen subtree
	# (the bank). Only the LIVE zone's register in _lights for the _process flicker; a
	# remembered neighbour's glow steadily (no flicker), which reads fine at distance.
	var lp: Node = _bank if _bank != null else _light_root
	var glow := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	var d: float = maxf(2.0, radius * 1.6)   # pool a bit wider than the sconce
	gm.size = Vector2(d, d)
	glow.mesh = gm
	glow.position = Vector3(cx, FLOOR_Y + 0.01, cy)
	glow.material_override = _fx_material(_glow_tex)
	lp.add_child(glow)

	var flame := Sprite3D.new()
	flame.texture = _flame_tex
	flame.pixel_size = 0.03
	flame.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	flame.shaded = false
	flame.transparent = true
	flame.material_override = _fx_material(_flame_tex)   # additive
	flame.position = Vector3(cx, 0.7, cy)                # above the sconce
	lp.add_child(flame)

	# Rising smoke plume. Only the LIVE zone gets emitters (keeps the particle count
	# bounded; distant neighbour plumes would be fogged anyway). Smoke is a NIGHT effect:
	# the flame fully fades by day, so smoke over an unlit sconce would look wrong — it
	# emits only at night and switches off at dawn (see _smoke_on / set_daylight).
	if _live_build:
		var entry := {"glow": glow, "flame": flame, "energy": 1.0}
		if smokes:
			var smoke := _make_smoke()
			smoke.position = Vector3(cx, 0.85, cy)   # just above the flame
			smoke.emitting = _smoke_on()             # honour the current time-of-day at build
			lp.add_child(smoke)
			entry["smoke"] = smoke
		_lights.append(entry)
	else:
		# Neighbour/static lights don't flicker in _process, so bake the current daylight
		# dimming into them now (otherwise they'd sit at full additive brightness by day).
		glow.transparency = clampf(1.0 - _glow_mul() * 0.6, 0.0, 1.0)
		# NB: a Sprite3D's `modulate` is IGNORED once material_override is set, so dim the
		# flame via GeometryInstance3D.transparency (same lever as the glow), not modulate.
		flame.transparency = clampf(1.0 - _flame_mul(), 0.0, 1.0)

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
	return _daylight < SMOKE_OFF_SUN

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
func _make_orbiters(cx: int, cy: int) -> void:
	var root := Node3D.new()
	root.position = Vector3(cx, ORBIT_CENTER_Y, cy)
	var motes: Array = []
	var fish_rot: float = _fish_rand(cx, cy, 0, 9) * TAU   # whole-cluster rotation, varies per fish
	for i in ORBIT_COUNT:
		var s := Sprite3D.new()
		s.texture = _mote_tex
		s.pixel_size = 0.006
		s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		s.shaded = false
		s.transparent = true
		s.material_override = _fx_material(_mote_tex)   # additive glow
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
uniform float halo_amt = 1.0;
uniform float halo_uv = 0.12;
uniform float strength = 1.3;
uniform float pulse_speed = 2.5;
void vertex() {
	// billboard (Godot's documented snippet) with scale preserved
	MODELVIEW_MATRIX = VIEW_MATRIX
		* mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3])
		* mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			   vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			   vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			   vec4(0.0, 0.0, 0.0, 1.0));
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
	// body: gentle glow in the FISH'S OWN colour (never a flat cyan fill, so it can't become
	// an opaque block); halo: the crisp cyan outline. Additive: contribution = ALBEDO * ALPHA.
	vec3 col = fish_rgb * here * body_amt + glow_color * halo * halo_amt;
	ALBEDO = col * strength;
	ALPHA = pulse;
}
"""

## Hang the glow bloom over a glowfish sprite `s`, matched to its cropped region so the
## glowing shape lines up with the fish exactly.
func _add_glow(s: Sprite3D, tex: Texture2D) -> void:
	var rr := s.region_rect if s.region_enabled else Rect2(0, 0, tex.get_width(), tex.get_height())
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	var mat := ShaderMaterial.new()
	mat.shader = _glow_shader
	mat.set_shader_parameter("fish_tex", tex)
	mat.set_shader_parameter("uv_min", Vector2(rr.position.x / tw, rr.position.y / th))
	mat.set_shader_parameter("uv_size", Vector2(rr.size.x / tw, rr.size.y / th))
	mat.set_shader_parameter("pad", GLOW_PAD)
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(rr.size.x * s.pixel_size, rr.size.y * s.pixel_size) * GLOW_PAD
	q.mesh = qm
	q.material_override = mat
	q.position = s.position                   # centred on the visible fish
	_bank.add_child(q)   # into _dynamic_root, freed + rebuilt each step

## Flicker: jitter each light's brightness a little every frame, so torches read
## as fire rather than steady lamps. Cheap — modulate the additive quads' alpha.
func _process(_dt: float) -> void:
	var gmul := _glow_mul()      # daylight dimming, recomputed once per frame
	var fmul := _flame_mul()
	for L in _lights:
		var e: float = 0.75 + randf() * 0.4        # 0.75..1.15
		L["energy"] = lerpf(L["energy"], e, 0.35)   # smoothed, so it shimmers not strobes
		var a: float = L["energy"]
		(L["glow"] as MeshInstance3D).transparency = clampf(1.0 - a * gmul * 0.6, 0.0, 1.0)
		var fs: float = 0.9 + a * 0.25
		var flame := L["flame"] as Sprite3D
		flame.scale = Vector3(fs, fs * (0.95 + randf() * 0.2), fs)
		# transparency, NOT modulate: modulate is ignored under material_override (which the
		# flame has, for additive blend), so the flicker/daylight fade never reached the ball.
		flame.transparency = clampf(1.0 - a * fmul, 0.0, 1.0)

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
				(m["s"] as Sprite3D).position = Vector3(x * ct - z * st, y, x * st + z * ct)


func _is_prism(obj: Dictionary) -> bool:
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

func _place_connector(tile: String, main_c: String, detail_c: String, cx: int, cy: int, dirs: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0) -> void:
	if dirs == "":
		_fence_half(cx, cy, "post", tile, main_c, detail_c, h, fill, y_center)
		return
	for d in dirs:
		_fence_half(cx, cy, d, tile, main_c, detail_c, h, fill, y_center)

# One upright half-panel from the cell centre out to the edge in direction d, using
# the family's E-W elevation art. Adjacent cells' halves meet at the shared edge,
# so runs are continuous and corners form a clean L. Used for every directional
# family: picket fences, pipes, and tent walls (which differ only in height).
func _fence_half(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0) -> void:
	var mi := _take_fence()
	var half := "r" if (d == "e" or d == "s") else "l"
	mi.material_override = _fence_material(_panel_art(tile), main_c, detail_c, half, fill)
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

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool, sink := 0.0, wet := false, skip_creatures := false, stair_cell := false, light_frac := 1.0) -> void:
	# Static builds exclude creatures (they render per step in _rebuild_dynamics);
	# remembered zones drop them entirely (they've wandered off since last live).
	if skip_creatures and _is_creature(obj):
		return
	var tile := String(obj.get("tile", ""))

	# No tile even after asking the object what it would DRAW means Qud draws
	# nothing: DaylightWidget, ZoneMusic, CheckpointWidget, Landmark* — zone
	# bookkeeping parked in real cells. We were painting them as colour dots.
	# (A tile path whose PNG is merely missing still falls through to the glyph
	# label below; that case is transient, since tiles export on sight.)
	if tile == "":
		_note(cx, cy, idx, "skipped(no tile — not drawn by Qud)", 0.0)
		return

	var main_c := String(obj.get("tilecolor", ""))
	if main_c == "": main_c = String(obj.get("color", ""))
	var detail_c := String(obj.get("detail", ""))
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
			var y := (BRIDGE_Y + idx * TIEBREAK) if wet else (FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK)
			d.position = Vector3(cx, y, cy)
			d.visible = true
			_track(d)
			_note(cx, cy, idx, "deck(over water)" if wet else "deck(on ground)", y)
			return

	var tex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj))

	# A filed verdict overrides everything below it. This is how facts that are not
	# in Qud's data get in: nothing in `sw_waterwheel_1` says the wheel runs
	# east-west, so a human says it and this honours it.
	var verdict := _override_for(tile)
	if verdict == "skip":
		_note(cx, cy, idx, "skipped(user verdict: not drawn)", 0.0)
		return
	if verdict == "panel_ew" or verdict == "panel_ns":
		var vtex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj))
		if vtex != null:
			var axis := "ew" if verdict == "panel_ew" else "ns"
			var vh := _panel_height(obj, tile)
			_place_connector(tile, main_c, detail_c, cx, cy, axis, vh,
				_fill_for(tile, Fill.ALL if bool(obj.get("occluding", false)) else Fill.NONE))
			_note(cx, cy, idx, "connector panels [%s] h=%.2f (user verdict)" % [axis, vh], vh * 0.5)
			return

	# Stairs down: a shaft into the level below, not a flat tile. Qud's StairsDown is
	# a vertical connector with no lateral facing, so unless a direction is supplied
	# (data field or a user override) we GUESS the descent axis. Build a framed
	# opening + a descending voxel flight in place of the sprite. Skipped if the user
	# filed a verdict that forces the normal floor/billboard path.
	if _is_stairs_down(obj, tile) and verdict != "billboard" and verdict != "floor" and not in_wall:
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
			uf.position = Vector3(cx, FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK, cy)
			uf.visible = true
			_track(uf)
			_note(cx, cy, idx, "stairs-up (flat floor tile)", uf.position.y)
			return

	# Qud's painted ground layer is flat by default — dirt, gravel, cracked earth.
	# But vegetation in that layer is cover you stand among, not a texture you walk
	# on, so it reads far better standing up. Route it to the billboard path.
	var upright_ground: bool = bool(obj.get("ground", false)) and _is_vegetation(tile)
	if verdict == "billboard":
		upright_ground = true        # force it off the floor path
	var as_floor: bool = (layer <= FLOOR_LAYER_MAX and not upright_ground) or verdict == "floor"

	if as_floor:
		if in_wall:
			_note(cx, cy, idx, "skipped(under wall)", 0.0)
			return  # hidden under a wall; don't bother
		if stair_cell:
			_note(cx, cy, idx, "skipped(floor over stair opening)", 0.0)
			return  # would cap the shaft; the frame lip is the floor here
		var f := _take_floor()
		var fkind := "floor"
		if tex != null:
			f.material_override = _mesh_material(tile, main_c, detail_c, tex)
			f.scale = Vector3.ONE
		else:
			f.material_override = _color_material(_qud_color(String(obj.get("color", ""))))
			f.scale = Vector3(0.5, 1.0, 0.5)
			fkind = "floor(no tile: flat colour dot)"
		f.position = Vector3(cx, FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK, cy)
		f.visible = true
		_track(f)
		_note(cx, cy, idx, fkind, f.position.y)
	elif tex != null:
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
			_place_connector(tile, main_c, detail_c, cx, cy, dirs, ph, pfill, yc)
			_note(cx, cy, idx, "connector panels [%s] h=%.2f%s%s" % [
				"post" if dirs == "" else dirs, ph,
				" filled-bg" if solid else "", "  floated" if floated else ""], yc)
		else:
			# Gaps *enclosed* by the art read as the cell background, the way Qud
			# draws them; everything outside the silhouette stays see-through.
			var btex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj),
				_color_key(obj), _fill_for(tile, Fill.INTERIOR))
			if btex == null:
				btex = tex
			var s := _take_sprite()
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
			s.visible = true
			if _should_glow(obj):
				_add_glow(s, btex)              # crisp bioluminescent bloom (glowfish, glowpad, tagged tiles)
			_track(s)
			var fmode := _fill_for(tile, Fill.INTERIOR)
			var gaps := tile_fill_px(tile, fmode)
			var kind := "billboard"
			if submerged:
				kind = "billboard(submerged %d%%)" % roundi(sink * 100.0)
			elif upright_ground:
				kind = "billboard(painted cover, stood up)"
			var names := ["none", "all", "interior", "fill-holes"]
			var fname: String = names[fmode] if fmode < names.size() else str(fmode)
			_note(cx, cy, idx, "%s, fill=%s %dpx" % [kind, fname, gaps], s.position.y)
	else:
		var l := _take_label()
		l.text = String(obj.get("glyph", "?"))
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
		cy_center = (WATER_LINE_Y if sink > 0.0 else 0.0) + PIXEL_SIZE * shown * 0.5
	s.position = Vector3(cx, cy_center, cy)

# --- greedy-meshed walls ----------------------------------------------------

func _parse_bg(color: String) -> String:
	# "&r^w" -> "w"  (the background colour); "" if no ^ component.
	# Counterpart to _fg_letter, which takes the half before the caret.
	var i := color.find("^")
	if i >= 0 and i + 1 < color.length():
		return color.substr(i + 1, 1)
	return ""

func _wall_bg_color() -> Color:
	# Qud fills transparent gaps with the world/cell background (dark green), NOT the
	# object's ^X. The ^X-derived colour was flooding e.g. metal walls cyan; the cyan
	# actually belongs to the detail pixels (the border), handled by the recolor.
	return _world_bg

func _rebuild_walls(wall_types: Dictionary) -> void:
	# Live rebuild clears _wall_root; when banking into a fresh neighbour subtree
	# (_sync_neighbors), there is nothing to clear, so don't wipe it mid-build.
	if _bank == null:
		for c in _wall_root.get_children():
			c.queue_free()
	for key in wall_types:
		var t = wall_types[key]
		_wall_tile = t["tile"]; _wall_main = t["main"]; _wall_detail = t["detail"]; _wall_bg = t["bg"]
		var cells: Dictionary = t["cells"]

		# SOLID CORE: a dark box filling each cell, just inside the voxel skin, so
		# the relief has something behind it. Without it you see straight through the
		# gaps between protruding columns into the empty cell. Coloured a darker
		# shade of the wall's darkest colour, so recesses read as deep shadow.
		var core_mat := _wall_core_material()
		# Side gaps bottom out on the core's outer faces (0.5 - SIDE_CARVE). Its TOP
		# sits just below the cap's carved gap floor (WALL_H - CAP_CARVE) so it never
		# pokes up through a roof gap; the cap draws its own recess-coloured floors.
		var core_half := 0.5 - SIDE_CARVE
		var core_top := WALL_H - CAP_CARVE - 0.01
		for k in cells:
			var core := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(core_half * 2.0, core_top, core_half * 2.0)
			core.mesh = bm
			core.material_override = core_mat
			core.position = Vector3(k.x, core_top * 0.5, k.y)
			_wall_parent().add_child(core)

		# ROOFS are per-cell, grouped by autotile variant. Merging them under one
		# texture drew the fully-bordered isolated tile on every cell, so a run of
		# wall read as a grid of separate framed squares instead of one continuous
		# surface. Qud already solved this: the -XXXXXXXX suffix says which edges
		# have a neighbour, and its art omits the border there. Use each cell's own.
		var by_variant := {}
		for k in cells:
			var v := String(cells[k])
			if not by_variant.has(v):
				by_variant[v] = []
			by_variant[v].append(k)
		for v in by_variant:
			var vmesh: ArrayMesh = _voxel_cap_mesh(v)
			var smesh: ArrayMesh = _side_voxel_mesh(v)
			for k in by_variant[v]:
				if vmesh != null:
					var rmi := MeshInstance3D.new()
					rmi.mesh = vmesh
					rmi.material_override = _voxel_material()
					rmi.position = Vector3(k.x, 0.0, k.y)
					_wall_parent().add_child(rmi)
				# a voxel side on each edge whose orthogonal neighbour isn't this wall.
				# the side mesh faces +Z (south); rotate it onto each exposed edge.
				if smesh != null:
					if not cells.has(Vector2i(k.x, k.y + 1)): _place_side(smesh, k, 0.0)     # S
					if not cells.has(Vector2i(k.x + 1, k.y)): _place_side(smesh, k, 90.0)    # E
					if not cells.has(Vector2i(k.x, k.y - 1)): _place_side(smesh, k, 180.0)   # N
					if not cells.has(Vector2i(k.x - 1, k.y)): _place_side(smesh, k, 270.0)   # W

func _place_side(mesh: ArrayMesh, k: Vector2i, deg: float) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _voxel_material()
	mi.position = Vector3(k.x, 0.0, k.y)
	mi.rotation = Vector3(0, deg_to_rad(deg), 0)
	_wall_parent().add_child(mi)

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

# --- voxel wall caps --------------------------------------------------------

const CAP_CARVE := 0.10     # how deep a background gap recesses DOWN into the roof
const SIDE_CARVE := 0.10    # how deep a background gap recesses INTO the wall face
var _voxel_cache := {}      # cap key -> ArrayMesh
var _voxel_mat: StandardMaterial3D

## Cap relief for a wall variant, centred on its cell. Same flush-and-carve model
## as the wall sides, vertical: every NON-background pixel (red main AND detail)
## sits flush at the roof surface (WALL_H); only the background gaps carve DOWN by
## CAP_CARVE, their floors filled with the dark recess colour. No protruding detail
## — the cap reads as a solid top with recessed pits, matching the faces. Cached
## per variant+colour, built once and instanced per cell.
func _voxel_cap_mesh(variant_tile: String) -> ArrayMesh:
	# reuse the recoloured, fully-framed cap the flat path already produced
	var tex := _cap_tex(variant_tile)
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	var key := "%s|%s|%s|%s" % [variant_tile, _wall_main, _wall_detail, _wall_bg]
	if _voxel_cache.has(key):
		return _voxel_cache[key]

	var w := img.get_width()
	var h := img.get_height()
	var bg := _wall_bg_color().to_html(false)
	var recess := _wall_recess_color()
	var mainc := _qud_color(_wall_main)     # material colour for boundary-closing walls
	# top height per pixel: flush at WALL_H (material) or carved down (background gap)
	var top := []
	for y in h:
		var row := []
		for x in w:
			row.append(WALL_H - CAP_CARVE if img.get_pixel(x, y).to_html(false) == bg else WALL_H)
		top.append(row)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ps := 1.0 / w
	for y in h:
		for x in w:
			var col := img.get_pixel(x, y)
			var yt: float = top[y][x]
			var x0 := -0.5 + x * ps
			var x1 := x0 + ps
			var z0 := -0.5 + y * ps
			var z1 := z0 + ps
			# flush pixels show their own colour; a carved gap floor shows the recess
			if yt >= WALL_H:
				_vc_top(st, x0, x1, z0, z1, yt, col)
			else:
				_vc_top(st, x0, x1, z0, z1, yt, recess)
			# walls of the carved gaps (+ close boundary gaps up to the neighbour cap)
			_vc_step(st, x, y, yt, top, w, h, x0, x1, z0, z1, col, mainc)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	_voxel_cache[key] = mesh
	return mesh

## Voxel relief for ONE wall face, in local cell space facing +Z (the south edge):
## the front-face art extruded OUTWARD per colour rank, so the wall's surface reads
## as bumpy stone that catches the sun. Qud uses the same south-face art on all four
## sides, so this one cached mesh is instanced+rotated onto each exposed edge.
var _side_cache := {}
func _side_voxel_mesh(variant_tile: String) -> ArrayMesh:
	var tex := _wall_region_tex("side")
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	var key := "%s|%s|%s|%s" % [variant_tile, _wall_main, _wall_detail, _wall_bg]
	if _side_cache.has(key):
		return _side_cache[key]
	var w := img.get_width()
	var h := img.get_height()
	var bg := _wall_bg_color().to_html(false)
	var mainc := _qud_color(_wall_main)     # material colour for boundary-closing walls
	# Depth per pixel: every NON-background pixel (red main AND blue detail) shares
	# ONE flush depth at the cell boundary (z=0.5), so the highlight sits at the same
	# depth as the red body, and the flush skins of adjacent faces meet cleanly at the
	# corners (south edge and east edge both land on the corner line). Only the
	# background (the gaps/rivet holes) carves INWARD, revealing the dark core.
	var dep := []
	for y in h:
		var row := []
		for x in w:
			row.append(0.5 - SIDE_CARVE if img.get_pixel(x, y).to_html(false) == bg else 0.5)
		dep.append(row)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pw := 1.0 / w
	var ph := WALL_H / h
	for y in h:
		for x in w:
			var col := img.get_pixel(x, y)
			var d: float = dep[y][x]
			var xa := -0.5 + x * pw                       # along the edge
			var xb := xa + pw
			var yt: float = WALL_H - y * ph               # row 0 = top of the wall
			var yb: float = yt - ph
			# Flush material pixels get an outward face; a GAP pixel gets NONE — its
			# hole bottoms out on the dark core, so you see the recess colour, not a
			# background-coloured quad floating at the carve depth.
			if d >= 0.5:
				for p in [Vector3(xa, yb, d), Vector3(xb, yb, d), Vector3(xb, yt, d),
						  Vector3(xa, yb, d), Vector3(xb, yt, d), Vector3(xa, yt, d)]:
					st.set_normal(Vector3(0, 0, 1)); st.set_color(col); st.add_vertex(p)
			# walls of the carved gaps (+ close boundary gaps out to the neighbour face)
			_side_step(st, x, y, d, dep, w, h, xa, xb, yt, yb, col, mainc)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	_side_cache[key] = mesh
	return mesh

## Walls of a carved-in background gap. In-cell: for each neighbour DEEPER than this
## pixel, draw the face from the neighbour's depth out to this pixel's (the more
## forward pixel owns it). At a CELL BOUNDARY along a straight run the checker runs
## to the edge, so a gap edge pixel's flush neighbour lives in the next cell's mesh
## and won't close the pit — leaving it open sideways. So when we ARE the gap at a
## boundary, close our own wall out to the neighbour's flush face, in the material
## colour (`mainc`) to match the in-cell trench walls.
func _side_step(st: SurfaceTool, x: int, y: int, d: float, dep: Array, w: int, h: int,
		xa: float, xb: float, yt: float, yb: float, col: Color, mainc: Color) -> void:
	for dir in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nx: int = x + dir[0]
		var ny: int = y + dir[1]
		var inb := nx >= 0 and nx < w and ny >= 0 and ny < h
		var otherz: float; var wcol: Color
		if inb:
			var nd := float(dep[ny][nx])
			if nd >= d:
				continue                               # neighbour not deeper -> no wall
			otherz = nd; wcol = col                    # this pixel forward, wall back to it
		else:
			if d >= 0.5:
				continue                               # flush edge: next cell's face abuts
			otherz = 0.5; wcol = mainc                 # gap at boundary: close out to flush
		var a: Vector3; var b: Vector3; var nrm: Vector3
		if dir == [1, 0]:      a = Vector3(xb, yb, 0); b = Vector3(xb, yt, 0); nrm = Vector3(1, 0, 0)
		elif dir == [-1, 0]:   a = Vector3(xa, yt, 0); b = Vector3(xa, yb, 0); nrm = Vector3(-1, 0, 0)
		elif dir == [0, 1]:    a = Vector3(xb, yb, 0); b = Vector3(xa, yb, 0); nrm = Vector3(0, -1, 0)
		else:                  a = Vector3(xa, yt, 0); b = Vector3(xb, yt, 0); nrm = Vector3(0, 1, 0)
		var af := Vector3(a.x, a.y, d); var bf := Vector3(b.x, b.y, d)
		var an := Vector3(a.x, a.y, otherz); var bn := Vector3(b.x, b.y, otherz)
		for p in [an, bf, af, an, bn, bf]:
			st.set_normal(nrm); st.set_color(wcol); st.add_vertex(p)

## Shared material for voxel caps:

## The core seen through the carved gaps. Art theory: a recess reads as a darker,
## slightly ambient-tinted shade of the material ITSELF, not a foreign colour. So
## take the wall's MAIN (the "red"), darken it, and nudge it toward the scene
## background (the teal ambient) — a colour between the red and the world bg, as
## requested — so gaps read as deep shadow in the material rather than a teal hole.
## Colour of a recess (carved gap floor, solid core): the wall's own red, darkened,
## with only a faint ambient nudge — reads as the material in shadow, not a foreign
## hole. Shared by the core box and the cap's carved gap floors so they match.
func _wall_recess_color() -> Color:
	return _qud_color(_wall_main).darkened(0.5).lerp(_world_bg, 0.12)

func _wall_core_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = _wall_recess_color()
	m.roughness = 0.95
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if SHADED_WORLD else BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

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

func _vc_top(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float, y: float, c: Color) -> void:
	for p in [Vector3(x0, y, z0), Vector3(x1, y, z1), Vector3(x1, y, z0),
			  Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1)]:
		st.set_normal(Vector3.UP); st.set_color(c); st.add_vertex(p)

## Walls of a carved-down background gap on the cap. In-cell: for each neighbour
## that sits LOWER, draw the face from the neighbour's height up to this pixel's
## (the higher pixel owns the wall, so it's drawn once). At a CELL BOUNDARY the
## art's checker runs to the edge, so an edge pixel can be a gap whose flush
## neighbour lives in the next cell's mesh — that cell can't see us and won't close
## it, leaving the pit open sideways (a dark groove along the seam). So when we ARE
## the gap at a boundary, close our own wall up to the neighbour's flush cap, in the
## material colour (`mainc`) so it matches the in-cell trench walls.
func _vc_step(st: SurfaceTool, x: int, y: int, yt: float, top: Array, w: int, h: int,
		x0: float, x1: float, z0: float, z1: float, c: Color, mainc: Color) -> void:
	for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nx: int = x + d[0]
		var ny: int = y + d[1]
		var inb := nx >= 0 and nx < w and ny >= 0 and ny < h
		var ylo: float; var yhi: float; var wcol: Color
		if inb:
			var nyt := float(top[ny][nx])
			if nyt >= yt:
				continue                               # neighbour not lower -> no wall
			ylo = nyt; yhi = yt; wcol = c              # this pixel higher, wall down to it
		else:
			if yt >= WALL_H:
				continue                               # flush edge: next cell's cap abuts
			ylo = yt; yhi = WALL_H; wcol = mainc       # gap at boundary: close it up to flush
		var a: Vector3; var b: Vector3
		if d == [1, 0]:    a = Vector3(x1, 0, z0); b = Vector3(x1, 0, z1)
		elif d == [-1, 0]: a = Vector3(x0, 0, z1); b = Vector3(x0, 0, z0)
		elif d == [0, 1]:  a = Vector3(x1, 0, z1); b = Vector3(x0, 0, z1)
		else:              a = Vector3(x0, 0, z0); b = Vector3(x1, 0, z0)
		var at := Vector3(a.x, yhi, a.z); var bt := Vector3(b.x, yhi, b.z)
		var ab := Vector3(a.x, ylo, a.z); var bb := Vector3(b.x, ylo, b.z)
		var nrm := Vector3(d[0], 0, d[1])
		for p in [ab, bt, at, ab, bb, bt]:
			st.set_normal(nrm); st.set_color(wcol); st.add_vertex(p)

## The top-down cap of ONE autotile variant, recoloured. Borders appear only on
## the edges that variant says are exposed, so adjacent cells join seamlessly.
func _cap_tex(tile: String) -> ImageTexture:
	var key := "cap|%s|%s|%s|%s" % [tile, _wall_main, _wall_detail, _wall_bg]
	if _wallmat_cache.has(key):
		return _wallmat_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return _wall_top_material_tex()      # fall back to the isolated tile
	var region := mask.get_region(Rect2i(0, 0, mask.get_width(), _wall_split(mask).x))
	var tex := _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
	_wallmat_cache[key] = tex
	return tex

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

func _wall_region_tex(kind: String) -> ImageTexture:
	if _wall_tile == "":
		return null
	var key := "%s|%s|%s|%s|%s" % [kind, _wall_tile, _wall_main, _wall_detail, _wall_bg]
	if _wallmat_cache.has(key):
		return _wallmat_cache[key]
	var iso := _wall_tile.replace("-11111111", "-00000000")  # isolated wall: real border on all 4 sides
	var tex: ImageTexture = null
	if kind == "top":
		var iso_mask := _mask(iso)
		if iso_mask != null:
			# REAL fully-framed tile — recolor its top square as-is (real crenellated border)
			var w := iso_mask.get_width()
			var region := iso_mask.get_region(Rect2i(0, 0, w, _wall_split(iso_mask).x))
			tex = _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
		else:
			var mask := _mask(_wall_tile)  # fallback: synthetic frame on the interior checker
			if mask != null:
				var w := mask.get_width()
				var region := mask.get_region(Rect2i(0, 0, w, _wall_split(mask).x))
				tex = _framed_top(region)
	else:
		# front-face strip: prefer the isolated tile's face, else a south-open variant
		var face_tile := iso
		var mask := _mask(face_tile)
		if mask == null:
			face_tile = _wall_tile.replace("-11111111", "-11100000")
			mask = _mask(face_tile)
		if mask != null:
			var w := mask.get_width()
			var h := mask.get_height()
			var split := _wall_split(mask)
			if split.y < h:
				var region := mask.get_region(Rect2i(0, split.y, w, h - split.y))
				tex = _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
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
func _colored_tex_rgb(tile: String, main: Color, detail: Color, ckey: String, fill := Fill.NONE) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	var key := "%s|%s|%d" % [tile, ckey, fill]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return null
	var inner = null
	if fill == Fill.INTERIOR:
		inner = _interior(tile)
	elif fill == Fill.SPAN:
		inner = _fill_holes(tile)
	var tex := _recolor_rgb(mask, main, detail, fill, inner)
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
	if _mask_cache.has(fname):
		return _mask_cache[fname]
	var path := _tiles_dir.path_join(fname)
	if not FileAccess.file_exists(path):
		if _live_build: _static_saw_missing = true   # export race — retry the static build later
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		if _live_build: _static_saw_missing = true   # file mid-write (export in progress)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		if _live_build: _static_saw_missing = true   # partial PNG mid-export
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
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED if _top_down else BaseMaterial3D.BILLBOARD_FIXED_Y
	s.rotation = Vector3.ZERO
	s.region_enabled = false
	s.flip_h = false
	s.flip_v = false
	return s

func _take_floor() -> MeshInstance3D:
	if _bank == null and _floor_pool.size() > 0: return _floor_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _plane
	_spawn_parent().add_child(mi)
	return mi

func _take_label() -> Label3D:
	if _bank == null and _label_pool.size() > 0: return _label_pool.pop_back()
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = 0.02
	l.font_size = 64
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_spawn_parent().add_child(l)
	return l

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
func _obj_main(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	var c := String(obj.get("tilecolor", ""))
	if c == "": c = String(obj.get("color", ""))
	return _qud_color(c)

func _obj_detail(obj: Dictionary) -> Color:
	var hex := String(obj.get("detailHex", ""))
	if hex != "":
		return Color(hex)
	return _qud_color(String(obj.get("detail", "")))

## Cache key for an object's colours — the painted rgb when present, else the
## colour codes. Must distinguish the two, or a painted and an unpainted object
## sharing a tile would collide in the texture cache.
func _color_key(obj: Dictionary) -> String:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return "%s~%s" % [hex, String(obj.get("detailHex", ""))]
	var c := String(obj.get("tilecolor", ""))
	if c == "": c = String(obj.get("color", ""))
	return "%s|%s" % [c, String(obj.get("detail", ""))]

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
	var c := code.strip_edges()
	var caret := c.find("^")
	if caret >= 0:
		c = c.substr(0, caret)      # drop the background half
	c = c.replace("&", "")
	if c.is_empty():
		return ""
	return c.substr(c.length() - 1, 1)

func _qud_color(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return Color.WHITE
	# prefer the palette Qud actually sent; COLORS is only a fallback
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

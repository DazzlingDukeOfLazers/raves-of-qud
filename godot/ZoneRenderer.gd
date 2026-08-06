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
var _noting := true             # whether _note records (off during dynamic-only rebuilds)
var _live_build := false        # true only while building the LIVE zone's static (its
                                # torches register for the _process flicker; neighbours don't)
var _hidden_cell := Vector2i(-9999, -9999)   # a live cell whose creature is not drawn (first-person: the player)
var _player_cell := Vector2i(-9999, -9999)   # the player's cell this snapshot (from data.player), for the world-map "on top" rule
var _placing_player := false                 # true while placing the player's own sprite in the dynamic pass

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
	# The ground plane IS Qud's field in 1:1: unshaded (the per-pixel ambient darkened it to
	# ~(6,30,30)) at the measured field colour, and CLIPPED to the stage rect — Qud's field exists
	# only inside the 80x25 stage; the letterbox around it is the AREA colour (17,33,38), which the
	# env clear provides (see SkyGrade). User mode restores the huge shaded palette-k ground.
	if _ground_mat != null:
		if on:
			_ground_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_ground_mat.albedo_color = QUD_FIELD_1TO1
		else:
			_ground_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if SHADED_WORLD else BaseMaterial3D.SHADING_MODE_UNSHADED
			_ground_mat.albedo_color = _world_bg
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
	_world_map = _zz < 0
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
		_lit_meshes.clear()            # and its connector panels (fences/pipes)
		_wall_cutaway.clear()          # and its wall nodes tracked for camera cutaway
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
			# Gap-fill bg comes from TILECOLOR's ^X (tile-mode truth) — never from
			# ColorString, whose ^ is glyph-mode (see _wall_bg_color's history).
			var bg := _parse_bg(String(obj.get("tilecolor", "")))
			var key := "%s|%s|%s|%s" % [tile, main_c, detail_c, bg]
			if not wall_types.has(key):
				wall_types[key] = {"cells": {}, "tile": tile, "main": main_c, "detail": detail_c, "bg": bg}
			# store the cell's REAL autotile variant, not just "occupied". The
			# variant encodes which neighbours are walls, which is exactly what
			# decides whether the roof draws a border on each edge.
			wall_types[key]["cells"][Vector2i(cx, cy)] = String(obj.get("tile", ""))
			wall_cells[Vector2i(cx, cy)] = true

## Pass 2 for ONE cell — floors + verticals (skip walls). This is the heavy, GPU-touching part
## (texture recolour, sprites, floor-batch entries); the incremental build calls it in chunks.
func _place_cell(cell: Dictionary, offset: Vector2i, wall_cells: Dictionary, skip_creatures: bool) -> void:
	# 1:1 renders EVERYTHING per turn in the dynamic pass (like Qud renders per frame): a
	# frozen ghost bake went stale whenever a liquid sloshed or objects changed (the
	# "Qud shows a watervine, Raves shows water" bug — the bake predated the vine's cell
	# state). Statics contribute nothing in 1:1.
	if _one_to_one:
		return
	var cx := int(cell.get("x", 0)) + offset.x
	var cy := int(cell.get("y", 0)) + offset.y
	var in_wall: bool = wall_cells.has(Vector2i(cx, cy))
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
	var idx := 0
	for obj in cell.get("objs", []):
		var o: Dictionary = obj
		if not _is_prism(o):
			_place_nonwall(o, cx, cy, idx, in_wall, sink, wet, skip_creatures, stair_cell, lf)
		# Creature lights are placed in the DYNAMIC pass so they follow the creature;
		# here (static) we only place fixed lights (sconces, braziers, lit terrain).
		if o.has("lightRadius") and not (skip_creatures and _is_creature(o)):
			_place_light(cx, cy, float(o["lightRadius"]), not _is_creature(o), bool(o.get("onFire", false)))
		idx += 1

# Small lift for the dynamic pass's full-colour floor quads so they cover the static ghost
# quads at the same cell (statics and dynamics share the layer-height scheme otherwise).
var _dyn_lift_1to1 := 0.0

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
func _rebuild_dynamics(cells: Array) -> void:
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
		if Vector2i(cx, cy) == _hidden_cell:
			continue     # first-person hides the player (the camera sits on this cell)
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
				if full_1to1:
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
		for obj in cell.get("objs", []):
			var od: Dictionary = obj
			if not _is_prism(od) and _is_creature(od):
				_place_nonwall(od, cx, cy, idx, false, sink, wet, false, false, lf)
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
	_placing_player = false
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
		if int(cell.get("light", 200)) < 199:   # anything below full Light(200) dims -> full path
			any_dark = true
			break
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
	if _lit_sprites.is_empty() and _lit_meshes.is_empty():
		return
	var frac := {}
	for cell in cells:
		frac[Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))] = _light_frac(cell)
	for e in _lit_sprites:
		var s = e["s"]
		if is_instance_valid(s):
			var lf: float = frac.get(e["cell"], 1.0)
			s.modulate = Color(lf, lf, lf) if lf < 0.999 else Color.WHITE
	for e in _lit_meshes:
		var mi = e["mi"]
		if is_instance_valid(mi) and mi.material_override != null:
			var lf: float = frac.get(e["cell"], 1.0)
			mi.material_override.albedo_color = Color(lf, lf, lf)

## Restore full brightness to the tracked static sprites/meshes — called once when a zone
## goes from having dark cells to fully lit (e.g. dawn), since _relight is then skipped.
func _reset_static_light() -> void:
	for e in _lit_sprites:
		if is_instance_valid(e["s"]):
			e["s"].modulate = Color.WHITE
	for e in _lit_meshes:
		if is_instance_valid(e["mi"]) and e["mi"].material_override != null:
			e["mi"].material_override.albedo_color = Color.WHITE

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
	if _ib_active and id == _ib_id:
		_ib_abort()             # its subtree is about to be freed; don't build into a dangling node
	if _static_zones.has(id):
		_static_zones[id].free()
		_static_zones.erase(id)

func _drop_all_static() -> void:
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
		if not _static_zones.has(id):
			var sub := Node3D.new()
			_remembered_root.add_child(sub)
			_static_zones[id] = sub
			_bank = sub
			_noting = false     # neighbours aren't inspected; don't touch _placed
			var wt := {}
			_build_zone(nb.get("cells", []), Vector2i.ZERO, true, wt)   # local coords
			_rebuild_walls(wt)     # _bank set -> into the subtree, no clear
			_flush_floor_batch()   # batched floor MultiMeshes into the neighbour subtree
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
		# Hide neighbours the fog fully hides anyway. Nearest planar distance from the live zone's
		# origin corner to this neighbour's cell box [o .. o+dims], plus the vertical level gap.
		var nx: float = clampf(0.0, float(o.x), float(o.x) + _live_w)
		var nz: float = clampf(0.0, float(o.y), float(o.y) + _live_h)
		var vgap: float = absf(float(dz) * level_height)
		var near: float = sqrt(nx * nx + nz * nz + vgap * vgap)
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

	var flame := Sprite3D.new()
	flame.texture = _fire_tex if on_fire else _flame_tex
	flame.pixel_size = 0.006 if on_fire else 0.03         # small drawn flame (~0.4 tile), sits ABOVE the logs
	flame.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	flame.shaded = false
	flame.transparent = true
	# on-fire: ALPHA (a solid flame that reads on any background); else ADDITIVE (a glowing torch core).
	flame.material_override = _fx_material_alpha(flame.texture) if on_fire else _fx_material(_flame_tex)
	flame.position = Vector3(cx, 0.55 if on_fire else 0.7, cy)   # sits just above the campfire's pixel logs
	lp.add_child(flame)

	# Rising smoke plume. Only the LIVE zone gets emitters (keeps the particle count bounded). A torch's
	# smoke is a NIGHT effect (its flame fades by day). A FIRE (campfire) burns day + night, so its smoke
	# emits always — `fire_smoke` tells set_daylight not to switch it off at dawn.
	if _live_build:
		var entry := {"glow": glow, "flame": flame, "energy": 1.0, "on_fire": on_fire}
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
		flame.transparency = 0.0 if on_fire else clampf(1.0 - _flame_mul(), 0.0, 1.0)

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
	return bool(Settings.get_value("fx_particles", false)) and _daylight < SMOKE_OFF_SUN

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
	if _one_to_one:
		return   # 1:1: no particle motes — Qud draws only the glowfish tile
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
	if _one_to_one:
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
				(m["s"] as Sprite3D).position = Vector3(x * ct - z * st, y, x * st + z * ct)


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

func _place_connector(tile: String, main_c: String, detail_c: String, cx: int, cy: int, dirs: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0, light_frac := 1.0) -> void:
	if dirs == "":
		_fence_half(cx, cy, "post", tile, main_c, detail_c, h, fill, y_center, light_frac)
		return
	for d in dirs:
		_fence_half(cx, cy, d, tile, main_c, detail_c, h, fill, y_center, light_frac)

# One upright half-panel from the cell centre out to the edge in direction d, using
# the family's E-W elevation art. Adjacent cells' halves meet at the shared edge,
# so runs are continuous and corners form a clean L. Used for every directional
# family: picket fences, pipes, and tent walls (which differ only in height).
func _fence_half(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String, h := FENCE_H, fill := Fill.NONE, y_center := -1.0, light_frac := 1.0) -> void:
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

## World-map water families (svylake, river/lake, duskwaters, marsh). On the parasang map these
## have no real liquid flags — the cells are abstractions — so we key off the tile family. Water
## stays FLAT (see the world-map card branch): a standing blue card reads as a wall. Mangrove is
## excluded: it's trees standing IN water, so it keeps the upright card.
const WM_WATER_KEYS := ["river", "lake", "water", "ocean", "marsh", "duskwater"]
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

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool, sink := 0.0, wet := false, skip_creatures := false, stair_cell := false, light_frac := 1.0) -> void:
	# Static builds exclude creatures (they render per step in _rebuild_dynamics);
	# remembered zones drop them entirely (they've wandered off since last live).
	if skip_creatures and _is_creature(obj):
		return
	var tile := String(obj.get("tile", ""))
	# Per-object gap-fill bg: the ^X of TILECOLOR (Starship walls fill gold '^W',
	# HangarWall bright '^Y'; metal walls carry no TileColor ^ and keep world bg).
	_wall_bg = _parse_bg(String(obj.get("tilecolor", "")))

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
	# EXCEPT an occluding wall whose TILECOLOR carries a ^X background: Qud fills
	# its gaps with that colour (Starship family '^W' gold frames, HangarWall
	# '^Y'; checker evidence StarshipGeometricWallGrey_goldframe_*). Plain walls
	# keep transparent gaps — their Qud render shows the terrain through, and
	# 213 bright-baseline walls pass on exactly that behaviour.
	var wall_fill := Fill.ALL if (_wall_bg != "" and bool(obj.get("occluding", false))) else Fill.NONE
	var tex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj), _color_key(obj),
		_fill_for(tile, wall_fill))

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
				_fill_for(tile, Fill.ALL if bool(obj.get("occluding", false)) else Fill.NONE), -1.0, light_frac)
			_note(cx, cy, idx, "connector panels [%s] h=%.2f (user verdict)" % [axis, vh], vh * 0.5)
			return

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
			Fill.ALL if csolid else Fill.NONE, cyc, light_frac)
		_note(cx, cy, idx, "connector panels [%s] h=%.2f (stood up)" % [
			"post" if cd == "" else cd, cph], cyc)
		return

	# Qud's painted ground layer is flat by default — dirt, gravel, cracked earth.
	# But vegetation in that layer is cover you stand among, not a texture you walk
	# on, so it reads far better standing up. Route it to the billboard path.
	var upright_ground: bool = bool(obj.get("ground", false)) and _is_vegetation(tile)
	if verdict == "billboard":
		upright_ground = true        # force it off the floor path
	var as_floor: bool = _flat_2d or (layer <= FLOOR_LAYER_MAX and not upright_ground) or verdict == "floor"

	if as_floor:
		if in_wall:
			_note(cx, cy, idx, "skipped(under wall)", 0.0)
			return  # hidden under a wall; don't bother
		if stair_cell:
			_note(cx, cy, idx, "skipped(floor over stair opening)", 0.0)
			return  # would cap the shaft; the frame lip is the floor here
		# Floors were one MeshInstance3D per cell — 2000 draw calls on the world map, which
		# tanked the framerate. Batch them by material into a MultiMesh instead (flushed at the
		# end of the build): one draw call per tile type. Floors are static, so this is free.
		var y := FLOOR_Y + layer * LAYER_LIFT + idx * TIEBREAK + _dyn_lift_1to1
		var fmat: Material
		var fscale := Vector3.ONE
		var fkind := "floor"
		if tex != null:
			fmat = _mesh_material(tile, main_c, detail_c, tex)
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
		_note(cx, cy, idx, fkind, y)
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
			_place_connector(tile, main_c, detail_c, cx, cy, dirs, ph, pfill, yc, light_frac)
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
				_add_glow(s, btex)              # crisp bioluminescent bloom (glowfish, glowpad, tagged tiles)
			_track(s)
			# STATIC plant/scenery billboard (tree, brinestalk): register it to be dimmed by
			# its cell's light EACH TURN (creatures get modulate directly; static sprites don't,
			# so they'd stay lit at night). Glowing things emit light — leave them bright.
			if _live_build and not glowing:
				_lit_sprites.append({"s": s, "cell": Vector2i(cx, cy)})
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
		cy_center = (WATER_LINE_Y if sink > 0.0 else 0.0) + PIXEL_SIZE * shown * 0.5
	s.position = Vector3(cx, cy_center, cy)

# --- greedy-meshed walls ----------------------------------------------------

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
		var core_mat := _wall_core_material(_live_build)
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
			_track_wall(k, core)

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
					rmi.material_override = _wall_skin_material()
					rmi.position = Vector3(k.x, 0.0, k.y)
					_wall_parent().add_child(rmi)
					_track_wall(k, rmi)
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
	mi.material_override = _wall_skin_material()
	mi.position = Vector3(k.x, 0.0, k.y)
	mi.rotation = Vector3(0, deg_to_rad(deg), 0)
	_wall_parent().add_child(mi)
	_track_wall(k, mi)

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

func _wall_core_material(fade := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = _wall_recess_color()
	m.roughness = 0.95
	if fade:   # live zone only — fade-capable so the core dissolves with the skin in the cutaway
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
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
	# _wall_bg keys the FILL colour (gap pixels paint _wall_bg_color()), so it
	# must key the cache too — a gold-fill Starship texture must not be served
	# for a world-fill wall that shares tile+colours.
	var key := "%s|%s|%d|%s" % [tile, ckey, fill, _wall_bg]
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
		for ty in th:
			for tx in tw:
				var tp := mask.get_pixel(tx, ty)
				var tlum := (tp.r + tp.g + tp.b) / 3.0
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
	_apply_wm_orient()   # world-map cards lie flat in top-down, stand up again otherwise (wins over the loop above)

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
	# AnimatedMaterialGeneric (data-driven tile cycler — Phasic Screw's helix):
	# the wire ships the part's spec "len|frame=tile|..."; exactly one frame's
	# tile is visible at a time, keyed to the shared 60fps Qud clock.
	var af := String(win.get("animFrames", ""))
	if af != "":
		var fparts := af.split("|")
		var alen := maxi(int(fparts[0]), 1)
		var sched: Array = []
		for fi in range(1, fparts.size()):
			var kv := fparts[fi].split("=")
			if kv.size() != 2:
				continue
			var ftex := _colored_tex_rgb(String(kv[1]), _obj_main(win), _obj_detail(win),
				"anim~f" + String(kv[1]) + "~" + _color_key(win), _fill_for(String(kv[1]), Fill.NONE))
			if ftex != null:
				sched.append({"f": int(kv[0]), "node": _overlay_quad(ftex, cx, cy, y_over, flip)})
		if sched.size() > 1:
			_anim_items.append({"kind": "frames", "len": alen, "sched": sched})
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
			# AnimatedMaterialGeneric: the schedule maps a frame threshold to a
			# tile; the ACTIVE entry is the last whose threshold <= the part's
			# clock (Qud frames, part-length cycle).
			var ff := int(ms * 0.06) % int(it["len"])
			var sched: Array = it["sched"]
			var active := 0
			for si in sched.size():
				if ff >= int(sched[si]["f"]):
					active = si
			for si in sched.size():
				var fn := sched[si]["node"] as MeshInstance3D
				if is_instance_valid(fn):
					fn.visible = si == active
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

func _flush_floor_batch() -> void:
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
		_spawn_parent().add_child(mmi)
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

func _obj_main(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	return _qud_color(_pick_color_string(obj))

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
	return _qud_color(d)

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

func _qud_color(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return Color.WHITE
	# prefer the palette Qud actually sent; COLORS is only a fallback
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

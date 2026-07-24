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
const SINK_SWIM := 0.72    # ... and swimming depth

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
var _overrides_raw := "?"   # last overrides.json text, to skip re-parsing

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
var _glow_tex: Texture2D
var _flame_tex: Texture2D
var _lights: Array = []           # [{glow, flame, x, z, base_energy}]

var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _floor_pool: Array[MeshInstance3D] = []
var _label_pool: Array[Label3D] = []

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
	_glow_tex = _make_radial(64, Color(1.0, 0.62, 0.25), 1.0)   # warm pool of light
	_flame_tex = _make_radial(32, Color(1.0, 0.80, 0.35), 1.6)  # tighter, brighter core

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

func render_snapshot(data: Dictionary) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))
	_placed.clear()

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

	for n in _active:
		n.visible = false
		if n is Sprite3D: _sprite_pool.append(n)
		elif n is Label3D: _label_pool.append(n)
		elif n is MeshInstance3D:
			if n.mesh == _fence_quad: _fence_pool.append(n)
			else: _floor_pool.append(n)
	_active.clear()

	for c in _light_root.get_children():
		c.queue_free()
	_lights.clear()

	_load_overrides()

	var cells = data.get("cells", [])

	# pass 1: group wall cells by TYPE (family + colours + background)
	var wall_types := {}   # key -> {cells, tile, main, detail, bg}
	var wall_cells := {}
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
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
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var in_wall: bool = wall_cells.has(Vector2i(cx, cy))
		var sink := _cell_sink(cell)
		var wet: bool = bool(cell.get("wade", false)) or bool(cell.get("swim", false))
		var idx := 0
		for obj in cell.get("objs", []):
			if not _is_prism(obj):
				_place_nonwall(obj, cx, cy, idx, in_wall, sink, wet)
			if obj.has("lightRadius"):
				_place_light(cx, cy, float(obj["lightRadius"]))
			idx += 1

	_rebuild_walls(wall_types)

# --- introspection (for CellInspector) --------------------------------------

func _note(cx: int, cy: int, idx: int, kind: String, y: float) -> void:
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
		return SINK_SWIM
	if bool(cell.get("wade", false)):
		return SINK_WADE
	return 0.0

# --- user overrides ----------------------------------------------------------

## A tile path reduced to its family, so one verdict covers every variant:
## `sw_waterwheel_1` and `_3`, `wall_rock-10100010` and every other bitmask.
func tile_family(tile: String) -> String:
	var t := tile.replace("\\", "/").get_file().get_basename().to_lower()
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
	_overrides.clear()
	_fill_overrides.clear()
	_position_overrides.clear()
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
	return "" if parts.is_empty() else "  ".join(parts)

func _override_for(tile: String) -> String:
	if _overrides.is_empty() or tile == "":
		return ""
	return String(_overrides.get(tile_family(tile), ""))

# --- torch / fire light ------------------------------------------------------

## An additive warm glow on the ground (the "light") plus a small flickering flame
## above the sconce. Qud's radius is in cells; 1 cell == 1 world unit.
func _place_light(cx: int, cy: int, radius: float) -> void:
	var glow := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	var d: float = maxf(2.0, radius * 1.6)   # pool a bit wider than the sconce
	gm.size = Vector2(d, d)
	glow.mesh = gm
	glow.position = Vector3(cx, FLOOR_Y + 0.01, cy)
	glow.material_override = _fx_material(_glow_tex)
	_light_root.add_child(glow)

	var flame := Sprite3D.new()
	flame.texture = _flame_tex
	flame.pixel_size = 0.03
	flame.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	flame.shaded = false
	flame.transparent = true
	flame.material_override = _fx_material(_flame_tex)   # additive
	flame.position = Vector3(cx, 0.7, cy)                # above the sconce
	_light_root.add_child(flame)

	_lights.append({"glow": glow, "flame": flame, "energy": 1.0})

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

## Flicker: jitter each light's brightness a little every frame, so torches read
## as fire rather than steady lamps. Cheap — modulate the additive quads' alpha.
func _process(_dt: float) -> void:
	for L in _lights:
		var e: float = 0.75 + randf() * 0.4        # 0.75..1.15
		L["energy"] = lerpf(L["energy"], e, 0.35)   # smoothed, so it shimmers not strobes
		var a: float = L["energy"]
		(L["glow"] as MeshInstance3D).transparency = clampf(1.0 - a * 0.6, 0.0, 1.0)
		var fs: float = 0.9 + a * 0.25
		var flame := L["flame"] as Sprite3D
		flame.scale = Vector3(fs, fs * (0.95 + randf() * 0.2), fs)
		flame.modulate = Color(1, 1, 1, clampf(a, 0.0, 1.0))

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
	_active.append(mi)

func _take_fence() -> MeshInstance3D:
	if _fence_pool.size() > 0:
		return _fence_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _fence_quad
	add_child(mi)
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
const UPRIGHT_GROUND := ["grass", "weed", "flower", "shrub", "moss", "fern"]

func _is_vegetation(tile: String) -> bool:
	var name := tile.replace("\\", "/").get_file().to_lower()
	for word in UPRIGHT_GROUND:
		if name.contains(word):
			return true
	return false

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool, sink := 0.0, wet := false) -> void:
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
			_active.append(d)
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
		_active.append(f)
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
			var submerged: bool = sink > 0.0 and bool(obj.get("sinks", false))
			_seat(s, btex, tile, cx, cy, sink if submerged else 0.0, position_for(tile) == "float")
			s.visible = true
			_active.append(s)
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
		_active.append(l)
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
	for c in _wall_root.get_children():
		c.queue_free()
	for key in wall_types:
		var t = wall_types[key]
		_wall_tile = t["tile"]; _wall_main = t["main"]; _wall_detail = t["detail"]; _wall_bg = t["bg"]
		var cells: Dictionary = t["cells"]


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
					_wall_root.add_child(rmi)
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
	_wall_root.add_child(mi)

# --- voxel wall caps --------------------------------------------------------

const VOXEL_STEP := 0.075   # world height per colour-rank level (caps)
const SIDE_STEP := 0.06     # outward protrusion per colour-rank level (sides)
var _voxel_cache := {}      # cap key -> ArrayMesh
var _voxel_mat: StandardMaterial3D

## Voxel relief mesh for a wall variant's cap, centred on its cell (x,z in
## -0.5..0.5, rising from WALL_H). Each pixel is a column; its height is the RANK
## of its colour by pixel count — the commonest colour (usually the filled
## background) is the base, rarer colours (the border/detail) stand proud, which
## is the "transparent is deepest, each colour extrudes" idea as real geometry.
## Per-pixel height LEVEL grid: rank each colour by pixel count (commonest -> 0,
## rarest -> highest), so the border/detail stands proudest and the filled
## background is the base. Shared by cap and side voxels.
func _rank_levels(img: Image) -> Array:
	var w := img.get_width()
	var h := img.get_height()
	var counts := {}
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y).to_html(false)
			counts[c] = int(counts.get(c, 0)) + 1
	var order := counts.keys()
	order.sort_custom(func(a, b): return int(counts[a]) > int(counts[b]))
	var level := {}
	for i in order.size():
		level[order[i]] = i
	var lev := []
	for y in h:
		var row := []
		for x in w:
			row.append(int(level[img.get_pixel(x, y).to_html(false)]))
		lev.append(row)
	return lev

## Voxel relief mesh for a wall variant's cap, centred on its cell, rising from
## WALL_H. Cached per variant+colour, built once and instanced per cell.
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
	var lev := _rank_levels(img)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ps := 1.0 / w
	for y in h:
		for x in w:
			var l: int = lev[y][x]
			var col := img.get_pixel(x, y)
			var y_top: float = WALL_H + l * VOXEL_STEP
			var x0 := -0.5 + x * ps
			var x1 := x0 + ps
			var z0 := -0.5 + y * ps
			var z1 := z0 + ps
			_vc_top(st, x0, x1, z0, z1, y_top, col)
			# vertical steps down to the lower of each neighbour (or the base at a
			# cell edge), so raised pixels show their sides and cast shadows
			_vc_step(st, x, y, l, lev, w, h, x0, x1, z0, z1, y_top, col)
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
	var lev := _rank_levels(img)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pw := 1.0 / w
	var ph := WALL_H / h
	for y in h:
		for x in w:
			var l: int = lev[y][x]
			var col := img.get_pixel(x, y)
			var d: float = 0.5 + l * SIDE_STEP           # outward from the cell edge
			var xa := -0.5 + x * pw                       # along the edge
			var xb := xa + pw
			var yt: float = WALL_H - y * ph               # row 0 = top of the wall
			var yb: float = yt - ph
			# front face (normal +Z)
			for p in [Vector3(xa, yb, d), Vector3(xb, yb, d), Vector3(xb, yt, d),
					  Vector3(xa, yb, d), Vector3(xb, yt, d), Vector3(xa, yt, d)]:
				st.set_normal(Vector3(0, 0, 1)); st.set_color(col); st.add_vertex(p)
			# side steps down to a shallower neighbour (or the base at grid edges)
			_side_step(st, x, y, l, lev, w, h, xa, xb, yt, yb, d, col)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	_side_cache[key] = mesh
	return mesh

## Vertical/horizontal step faces around a protruding side pixel, only toward a
## shallower neighbour, from that neighbour's depth out to this pixel's depth.
func _side_step(st: SurfaceTool, x: int, y: int, l: int, lev: Array, w: int, h: int,
		xa: float, xb: float, yt: float, yb: float, d: float, col: Color) -> void:
	for dir in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nx: int = x + dir[0]
		var ny: int = y + dir[1]
		var nl := -1
		if nx >= 0 and nx < w and ny >= 0 and ny < h:
			nl = int(lev[ny][nx])
		if nl >= l:
			continue
		var d0: float = 0.5 + maxi(nl, 0) * SIDE_STEP
		var a: Vector3; var b: Vector3; var nrm: Vector3
		if dir == [1, 0]:      a = Vector3(xb, yb, 0); b = Vector3(xb, yt, 0); nrm = Vector3(1, 0, 0)
		elif dir == [-1, 0]:   a = Vector3(xa, yt, 0); b = Vector3(xa, yb, 0); nrm = Vector3(-1, 0, 0)
		elif dir == [0, 1]:    a = Vector3(xb, yb, 0); b = Vector3(xa, yb, 0); nrm = Vector3(0, -1, 0)
		else:                  a = Vector3(xa, yt, 0); b = Vector3(xb, yt, 0); nrm = Vector3(0, 1, 0)
		var af := Vector3(a.x, a.y, d); var bf := Vector3(b.x, b.y, d)
		var a0 := Vector3(a.x, a.y, d0); var b0 := Vector3(b.x, b.y, d0)
		for p in [a0, bf, af, a0, b0, bf]:
			st.set_normal(nrm); st.set_color(col); st.add_vertex(p)

## Shared material for voxel caps:

## Shared material for voxel caps: shaded, colour comes from the per-pixel vertex
## colour, so one material covers every wall type and the sun shades the relief.
func _voxel_material() -> StandardMaterial3D:
	if _voxel_mat != null:
		return _voxel_mat
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
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

## Vertical faces on the four sides of a pixel column, only where the neighbour
## (or the cell edge -> base) is lower, from that neighbour's height up to y_top.
func _vc_step(st: SurfaceTool, x: int, y: int, l: int, lev: Array, w: int, h: int,
		x0: float, x1: float, z0: float, z1: float, y_top: float, c: Color) -> void:
	var dirs := [[1, 0], [-1, 0], [0, 1], [0, -1]]
	for d in dirs:
		var nx: int = x + d[0]
		var ny: int = y + d[1]
		var nl := -1                                   # off-cell -> base (WALL_H)
		if nx >= 0 and nx < w and ny >= 0 and ny < h:
			nl = int(lev[ny][nx])
		if nl >= l:
			continue
		var y_bot: float = WALL_H + maxi(nl, 0) * VOXEL_STEP
		var a: Vector3; var b: Vector3
		if d == [1, 0]:    a = Vector3(x1, 0, z0); b = Vector3(x1, 0, z1)
		elif d == [-1, 0]: a = Vector3(x0, 0, z1); b = Vector3(x0, 0, z0)
		elif d == [0, 1]:  a = Vector3(x1, 0, z1); b = Vector3(x0, 0, z1)
		else:              a = Vector3(x0, 0, z0); b = Vector3(x1, 0, z0)
		var at := Vector3(a.x, y_top, a.z); var bt := Vector3(b.x, y_top, b.z)
		var ab := Vector3(a.x, y_bot, a.z); var bb := Vector3(b.x, y_bot, b.z)
		var nrm := Vector3(d[0], 0, d[1])
		for p in [ab, bt, at, ab, bb, bt]:
			st.set_normal(nrm); st.set_color(c); st.add_vertex(p)

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
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
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

func _take_sprite() -> Sprite3D:
	var s: Sprite3D
	if _sprite_pool.size() > 0:
		s = _sprite_pool.pop_back()
	else:
		s = Sprite3D.new()
		s.pixel_size = PIXEL_SIZE
		s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		s.shaded = false
		s.transparent = true
		s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		add_child(s)
	# reset per take — fence panels and submerged actors override these, normal
	# sprites need the defaults back
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	s.rotation = Vector3.ZERO
	s.region_enabled = false
	s.flip_h = false
	s.flip_v = false
	return s

func _take_floor() -> MeshInstance3D:
	if _floor_pool.size() > 0: return _floor_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _plane
	add_child(mi)
	return mi

func _take_label() -> Label3D:
	if _label_pool.size() > 0: return _label_pool.pop_back()
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = 0.02
	l.font_size = 64
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	add_child(l)
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

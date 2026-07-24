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
const FENCE_H := 0.6  # standing height of fence/pipe panels (content, sat on ground)
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
enum Fill { NONE, ALL, INTERIOR }

# Widest horizontal transparent run still treated as a seam in the art rather
# than a genuine opening. Tuned against sw_chest (1px channels beside its bands,
# must fill) vs sw_dromad (10px gap between its legs, must not).
const MAX_SLOT_PX := 2

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
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = _world_bg
	_ground_mat = gm
	ground.material_override = gm
	add_child(ground)

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
			wall_types[key]["cells"][Vector2i(cx, cy)] = true
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

## How many transparent pixels this tile's art encloses — the ones repainted as
## background. 0 means the silhouette has no interior gaps.
func tile_interior_px(tile: String) -> int:
	var n := 0
	for row in _interior(tile):
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

func _is_prism(obj: Dictionary) -> bool:
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
func _panel_height(obj: Dictionary) -> float:
	return WALL_H if bool(obj.get("occluding", false)) else FENCE_H

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

func _place_connector(tile: String, main_c: String, detail_c: String, cx: int, cy: int, dirs: String, h := FENCE_H, fill := Fill.NONE) -> void:
	if dirs == "":
		_fence_half(cx, cy, "post", tile, main_c, detail_c, h, fill)
		return
	for d in dirs:
		_fence_half(cx, cy, d, tile, main_c, detail_c, h, fill)

# One upright half-panel from the cell centre out to the edge in direction d, using
# the family's E-W elevation art. Adjacent cells' halves meet at the shared edge,
# so runs are continuous and corners form a clean L. Used for every directional
# family: picket fences, pipes, and tent walls (which differ only in height).
func _fence_half(cx: int, cy: int, d: String, tile: String, main_c: String, detail_c: String, h := FENCE_H, fill := Fill.NONE) -> void:
	var mi := _take_fence()
	var half := "r" if (d == "e" or d == "s") else "l"
	mi.material_override = _fence_material(_family_ew(tile), main_c, detail_c, half, fill)
	mi.scale = Vector3(0.5, h, 1.0)
	var pos := Vector3(cx, h * 0.5, cy)
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
		if fill == Fill.NONE:
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

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool, sink := 0.0, wet := false) -> void:
	var tile := String(obj.get("tile", ""))
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

	if layer <= FLOOR_LAYER_MAX:
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
		# directional connectors (fences/pipes: family_<dirs>) -> orientation-locked
		# standing panels, not billboards. Gated on wall so creatures don't match.
		var dirs = _connector_dirs(tile) if bool(obj.get("wall", false)) else null
		if dirs != null:
			# sight-blocking connectors stand tall AND read as solid (background
			# filled); see-through ones stay low and open.
			var solid := bool(obj.get("occluding", false))
			var pfill: int = Fill.ALL if solid else Fill.NONE
			var ph := _panel_height(obj)
			_place_connector(tile, main_c, detail_c, cx, cy, dirs, ph, pfill)
			_note(cx, cy, idx, "connector panels [%s] h=%.2f%s" % [
				"post" if dirs == "" else dirs, ph, " filled-bg" if solid else ""], ph * 0.5)
		else:
			# Gaps *enclosed* by the art read as the cell background, the way Qud
			# draws them; everything outside the silhouette stays see-through.
			var btex := _colored_tex_rgb(tile, _obj_main(obj), _obj_detail(obj),
				_color_key(obj), Fill.INTERIOR)
			if btex == null:
				btex = tex
			var s := _take_sprite()
			s.texture = btex
			s.flip_h = bool(obj.get("hflip", false))
			s.flip_v = bool(obj.get("vflip", false))
			var submerged: bool = sink > 0.0 and bool(obj.get("sinks", false))
			_seat(s, btex, tile, cx, cy, sink if submerged else 0.0)
			s.visible = true
			_active.append(s)
			var gaps := tile_interior_px(tile)
			_note(cx, cy, idx, "%s, %s" % [
				("billboard(submerged %d%%)" % roundi(sink * 100.0)) if submerged else "billboard",
				("%d px enclosed gap -> bg" % gaps) if gaps > 0 else "no enclosed gaps"],
				s.position.y)
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
func _seat(s: Sprite3D, tex: ImageTexture, tile: String, cx: int, cy: int, sink: float) -> void:
	var h := tex.get_height()
	var vr := _opaque_v(_mask(tile))
	var top := vr.x * h
	var shown: float = max(1.0, vr.y * h * (1.0 - sink))
	var base := WATER_LINE_Y if sink > 0.0 else 0.0
	s.region_enabled = true
	s.region_rect = Rect2(0, top, tex.get_width(), shown)
	s.position = Vector3(cx, base + PIXEL_SIZE * shown * 0.5, cy)

# --- greedy-meshed walls ----------------------------------------------------

func _parse_bg(color: String) -> String:
	# "&r^w" -> "w"  (the background colour); "" if no ^ component
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
	# one greedy-meshed MeshInstance per wall type, each with its own tile + colours
	for key in wall_types:
		var t = wall_types[key]
		_wall_tile = t["tile"]; _wall_main = t["main"]; _wall_detail = t["detail"]; _wall_bg = t["bg"]
		var mesh := _build_wall_mesh(t["cells"])
		if mesh.get_surface_count() >= 1:
			mesh.surface_set_material(0, _wall_top_material())
		if mesh.get_surface_count() >= 2:
			mesh.surface_set_material(1, _wall_side_material())
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		_wall_root.add_child(mi)

func _build_wall_mesh(wall_set: Dictionary) -> ArrayMesh:
	var st_top := SurfaceTool.new(); st_top.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_side := SurfaceTool.new(); st_side.begin(Mesh.PRIMITIVE_TRIANGLES)

	var minx := 1 << 30; var maxx := -(1 << 30)
	var minz := 1 << 30; var maxz := -(1 << 30)
	for k in wall_set:
		minx = min(minx, k.x); maxx = max(maxx, k.x)
		minz = min(minz, k.y); maxz = max(maxz, k.y)

	# top faces: greedy 2D rectangles at y = WALL_H
	var visited := {}
	for z in range(minz, maxz + 1):
		for x in range(minx, maxx + 1):
			var key := Vector2i(x, z)
			if not wall_set.has(key) or visited.has(key):
				continue
			var x1 := x
			while wall_set.has(Vector2i(x1 + 1, z)) and not visited.has(Vector2i(x1 + 1, z)):
				x1 += 1
			var z1 := z
			var grow := true
			while grow:
				var nz := z1 + 1
				for xx in range(x, x1 + 1):
					if not wall_set.has(Vector2i(xx, nz)) or visited.has(Vector2i(xx, nz)):
						grow = false
						break
				if grow: z1 = nz
			for xx in range(x, x1 + 1):
				for zz in range(z, z1 + 1):
					visited[Vector2i(xx, zz)] = true
			_quad_top(st_top, x, x1, z, z1)

	# side faces: exposed edges merged into runs
	_sides_x(st_side, wall_set, minx, maxx, minz, maxz, 1)
	_sides_x(st_side, wall_set, minx, maxx, minz, maxz, -1)
	_sides_z(st_side, wall_set, minx, maxx, minz, maxz, 1)
	_sides_z(st_side, wall_set, minx, maxx, minz, maxz, -1)

	var mesh := ArrayMesh.new()
	st_top.commit(mesh)
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
			var region := iso_mask.get_region(Rect2i(0, 0, w, min(w, iso_mask.get_height())))
			tex = _recolor_image(region, _wall_main, _wall_detail, Fill.ALL)
		else:
			var mask := _mask(_wall_tile)  # fallback: synthetic frame on the interior checker
			if mask != null:
				var w := mask.get_width()
				var region := mask.get_region(Rect2i(0, 0, w, min(w, mask.get_height())))
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
			if h > w:
				var region := mask.get_region(Rect2i(0, w, w, h - w))
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
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true   # baked per-face shade multiplies the rock
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		m.albedo_color = _qud_color(_wall_main)
	return m

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
	var inner = _interior(tile) if fill == Fill.INTERIOR else null
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
				var paint: bool = fill == Fill.ALL or (fill == Fill.INTERIOR
					and inner != null and y < inner.size() and bool(inner[y][x]))
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

func _qud_color(code: String) -> Color:
	var c := code.strip_edges()
	if c.is_empty():
		return Color.WHITE
	var ch := c.substr(c.length() - 1, 1)
	# prefer the palette Qud actually sent; COLORS is only a fallback
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

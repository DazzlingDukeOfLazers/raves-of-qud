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
const PIXEL_SIZE := 0.042
const FLOOR_Y := 0.02
const LAYER_STEP := 0.02

var _tiles_dir := ""
var _mask_cache := {}       # fname -> Image
var _tex_cache := {}        # "tile|main|detail|fill" -> ImageTexture
var _texmat_cache := {}     # key -> StandardMaterial3D (floors)
var _colmat_cache := {}     # color html -> StandardMaterial3D

var _plane: PlaneMesh
var _wall_mi: MeshInstance3D   # single merged wall mesh, rebuilt per snapshot

# collected per snapshot for the wall mesh
var _wall_tile := ""
var _wall_main := ""
var _wall_detail := ""

var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _floor_pool: Array[MeshInstance3D] = []
var _label_pool: Array[Label3D] = []

func _ready() -> void:
	_plane = PlaneMesh.new()
	_plane.size = Vector2(CELL, CELL)
	_wall_mi = MeshInstance3D.new()
	add_child(_wall_mi)

func render_snapshot(data: Dictionary) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))

	for n in _active:
		n.visible = false
		if n is Sprite3D: _sprite_pool.append(n)
		elif n is Label3D: _label_pool.append(n)
		elif n is MeshInstance3D: _floor_pool.append(n)
	_active.clear()

	var cells = data.get("cells", [])

	# pass 1: collect wall cells (+ a representative rock colour/tile)
	var wall_set := {}
	_wall_tile = ""; _wall_main = ""; _wall_detail = ""
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		for obj in cell.get("objs", []):
			if bool(obj.get("wall", false)):
				wall_set[Vector2i(cx, cy)] = true
				if _wall_tile == "":
					_wall_tile = _canon_wall_tile(String(obj.get("tile", "")))
					_wall_main = String(obj.get("tilecolor", obj.get("color", "")))
					_wall_detail = String(obj.get("detail", ""))

	# pass 2: floors + verticals (skip walls; they're in the merged mesh)
	for cell in cells:
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var in_wall: bool = wall_set.has(Vector2i(cx, cy))
		var idx := 0
		for obj in cell.get("objs", []):
			if not bool(obj.get("wall", false)):
				_place_nonwall(obj, cx, cy, idx, in_wall)
			idx += 1

	_rebuild_walls(wall_set)

func _place_nonwall(obj: Dictionary, cx: int, cy: int, idx: int, in_wall: bool) -> void:
	var tile := String(obj.get("tile", ""))
	var main_c := String(obj.get("tilecolor", ""))
	if main_c == "": main_c = String(obj.get("color", ""))
	var detail_c := String(obj.get("detail", ""))
	var layer := int(obj.get("layer", 99))
	var tex := _colored_tex(tile, main_c, detail_c)

	if layer <= FLOOR_LAYER_MAX:
		if in_wall:
			return  # hidden under a wall; don't bother
		var f := _take_floor()
		if tex != null:
			f.material_override = _mesh_material(tile, main_c, detail_c, tex)
			f.scale = Vector3.ONE
		else:
			f.material_override = _color_material(_qud_color(String(obj.get("color", ""))))
			f.scale = Vector3(0.5, 1.0, 0.5)
		f.position = Vector3(cx, FLOOR_Y + idx * 0.005, cy)
		f.visible = true
		_active.append(f)
	elif tex != null:
		var s := _take_sprite()
		s.texture = tex
		s.position = Vector3(cx, PIXEL_SIZE * tex.get_height() * 0.5, cy)
		s.visible = true
		_active.append(s)
	else:
		var l := _take_label()
		l.text = String(obj.get("glyph", "?"))
		l.modulate = _qud_color(String(obj.get("color", "")))
		l.position = Vector3(cx, 0.5 + idx * LAYER_STEP, cy)
		l.visible = true
		_active.append(l)

# --- greedy-meshed walls ----------------------------------------------------

func _rebuild_walls(wall_set: Dictionary) -> void:
	if wall_set.is_empty():
		_wall_mi.mesh = null
		return
	_wall_mi.mesh = _build_wall_mesh(wall_set)
	_wall_mi.material_override = _wall_material()

func _build_wall_mesh(wall_set: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

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
			_quad_top(st, x, x1, z, z1)

	# side faces: exposed edges merged into runs
	_sides_x(st, wall_set, minx, maxx, minz, maxz, 1)
	_sides_x(st, wall_set, minx, maxx, minz, maxz, -1)
	_sides_z(st, wall_set, minx, maxx, minz, maxz, 1)
	_sides_z(st, wall_set, minx, maxx, minz, maxz, -1)

	return st.commit()

func _v(st: SurfaceTool, p: Vector3, n: Vector3, uv: Vector2) -> void:
	st.set_normal(n)
	st.set_uv(uv)
	st.add_vertex(p)

func _quad_top(st: SurfaceTool, x0: int, x1: int, z0: int, z1: int) -> void:
	var ax := x0 - 0.5; var bx := x1 + 0.5
	var az := z0 - 0.5; var bz := z1 + 0.5
	var y := WALL_H
	var uu := float(x1 - x0 + 1); var vv := float(z1 - z0 + 1)
	var n := Vector3.UP
	_v(st, Vector3(ax, y, az), n, Vector2(0, 0))
	_v(st, Vector3(bx, y, bz), n, Vector2(uu, vv))
	_v(st, Vector3(bx, y, az), n, Vector2(uu, 0))
	_v(st, Vector3(ax, y, az), n, Vector2(0, 0))
	_v(st, Vector3(ax, y, bz), n, Vector2(0, vv))
	_v(st, Vector3(bx, y, bz), n, Vector2(uu, vv))

func _sides_x(st: SurfaceTool, wall_set: Dictionary, minx: int, maxx: int, minz: int, maxz: int, dir: int) -> void:
	var n := Vector3(dir, 0, 0)
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
			_quad_side(st, Vector3(px, 0, z - 0.5), Vector3(px, 0, z1 + 0.5), n, float(z1 - z + 1))
			z = z1 + 1

func _sides_z(st: SurfaceTool, wall_set: Dictionary, minx: int, maxx: int, minz: int, maxz: int, dir: int) -> void:
	var n := Vector3(0, 0, dir)
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
			_quad_side(st, Vector3(x - 0.5, 0, pz), Vector3(x1 + 0.5, 0, pz), n, float(x1 - x + 1))
			x = x1 + 1

# a vertical quad from base a..b (y=0) up to WALL_H; `ulen` cells wide for UV tiling
func _quad_side(st: SurfaceTool, a: Vector3, b: Vector3, n: Vector3, ulen: float) -> void:
	var top_a := a + Vector3(0, WALL_H, 0)
	var top_b := b + Vector3(0, WALL_H, 0)
	_v(st, a, n, Vector2(0, 0))
	_v(st, top_b, n, Vector2(ulen, WALL_H))
	_v(st, top_a, n, Vector2(0, WALL_H))
	_v(st, a, n, Vector2(0, 0))
	_v(st, b, n, Vector2(ulen, 0))
	_v(st, top_b, n, Vector2(ulen, WALL_H))

func _wall_material() -> Material:
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0
	m.metallic = 0.0
	var tex: ImageTexture = null
	if _wall_tile != "":
		tex = _colored_tex(_wall_tile, _wall_main, _wall_detail, true)
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		m.albedo_color = _qud_color(_wall_main)
	return m  # default shading is lit, so tops/sides shade differently

# --- textures & materials (floors/sprites) ----------------------------------

func _colored_tex(tile: String, main_c: String, detail_c: String, fill := false) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	var key := "%s|%s|%s|%s" % [tile, main_c, detail_c, fill]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return null
	var main := _qud_color(main_c)
	var detail := _qud_color(detail_c)
	var w := mask.get_width()
	var h := mask.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var p := mask.get_pixel(x, y)
			if p.a < 0.5:
				img.set_pixel(x, y, Color(main.r, main.g, main.b, 1.0) if fill else Color(0, 0, 0, 0))
			else:
				var lum := (p.r + p.g + p.b) / 3.0
				var c := main.lerp(detail, lum)
				img.set_pixel(x, y, Color(c.r, c.g, c.b, p.a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex

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
	if _sprite_pool.size() > 0: return _sprite_pool.pop_back()
	var s := Sprite3D.new()
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	s.pixel_size = PIXEL_SIZE
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.transparent = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	add_child(s)
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

# Qud palette (Base/Colors.xml): Y=white y=gray K=black W=gold w=brown O/o=orange
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

func _qud_color(code: String) -> Color:
	var c := code.strip_edges()
	if c.is_empty():
		return Color.WHITE
	var ch := c.substr(c.length() - 1, 1)
	return COLORS.get(ch, Color.WHITE)

extends Node3D
class_name ZoneRenderer

## Renders a zone snapshot, classifying each object by Qud render layer + IsWall:
##   layer <= FLOOR_LAYER_MAX  -> flat quad on the ground (shale *, dirt, water)
##   wall (IsWall)             -> rectangular BoxMesh prism, a cell tall
##   otherwise                 -> upright billboard sprite (plants, creatures, items)
## Tiles are 2-colour masks (black = TileColor, white = DetailColor) recoloured on
## the CPU. Objects with no exported tile fall back to an ASCII glyph.

const CELL := 1.0
const FLOOR_LAYER_MAX := 2
const WALL_H := 1.2
const PIXEL_SIZE := 0.042
const FLOOR_Y := 0.02
const LAYER_STEP := 0.02

var _tiles_dir := ""
var _mask_cache := {}       # fname -> Image
var _tex_cache := {}        # "tile|main|detail" -> ImageTexture
var _texmat_cache := {}     # same key -> StandardMaterial3D (for meshes)
var _colmat_cache := {}     # color html -> StandardMaterial3D

var _plane: PlaneMesh
var _box: BoxMesh

var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _floor_pool: Array[MeshInstance3D] = []
var _wall_pool: Array[MeshInstance3D] = []
var _label_pool: Array[Label3D] = []

func _ready() -> void:
	_plane = PlaneMesh.new()
	_plane.size = Vector2(CELL, CELL)           # XZ plane, normal +Y
	_box = BoxMesh.new()
	_box.size = Vector3(CELL * 0.96, WALL_H, CELL * 0.96)

func render_snapshot(data: Dictionary) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))

	for n in _active:
		n.visible = false
		if n is Sprite3D: _sprite_pool.append(n)
		elif n is Label3D: _label_pool.append(n)
		elif n is MeshInstance3D:
			if n.mesh == _plane: _floor_pool.append(n)
			else: _wall_pool.append(n)
	_active.clear()

	for cell in data.get("cells", []):
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var idx := 0
		for obj in cell.get("objs", []):
			_place(obj, cx, cy, idx)
			idx += 1

func _place(obj: Dictionary, cx: int, cy: int, idx: int) -> void:
	var tile := String(obj.get("tile", ""))
	var main_c := String(obj.get("tilecolor", ""))
	if main_c == "": main_c = String(obj.get("color", ""))
	var detail_c := String(obj.get("detail", ""))
	var tex := _colored_tex(tile, main_c, detail_c)
	var layer := int(obj.get("layer", 99))
	var is_wall: bool = bool(obj.get("wall", false))

	if is_wall:
		var w := _take_wall()
		var wtex := _colored_tex(tile, main_c, detail_c, true)  # opaque-filled: solid prism
		if wtex != null:
			w.material_override = _mesh_material(tile, main_c, detail_c, wtex, true)
		else:
			w.material_override = _color_material(_qud_color(main_c))  # prism until tile exports
		w.position = Vector3(cx, WALL_H * 0.5, cy)
		w.visible = true
		_active.append(w)
	elif layer <= FLOOR_LAYER_MAX:
		var f := _take_floor()
		var y := FLOOR_Y + idx * 0.005
		if tex != null:
			f.material_override = _mesh_material(tile, main_c, detail_c, tex)
			f.scale = Vector3.ONE
		else:
			# no tile (e.g. the * ground clutter): a small flat coloured dot
			f.material_override = _color_material(_qud_color(String(obj.get("color", ""))))
			f.scale = Vector3(0.5, 1.0, 0.5)
		f.position = Vector3(cx, y, cy)
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

# --- textures & materials ---------------------------------------------------

func _colored_tex(tile: String, main_c: String, detail_c: String, fill := false) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	# `fill`: transparent pixels become the main colour (opaque) — used for walls so
	# prisms are solid instead of speckled with holes.
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

func _mask(tile: String) -> Image:
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	if _mask_cache.has(fname):
		return _mask_cache[fname]
	var path := _tiles_dir.path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	# Files are always PNG content even when the name ends in .bmp (Qud tile paths),
	# so parse PNG explicitly rather than letting the extension pick the loader.
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

func _mesh_material(tile: String, main_c: String, detail_c: String, tex: ImageTexture, opaque := false) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s" % [tile, main_c, detail_c, opaque]
	if _texmat_cache.has(key):
		return _texmat_cache[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if opaque:
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		m.cull_mode = BaseMaterial3D.CULL_BACK
	else:
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

func _take_wall() -> MeshInstance3D:
	if _wall_pool.size() > 0: return _wall_pool.pop_back()
	var mi := MeshInstance3D.new()
	mi.mesh = _box
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

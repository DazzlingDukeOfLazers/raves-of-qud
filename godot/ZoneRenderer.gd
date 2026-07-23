extends Node3D
class_name ZoneRenderer

## Renders a zone snapshot as billboards on a 3D grid.
## Real Qud tiles are 2-color masks (black = main / TileColor, white = detail /
## DetailColor, on transparent). We recolor each tile on the CPU per colour combo
## (cached) and show it as a Sprite3D; objects whose tile isn't exported yet fall
## back to an ASCII glyph and retry on later frames.

const CELL := 1.0
const LAYER_STEP := 0.02
const PIXEL_SIZE := 0.042   # 24px tile ~= 1 cell tall

var _tiles_dir := ""
var _mask_cache := {}       # tile filename -> Image (raw 2-colour mask); hits only
var _tex_cache := {}        # "tile|main|detail" -> ImageTexture
var _active: Array = []
var _sprite_pool: Array[Sprite3D] = []
var _label_pool: Array[Label3D] = []

func render_snapshot(data: Dictionary) -> void:
	_tiles_dir = String(data.get("tilesDir", ""))

	for n in _active:
		n.visible = false
		if n is Sprite3D: _sprite_pool.append(n)
		else: _label_pool.append(n)
	_active.clear()

	for cell in data.get("cells", []):
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var idx := 0
		for obj in cell.get("objs", []):
			var tile := String(obj.get("tile", ""))
			var main_c := String(obj.get("tilecolor", ""))
			if main_c == "": main_c = String(obj.get("color", ""))
			var detail_c := String(obj.get("detail", ""))
			var tex := _colored_tex(tile, main_c, detail_c)
			var pos := Vector3(cx * CELL, idx * LAYER_STEP, cy * CELL)
			if tex != null:
				var s := _take_sprite()
				s.texture = tex
				# stand the sprite up on the ground plane
				s.position = pos + Vector3(0, PIXEL_SIZE * tex.get_height() * 0.5, 0)
				s.visible = true
				_active.append(s)
			else:
				var l := _take_label()
				l.text = String(obj.get("glyph", "?"))
				l.modulate = _qud_color(String(obj.get("color", "")))
				l.position = pos
				l.visible = true
				_active.append(l)
			idx += 1

# --- tile recolouring -------------------------------------------------------

func _colored_tex(tile: String, main_c: String, detail_c: String) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	var key := "%s|%s|%s" % [tile, main_c, detail_c]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var mask := _mask(tile)
	if mask == null:
		return null   # not exported yet; retry next frame
	var main := _qud_color(main_c)
	var detail := _qud_color(detail_c)
	var w := mask.get_width()
	var h := mask.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var p := mask.get_pixel(x, y)
			if p.a < 0.5:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				var lum := (p.r + p.g + p.b) / 3.0
				var c := main.lerp(detail, lum)   # black->main, white->detail
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
	var img := Image.load_from_file(path)
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mask_cache[fname] = img
	return img

# --- node pools -------------------------------------------------------------

func _take_sprite() -> Sprite3D:
	if _sprite_pool.size() > 0:
		return _sprite_pool.pop_back()
	var s := Sprite3D.new()
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y   # upright, faces camera (2.5D)
	s.pixel_size = PIXEL_SIZE
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.transparent = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	add_child(s)
	return s

func _take_label() -> Label3D:
	if _label_pool.size() > 0:
		return _label_pool.pop_back()
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

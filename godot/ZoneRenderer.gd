extends Node3D
class_name ZoneRenderer

## Renders a zone snapshot as billboards on a 3D grid.
## Prefers real Qud tile sprites (PNGs the mod exports to `tilesDir`); falls back
## to an ASCII glyph (Label3D) for any object whose tile isn't on disk yet.

const CELL := 1.0        # world units per Qud cell
const LAYER_STEP := 0.02 # tiny Y offset so stacked objects don't z-fight
const PIXEL_SIZE := 0.04 # a 24px-tall tile ~= 1 cell

var _tiles_dir := ""
var _tex_cache := {}     # sanitized filename -> ImageTexture (hits only; misses retry)
var _active: Array = []  # nodes shown this frame
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
			var pos := Vector3(cx * CELL, idx * LAYER_STEP, cy * CELL)
			var tex := _tex_for(String(obj.get("tile", "")))
			if tex != null:
				var s := _take_sprite()
				s.texture = tex
				# Qud tints the tile by TileColor (fall back to the glyph color).
				var c: String = obj.get("tilecolor", "")
				if c == "": c = String(obj.get("color", ""))
				s.modulate = _qud_color(c)
				s.position = pos
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

func _tex_for(tile: String) -> ImageTexture:
	if tile.is_empty() or _tiles_dir.is_empty():
		return null
	var key := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	if _tex_cache.has(key):
		return _tex_cache[key]
	# Not cached: try to load. Misses are NOT cached, so a tile the mod exports a
	# moment later gets picked up on a subsequent frame.
	var path := _tiles_dir.path_join(key)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex

func _take_sprite() -> Sprite3D:
	if _sprite_pool.size() > 0:
		return _sprite_pool.pop_back()
	var s := Sprite3D.new()
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.pixel_size = PIXEL_SIZE
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.transparent = true
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD  # crisp edges, correct depth sorting
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

# Qud's 16-color palette. Non-obvious mapping (Base/Colors.xml):
#   Y = white, y = gray, K = black; W = GOLD/yellow, w = BROWN; O/o = orange.
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

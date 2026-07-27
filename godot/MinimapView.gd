extends PanelContainer

## Minimap view — its own scene in MainFrame's row-3 side column. A low-res top-down map of the
## CURRENT zone, built CLIENT-SIDE from the snapshot's cells (no mod data): one pixel per cell, tinted
## by the topmost object's colour, with the player marked. Scaled up nearest-neighbour to fill.

const BG := Color(0.05, 0.06, 0.08)
const PLAYER := Color(1, 1, 1)

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

var _palette := {}
var _rect: TextureRect

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var title := Label.new()
	title.text = "Minimap"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)
	_rect = TextureRect.new()
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixels, no blur
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rect)

## MainFrame calls this each snapshot with the full data (needs cells + player + zone dims + palette).
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	var z: Dictionary = data.get("zone", {})
	var w := int(z.get("width", 0))
	var h := int(z.get("height", 0))
	if w <= 0 or h <= 0:
		return
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(BG)
	for cell in data.get("cells", []):
		var x := int(cell.get("x", -1))
		var y := int(cell.get("y", -1))
		if x < 0 or y < 0 or x >= w or y >= h:
			continue
		img.set_pixel(x, y, _cell_color(cell))
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px >= 0 and py >= 0 and px < w and py < h:
		img.set_pixel(px, py, PLAYER)
	_rect.texture = ImageTexture.create_from_image(img)

## Colour of one cell: the topmost object's foreground colour, else the world background.
func _cell_color(cell: Dictionary) -> Color:
	var objs: Array = cell.get("objs", [])
	if objs.is_empty():
		return BG
	return _obj_main(objs[objs.size() - 1])   # top of the stack

func _obj_main(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	var c := String(obj.get("tilecolor", ""))
	if c == "":
		c = String(obj.get("color", ""))
	return _qud_color(c)

func _qud_color(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return BG
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, BG)

func _fg_letter(code: String) -> String:
	var c := code.strip_edges()
	var caret := c.find("^")
	if caret >= 0:
		c = c.substr(0, caret)
	c = c.replace("&", "")
	if c.is_empty():
		return ""
	return c.substr(c.length() - 1, 1)

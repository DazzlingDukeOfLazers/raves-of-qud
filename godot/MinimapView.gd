extends PanelContainer

## Minimap view — its own scene in MainFrame's row-3 side column. A low-res top-down map of the
## CURRENT zone, built CLIENT-SIDE from the snapshot's cells (no mod data): one pixel per cell, with
## the player marked, scaled up nearest-neighbour to fill.
##
## Two modes, toggled in the title bar:
##   FULL (default): every cell tinted by its topmost object's colour — a rich, painterly map.
##   MINIMAL (Qud-style): walls drawn PRONOUNCED (brightened), everything else dimmed to a faint hint,
##                        so the built structure of the zone reads at a glance.

const BG := Color(0.05, 0.06, 0.08)
const PLAYER := Color(1, 1, 1)

const MODE_FULL := 0
const MODE_MINIMAL := 1

# MINIMAL mode tuning: walls are lifted toward white; other objects are knocked down toward BG.
const WALL_LIFT := 0.45     # how far a wall's colour is lerped toward white
const NONWALL_DIM := 0.30   # how much of a non-wall object's colour survives (rest -> BG)

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
var _toggle: Button
var _mode := MODE_FULL
var _last_data := {}   # last snapshot, so a mode toggle re-renders without waiting for a new one

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

	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "Minimap"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_toggle = Button.new()
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_toggle_mode)
	head.add_child(_toggle)
	_refresh_toggle()

	_rect = TextureRect.new()
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixels, no blur
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rect)

## MainFrame calls this each snapshot with the full data (needs cells + player + zone dims + palette).
func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_rerender()

func _rerender() -> void:
	var data := _last_data
	if data.is_empty():
		return
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

## Colour of one cell, per mode.
func _cell_color(cell: Dictionary) -> Color:
	var objs: Array = cell.get("objs", [])
	if objs.is_empty():
		return BG
	if _mode == MODE_MINIMAL:
		return _cell_color_minimal(objs)
	return _obj_main(objs[objs.size() - 1])   # FULL: top of the stack

## MINIMAL: a wall in the cell wins and is lifted toward white (pronounced, Qud-style); otherwise the
## topmost object is dimmed to a faint structural hint.
func _cell_color_minimal(objs: Array) -> Color:
	for i in range(objs.size() - 1, -1, -1):
		if bool(objs[i].get("wall", false)):
			return _obj_main(objs[i]).lerp(Color.WHITE, WALL_LIFT)
	return BG.lerp(_obj_main(objs[objs.size() - 1]), NONWALL_DIM)

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

func _toggle_mode() -> void:
	_mode = MODE_FULL if _mode == MODE_MINIMAL else MODE_MINIMAL
	_refresh_toggle()
	_rerender()

func _refresh_toggle() -> void:
	if _toggle == null:
		return
	_toggle.text = "minimal" if _mode == MODE_MINIMAL else "full"
	var other := "full" if _mode == MODE_MINIMAL else "minimal"
	_toggle.tooltip_text = "Switch to %s mode" % other

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

var _tiles: RefCounted   # shared colour resolution (QudTiles), set in _ready
var _palette := {}
var _rect: TextureRect
var _tex: ImageTexture   # reused across snapshots; only reallocated when the zone size changes
var _toggle: Button
var _title: Label      # header — "Minimap" (user) or the zone name (1:1, Qud-style)
var _mode := MODE_FULL
var _last_data := {}   # last snapshot, so a mode toggle re-renders without waiting for a new one

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
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
	_title = Label.new()
	_title.text = "Minimap"
	_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
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
	_tiles.palette = _palette
	if _one_to_one:
		_update_title_1to1()   # Qud puts the zone name atop the minimap; keep it live as we travel
	_rerender()

## 1:1 header: the zone/terrain name (Qud's sidebar header), from the snapshot's stats. Falls back to
## "Minimap" so the header is never blank before the first stats arrive.
func _update_title_1to1() -> void:
	if _title == null:
		return
	var nm := QudText.strip(String(_last_data.get("stats", {}).get("terrain", "")))
	_title.text = nm if nm != "" else "Minimap"

## 1:1 (parity) mode: render the Qud-faithful minimap — the MINIMAL (structural) map, no FULL/MINIMAL
## toggle (Qud has none), and the header shows the zone name instead of "Minimap". Reverting restores
## the QoL header + toggle.
var _one_to_one := false
var _saved_mode := MODE_FULL   # user's FULL/MINIMAL choice, restored when leaving 1:1
func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	if _toggle != null:
		_toggle.visible = not on
	if on:
		_saved_mode = _mode
		_mode = MODE_MINIMAL     # Qud's structural overview, not the painterly per-cell FULL map
		_update_title_1to1()
	else:
		_mode = _saved_mode      # restore the user's map style
		if _title != null:
			_title.text = "Minimap"
		_refresh_toggle()
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
	# Reuse one texture: update its pixels in place, only reallocating if the zone size changed. This
	# avoids a per-turn GPU texture alloc/free that would otherwise churn during the risky viewport
	# enable window.
	if _tex != null and _tex.get_width() == w and _tex.get_height() == h:
		_tex.update(img)
	else:
		_tex = ImageTexture.create_from_image(img)
		_rect.texture = _tex

## Colour of one cell, per mode.
func _cell_color(cell: Dictionary) -> Color:
	var objs: Array = cell.get("objs", [])
	if objs.is_empty():
		return BG
	if _mode == MODE_MINIMAL:
		return _cell_color_minimal(objs)
	return _tiles.main_color(objs[objs.size() - 1], BG)   # FULL: top of the stack

## MINIMAL: a wall in the cell wins and is lifted toward white (pronounced, Qud-style); otherwise the
## topmost object is dimmed to a faint structural hint. (BG is the fallback so colourless cells recede.)
func _cell_color_minimal(objs: Array) -> Color:
	for i in range(objs.size() - 1, -1, -1):
		if bool(objs[i].get("wall", false)):
			return _tiles.main_color(objs[i], BG).lerp(Color.WHITE, WALL_LIFT)
	return BG.lerp(_tiles.main_color(objs[objs.size() - 1], BG), NONWALL_DIM)

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

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
	_apply_panel_box()

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
	# IGNORE_SIZE: the rect's min size is 0 (not the tiny 80x25 texture), so EXPAND_FILL actually grows
	# it to fill the panel height — otherwise the image stays a small centred strip and the panel's
	# min-height just adds dead space below it.
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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
	# Give the map image a real height. Setting it on the TextureRect (content-min) reliably grows the
	# panel — the panel's own custom_minimum_size wasn't translating into a taller image (the rect stayed
	# a short strip). ~110px matches Qud's sidebar minimap.
	if _rect != null:
		_rect.custom_minimum_size = Vector2(0, 110 if on else 0)
	if on:
		_saved_mode = _mode
		_mode = MODE_MINIMAL     # Qud's structural overview, not the painterly per-cell FULL map
		_update_title_1to1()
	else:
		_mode = _saved_mode      # restore the user's map style
		if _title != null:
			_title.text = "Minimap"
		_refresh_toggle()
	# the heading is Qud's dim grey-teal at the log's 0.76x body, as on the two panels below
	if _title != null:
		if on:
			_title.add_theme_font_size_override("font_size",
				int(round(UiFont.px(get_viewport(), "body") * LOG_FONT_FRAC_1TO1)))
			_title.add_theme_color_override("font_color", TITLE_COLOR_1TO1)
		else:
			_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
			_title.remove_theme_color_override("font_color")
	_apply_panel_box()
	queue_redraw()
	_rerender()

## 1:1: Qud's OWN minimap, from the mod's `minimap` block (Cell.RefreshMinimapColor per cell).
##
## Geometry is Qud's: its texture is 80x50 for a 25-row zone — EACH ZONE ROW WRITES TWO TEXTURE
## ROWS (ActionManager.UpdateMinimap: `(24 - i) * 2` and `+ 1`), which also flips the map so row 0
## is at the bottom. Point-filtered. Reproducing the doubling rather than stretching a 80x25 image
## keeps the two textures directly comparable if Qud's own ever renders.
##
## Colours carry ALPHA (unexplored 32, unlit 128, lit 164, features 230) so the panel background
## washes through — this is a translucent overlay, not opaque pixels.
func _render_qud_minimap(mm: Dictionary) -> bool:
	var w := int(mm.get("width", 0))
	var h := int(mm.get("height", 0))
	var cells := String(mm.get("cells", ""))
	var pal: Array = mm.get("palette", [])
	if w <= 0 or h <= 0 or cells.length() < w * h or pal.is_empty():
		return false
	var cols: Array[Color] = []
	for p in pal:
		var s := String(p)
		if s.length() < 8:
			cols.append(Color(0, 0, 0, 0))
			continue
		cols.append(Color8(("0x" + s.substr(0, 2)).hex_to_int(), ("0x" + s.substr(2, 2)).hex_to_int(),
			("0x" + s.substr(4, 2)).hex_to_int(), ("0x" + s.substr(6, 2)).hex_to_int()))
	var img := Image.create(w, h * 2, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var idx := QUD_MM_ALPHABET.find(cells[y * w + x])
			var c: Color = cols[idx] if idx >= 0 and idx < cols.size() else Color(0, 0, 0, 0)
			var ty := (h - 1 - y) * 2      # Qud's (24 - i) * 2 — the map is bottom-up
			img.set_pixel(x, ty, c)
			img.set_pixel(x, ty + 1, c)
	if _tex != null and _tex.get_width() == w and _tex.get_height() == h * 2:
		_tex.update(img)
	else:
		_tex = ImageTexture.create_from_image(img)
		_rect.texture = _tex
	return true

const QUD_MM_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# ── 1:1 chrome, shared with the two panels below it so the sidebar reads as one column ──────────
const LOG_FONT_FRAC_1TO1 := 0.76
const TITLE_COLOR_1TO1 := Color8(59, 89, 107)
const SEP_MARGIN_1TO1 := 20
## Qud's movable-window backdrop: a dot every 16px, one shade off the panel fill (measured
## (19,23,26) against the (17,33,38) chrome).
const DOT_PITCH_1TO1 := 16
var DOT_COLOR_1TO1 := QudChrome.q8(19, 23, 26)
var SEP_OUTER := QudChrome.q8(68, 99, 112)
var SEP_CENTER := QudChrome.q8(30, 57, 72)

func _apply_panel_box() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudChrome.q8(17, 33, 38) if _one_to_one else QudPalette.CHROME
	sb.content_margin_left = SEP_MARGIN_1TO1 if _one_to_one else 6
	sb.content_margin_right = 6
	sb.content_margin_top = 0 if _one_to_one else 6
	sb.content_margin_bottom = 6
	if not _one_to_one:
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.12)
		sb.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", sb)

## 1:1 only: the ||| grab-bar (continuing the log's, centre column 2px wide — see MessageLog) and
## Qud's dotted window backdrop behind the map.
func _draw() -> void:
	if not _one_to_one:
		return
	var h := size.y
	for y in range(0, int(h), DOT_PITCH_1TO1):
		for x in range(SEP_MARGIN_1TO1, int(size.x), DOT_PITCH_1TO1):
			draw_rect(Rect2(x, y, 1, 1), DOT_COLOR_1TO1)
	draw_rect(Rect2(2, 0, 1, h), SEP_OUTER)
	draw_rect(Rect2(6, 0, 2, h), SEP_CENTER)
	draw_rect(Rect2(11, 0, 1, h), SEP_OUTER)

func _rerender() -> void:
	var data := _last_data
	if data.is_empty():
		return
	# 1:1 renders QUD's map when the mod ships it; anything else falls back to the QoL map below.
	if _one_to_one:
		var mm: Variant = data.get("minimap", null)
		if mm is Dictionary and _render_qud_minimap(mm):
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

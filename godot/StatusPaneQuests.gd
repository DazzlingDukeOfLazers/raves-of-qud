extends Control

## The QUESTS tab's list, mirroring Qud.UI.QuestsStatusScreen's left-hand pane.
##
## Geometry and colours are Qud's own, read off the live RectTransforms with the mod's UiProbe
## (see docs/decisions/1to1-measurement-and-layout.md — reproduce the MODEL, not the pixels):
##
##   pane        List Scroller x=158.5 y=177 w=815; rows start x=174.5 w=799
##   row         caret 15x15 at +0.5/+4.5 | title band at +18, h 24.6, font 18
##               giver line at +28.6, font 16 | body at +60/+64.8, font 16
##               rows are separated by 16px and each is as tall as its body
##   title       "[-] Name" / "[+] Name", with a DOTTED LEADER filling to the row's right edge
##
## The MAP panel on the right is Qud's own rendered TEXTURE, exported by the mod (MapExporter) —
## RefreshMap builds it by walking all 80x25 cells of JoppaWorld into a 1280x600 image, and
## re-deriving that here would mean reproducing Qud's whole world-map render and keeping it in
## step forever. Qud draws it at 2x inside a 724x744 viewport, scrolled to the quest pin.
##
## Content is Qud's too: the body lines come from QuestLog.GetLinesForQuest via QuestsExporter, so
## step order, completion glyphs and optional/failed wording are the game's, not ours.

const PANE_X := 158.5
const PANE_Y := 177.0
const ROW_X := 174.5
const ROW_W := 799.0
const LIST_W := 815.0
const CARET_DX := 0.5
const CARET_DY := 4.5
const CARET := 15.0
const BAND_DX := 18.0          # title band / giver / body all inset this far from the row
const BAND_W := 781.0
const TITLE_H := 24.6
const TITLE_FONT := 18
const GIVER_DY := 28.6
const GIVER_FONT := 16
const GIVER_TEXT_DX := 52.0    # "Quest Giver: " starts here (row+18+34), measured
const BODY_DX := 60.0
const BODY_DY := 64.8
const BODY_FONT := 16
const ROW_GAP := 16.0

# The map panel, measured off Qud's live RectTransforms.
const MAP_X := 1021.5
const MAP_Y := 177.0
const MAP_W := 724.0
const MAP_H := 744.0
const MAP_ZOOM := 2.0       # the 1280x600 texture is drawn at 2560x1200
const MAP_CELL_W := 16.0    # RefreshMap's per-cell blit, so a pin's (x,y) -> texture px
const MAP_CELL_H := 24.0

# Qud's own colours for this screen, straight off the live TMP components.
const C_TITLE := Color8(0x82, 0x9e, 0xa8)
const C_GIVER_LABEL := Color8(0x60, 0x91, 0xbc)
const C_GIVER := Color8(0x5b, 0x7a, 0x8a)
const C_BODY := Color8(0x5b, 0x7a, 0x8a)
const C_CARET := Color8(0xcf, 0xc0, 0x41)
const C_LEADER := Color8(0x3b, 0x55, 0x5e)   # the dotted leader after the title

var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

var _quests: Array = []
var _empty := ""
var _palette := {}
var _sel := 0
var _rows: Array = []          # [{y, h, id}] laid out, for hit-testing and the caret
var _pins: Array = []
var _map: Texture2D = null
var _map_tried := false
var _player_pos := Vector2(-1, -1)

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	_quests = data.get("quests", [])
	_pins = data.get("pins", [])
	var pp: Dictionary = data.get("player", {})
	_player_pos = Vector2(float(pp.get("x", 0)), float(pp.get("y", 0))) if not pp.is_empty() \
		else Vector2(-1, -1)
	_empty = str(data.get("empty", ""))
	_sel = clampi(_sel, 0, maxi(0, _quests.size() - 1))
	_build()

func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_rows.clear()

	# EMPTY STATE is a real row in Qud, not an absence of rows — same caret, same title band.
	if _quests.is_empty():
		if _empty != "":
			_add_row({"name": _empty}, PANE_Y + 32.0, true)
		queue_redraw()
		return

	var y := PANE_Y + 32.0
	for i in _quests.size():
		y += _add_row(_quests[i], y, false) + ROW_GAP
	queue_redraw()

## Lay one quest out at `y`; returns its height.
func _add_row(q: Dictionary, y: float, empty_state: bool) -> float:
	var title := _mk(TITLE_FONT, C_TITLE)
	title.position = Vector2(ROW_X + BAND_DX, y)
	title.text = ("[-] " if not empty_state else "") + str(q.get("name", ""))
	add_child(title)
	var title_w := title.get_combined_minimum_size().x

	var h := TITLE_H
	if not empty_state:
		var giver := _mk(GIVER_FONT, C_GIVER)
		giver.position = Vector2(ROW_X + BAND_DX + GIVER_TEXT_DX, y + GIVER_DY)
		giver.text = "[color=#%s]Quest Giver: [/color]%s" % [
			C_GIVER_LABEL.to_html(false), str(q.get("giver", ""))]
		add_child(giver)

		var body := _mk(BODY_FONT, C_BODY)
		body.position = Vector2(ROW_X + BODY_DX, y + BODY_DY)
		body.custom_minimum_size = Vector2(ROW_W - BODY_DX - 20.0, 0)
		# The body arrives as Qud's own rendered LINES (QuestLog.GetLinesForQuest). Convert each
		# line SEPARATELY and join afterwards: QudText.cp437 maps CP437 control bytes to glyphs,
		# and 0x0A is "◙" in that table — feeding it a joined string turns every newline into a
		# glyph and runs the whole quest log onto one line. The bytes are only glyphs inside a
		# single line; a line break is a line break.
		var lines := PackedStringArray()
		for ln in _strs(q.get("body", [])):
			lines.append(QudText.to_bbcode(ln, _palette))
		body.text = "\n".join(lines)
		add_child(body)
		h = BODY_DY + body.get_combined_minimum_size().y

	_rows.append({"y": y, "h": h, "title_w": title_w, "empty": empty_state})
	return h

func _strs(a) -> Array:
	var out := []
	for v in a:
		out.append(str(v))
	return out

func _mk(px: int, col: Color) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.add_theme_font_size_override("normal_font_size", px)
	rt.add_theme_color_override("default_color", col)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rt

func _draw() -> void:
	_draw_map()
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		# The gold caret marks the selected row (Qud draws its `leftrightarrow` sprite here).
		if i == _sel:
			var cy: float = r["y"] + CARET_DY
			draw_rect(Rect2(ROW_X + CARET_DX, cy + 4.0, CARET - 4.0, 2.0), C_CARET)
			draw_rect(Rect2(ROW_X + CARET_DX + CARET - 6.0, cy + 1.0, 2.0, 8.0), C_CARET)
		# The dotted leader that runs from the end of the title to the row's right edge.
		var lx: float = ROW_X + BAND_DX + r["title_w"] + 8.0
		var rx: float = ROW_X + BAND_W + BAND_DX - 18.0
		var ly: float = r["y"] + TITLE_H * 0.5
		var x := lx
		while x < rx:
			draw_rect(Rect2(x, ly, 2.0, 1.0), C_LEADER)
			x += 6.0


## Qud's world-map panel: its own rendered texture, drawn at 2x and scrolled so the quest pin is
## centred (clamped to the map's edges — which is why Qud's own view sits against the bottom when
## the only pin is Joppa, low on the map).
func _draw_map() -> void:
	if _map == null and not _map_tried:
		_map_tried = true
		var path := InputModel.support_dir().path_join("map").path_join("quests_map.png")
		if FileAccess.file_exists(path):
			var img := Image.new()
			if img.load(path) == OK:
				_map = ImageTexture.create_from_image(img)
	if _map == null:
		return
	var tw := _map.get_width() * MAP_ZOOM
	var th := _map.get_height() * MAP_ZOOM
	# centre on the first pin, then clamp so we never show past the map's edge
	# Default centre is the PLAYER's parasang, not the texture's middle — that is where Qud's
	# map sits with nothing selected, and the middle put us several parasangs away.
	var cx := tw * 0.5
	var cy := th * 0.5
	if _player_pos != Vector2(-1, -1):
		cx = (_player_pos.x + 0.5) * MAP_CELL_W * MAP_ZOOM
		cy = (_player_pos.y + 0.5) * MAP_CELL_H * MAP_ZOOM
	if not _pins.is_empty():
		cx = (float(_pins[0].get("x", 0)) + 0.5) * MAP_CELL_W * MAP_ZOOM
		cy = (float(_pins[0].get("y", 0)) + 0.5) * MAP_CELL_H * MAP_ZOOM
	var ox := clampf(MAP_X + MAP_W * 0.5 - cx, MAP_X + MAP_W - tw, MAP_X)
	var oy := clampf(MAP_Y + MAP_H * 0.5 - cy, MAP_Y + MAP_H - th, MAP_Y)

	# clip to the viewport: the texture is far larger than the panel
	draw_set_transform(Vector2.ZERO)
	var clip := Rect2(MAP_X, MAP_Y, MAP_W, MAP_H)
	draw_rect(clip, Color8(4, 19, 18))      # RefreshMap's own backdrop colour
	var prev_filter := texture_filter
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# draw only the visible slice, so a 2560x1200 blit doesn't spill over the list
	var src_x := (MAP_X - ox) / MAP_ZOOM
	var src_y := (MAP_Y - oy) / MAP_ZOOM
	var src := Rect2(src_x, src_y, MAP_W / MAP_ZOOM, MAP_H / MAP_ZOOM)
	draw_texture_rect_region(_map, clip, src)
	texture_filter = prev_filter

	# the pins
	for p in _pins:
		var px := ox + (float(p.get("x", 0)) + 0.5) * MAP_CELL_W * MAP_ZOOM
		var py := oy + (float(p.get("y", 0)) + 0.5) * MAP_CELL_H * MAP_ZOOM
		if not clip.has_point(Vector2(px, py)):
			continue
		draw_rect(Rect2(px - 5.0, py - 5.0, 10.0, 10.0), C_CARET, false, 2.0)

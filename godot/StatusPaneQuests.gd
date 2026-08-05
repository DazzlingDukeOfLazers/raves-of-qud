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
## The MAP panel that occupies the right of Qud's tab is deliberately not here yet — this pass is
## the list. Qud's own list is 815 wide of a 1603 pane, so the space is left rather than filled.
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

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	_quests = data.get("quests", [])
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

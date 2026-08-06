extends Control

## The JOURNAL tab, mirroring Qud.UI.JournalStatusScreen's left-hand list.
##
## Geometry is Qud's own, read off the live RectTransforms with the mod's UiProbe:
##
##   header      "Locations" at x=187.5 y=182.6, font 24, flanked by rule ends
##   list        EntryScroller x=158.5 y=234 w=793.5; rows at x=174.5 w=777.5
##   row         caret x=175.6 +18.2 15x15 | header text x=190.5 font 20 with a dotted
##               leader filling right | body text x=190.5 below, font 16
##
## Qud puts a WORLD MAP in the right half (x=952 w=793.5). Deferred, exactly as on the Quests
## tab -- the list first. Qud's own list is 793.5 of a 1603 pane, so the space is left empty
## rather than filled with something invented.
##
## The seven sub-tabs are Qud's (JournalScreen's STR_ constants, in screen order). Qud draws them
## as an ICON STRIP; this renders them as text labels for now -- navigable and honest, but not the
## icons. Q/E cycle, matching Qud's [Q]/[E] badges on that strip.

const HDR_X := 187.5
const HDR_Y := 182.6
const HDR_FONT := 24
const LIST_X := 174.5
const LIST_Y := 250.0
const LIST_W := 777.5
const LIST_H := 671.0
const CARET_DX := 1.1
const CARET_DY := 18.2
const ROW_TEXT_DX := 16.0     # header/body text sit 16 in from the row's left
const ROW_FONT := 20          # header row (category / recipe name / the empty-state line)
const BODY_FONT := 16
const ROW_GAP := 6.0
const STRIP_Y := 186.0        # the sub-tab strip, centred like Qud's icon row

const C_TEXT := Color8(0xaf, 0xc6, 0xc1)
const C_DIM := Color8(0x3b, 0x55, 0x5e)
const C_GOLD := Color8(0xcf, 0xc0, 0x41)
const C_HDR := Color8(0x82, 0x9e, 0xa8)

var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

var _tabs: Array = []
var _tab := 0
var _sel := 0
var _scroll := 0.0
var _palette := {}
var _font: Font
var _content: Control

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_font = UiFont.make_theme(get_viewport()).default_font
	_content = Control.new()
	_content.position = Vector2(0, 0)
	_content.size = Vector2(1920, 940)
	_content.clip_contents = false
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.draw.connect(_draw_all)
	add_child(_content)

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	_tabs = data.get("tabs", [])
	_tab = clampi(_tab, 0, maxi(0, _tabs.size() - 1))
	_sel = 0
	_scroll = 0.0
	if _content != null:
		_content.queue_redraw()

func _cur() -> Dictionary:
	if _tabs.is_empty():
		return {}
	return _tabs[clampi(_tab, 0, _tabs.size() - 1)]

func _draw_all() -> void:
	if _font == null or _tabs.is_empty():
		return
	var tab := _cur()

	# --- header: the current tab's display name, with Qud's rule ends either side
	var name := str(tab.get("name", ""))
	_content.draw_string(_font, Vector2(HDR_X, HDR_Y + 22.0), name,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HDR_FONT, C_HDR)
	var nw := _font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, HDR_FONT).x
	_content.draw_rect(Rect2(HDR_X - 17.0, HDR_Y + 7.0, 16.0, 1.0), C_DIM)
	_content.draw_rect(Rect2(HDR_X + nw + 4.0, HDR_Y + 7.0, 16.0, 1.0), C_DIM)

	# --- the sub-tab strip, centred (Qud draws icons; these are labels for now)
	var strip := PackedStringArray()
	for t in _tabs:
		strip.append(str(t.get("name", "")))
	var total := 0.0
	for s in strip:
		total += _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 22.0
	var x := 960.0 - total * 0.5
	for i in strip.size():
		var w := _font.get_string_size(strip[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var col := C_GOLD if i == _tab else C_DIM
		_content.draw_string(_font, Vector2(x, STRIP_Y + 14.0), strip[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		if i == _tab:
			_content.draw_rect(Rect2(x, STRIP_Y + 19.0, w, 1.0), C_GOLD)
		x += w + 22.0

	# --- the entry list
	var entries: Array = tab.get("entries", [])
	var y := LIST_Y - _scroll
	if entries.is_empty():
		# Qud's empty state is a real ROW, header-styled, with the same dotted leader.
		_draw_header_row(str(tab.get("empty", "No entries found.")), y, true)
		return
	for i in entries.size():
		if y > LIST_Y + LIST_H:
			break
		var h := _draw_entry(entries[i], y, i == _sel)
		y += h + ROW_GAP

## A header-styled row (empty state / recipe name), with the leader running to the list's right.
func _draw_header_row(s: String, y: float, caret: bool) -> void:
	if caret:
		_content.draw_string(_font, Vector2(LIST_X + CARET_DX, y + CARET_DY + 12.0), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_GOLD)
	var tx := LIST_X + ROW_TEXT_DX
	_content.draw_string(_font, Vector2(tx, y + 24.0), " " + s,
		HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_TEXT)
	var w := _font.get_string_size(" " + s, HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT).x
	var lx := tx + w + 8.0
	while lx < LIST_X + LIST_W:
		_content.draw_rect(Rect2(lx, y + 18.0, 2.0, 1.0), C_DIM)
		lx += 6.0

## One entry. Returns its height.
func _draw_entry(e: Dictionary, y: float, selected: bool) -> float:
	if selected:
		_content.draw_string(_font, Vector2(LIST_X + CARET_DX, y + CARET_DY + 12.0), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_GOLD)
	# A RECIPE is the one entry kind with its own header: setData puts the recipe's display name
	# in the header row and the ingredients/effects in the body.
	var h := 0.0
	if e.has("recipe"):
		_draw_header_row(str(e.get("recipe", "")), y, false)
		h += 30.0
		h += _body(["{{K|Ingredients:}} " + str(e.get("ingredients", ""))], y + h)
		var eff := str(e.get("effects", ""))
		if eff != "":
			var lines := PackedStringArray()
			for ln in eff.split("\n"):
				lines.append("{{K|/}} {{y|" + ln + "}}")
			h += _body(lines, y + h)
		return h
	# Plain entry: setData's two prefixes, then the display text.
	var pre := ""
	if e.has("tracked"):
		pre += "[X] " if bool(e.get("tracked", false)) else "[ ] "
	pre += "{{G|$}} " if bool(e.get("tradable", false)) else "{{K|$}} "
	var body := str(e.get("text", ""))
	if bool(e.get("tomb", false)):
		body = "{{w|[tomb engraving] " + body + "}}"
	return _body([pre + body], y)

## Draw wrapped markup lines into the list column; returns the height used.
func _body(lines: Array, y: float) -> float:
	var used := 0.0
	for raw in lines:
		for seg in _wrap(str(raw), LIST_W - ROW_TEXT_DX - 40.0):
			_draw_markup(seg, Vector2(LIST_X + ROW_TEXT_DX + 32.0, y + used + 14.0), BODY_FONT)
			used += 18.0
	return used

func _wrap(s: String, w: float) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in QudText.strip(s).split(" ", false):
		var probe := word if line == "" else line + " " + word
		if _font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT).x > w:
			out.append(line)
			line = word
		else:
			line = probe
	if line != "":
		out.append(line)
	return out

func _draw_markup(s: String, pos: Vector2, px: int) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, C_TEXT):
		var txt: String = run[0]
		if txt == "":
			continue
		_content.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## Q/E cycle the sub-tabs, matching the [Q]/[E] badges Qud puts either side of its icon strip.
func handle_key(e: InputEventKey) -> bool:
	if _tabs.is_empty():
		return false
	if e.keycode == KEY_Q:
		_tab = (_tab - 1 + _tabs.size()) % _tabs.size()
	elif e.keycode == KEY_E:
		_tab = (_tab + 1) % _tabs.size()
	else:
		return false
	_sel = 0
	_scroll = 0.0
	_content.queue_redraw()
	return true

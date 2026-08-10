extends Control

## QUD'S CYBERNETICS TERMINAL (the becoming nook), mirrored — `Qud.UI.CyberneticsTerminalScreen`.
##
## A THIRD OVERLAY beside PopupOverlay and PickerOverlay, because it is a third kind of thing: its
## own SingletonWindowBase screen with its own completionSource, invisible to both other mirrors.
## The mod's CyberBridge publishes it from PopupBridge's UI-thread watcher (the terminal parks the
## turn thread, so that is the only pump still running) and answers go back as a `cyber` command.
##
## GEOMETRY IS MEASURED, not styled — every number below is a rect from a uiprobe dump of the live
## screen (`probe/ui_CyberneticsTerminalScreen.json`, 2026-08-10, 1920x1080):
##
##   top rule      y 238.44   filler 544..872 | header 872..1048 | filler 1048..1376, each h16
##   icon panel    560,254.44  800x16   solid, alpha 0x63
##   viewport      560,270.44  800x484
##   caret         x593  10x16          (Qud's `leftrightarrow`, already exported as picker_caret)
##   row text      x607  w753           body at y288.44, options from y366.78, pitch 38.12
##   footer        560,754.44 800x20.12
##   bottom rule   y 774.56             same three sprites as the top
##   hint bar      y ~790.56
##
## THE TERMINAL IS A TRANSPARENT OVERLAY IN QUD — the art behind it is the playfield, not a panel
## sprite (checked against the capture: the "illustration" beside the menu is the becoming-nook room
## itself). So this draws chrome and text only, and lets Raves' own 3D playfield show through, which
## is what makes the two screens read the same without shipping a background at all.

signal answered(payload: Dictionary)   # {"action":"select","index":n} / {"action":"quit"}

const RULE_Y := 238.44
const RULE_BOT_Y := 774.56
const RULE_H := 16.0
const FILL_L_X := 544.0
const HEAD_X := 872.0
const HEAD_W := 176.0
const FILL_R_X := 1048.0
const FILL_W := 328.0
const PANEL_X := 560.0
const PANEL_W := 800.0
const ICON_PANEL_Y := 254.44
const BODY_Y := 288.44
const OPT_Y0 := 366.78
const OPT_PITCH := 38.12
const LINE_H := 20.12
const CARET_X := 593.0
const TEXT_X := 607.0
const FOOTER_Y := 754.44
const HINT_Y := 790.56

# Qud's own colours off the probe: body/option text #afc6c1, bracket #b1c9c3, hotkey #cfc041.
const C_TEXT := Color("#afc6c1")
const C_BRACKET := Color("#b1c9c3")
const C_HOTKEY := Color("#cfc041")

var _data := {}
var _palette := {}
var _sel := 0
var _root: Control
var _draw: Control
var _font: Font
var _caret_tex: Texture2D = null
var _rule_tex: Texture2D = null
var _head_tex: Texture2D = null
var _row_rects: Array = []   # [[Rect2, option_index], …] rebuilt each draw


func _ready() -> void:
	name = "CyberOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP     # modal while shown
	_root.gui_input.connect(_on_root_input)
	_root.theme = UiFont.make_theme(get_viewport())
	add_child(_root)
	_draw = Control.new()
	_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw.draw.connect(_render)
	_root.add_child(_draw)
	_font = _root.get_theme_default_font()
	_caret_tex = _chrome("picker_caret.png")
	# The rule is TWO sprites, not one repeated: `polat-frame-reverse-top-header-filler` (12x16,
	# already exported as picker_divider) tiles the runs, and `polat-frame-reverse-top-header`
	# is the NOTCHED centre. Aliasing both to the filler drew a plain bar and lost the notch.
	_rule_tex = _chrome("picker_divider.png")
	_head_tex = _chrome("term_header.png")


static func _chrome(fname: String) -> Texture2D:
	var p := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	return ImageTexture.create_from_image(QudChrome.brighten(img))


func show_terminal(data: Dictionary, palette: Dictionary) -> void:
	_data = data
	if not palette.is_empty():
		_palette = palette
	_sel = int(data.get("selected", 0))
	if _caret_tex == null:
		_caret_tex = _chrome("picker_caret.png")   # may have been exported since we started
	if _rule_tex == null:
		_rule_tex = _chrome("picker_divider.png")
	if _head_tex == null:
		_head_tex = _chrome("term_header.png")
	visible = true
	_draw.queue_redraw()
	UiState.set_scene("cyber_terminal")   # highvisor: the terminal is its own state


func hide_terminal() -> void:
	if not visible:
		return
	visible = false
	_data = {}
	_row_rects.clear()
	UiState.set_scene("in_game")


## Qud wraps the body at 67 columns before it ever reaches us (TerminalScreen's
## RenderedTextForModernUI = StringFormat.ClipText(MainText, 67, KeepNewlines: true)), so the
## newlines in the payload ARE Qud's line breaks. Splitting on them is reproducing its layout,
## not guessing at one — do not re-wrap.
func _body_lines() -> PackedStringArray:
	return String(_data.get("body", "")).split("\n")


func _render() -> void:
	if _data.is_empty():
		return
	# the two horizontal rules, three sprites each (filler | header | filler)
	for y in [RULE_Y, RULE_BOT_Y]:
		_rule_seg(FILL_L_X, y, FILL_W, _rule_tex, true)
		_rule_seg(HEAD_X, y, HEAD_W, _head_tex, false)
		_rule_seg(FILL_R_X, y, FILL_W, _rule_tex, true)
	# NOT DRAWN: the probe reports an "Icon Panel" here (560,254.44 800x16, sprite `solid`,
	# tint #ffffff63). Rendering that as a 39%-white band put a pale bar across the screen that
	# Qud's own capture does not have anywhere — the sprite is evidently not white, or the strip
	# is occluded. A node in the layout dump is not automatically INK; when the capture shows
	# nothing, draw nothing rather than invent an alpha that makes the diff worse.

	var asc := _font.get_ascent(16)
	var y := BODY_Y
	for ln in _body_lines():
		_draw.draw_string(_font, Vector2(TEXT_X, y + asc).round(), String(ln),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_TEXT)
		y += LINE_H

	_row_rects.clear()
	var opts: Array = _data.get("options", [])
	for i in opts.size():
		var ry := OPT_Y0 + float(i) * OPT_PITCH
		_row_rects.append([Rect2(PANEL_X, ry - 2.0, PANEL_W, LINE_H + 4.0), i])
		if i == _sel:
			_caret(ry)
		var runs: Array = QudText.runs(String(opts[i]), _palette, C_TEXT)
		var x := TEXT_X
		for r in runs:
			var txt: String = r[0]
			_draw.draw_string(_font, Vector2(x, ry + asc).round(), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, r[1])
			x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x

	# footer — Qud's own composed string ("Credits: 0  License Tier: 2  Points Used: 2"); the
	# tier/points arithmetic is the screen's, never re-derived here
	_draw.draw_string(_font, Vector2(PANEL_X, FOOTER_Y + asc).round(),
		String(_data.get("footer", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_TEXT)

	_hints()


func _rule_seg(x: float, y: float, w: float, tex: Texture2D, tile: bool) -> void:
	if tex != null:
		_draw.draw_texture_rect(tex, Rect2(x, y, w, RULE_H), tile)
	else:
		# stand-in until the chrome sprite has been exported: Qud's rule sits on the strip's
		# vertical centre, so a 1px line there is wrong by no more than the sprite's texture
		_draw.draw_rect(Rect2(x, y + RULE_H * 0.5 - 0.5, w, 1.0), C_TEXT * Color(1, 1, 1, 0.5))


func _caret(row_y: float) -> void:
	if _caret_tex != null:
		_draw.draw_texture_rect(_caret_tex, Rect2(CARET_X, row_y, 10, 16), false, C_HOTKEY)
	else:
		_draw.draw_string(_font, Vector2(CARET_X, row_y + _font.get_ascent(16)), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_HOTKEY)


## Qud's footer hint row, at the probed x's: [glyph] navigate  [Space] accept  [Esc] quit.
func _hints() -> void:
	var asc := _font.get_ascent(16)
	# Qud's first hint key is its own PUA input glyph (U+E80A), ONE character wide, and its x's
	# are laid out for that. Spelling it "Arrows" ran the bracket group into "navigate" — so use
	# the real glyph when the mod has extracted Qud's icon font, and a single-character stand-in
	# when it has not. Either way the row keeps Qud's measured positions.
	var nav_key := String.chr(0xE80A) if UiFont.qud_glyph_font() != null else "\u2195"
	for h in [[771.9, nav_key, 825.1, "navigate"], [916.9, "Space", 994.1, "accept"],
			[1066.7, "Esc", 1124.7, "quit"]]:
		var bx: float = h[0]
		_draw.draw_string(_font, Vector2(bx, HINT_Y + asc).round(), "[",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_BRACKET)
		var w1 := _font.get_string_size("[", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_draw.draw_string(_font, Vector2(bx + w1, HINT_Y + asc).round(), String(h[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_HOTKEY)
		var w2 := _font.get_string_size(String(h[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_draw.draw_string(_font, Vector2(bx + w1 + w2, HINT_Y + asc).round(), "]",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_BRACKET)
		_draw.draw_string(_font, Vector2(float(h[2]), HINT_Y + asc).round(), String(h[3]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_TEXT)


func _on_root_input(e: InputEvent) -> void:
	if e is InputEventMouseButton or e is InputEventMouseMotion:
		_root.accept_event()   # a modal owns the mouse; the wheel needs this (docs/gotchas.md)
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		for r in _row_rects:
			if (r[0] as Rect2).has_point(e.position):
				_sel = int(r[1])
				_draw.queue_redraw()
				answered.emit({"action": "select", "index": _sel})
				return


func handle_key(e: InputEventKey) -> bool:
	if not visible:
		return false
	var opts: Array = _data.get("options", [])
	match e.keycode:
		KEY_UP, KEY_KP_8:
			_sel = maxi(0, _sel - 1); _draw.queue_redraw(); return true
		KEY_DOWN, KEY_KP_2:
			_sel = mini(maxi(0, opts.size() - 1), _sel + 1); _draw.queue_redraw(); return true
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			answered.emit({"action": "select", "index": _sel}); return true
		KEY_ESCAPE:
			answered.emit({"action": "quit"}); return true
	return false


## FEEDBACK PROVIDER: name the row under the cursor, like the other panes.
func feedback_element_at(p: Vector2) -> Dictionary:
	if not visible:
		return {}
	for r in _row_rects:
		if (r[0] as Rect2).has_point(p):
			var opts: Array = _data.get("options", [])
			var i: int = int(r[1])
			return {"label": "terminal · %s" % (String(opts[i]) if i < opts.size() else "?"),
				"rect": r[0]}
	return {}

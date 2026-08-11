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

## EVERY VERTICAL IS AN OFFSET FROM THE SCROLL VIEWPORT'S TOP, which the mod ships live as
## `vpY100` (hundredths). The frame MOVES with its content — the welcome screen's viewport sits
## at 270.44 and the "Learn About Cybernetics" sub-screen's at 292.44 — so the first version's
## pinned constants collided the option rows with a longer body the moment a selection was
## driven through. These offsets are the part that IS stable: checked across both screens.
const VP_Y_FALLBACK := 270.44   # the welcome screen's, for a frame with no anchor
const RULE_DY := -32.0
const ICON_PANEL_DY := -16.0
const BODY_DY := 18.0
const FOOTER_DY := 484.0
const RULE_BOT_DY := 504.12
const HINT_DY := 520.12
const ROW_GAP := 18.0            # Qud's inter-row spacing; body->options and option->option
const RULE_H := 16.0
const FILL_L_X := 544.0
const HEAD_X := 872.0
const HEAD_W := 176.0
const FILL_R_X := 1048.0
const FILL_W := 328.0
const PANEL_X := 560.0
const PANEL_W := 800.0
const LINE_H := 20.12
const CARET_X := 593.0
const TEXT_X := 607.0


# Qud's own colours off the probe: body/option text #afc6c1, bracket #b1c9c3, hotkey #cfc041.
const C_TEXT := Color("#afc6c1")
const C_BRACKET := Color("#b1c9c3")
const C_HOTKEY := Color("#cfc041")

## Qud dims the WHOLE screen behind the terminal: the probe's `OuterBackground` is a 1920x1080 Image
## tinted #041111cc, i.e. 80%-opaque near-black over the playfield. This one is drawn (unlike the
## "Icon Panel" below) because the capture AGREES with the layout dump instead of contradicting it:
## Raves' undimmed playfield measures RGB(18,46,45) in the same region where Qud measures (7,23.3,
## 23.2), and compositing this colour at alpha .8 over Raves' value predicts (6.8,22.8,22.6) — a
## match to within half a level, on three separate sample regions. Without it Raves' terminal read
## twice as bright as Qud's everywhere outside the text.
const C_SCRIM := Color("#041111cc")

## THE PHOSPHOR TINT. Qud renders the terminal's own text green, and it does it on TOP of the
## ordinary colours rather than instead of them: the probe reports the row markup as Qud's normal
## greys (`<color=#b1c9c3FF>` = the `&y` palette entry, footer `#afc6c1`) while the PIXELS come out
## (150,255,169). Measured, that difference is a per-channel MULTIPLY, and the multiplier calibrated
## on `&y` alone predicts two colours it was not fitted to:
##     &C #77bfcf -> predicted (101,242,179), measured (98,242,184)
##     footer #afc6c1 -> predicted (148,251,167), measured (148,255,167)  [R and B exact]
## which is why this is a function of the source colour and not a flat green: an accent stays a
## distinguishable accent, exactly as it does in Qud. Applies to the ROW TEXT and the FOOTER only —
## the hint bar's gold (200,184,57 measured, i.e. untinted #cfc041) and the selection caret are
## outside the tinted content and must stay as they are.
const TERM_TINT := Vector3(150.0 / 177.0, 255.0 / 201.0, 169.0 / 195.0)

func _term(c: Color) -> Color:
	return Color(minf(c.r * TERM_TINT.x, 1.0), minf(c.g * TERM_TINT.y, 1.0),
		minf(c.b * TERM_TINT.z, 1.0), c.a)


## THE TYPEWRITER, straight off Qud's `CyberneticsTerminalRow.Update()`:
##   * 0.015s PER CHARACTER, and a long frame catches up in one go (`(int)(cursorTimer / 0.015f)`)
##     rather than dropping the backlog, so the reveal keeps real time on a slow frame.
##   * the cursor is a literal `_` appended to the revealed prefix (`Text.Substring(0, cursor) + "_"`)
##     -- that is the `tier_` visible in any mid-animation capture.
##   * rows type ONE AT A TIME, in order, body first: a finished row hands off with
##     `data.nextCursorData.row.currentCursor = true`. That sequential hand-off IS the sweep.
##   * the cursor counts characters of the RAW markup string, so it spends real time invisibly
##     "typing" the `&C` codes. Faithful here for the same reason: it is what sets the pacing.
##   * ANY command completes EVERYTHING instantly -- the check sits outside the per-row cursor
##     branch, so every row's Update() completes itself on the same frame.
const TYPE_DT := 0.015

var _data := {}
var _palette := {}
var _sel := 0
var _root: Control
var _cur_row := 0        # which row is typing: 0 = the body, 1+ = option (row - 1)
var _cur_pos := 0        # character index within that row's RAW text
var _cur_t := 0.0
var _typing := false
var _type_sig := ""      # the content the current animation belongs to (see show_terminal)
var _draw: Control
var _font: Font
var _caret_tex: Texture2D = null
var _rule_tex: Texture2D = null
var _head_tex: Texture2D = null
var _rule_tex_top: Texture2D = null   # the same two sprites mirrored, for the TOP rule (see _chrome_ex)
var _head_tex_top: Texture2D = null
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
	_rule_tex_top = _chrome_ex("picker_divider.png", true)
	_head_tex_top = _chrome_ex("term_header.png", true)
	_fit()
	get_viewport().size_changed.connect(_fit)


## SIZE THIS SUBTREE BY HAND, because anchors cannot do it here: Main is a **Node3D**, so this
## Control has no Control parent, PRESET_FULL_RECT resolves against nothing, and every rect in the
## subtree stays (0,0). That is not cosmetic -- a zero-size Control is never picked, so `_root` got
## no `gui_input` at all, which is why hover did nothing AND why a click never hit-tested a row.
##
## It also explains the earlier scrim no-op: `draw_rect(Rect2(Vector2.ZERO, _draw.size), ...)` drew
## an empty rectangle. Drawing kept working throughout because everything here draws in ABSOLUTE
## coordinates and Controls do not clip -- so the overlay LOOKED completely fine while being, as far
## as input was concerned, a zero-by-zero node. Rendering correctly is not evidence of a sane rect.
func _fit() -> void:
	var vs := get_viewport_rect().size
	position = Vector2.ZERO
	size = vs
	if _root != null:
		_root.position = Vector2.ZERO
		_root.size = vs
	if _draw != null:
		_draw.position = Vector2.ZERO
		_draw.size = vs


static func _chrome(fname: String) -> Texture2D:
	return _chrome_ex(fname, false)


## `flip_v` builds the MIRRORED copy of a chrome sprite. Qud draws the TOP rule flipped: measured
## against its own capture, the top rule's line lands on rows 2-3 of its 16px box and the bottom
## rule's on rows 13-14 — the same three sprites, mirrored, so the line hugs the panel's outer edge
## and the notch always points inward. Drawing both unflipped put the top rule 10px low on every
## terminal screen (the box was never wrong: Qud's own probe reports `polat top header` at y238.44,
## exactly vp+RULE_DY). Flip the IMAGE rather than passing a negative-height Rect2 — the fillers are
## drawn with tile=true, where a negative size is not reliably a mirror.
static func _chrome_ex(fname: String, flip_v: bool) -> Texture2D:
	var p := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	img = QudChrome.brighten(img)
	if flip_v:
		img.flip_y()
	return ImageTexture.create_from_image(img)


func show_terminal(data: Dictionary, palette: Dictionary) -> void:
	_data = data
	if not palette.is_empty():
		_palette = palette
	_sel = int(data.get("selected", 0))
	# Restart the reveal only when the CONTENT actually changed. The mirror republishes this frame
	# continuously (and re-sends the whole thing on every client connect), so keying the animation
	# off "a frame arrived" would retype the screen forever and it would never finish.
	var sig := String(data.get("body", ""))
	for o in (data.get("options", []) as Array):
		sig += "\n" + String(o)
	if sig != _type_sig:
		_type_sig = sig
		_start_typing()
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
	# Forget the signature, or REOPENING the same screen never retypes. Qud builds fresh rows on
	# every Show(), so closing the nook and walking back to it plays the reveal again. Leaving this
	# set made the animation look completely dead in testing: the first open had already consumed
	# the welcome screen's signature, so every later open matched it and skipped straight to done.
	_type_sig = ""
	_typing = false
	UiState.set_scene("in_game")


## Qud wraps the body at 67 columns before it ever reaches us (TerminalScreen's
## RenderedTextForModernUI = StringFormat.ClipText(MainText, 67, KeepNewlines: true)), so the
## newlines in the payload ARE Qud's line breaks. Splitting on them is reproducing its layout,
## not guessing at one — do not re-wrap.
func _body_lines() -> PackedStringArray:
	return _revealed(0).split("\n")


## The RAW text of a typing row: row 0 is the body, row n>0 is option n-1. Raw, not rendered —
## Qud's cursor walks the markup string, and the layout below has to agree with the reveal.
func _row_text(row: int) -> String:
	if row <= 0:
		return String(_data.get("body", ""))
	var opts: Array = _data.get("options", [])
	var i := row - 1
	return String(opts[i]) if i < opts.size() else ""


## What that row shows RIGHT NOW: nothing before its turn, prefix + `_` during it, all of it after.
func _revealed(row: int) -> String:
	if not _typing or row < _cur_row:
		return _row_text(row)
	if row > _cur_row:
		return ""
	return _row_text(row).substr(0, _cur_pos) + "_"


func _rows_total() -> int:
	return 1 + (_data.get("options", []) as Array).size()


func _start_typing() -> void:
	_cur_row = 0
	_cur_pos = 0
	_cur_t = 0.0
	_typing = true


## Qud completes EVERY row on any command, not just the one holding the cursor — the check sits
## outside the per-row cursor branch, so all of them finish on the same frame.
func _finish_typing() -> void:
	if _typing:
		_typing = false
		_draw.queue_redraw()


## Move the caret to the row under `p`, if any. Qud does this on HOVER with no click at all --
## measured by parking the pointer over one of its rows and watching the caret jump to it.
##
## NOT VERIFIED THROUGH THE HARNESS, and the reason is worth knowing before anyone tries again:
## `hv mouse` WARPS the cursor, and a warp delivers no InputEventMouseMotion to Godot, so the caret
## never moves under it. That is a fact about the harness, not about this code -- the same warp DOES
## move Qud's caret, because Unity polls the pointer position every frame instead of reading events.
## Polling was tried here on both `get_local_mouse_position()` (fed by the same events, so equally
## stale) and `DisplayServer.mouse_get_position()`; neither moved the caret under `hv mouse`, so the
## simple event handler is what ships. Confirm this one with a real mouse.
func _hover_at(p: Vector2) -> void:
	for r in _row_rects:
		if (r[0] as Rect2).has_point(p):
			if _sel != int(r[1]):
				_sel = int(r[1])
				_draw.queue_redraw()
			return


func _process(delta: float) -> void:
	if not visible:
		return
	if not _typing:
		return
	_cur_t += delta
	if _cur_t < TYPE_DT:
		return
	# Catch up whole characters, exactly as Qud does -- a long frame advances the reveal by the
	# number of ticks it covered rather than by one, so the animation keeps real time.
	var n := int(_cur_t / TYPE_DT)
	_cur_t -= TYPE_DT * float(n)
	_cur_pos += n
	# Hand off to the next row when this one runs out. The overshoot is DROPPED rather than carried:
	# Qud restarts the next row's timer from zero in setData, so a row always gets its full 0.015s
	# on its first character. `_cur_row` strictly increases, so this cannot spin on an empty row.
	while _typing and _cur_pos >= _row_text(_cur_row).length():
		_cur_row += 1
		_cur_pos = 0
		if _cur_row >= _rows_total():
			_typing = false
	_draw.queue_redraw()


## How many lines the body OCCUPIES — which is not the same as how many `split("\n")` returns.
## Some bodies end with a newline and some do not, and Qud lays the options out one gap below the
## last VISIBLE line either way. Read off the wire (2026-08-10), the upgrade sub-screen's body is
##     "…\n&C4&y credits for license tiers 25+\n"
## -> 8 elements, the last one empty, for 7 rendered lines; the welcome screen's has no trailing
## newline and split() is already right. Counting the empty tail put every option row on that one
## screen exactly one LINE_H low (measured +21px against Qud's capture) while the welcome screen
## matched to 1px — which is what made this look screen-specific rather than like an off-by-one.
## Only the single-trailing-newline case is measured; dropping the whole empty tail is the same
## rule stated generally ("options follow the last line with ink").
func _body_line_count() -> int:
	var lines := _body_lines()
	var n := lines.size()
	while n > 0 and String(lines[n - 1]).strip_edges() == "":
		n -= 1
	return n


func _render() -> void:
	if _data.is_empty():
		return
	# The full-screen dimming scrim goes down FIRST, under every other thing this draws. Sized from
	# the VIEWPORT rather than `_draw.size` — `_fit()` now keeps those equal, but this does not need
	# to depend on that having run.
	_draw.draw_rect(Rect2(Vector2.ZERO, _draw.get_viewport_rect().size), C_SCRIM)
	var vp: float = float(_data.get("vpY100", VP_Y_FALLBACK * 100.0)) / 100.0
	var rule_y := vp + RULE_DY
	var rule_bot_y := vp + RULE_BOT_DY
	# The two horizontal rules, three sprites each (filler | header | filler). The TOP one is drawn
	# from the MIRRORED copies so its line hugs the panel's top edge and the notch points down into
	# the panel, which is what Qud does — see _chrome_ex.
	var top_fill: Texture2D = _rule_tex_top if _rule_tex_top != null else _rule_tex
	var top_head: Texture2D = _head_tex_top if _head_tex_top != null else _head_tex
	for pair in [[rule_y, top_fill, top_head], [rule_bot_y, _rule_tex, _head_tex]]:
		var seg_y: float = pair[0]
		_rule_seg(FILL_L_X, seg_y, FILL_W, pair[1], true)
		_rule_seg(HEAD_X, seg_y, HEAD_W, pair[2], false)
		_rule_seg(FILL_R_X, seg_y, FILL_W, pair[1], true)
	# NOT DRAWN: the probe reports an "Icon Panel" here (560,254.44 800x16, sprite `solid`,
	# tint #ffffff63). Rendering that as a 39%-white band put a pale bar across the screen that
	# Qud's own capture does not have anywhere — the sprite is evidently not white, or the strip
	# is occluded. A node in the layout dump is not automatically INK; when the capture shows
	# nothing, draw nothing rather than invent an alpha that makes the diff worse.

	var asc := _font.get_ascent(16)
	var y := vp + BODY_DY
	# THE BODY CARRIES MARKUP TOO, and it is parsed as ONE string rather than per line.
	# The option rows always went through QudText; the body did not, because the first
	# screens had none — then the install refusal arrived as "&yInsufficent license points"
	# and Raves printed the codes verbatim (2026-08-10). `&X` is Qud's RUNNING colour: it
	# stays in force across newlines, so parsing line by line would drop the carry and
	# repaint the tail wrong. Parse whole, then break runs on their own newlines.
	var bx := TEXT_X
	for run in QudText.runs(_revealed(0), _palette, C_TEXT):
		var parts: PackedStringArray = String(run[0]).split("\n")
		for pi in parts.size():
			var seg: String = parts[pi]
			if pi > 0:
				bx = TEXT_X
				y += LINE_H
			if seg == "":
				continue
			_draw.draw_string(_font, Vector2(bx, y + asc).round(), seg,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, _term(run[1]))
			bx += _font.get_string_size(seg, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x

	# Options start one ROW_GAP below the body block and stack the same way — Qud's vertical
	# layout, derived rather than pinned, so a 3-line body and a 6-line one both land right.
	# The count comes from _body_line_count(), NOT lines.size(): a trailing newline is not a line.
	var opt_y0 := vp + BODY_DY + float(_body_line_count()) * LINE_H + ROW_GAP
	_row_rects.clear()
	var opts: Array = _data.get("options", [])
	for i in opts.size():
		var ry := opt_y0 + float(i) * (LINE_H + ROW_GAP)
		# The hit rect exists from the first frame even while the row is still blank, so the mouse
		# can hover-select a row Qud has not finished typing — which is what Qud does too (the row
		# object is created up front with empty text and its navigation context is live). What the
		# row cannot do yet is ACTIVATE; see _on_root_input.
		_row_rects.append([Rect2(PANEL_X, ry - 2.0, PANEL_W, LINE_H + 4.0), i])
		if i == _sel:
			_caret(ry)
		var shown := _revealed(i + 1)
		if shown == "":
			continue
		var runs: Array = QudText.runs(shown, _palette, C_TEXT)
		var x := TEXT_X
		for r in runs:
			var txt: String = r[0]
			_draw.draw_string(_font, Vector2(x, ry + asc).round(), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, _term(r[1]))
			x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x

	# footer — Qud's own composed string ("Credits: 0  License Tier: 2  Points Used: 2"); the
	# tier/points arithmetic is the screen's, never re-derived here. Tinted: measured green in
	# Qud's capture, and it is the pair that confirmed the multiply (see TERM_TINT).
	_draw.draw_string(_font, Vector2(PANEL_X, vp + FOOTER_DY + asc).round(),
		String(_data.get("footer", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, _term(C_TEXT))

	_hints(vp + HINT_DY)


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
func _hints(hint_y: float) -> void:
	var asc := _font.get_ascent(16)
	# Qud's first hint key is its own PUA input glyph (U+E80A), ONE character wide, and its x's
	# are laid out for that. Spelling it "Arrows" ran the bracket group into "navigate" — so use
	# the real glyph when the mod has extracted Qud's icon font, and a single-character stand-in
	# when it has not. Either way the row keeps Qud's measured positions.
	var nav_key := String.chr(0xE80A) if UiFont.qud_glyph_font() != null else "\u2195"
	for h in [[771.9, nav_key, 825.1, "navigate"], [916.9, "Space", 994.1, "accept"],
			[1066.7, "Esc", 1124.7, "quit"]]:
		var bx: float = h[0]
		_draw.draw_string(_font, Vector2(bx, hint_y + asc).round(), "[",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_BRACKET)
		var w1 := _font.get_string_size("[", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_draw.draw_string(_font, Vector2(bx + w1, hint_y + asc).round(), String(h[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_HOTKEY)
		var w2 := _font.get_string_size(String(h[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_draw.draw_string(_font, Vector2(bx + w1 + w2, hint_y + asc).round(), "]",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_BRACKET)
		_draw.draw_string(_font, Vector2(float(h[2]), hint_y + asc).round(), String(h[3]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_TEXT)


func _on_root_input(e: InputEvent) -> void:
	if e is InputEventMouseButton or e is InputEventMouseMotion:
		_root.accept_event()   # a modal owns the mouse; the wheel needs this (docs/gotchas.md)
	# HOVER SELECTS, because Qud's does: measured 2026-08-10 by parking the pointer over a row with
	# no click at all -- the caret moved to it. Without this the rows were already clickable (a click
	# round-trips through the bridge and Qud navigates) but nothing on screen responded to the mouse
	# until the click landed, so they did not READ as clickable.
	if e is InputEventMouseMotion:
		_hover_at(e.position)
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		# A click mid-reveal completes the text instead of choosing. Qud's HandleSelect refuses
		# outright while the row is still typing (`is CyberneticsTerminalLineData { CursorDone: not
		# false }`), so activating here would be wrong -- but a click that does NOTHING reads as a
		# broken control, and Qud already treats input during the reveal as "skip it". Completing is
		# that same gesture on the mouse; the second click selects.
		if _typing:
			_finish_typing()
			return
		for r in _row_rects:
			if (r[0] as Rect2).has_point(e.position):
				_sel = int(r[1])
				_draw.queue_redraw()
				answered.emit({"action": "select", "index": _sel})
				return


func handle_key(e: InputEventKey) -> bool:
	if not visible:
		return false
	# ANY key completes the reveal and is swallowed -- Qud's rows check
	# `ControlManager.currentFrameCommands.Count > 0` before they check their own cursor, so the
	# keypress that skips the animation does not also navigate or accept.
	if _typing:
		_finish_typing()
		return true
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
			# Keyed by ROW INDEX, not the option text: the text is Qud's and varies with what the
			# terminal is offering, so it would scatter one control across a dozen buckets.
			return {"label": "terminal · %s" % (String(opts[i]) if i < opts.size() else "?"),
				"key": "terminal.row", "rect": r[0]}
	return {}

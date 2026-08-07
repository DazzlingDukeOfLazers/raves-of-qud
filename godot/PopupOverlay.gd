class_name PopupOverlay
extends CanvasLayer

## Mirrors a Qud modal popup that the mod forwarded over the bridge — message, Yes/No, an option list
## (PickOption), or a text prompt (AskString). While visible it is MODAL: it consumes keyboard input in
## `_input` (which runs before the Holodeck's `_unhandled_input`), so movement / wishes don't leak through.
## The viewer's answer is emitted as `answered`; Main relays it as a "popup" command, which invokes Qud's
## own popup callback and unblocks the turn thread the real popup is parked on.
##
## Answer payloads (→ mod PopupBridge.HandleCommand):
##   {"action":"button","btn":<command>}   dismiss with a bottom button (Accept/Yes/No/Cancel/…)
##   {"action":"option","index":<i>}        pick option i from a PickOption list
##   {"action":"input","text":<s>}          submit AskString text

signal answered
## Emitted whenever the modal leaves the screen -- answered here, or dismissed by Qud.
## Screens behind it use this to refresh: an item action only lands when the viewer
## ANSWERS, so that is the moment their data is stale, not when the menu opened.
signal closed(payload: Dictionary)

var _palette := {}
var _cur_id := -1             # id of the popup currently shown (or last answered) — dedupes resends
var _content_sig := ""        # content fingerprint — a flap re-announce must not reset typed input
var _buttons: Array = []      # [{text,command,hotkey}] — the bottom button row
var _options: Array = []      # [{text,command}] — PickOption items (empty for a plain message)
var _sel := 0                 # highlighted option index (menu mode)
var _bsel := 0                # keyboard-selected BUTTON (message/confirm mode)
var _built := false

var _root: Control
var _title: RichTextLabel
var _msg: RichTextLabel
var _opt_box: VBoxContainer
# The CONTEXT HEADER Qud puts above the command list: the subject's tile and its name,
# closed off by a divider (PopupMessage's contextImage / contextText / contextFrame).
# MEASURED off the item menu: panel x840-1079 (240 wide), top line y334, tile box 48x72
# centred on the panel at y360, name ink y447-458, divider y485.
var _ctx_box: VBoxContainer
var _ctx_img: Control
var _ctx_text: RichTextLabel
var _ctx_tex: Texture2D = null
var _ctx_tiles: RefCounted = null
const CTX_IMG := Vector2(48, 72)   # Qud's contextImage RectTransform, read off a live one
# Everything else in the header, MEASURED off Qud's own popup as offsets from the top
# LINE (not from the panel, whose padding differs): tile box +26 (its ink then lands at
# +35, the sprite's opaque box starting 3 rows in), the name's ink at +113, the divider
# at +151, and the first command's ink 22 below that. Driving the block off the line
# keeps it independent of container layout timing -- the first attempt read
# _ctx_box.size.y during the panel's draw, which is still stale on the show frame, and
# put the divider straight through the name.
const CTX_TILE_TOP := 26.0
const CTX_NAME_INK := 113.0
const CTX_DIVIDER := 151.0
const CTX_OPT_GAP := 22.0
# How far a RichTextLabel's first ink sits below its own top at this size -- MEASURED
# (the name landed 25px low on a -4 guess), not derived, because it is the label's
# internal leading plus the [center] block's, which Godot does not expose.
const CTX_NAME_SIZE := 16
var _ctx_name_runs: Array = []

## Qud's own contextText.color, scaled to land its RENDERED ink. Same concession as the
## inventory list's small text: at this size the glyphs are thin enough that
## rasterisation decides the result and Godot's reaches brighter than Unity's -- measured
## mean ink (94.7,123.7,120.1) against ours (115.7,143.2,139.9). The markup-coloured runs
## (the AV/DV badges) are left alone; those already match to the pixel.
func _ctx_name_color(ctx: Dictionary) -> Color:
	var c := Color(str(ctx.get("textColor", "#a8c2bb")))
	return Color(c.r * 0.819, c.g * 0.863, c.b * 0.859)
var _edit: LineEdit
var _btn_row: HBoxContainer

func _init() -> void:
	layer = 130                # above the chrome; below nothing that matters
	visible = false

func _ready() -> void:
	_build()

# Qud dialog chrome, measured off reports/2026-08-04-status-screens/sysmenu_qud.png
# (panel bg 6,37,37 · inset top line 53,90,98 with a centred gap + short stops ·
# bottom line 64,106,115 carrying the button text in its gap · selected option =
# 26px bar 23,59,60 with a gold ">" · option/hotkey colours come from Qud's own
# {{...}} markup via QudText.to_bbcode). Drawn at +6/channel above the dark knee —
# the same capture-fitted compensation as ControlMappingScreen (q8 overshoots here).
static func _cq(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_PANEL := _cq(6, 37, 37)
var C_TOPLINE := _cq(53, 90, 98)
var C_BOTLINE := _cq(64, 106, 115)
var C_SELBAR := _cq(23, 59, 60)
var C_GOLD := _cq(200, 184, 57)
var C_PALE := _cq(168, 194, 187)
var C_BTN := _cq(100, 140, 135)

var _panel: PanelContainer
var _sb_box: StyleBoxFlat
var _sb_banner: StyleBoxFlat
var _banner := false         # wide-strip mode (plain message / yes-no confirms)

func _build() -> void:
	if _built:
		return
	_built = true
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP       # eat clicks headed for the Holodeck
	_root.theme = UiFont.make_theme(get_viewport())      # dodge the CanvasLayer tiny-font trap
	add_child(_root)

	# Qud's popup backdrop reads as a near-flat (17,52,51) teal with faint field
	# detail. This layer (130) sits ABOVE the CRT, so the status-screens scrim
	# formula doesn't transfer (it was fitted on pre-CRT input and rendered too
	# dark here) — a high-alpha flat teal lands on the measured value instead.
	var dim := ColorRect.new()
	var dc := _cq(17, 52, 51)
	dc.a = 0.88
	dim.color = dc
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	# BOXED style (menus / inputs): measured insets 25 l/r · 24 top · 6 bottom
	_sb_box = StyleBoxFlat.new()
	_sb_box.bg_color = C_PANEL
	_sb_box.content_margin_left = 25
	_sb_box.content_margin_right = 25
	_sb_box.content_margin_top = 24
	_sb_box.content_margin_bottom = 6
	# BANNER style (plain messages / yes-no): Qud's wide strip — same opaque fill,
	# tighter top (line at +4, text at +24) — measured off the defaults confirm
	# (strip 673x76 for a one-line message)
	_sb_banner = StyleBoxFlat.new()
	_sb_banner.bg_color = C_PANEL
	_sb_banner.content_margin_left = 25
	_sb_banner.content_margin_right = 25
	_sb_banner.content_margin_top = 20
	_sb_banner.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", _sb_box)
	_panel.custom_minimum_size = Vector2(160, 0)   # Qud sizes to content (titled picker = 221)
	_panel.draw.connect(_draw_chrome)
	center.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	_title = _mk_rt()
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF   # the title's natural width drives the panel
	vb.add_child(_title)
	_msg = _mk_rt()
	vb.add_child(_msg)

	# context header, above the commands (Qud's order: image, then name, then divider)
	# ONE fixed-height block: the tile is drawn into it and the name is a child placed
	# by hand, so both land on Qud's offsets regardless of when the container settles.
	_ctx_box = VBoxContainer.new()
	_ctx_box.visible = false
	vb.add_child(_ctx_box)
	_ctx_img = Control.new()
	_ctx_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ctx_img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ctx_img.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctx_img.draw.connect(_draw_ctx_img)
	_ctx_box.add_child(_ctx_img)
	_ctx_text = _mk_rt()
	_ctx_text.autowrap_mode = TextServer.AUTOWRAP_OFF
	_ctx_text.add_theme_color_override("default_color", C_PALE)
	_ctx_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ctx_img.add_child(_ctx_text)

	_opt_box = VBoxContainer.new()
	_opt_box.add_theme_constant_override("separation", 2)
	vb.add_child(_opt_box)

	_edit = LineEdit.new()
	_edit.custom_minimum_size = Vector2(400, 0)
	_edit.add_theme_color_override("font_color", C_PALE)
	_edit.add_theme_color_override("caret_color", C_PALE)
	var esb := StyleBoxFlat.new()
	esb.bg_color = Color8(2, 22, 22)
	esb.set_border_width_all(1)
	esb.border_color = C_BOTLINE
	esb.content_margin_left = 8
	esb.content_margin_top = 4
	esb.content_margin_bottom = 4
	_edit.add_theme_stylebox_override("normal", esb)
	_edit.add_theme_stylebox_override("focus", esb)
	_edit.text_submitted.connect(func(_t: String): _submit_input())
	_edit.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			_cancel())
	vb.add_child(_edit)

	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 34)
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(_btn_row)

## The Qud dialog frame, measured off sysmenu_qud.png + the titled "Selected Bind
## Set" picker: the top line is FULL WIDTH with a 10px centre notch (down-ticks at
## its edges) and 6px side notches at ±w/3.1 (outward ticks) — not one big gap.
## A TITLE gets its own row under the line (gold, centred), flanked by ─┤ ├─
## assemblies at the panel edges; the line drops to +16 to make room. The bottom
## line runs through the button row's gap with stops.
func _draw_chrome() -> void:
	var w := _panel.size.x
	var h := _panel.size.y
	var ly := 4.0 if _banner else (16.0 if _title.visible else 8.0)
	var cx := w * 0.5
	# side notches sit at ±71 on both recently-measured popups (picker AND the wide
	# banner); the sysmenu's ±92 tracked w/3.1 — use the fixed offset, clamped in
	var side := minf(71.0, w * 0.32)
	var l0 := cx - side - 3.0
	var l1 := cx - side + 3.0
	var c0 := cx - 5.0
	var c1 := cx + 5.0
	var r0 := cx + side - 3.0
	var r1 := cx + side + 3.0
	for seg in [[0.0, l0], [l1, c0], [c1, r0], [r1, w]]:
		_panel.draw_rect(Rect2(seg[0], ly, seg[1] - seg[0], 2), C_TOPLINE)
	_panel.draw_rect(Rect2(l0 - 2, ly - 4, 2, 10), C_TOPLINE)   # ╢ outward side ticks
	_panel.draw_rect(Rect2(r1, ly - 4, 2, 10), C_TOPLINE)       # ╟
	_panel.draw_rect(Rect2(c0 - 2, ly, 2, 10), C_TOPLINE)       # ╖ centre down-ticks
	_panel.draw_rect(Rect2(c1, ly, 2, 10), C_TOPLINE)           # ╓
	# The context block is closed off by its own full-width divider, notched like the top
	# line (Qud: top line y334, divider y485 -- both segmented the same way).
	if _ctx_box.visible:
		var dy := ly + CTX_DIVIDER
		for seg in [[0.0, l0], [l1, c0], [c1, r0], [r1, w]]:
			_panel.draw_rect(Rect2(seg[0], dy, seg[1] - seg[0], 2), C_TOPLINE)
		_panel.draw_rect(Rect2(l0 - 2, dy - 4, 2, 10), C_TOPLINE)
		_panel.draw_rect(Rect2(r1, dy - 4, 2, 10), C_TOPLINE)
		_panel.draw_rect(Rect2(c0 - 2, dy, 2, 10), C_TOPLINE)
		_panel.draw_rect(Rect2(c1, dy, 2, 10), C_TOPLINE)
	if _title.visible:
		# ─┤ Title ├─ edge assemblies at the title row's mid-height
		var ty := 28.0 + _title.get_combined_minimum_size().y * 0.5
		_panel.draw_rect(Rect2(0, ty - 1, 10, 2), C_BOTLINE)
		_panel.draw_rect(Rect2(10, ty - 8, 2, 16), C_BOTLINE)
		_panel.draw_rect(Rect2(w - 12, ty - 8, 2, 16), C_BOTLINE)
		_panel.draw_rect(Rect2(w - 10, ty - 1, 10, 2), C_BOTLINE)
	# bottom line through the button row (or plain, 14 up, when there are no buttons).
	# Use MINIMUM sizes — the actual rects aren't laid out yet on the show frame.
	var by := h - 14.0
	var bw := 0.0
	if _btn_row.visible and _btn_row.get_child_count() > 0:
		var bh := _btn_row.get_combined_minimum_size().y
		by = h - 6.0 - bh * 0.5
		for c in _btn_row.get_children():
			if c is Control:
				bw += (c as Control).get_combined_minimum_size().x
		bw += 18.0 * maxi(0, _btn_row.get_child_count() - 1)
	if bw > 0.0:
		var b0 := (w - bw) * 0.5 - 12.0
		var b1 := (w + bw) * 0.5 + 12.0
		_panel.draw_rect(Rect2(0, by, b0 - 4, 1), C_BOTLINE)
		_panel.draw_rect(Rect2(b1 + 4, by, w - b1 - 4, 1), C_BOTLINE)
		_panel.draw_rect(Rect2(b0 - 4, by - 7, 2, 14), C_BOTLINE)
		_panel.draw_rect(Rect2(b1 + 2, by - 7, 2, 14), C_BOTLINE)
	else:
		_panel.draw_rect(Rect2(0, by, w, 1), C_BOTLINE)

## Build the header from the mod's `context` block. The mod ships RESOLVED rgba for the
## two tones (UIThreeColorProperties.Foreground/Detail), so there is no palette lookup
## here -- and it ships the tile as PIXELS under a per-popup filename, because the sprite
## comes off an atlas with no name of its own to send.
func _apply_context(ctx: Dictionary) -> void:
	_ctx_tex = null
	if ctx.is_empty():
		_ctx_box.visible = false
		return
	var tile := str(ctx.get("tile", ""))
	if tile != "":
		if _ctx_tiles == null:
			_ctx_tiles = load("res://QudTiles.gd").new()
		_ctx_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
		_ctx_tex = _ctx_tiles.texture(tile,
			Color(str(ctx.get("fg", "#ffffff"))), Color(str(ctx.get("dt", "#ffffff"))))
	_ctx_img.visible = _ctx_tex != null
	# Prefer the palette the POPUP carries: a popup can be the first thing drawn after
	# connecting, before any snapshot has delivered one, and the client's fallback table
	# disagrees with Qud (the status screens hit this too). Without it the AV/DV badges
	# lose their markup colours and the whole line renders in one flat tone.
	var pal: Dictionary = ctx.get("palette", {})
	if pal.is_empty():
		pal = _palette
	elif _palette.is_empty():
		_palette = pal
	var txt := str(ctx.get("text", ""))
	_ctx_name_runs = QudText.runs(txt, pal, _ctx_name_color(ctx)) if txt != "" else []
	_ctx_text.visible = false   # the name is DRAWN now, not laid out (see _draw_ctx_img)
	_ctx_box.visible = _ctx_tex != null or not _ctx_name_runs.is_empty()
	if _ctx_box.visible:
		# reserve exactly the room Qud's header occupies: down to the divider, plus the
		# gap it leaves before the first command (minus the VBox separation that follows)
		_ctx_img.custom_minimum_size = Vector2(CTX_IMG.x,
			CTX_DIVIDER + CTX_OPT_GAP - CTX_TILE_TOP - 12.0)
	_ctx_img.queue_redraw()

## The context tile: Qud stretches the whole 16x24 sprite into a 48x72 box (3x, its
## RectTransform read off a live popup), so no aspect fitting and no opaque-box games --
## the same law as the filter bar and the paper doll, at a third size.
func _draw_ctx_img() -> void:
	var top := _ctx_top_local()
	if _ctx_tex != null:
		# centred on the PANEL, which is what Qud centres on (its tile box lands dead on
		# the panel's midline), at the block-local y that puts the ink on Qud's +35
		var x := (_ctx_img.size.x - CTX_IMG.x) * 0.5
		_ctx_img.draw_texture_rect(_ctx_tex, Rect2(Vector2(x, top), CTX_IMG), false)
	# The NAME is drawn here too, in the SAME pass and off the SAME `top`. It used to be
	# a RichTextLabel positioned from a deferred callback, which re-read that offset at a
	# different moment -- when the layout shifted in between, the tile landed right and
	# the name did not, intermittently. One pass, one reading, no drift. Drawing it also
	# retires the guessed label leading: the baseline is the font's own ascent.
	if _ctx_name_runs.is_empty():
		return
	var f := _ctx_font()
	if f == null:
		return
	var total := 0.0
	for run in _ctx_name_runs:
		total += f.get_string_size(run[0], HORIZONTAL_ALIGNMENT_LEFT, -1, CTX_NAME_SIZE).x
	var px := (_ctx_img.size.x - total) * 0.5
	# -5: CTX_NAME_INK is where Qud's INK starts, and a baseline of ink_top + ascent
	# lands the cap 5px low, ascent being taller than the cap height. Measured against
	# Qud's own band (+113..+124) rather than derived from font metrics Godot rounds.
	var baseline := top + (CTX_NAME_INK - CTX_TILE_TOP) + f.get_ascent(CTX_NAME_SIZE) - 5.0
	for run in _ctx_name_runs:
		var txt: String = run[0]
		_ctx_img.draw_string(f, Vector2(px, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, CTX_NAME_SIZE, run[1])
		px += f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, CTX_NAME_SIZE).x

func _ctx_font() -> Font:
	if _ctx_img == null:
		return null
	return _ctx_img.get_theme_default_font()

## Local y of the tile box inside the block: the block starts at the panel's content
## margin, the offsets are quoted from the top LINE, so convert once here.
func _ctx_top_local() -> float:
	return CTX_TILE_TOP - (_ctx_img.global_position.y - _panel.global_position.y - _line_y())

func _line_y() -> float:
	return 4.0 if _banner else (16.0 if _title.visible else 8.0)

func _mk_rt() -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.custom_minimum_size = Vector2(120, 0)   # content-driven width; _msg widens itself when visible
	rt.add_theme_font_size_override("normal_font_size", 16)
	rt.add_theme_color_override("default_color", C_PALE)
	return rt

## Show / update the overlay from a mod popup frame. `palette` is the Qud colour map from the last snapshot.
func show_popup(data: Dictionary, palette: Dictionary) -> void:
	if not _built:
		_build()
	if not palette.is_empty():
		_palette = palette
	var id := int(data.get("id", -1))
	if id == _cur_id:
		return                      # same popup (or one we already answered) — don't rebuild/reshow
	# a re-announced popup with IDENTICAL content (watcher flap / reconnect): keep the
	# user's half-typed input instead of rebuilding — the reset-while-typing bug
	var content_sig := "%s|%s|%s|%s|%s" % [str(data.get("message", "")), str(data.get("title", "")),
		str(data.get("buttons", [])), str(data.get("options", [])), str(data.get("input", false))]
	if content_sig == _content_sig and visible:
		# Same popup, new id (the watcher re-announced it). Rebuilding here throws away
		# what the viewer has done to it: it used to reset half-typed input, and it also
		# reset an option list's SELECTION -- pressing Down moved the bar and then it
		# sprang back to the first row a second later, which reads as "arrows do nothing".
		# Adopt the id and keep the state.
		_cur_id = id
		if bool(data.get("input", false)) and _edit != null:
			UiState.set_popup("input")
			_edit.grab_focus()
		return
	_content_sig = content_sig
	_cur_id = id
	_buttons = data.get("buttons", [])
	_options = data.get("options", [])
	var is_input := bool(data.get("input", false))
	_apply_context(data.get("context", {}))

	var title_markup := str(data.get("title", "")).strip_edges()
	_title.visible = title_markup != ""
	if _title.visible:
		# Qud renders dialog titles centred in GOLD (palette 'W') on their own row
		# under the top line — unmarked title text inherits the gold; any {{...}}
		# markup inside still wins
		var goldhex := String(_palette.get("W", "#cfc041"))
		if not goldhex.begins_with("#"):
			goldhex = "#" + goldhex
		_title.text = "[center][color=%s]%s[/color][/center]" % [goldhex,
			QudText.to_bbcode(title_markup, _palette)]
	var msg_raw := str(data.get("message", ""))
	# menus ship an EMPTY body ("{{y|}}") — hide it or it pads the panel to msg width
	_msg.visible = QudText.strip(msg_raw).strip_edges() != ""
	_msg.text = QudText.to_bbcode(msg_raw, _palette)
	# BANNER mode (Qud's wide strip) for plain messages / confirms — no options, no
	# input. The message's natural width drives the strip, capped so long text wraps.
	_banner = _options.is_empty() and not is_input
	_panel.add_theme_stylebox_override("panel", _sb_banner if _banner else _sb_box)
	if _banner and _msg.visible:
		var f := _root.get_theme_font("font", "Label")
		var natural := f.get_string_size(QudText.strip(msg_raw),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_msg.custom_minimum_size = Vector2(minf(natural + 4.0, 1240.0), 0)
	else:
		_msg.custom_minimum_size = Vector2(430, 0)

	_build_options()
	_build_buttons()

	_edit.visible = is_input
	if is_input:
		_edit.text = str(data.get("inputDefault", ""))
	_opt_box.visible = _options.size() > 0
	_sel = 0
	_highlight_option()

	visible = true
	if is_input:
		_edit.grab_focus()
		_edit.caret_column = _edit.text.length()
	else:
		_edit.release_focus()
	# highvisor state report: a popup is up (kind feeds `hv assert --popup …`)
	UiState.set_popup("input" if is_input else ("menu" if _options.size() > 0 else "message"))

func _build_buttons() -> void:
	for c in _btn_row.get_children():
		_btn_row.remove_child(c)   # remove NOW — queue_free'd rows linger a frame and
		c.queue_free()             # poison get_children() on a same-frame re-show
	for b in _buttons:
		var bt := Button.new()
		bt.set_meta("base", QudText.strip(str(b.get("text", ""))))
		bt.focus_mode = Control.FOCUS_NONE
		bt.flat = true
		bt.add_theme_font_size_override("font_size", 16)
		bt.add_theme_color_override("font_hover_color", C_PALE)
		bt.add_theme_color_override("font_pressed_color", C_PALE)
		var empty := StyleBoxEmpty.new()
		for sn in ["normal", "hover", "pressed", "focus"]:
			bt.add_theme_stylebox_override(sn, empty)
		var cmd := str(b.get("command", ""))
		bt.pressed.connect(func(): _answer_button(cmd))
		_btn_row.add_child(bt)
	_bsel = 0
	_refresh_btn_sel()
	_panel.queue_redraw()   # the bottom line's gap tracks the button row

## Qud marks the keyboard-selected button with a "> " cursor (Left/Right move it,
## Space/Enter answer it).
func _refresh_btn_sel() -> void:
	var kids := _btn_row.get_children()
	for i in kids.size():
		var bt: Button = kids[i]
		var base := str(bt.get_meta("base", bt.text))
		if i == _bsel and kids.size() > 1:
			bt.text = "> " + base
			bt.add_theme_color_override("font_color", C_PALE)
		else:
			bt.text = base
			bt.add_theme_color_override("font_color", C_BTN)
	_panel.queue_redraw()

## Option rows keep QUD'S OWN colours ({{W|[k]}} hotkeys etc.) via to_bbcode; the
## selected row gets Qud's 26px bar + gold ">" cursor.
func _build_options() -> void:
	for c in _opt_box.get_children():
		_opt_box.remove_child(c)
		c.queue_free()
	for i in _options.size():
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, 26)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var rt := _mk_rt()
		rt.fit_content = true
		rt.autowrap_mode = TextServer.AUTOWRAP_OFF
		rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(rt)
		var idx := i
		row.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_answer_option(idx))
		row.mouse_entered.connect(func(): _sel = idx; _highlight_option())
		_opt_box.add_child(row)

func _highlight_option() -> void:
	var kids := _opt_box.get_children()
	var goldc := "#%s" % C_GOLD.to_html(false)
	for i in mini(kids.size(), _options.size()):
		var row: PanelContainer = kids[i]
		var rt: RichTextLabel = row.get_child(0)
		var body := QudText.to_bbcode(str(_options[i].get("text", "")), _palette)
		if i == _sel:
			rt.text = "[color=%s]> [/color]%s" % [goldc, body]
			var sb := StyleBoxFlat.new()
			sb.bg_color = C_SELBAR
			sb.content_margin_left = 4
			row.add_theme_stylebox_override("panel", sb)
		else:
			rt.text = "  " + body
			var sbe := StyleBoxEmpty.new()
			sbe.content_margin_left = 4
			row.add_theme_stylebox_override("panel", sbe)

# --- input -----------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if _edit.visible:
		return                      # text prompt: let the LineEdit type; Enter/Esc via its gui_input
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var kc: int = event.keycode
	if _options.size() > 0:
		match kc:
			KEY_UP, KEY_KP_8:   _sel = max(0, _sel - 1); _highlight_option()
			KEY_DOWN, KEY_KP_2: _sel = min(_options.size() - 1, _sel + 1); _highlight_option()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _answer_option(_sel)
			KEY_ESCAPE: _cancel()
			_:
				if not _try_option_hotkey(event) and not _try_button_hotkey(kc):
					return          # let unrelated keys through (nothing else should, but be safe)
	else:
		match kc:
			KEY_LEFT, KEY_KP_4:
				_bsel = maxi(0, _bsel - 1)
				_refresh_btn_sel()
			KEY_RIGHT, KEY_KP_6:
				_bsel = mini(maxi(0, _buttons.size() - 1), _bsel + 1)
				_refresh_btn_sel()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				if _bsel < _buttons.size():
					_answer_button(str(_buttons[_bsel].get("command", "")))
				else:
					_answer_token("Accept")
			KEY_ESCAPE: _answer_token("Cancel")
			_:
				if not _try_button_hotkey(kc):
					return
	get_viewport().set_input_as_handled()

## Pick an option by its own hotkey. An item menu's rows read "[d] drop", "[E] Equip
## (manual)" -- and the letter is in the row TEXT, not in QudMenuItem.hotkey, so scanning
## the hotkey field alone matched nothing and every letter escaped the modal to the app
## underneath (pressing "l" for look toggled Raves' font ruler behind the popup).
##
## CASE MATTERS: Qud gives one item "[e] equip (auto)" and the next "[E] Equip (manual)",
## so the shift state has to agree with the bracketed letter's case.
func _try_option_hotkey(event: InputEventKey) -> bool:
	if _options.is_empty():
		return false
	var kc: int = event.keycode
	if kc < KEY_A or kc > KEY_Z:
		return false
	var upper: bool = event.shift_pressed
	var want: String = char(kc) if upper else char(kc).to_lower()
	for i in _options.size():
		var txt := QudText.strip(str(_options[i].get("text", ""))).strip_edges()
		# also honour the field when Qud does populate it
		for tok in str(_options[i].get("hotkey", "")).split(","):
			if tok.strip_edges() == want:
				_sel = i
				_answer_option(i)
				return true
		if txt.length() >= 3 and txt[0] == "[":
			var close := txt.find("]")
			if close == 2 and txt.substr(1, 1) == want:
				_sel = i
				_answer_option(i)
				return true
	return false

## Map a letter key to a bottom button whose hotkey lists that letter (e.g. Y → the "Yes" button).
func _try_button_hotkey(kc: int) -> bool:
	if kc < KEY_A or kc > KEY_Z:
		return false
	var letter := char(kc)          # Godot letter keycodes equal ASCII uppercase
	for b in _buttons:
		for tok in str(b.get("hotkey", "")).split(","):
			if tok.strip_edges().to_upper() == letter:
				_answer_button(str(b.get("command", "")))
				return true
	return false

## Dismiss via the button carrying a named hotkey token ("Accept" for Space/Enter, "Cancel" for Esc).
func _answer_token(token: String) -> void:
	for b in _buttons:
		for tok in str(b.get("hotkey", "")).split(","):
			if tok.strip_edges() == token:
				_answer_button(str(b.get("command", "")))
				return
	if token == "Accept" and _buttons.size() > 0:
		_answer_button(str(_buttons[0].get("command", "")))
	# "Cancel" with no cancel button → this popup can't be escaped; ignore.

func _answer_button(command: String) -> void:
	_finish({"action": "button", "btn": command})

func _answer_option(index: int) -> void:
	if index < 0 or index >= _options.size():
		return
	# the chosen option's plain text rides along (the mod ignores it) so Main can
	# mirror menu picks locally — e.g. "Control Mapping" opens Raves' own screen
	_finish({"action": "option", "index": index,
		"text": QudText.strip(str(_options[index].get("text", "")))})

func _submit_input() -> void:
	_finish({"action": "input", "text": _edit.text})

func _cancel() -> void:
	_answer_token("Cancel")

## Emit the answer and hide locally. We keep `_cur_id` so a stale resend of the same popup can't reshow it;
## a fresh popup (new id) or a normal snapshot (via hide) resets it.
func _finish(payload: Dictionary) -> void:
	visible = false
	_edit.release_focus()
	UiState.clear_popup()
	answered.emit(payload)

## Called on `active:false` and on any normal snapshot (a snapshot can only publish once Qud's turn thread
## has unblocked — i.e. the popup is gone) so a coalesced-away dismissal can't strand the overlay.
func hide_popup() -> void:
	var was := visible
	if visible:
		visible = false
		_edit.release_focus()
	UiState.clear_popup()
	_cur_id = -1
	if was:
		closed.emit()

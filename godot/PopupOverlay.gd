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
# +35, the sprite's opaque box starting 3 rows in), the name's ink at +113 and the divider
# at +151. (There is no constant for the gap to the first command any more: it is not part
# of the header at all, it is MenuControll's own spacing.) Driving the block off the line
# keeps it independent of container layout timing -- the first attempt read
# _ctx_box.size.y during the panel's draw, which is still stale on the show frame, and
# put the divider straight through the name.
const CTX_TILE_TOP := 26.0
const CTX_NAME_INK := 113.0
const CTX_DIVIDER := 151.0

## QUD'S POPUP BOX MODEL — ported whole, 2026-08-08, from the live RectTransforms
## (`uiprobe target=PopupMessage`) of four popups: three item menus of 7/8/9 options and
## widths 239.81/278.21/433.61, plus the wish AskString (650x76.72, no context header).
## Every number below is Qud's own; nothing here is fitted to a capture.
##
##   PopupMessage   1920x1080 VerticalLayoutGroup, align MiddleCenter, no padding
##     MenuControll spacing 10, pad L20 R20 T0 B5 -- THE BOX. Qud CENTRES this, and the
##                  visible chrome hangs off it (see below); it does not centre the chrome.
##       ContextContainer  spacing 10, pad T10, MiddleCenter
##                         = 10 + tile 72 + 10 + name 20.12 + 10 + divider 16 = 138.12
##       [PolatFrameSuperHeader 20]      the title row -- AFTER the context block
##       Scroll View / Content  spacing 2, pad L5 R5
##                         = Message + 2 + options area + 2 + inputbox
##                           options area = 26 per row, spacing 2
##       MenuCrome         20 tall, spacing 5, pad L-20 R-20 (so it spans the WHOLE box)
##
## Verified arithmetic (probe vs model, both popups): 138.12 + 10 + 224 + 10 + 20 + 5 =
## 407.12 = the probe's MenuControll h, and y = (1080-407.12)/2 = 336.44 = the probe's y.
const BOX_SPACING := 10.0
const BOX_PAD_LR := 20.0
const BOX_PAD_B := 5.0
const CTX_H := 138.12              # ContextContainer, a CONSTANT across every item probed
const CROME_H := 20.0              # MenuCrome (the bottom command bar)
const CROME_SP := 5.0              # its spacing, and the gutter inside each option
const CROME_PAD_L := 2.0           # MenuOptionText padL
const CROME_CURSOR := 8.0          # its Selection Cursor cell -- present even when unselected
const CROME_PAD_R := 20.0          # MenuOptionText padR
## MenuCrome's two line sprites stretch, but they have a MINIMUM of 25 -- and that minimum
## can size the whole popup. Qud's quit confirm is the case that shows it: its message only
## asks for 383.40 of content, its three entries for 393.40, and the box comes out 453.40 =
## 393.40 + 2 spacings + 2 lines at their 25px floor. No other kind reaches it, which is
## exactly why the box model had to be checked against a yes/no and not only a menu.
const CROME_LINE_MIN := 25.0
const ROW_H := 26.0                # MenuOptionText(Clone) in the options area
const ROW_TEXT_X := 15.0           # padL 2 + cursor 8 + spacing 5
const CONTENT_PAD_LR := 5.0        # Content padL/padR
const MSG_LINE := 20.12            # Qud's Message/ContextItemText line box at font 16
const MSG_W_MAX := 1240.0          # our own wrap cap; Qud's comes from the caller
const EDIT_W := 600.0              # AskString inputbox -- what makes the wish box 650 wide
const EDIT_H := 17.6

## WHERE THE CHROME HANGS OFF THE BOX. Qud's visible rules do NOT bound the centred box:
## measured on the item popup (box y336.44 h407.12) and confirmed on the wish popup
## (box y501.64 h76.72), whose different fractional origin is what pins these to the
## pixel rather than to one capture:
##   top rule ink    rows 320-321 / 486-487   = box_top - 16, 2px tall
##   opaque fill     rows 316-741 / 482-575   = box_top - 20 .. box_bottom - 2
##   bottom rule ink row 728 / 563            = box_bottom - 15.5, 1px tall
## i.e. the top rule sits 16px ABOVE the box and the bottom rule 15.5px INSIDE it.
const CHROME_TOP := -16.0
const FILL_TOP := -20.0
const FILL_BOT := -2.0
const CHROME_BOT := -15.5
## The bottom rule's line sprites are 15 tall, MiddleCentred in the 20px MenuCrome row,
## and carry a 1px end tick down their whole height (Qud: x879 / x1040, rows 721-735).
const CROME_TICK_TOP := -22.5
const CROME_TICK_H := 15.0
## One-shot layout dump for a measure cycle -- writes the carrier rect, the exact box and
## the offset between them to <support>/popup_layout.txt on every draw. It is what settled
## the "Godot ceils a fractional container minimum" and "position is not readable from a
## draw callback" questions, both of which had been guessed at from pixels first. FALSE in
## a shipped build.
const _DEBUG_LAYOUT := false
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

var _panel: PanelContainer   # == Qud's MenuControll. Its RECT is the box; the chrome hangs off it.
var _sb_box: StyleBoxFlat
var _scroll_wrap: MarginContainer   # Qud's Scroll View -> Content padding (L5 R5)
var _content: VBoxContainer         # Content: Message / options area / inputbox, spacing 2
var _msg_slot: Control              # Qud's Message element: always present, h=0 when empty
## Qud's box, in Qud's own SUBPIXELS. Godot snaps every Control rect to a whole pixel, so
## the PanelContainer can only ever be a whole-pixel carrier for a box that is 278.21 wide
## and sits at y336.44. These carry the model's exact numbers so the chrome can be drawn
## where Qud draws it instead of where the carrier happens to have landed -- which is the
## last pixel of the AskString popup's top rule and bottom rule.
var _box_w := 0.0
var _box_h := 0.0
var _crome_w := 0.0                 # MenuCrome's entries + spacing: the bottom rule's gap
var _ctx_w := 0.0
var _msg_w := 0.0
var _msg_h := 0.0
var _edit_slot: Control             # Qud's inputbox slot, pinned to its 17.60

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
	# THE BOX = Qud's MenuControll: spacing 10, pad L20 R20 T0 B5. The background is NOT
	# the stylebox, because Qud's opaque fill does not coincide with the box (it starts 20
	# above it and stops 2 short of its bottom) -- it is drawn in _draw_chrome, behind the
	# children, which are separate CanvasItems.
	_sb_box = StyleBoxFlat.new()
	_sb_box.bg_color = Color(0, 0, 0, 0)
	_sb_box.content_margin_left = BOX_PAD_LR
	_sb_box.content_margin_right = BOX_PAD_LR
	_sb_box.content_margin_top = 0
	_sb_box.content_margin_bottom = BOX_PAD_B
	_panel.add_theme_stylebox_override("panel", _sb_box)
	_panel.draw.connect(_draw_chrome)
	center.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", BOX_SPACING)
	_panel.add_child(vb)

	# context header, ABOVE everything else (Qud's child order: ContextContainer, then the
	# title row, then the Scroll View, then MenuCrome). ONE fixed-height block: the tile is
	# drawn into it and the name is a child placed by hand, so both land on Qud's offsets
	# regardless of when the container settles.
	_ctx_box = VBoxContainer.new()
	_ctx_box.visible = false
	vb.add_child(_ctx_box)

	# PolatFrameSuperHeader — Qud puts the title row AFTER the context block, not before it
	_title = _mk_rt()
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF   # the title's natural width drives the panel
	_title.custom_minimum_size = Vector2(120, CROME_H)
	vb.add_child(_title)
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

	# Scroll View -> Content: Qud's list/message/input all live inside ONE container with
	# pad L5 R5 and spacing 2. Reproducing that container is what makes the box the right
	# WIDTH (box = 40 + 10 + row) as well as the right height.
	_scroll_wrap = MarginContainer.new()
	_scroll_wrap.add_theme_constant_override("margin_left", CONTENT_PAD_LR)
	_scroll_wrap.add_theme_constant_override("margin_right", CONTENT_PAD_LR)
	vb.add_child(_scroll_wrap)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 2)
	_scroll_wrap.add_child(_content)

	# Qud's Message element is ALWAYS present; when a menu ships an empty body it is simply
	# h=0 and the Content spacing after it still counts (that 2px is why an 8-option list
	# measures 224 and not 222). So the SLOT is always here and only its height changes.
	#
	# It is a plain Control with the label anchored inside rather than a container child,
	# because Qud's Message line is 20.12 tall and a RichTextLabel at font 16 reports a
	# 21px minimum that a Container would take as the row height -- the picker hit exactly
	# this and solved it the same way (docs/gotchas.md, "the +7px residual").
	_msg_slot = Control.new()
	_msg_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msg_slot.clip_contents = true
	_msg_slot.custom_minimum_size = Vector2.ZERO
	_content.add_child(_msg_slot)
	_msg = _mk_rt()
	_msg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_msg_slot.add_child(_msg)

	# The options area. Qud keeps it too when a popup has no options -- h=0, and the
	# spacing on BOTH sides of it still counts -- so it stays visible and simply empties.
	_opt_box = VBoxContainer.new()
	_opt_box.add_theme_constant_override("separation", 2)
	_content.add_child(_opt_box)

	_edit = LineEdit.new()
	_edit.add_theme_color_override("font_color", C_PALE)
	_edit.add_theme_color_override("caret_color", C_PALE)
	var esb := StyleBoxFlat.new()
	esb.bg_color = Color8(2, 22, 22)
	esb.set_border_width_all(1)
	esb.border_color = C_BOTLINE
	esb.content_margin_left = 8
	esb.content_margin_top = 0
	esb.content_margin_bottom = 0
	_edit.add_theme_stylebox_override("normal", esb)
	_edit.add_theme_stylebox_override("focus", esb)
	_edit.text_submitted.connect(func(_t: String): _submit_input())
	_edit.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			_cancel())
	# same fixed-slot trick as the Message: a LineEdit's minimum is its FONT height (21),
	# and Qud's inputbox is 17.60, so a container child would make the box 4px too tall
	# before anything else went wrong.
	_edit_slot = Control.new()
	_edit_slot.clip_contents = true
	_edit_slot.custom_minimum_size = Vector2(EDIT_W, _snap(EDIT_H))
	_edit_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edit_slot.add_child(_edit)
	_content.add_child(_edit_slot)

	# MenuCrome: 20 tall, spacing 5, MiddleCenter, and pad L-20 R-20 so it spans the WHOLE
	# box while everything else sits inside the 20px padding. Since the content box is
	# centred in the box, centring the row in the content box centres it on the box too.
	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", CROME_SP)
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_btn_row.custom_minimum_size = Vector2(0, CROME_H)
	vb.add_child(_btn_row)

## The Qud dialog frame, hung off THE BOX (see the box-model block above) rather than
## drawn inside a panel. Everything here is box-local, so the negative offsets are real:
## the fill starts 20 above the box and the top rule 16 above it, which is exactly the
## thing that made "the popup sits 16px low" look like a constant to add.
##
## The rule's own pattern is Qud's `polat frame reverse header` strip: a fixed 176-wide
## ornamented centre (872..1048 on screen, i.e. ±88 of screen centre) between two plain
## lines that stretch with the box. Since Qud centres the box, the notches always land on
## the same absolute columns -- gaps at cx±70 (6 wide) and cx (10 wide), measured
## identically on the 278-wide item popup and the 650-wide wish popup.
## Qud's box, as an offset from where Godot put the carrier.
##
## Derived from SIZES ONLY. A Control's `position` is not readable from inside its own
## draw callback -- both `position` and `global_position` come back (0,0) on the show
## frame, and since nothing dirties the panel afterwards that stale draw is the one left
## on screen (this is the same trap that once put the context divider through the item
## name). Sizes ARE valid there, and the placement is reproducible without reading it:
## a CenterContainer puts the child at (parent - child)/2 and Godot FLOORS every Control
## rect to a whole pixel. Confirmed on two popups whose centring lands on opposite sides
## of a half pixel -- 279 wide -> x820 (820.5 floored) and 278 wide -> x821 (exact).
func _box_offset(w: float, h: float) -> Vector2:
	if _root == null:
		return Vector2.ZERO
	return (_root.size - Vector2(w, h)) * 0.5 - ((_root.size - _panel.size) * 0.5).floor()

func _draw_chrome() -> void:
	var w := _box_w if _box_w > 0.0 else _panel.size.x
	var h := _box_h if _box_h > 0.0 else _panel.size.y
	var off := _box_offset(w, h)
	if _DEBUG_LAYOUT:
		var fdbg := FileAccess.open(
			InputModel.support_dir().path_join("popup_layout.txt"), FileAccess.WRITE)
		if fdbg != null:
			fdbg.store_line("panel pos=%s gpos=%s size=%s | root=%s exact %.2fx%.2f off %s" % [
				_panel.position, _panel.global_position, _panel.size, _root.size,
				w, h, off])
			for c in [_ctx_box, _title, _scroll_wrap, _opt_box, _btn_row]:
				fdbg.store_line("  %s vis=%s pos=%s size=%s min=%s" % [
					c.name, c.visible, c.global_position, c.size,
					c.get_combined_minimum_size()])
			for c in _opt_box.get_children():
				fdbg.store_line("    row size=%s min=%s" % [
					(c as Control).size, (c as Control).get_combined_minimum_size()])
			fdbg.close()
	var ly := CHROME_TOP
	var cx := w * 0.5
	# The opaque fill: box_top-20 .. box_bottom-2, full box width. Drawn from the panel's
	# own draw callback, so it lands BEHIND the child Controls.
	_rect(off, Rect2(0, FILL_TOP, w, h - FILL_TOP + FILL_BOT), C_PANEL)
	# side notches: Qud's gaps run cx-73..cx-67 and cx+67..cx+73 (6 wide, centred ±70)
	var side := minf(70.0, w * 0.32)
	var l0 := cx - side - 3.0
	var l1 := cx - side + 3.0
	var c0 := cx - 5.0
	var c1 := cx + 5.0
	var r0 := cx + side - 3.0
	var r1 := cx + side + 3.0
	for seg in [[0.0, l0], [l1, c0], [c1, r0], [r1, w]]:
		_rect(off, Rect2(seg[0], ly, seg[1] - seg[0], 2), C_TOPLINE)
	_rect(off, Rect2(l0 - 2, ly - 4, 2, 10), C_TOPLINE)   # ╢ outward side ticks
	_rect(off, Rect2(r1, ly - 4, 2, 10), C_TOPLINE)       # ╟
	_rect(off, Rect2(c0 - 2, ly, 2, 10), C_TOPLINE)       # ╖ centre down-ticks
	_rect(off, Rect2(c1, ly, 2, 10), C_TOPLINE)           # ╓
	# The context block is closed off by its own full-width divider, notched like the top
	# line (Qud: top rule y320, divider y471 -- both the same strip, 151 apart).
	if _ctx_box.visible:
		var dy := ly + CTX_DIVIDER
		for seg in [[0.0, l0], [l1, c0], [c1, r0], [r1, w]]:
			_rect(off, Rect2(seg[0], dy, seg[1] - seg[0], 2), C_TOPLINE)
		_rect(off, Rect2(l0 - 2, dy - 4, 2, 10), C_TOPLINE)
		_rect(off, Rect2(r1, dy - 4, 2, 10), C_TOPLINE)
		_rect(off, Rect2(c0 - 2, dy, 2, 10), C_TOPLINE)
		_rect(off, Rect2(c1, dy, 2, 10), C_TOPLINE)
	if _title.visible:
		# ─┤ Title ├─ edge assemblies at the title row's mid-height. The title row is
		# Qud's PolatFrameSuperHeader, which follows the context block.
		var ty := (CTX_H + BOX_SPACING if _ctx_box.visible else 0.0) + CROME_H * 0.5
		_rect(off, Rect2(0, ty - 1, 10, 2), C_BOTLINE)
		_rect(off, Rect2(10, ty - 8, 2, 16), C_BOTLINE)
		_rect(off, Rect2(w - 12, ty - 8, 2, 16), C_BOTLINE)
		_rect(off, Rect2(w - 10, ty - 1, 10, 2), C_BOTLINE)
	# The bottom rule is MenuCrome's two line sprites. Qud splits the box width around the
	# command entries: line = (box_w - entries - 2*spacing)/2, and each entry measures
	# padL 2 + cursor 8 + spacing 5 + text + padR 20. Verified on both probes -- the item
	# popup's one entry gives 59.01 and the wish popup's two give 157.70, to the pixel.
	# Use MINIMUM sizes: the real rects are not laid out yet on the show frame.
	var by := h + CHROME_BOT
	var mid := _crome_w
	if mid > 0.0:
		var line := maxf(0.0, (w - mid - 2.0 * CROME_SP) * 0.5)
		_rect(off, Rect2(0, by, line, 1), C_BOTLINE)
		_rect(off, Rect2(w - line, by, line, 1), C_BOTLINE)
		# the 1px end tick each line carries, down the sprite's whole 15px height
		_rect(off, Rect2(line - 1.0, h + CROME_TICK_TOP, 1, CROME_TICK_H), C_BOTLINE)
		_rect(off, Rect2(w - line, h + CROME_TICK_TOP, 1, CROME_TICK_H), C_BOTLINE)
	else:
		_rect(off, Rect2(0, by, w, 1), C_BOTLINE)


## Qud's box, computed from the MODEL in Qud's own subpixels -- the same arithmetic the
## probe confirms, run forwards. Reproduced exactly on all four probed popups:
##
##   cloth robe   138.12 + 10 + 224    + 10 + 20 + 5 = 407.12   w 40 + 238.2 = 278.2
##   basic toolkit 138.12 + 10 + 196   + 10 + 20 + 5 = 379.12   w 40 + 199.8 = 239.8
##   data disk    138.12 + 10 + 252    + 10 + 20 + 5 = 435.12   w 40 + 393.6 = 433.6
##   wish prompt              41.72    + 10 + 20 + 5 =  76.72   w 40 + 610   = 650.0
##
## against Qud's 407.12/278.21, 379.12/239.81, 435.12/433.61 and 76.72/650.00. The data
## disk is the one that proves the width rule is not just "the widest command": its box is
## sized by the ITEM NAME, 393.61 against a command area that only asks for 199.81.
func _measure_box(is_input: bool) -> void:
	# Scroll View / Content: Message + 2 + options area + 2 + inputbox, pad L5 R5.
	# An ABSENT inputbox takes its spacing with it (the item menu's Content is 0 + 2 + 222
	# = 224); an empty options area does NOT (the wish's is 20.12 + 2 + 0 + 2 + 17.6).
	var n := _options.size()
	var opts_h := (ROW_H * n + 2.0 * (n - 1)) if n > 0 else 0.0
	var msg_h := _msg_h
	var content_h := msg_h + 2.0 + opts_h
	if is_input:
		content_h += 2.0 + EDIT_H
	var content_w := maxf(_msg_w, EDIT_W if is_input else 0.0)
	for c in _opt_box.get_children():
		content_w = maxf(content_w, float((c as Control).get_meta("exact_w", 0.0)))
	# MenuCrome spans the whole box (pad L-20 R-20), so it asks the CONTENT box for 40 less
	# -- and it asks for its two line sprites at their 25px floor as well as its entries.
	_crome_w = 0.0
	for c in _btn_row.get_children():
		_crome_w += float((c as Control).get_meta("exact_w", 0.0))
	_crome_w += CROME_SP * maxf(0.0, _btn_row.get_child_count() - 1)
	var crome_ask := 0.0
	if _btn_row.get_child_count() > 0:
		crome_ask = _crome_w + 2.0 * CROME_SP + 2.0 * CROME_LINE_MIN - 2.0 * BOX_PAD_LR
	var box_content_w := maxf(content_w + 2.0 * CONTENT_PAD_LR, crome_ask)
	_btn_row.custom_minimum_size = Vector2(_snap(maxf(0.0, crome_ask)), CROME_H)
	if _ctx_box.visible:
		box_content_w = maxf(box_content_w, _ctx_w)
	_box_w = 2.0 * BOX_PAD_LR + box_content_w
	var parts: Array[float] = []
	if _ctx_box.visible:
		parts.append(CTX_H)
	if _title.visible:
		parts.append(CROME_H)
	parts.append(content_h)
	parts.append(CROME_H)
	_box_h = BOX_PAD_B + BOX_SPACING * (parts.size() - 1)
	for v in parts:
		_box_h += v

## One chrome rect, placed on QUD'S box rather than on the snapped carrier. `off` is the
## difference between the two; it is never more than half a pixel, and it is exactly what
## decides which row a 1px rule lands on.
func _rect(off: Vector2, r: Rect2, c: Color) -> void:
	_panel.draw_rect(Rect2(r.position + off, r.size), c)

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
		# Qud's ContextContainer is a CONSTANT 138.12 tall -- padT 10 + tile 72 + 10 +
		# name 20.12 + 10 + divider 16 -- on every item probed, whatever the name's length.
		# The gap to the first command is not part of it: that is MenuControll's spacing.
		#
		# Its WIDTH is the item NAME, and that can be what sizes the whole popup: the data
		# disk's 41-character name makes Qud's box 433.61 where its widest command would
		# only ask for 199.81. Leaving this at the tile's 48 would have made that popup
		# little over half Qud's width, which no amount of chrome work would have shown on
		# the cloth robe.
		var fw := _ctx_font()
		var name_w := _runs_width(fw, _ctx_name_runs, CTX_NAME_SIZE) if fw != null else 0.0
		_ctx_img.custom_minimum_size = Vector2(_snap(maxf(CTX_IMG.x, name_w)), CTX_H)
		_ctx_w = maxf(CTX_IMG.x, name_w)
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
	var pitch := _pitch(f, CTX_NAME_SIZE)
	var total := _runs_width(f, _ctx_name_runs, CTX_NAME_SIZE)
	var px := (_ctx_img.size.x - total) * 0.5
	# -5: CTX_NAME_INK is where Qud's INK starts, and a baseline of ink_top + ascent
	# lands the cap 5px low, ascent being taller than the cap height. Measured against
	# Qud's own band (+113..+124) rather than derived from font metrics Godot rounds.
	var baseline := top + (CTX_NAME_INK - CTX_TILE_TOP) + f.get_ascent(CTX_NAME_SIZE) - 5.0
	for run in _ctx_name_runs:
		var txt: String = run[0]
		_ctx_img.draw_string(f, Vector2(px, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, CTX_NAME_SIZE, run[1])
		px += pitch * txt.length()   # advance on QUD'S pitch, not on a re-rounded run width

## Source Code Pro's advance, as a FRACTION. Qud lays this text out at exactly 0.6em --
## every width the probe reports is 9.6 * len at font 16 (211.21 for a 22-character row,
## 115.20 for "[Esc] Cancel") -- but Godot's `get_string_size` returns a whole number, so
## the same row measures 212, and summing the per-run pieces of a coloured string rounds
## again and reaches 213. Those 1.8px are not cosmetic: the box is sized off the widest
## row, so they made it 280 wide against Qud's 278.21 and moved its centred left edge, the
## top rule, the divider and the item name a whole pixel with it.
##
## Taking the pitch from the font rather than hardcoding 9.6 keeps it true if the face or
## the size changes. Same reasoning as the journal header, which takes its pitch from the
## width Qud ships rather than from a constant.
## THE ONE CONCESSION IN THIS PORT, and it is a rounding, not a fit. Qud lays its box out
## in subpixels (278.21 wide, left edge 820.895); Godot snaps every Control rect to a whole
## pixel, so Raves has to choose 278 or 279. Left to itself a Container CEILS -- a row
## asking for 228.2 is handed 229 -- and the box came out 279, whose centred left edge is
## 820 where Qud's 278.21 rasterises from 821. Rounding Qud's own value to the NEAREST
## pixel instead reproduces the pixel Qud lands on, and it does so on all four probed
## popups: 278.21->278 (x821, Qud 821), 239.81->240 (x840, Qud 840), 433.61->434 (x743,
## Qud 743), 650->650. Never round a POSITION here -- only the model's own widths, once,
## where Godot would otherwise round them for us in the wrong direction.
static func _snap(v: float) -> float:
	return roundf(v)

static func _pitch(f: Font, size: int) -> float:
	return f.get_string_size("AAAAAAAAAA", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x / 10.0

## Width of a run list laid out on that pitch (Qud's own measurement of the same string).
static func _runs_width(f: Font, runs: Array, size: int) -> float:
	var n := 0
	for run in runs:
		n += String(run[0]).length()
	return _pitch(f, size) * n

func _ctx_font() -> Font:
	if _ctx_img == null:
		return null
	return _ctx_img.get_theme_default_font()

## Local y of the tile box inside the block: the block starts at the panel's content
## margin, the offsets are quoted from the top LINE, so convert once here. With the box
## model the block starts at the box's own top (pad T0) and the line sits 16 ABOVE it,
## so this resolves to Qud's padT of 10 -- the header's internals are unchanged, which
## is the point: they already measured 151.0 against Qud's 151.0.
func _ctx_top_local() -> float:
	return CTX_TILE_TOP - (_ctx_img.global_position.y - _panel.global_position.y - _line_y())

func _line_y() -> float:
	return CHROME_TOP

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
			# ensure_, not set_: this is the SAME popup re-announced, so re-assert the kind
			# without counting a fresh raise. set_popup() here bumped popup_n on every
			# re-announce (~1/s from highvisor's own polling), and popup_n is what a dismiss
			# step diffs to prove its key landed — see UiState.ensure_popup.
			UiState.ensure_popup("input")
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
	# menus ship an EMPTY body ("{{y|}}"). Qud keeps the Message ELEMENT either way -- an
	# empty one is h=0 and the Content spacing after it still counts -- so the slot stays
	# and only its height changes, or the list starts 2px high.
	_msg.visible = QudText.strip(msg_raw).strip_edges() != ""
	_msg.text = QudText.to_bbcode(msg_raw, _palette)
	# ONE box for every kind (Qud has one PopupMessage prefab, not a boxed and a banner
	# variant). The message's natural width drives it, capped so long text wraps; an
	# AskString gets Qud's own 600px inputbox width instead.
	if _msg.visible:
		var f := _root.get_theme_font("font", "Label")
		var natural := _pitch(f, 16) * QudText.strip(msg_raw).length()
		var msg_w := minf(natural, MSG_W_MAX)
		if is_input:
			msg_w = EDIT_W          # an AskString is sized by its inputbox, not its prompt
		var lines := maxf(1.0, ceilf(natural / maxf(1.0, msg_w)))
		_msg_slot.custom_minimum_size = Vector2(msg_w, _snap(MSG_LINE * lines))
		_msg_w = msg_w
		_msg_h = MSG_LINE * lines
	else:
		_msg_slot.custom_minimum_size = Vector2.ZERO
		_msg_w = 0.0
		_msg_h = 0.0
	_edit_slot.visible = is_input

	_build_options()
	_build_buttons()

	_edit.visible = is_input
	if is_input:
		_edit.text = str(data.get("inputDefault", ""))
	_sel = 0
	_highlight_option()
	_measure_box(is_input)

	visible = true
	if is_input:
		_edit.grab_focus()
		_edit.caret_column = _edit.text.length()
	else:
		_edit.release_focus()
	# highvisor state report: a popup is up (kind feeds `hv assert --popup …`)
	UiState.set_popup("input" if is_input else ("menu" if _options.size() > 0 else "message"))

## MenuCrome's entries are Qud's `MenuOptionText`: padL 2 + an 8px Selection Cursor cell +
## spacing 5 + the text + padR 20. That cursor cell is there even on a single-entry bar --
## it is why the item popup's one "[Esc] Cancel" measures 150.20 against a 115.20 label --
## so it is a fixed CELL here too, not a "> " prefix on the text. Prefixing was what made
## the box 6px wider than Qud's and pulled the bottom rule's gap in with it.
##
## They are OWNER-DRAWN plain Controls rather than Buttons for the same reason the picker's
## category rows are plain Panels: a Button/RichTextLabel at font 16 reports a minimum
## taller than the 20px Qud draws, and a Container takes max(own, content), so the whole
## box would come out a pixel tall and shift the centred chrome half a pixel with it.
func _build_buttons() -> void:
	for c in _btn_row.get_children():
		_btn_row.remove_child(c)   # remove NOW — queue_free'd rows linger a frame and
		c.queue_free()             # poison get_children() on a same-frame re-show
	var f := _root.get_theme_font("font", "Label")
	for i in _buttons.size():
		var b: Dictionary = _buttons[i]
		var runs: Array = QudText.runs(str(b.get("text", "")), _palette, C_BTN)
		var tw := _runs_width(f, runs, 16)
		var cell := Control.new()
		cell.custom_minimum_size = Vector2(
			_snap(CROME_PAD_L + CROME_CURSOR + CROME_SP + tw + CROME_PAD_R), CROME_H)
		cell.set_meta("exact_w", CROME_PAD_L + CROME_CURSOR + CROME_SP + tw + CROME_PAD_R)
		cell.clip_contents = true
		cell.mouse_filter = Control.MOUSE_FILTER_STOP
		cell.set_meta("runs", runs)
		cell.set_meta("idx", i)
		cell.draw.connect(_draw_crome_cell.bind(cell))
		var cmd := str(b.get("command", ""))
		cell.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_answer_button(cmd))
		_btn_row.add_child(cell)
	_bsel = 0
	_refresh_btn_sel()
	_panel.queue_redraw()   # the bottom line's gap tracks the button row

func _draw_crome_cell(cell: Control) -> void:
	var f := cell.get_theme_default_font()
	if f == null:
		return
	var base := f.get_ascent(16) + (CROME_H - f.get_ascent(16) - f.get_descent(16)) * 0.5
	if int(cell.get_meta("idx", -1)) == _bsel and _btn_row.get_child_count() > 1:
		cell.draw_string(f, Vector2(CROME_PAD_L, base), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GOLD)
	var pitch := _pitch(f, 16)
	var px := CROME_PAD_L + CROME_CURSOR + CROME_SP
	var runs: Array = cell.get_meta("runs", [])
	for run in runs:
		var txt: String = run[0]
		cell.draw_string(f, Vector2(px, base), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, run[1])
		px += pitch * txt.length()

## Qud marks the keyboard-selected entry with its Selection Cursor (Left/Right move it,
## Space/Enter answer it) — the cell is always reserved, only its glyph comes and goes.
func _refresh_btn_sel() -> void:
	for c in _btn_row.get_children():
		(c as Control).queue_redraw()
	_panel.queue_redraw()

## Option rows are Qud's `MenuOptionText(Clone)`: 26 tall, spacing 2, and the same
## padL 2 + cursor 8 + spacing 5 gutter, so the text starts 15 in. They keep QUD'S OWN
## colours ({{W|[k]}} hotkeys etc.) via to_bbcode; the selected row gets Qud's 26px bar
## and its gold cursor, drawn in the reserved cell rather than prefixed to the text.
func _build_options() -> void:
	for c in _opt_box.get_children():
		_opt_box.remove_child(c)
		c.queue_free()
	var f := _root.get_theme_font("font", "Label")
	for i in _options.size():
		var runs: Array = QudText.runs(str(_options[i].get("text", "")), _palette, C_PALE)
		var tw := _runs_width(f, runs, 16)
		var row := Control.new()
		# The row's WIDTH is the thing that sizes the whole box (Qud: box = 67 + widest
		# option text), so it is measured with the font and kept FRACTIONAL. A
		# RichTextLabel reports a ceil'd content width, and a Container takes
		# max(own, content): that 0.79px of rounding on the cloth robe's widest row made
		# the box 279 instead of 278.21, which pushed its centred left edge a whole pixel
		# out and took the top rule, the divider and the item name with it.
		row.custom_minimum_size = Vector2(_snap(ROW_TEXT_X + tw + CROME_PAD_L), ROW_H)
		row.set_meta("exact_w", ROW_TEXT_X + tw + CROME_PAD_L)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.clip_contents = true
		row.set_meta("runs", runs)
		var idx := i
		row.draw.connect(_draw_option_row.bind(row, idx))
		row.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_answer_option(idx))
		row.mouse_entered.connect(func(): _sel = idx; _highlight_option())
		_opt_box.add_child(row)

func _draw_option_row(row: Control, idx: int) -> void:
	var f := row.get_theme_default_font()
	if f == null:
		return
	if idx == _sel:
		row.draw_rect(Rect2(Vector2.ZERO, row.size), C_SELBAR)
	# Qud's Item Text is the same 20.12 line as the context name, at the row's padT of 2,
	# so it takes the same ink->baseline conversion (see _draw_ctx_img's -5 note).
	var base := 2.0 + 4.56 + f.get_ascent(16) - 5.0
	if idx == _sel:
		row.draw_string(f, Vector2(CROME_PAD_L, base), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GOLD)
	var pitch := _pitch(f, 16)
	var px := ROW_TEXT_X
	var runs: Array = row.get_meta("runs", [])
	for run in runs:
		var txt: String = run[0]
		row.draw_string(f, Vector2(px, base), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, run[1])
		px += pitch * txt.length()

func _highlight_option() -> void:
	for c in _opt_box.get_children():
		(c as Control).queue_redraw()

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

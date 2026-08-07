class_name PickerOverlay
extends CanvasLayer

## Mirrors Qud's ITEM PICKER (Qud.UI.PickGameObjectScreen), forwarded by the mod's PickerBridge.
##
## WHY IT ISN'T PART OF PopupOverlay: the picker is a Qud SCREEN, not a PopupMessage. Clicking an empty
## paper-doll slot runs ShowBodypartEquipUI -> PickItem.ShowPicker -> PickGameObjectScreen.show(), which
## never touches getWindow("PopupMessage") -- so the popup mirror is structurally blind to it, and until
## this existed Qud put the picker up while Raves showed nothing at all.
##
## The row model is Qud's own (PickGameObjectLine.setData): a CATEGORY row is "[-] name" and toggles
## collapse; an ITEM row is hotkey + tile + display name + right-floated weight. We never decide which is
## which -- we send the row INDEX back and Qud's HandleSelectItem applies the rule, so collapse/pick can't
## drift from the game.
##
## Layer 129 puts it UNDER PopupOverlay (130) on purpose: an empty slot with nothing to put in it answers
## with a real popup ("You don't have anything to use in that slot"), which has to draw on top.

signal answered(payload: Dictionary)
signal closed

# QUD'S OWN LAYOUT MODEL, read off the live RectTransforms with `hv`/the mod's UiProbe across three
# content states (left-hand picker, thrown-weapon picker, and the same list re-sorted). See
# docs/decisions/1to1-measurement-and-layout.md: reproduce the MODEL, not the pixels. The vertical
# rule below reconstructs Qud's panel height to 0.00px in every state measured.
#
#   panel  centred on screen both axes; h = TITLE_H + 5 + listH + GAP_LIST_FOOT + footH + BOT_PAD
#   title  panel+TITLE_X, at the panel's TOP EDGE, LEFT-aligned (Qud does not centre it)
#   list   panel+LIST_INSET, panel top + 26; footer panel+FOOT_INSET, 21 below the list
const TITLE_H := 21.0
const TITLE_X := 16.0
const GAP_TITLE_LIST := 5.0
const LIST_INSET := 11.0
const GAP_LIST_FOOT := 21.0
const FOOT_INSET := 6.0
const FOOT_LINE_H := 22.0
const BOT_PAD := 6.0
const PANEL_MIN_W := 412.0         # Qud clamps here; wider lists grow to contentW + 37
const PANEL_W_SLACK := 37.0

# Row model. An item row is TALLER than a category row because it carries a 20x30 icon.
const ROW_H_ITEM := 30.0
const ROW_H_CAT := 20.12
const CARET_W := 15.0
const CARET_H := 15.0              # the SelectionCaret sprite is square, centred in the row
const HOTKEY_W := 24.0
const HOTKEY_W_INDENT := 48.0      # setData prefixes 3 spaces to an indented row's hotkey
const ICON := Vector2(20, 30)
const SPACER_W := 2.0
const PAD_SIDE := 6.0              # Background's VerticalLayoutGroup padL/padR/padB (padT is TITLE_H)
const TAB_PAD := 8.0               # the Title row's two Padding elements, one either side
const FONT_PX := 16                # every text on this screen is 16px in Qud, title included

var _palette := {}
var _rows: Array = []              # the mod's row dicts, in Qud's order
var _sel := 0
var _cur_id := -1
var _built := false
var _tiles: RefCounted = null

var _root: Control
var _panel: PanelContainer
var _title: RichTextLabel
var _scroll: ScrollContainer
var _list: VBoxContainer
var _foot: HFlowContainer
var _foot_abs: Control        # absolute placement using Qud's own laid-out boxes
var _bar_h := 0.0             # Qud's KeyMenuOptionBar height, as shipped in the frame
var _tab_w := 0.0             # Qud's title-tab width, likewise
var _menu: Array = []           # the footer bar's entries, as Qud yielded them

# Same measured dialog chrome as PopupOverlay (see its notes: +6/channel above the dark
# knee, fitted against captures). Kept as its own copy rather than reaching across --
# these are drawing constants, and a shared mutable would couple two screens that are
# free to diverge as each gets measured.
static func _cq(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_PANEL := _cq(6, 37, 37)
var C_TOPLINE := _cq(53, 90, 98)
var C_BOTLINE := _cq(64, 106, 115)
var C_GOLD := _cq(200, 184, 57)
var C_PALE := _cq(168, 194, 187)
var C_DIM := _cq(59, 93, 113)       # Qud's {{K|...}} category grey, as used on the inventory pane

func _init() -> void:
	layer = 129
	visible = false

func _ready() -> void:
	_build()

func _build() -> void:
	if _built:
		return
	_built = true
	_tiles = load("res://QudTiles.gd").new()
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = UiFont.make_theme(get_viewport())
	add_child(_root)

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

	# The panel carries NO uniform stylebox inset: Qud insets each band differently (title 16,
	# list 11, footer 6) and the title sits flush with the panel's top edge, so a single content
	# margin can't express it. Zero margins, and each band takes its own MarginContainer.
	_panel = PanelContainer.new()
	# NO stylebox fill on the panel itself. Qud's Background is a VerticalLayoutGroup with padding
	# L6 R6 T21 B6, and it paints only INSIDE that padding: the 6px edges and the whole 21px title
	# band are transparent, with the dimmed world showing through everywhere except the title tab.
	# A full-rect fill covered the band, which is what made Raves look like it had a title BAR where
	# Qud has a little tab.
	_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_panel.draw.connect(_draw_chrome)
	center.add_child(_panel)

	# NO frame sprite. Qud's Background carries "polat-char-frame-border", but measuring the live
	# screen shows none of that sprite's light border reaching the glass: the panel is a plain fill
	# from the padding inwards, with no edge line on any side. Drawing the extracted sprite as a
	# 9-slice painted a 6px light border and a 21px light top band that Qud simply does not have,
	# and it covered the title tab. The body fill below is the whole of Qud's picker chrome.

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	_panel.add_child(vb)

	var tm := MarginContainer.new()
	tm.add_theme_constant_override("margin_left", int(TITLE_X))
	tm.custom_minimum_size = Vector2(0, TITLE_H)
	vb.add_child(tm)
	_title = _mk_rt()
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	_title.add_theme_font_size_override("normal_font_size", FONT_PX)
	tm.add_child(_title)

	vb.add_child(_gap(GAP_TITLE_LIST))

	var lm := MarginContainer.new()
	lm.add_theme_constant_override("margin_left", int(LIST_INSET))
	lm.add_theme_constant_override("margin_right", int(LIST_INSET))
	vb.add_child(lm)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	lm.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 0)
	# EXPAND, not just FILL: a ScrollContainer stretches a child to its viewport only when the child
	# asks to expand — otherwise the child gets its own minimum width. That used to come free from
	# the rows' content, and the moment the rows stopped reporting a content width (they are Panels
	# now, sized by us) the whole list collapsed to zero wide and drew nothing.
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	vb.add_child(_gap(GAP_LIST_FOOT))

	# Qud's footer is a MENU BAR, not a caption: it wraps across as many centred lines as it
	# needs ("[Esc] Close Menu  [nav] navigate" / "[7] sort: list/by class" / "[Space] Select"),
	# on a 22px line pitch. HFlowContainer reproduces that wrap.
	var fm := MarginContainer.new()
	fm.add_theme_constant_override("margin_left", int(FOOT_INSET))
	fm.add_theme_constant_override("margin_right", int(FOOT_INSET))
	vb.add_child(fm)
	_foot = HFlowContainer.new()
	_foot.alignment = FlowContainer.ALIGNMENT_CENTER
	_foot.add_theme_constant_override("h_separation", 0)
	_foot.add_theme_constant_override("v_separation", 0)
	fm.add_child(_foot)
	# Absolute placement layer, used whenever Qud ships its laid-out boxes (the normal case). Qud's
	# bar is a FlowLayoutGroup wrapping on "running + item > width" using ITS OWN measurement of each
	# label — which a different text rasteriser cannot reproduce, so any spacing constant we picked
	# would only ever match by luck. Place at Qud's offsets instead and the break points are its own.
	_foot_abs = Control.new()
	_foot_abs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_foot_abs.visible = false
	fm.add_child(_foot_abs)

	vb.add_child(_gap(BOT_PAD))

func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _mk_rt() -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.add_theme_color_override("default_color", C_PALE)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rt

## The dialog frame: notched top line, ─┤ title ├─ edge assemblies, plain bottom line under the
## footer. Same assembly as PopupOverlay's titled form.
func _draw_chrome() -> void:
	# THE WHOLE OF QUD'S PICKER CHROME, measured off the live screen. It is not a framed dialog --
	# it is two solid rects and a divider:
	#   - the BODY: the panel rect inset by Qud's layout padding (L/R/B 6, T 21). The 21px title
	#     band and the 6px edges stay transparent, so the dimmed world shows through them.
	#   - a SOLID tab behind the title, panel+16, 21 tall, sized to Qud's own measurement of the text
	#   - the list/footer divider: TWO mirrored halves of one 12x16 sprite, each (panelW-12)/2 wide,
	#     meeting exactly at the panel centre, 5px under the list
	# Drawn here rather than as child Controls because PanelContainer re-fits every child to its own
	# rect, which would throw away the four independent insets.
	var w := _panel.size.x
	_panel.draw_rect(Rect2(PAD_SIDE, TITLE_H, w - PAD_SIDE * 2.0,
		_panel.size.y - TITLE_H - PAD_SIDE), C_PANEL)
	if _title.visible:
		# Qud's own tab width when the frame carries it (it is a text measurement, and ours differs);
		# our text width + 2x8 padding only as a fallback.
		var tw := _tab_w if _tab_w > 0.0 else _title.get_combined_minimum_size().x + TAB_PAD * 2.0
		_panel.draw_rect(Rect2(TITLE_X, 0, tw, TITLE_H), C_PANEL)
	var dtex := _chrome_tex("picker_divider.png")
	if dtex != null and _scroll != null:
		# PANEL-RELATIVE. `_scroll.position` is relative to the MarginContainer it sits in, so using
		# it directly lost the title band and its gap (21 + 5) and drew the divider 26px high --
		# straight through the last row of the list. Measured against Qud: divider at panel+385 here.
		var dy := _scroll.global_position.y - _panel.global_position.y + _scroll.size.y + 5.0
		var half := (w - FOOT_INSET * 2.0) * 0.5
		_panel.draw_texture_rect(dtex, Rect2(FOOT_INSET, dy, half, 16), false)
		# The right half is the same sprite mirrored, which is why it can meet the centre seamlessly.
		# Drawn from a pre-flipped copy: a negative-width Rect2 does not flip in Godot 4, it simply
		# does not rasterise, so the right half of the divider was missing entirely.
		var mtex := _chrome_tex_mirrored("picker_divider.png")
		if mtex != null:
			_panel.draw_texture_rect(mtex, Rect2(FOOT_INSET + half, dy, half, 16), false)

## A chrome sprite the mod extracted from the live screen, cached. Missing is not an error — the
## export runs when a picker has been open at least once, and the panel still reads fine without it.
static var _chrome_cache := {}

func _chrome_tex(fname: String) -> Texture2D:
	if _chrome_cache.has(fname):
		return _chrome_cache[fname]
	var path := InputModel.support_dir().path_join("tiles").path_join(fname)
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_chrome_cache[fname] = tex
	return tex

## The same sprite flipped horizontally, cached alongside the original.
func _chrome_tex_mirrored(fname: String) -> Texture2D:
	var key := fname + "#mirror"
	if _chrome_cache.has(key):
		return _chrome_cache[key]
	var tex: Texture2D = null
	var src := _chrome_tex(fname)
	if src != null:
		var img := src.get_image()
		img.flip_x()
		tex = ImageTexture.create_from_image(img)
	_chrome_cache[key] = tex
	return tex

# --- show / hide -------------------------------------------------------------------------------

func show_picker(data: Dictionary, palette: Dictionary) -> void:
	_build()
	if not palette.is_empty():
		_palette = palette
	# The frame ships Qud's own palette; prefer it over the last snapshot's.
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
		_tiles.palette = own

	_rows = data.get("rows", [])
	_cur_id = int(data.get("id", -1))
	# The mod ships the rect numbers as strings; float() takes either.
	_bar_h = float(data.get("barH", 0))
	_tab_w = float(data.get("tabW", 0))
	# Adopt QUD'S highlighted row rather than starting at zero. Its opening selection lands on
	# the first ITEM (not the leading category), and it re-clamps after every collapse — copying
	# the exported index keeps us honest through both without reimplementing either rule.
	_sel = clampi(int(data.get("sel", 0)), 0, maxi(0, _rows.size() - 1))

	var t := str(data.get("title", "")).strip_edges()
	_title.visible = t != ""
	if _title.visible:
		# LEFT-aligned. Qud puts the title in a little tab at the panel's top-left, not centred —
		# measured at panel+16 in every state.
		_title.text = "[color=#%s]%s[/color]" % [
			C_GOLD.to_html(false), QudText.to_bbcode(t, _palette)]
	_menu = data.get("menu", [])
	_build_menu()

	_build_rows()
	_highlight()

	# Qud sizes the list to its CONTENT (sum of row heights) — no scrolling in any state measured.
	# Keep a viewport cap anyway so a pathologically long list can't grow off-screen; when it bites,
	# ours scrolls where Qud's would have been taller, and that difference is worth knowing about.
	var vh := float(get_viewport().get_visible_rect().size.y)
	# Take the list height from the rows AS LAID OUT, not from a parallel sum of the constants:
	# Godot rounds a 20.12 minimum in its own way, so a hand-summed 341.32 disagreed with the real
	# content by a few px and the last row was clipped behind the divider.
	var content_h := _list.get_combined_minimum_size().y
	var listh := minf(content_h, vh - (TITLE_H + GAP_TITLE_LIST + GAP_LIST_FOOT + BOT_PAD + 120.0))
	_scroll.custom_minimum_size = Vector2(0, listh)
	# Width: Qud clamps to PANEL_MIN_W and otherwise grows to the widest row + slack.
	_panel.custom_minimum_size = Vector2(PANEL_MIN_W, 0)
	visible = true
	# Report it the same way popups do, so `hv state` / `hv assert` can see the picker is up.
	UiState.set_popup("itempicker")

## The footer bar. Each entry is Qud's own rendered text ("[{{W|Esc}}] Close Menu"), so the
## markup carries its own colours; a DISABLED entry ("navigate") is a legend and stays inert.
func _build_menu() -> void:
	for c in _foot.get_children():
		_foot.remove_child(c)
		c.queue_free()
	for c in _foot_abs.get_children():
		_foot_abs.remove_child(c)
		c.queue_free()

	# Did Qud ship its laid-out boxes? Then mirror them exactly; otherwise fall back to our own flow.
	#
	# ANY box is enough — do NOT demand one per entry. yieldMenuOptions() can yield an option the bar
	# has not instantiated (the context-dependent "[Space] Select" is yielded while only three
	# KeyMenuOption prefabs exist), and requiring a box for every entry dropped the whole absolute
	# layout back to our own flow. That flow wrapped to two lines against Qud's three, which was the
	# last 24px of the panel-height residual. An entry with no box is one Qud is not drawing.
	var have_rects := false
	for m in _menu:
		if m.has("lx"):
			have_rects = true
			break
	_foot_abs.visible = have_rects
	_foot.visible = not have_rects
	var host: Control = _foot_abs if have_rects else _foot

	for i in _menu.size():
		var m: Dictionary = _menu[i]
		# Mirroring Qud's boxes means mirroring its omissions too.
		if have_rects and not m.has("lx"):
			continue
		var lbl := _mk_rt()
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		lbl.add_theme_font_size_override("normal_font_size", FONT_PX)
		# Qud's bar runs on a 22px line pitch; a RichTextLabel's natural line box at 16px is ~27,
		# which stretched the whole panel. Shrink the LINE BOX -- clearing fit_content instead
		# collapses the label to nothing and the footer disappears entirely.
		lbl.add_theme_constant_override("line_separation", int(FOOT_LINE_H) - 27)
		lbl.text = QudText.to_bbcode(str(m.get("text", "")), _palette)
		if have_rects:
			# Qud's KeyMenuOption box carries 15px of internal left padding before its text
			# (HorizontalLayoutGroup padL=15, read off the live component).
			lbl.position = Vector2(float(m.get("lx", 0)) + 15.0, float(m.get("ly", 0)))
			lbl.size = Vector2(maxf(0.0, float(m.get("lw", 0)) - 15.0), float(m.get("lh", FOOT_LINE_H)))
		if not bool(m.get("disabled", false)):
			lbl.mouse_filter = Control.MOUSE_FILTER_STOP
			var idx := i
			lbl.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					_activate_menu(idx))
		host.add_child(lbl)

	# The bar's HEIGHT comes from Qud too, so the panel follows Qud's line count rather than ours --
	# the two disagreed by exactly one 22px line, which was most of the panel-height residual.
	#
	# Take the BAR'S OWN height, not the extent of its boxes: Qud's bar is 66 tall while its options
	# only reach 44, because the FlowLayoutGroup keeps a trailing row's worth of space. Measuring the
	# boxes left the panel 24px short even after the rows matched to the pixel.
	if have_rects:
		var bh := _bar_h
		if bh <= 0.0:
			for m in _menu:
				bh = maxf(bh, float(m.get("ly", 0)) + float(m.get("lh", FOOT_LINE_H)))
		_foot_abs.custom_minimum_size = Vector2(0, bh)

func _activate_menu(i: int) -> void:
	if i < 0 or i >= _menu.size():
		return
	var m: Dictionary = _menu[i]
	if bool(m.get("disabled", false)):
		return
	# Cancel is Qud's own bar entry, but it routes to the same sc.Cancel() our Esc already uses;
	# keep the one path so a click and a keypress can't diverge.
	if str(m.get("id", "")) == "Cancel":
		_answer({"do": "cancel"})
		return
	_answer({"do": "menu", "row": int(m.get("i", i)), "id": str(m.get("id", ""))})

## A bar entry whose announced key description matches this event, or -1. Qud resolves those
## descriptions through ControlManager, so they arrive as whatever the player has bound ("7",
## "Space", "Esc") — match the printable ones by character and name the few special keys.
func _menu_for_key(k: InputEventKey) -> int:
	var ch := char(k.unicode).to_lower()
	var named := ""
	match k.keycode:
		KEY_SPACE: named = "space"
		KEY_ESCAPE: named = "esc"
		KEY_ENTER, KEY_KP_ENTER: named = "enter"
		KEY_TAB: named = "tab"
	for i in _menu.size():
		var m: Dictionary = _menu[i]
		if bool(m.get("disabled", false)):
			continue
		var kd := str(m.get("key", "")).strip_edges().to_lower()
		if kd == "":
			continue
		if kd == named or (ch != "" and kd == ch):
			return i
	return -1

func hide_picker() -> void:
	if not visible:
		return
	visible = false
	_rows = []
	_menu = []
	_sel = 0
	UiState.clear_popup()
	closed.emit()

# --- rows --------------------------------------------------------------------------------------

## The hotkey cell, which BOTH row kinds get (Qud letters its categories too).
func _hotkey_cell(r: Dictionary) -> RichTextLabel:
	var hk := _mk_rt()
	hk.autowrap_mode = TextServer.AUTOWRAP_OFF
	hk.custom_minimum_size = Vector2(HOTKEY_W_INDENT if bool(r.get("indent", false)) else HOTKEY_W, 0)
	hk.add_theme_font_size_override("normal_font_size", FONT_PX)
	var kd := str(r.get("hk", ""))
	if kd != "":
		# Qud prefixes 3 spaces to an INDENTED row's hotkey — that is what widens the cell from
		# 24 to 48 and pushes the icon/text columns right, so it belongs in the text, not a margin.
		hk.text = "%s[color=#%s]%s)[/color]" % [
			("   " if bool(r.get("indent", false)) else ""), C_GOLD.to_html(false), kd]
	return hk


## Integer height for row `i` such that the running total tracks Qud's fractional one.
##
## A category row is 20.12px. Godot lays out on whole pixels, so giving every such row a 21px
## minimum accumulated ~0.9px of error per row and made the list — and therefore the whole panel —
## several px too tall. Taking the difference of the ROUNDED CUMULATIVE edges instead keeps each row
## within a pixel of Qud's AND makes the sum of any prefix match, which is what the panel height and
## the scroll-into-view maths both depend on.
func _row_px(i: int) -> float:
	var before := 0.0
	for k in i:
		before += ROW_H_CAT if bool(_rows[k].get("cat", false)) else ROW_H_ITEM
	var here: float = ROW_H_CAT if bool(_rows[i].get("cat", false)) else ROW_H_ITEM
	return roundf(before + here) - roundf(before)



func _build_rows() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var cat := bool(r.get("cat", false))
		# A `Panel`, NOT a PanelContainer. Qud's category rows are 20.12px tall, but a 16px
		# RichTextLabel reports a 21px minimum and a *Container* takes max(own, content) — so every
		# category row came out 21 and the list ran 11 x 0.88 = 9.7px long. That was the whole
		# panel-height residual. A Panel draws the same "panel" stylebox but does no child layout,
		# so the row is exactly the height Qud draws and the label overflows into the clip.
		# (line_separation cannot fix this: it spaces lines WITHIN a label, so a single-line label
		# keeps its full ascent+descent minimum regardless.)
		var row := Panel.new()
		row.custom_minimum_size = Vector2(0, _row_px(i))
		row.clip_contents = true
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		# FIXED COLUMNS, separation 0 — Qud's row is a run of fixed-width cells, so each element's
		# offset is the sum of the ones before it (caret 15, hotkey 24/48, icon 20, spacer 2). Letting
		# an HBox space them naturally is what put our text and weight in the wrong columns.
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 0)
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.add_child(hb)

		# Qud marks the highlighted row with its SelectionCaret: the 15x15 "leftrightarrow" sprite
		# tinted #cfc041ff, in a 15px gutter left of the hotkey, centred in the row. It is the only
		# selection cue the picker has (every row background is alpha zero), and a ">" glyph only
		# approximated it -- the sprite is a filled chevron with its own anti-aliased edge.
		var caret := Control.new()
		caret.custom_minimum_size = Vector2(CARET_W, 0)
		caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
		caret.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var ctex := _chrome_tex("picker_caret.png")
		caret.draw.connect(func():
			if not bool(caret.get_meta("sel", false)):
				return
			var cy := roundf((caret.size.y - CARET_H) * 0.5)
			if ctex != null:
				caret.draw_texture_rect(ctex, Rect2(0.0, cy, CARET_W, CARET_H), false, C_GOLD)
			else:
				# The sprite only exists once a picker has been open with the mod's chrome export
				# run; without a cue there is no selection at all, so fall back to the glyph.
				var f := caret.get_theme_default_font()
				if f != null:
					caret.draw_string(f, Vector2(0.0, cy + CARET_H), ">",
						HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_PX, C_GOLD))
		hb.add_child(caret)

		hb.add_child(_hotkey_cell(r))

		if cat:
			var crt := _mk_rt()
			crt.autowrap_mode = TextServer.AUTOWRAP_OFF
			crt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			crt.add_theme_font_size_override("normal_font_size", FONT_PX)
			# Qud: "[" + (collapsed ? "+" : "-") + "] {{K|name}}" — the expander marker is part of
			# the text, not a separate widget (the prefab's Expander object is inactive).
			crt.text = "[color=#%s][%s] %s[/color]" % [C_DIM.to_html(false),
				("+" if bool(r.get("collapsed", false)) else "-"), str(r.get("name", ""))]
			hb.add_child(crt)
		else:
			var icon := Control.new()
			icon.custom_minimum_size = ICON
			icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var tex: Texture2D = _tiles.texture_for(r, true)
			if tex != null:
				icon.draw.connect(func():
					icon.draw_texture_rect(tex, Rect2(Vector2.ZERO, ICON), false))
			hb.add_child(icon)

			var sp := Control.new()
			sp.custom_minimum_size = Vector2(SPACER_W, 0)
			sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hb.add_child(sp)

			var nm := _mk_rt()
			nm.autowrap_mode = TextServer.AUTOWRAP_OFF
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			nm.add_theme_font_size_override("normal_font_size", FONT_PX)
			nm.text = QudText.to_bbcode(str(r.get("name", "")), _palette)
			hb.add_child(nm)

			# Qud right-floats the weight to the ROW's right edge.
			var wt := _mk_rt()
			wt.autowrap_mode = TextServer.AUTOWRAP_OFF
			wt.add_theme_font_size_override("normal_font_size", FONT_PX)
			wt.text = "[right][color=#%s]%s#[/color][/right]" % [
				C_DIM.to_html(false), str(r.get("weight", ""))]
			hb.add_child(wt)

		var idx := i
		row.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_pick(idx))
		row.mouse_entered.connect(func(): _sel = idx; _highlight())
		_list.add_child(row)

func _highlight() -> void:
	var kids := _list.get_children()
	for i in mini(kids.size(), _rows.size()):
		var row: Panel = kids[i]
		var caret := row.get_child(0).get_child(0) as Control
		caret.set_meta("sel", i == _sel)
		caret.queue_redraw()
		# NO SELECTION BAR. Every InventoryItemScrollerLine's background Image is #ffffff00 on the
		# live screen -- alpha zero, selected row included. Qud marks the selection with the gold
		# caret alone (SelectionCaret is #cfc041ff on the selected line and #7f7f7f00 on the rest),
		# so a filled bar was ours, not Qud's.
		row.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_scroll_into_view()

func _scroll_into_view() -> void:
	if _scroll == null or _rows.is_empty():
		return
	# Rows are two different heights (item 30 / category 20.12), so the selected row's top is the
	# SUM of the ones above it — a single pitch would drift further down the list with every
	# category crossed.
	var top := 0.0
	for i in _sel:
		top += _row_px(i)
	var h := _row_px(_sel)
	var view := _scroll.size.y
	if top < _scroll.scroll_vertical:
		_scroll.scroll_vertical = int(top)
	elif top + h > _scroll.scroll_vertical + view:
		_scroll.scroll_vertical = int(top + h - view)

# --- input -------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# typing guard: this dispatch runs before the GUI pass, so a focused text field has
	# not consumed the key yet — see TypingGuard
	if TypingGuard.typing(get_viewport()):
		return
	if not visible:
		return
	if not (event is InputEventKey) or not event.is_pressed():
		return
	var k := event as InputEventKey
	match k.keycode:
		KEY_ESCAPE:
			_answer({"do": "cancel"})
			get_viewport().set_input_as_handled()
			return
		KEY_UP:
			_move(-1)
			get_viewport().set_input_as_handled()
			return
		KEY_DOWN:
			_move(1)
			get_viewport().set_input_as_handled()
			return
		KEY_PAGEUP:
			_move(-8)
			get_viewport().set_input_as_handled()
			return
		KEY_PAGEDOWN:
			_move(8)
			get_viewport().set_input_as_handled()
			return
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_pick(_sel)
			get_viewport().set_input_as_handled()
			return
	# quick-keys: Qud assigns a letter per item row and the viewer expects it to pick directly
	var ch := char(k.unicode)
	if ch != "":
		for i in _rows.size():
			if str(_rows[i].get("key", "")) == ch:
				_pick(i)
				get_viewport().set_input_as_handled()
				return
	# Then the footer bar's own keys (Qud binds the sort toggle to "Page Left" -> [7]). Rows win
	# the tie: their quick-keys are the primary interaction and the bar's are the exception.
	var mi := _menu_for_key(k)
	if mi >= 0:
		_activate_menu(mi)
		get_viewport().set_input_as_handled()

func _move(d: int) -> void:
	if _rows.is_empty():
		return
	_sel = clampi(_sel + d, 0, _rows.size() - 1)
	_highlight()

func _pick(i: int) -> void:
	if i < 0 or i >= _rows.size():
		return
	# Send the mod's OWN row index, not our list position -- the mod skips null rows when it
	# builds the frame, so the two can differ and only its index means anything to Qud.
	_answer({"do": "select", "row": int(_rows[i].get("i", i))})

func _answer(payload: Dictionary) -> void:
	answered.emit(payload)
	# Do NOT hide here. A category toggle keeps the picker up (Qud rebuilds the rows and
	# re-announces); a real pick ends it, and the mod's active:false frame is what closes us.

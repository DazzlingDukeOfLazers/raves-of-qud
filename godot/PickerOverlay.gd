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

const ROW_H := 26.0
const ICON := Vector2(16, 24)      # Qud's picker line icon box
const HOTKEY_W := 40.0
const MAX_H_FRAC := 0.72           # never taller than this share of the viewport

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
var C_SELBAR := _cq(23, 59, 60)
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

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.content_margin_left = 25
	sb.content_margin_right = 25
	sb.content_margin_top = 24
	sb.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = Vector2(520, 0)
	_panel.draw.connect(_draw_chrome)
	center.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	_title = _mk_rt()
	_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	vb.add_child(_title)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	# Qud's footer is a MENU BAR, not a caption: it wraps across as many centred lines as it
	# needs ("[Esc] Close Menu  [↕] navigate" / "[7] sort: list/by class" / "[Space] Select").
	# HFlowContainer reproduces that wrap; each entry is its own clickable label.
	_foot = HFlowContainer.new()
	_foot.alignment = FlowContainer.ALIGNMENT_CENTER
	_foot.add_theme_constant_override("h_separation", 18)
	_foot.add_theme_constant_override("v_separation", 2)
	vb.add_child(_foot)

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
	var w := _panel.size.x
	var h := _panel.size.y
	var ly := 16.0
	var cx := w * 0.5
	var side := minf(71.0, w * 0.32)
	var l0 := cx - side - 3.0
	var l1 := cx - side + 3.0
	var c0 := cx - 5.0
	var c1 := cx + 5.0
	var r0 := cx + side - 3.0
	var r1 := cx + side + 3.0
	for seg in [[0.0, l0], [l1, c0], [c1, r0], [r1, w]]:
		_panel.draw_rect(Rect2(seg[0], ly, seg[1] - seg[0], 2), C_TOPLINE)
	_panel.draw_rect(Rect2(l0 - 2, ly - 4, 2, 10), C_TOPLINE)
	_panel.draw_rect(Rect2(r1, ly - 4, 2, 10), C_TOPLINE)
	_panel.draw_rect(Rect2(c0 - 2, ly, 2, 10), C_TOPLINE)
	_panel.draw_rect(Rect2(c1, ly, 2, 10), C_TOPLINE)
	if _title.visible:
		var ty := 28.0 + _title.get_combined_minimum_size().y * 0.5
		_panel.draw_rect(Rect2(0, ty - 1, 10, 2), C_BOTLINE)
		_panel.draw_rect(Rect2(10, ty - 8, 2, 16), C_BOTLINE)
		_panel.draw_rect(Rect2(w - 12, ty - 8, 2, 16), C_BOTLINE)
		_panel.draw_rect(Rect2(w - 10, ty - 1, 10, 2), C_BOTLINE)
	var by := h - 6.0 - _foot.get_combined_minimum_size().y - 4.0
	_panel.draw_rect(Rect2(0, by, w, 1), C_BOTLINE)

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
	# Adopt QUD'S highlighted row rather than starting at zero. Its opening selection lands on
	# the first ITEM (not the leading category), and it re-clamps after every collapse — copying
	# the exported index keeps us honest through both without reimplementing either rule.
	_sel = clampi(int(data.get("sel", 0)), 0, maxi(0, _rows.size() - 1))

	var t := str(data.get("title", "")).strip_edges()
	_title.visible = t != ""
	if _title.visible:
		_title.text = "[center][color=#%s]%s[/color][/center]" % [
			C_GOLD.to_html(false), QudText.to_bbcode(t, _palette)]
	_menu = data.get("menu", [])
	_build_menu()

	_build_rows()
	_highlight()
	# Cap the panel so a 40-item picker scrolls instead of growing off-screen.
	var vh := float(get_viewport().get_visible_rect().size.y)
	_scroll.custom_minimum_size = Vector2(0, minf(_rows.size() * ROW_H, vh * MAX_H_FRAC))
	visible = true
	# Report it the same way popups do, so `hv state` / `hv assert` can see the picker is up.
	UiState.set_popup("itempicker")

## The footer bar. Each entry is Qud's own rendered text ("[{{W|Esc}}] Close Menu"), so the
## markup carries its own colours; a DISABLED entry ("navigate") is a legend and stays inert.
func _build_menu() -> void:
	for c in _foot.get_children():
		_foot.remove_child(c)
		c.queue_free()
	for i in _menu.size():
		var m: Dictionary = _menu[i]
		var lbl := _mk_rt()
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		lbl.text = QudText.to_bbcode(str(m.get("text", "")), _palette)
		if bool(m.get("disabled", false)):
			_foot.add_child(lbl)
			continue
		lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		lbl.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_activate_menu(idx))
		_foot.add_child(lbl)

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
	hk.custom_minimum_size = Vector2(HOTKEY_W, 0)
	var kd := str(r.get("hk", ""))
	if kd != "":
		hk.text = "%s[color=#%s]%s)[/color]" % [
			("   " if bool(r.get("indent", false)) else ""), C_GOLD.to_html(false), kd]
	return hk

func _build_rows() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(0, ROW_H)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(hb)

		hb.add_child(_hotkey_cell(r))

		if bool(r.get("cat", false)):
			var crt := _mk_rt()
			crt.autowrap_mode = TextServer.AUTOWRAP_OFF
			crt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# Qud: "[" + (collapsed ? "+" : "-") + "] {{K|name}}"
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

			var nm := _mk_rt()
			nm.autowrap_mode = TextServer.AUTOWRAP_OFF
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			nm.text = QudText.to_bbcode(str(r.get("name", "")), _palette)
			hb.add_child(nm)

			var wt := _mk_rt()
			wt.autowrap_mode = TextServer.AUTOWRAP_OFF
			wt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			wt.text = "[color=#%s]%s#[/color]" % [C_DIM.to_html(false), str(r.get("weight", ""))]
			hb.add_child(wt)

		# Qud marks the highlighted row with a gold ">" in the left gutter, outside the hotkey
		# column — drawn per row so the caret can't drift out of step with the selection bar.
		var caret := _mk_rt()
		caret.autowrap_mode = TextServer.AUTOWRAP_OFF
		caret.custom_minimum_size = Vector2(14, 0)
		hb.add_child(caret)
		hb.move_child(caret, 0)

		var idx := i
		row.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_pick(idx))
		row.mouse_entered.connect(func(): _sel = idx; _highlight())
		_list.add_child(row)

func _highlight() -> void:
	var kids := _list.get_children()
	for i in mini(kids.size(), _rows.size()):
		var row: PanelContainer = kids[i]
		var caret: RichTextLabel = row.get_child(0).get_child(0)
		caret.text = "[color=#%s]>[/color]" % C_GOLD.to_html(false) if i == _sel else ""
		if i == _sel:
			var sb := StyleBoxFlat.new()
			sb.bg_color = C_SELBAR
			sb.content_margin_left = 4
			row.add_theme_stylebox_override("panel", sb)
		else:
			var sbe := StyleBoxEmpty.new()
			sbe.content_margin_left = 4
			row.add_theme_stylebox_override("panel", sbe)
	_scroll_into_view()

func _scroll_into_view() -> void:
	if _scroll == null or _rows.is_empty():
		return
	var top := _sel * ROW_H
	var view := _scroll.size.y
	if top < _scroll.scroll_vertical:
		_scroll.scroll_vertical = int(top)
	elif top + ROW_H > _scroll.scroll_vertical + view:
		_scroll.scroll_vertical = int(top + ROW_H - view)

# --- input -------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
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

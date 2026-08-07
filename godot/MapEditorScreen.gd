extends Control

## THE MAP EDITOR — a 1:1 mimic of Caves of Qud's Modding Toolkit › Map Editor.
##
## Qud's editor is a menu bar over an 80x25 cell canvas, with a blueprint palette down the right
## side and live readouts under it. Geometry MEASURED off a 1920x1080 capture of Qud 1.0.5
## (2026-08-06): menu text baselines y10..21 with items starting at x29/95/160/275/342, the title
## "Map Editor" centred at x913..1006, canvas x50..1470 y208..872 (80x25 -> cell 17.75 x 26.56),
## palette rows pitch 24 from y38, readouts at y688 and y710, control hints at y1023 and y1039.
##
## The palette DATA is the player's own install — blueprints.json, exported by the bridge mod
## (BlueprintExporter). Never bundled. The menu ITEM lists are verbatim from Qud's own menus,
## cross-checked against Overlay.MapEditor.MapEditorView by reflection, so the hotkey column is
## the real one rather than a guess.
##
## Scope note: this reproduces the editor's CHROME and its selection/paint model in Raves. It does
## not write Qud .rpm map files — saving is a later leaf. Editing here drives Raves' own grid; the
## bridge command `mapedit` (mod/MapEditorDriver.cs) is what drives QUD's editor when the two need
## to be compared.
##
## Opened from ModdingToolkitScreen via MainMenu's open_tool. UiState scene: "map_editor".

signal closed

var ui_scene := "map_editor"

# ── palette (sampled off the reference) ───────────────────────────────────────
const BG := Color8(0x06, 0x14, 0x14)            # window field behind everything
const BAR_BG := Color8(0x0B, 0x24, 0x24)        # menu bar strip
const BAR_TEXT := Color8(0xD2, 0xE4, 0xE0)
const BAR_HILITE := Color8(0x1D, 0x4A, 0x46)    # hovered/open menu item background
const MENU_BG := Color8(0x0E, 0x2E, 0x2C)       # dropdown panel
const MENU_BORDER := Color8(0x4C, 0x74, 0x70)
const HOTKEY := Color8(0x8A, 0xA6, 0xA2)        # the Ctrl+X column, dimmer than the label
const CANVAS_BG := Color8(0x0A, 0x2A, 0x28)
const GRID_DOT := Color8(0x14, 0x3E, 0x3B)
const CURSOR := Color8(0x3C, 0xE0, 0x50)        # the green cell cursor / selection frame
const PANEL_TEXT := Color8(0xCF, 0xE2, 0xDE)
const HINT := Color8(0xB8, 0xC8, 0xC4)
const SEP := Color8(0x39, 0x5C, 0x58)

const FONT_MONO := "res://fonts/SourceCodePro-Regular.ttf"

# ── geometry, measured at 1920x1080 ───────────────────────────────────────────
const BAR_H := 32
const BAR_TEXT_PX := 15
const MENU_X := {"File": 29, "Edit": 95, "Transform": 160, "View": 275, "Recent": 342}
const TITLE_X := 913
const CANVAS := Rect2(50, 208, 1420, 664)
const COLS := 80
const ROWS := 25
const PANEL_X := 1524
const PALETTE_TOP := 38
const PALETTE_ROW_H := 24
const READOUT_Y := 688
const READOUT_Y2 := 710
const HINT_Y := 1023
const HINT_Y2 := 1039
const MAX_PALETTE_ROWS := 60   # rendered rows; the count line reports anything not drawn

## Qud's menus, verbatim. `hot` is the right-hand hotkey column ("" = none). Cross-checked against
## MapEditorView: New map/Load map/Test/Save/SaveAs/_ReloadBlueprints/Exit, SelectAll/Undo/Redo,
## FlipHorizontal/FlipVertical, ToggleOverlay.
const MENUS := {
	"File": [
		{"text": "New map", "hot": "Ctrl+N", "act": "new"},
		{"text": "Load map...", "hot": "Ctrl+O", "act": ""},
		{"text": "Test", "hot": "Ctrl+T", "act": ""},
		{"text": "Save", "hot": "Ctrl+S", "act": ""},
		{"text": "Save As...", "hot": "", "act": ""},
		{"sep": true},
		{"text": "Reload Blueprints", "hot": "", "act": "reload"},
		{"sep": true},
		{"text": "Exit", "hot": "", "act": "exit"},
	],
	"Edit": [
		{"text": "Select All", "hot": "Ctrl+A", "act": "selectall"},
		{"text": "Undo", "hot": "Ctrl+Z", "act": "undo"},
		{"text": "Redo", "hot": "Ctrl+Y", "act": "redo"},
	],
	"Transform": [
		{"text": "Flip Horizontal", "hot": "", "act": "fliph"},
		{"text": "Flip Vertical", "hot": "", "act": "flipv"},
	],
	"View": [
		{"text": "Toggle NorthSheva Overlay", "hot": "Ctrl+F1", "act": "overlay"},
	],
	"Recent": [],   # populated from recent files; EMPTY on a fresh install (measured)
}

var _blueprints: Array = []      # [{name, display, tile, …}] from blueprints.json
var _filtered: Array = []
var _brush := ""
var _hover := Vector2i(-1, -1)
var _selected := Vector2i(-1, -1)
var _region := Rect2i(0, 0, 0, 0)
var _has_region := false
var _drag_start := Vector2i(-1, -1)
var _dragging := false
var _cells := {}                 # Vector2i -> [blueprint names]
var _undo: Array = []
var _overlay_on := false

var _open_menu := ""
var _menu_panel: Control
var _canvas: Control
var _palette_list: VBoxContainer
var _filter_edit: LineEdit
var _readout_a: Label
var _readout_b: Label
var _in_use := false
var _count_note: Label

func _ready() -> void:
	name = "MapEditorScreen"
	_fit_to_viewport()
	theme = UiFont.make_theme(get_viewport())
	var empty := StyleBoxEmpty.new()
	for tt in ["Label", "Caption", "Title", "Big"]:
		theme.set_stylebox("normal", tt, empty)
	get_viewport().size_changed.connect(_fit_to_viewport)

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	_load_blueprints()
	_build_menubar()
	_build_canvas()
	_build_palette()
	_build_readouts()
	_build_hints()
	_refresh_filter()
	set_process(true)

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── data ──────────────────────────────────────────────────────────────────────

func _load_blueprints() -> void:
	var path := InputModel.support_dir().path_join("blueprints.json")
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.get("blueprints", null) is Array:
		_blueprints = d["blueprints"]
		_blueprints.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))

# ── menu bar ──────────────────────────────────────────────────────────────────

func _mono(l: Label, px: int) -> void:
	l.add_theme_font_override("font", load(FONT_MONO))
	l.add_theme_font_size_override("font_size", px)

func _build_menubar() -> void:
	var bar := ColorRect.new()
	bar.color = BAR_BG
	bar.position = Vector2.ZERO
	bar.size = Vector2(get_viewport_rect().size.x, BAR_H)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	for m in MENU_X.keys():
		var l := Label.new()
		l.text = m
		_mono(l, BAR_TEXT_PX)
		l.add_theme_color_override("font_color", BAR_TEXT)
		l.position = Vector2(MENU_X[m], 7)
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		l.mouse_entered.connect(func():
			if _open_menu != "":   # Qud slides between menus once one is open
				_open_dropdown(m))
		l.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_open_dropdown("" if _open_menu == m else m))
		add_child(l)

	var t := Label.new()
	t.text = "Map Editor"
	_mono(t, BAR_TEXT_PX)
	t.add_theme_color_override("font_color", BAR_TEXT)
	t.position = Vector2(TITLE_X, 7)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(t)

func _open_dropdown(which: String) -> void:
	if _menu_panel != null:
		_menu_panel.queue_free()
		_menu_panel = null
	_open_menu = which
	if which == "":
		return
	var items: Array = MENUS.get(which, [])
	if items.is_empty():
		return   # Qud draws no panel for an empty menu (Recent, fresh install) — measured
	var panel := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = MENU_BG
	sb.set_border_width_all(1)
	sb.border_color = MENU_BORDER
	panel.add_theme_stylebox_override("panel", sb)
	var row_h := 33
	var w := 0
	for it in items:
		if it.get("sep", false):
			continue
		w = maxi(w, 170 + str(it.get("hot", "")).length() * 8)
	panel.position = Vector2(MENU_X[which] - 12, BAR_H)
	var h := 0
	for it in items:
		h += 7 if it.get("sep", false) else row_h
	panel.size = Vector2(w + 40, h + 12)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	_menu_panel = panel

	var y := 6
	for it in items:
		if it.get("sep", false):
			var line := ColorRect.new()
			line.color = SEP
			line.position = Vector2(6, y + 3)
			line.size = Vector2(panel.size.x - 12, 1)
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			panel.add_child(line)
			y += 7
			continue
		var row := Control.new()
		row.position = Vector2(0, y)
		row.size = Vector2(panel.size.x, row_h)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var hl := ColorRect.new()
		hl.color = Color(0, 0, 0, 0)
		hl.set_anchors_preset(Control.PRESET_FULL_RECT)
		hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(hl)
		var lbl := Label.new()
		lbl.text = str(it.get("text", ""))
		_mono(lbl, 15)
		lbl.add_theme_color_override("font_color", BAR_TEXT)
		lbl.position = Vector2(22, 6)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lbl)
		if str(it.get("hot", "")) != "":
			var hk := Label.new()
			hk.text = str(it["hot"])
			_mono(hk, 11)
			hk.add_theme_color_override("font_color", HOTKEY)
			hk.position = Vector2(panel.size.x - 60, 10)
			hk.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(hk)
		var act := str(it.get("act", ""))
		row.mouse_entered.connect(func(): hl.color = BAR_HILITE)
		row.mouse_exited.connect(func(): hl.color = Color(0, 0, 0, 0))
		row.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_open_dropdown("")
				_do(act))
		panel.add_child(row)
		y += row_h

func _do(act: String) -> void:
	match act:
		"exit":
			closed.emit()
		"new":
			_cells.clear(); _undo.clear(); _has_region = false; _canvas.queue_redraw()
		"selectall":
			_region = Rect2i(0, 0, COLS, ROWS); _has_region = true; _canvas.queue_redraw()
		"undo":
			if not _undo.is_empty():
				_cells = _undo.pop_back(); _canvas.queue_redraw()
		"fliph", "flipv":
			var out := {}
			for k in _cells:
				var p: Vector2i = k
				out[Vector2i(COLS - 1 - p.x, p.y) if act == "fliph" else Vector2i(p.x, ROWS - 1 - p.y)] = _cells[k]
			_push_undo(); _cells = out; _canvas.queue_redraw()
		"overlay":
			_overlay_on = not _overlay_on; _canvas.queue_redraw()
		"reload":
			_load_blueprints(); _refresh_filter()

func _push_undo() -> void:
	_undo.append(_cells.duplicate(true))
	if _undo.size() > 50:
		_undo.pop_front()

# ── canvas ────────────────────────────────────────────────────────────────────

func _build_canvas() -> void:
	_canvas = Control.new()
	_canvas.position = CANVAS.position
	_canvas.size = CANVAS.size
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_canvas_input)
	_canvas.mouse_exited.connect(func(): _hover = Vector2i(-1, -1); _canvas.queue_redraw())
	add_child(_canvas)

func _cell_size() -> Vector2:
	return Vector2(CANVAS.size.x / float(COLS), CANVAS.size.y / float(ROWS))

func _cell_at(p: Vector2) -> Vector2i:
	var cs := _cell_size()
	return Vector2i(int(p.x / cs.x), int(p.y / cs.y))

func _draw_canvas() -> void:
	var cs := _cell_size()
	_canvas.draw_rect(Rect2(Vector2.ZERO, CANVAS.size), CANVAS_BG)
	if _overlay_on:
		# the View menu's NorthSheva tracing overlay — Qud's own art when extracted
		var tex := _overlay_texture()
		if tex != null:
			_canvas.draw_texture_rect(tex, Rect2(Vector2.ZERO, CANVAS.size), false,
				Color(1, 1, 1, 0.35))
	# the dotted grid: one dot per cell centre, like Qud's empty field
	for x in range(COLS):
		for y in range(ROWS):
			var c := Vector2((x + 0.5) * cs.x, (y + 0.5) * cs.y)
			_canvas.draw_rect(Rect2(c - Vector2(1.5, 1.5), Vector2(3, 3)), GRID_DOT)
	# painted cells — render the blueprint's glyph until tiles are wired
	for k in _cells:
		var p: Vector2i = k
		var names: Array = _cells[k]
		if names.is_empty():
			continue
		var r := Rect2(Vector2(p.x * cs.x, p.y * cs.y), cs)
		_canvas.draw_rect(r.grow(-2.0), Color(0.35, 0.75, 0.35, 0.55))
	if _has_region:
		var rr := Rect2(Vector2(_region.position.x * cs.x, _region.position.y * cs.y),
			Vector2(_region.size.x * cs.x, _region.size.y * cs.y))
		_canvas.draw_rect(rr, CURSOR, false, 2.0)
	if _hover.x >= 0:
		var hr := Rect2(Vector2(_hover.x * cs.x, _hover.y * cs.y), cs)
		_canvas.draw_rect(hr, CURSOR, false, 2.0)

func _overlay_texture() -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("bg").path_join("raw_bears.png")
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _canvas_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var c := _cell_at(e.position)
		if c != _hover:
			_hover = c
			if _dragging:
				_region = _rect_from(_drag_start, c)
				_has_region = true
			_update_readouts()
			_canvas.queue_redraw()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		var c := _cell_at(e.position)
		if e.pressed:
			if Input.is_key_pressed(KEY_SHIFT):        # Qud: Shift+drag = region select
				_dragging = true
				_drag_start = c
				_region = _rect_from(c, c)
				_has_region = true
			elif Input.is_key_pressed(KEY_CTRL):       # Qud: Ctrl+drag = paint from palette
				_paint(c)
			elif Input.is_key_pressed(KEY_ALT):        # Qud: Alt+click = sample to palette
				var names: Array = _cells.get(c, [])
				if not names.is_empty():
					_set_brush(str(names[-1]))
			else:
				_selected = c
			_update_readouts()
			_canvas.queue_redraw()
		else:
			_dragging = false

func _rect_from(a: Vector2i, b: Vector2i) -> Rect2i:
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(lo, hi - lo + Vector2i.ONE)

func _paint(c: Vector2i) -> void:
	if _brush == "" or c.x < 0 or c.y < 0 or c.x >= COLS or c.y >= ROWS:
		return
	_push_undo()
	var names: Array = _cells.get(c, [])
	names.append(_brush)
	_cells[c] = names

# ── palette ───────────────────────────────────────────────────────────────────

func _build_palette() -> void:
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Enter text..."
	_filter_edit.position = Vector2(PANEL_X, 4)
	_filter_edit.size = Vector2(get_viewport_rect().size.x - PANEL_X - 4, 26)
	_filter_edit.add_theme_font_size_override("font_size", 14)
	var fb := StyleBoxFlat.new()
	fb.bg_color = Color8(0x08, 0x1E, 0x1E)
	fb.set_border_width_all(1)
	fb.border_color = MENU_BORDER
	fb.content_margin_left = 6
	_filter_edit.add_theme_stylebox_override("normal", fb)
	_filter_edit.add_theme_stylebox_override("focus", fb)
	_filter_edit.add_theme_color_override("font_color", PANEL_TEXT)
	_filter_edit.text_changed.connect(func(_t): _refresh_filter())
	add_child(_filter_edit)

	# Qud's "In Use" toggle limits the list to blueprints already placed on the map
	var use := Label.new()
	use.text = "[ ] In Use"
	_mono(use, 14)
	use.add_theme_color_override("font_color", PANEL_TEXT)
	use.position = Vector2(get_viewport_rect().size.x - 110, PALETTE_TOP + 2)
	use.mouse_filter = Control.MOUSE_FILTER_STOP
	use.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_in_use = not _in_use
			use.text = ("[x] In Use" if _in_use else "[ ] In Use")
			_refresh_filter())
	add_child(use)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(PANEL_X, PALETTE_TOP + 24)
	scroll.size = Vector2(get_viewport_rect().size.x - PANEL_X - 4, READOUT_Y - PALETTE_TOP - 32)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_palette_list = VBoxContainer.new()
	_palette_list.add_theme_constant_override("separation", 0)
	scroll.add_child(_palette_list)

func _refresh_filter() -> void:
	var q := _filter_edit.text.strip_edges().to_lower() if _filter_edit != null else ""
	var used := {}
	for k in _cells:
		for n in _cells[k]:
			used[n] = true
	_filtered.clear()
	var dropped := 0
	for b in _blueprints:
		var n := str(b.get("name", ""))
		if q != "" and not (q in n.to_lower()):
			continue
		if _in_use and not used.has(n):
			continue
		if _filtered.size() >= MAX_PALETTE_ROWS:
			dropped += 1
			continue
		_filtered.append(b)
	_populate_palette(dropped)

func _populate_palette(dropped: int) -> void:
	for c in _palette_list.get_children():
		c.queue_free()
	for b in _filtered:
		_palette_list.add_child(_palette_row(b))
	if _count_note == null:
		_count_note = Label.new()
		_count_note.add_theme_font_size_override("font_size", 12)
		_count_note.add_theme_color_override("font_color", HINT)
		_count_note.position = Vector2(PANEL_X, READOUT_Y - 20)
		_count_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_count_note)
	# never a silent cap — say what was left undrawn (user mode only; Qud has no such line)
	if Settings.one_to_one():
		_count_note.text = ""
	elif _blueprints.is_empty():
		_count_note.text = "no blueprints.json — run the bridge export"
	else:
		_count_note.text = ("%d shown of %d" % [_filtered.size(), _blueprints.size()]) + \
			(" (%d more not drawn)" % dropped if dropped > 0 else "")

func _palette_row(b: Dictionary) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, PALETTE_ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	var hl := ColorRect.new()
	hl.color = Color(0, 0, 0, 0)
	hl.set_anchors_preset(Control.PRESET_FULL_RECT)
	hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hl)
	var name := str(b.get("name", ""))
	var lbl := Label.new()
	lbl.text = name
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", PANEL_TEXT)
	lbl.position = Vector2(28, 3)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)
	row.mouse_entered.connect(func(): hl.color = BAR_HILITE if _brush != name else hl.color)
	row.mouse_exited.connect(func(): hl.color = Color(0.25, 0.6, 0.3, 0.55) if _brush == name else Color(0, 0, 0, 0))
	row.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_set_brush(name)
			_populate_palette(0))
	if _brush == name:
		hl.color = Color(0.25, 0.6, 0.3, 0.55)
	return row

func _set_brush(n: String) -> void:
	_brush = n
	_update_readouts()

# ── readouts + hints ──────────────────────────────────────────────────────────

func _build_readouts() -> void:
	_readout_a = Label.new()
	_readout_a.add_theme_font_size_override("font_size", 15)
	_readout_a.add_theme_color_override("font_color", PANEL_TEXT)
	_readout_a.position = Vector2(PANEL_X + 4, READOUT_Y)
	_readout_a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_readout_a)
	_readout_b = Label.new()
	_readout_b.add_theme_font_size_override("font_size", 15)
	_readout_b.add_theme_color_override("font_color", PANEL_TEXT)
	_readout_b.position = Vector2(PANEL_X + 4, READOUT_Y2)
	_readout_b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_readout_b)
	_update_readouts()

func _update_readouts() -> void:
	if _readout_a == null:
		return
	var mp := "%d, %d" % [_hover.x, _hover.y] if _hover.x >= 0 else "0, 0"
	_readout_a.text = "Mouse Position: %s        Brush: %s" % [mp, _brush]
	if _has_region:
		_readout_b.text = "Selected Cell: %d, %d - %d, %d" % [
			_region.position.x, _region.position.y,
			_region.position.x + _region.size.x - 1, _region.position.y + _region.size.y - 1]
	elif _selected.x >= 0:
		_readout_b.text = "Selected Cell: %d, %d" % [_selected.x, _selected.y]
	else:
		_readout_b.text = "Selected Cell: none"

func _build_hints() -> void:
	for spec in [[HINT_Y, "Ctrl+Click-Paint from palette    Alt+Click-Select to palette"],
			[HINT_Y2, "Ctrl+Z-Undo  Ctrl+Y-Redo"]]:
		var l := Label.new()
		l.text = str(spec[1])
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", HINT)
		l.position = Vector2(2, spec[0])
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)

# ── input ─────────────────────────────────────────────────────────────────────

func _unhandled_input(e: InputEvent) -> void:
	if TypingGuard.typing(get_viewport()) and not e.is_action_pressed("ui_cancel"):
		return
	if e is InputEventKey and e.pressed and e.ctrl_pressed:
		match e.keycode:
			KEY_N: _do("new"); accept_event(); return
			KEY_A: _do("selectall"); accept_event(); return
			KEY_Z: _do("undo"); accept_event(); return
			KEY_F1: _do("overlay"); accept_event(); return
	if e.is_action_pressed("ui_cancel"):
		if _open_menu != "":
			_open_dropdown("")
		elif _filter_edit != null and _filter_edit.has_focus():
			_filter_edit.release_focus()
		else:
			closed.emit()
		accept_event()

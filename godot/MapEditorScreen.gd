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

# Per-object context menu. The five items and their ORDER are Qud's own: MapEditorView.OnEnter
# builds ContextMenu with exactly five Menu.addItem calls and -- unlike the File/Edit menus --
# no HotKeyText follow-up, so there is no hotkey column. Geometry measured off a live capture:
# the panel's top-left sits AT the mouse (offset 0,+1), 127x85 for five 17px rows, text inset 13.
const CTX_ITEMS := [
	{"text": "Set owner", "act": "ctx_owner"},
	{"text": "Set part", "act": "ctx_part"},
	{"text": "Add string property", "act": "ctx_addprop"},
	{"text": "Add int property", "act": "ctx_addint"},
	{"text": "Remove property", "act": "ctx_delprop"},
]
const CTX_W := 127
const CTX_H := 85
const CTX_TEXT_X := 13
# Qud draws these labels on a FIXED CELL, not with a font's own metrics: across the five items
# the ink width tracks 5.0 px/char exactly (19 chars -> 94 px, 16 -> 79, 15 -> 74), and no
# integer font size reproduces that in Godot -- 8 comes out 5% narrow, 9 runs 7% wide. So we
# advance the pen ourselves, the same way the glyph fallback draws on the canvas grid.
const CTX_ADVANCE := 5.0
const CTX_TEXT_PX := 8          # cap height 5 px, measured off "Set part"
const CTX_ROW_PITCH := 16.5     # baselines measured at 12, 28, 45, 61, 78
const CTX_BASELINE := 12.0
# The panel is OPAQUE and 1px-scanlined -- sampling 448 interior pixels found exactly two
# colours alternating every row, with the parity keyed to SCREEN y, not to the panel.
const CTX_LINE_EVEN := Color8(0x05, 0x32, 0x30)   # (5,50,48)
const CTX_LINE_ODD := Color8(0x02, 0x16, 0x16)    # (2,22,22)
const CTX_TEXT_COL := Color8(0xC2, 0xCD, 0xCC)    # (194,205,204)
const CTX_HILITE := Color8(0x1D, 0x4A, 0x46)

# The DialogManager popups the context actions open. Measured at 1920x1080: the panel is a flat
# grey centred on x=959.5, the screen behind it dimmed with black at alpha 0.42, and the text
# fields are a FIXED 204 wide centred on the same axis regardless of the panel's width.
const DLG_DIM := 0.42
const DLG_PANEL := Color8(0x6B, 0x6B, 0x6B)       # (107,107,107)
const DLG_FIELD_W := 204
const DLG_FIELD_H := 17
const DLG_BTN_W := 59
const DLG_BTN_H := 23
const DLG_PAD := 18
const DLG_TITLE_PX := 15
const DLG_TEXT_PX := 14
const DLG_FIELD_BG := Color8(0xFF, 0xFF, 0xFF)    # (255,255,255) — sampled, pure white
const DLG_BTN_BG := Color8(0xF5, 0xF5, 0xF5)      # (245,245,245)
const DLG_INK := Color8(0x37, 0x37, 0x37)         # (55,55,55) — field and button text
const DLG_TITLE_INK := Color8(0xFD, 0xFD, 0xFD)   # (253,253,253)

## Qud's menus, verbatim. `hot` is the right-hand hotkey column ("" = none). Cross-checked against
## MapEditorView: New map/Load map/Test/Save/SaveAs/_ReloadBlueprints/Exit, SelectAll/Undo/Redo,
## FlipHorizontal/FlipVertical, ToggleOverlay.
const MENUS := {
	"File": [
		{"text": "New map", "hot": "Ctrl+N", "act": "new"},
		{"text": "Load map...", "hot": "Ctrl+O", "act": "load"},
		{"text": "Test", "hot": "Ctrl+T", "act": "test"},
		{"text": "Save", "hot": "Ctrl+S", "act": "save"},
		{"text": "Save As...", "hot": "", "act": "saveas"},
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
## Vector2i -> [ {name, owner, part, iprops:{}} ]. Objects are DICTS, not bare names,
## because a .rpm carries Owner/Part attributes and <intproperty> children per object;
## storing only the name would silently drop them on a load -> save round-trip.
var _cells := {}
var _filename := ""              # current .rpm path ("" = never saved)
var _dialog: FileDialog
var _undo: Array = []
var _overlay_on := false

## Qud tile rendering, via the shared helper every other view uses (it handles the
## path -> filename normalisation, the grayscale-mask recolour, and caching).
var _tiles                       # QudTiles instance
var _by_name := {}               # blueprint name -> record, for tile/colour lookup
var _requested := {}             # tile paths already asked of the mod, so we ask once
var _peer := StreamPeerTCP.new()

var _retry_t := 0.0
var _open_menu := ""
var _menu_panel: Control
var _canvas: Control
var _palette_list: VBoxContainer
var _filter_edit: LineEdit
var _readout_a: Label
var _readout_b: Label
var _in_use := false
var _count_note: Label
var _title_label: Label
var _ctx: Control                # the per-object context menu panel ("" = closed)
var _ctx_cell := Vector2i(-1, -1)
var _ctx_bp := ""                # the blueprint the menu is acting on
var _ctx_hover := -1
var _modal: Control              # the active DialogManager-style popup

## macOS turns Ctrl+left-click into a RIGHT-button event in the display server itself
## (the platform's "control-click == secondary click" convention, applied in Godot's
## GodotContentView mouseDown/mouseDragged/mouseUp). Godot exposes no switch for it, so the
## editor un-converts below: a RIGHT button carrying ctrl is really the Ctrl+left paint
## gesture, and a genuine right-click always arrives with ctrl CLEAR. Measured 2026-08-08 —
## ctrl+left logged `btn=2 ctrl=true` while a real right-click logged `btn=2 ctrl=false`.
## Ctrl+right is not a Map Editor binding, so collapsing the two costs nothing.
var _mac := OS.get_name() == "macOS"

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

	_tiles = load("res://QudTiles.gd").new()
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
	_load_blueprints()
	_build_menubar()
	_build_canvas()
	_build_palette()
	_build_readouts()
	_build_hints()
	_refresh_filter()
	set_process(true)

func _process(dt: float) -> void:
	_peer.poll()
	if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var avail := _peer.get_available_bytes()
		if avail > 0:
			_peer.get_data(avail)     # drain; we only SEND on this socket
	# a requested tile lands on disk a moment later — retry those cells periodically
	if not _requested.is_empty():
		_retry_t += dt
		if _retry_t >= 1.0:
			_retry_t = 0.0
			_canvas.queue_redraw()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

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
		for b in _blueprints:
			_by_name[str(b.get("name", ""))] = b

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

	_title_label = Label.new()
	var t := _title_label
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
			_push_undo()
			_cells.clear(); _has_region = false; _filename = ""
			_update_title(); _refresh_filter(); _canvas.queue_redraw()
		"load":
			_pick_file(false)
		"save":
			if _filename == "":
				_pick_file(true)
			else:
				_save_rpm(_filename)
		"saveas":
			_pick_file(true)
		"test":
			_run_test()
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
		"ctx_owner":
			_ctx_set_owner()
		"ctx_part":
			_ctx_set_part()
		"ctx_addprop":
			_ctx_add_prop(false)
		"ctx_addint":
			_ctx_add_prop(true)
		"ctx_delprop":
			_ctx_remove_prop()

# .rpm file I/O ---------------------------------------------------------------
# Qud's map format, read off the 273 shipped maps in StreamingAssets/Base:
#   <Map Width="80" Height="25">
#     <cell X="0" Y="0">
#       <object Name="Fulcrete"></object>
#       <object Name="X" Owner="o" Part="p"><intproperty Name="N" Value="1" /></object>
#     </cell>
# Attribute census over every shipped map: Name 129143, Owner 392, Part 37, plus 96
# <intproperty> children -- that is the entire surface a round-trip has to preserve.
# Cells are written in Qud's own order (X outer, Y inner); empty cells are omitted.

func _obj_name(o) -> String:
	return str(o.get("name", "")) if o is Dictionary else str(o)

func _maps_dir() -> String:
	var d := InputModel.support_dir().path_join("maps")
	DirAccess.make_dir_recursive_absolute(d)
	return d

func _xml_escape(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

func _save_rpm(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("map editor: cannot write " + path)
		return false
	f.store_string("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	f.store_string("<Map Width=\"%d\" Height=\"%d\">\n" % [COLS, ROWS])
	for x in range(COLS):
		for y in range(ROWS):
			var objs: Array = _cells.get(Vector2i(x, y), [])
			if objs.is_empty():
				# Qud writes EVERY cell of the grid, empties included as a one-line
				# <cell X=".." Y=".."></cell> — verified against the shipped maps (2000
				# cells for 80x25, 122 of them empty). Omitting them round-tripped every
				# object correctly but still differed from Qud's own output, so match it.
				f.store_string("  <cell X=\"%d\" Y=\"%d\"></cell>
" % [x, y])
				continue
			f.store_string("  <cell X=\"%d\" Y=\"%d\">\n" % [x, y])
			for o in objs:
				var line := "    <object Name=\"%s\"" % _xml_escape(_obj_name(o))
				if o is Dictionary:
					if str(o.get("owner", "")) != "":
						line += " Owner=\"%s\"" % _xml_escape(str(o["owner"]))
					if str(o.get("part", "")) != "":
						line += " Part=\"%s\"" % _xml_escape(str(o["part"]))
				var sp: Dictionary = o.get("props", {}) if o is Dictionary else {}
				var ip: Dictionary = o.get("iprops", {}) if o is Dictionary else {}
				if ip.is_empty() and sp.is_empty():
					f.store_string(line + "></object>\n")
				else:
					f.store_string(line + ">")
					for k in sp:
						f.store_string("<property Name=\"%s\" Value=\"%s\" />" % [
							_xml_escape(str(k)), _xml_escape(str(sp[k]))])
					for k in ip:
						f.store_string("<intproperty Name=\"%s\" Value=\"%s\" />" % [
							_xml_escape(str(k)), _xml_escape(str(ip[k]))])
					f.store_string("</object>\n")
			f.store_string("  </cell>\n")
	f.store_string("</Map>\n")
	f.close()
	_filename = path
	_update_title()
	return true

func _load_rpm(path: String) -> bool:
	var px := XMLParser.new()
	if px.open(path) != OK:
		push_warning("map editor: cannot read " + path)
		return false
	var cells := {}
	var cur := Vector2i(-1, -1)
	var cur_obj: Dictionary = {}
	while px.read() == OK:
		var t := px.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			var n := px.get_node_name().to_lower()
			if n == "cell":
				cur = Vector2i(int(px.get_named_attribute_value_safe("X")),
					int(px.get_named_attribute_value_safe("Y")))
			elif n == "object" and cur.x >= 0:
				cur_obj = {"name": px.get_named_attribute_value_safe("Name"),
					"owner": px.get_named_attribute_value_safe("Owner"),
					"part": px.get_named_attribute_value_safe("Part"),
					"props": {}, "iprops": {}}
				var arr: Array = cells.get(cur, [])
				arr.append(cur_obj)
				cells[cur] = arr
				if px.is_empty():
					cur_obj = {}          # <object ... /> — no children follow
			elif n == "property" and not cur_obj.is_empty():
				cur_obj["props"][px.get_named_attribute_value_safe("Name")] = \
					px.get_named_attribute_value_safe("Value")
			elif n == "intproperty" and not cur_obj.is_empty():
				cur_obj["iprops"][px.get_named_attribute_value_safe("Name")] = \
					px.get_named_attribute_value_safe("Value")
		elif t == XMLParser.NODE_ELEMENT_END and px.get_node_name().to_lower() == "object":
			cur_obj = {}
	_push_undo()
	_cells = cells
	_filename = path
	_has_region = false
	_update_title()
	_refresh_filter()
	_canvas.queue_redraw()
	return true

## Test: write the current map to a scratch .rpm and ask Qud to build it as a live zone.
## Raves does not simulate — Qud owns worldgen — so this hands the map to Qud's OWN Test
## (MapEditorDriver.Test -> MapEditorView.Test), which needs Qud sitting in its Map Editor.
## Saving first means Test always runs the map you can SEE, saved or not.
func _run_test() -> void:
	var scratch := _maps_dir().path_join("_raves_test.rpm")
	var keep := _filename            # a scratch write must not steal the document's identity
	if not _save_rpm(scratch):
		push_warning("map editor: could not write the test map")
		return
	_filename = keep
	_update_title()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_warning("map editor: Test needs the Qud bridge (is Qud running?)")
		return
	var msg := {"type": "command", "name": "mapedit", "do": "test", "bp": scratch}
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF); frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF); frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## Qud shows the open file in the title (MapEditorView.UpdateTitle); mirror that.
func _update_title() -> void:
	if _title_label == null:
		return
	_title_label.text = "Map Editor" if _filename == "" else "Map Editor - " + _filename.get_file()

## Raves uses a Godot FileDialog here; Qud has its own picker, so this is one of the
## deliberate non-1:1 spots (a file chooser is chrome, not game UI).
func _pick_file(save: bool) -> void:
	if _dialog != null:
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.current_dir = _maps_dir()
	_dialog.filters = PackedStringArray(["*.rpm ; Qud map"])
	_dialog.size = Vector2i(900, 600)
	_dialog.file_selected.connect(func(p: String):
		if save:
			_save_rpm(p if p.ends_with(".rpm") else p + ".rpm")
		else:
			_load_rpm(p))
	add_child(_dialog)
	_dialog.popup_centered()

# per-object context menu ------------------------------------------------------
# Qud builds this menu but never shows it: DisplayContextInRegion has NO caller anywhere in
# Assembly-CSharp (verified by an IL scan of every method on MapEditorView, and its own
# OnCommand has no branch for the "MiddleTile:x,y" command OnClick faithfully dispatches).
# So the middle button is a slot Qud dispatches and drops on the floor. Raves hangs the menu
# there -- a DELIBERATE divergence, and the only one available: reproducing the menu 1:1 while
# leaving it unreachable would be reproducing a bug rather than the UI.

func _erase_top(c: Vector2i) -> void:
	var objs: Array = _cells.get(c, [])
	if objs.is_empty():
		return
	_push_undo()
	objs.pop_back()
	if objs.is_empty():
		_cells.erase(c)
	else:
		_cells[c] = objs
	_refresh_filter()
	_update_readouts()
	_canvas.queue_redraw()

func _close_context() -> void:
	if _ctx != null:
		_ctx.queue_free()
		_ctx = null
	_ctx_hover = -1

## Qud shows the menu at Input.mousePosition with the panel's top-left ON the cursor, and it
## acts on the FIRST object in the cell (DisplayContextInRegion takes one blueprint).
func _open_context(c: Vector2i, at: Vector2) -> void:
	_close_context()
	var objs: Array = _cells.get(c, [])
	if objs.is_empty():
		return                      # no object under the cursor, nothing to configure
	_ctx_cell = c
	_ctx_bp = _obj_name(objs[0])
	var panel := Control.new()
	panel.position = Vector2(at.x, at.y + 1.0)
	panel.size = Vector2(CTX_W, CTX_H)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.draw.connect(_draw_context)
	panel.gui_input.connect(_context_input)
	panel.mouse_exited.connect(func():
		_ctx_hover = -1
		if _ctx != null:
			_ctx.queue_redraw())
	_ctx = panel          # before add_child: the first draw can fire inside it
	add_child(panel)

func _draw_context() -> void:
	# scanlines: the parity follows SCREEN y, so the stripes stay put as the menu moves
	var top := int(_ctx.global_position.y)
	for y in range(CTX_H):
		var col := CTX_LINE_ODD if (top + y) % 2 == 1 else CTX_LINE_EVEN
		_ctx.draw_rect(Rect2(0, y, CTX_W, 1), col)
	if _ctx_hover >= 0:
		_ctx.draw_rect(Rect2(0, _ctx_hover * CTX_ROW_PITCH, CTX_W, CTX_ROW_PITCH), CTX_HILITE)
	var f: Font = load(FONT_MONO)
	for i in range(CTX_ITEMS.size()):
		var base := CTX_BASELINE + i * CTX_ROW_PITCH
		var text := str(CTX_ITEMS[i]["text"])
		for j in range(text.length()):
			_ctx.draw_string(f, Vector2(CTX_TEXT_X + j * CTX_ADVANCE, base), text.substr(j, 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, CTX_TEXT_PX, CTX_TEXT_COL)

func _context_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var i := int(e.position.y / CTX_ROW_PITCH)
		if i != _ctx_hover:
			_ctx_hover = clampi(i, -1, CTX_ITEMS.size() - 1)
			_ctx.queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var i := int(e.position.y / CTX_ROW_PITCH)
		if i >= 0 and i < CTX_ITEMS.size():
			var act := str(CTX_ITEMS[i]["act"])
			_close_context()
			_do(act)

## Every object in scope for a context action: Qud applies these ACROSS the selected region
## (MapFileRegion.FindCellsWithObjectBlueprint over SelectedRegion), falling back to the whole
## map when nothing is selected -- so a single edit can retag every instance at once.
func _ctx_targets() -> Array:
	var out: Array = []
	for k in _cells:
		var p: Vector2i = k
		if _has_region and not _region.has_point(p):
			continue
		for o in _cells[k]:
			if o is Dictionary and str(o.get("name", "")) == _ctx_bp:
				out.append(o)
	return out

func _ctx_first() -> Dictionary:
	var t := _ctx_targets()
	return t[0] if not t.is_empty() else {}

# the DialogManager popups -----------------------------------------------------
# Qud's modding tools use Unity's plain dialogs here rather than Qud's own console chrome, so
# these are sans-serif on flat grey -- reproduced from measurement, not styled to taste.

## Qud's modding dialogs use Unity's stock UI font -- sans, not the console mono this screen
## draws everything else in -- so these controls deliberately opt OUT of the screen's face.
## That face is LIBERATION SANS specifically, not "some sans": it ships embedded in the game's
## own sharedassets0.assets, which is where tools/capture/fonts.py carves it from. Falls back to
## the theme font when it has not been extracted on this machine.
var _sans_cached := false
var _sans: FontFile

func _dlg_face() -> Font:
	if not _sans_cached:
		_sans_cached = true
		var p := InputModel.support_dir().path_join("title").path_join("chrome") 			.path_join("LiberationSans-Regular.ttf")
		if FileAccess.file_exists(p):
			var f := FontFile.new()
			if f.load_dynamic_font(p) == OK:
				_sans = f
	return _sans if _sans != null else ThemeDB.fallback_font

func _dlg_sans(c: Control, px: int, ink: Color) -> void:
	c.add_theme_font_override("font", _dlg_face())
	c.add_theme_font_size_override("font_size", px)
	c.add_theme_color_override("font_color", ink)

func _dlg_box(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(4)
	return sb

func _close_modal() -> void:
	if _modal != null:
		_modal.queue_free()
		_modal = null

func _modal_root() -> Control:
	_close_modal()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, DLG_DIM)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	add_child(root)
	_modal = root
	return root

func _dlg_panel(root: Control, title: String, w: int, h: int) -> Control:
	var vw := get_viewport_rect().size.x
	var panel := ColorRect.new()
	panel.color = DLG_PANEL
	panel.position = Vector2(roundf((vw - w) * 0.5), roundf((1080.0 - h) * 0.5))
	panel.size = Vector2(w, h)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(panel)
	var l := Label.new()
	l.text = title
	_dlg_sans(l, DLG_TITLE_PX, DLG_TITLE_INK)
	l.size = Vector2(w, 20)
	l.position = Vector2(0, 12)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(l)
	return panel

func _dlg_field(panel: Control, y: int, text: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	_dlg_sans(e, DLG_TEXT_PX, DLG_INK)
	e.add_theme_color_override("font_selected_color", DLG_INK)
	e.add_theme_color_override("caret_color", DLG_INK)
	e.add_theme_stylebox_override("normal", _dlg_box(DLG_FIELD_BG))
	e.add_theme_stylebox_override("focus", _dlg_box(DLG_FIELD_BG))
	e.position = Vector2((panel.size.x - DLG_FIELD_W) * 0.5, y)
	e.size = Vector2(DLG_FIELD_W, DLG_FIELD_H)
	panel.add_child(e)
	return e

func _dlg_button(b: Button) -> void:
	_dlg_sans(b, DLG_TEXT_PX, DLG_INK)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, _dlg_box(DLG_BTN_BG))
	b.add_theme_color_override("font_hover_color", DLG_INK)
	b.add_theme_color_override("font_pressed_color", DLG_INK)
	b.add_theme_color_override("font_focus_color", DLG_INK)

func _dlg_buttons(panel: Control, y: int, ok_cb: Callable, with_cancel := true) -> void:
	var n := 2 if with_cancel else 1
	var total := DLG_BTN_W * n + (4 * (n - 1))
	var x := (panel.size.x - total) * 0.5
	var ok := Button.new()
	ok.text = "Ok"
	_dlg_button(ok)
	ok.position = Vector2(x, y)
	ok.size = Vector2(DLG_BTN_W, DLG_BTN_H)
	ok.pressed.connect(func():
		ok_cb.call()
		_close_modal())
	panel.add_child(ok)
	if not with_cancel:
		return
	var no := Button.new()
	no.text = "Cancel"
	_dlg_button(no)
	no.position = Vector2(x + DLG_BTN_W + 4, y)
	no.size = Vector2(DLG_BTN_W, DLG_BTN_H)
	no.pressed.connect(_close_modal)
	panel.add_child(no)

## DialogManager.getString -- panel 240x110, title +14, field +44, buttons +77 (measured)
func _dlg_string(title: String, initial: String, cb: Callable) -> void:
	var root := _modal_root()
	var panel := _dlg_panel(root, title, 240, 110)
	var f := _dlg_field(panel, 44, initial)
	_dlg_buttons(panel, 77, func(): cb.call(f.text))
	f.grab_focus()
	f.select_all()

## DialogManager.getPair -- panel 244x130, title +13, fields +44/+64, buttons +98 (measured)
func _dlg_pair(title: String, a: String, b: String, cb: Callable) -> void:
	var root := _modal_root()
	var panel := _dlg_panel(root, title, 244, 130)
	var fa := _dlg_field(panel, 44, a)
	var fb := _dlg_field(panel, 64, b)
	_dlg_buttons(panel, 98, func(): cb.call(fa.text, fb.text))
	fa.grab_focus()
	fa.select_all()

## DialogManager.info -- panel 224x92, message +14, a lone Ok at +59 (measured)
func _dlg_info(message: String) -> void:
	var root := _modal_root()
	var panel := _dlg_panel(root, message, 224, 92)
	_dlg_buttons(panel, 59, func(): pass, false)

## DialogManager.getChoice -- same family, sized to the option count
func _dlg_choice(title: String, options: Array, cb: Callable) -> void:
	var root := _modal_root()
	var h := 60 + options.size() * 22 + 30
	var panel := _dlg_panel(root, title, 260, h)
	for i in range(options.size()):
		var b := Button.new()
		b.text = str(options[i])
		_dlg_button(b)
		b.position = Vector2((panel.size.x - DLG_FIELD_W) * 0.5, 40 + i * 22)
		b.size = Vector2(DLG_FIELD_W, 20)
		var idx := i
		b.pressed.connect(func():
			cb.call(idx)
			_close_modal())
		panel.add_child(b)
	_dlg_buttons(panel, h - 30, func(): pass, false)

# the five context actions -----------------------------------------------------
# Prompts are verbatim from the IL: SetOwnerInRegion getString("New owner:"),
# SetPartForContext getString("New part:"), Add{,Int}PropertyForContext
# getPair("Define property name and value", "[Name]", "[Value]"/"1"), and
# RemovePropertyForContext getChoice("Choose a property to remove") / info("No properties defined.").

func _ctx_set_owner() -> void:
	var cur := str(_ctx_first().get("owner", ""))
	_dlg_string("New owner:", cur, func(v: String):
		_push_undo()
		for o in _ctx_targets():
			o["owner"] = v
		_canvas.queue_redraw())

func _ctx_set_part() -> void:
	var cur := str(_ctx_first().get("part", ""))
	_dlg_string("New part:", cur, func(v: String):
		_push_undo()
		for o in _ctx_targets():
			o["part"] = v
		_canvas.queue_redraw())

func _ctx_add_prop(as_int: bool) -> void:
	_dlg_pair("Define property name and value", "[Name]", "1" if as_int else "[Value]",
		func(n: String, v: String):
			if n == "" or n == "[Name]":
				return
			_push_undo()
			for o in _ctx_targets():
				var key := "iprops" if as_int else "props"
				var d: Dictionary = o.get(key, {})
				d[n] = v
				o[key] = d
			_canvas.queue_redraw())

## Qud gathers the properties of EVERY instance in scope and labels each choice with the set of
## values seen across them -- "Faction (Joppa, Grit Gate)" -- so a bulk remove shows what it hits.
func _ctx_remove_prop() -> void:
	var seen := {}
	for o in _ctx_targets():
		for key in ["props", "iprops"]:
			var d: Dictionary = o.get(key, {})
			for n in d:
				var vals: Array = seen.get(n, [])
				if not vals.has(str(d[n])):
					vals.append(str(d[n]))
				seen[n] = vals
	if seen.is_empty():
		_dlg_info("No properties defined.")
		return
	var names: Array = seen.keys()
	names.sort()
	var labels: Array = []
	for n in names:
		labels.append("%s (%s)" % [n, ", ".join(seen[n])])
	_dlg_choice("Choose a property to remove", labels, func(i: int):
		var victim := str(names[i])
		_push_undo()
		for o in _ctx_targets():
			for key in ["props", "iprops"]:
				var d: Dictionary = o.get(key, {})
				d.erase(victim)
				o[key] = d
		_canvas.queue_redraw())

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
	# painted cells — Qud's own tile art, recoloured from the blueprint's TileColor/DetailColor.
	# Falls back to the render glyph when the mask isn't on disk yet (the mod exports a few hundred
	# tiles by default; _want_tile asks for the rest one at a time as they're actually drawn).
	for k in _cells:
		var p: Vector2i = k
		var names: Array = _cells[k]
		if names.is_empty():
			continue
		var r := Rect2(Vector2(p.x * cs.x, p.y * cs.y), cs)
		var top := _obj_name(names[-1])
		var tex := _tile_for(top)
		if tex != null:
			# preserve the tile's aspect inside the cell, like Qud draws it
			var ts := tex.get_size()
			var scale: float = minf(cs.x / ts.x, cs.y / ts.y)
			var d := ts * scale
			_canvas.draw_texture_rect(tex, Rect2(r.position + (cs - d) * 0.5, d), false)
		else:
			var rec: Dictionary = _by_name.get(top, {})
			var glyph := _glyph_of(str(rec.get("render", "")))
			if glyph != "":
				# centred in the cell, in the console face — Qud draws its glyphs on the
				# cell grid, not hanging off a baseline in whatever font came to hand
				var gf: Font = load(FONT_MONO)
				var gsize := 18
				var gw := gf.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, gsize).x
				_canvas.draw_string(gf,
					r.position + Vector2((cs.x - gw) * 0.5, cs.y * 0.5 + gsize * 0.36),
					glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, gsize, _tiles.color_of(_main_code(top)))
			else:
				_canvas.draw_rect(r.grow(-2.0), Color(0.35, 0.75, 0.35, 0.45))
	if _has_region:
		var rr := Rect2(Vector2(_region.position.x * cs.x, _region.position.y * cs.y),
			Vector2(_region.size.x * cs.x, _region.size.y * cs.y))
		_canvas.draw_rect(rr, CURSOR, false, 2.0)
	if _hover.x >= 0:
		var hr := Rect2(Vector2(_hover.x * cs.x, _hover.y * cs.y), cs)
		_canvas.draw_rect(hr, CURSOR, false, 2.0)

## The recoloured tile for a blueprint, or null when its mask isn't exported yet (in which case
## we ask the mod for it exactly once and the next redraw picks it up).
func _tile_for(bp_name: String) -> Texture2D:
	var rec: Dictionary = _by_name.get(bp_name, {})
	var tile := str(rec.get("tile", ""))
	if tile == "":
		return null
	var tex: Texture2D = _tiles.texture(tile, _tiles.color_of(_main_code(bp_name)),
		_tiles.color_of(str(rec.get("detail", ""))))
	if tex == null:
		_want_tile(tile)
	return tex

## Qud's TileColor is a colour STRING ("&Y"); QudTiles.color_of wants the bare code.
func _main_code(bp_name: String) -> String:
	var rec: Dictionary = _by_name.get(bp_name, {})
	var c := str(rec.get("tilecolor", ""))
	if c == "":
		c = str(rec.get("colors", ""))
	c = c.replace("&", "")
	var caret := c.find("^")
	if caret >= 0:
		c = c.substr(0, caret)
	return c.substr(0, 1) if c.length() > 0 else "y"

## Ask the mod to export one tile (bridge `wanttile`). Bounded by _requested so a missing mask
## costs one request, not one per frame.
func _want_tile(tile: String) -> void:
	if tile == "" or _requested.has(tile):
		return
	_requested[tile] = true
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var payload := JSON.stringify({"type": "command", "name": "wanttile", "path": tile}).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF); frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF); frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## Qud's RenderString is EITHER a literal character ("~", "=", "@") OR a CP437 code point
## written as a DECIMAL STRING ("176" = light shade, "219" = full block, "247" = approx) —
## measured across blueprints.json, where 176/219/247 are among the most common values.
## Drawing the digits verbatim is what turned a wall-heavy map into "176767..." noise.
const CP437_HIGH := "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "

func _glyph_of(render: String) -> String:
	if render == "":
		return ""
	if not render.is_valid_int():
		return render.substr(0, 1)
	var code := render.to_int()
	if code >= 32 and code < 127:
		return char(code)
	if code >= 128 and code <= 255:
		return CP437_HIGH.substr(code - 128, 1)
	return ""

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
			# a ctrl+drag is held down as the RIGHT button on macOS (see _mac), so the
			# paint-along-the-drag mask has to accept either one
			var paint_mask: int = MOUSE_BUTTON_MASK_LEFT
			if _mac:
				paint_mask |= MOUSE_BUTTON_MASK_RIGHT
			if _dragging:
				_region = _rect_from(_drag_start, c)
				_has_region = true
			elif e.ctrl_pressed and e.button_mask & paint_mask:
				_paint(c)          # Qud paints continuously along a Ctrl+drag
			_update_readouts()
			_canvas.queue_redraw()
	elif e is InputEventMouseButton:
		var btn: int = e.button_index
		if _mac and btn == MOUSE_BUTTON_RIGHT and e.ctrl_pressed:
			btn = MOUSE_BUTTON_LEFT       # un-convert; see _mac
		if btn == MOUSE_BUTTON_RIGHT and e.pressed:
			# Qud's OnClick sends "RightTile:x,y", and OnCommand's handler pops the TOP object
			# off that cell (pushing a "Remove" undo action). Right-click erases, not menus.
			_erase_top(_cell_at(e.position))
		elif btn == MOUSE_BUTTON_MIDDLE and e.pressed:
			_open_context(_cell_at(e.position), e.position + CANVAS.position)
		elif btn == MOUSE_BUTTON_LEFT:
			var c := _cell_at(e.position)
			if e.pressed:
				if e.shift_pressed:                        # Qud: Shift+drag = region select
					_dragging = true
					_drag_start = c
					_region = _rect_from(c, c)
					_has_region = true
				elif e.ctrl_pressed:                       # Qud: Ctrl+drag = paint from palette
					_paint(c)
				elif e.alt_pressed:                        # Qud: Alt+click = sample to palette
					var objs: Array = _cells.get(c, [])
					if not objs.is_empty():
						_set_brush(_obj_name(objs[-1]))
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
	var objs: Array = _cells.get(c, [])
	objs.append({"name": _brush, "owner": "", "part": "", "props": {}, "iprops": {}})
	_cells[c] = objs

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
	# The VBox must fill the scroll's width or every row is 0px wide and nothing is
	# clickable — the brush stayed empty and painting silently no-opped.
	_palette_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_list.custom_minimum_size = Vector2(scroll.size.x, 0)
	scroll.add_child(_palette_list)

func _refresh_filter() -> void:
	var q := _filter_edit.text.strip_edges().to_lower() if _filter_edit != null else ""
	var used := {}
	for k in _cells:
		for o in _cells[k]:
			used[_obj_name(o)] = true
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
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		if _modal != null:
			_close_modal(); accept_event(); return
		if _ctx != null:
			_close_context(); accept_event(); return
	if TypingGuard.typing(get_viewport()) and not e.is_action_pressed("ui_cancel"):
		return
	if e is InputEventKey and e.pressed and e.ctrl_pressed:
		match e.keycode:
			KEY_N: _do("new"); accept_event(); return
			KEY_O: _do("load"); accept_event(); return
			KEY_S: _do("save"); accept_event(); return
			KEY_T: _do("test"); accept_event(); return
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

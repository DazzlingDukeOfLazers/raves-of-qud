extends Control

## THE BLUEPRINT BROWSER — a 1:1 mimic of Caves of Qud's Modding Toolkit › Blueprint Browser.
##
## Qud shows the ObjectBlueprints inheritance hierarchy as a collapsible tree on a black field:
## a "Filter…" box top-left, rows of [expander ▶] [cube icon] [blueprint name] indented by depth,
## and a large "Back" bottom-right. Measured off a 1:1 capture of Qud 1.0.5 (2026-08-06).
##
## The DATA is the player's own install — `blueprints.json`, exported by the bridge mod
## (BlueprintExporter reads GameObjectFactory.Factory.Blueprints, so a modded install shows its
## mods' blueprints too). Never bundled. Verified against Qud's own screen: the same 9 roots, and
## expanders on exactly the same nodes.
##
## Opened as an overlay from ModdingToolkitScreen (via MainMenu's open_tool); `closed` fires on Esc
## or Back. UiState scene: "blueprint_browser".

signal closed

var ui_scene := "blueprint_browser"

# palette — sampled off the reference capture
const BG := Color8(0x00, 0x00, 0x00)          # Qud draws this screen on pure black
const ROW := Color8(0xC8, 0xC8, 0xC8)         # blueprint name
const ROW_SEL := Color8(0xFF, 0xFF, 0xFF)
const SEL_BAR := Color(1, 1, 1, 0.10)
const EXPANDER := Color8(0xC8, 0xC8, 0xC8)
const ICON := Color8(0xB4, 0xB4, 0xB4)        # the little cube glyph
const BACK := Color8(0x8C, 0x8C, 0x8C)
const NOTE := Color8(0x6E, 0x8A, 0x86)        # our own count/status line

# geometry, measured at 1920x1080 (see the class comment)
const FILTER_RECT := Rect2(19, 12, 286, 26)
const LIST_TOP := 58
const ROW_H := 24
const INDENT := 16
const X_EXPANDER := 12
const X_ICON := 34
const X_NAME := 52
const BACK_POS := Vector2(1856, 1034)

## Filtering 5247 rows can match thousands; render a bounded page and SAY so (never a silent cap).
const MAX_ROWS := 400

var _by_name := {}          # name -> record
var _children := {}         # parent name -> [names]
var _roots: Array = []
var _expanded := {}         # name -> true
var _visible: Array = []    # [{name, depth, parent}] currently drawn
var _sel := 0
var _filter := ""
var _truncated := 0

var _list: VBoxContainer
var _scroll: ScrollContainer
var _filter_edit: LineEdit
var _note: Label

func _ready() -> void:
	name = "BlueprintBrowserScreen"
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
	_build_filter()
	_build_list()
	_build_back()
	_build_note()
	_rebuild_visible()

func _fit_to_viewport() -> void:
	# runtime overlay: the parent doesn't propagate size (the ModsScreen gotcha)
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── data ──────────────────────────────────────────────────────────────────────

func _load_blueprints() -> void:
	var path := InputModel.support_dir().path_join("blueprints.json")
	if not FileAccess.file_exists(path):
		return   # the note line reports the empty state
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary and data.get("blueprints", null) is Array):
		return
	for b in data["blueprints"]:
		if not (b is Dictionary):
			continue
		var n := str(b.get("name", ""))
		if n == "":
			continue
		_by_name[n] = b
		var inh := str(b.get("inherits", ""))
		if inh == "":
			_roots.append(n)
		else:
			if not _children.has(inh):
				_children[inh] = []
			_children[inh].append(n)
	_roots.sort()
	for k in _children:
		_children[k].sort()

# ── chrome ────────────────────────────────────────────────────────────────────

func _build_filter() -> void:
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Filter..."
	_filter_edit.position = FILTER_RECT.position
	_filter_edit.size = FILTER_RECT.size
	_filter_edit.add_theme_font_size_override("font_size", 14)
	# Qud's filter box is a plain light field on the black screen
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(0xF0, 0xF0, 0xF0)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	_filter_edit.add_theme_stylebox_override("normal", sb)
	_filter_edit.add_theme_stylebox_override("focus", sb)
	_filter_edit.add_theme_color_override("font_color", Color8(0x20, 0x20, 0x20))
	_filter_edit.add_theme_color_override("font_placeholder_color", Color8(0x80, 0x80, 0x80))
	_filter_edit.text_changed.connect(_on_filter_changed)
	add_child(_filter_edit)

func _build_list() -> void:
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(0, LIST_TOP)
	_scroll.size = Vector2(get_viewport_rect().size.x, get_viewport_rect().size.y - LIST_TOP - 60)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

func _build_back() -> void:
	var l := Label.new()
	l.text = "Back"
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", BACK)
	l.position = BACK_POS
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.mouse_entered.connect(func(): l.add_theme_color_override("font_color", ROW_SEL))
	l.mouse_exited.connect(func(): l.add_theme_color_override("font_color", BACK))
	l.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			closed.emit())
	add_child(l)

## Our own status line (Qud has none): the blueprint count, and — when a filter matches more rows
## than we render — exactly how many were left off. Never cap silently.
func _build_note() -> void:
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 13)
	_note.add_theme_color_override("font_color", NOTE)
	_note.position = Vector2(FILTER_RECT.position.x + FILTER_RECT.size.x + 16, FILTER_RECT.position.y + 5)
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_note)

# ── the tree ──────────────────────────────────────────────────────────────────

func _on_filter_changed(text: String) -> void:
	_filter = text.strip_edges().to_lower()
	_sel = 0
	_rebuild_visible()

## Flatten the tree into the rows to draw: with no filter, the expanded subtree from the roots;
## with a filter, every matching blueprint (flat, like Qud's own filtered view).
func _rebuild_visible() -> void:
	_visible.clear()
	_truncated = 0
	if _filter == "":
		for r in _roots:
			_walk(r, 0)
	else:
		var names: Array = _by_name.keys()
		names.sort()
		for n in names:
			if _filter in str(n).to_lower():
				if _visible.size() >= MAX_ROWS:
					_truncated += 1
					continue
				_visible.append({"name": n, "depth": 0})
	_populate()

func _walk(n: String, depth: int) -> void:
	if _visible.size() >= MAX_ROWS:
		_truncated += 1
		return
	_visible.append({"name": n, "depth": depth})
	if not _expanded.has(n):
		return
	for c in _children.get(n, []):
		_walk(c, depth + 1)

func _populate() -> void:
	for c in _list.get_children():
		c.queue_free()
	for i in range(_visible.size()):
		_list.add_child(_build_row(i))
	_update_note()
	_apply_selection()

func _update_note() -> void:
	if _by_name.is_empty():
		_note.text = "no blueprints.json — run the bridge export with Qud running"
		return
	var total: int = _by_name.size()
	if _truncated > 0:
		_note.text = "%d shown of %d matching (%d more not drawn) · %d blueprints" % [
			_visible.size(), _visible.size() + _truncated, _truncated, total]
	else:
		_note.text = "%d shown · %d blueprints" % [_visible.size(), total]

func _build_row(idx: int) -> Control:
	var rec: Dictionary = _visible[idx]
	var bp: Dictionary = _by_name.get(rec["name"], {})
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP

	var bar := ColorRect.new()
	bar.color = Color(0, 0, 0, 0)
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	var indent: int = int(rec["depth"]) * INDENT
	# expander — only for a blueprint that IS somebody's parent (Qud's own rule)
	if bool(bp.get("parent", false)) and _filter == "":
		var ex := Label.new()
		ex.text = "▼" if _expanded.has(rec["name"]) else "▶"
		ex.add_theme_font_size_override("font_size", 11)
		ex.add_theme_color_override("font_color", EXPANDER)
		ex.position = Vector2(X_EXPANDER + indent, 4)
		ex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ex)
	var ic := Label.new()
	ic.text = "▣"
	ic.add_theme_font_size_override("font_size", 13)
	ic.add_theme_color_override("font_color", ICON)
	ic.position = Vector2(X_ICON + indent, 2)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ic)
	var lbl := Label.new()
	lbl.text = str(rec["name"])
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", ROW)
	lbl.position = Vector2(X_NAME + indent, 2)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)

	row.mouse_entered.connect(func(): _select(idx))
	row.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(idx)
			_toggle())
	return row

func _select(idx: int) -> void:
	if idx < 0 or idx >= _visible.size():
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	var rows := _list.get_children()
	for i in range(rows.size()):
		var on: bool = (i == _sel)
		var r: Control = rows[i]
		if r.get_child_count() > 0 and r.get_child(0) is ColorRect:
			(r.get_child(0) as ColorRect).color = SEL_BAR if on else Color(0, 0, 0, 0)
		for c in r.get_children():
			if c is Label and c.text != "▶" and c.text != "▼" and c.text != "▣":
				c.add_theme_color_override("font_color", ROW_SEL if on else ROW)

## Expand/collapse the selected node (no-op for a leaf, and while filtering — the filtered view is
## flat, exactly like Qud's).
func _toggle() -> void:
	if _sel < 0 or _sel >= _visible.size() or _filter != "":
		return
	var n: String = str(_visible[_sel]["name"])
	if not bool(_by_name.get(n, {}).get("parent", false)):
		return
	if _expanded.has(n):
		_expanded.erase(n)
	else:
		_expanded[n] = true
	var keep := _sel
	_rebuild_visible()
	_sel = mini(keep, maxi(0, _visible.size() - 1))
	_apply_selection()

func _unhandled_input(e: InputEvent) -> void:
	# The filter field consumes its own keys in the GUI pass (this is _unhandled_input, so it is
	# guarded for free — see TypingGuard) but arrows/Esc still arrive; don't navigate while typing.
	if TypingGuard.typing(get_viewport()) and not e.is_action_pressed("ui_cancel"):
		return
	if e.is_action_pressed("ui_down"):
		_select(mini(_sel + 1, _visible.size() - 1))
		accept_event()
	elif e.is_action_pressed("ui_up"):
		_select(maxi(_sel - 1, 0))
		accept_event()
	elif e.is_action_pressed("ui_accept"):
		_toggle()
		accept_event()
	elif e.is_action_pressed("ui_cancel"):
		if _filter_edit != null and _filter_edit.has_focus():
			_filter_edit.release_focus()   # Esc leaves the field first, then the screen
		else:
			closed.emit()
		accept_event()

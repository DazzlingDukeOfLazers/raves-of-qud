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

# Geometry MEASURED off a 1920x1080 capture of Qud's own screen (pixel-diff pass, 2026-08-06):
# filter box x 18..305 / y 12..38; row glyph tops 62, 86, 110 … (pitch 24); on a row with an
# expander the clusters are expander x 8..17, icon x 27..43 (17x18), text x0 48; "Back" glyph
# bbox x 1832..1884 y 1026..1042. LIST_TOP is set so the FIRST GLYPH TOP lands on Qud's 62.
const FILTER_RECT := Rect2(18, 12, 288, 27)
const LIST_TOP := 56
const ROW_H := 24
## CALIBRATED against Qud, not guessed. Qud renders "BaseAnimatedObject" as 122 px of ink with a
## 9 px 'B' cap, which fixes the SIZE at 13 (14 px measured 130 px wide; 14 * 122/130 = 13.1, and
## the cap-height projection agrees at 12.9).
##
## The WEIGHT is Medium, and width alone could not tell us that -- width-per-cap puts Qud at 13.56
## between Regular's 13.39 and Medium's 13.89, which is inside the measurement noise. Ink DENSITY
## separates them cleanly: rendering the same string at a matched 9 px cap gives total ink 74805
## (Regular), 99652 (Medium), 123041 (Bold) against Qud's own 95458. Medium, comfortably.
const NAME_PX := 13
const NAME_WEIGHT := "Medium"
const INDENT := 16
const X_EXPANDER := 8
const X_ICON := 27
const X_NAME := 48
const ICON_SIZE := Vector2i(17, 18)
const BACK_POS := Vector2(1830, 1019)

## Filtering 5247 rows can match thousands; render a bounded page and SAY so (never a silent cap).
const MAX_ROWS := 400

var _by_name := {}          # name -> record
var _children := {}         # parent name -> [names]
var _roots: Array = []
var _expanded := {}         # name -> true
var _visible: Array = []    # [{name, depth, parent}] currently drawn
## Qud opens with NO row highlighted (measured) — selection appears on hover/arrow. -1 = none.
var _sel := -1
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
	# The visible box is its OWN Panel at the measured rect. A LineEdit floors its height at
	# font-height + margins (31px against Qud's 27) and no override shrinks it, so the field is
	# transparent and merely sits inside the panel — the drawn rect is then exactly what we
	# measured, independent of the theme's minimums.
	var box := Panel.new()
	box.position = FILTER_RECT.position
	box.size = FILTER_RECT.size
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(0xF0, 0xF0, 0xF0)
	sb.set_corner_radius_all(3)
	box.add_theme_stylebox_override("panel", sb)
	add_child(box)

	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Filter..."
	_filter_edit.flat = true
	var clear := StyleBoxEmpty.new()
	clear.content_margin_left = 6
	clear.content_margin_right = 6
	for st in ["normal", "focus", "read_only"]:
		_filter_edit.add_theme_stylebox_override(st, clear)
	_filter_edit.add_theme_font_size_override("font_size", 14)
	_filter_edit.add_theme_color_override("font_color", Color8(0x20, 0x20, 0x20))
	_filter_edit.add_theme_color_override("font_placeholder_color", Color8(0x80, 0x80, 0x80))
	# vertically centre the (taller) field on the drawn box
	var fh := 31.0
	_filter_edit.position = Vector2(FILTER_RECT.position.x,
		FILTER_RECT.position.y + (FILTER_RECT.size.y - fh) * 0.5)
	_filter_edit.size = Vector2(FILTER_RECT.size.x, fh)
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

## Our own status line — the blueprint count, and when a filter matches more rows than we render,
## exactly how many were left off (never cap silently). Qud has NO such line, so 1:1 mode omits it;
## user mode keeps it. Same gating discipline as every other Raves QoL addition.
func _build_note() -> void:
	if Settings.one_to_one():
		return
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
	if _note == null:
		return   # 1:1 mode: Qud shows no status line
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
		# 19px puts the triangle at Qud's measured 10px width (x 8..17); 11 gave 6, 15 gave 7.
		ex.add_theme_font_size_override("font_size", 19)
		ex.add_theme_color_override("font_color", EXPANDER)
		ex.position = Vector2(X_EXPANDER + indent, 4)
		ex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ex)
	var ic := TextureRect.new()
	ic.texture = _cube_icon()
	ic.position = Vector2(X_ICON + indent, (ROW_H - ICON_SIZE.y) / 2.0 + 3)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ic)
	var lbl := Label.new()
	lbl.text = str(rec["name"])
	_apply_ui_font(lbl, NAME_PX)
	lbl.add_theme_color_override("font_color", ROW)
	# y=4, not 2: with the real face in place the glyphs were landing 2 px high against Qud
	# (rows 3 and 4 measured 109..117 and 133..141 against Qud's 111..119 and 135..143 -- both
	# descender-free, so that is a clean baseline offset rather than a metrics mismatch).
	lbl.position = Vector2(X_NAME + indent, 4)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)

	row.mouse_entered.connect(func(): _select(idx))
	row.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(idx)
			_toggle())
	return row

## Qud's list font here is ElliotSans Medium (its modern-UI face), carved from the player's own
## install into title/chrome/ by tools/capture/fonts.py — the same asset MainMenu._elliot() uses
## for the title. It is CONDENSED: at a matched cap height Qud's rows measure ~6.5px/char against
## Atkinson's ~8.4 (measured), so the names run ~29% wider without it. This returns null when the
## font has not been extracted on this machine, and callers fall back to the theme font —
## correct-when-present rather than faking the width by shrinking, which would break the cap
## height that already matches.
var _ui_font_cached := false
var _ui_font: FontFile

func _ui_font_or_null() -> FontFile:
	if _ui_font_cached:
		return _ui_font
	_ui_font_cached = true
	var path := InputModel.support_dir().path_join("title").path_join("chrome") 		.path_join("ElliotSans-%s.ttf" % NAME_WEIGHT)
	if FileAccess.file_exists(path):
		var f := FontFile.new()
		if f.load_dynamic_font(path) == OK:
			_ui_font = f
	return _ui_font

func _apply_ui_font(l: Label, px: int) -> void:
	var f := _ui_font_or_null()
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", px)

## Qud's row icon is a 17x18 isometric CUBE OUTLINE, not a glyph — a text "▣" measured 9px wide
## against its 17 and read as a different shape. Drawn once and shared by every row: a hexagon
## silhouette plus the three edges meeting at the front-top vertex.
var _cube: ImageTexture

func _cube_icon() -> ImageTexture:
	if _cube != null:
		return _cube
	var w := ICON_SIZE.x
	var h := ICON_SIZE.y
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := (w - 1) / 2.0
	var top := Vector2(cx, 0.0)
	var upper_l := Vector2(0.0, h * 0.25)
	var upper_r := Vector2(w - 1, h * 0.25)
	var lower_l := Vector2(0.0, h * 0.75)
	var lower_r := Vector2(w - 1, h * 0.75)
	var bottom := Vector2(cx, h - 1)
	var mid := Vector2(cx, h * 0.5)      # the front vertex where the three visible edges meet
	for e in [[top, upper_l], [top, upper_r], [upper_l, lower_l], [upper_r, lower_r],
			[lower_l, bottom], [lower_r, bottom],           # hexagon silhouette
			[upper_l, mid], [upper_r, mid], [top, mid]]:    # the three inner edges
		_line(img, e[0], e[1], ICON)
	_cube = ImageTexture.create_from_image(img)
	return _cube

func _line(img: Image, a: Vector2, b: Vector2, col: Color) -> void:
	var steps := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	for i in range(steps + 1):
		var p := a.lerp(b, float(i) / float(steps))
		var x := int(round(p.x))
		var y := int(round(p.y))
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, col)

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
	# The filter field consumes its own keys in the GUI pass, but that is NOT the same as being
	# guarded — this comment used to claim `_unhandled_input` was "guarded for free", which is the
	# half-truth TypingGuard's own note was written to correct: a field consumes the keys it has a
	# USE for and everything else falls straight through. Hence the explicit check.
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

extends PanelContainer

## Command bar — row 5. The player's activated abilities (the mod's `abilities` block, in Qud's bar
## order): each shows its icon + name + [state] + <hotkey>, and the name is clickable to activate it
## (sends the ability's command over the bridge, like fire/reload). Horizontal, wraps if needed.

signal command_requested(payload: Dictionary)   # {type:"command", command:"..."} — MainFrame forwards it

# Abilities whose command opens a Qud direction prompt (PickDirection). Clicking these shows Raves'
# direction picker. Only gate KNOWN ones — activating a direction ability BLOCKS Qud until answered,
# so we must not show/cancel the picker for abilities that don't actually prompt. Extend as found.
const DIR_ABILITIES := ["CommandSurvivalCamp"]   # Make Camp

const DIM := "#8a8f9a"
const KEY := "#ffd200"       # hotkey — UI yellow
const ON := "#59d38a"        # toggled-on green
const OFF := "#8a8f9a"       # toggled-off / dim
const CD := "#e08a4a"        # cooling-down amber

# 1:1 (measured off Qud's command bar): the ability icon is ~40px tall, the name text is a muted teal
# and the <N> quick-slot number a light grey; a green frame boxes each ability cell.
## The BOX we give the ability icon. Its rendered INK came out 34 tall against Qud's 40 -- the
## sprite is fitted into the box with KEEP_ASPECT_CENTERED and the box's own aspect, not the
## nominal size, decides the scale. 47 lands the ink at 38 against Qud's 40 and is the LIMIT: at 50
## the box turns wide enough that the sprite fits by WIDTH instead of height, and a wide icon like
## Make Camp collapses from 45 to 25 across (bar mean 10.06 -> 16.90). Measured, not derived.
const ICON_PX_1TO1 := 47
const NAME_1TO1 := "#609caa"       # ability name — measured Color8(96,156,170)
const NUM_1TO1 := "#929393"        # <N> action number — measured Color8(146,147,147)
var CELL_FRAME_1TO1 := QudChrome.q8(11, 148, 71)   # green selection box (Qud draws it on the first/selected cell)
var CELL_FILL_1TO1 := QudChrome.q8(21, 23, 23)     # ...and the fill inside it

# 1:1 PAGINATION (measured off Qud with 10+ abilities on sync-raves-and-qud): Qud packs
# content-sized cells left-to-right and moves what doesn't fit onto further pages — the
# left gutter becomes "ABILITIES / page N of M" with a green up/down stepper showing the
# page number, and Ctrl+Tab / Ctrl+Shift+Tab flip pages. With one page, surplus width is
# shared between the cells (plain HBox expand — the meta 4-ability spread).
const GUTTER_W_1TO1 := 180                       # first cell's green frame starts x180
const ABIL_CYAN := Color8(41, 130, 181)          # ABILITIES / page N of M text
const PAGE_NUM := Color8(141, 124, 84)           # the stepper's page digit
const PAGE_ARROW := Color8(11, 148, 71)          # stepper arrows — Qud's selection green

var _tiles: RefCounted       # shared tile recolouring for ability icons (set in _ready)
var _rt: RichTextLabel       # user (QoL) layout: all abilities inline, left-packed
var _cells: HBoxContainer    # 1:1 layout: one equal-width cell per ability, spread across the bar (Qud)
var _row: HBoxContainer      # the bar's own row: gutter + cells. Its lead-in is what set the cells' x.
var _cellwrap: ScrollContainer   # clips the cells: their min width must NOT inflate the chrome row
var _abilities_btn: Button   # far-left: opens Qud's Abilities menu (the 'a' command)
var _palette := {}
var _ability_tex := {}       # command -> recoloured icon texture, for the direction picker cursor
var _last_data := {}         # last snapshot, so a mode toggle re-renders without waiting for a new one
var _one_to_one := false     # 1:1: spread abilities in equal cells (Qud) vs the inline QoL list
var _abilities: Array = []   # current abilities in bar order, for the 1-9 hotkeys (1:1)
var _page := 0               # current 1:1 bar page
var _pages: Array = []       # per-page arrays of indices into _abilities
var _gutter: Control         # 1:1 left gutter: ABILITIES / page N of M / stepper
var _gutter_title: Label
var _gutter_page: Label
var _gutter_box: VBoxContainer   # the ABILITIES/page stack — pushed below the keycap hints when paged

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudPalette.CHROME
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	_row = h
	add_child(h)

	# Far-left: the Abilities menu (Qud's 'a' = CmdAbilities), sent over the bridge like any command.
	_abilities_btn = Button.new()
	_abilities_btn.text = "Ⓐ Abilities"
	_abilities_btn.focus_mode = Control.FOCUS_NONE
	_abilities_btn.tooltip_text = "Open the Abilities menu (a)"
	_abilities_btn.pressed.connect(func() -> void:
		command_requested.emit({"type": "command", "command": "CmdAbilities"}))
	h.add_child(_abilities_btn)

	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true
	_rt.fit_content = true
	_rt.scroll_active = false
	# NOT focusable and NOT selectable: an ability [url] click must NOT grab keyboard focus, or the
	# focused label swallows the movement arrows (Godot uses them for UI focus nav) — that was the
	# "can't move after Make Camp" bug. meta_clicked still fires on FOCUS_NONE. (Same rule as the buttons.)
	_rt.focus_mode = Control.FOCUS_NONE
	_rt.selection_enabled = false
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rt.meta_clicked.connect(_on_meta)      # ability names are clickable [url] links
	h.add_child(_rt)

	# 1:1 layout: equal-width cells spread across the bar (hidden until 1:1). Populated per snapshot.
	# The cells live inside a scrollbar-less ScrollContainer so their combined MINIMUM width never
	# propagates to the row: with enough abilities (9 on sync-raves-and-qud) a bare HBox min
	# (~2600px) inflates the whole chrome VBox past the window and every trailing element — the
	# side column with the message log included — silently walks off the right edge.
	# 1:1 left gutter (replaces the QoL button): Qud's cyan ABILITIES label + the page
	# line and green stepper when the bar paginates. Click = open the Abilities menu
	# (same function as the button); the stepper arrows flip pages.
	_gutter = Control.new()
	_gutter.custom_minimum_size = Vector2(GUTTER_W_1TO1, 0)
	_gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gutter.visible = false
	_gutter.mouse_filter = Control.MOUSE_FILTER_STOP
	_gutter.tooltip_text = "Open the Abilities menu (a)"
	_gutter.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			if _pages.size() > 1 and e.position.x > GUTTER_W_1TO1 - 26:
				_flip_page(-1 if e.position.y < _gutter.size.y * 0.5 else 1)
			else:
				command_requested.emit({"type": "command", "command": "CmdAbilities"}))
	_gutter.draw.connect(_draw_gutter)
	var gv := VBoxContainer.new()
	_gutter_box = gv
	gv.set_anchors_preset(Control.PRESET_FULL_RECT)
	gv.alignment = BoxContainer.ALIGNMENT_CENTER
	gv.add_theme_constant_override("separation", 0)
	gv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gutter.add_child(gv)
	_gutter_title = Label.new()
	_gutter_title.text = "ABILITIES"
	_gutter_title.add_theme_color_override("font_color", ABIL_CYAN)
	_gutter_title.add_theme_font_size_override("font_size", 16)
	_gutter_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gutter_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gv.add_child(_gutter_title)
	_gutter_page = Label.new()
	_gutter_page.add_theme_color_override("font_color", ABIL_CYAN)
	_gutter_page.add_theme_font_size_override("font_size", 16)
	_gutter_page.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gutter_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gutter_page.visible = false
	gv.add_child(_gutter_page)
	h.add_child(_gutter)

	_cellwrap = ScrollContainer.new()
	_cellwrap.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_cellwrap.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_cellwrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cellwrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cellwrap.visible = false
	h.add_child(_cellwrap)
	_cells = HBoxContainer.new()
	_cells.add_theme_constant_override("separation", 0)   # dividers come from VSeparators between cells
	_cells.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cells.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cellwrap.add_child(_cells)

## MainFrame calls this each snapshot with the full data (needs abilities + palette + tilesDir).
func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.palette = _palette
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_ability_tex.clear()
	_abilities = data.get("abilities", [])   # keep for the 1-9 hotkeys
	if _one_to_one:
		_render_cells(_abilities)
	else:
		_render_inline(_abilities)

## 1:1 (parity) mode: spread abilities in equal-width bordered cells across the bar, like Qud (vs the
## QoL inline list). Master switch is MainFrame/Holodeck; here we swap the layout + re-render.
func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	_rt.visible = not on
	_cellwrap.visible = on
	_abilities_btn.visible = not on   # 1:1 uses Qud's ABILITIES gutter instead
	_gutter.visible = on
	# Qud's ability bar is exactly 58px tall at 1920x1080 (measured; icons 40px within) — pin it so
	# the play hole's bottom edge lands where Qud's does. User mode sizes to content as before.
	# 62, measured off Qud's own ability CELL (x180..367, y1018..1079) rather than off the bar's
	# apparent edge -- the earlier 58/54 reading was short, which left our cells 44 tall against
	# Qud's 62. Qud's bottom 90 is row3 990..1017 flush against the bar 1018..1079.
	custom_minimum_size = Vector2(0, 62) if on else Vector2(0, 0)
	# drop the rounded QoL box in 1:1 — the continuous bottom-strip chrome + the VSeparator dividers ARE
	# Qud's look; the framed box floated on the playfield. Restore it in user mode.
	var cur := get_theme_stylebox("panel")
	if cur is StyleBoxFlat:
		var f: StyleBoxFlat = (cur as StyleBoxFlat).duplicate()
		if on:
			f.bg_color = Color(0, 0, 0, 0)
			f.set_border_width_all(0)
			f.set_corner_radius_all(0)
			# ...and no vertical inset. The stylebox's 5px content margins are LAYOUT, not just
			# decoration: they survived the transparent 1:1 box and kept the cells 10px shorter than
			# the bar, so pinning the bar to Qud's 62 still left 52-tall cells against Qud's 62.
			f.content_margin_top = 0
			f.content_margin_bottom = 0
			# ...and no lead-in on the left. GUTTER_W_1TO1 is already Qud's 180, but the bar's own
			# 8px margin plus the row's 10px separation sat in front of it, so the first cell began
			# at exactly 198 -- 18 short of Qud's 180 by construction, not by accident.
			f.content_margin_left = 0
			f.content_margin_right = 0
		if _row != null:
			_row.add_theme_constant_override("separation", 0 if on else 10)
		else:
			f.bg_color = QudPalette.CHROME
			f.set_border_width_all(1)
			f.border_color = Color(1, 1, 1, 0.12)
			f.set_corner_radius_all(3)
			f.content_margin_top = 5
			f.content_margin_bottom = 5
		add_theme_stylebox_override("panel", f)
	if not _last_data.is_empty():
		set_snapshot(_last_data)

## USER (QoL): all abilities inline in one label, left-packed, names clickable.
func _render_inline(abilities: Array) -> void:
	_rt.clear()
	if abilities.is_empty():
		_rt.append_text("[color=%s]No abilities[/color]" % DIM)
		return
	var img_h := int(UiFont.px(get_viewport(), "body") * 3.0)   # 2x the previous size, per request
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	for a in abilities:
		var tex: Texture2D = _tiles.texture_for(a, true)   # abilities have no perceived variant
		var cmd := String(a.get("command", ""))
		if cmd != "":
			_ability_tex[cmd] = tex        # remember the icon for the direction-picker cursor
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(String(a.get("glyph", "")).replace("[", "[lb]"))
		var name_bb := QudText.to_bbcode(String(a.get("name", "")), _palette)
		_rt.append_text(" [url=cmd:%s]%s[/url]%s%s     " % [cmd, name_bb, _state_tag(a), _hotkey_tag(a)])

## 1:1 (Qud): one equal-width cell per ability, spread across the whole bar with dividers between.
func _render_cells(abilities: Array) -> void:
	for c in _cells.get_children():
		c.queue_free()
	if abilities.is_empty():
		_pages = []
		_update_gutter()
		var empty := Label.new()
		empty.text = "No abilities"
		empty.add_theme_color_override("font_color", Color.html(DIM))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cells.add_child(empty)
		return
	var icon_px := ICON_PX_1TO1   # match Qud's ~40px ability icon (Sprint / Make Camp / etc.)
	_pages = _paginate(abilities)
	_page = clampi(_page, 0, _pages.size() - 1)
	_update_gutter()
	var page: Array = _pages[_page]
	for j in page.size():
		var i: int = page[j]
		if j > 0:
			_cells.add_child(VSeparator.new())   # divider between cells, like Qud
		# Qud frames the selected quick-slot with a green box; default selection is the first ability.
		# Slots restart per page — the 1-9 keys always activate the VISIBLE cells.
		_cells.add_child(_make_cell(abilities[i], icon_px, j + 1, j == 0))

## Greedy page fit, like Qud: pack content-sized cells until the next one would not fit
## in the bar (window minus the gutter), then start a new page. Cell width is estimated
## from the same font/icon/margins _make_cell lays out.
func _paginate(abilities: Array) -> Array:
	var avail := (size.x if size.x > 100.0 else 1920.0) - GUTTER_W_1TO1 - 26.0
	var f := get_theme_font("normal_font", "RichTextLabel")
	if f == null:
		f = get_theme_font("font", "Label")
	var fsize := 14   # the cell labels pin 14px (measured off Qud's bar) — estimate with the same
	var pages: Array = []
	var cur: Array = []
	var used := 0.0
	for i in abilities.size():
		var a: Dictionary = abilities[i]
		var txt := "%s%s%s" % [QudText.strip(String(a.get("name", ""))),
			_state_plain(a), _hotkey_label(a, (cur.size() + 1))]
		var wmin := 8.0 + round(ICON_PX_1TO1 * 16.0 / 24.0) + 6.0 \
			+ f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var need := wmin + (10.0 if cur.size() > 0 else 0.0)   # divider + separation
		if cur.size() > 0 and used + need > avail:
			pages.append(cur)
			cur = []
			used = 0.0
			need = wmin
		cur.append(i)
		used += need
	if not cur.is_empty():
		pages.append(cur)
	return pages

# The gutter's paged-mode extras, all measured off Qud: the Ctrl+Tab / Ctrl+Shift+Tab
# keycap hints along the top (gold ~(182,164,5), 17x11 keycaps with micro-labels), and
# the green up/down stepper with the page digit right of the text block.
const HINT_GOLD := Color8(182, 164, 5)
const HINT_GOLD_DIM := Color8(125, 114, 9)

func _draw_gutter() -> void:
	if _pages.size() <= 1:
		return
	var f := get_theme_font("font", "Label")
	# keycap hints row at the very top: [Ctrl]+Tab   [Ctrl]+[Shift]+Tab
	var hy := 2.0
	var x := 64.0
	x = _draw_keycap(f, x, hy, 17.0, "Ctrl")
	x = _draw_plus(f, x, hy)
	x = _draw_hint_text(f, x, hy, "Tab")
	x += 7.0
	x = _draw_keycap(f, x, hy, 17.0, "Ctrl")
	x = _draw_plus(f, x, hy)
	x = _draw_keycap(f, x, hy, 18.0, "Shift")
	x = _draw_plus(f, x, hy)
	_draw_hint_text(f, x, hy, "Tab")
	# green up/down stepper + the page digit
	var cx := GUTTER_W_1TO1 - 14.0
	var cy := _gutter.size.y * 0.5
	_gutter.draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 7, cy - 10), Vector2(cx + 7, cy - 10), Vector2(cx, cy - 18)]), PAGE_ARROW)
	_gutter.draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 7, cy + 10), Vector2(cx + 7, cy + 10), Vector2(cx, cy + 18)]), PAGE_ARROW)
	_gutter.draw_string(f, Vector2(cx - 5, cy + 6), str(_page + 1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, PAGE_NUM)

## One bordered keycap with a tiny centred label; returns the x after it.
func _draw_keycap(f: Font, x: float, y: float, w: float, label: String) -> float:
	_gutter.draw_rect(Rect2(x, y, w, 11), HINT_GOLD, false, 1.0)
	var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x
	_gutter.draw_string(f, Vector2(x + (w - tw) * 0.5, y + 7), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 6, HINT_GOLD_DIM)
	return x + w

func _draw_plus(f: Font, x: float, y: float) -> float:
	_gutter.draw_string(f, Vector2(x + 1, y + 7), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, HINT_GOLD_DIM)
	return x + 7.0

func _draw_hint_text(f: Font, x: float, y: float, txt: String) -> float:
	_gutter.draw_string(f, Vector2(x, y + 8), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, HINT_GOLD)
	return x + f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x

func _flip_page(dir: int) -> void:
	if _pages.size() <= 1:
		return
	_page = wrapi(_page + dir, 0, _pages.size())
	_render_cells(_abilities)

func _update_gutter() -> void:
	if _gutter_page == null:
		return
	_gutter_page.visible = _pages.size() > 1
	if _pages.size() > 1:
		_gutter_page.text = "page %d of %d" % [_page + 1, _pages.size()]
	if _gutter_box != null:
		_gutter_box.offset_top = 13.0 if _pages.size() > 1 else 0.0   # room for the keycap hints
	_gutter.queue_redraw()

## One ability as a centred, equal-share, clickable cell: a nearest-filtered tile icon + a name/state/
## hotkey label, both centred. The cell (an HBox) catches the click via gui_input; children IGNORE the
## mouse so it falls through. Nothing here takes keyboard focus, so the movement arrows are never
## swallowed (the "can't move after Make Camp" bug).
func _make_cell(a: Dictionary, icon_px: int, slot: int, selected: bool) -> Control:
	var cmd := String(a.get("command", ""))
	var tex: Texture2D = _tiles.texture_for(a, true)
	if cmd != "":
		_ability_tex[cmd] = tex
	# The click target + optional green selection frame is the outer PanelContainer; children ignore the
	# mouse so the click falls through to it, and nothing here grabs keyboard focus (movement-arrow bug).
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # equal share of the bar width
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var fs := StyleBoxFlat.new()
	# The SELECTED cell is filled, not just framed: Qud paints (21,23,23) inside the green box
	# (measured x181..366, y1019..1078 -- the whole cell), a touch lighter than the bottom strip it
	# sits on. We drew the frame and left the interior showing the strip, so the box read as an
	# outline on the same ground instead of a lit cell.
	fs.bg_color = CELL_FILL_1TO1 if selected else Color(0, 0, 0, 0)
	fs.set_corner_radius_all(0)                              # Qud's box is a sharp rectangle
	fs.set_border_width_all(1 if selected else 0)
	fs.border_color = CELL_FRAME_1TO1
	# 10, not 4: with the lead-in gone the first cell started on Qud's x180 but ran to 355 against
	# its 367 -- 12 narrow, i.e. 6 a side. The cells size to their content in both apps, so the
	# difference is the padding around it.
	fs.content_margin_left = 8
	fs.content_margin_right = 8
	frame.add_theme_stylebox_override("panel", fs)
	frame.tooltip_text = QudText.strip(String(a.get("name", "")))
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	frame.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_activate(cmd))
	var cell := HBoxContainer.new()
	# CENTRED, from Qud's own model: AbilityBarButton pads 5 and holds a WorkableArea whose layout is
	# MiddleCenter with spacing 10. The button being UpperLeft misled an earlier attempt into
	# left-aligning the CONTENT; it is the WorkableArea that positions it, and that centres.
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Qud leaves 17px between the icon's ink and the text where this leaves 11 (6 of separation plus
	# the transparent margin inside the icon box). MATCHING IT ALONE MAKES THINGS WORSE: the cell
	# centres its content, so the extra 6 is split between the two sides -- the text gained 3 toward
	# Qud's column and the icons lost 3, and the bar scored 10.06 -> 10.49. Qud is not centring the
	# same content; closing this needs its actual layout, not a wider gap.
	# 6, and NOT Qud's 10, deliberately. Qud's own model for a cell (read off AbilityBarButton with
	# the probe) is:
	#
	#     AbilityBarButton  w=159.36  padL=5, UpperLeft
	#       Spacer          w=1                     <- the 1px divider between cells
	#       WorkableArea    w=154.36  spacing 10, MiddleCenter
	#         TopHalf       32 x 48                 <- the icon element
	#         Ability Text  100.81 x 25
	#
	# Copying the 10 makes the bar WORSE (mean 10.06 -> 14.78), and so does copying padL=5 with
	# UpperLeft (-> 15.07), because our cell's ELEMENTS are not Qud's: the spacing only lands right
	# once the icon element is exactly 32 wide and the text element exactly 100.81. Until the cell is
	# rebuilt to that structure, these numbers are a set -- 6 with our widths puts the boundaries on
	# Qud's columns, which is what the eye reads.
	cell.add_theme_constant_override("separation", 6)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(cell)
	if tex != null:
		var ir := TextureRect.new()
		ir.texture = tex
		ir.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel-art, no blur
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.custom_minimum_size = Vector2(round(icon_px * 16.0 / 24.0), icon_px)
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE   # click falls through to the cell
		cell.add_child(ir)
	# Name in Qud's muted teal, state + <N> quick-slot in light grey (measured off the command bar).
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.selection_enabled = false
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.focus_mode = Control.FOCUS_NONE
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl.add_theme_font_size_override("normal_font_size", 14)   # Qud's bar text measures ~14px (advance ~8.4/char)
	lbl.text = "[color=%s]%s[/color][color=%s]%s%s[/color]" % [
		NAME_1TO1, QudText.strip(String(a.get("name", ""))),
		NUM_1TO1, _state_plain(a), _hotkey_label(a, slot)]
	cell.add_child(lbl)
	return frame

## The cell's hotkey tag: the mod's own hotkey if it sends one, else the positional bar slot (1-9),
## which is what the 1-9 keys activate in 1:1. Matches Qud's " <1>".. quick-slot labels.
func _hotkey_label(a: Dictionary, slot: int) -> String:
	var hk := String(a.get("hotkey", ""))
	if hk == "" and slot >= 1 and slot <= 9:
		hk = str(slot)
	return " <%s>" % hk if hk != "" else ""

## Cooldown in TURNS as Qud displays it. The mod sends the raw ActivatedAbilityEntry.Cooldown, which is
## 10x the shown turns (Qud renders `Cooldown / 10` — e.g. 950 -> 95). 0 = not cooling.
func _cooldown_turns(a: Dictionary) -> int:
	var cd := int(a.get("cooldown", 0))
	return maxi(1, int(cd / 10.0)) if cd > 0 else 0   # never show "cd 0" while still cooling

## Plain-text state suffixes for the cell label. Cooldown first, then toggle/disabled — matching Qud's
## "[95] [off]" (a toggleable ability can be BOTH cooling down AND toggled off, so show both).
func _state_plain(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += " [cd %d]" % cd
	if bool(a.get("toggleable", false)):
		s += " [on]" if bool(a.get("toggle", false)) else " [off]"
	elif not bool(a.get("enabled", true)):
		s += " [disabled]"
	return s

func _hotkey_plain(a: Dictionary) -> String:
	var hk := String(a.get("hotkey", ""))
	return " <%s>" % hk if hk != "" else ""

## Shared activate path for a cell click (mirrors _on_meta): send the command + direction-picker hint.
func _activate(cmd: String) -> void:
	if cmd == "":
		return
	command_requested.emit({
		"type": "command", "command": cmd,
		"icon": _ability_tex.get(cmd),
		"pick_dir": DIR_ABILITIES.has(cmd),
	})

## 1:1 ability hotkeys: the 1-9 keys activate the matching bar slot. Only in 1:1 (where the camera-mode
## 1-7 bindings are locked out, so the digits are free); user mode leaves them to the camera. Runs in
## _unhandled_key_input, which fires BEFORE Main's _unhandled_input, so a handled digit never reaches
## the (locked) camera switch. Nothing here grabs focus.
func _unhandled_key_input(e: InputEvent) -> void:
	if not _one_to_one or _abilities.is_empty():
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	# Ctrl+Tab / Ctrl+Shift+Tab flip bar pages (Qud's own binding, shown in its gutter)
	if e.keycode == KEY_TAB and e.ctrl_pressed and _pages.size() > 1:
		_flip_page(-1 if e.shift_pressed else 1)
		get_viewport().set_input_as_handled()
		return
	var slot := -1
	if e.keycode >= KEY_1 and e.keycode <= KEY_9:
		slot = e.keycode - KEY_1                       # top-row digits
	elif e.keycode >= KEY_KP_1 and e.keycode <= KEY_KP_9:
		slot = e.keycode - KEY_KP_1                    # numpad digits
	if slot < 0:
		return
	# the digits act on the VISIBLE page's cells (slots restart per page, like Qud)
	var page: Array = _pages[_page] if _page < _pages.size() else []
	if slot >= page.size():
		return
	_activate(String(_abilities[page[slot]].get("command", "")))
	get_viewport().set_input_as_handled()

func _state_tag(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += " [color=%s][cd %d][/color]" % [CD, cd]
	if bool(a.get("toggleable", false)):
		var on := bool(a.get("toggle", false))
		s += " [color=%s][%s][/color]" % [ON if on else OFF, "on" if on else "off"]
	elif not bool(a.get("enabled", true)):
		s += " [color=%s][disabled][/color]" % DIM
	return s

func _hotkey_tag(a: Dictionary) -> String:
	var hk := String(a.get("hotkey", ""))
	return " [color=%s]<%s>[/color]" % [KEY, hk] if hk != "" else ""

func _on_meta(meta: Variant) -> void:
	var s := String(meta)
	if s.begins_with("cmd:"):
		var c := s.substr(4)
		if c != "":
			command_requested.emit({
				"type": "command", "command": c,
				"icon": _ability_tex.get(c),           # cursor for the direction picker
				"pick_dir": DIR_ABILITIES.has(c),      # only known direction abilities open the picker
			})

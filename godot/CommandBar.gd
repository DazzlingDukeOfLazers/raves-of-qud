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

# STATE TAGS, sampled off Qud's own ability bar (Sprint driven through off / on / cooling over
# the bridge, glyph cores read per pixel column). The arguments are Qud's SCREEN values, wrapped
# in q8 — which pre-compensates RAVES' canvas shader so a value survives it intact (drawing
# q8(148)=158 measured back as 148 on screen). Do NOT feed q8 a Qud PALETTE source: that
# double-counts a curve Qud has already applied — the palette's `g` is (0,148,3), but what Qud
# actually puts on the glass is (3,123,6), and the glass is what we are matching.
#
# The lift matters most where it is least obvious. Drawn raw, the near-black brackets came back
# DIMMER than Qud's (they fell out of a sum>115 pixel scan entirely) while the bright grey word
# matched fine — Raves' shader compresses the dark end hardest, which is the end q8 lifts.
#
# Peaks vary ±8% between captures of the identical tag (glyph AA lands differently by subpixel
# position), so treat anything inside that as matched and don't chase it.
#
#   [off]   dark brackets + grey word    [on]   dark brackets + green word    [81]   all cyan
#
# Two things the old single-tone constants could not say:
#  1. Qud colours the BRACKETS separately from the body — the same near-black green either way —
#     which is exactly what Daniel reported ("the brackets look dark green and 'on' is closer to
#     the rectangle selecting Sprint").
#  2. `on` is a SATURATED green, not a mint. The old #59d38a carried a lot of blue; Qud's green
#     measures blue = SIX, which rules out the mint and the palette's bright `G` alike.
var TAG_BRK := QudChrome.q8(21, 56, 56)     # both brackets, both states
var TAG_ON := QudChrome.q8(3, 123, 6)
var TAG_OFF := QudChrome.q8(160, 187, 180)
## Cooling down. NOT a distinct light blue: Qud draws `[81]` — brackets included — in the SAME
## cyan as the ability's name (measured in one frame, (95,159,173) against the "Sprint" glyphs'
## (96,161,176)). The old #6cb7c8 was a lone brighter blue. This was the open colour question in
## docs/next-session.md; binding CD to the name keeps Qud's relationship true by construction.
var CD := Color.html(NAME_1TO1)

# 1:1 (measured off Qud's command bar): the ability icon is ~40px tall, the name text is a muted teal
# and the <N> quick-slot number a light grey; a green frame boxes each ability cell.
## The BOX we give the ability icon. Its rendered INK came out 34 tall against Qud's 40 -- the
## sprite is fitted into the box with KEEP_ASPECT_CENTERED and the box's own aspect, not the
## nominal size, decides the scale. 47 lands the ink at 38 against Qud's 40 and is the LIMIT: at 50
## the box turns wide enough that the sprite fits by WIDTH instead of height, and a wide icon like
## Make Camp collapses from 45 to 25 across (bar mean 10.06 -> 16.90). Measured, not derived.
const ICON_PX_1TO1 := 47
const NAME_1TO1 := "#609caa"       # ability name — measured Color8(96,156,170)
## The <N> quick slot is TWO colours, not one: Qud draws the CHEVRONS bright grey and the DIGIT
## amber. Sampled per glyph in the same frame as the state tags — (189,189,189) and (193,193,193)
## for `<` and `>`, (127,111,77) for the `1` between them. The flat #929393 that used to cover the
## whole tag split the difference and got both wrong: too dark for the chevrons, colourless for
## the digit. (Screen values through q8 — see the state-tag note above.)
var SLOT_CHEV := QudChrome.q8(191, 191, 191)
var SLOT_NUM := QudChrome.q8(127, 111, 77)
var CELL_FRAME_1TO1 := QudChrome.q8(11, 148, 71)   # green selection box (Qud draws it on the first/selected cell)
var CELL_FILL_1TO1 := QudChrome.q8(21, 23, 23)     # ...and the fill inside it
var CELL_DIVIDER_1TO1 := QudChrome.q8(46, 75, 83)  # Qud's 1px Spacer between cells, measured
var ABIL_KEY_COL := QudChrome.q8(205, 174, 4)      # the gold "A", measured on the glass

# 1:1 PAGINATION (measured off Qud with 10+ abilities on sync-raves-and-qud): Qud packs
# content-sized cells left-to-right and moves what doesn't fit onto further pages — the
# left gutter becomes "ABILITIES / page N of M" with a green up/down stepper showing the
# page number, and Ctrl+Tab / Ctrl+Shift+Tab flip pages. With one page, surplus width is
# shared between the cells (plain HBox expand — the meta 4-ability spread).
## Qud's ButtonArea starts at 175. The 180 the green frame lands on is 175 + the button's padL of
## 5 -- so the gutter states the real edge and the inset comes from the cell, as it does in Qud.
const GUTTER_W_1TO1 := 175
const CELL_PAD_L_1TO1 := 5       # AbilityBarButton padL (padR is 0)
const GUTTER_FONT_1TO1 := 14     # ABILITIES / page line — Qud's, measured off their widths
const GUTTER_TEXT_W_1TO1 := 155  # Qud's Hotbar Swapper — the box those two lines centre in
const KEYCAP_W := 13.0           # Qud's hint keycaps, measured (13 x 9 at x64)
const KEYCAP_H := 9.0
const ABIL_KEY_X := 5.0          # the gold "A" — Qud's ability-menu hotkey letter
const ABIL_KEY_BASE := 20.0      # baseline within the gutter (its ink sits y1023..1034)
const CELL_SPACING_1TO1 := 10    # WorkableArea spacing: icon element -> text
const ICON_W_1TO1 := 32          # TopHalf — the icon ELEMENT; the sprite is fitted inside it
const ICON_H_1TO1 := 48
const ABIL_CYAN := Color8(41, 130, 181)          # ABILITIES / page N of M text
const PAGE_NUM := Color8(141, 124, 84)           # the stepper's page digit
const PAGE_ARROW := Color8(11, 148, 71)          # stepper arrows — Qud's selection green

var _tiles: RefCounted       # shared tile recolouring for ability icons (set in _ready)
var _rt: RichTextLabel       # user (QoL) layout: all abilities inline, left-packed
var _cells: HBoxContainer    # 1:1 layout: one equal-width cell per ability, spread across the bar (Qud)
var _row: HBoxContainer      # the bar's own row: gutter + cells. Its lead-in is what set the cells' x.
var _bar_cells: Array[float] = []   # Qud's own laid-out cell widths, in bar order (snapshot barCells)
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
	# Centred in 155, NOT in the gutter's 175: Qud's Hotbar Swapper is 155 wide and its ABILITIES
	# and page lines centre inside that, which puts their ink at 39 and 31 (measured 39 and 31).
	# Centring in the full gutter put both 10px right.
	gv.offset_right = -(GUTTER_W_1TO1 - GUTTER_TEXT_W_1TO1)
	gv.alignment = BoxContainer.ALIGNMENT_CENTER
	gv.add_theme_constant_override("separation", 0)
	gv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gutter.add_child(gv)
	_gutter_title = Label.new()
	_gutter_title.text = "ABILITIES"
	_gutter_title.add_theme_color_override("font_color", ABIL_CYAN)
	# 14, not 16: Qud's "ABILITIES" measures 76 wide where ours ran 86, and its page line 92 to our
	# 104 -- the same 13% our other 1:1 text has been carrying.
	_gutter_title.add_theme_font_size_override("font_size", GUTTER_FONT_1TO1)
	_gutter_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gutter_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gv.add_child(_gutter_title)
	_gutter_page = Label.new()
	_gutter_page.add_theme_color_override("font_color", ABIL_CYAN)
	_gutter_page.add_theme_font_size_override("font_size", GUTTER_FONT_1TO1)
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
	# ROUNDED CUMULATIVE EDGES, not rounded widths. Qud's cell widths are fractional (192.96,
	# 167.76, 159.36, ...) and rounding each one independently accumulates: the boundaries came out
	# -1, +1, +2, +3, +3, +4, +5 along the bar. Taking the difference of rounded running totals
	# keeps every EDGE within a pixel of Qud's, which is what the eye follows. (Same fix as the
	# picker's row heights -- see PickerOverlay._row_px.)
	_bar_cells.clear()
	var cum := 0.0
	var prev := 0.0
	for w in String(data.get("barCells", "")).split(",", false):
		cum += float(w)
		var edge := roundf(cum)
		_bar_cells.append(edge - prev)
		prev = edge
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
		# No separator NODE: Qud's divider is a 1px Spacer INSIDE the button, so the cell's own width
		# already covers it. A node between cells adds width Qud does not have.
		# Qud frames the selected quick-slot with a green box; default selection is the first ability.
		# Slots restart per page — the 1-9 keys always activate the VISIBLE cells.
		var cw: float = _bar_cells[j] if j < _bar_cells.size() else 0.0
		_cells.add_child(_make_cell(abilities[i], icon_px, j + 1, j == 0, cw))

## Greedy page fit, like Qud: pack content-sized cells until the next one would not fit
## in the bar (window minus the gutter), then start a new page. Cell width is estimated
## from the same font/icon/margins _make_cell lays out.
func _paginate(abilities: Array) -> Array:
	# QUD'S OWN PAGE SIZE when it has told us: barCells holds one width per cell on the page it is
	# showing, so its LENGTH is how many Qud fits. Our own estimate cannot match it -- it is built
	# from our text metrics and our padding, and after those were re-measured it began fitting 8
	# where Qud fits 9, which left the last cell missing and the bar ending at 1669 against Qud's
	# 1912. Later pages assume the same count, which is the best available guess until Qud is on one.
	if _bar_cells.size() > 0:
		var per := _bar_cells.size()
		var out: Array = []
		var idx := 0
		while idx < abilities.size():
			var chunk: Array = []
			while chunk.size() < per and idx < abilities.size():
				chunk.append(idx)
				idx += 1
			out.append(chunk)
		return out if out.size() > 0 else [[]]
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
		var wmin := float(CELL_PAD_L_1TO1) + ICON_W_1TO1 + float(CELL_SPACING_1TO1) \
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
# keycap hints along the top (gold (182,163,5) on the glass, 13x9 keycaps with micro-labels), and
# the green up/down stepper with the page digit right of the text block.
## The hint row's golds, COMPENSATED. Qud's keycap border reads (182,163,5) on the glass and its
## label (125,114,9); ours were raw Color8s landing at (173,154,6) and (114,103,11) -- 9 and 11 dark.
var HINT_GOLD := QudChrome.q8(182, 164, 5)
var KEYCAP_FILL := QudChrome.q8(23, 23, 16)   # the slug inside the border
var HINT_GOLD_DIM := QudChrome.q8(125, 114, 9)

func _draw_gutter() -> void:
	var f := get_theme_font("font", "Label")
	# Qud's ability-menu hotkey letter, gold, hard against the bar's left edge (measured x5..13,
	# y1023..1034, (205,174,4) on the glass). It is there whether or not the bar paginates -- ours
	# drew nothing at all in that corner.
	_gutter.draw_string(f, Vector2(ABIL_KEY_X, ABIL_KEY_BASE), "A",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ABIL_KEY_COL)
	if _pages.size() <= 1:
		return
	# keycap hints row at the very top: [Ctrl]+Tab   [Ctrl]+[Shift]+Tab
	# Qud's row, element by element: keycaps 13 wide and 9 tall at x64, "+" on 3px steps, "Tab"
	# ~15, ending by 154. Measured gold runs: 64-76, 79, 82-96, 103-115, 118, 121-133, 136, 140-148.
	# (The 31..154 run this once chased is the ABILITIES text underneath, not the hints.) Ours was
	# 17x11 on 7px steps and ran to 199 -- past the gutter, into the first cell.
	var hy := 10.0
	var x := 64.0
	x = _draw_keycap(f, x, hy, KEYCAP_W, "Ctrl")
	x = _draw_plus(f, x, hy)
	x = _draw_hint_text(f, x, hy, "Tab")
	x += 7.0
	x = _draw_keycap(f, x, hy, KEYCAP_W, "Ctrl")
	x = _draw_plus(f, x, hy)
	x = _draw_keycap(f, x, hy, KEYCAP_W, "Shift")
	x = _draw_plus(f, x, hy)
	_draw_hint_text(f, x, hy, "Tab")
	# green up/down stepper + the page digit
	# Qud's stepper ink runs 159..170; at -14 ours landed 154..167.
	var cx := GUTTER_W_1TO1 - 10.0
	var cy := _gutter.size.y * 0.5
	# CHEVRONS, not filled triangles: Qud's stepper is two open strokes.
	_gutter.draw_polyline(PackedVector2Array([
		Vector2(cx - 6, cy - 10), Vector2(cx, cy - 16), Vector2(cx + 6, cy - 10)]), PAGE_ARROW, 2.0)
	_gutter.draw_polyline(PackedVector2Array([
		Vector2(cx - 6, cy + 10), Vector2(cx, cy + 16), Vector2(cx + 6, cy + 10)]), PAGE_ARROW, 2.0)
	_gutter.draw_string(f, Vector2(cx - 5, cy + 6), str(_page + 1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, PAGE_NUM)

## One bordered keycap with a tiny centred label; returns the x after it.
func _draw_keycap(f: Font, x: float, y: float, w: float, label: String) -> float:
	# FILLED, then bordered. Qud's keycap is a dark slug (23,23,16) inside a bright gold edge --
	# ours was an outline on the bar's own ground, which reads as a thinner, emptier box.
	_gutter.draw_rect(Rect2(x, y, w, KEYCAP_H), KEYCAP_FILL)
	_gutter.draw_rect(Rect2(x, y, w, KEYCAP_H), HINT_GOLD, false, 1.0)
	var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 5).x
	# The CAP TEXT is full gold, same as its border -- it was on HINT_GOLD_DIM, which is what made
	# "Ctrl"/"Shift" read washed out inside bright edges (Daniel: "need to be full yellow
	# brightness"). The dim tone stays for the connective "+", which Qud does keep quieter.
	_gutter.draw_string(f, Vector2(x + (w - tw) * 0.5, y + KEYCAP_H - 2.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 5, HINT_GOLD)
	return x + w

func _draw_plus(f: Font, x: float, y: float) -> float:
	_gutter.draw_string(f, Vector2(x + 1, y + 7), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 7, HINT_GOLD_DIM)
	return x + 3.0

func _draw_hint_text(f: Font, x: float, y: float, txt: String) -> float:
	_gutter.draw_string(f, Vector2(x, y + 8), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, HINT_GOLD)
	return x + f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x

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
		# 18: the block sits 6px low of where centring puts it -- Qud's ABILITIES ink is y1045..1055
		# and ours was 1039..1049.
		_gutter_box.offset_top = 18.0 if _pages.size() > 1 else 0.0   # room for the keycap hints
	_gutter.queue_redraw()

## One ability as a centred, equal-share, clickable cell: a nearest-filtered tile icon + a name/state/
## hotkey label, both centred. The cell (an HBox) catches the click via gui_input; children IGNORE the
## mouse so it falls through. Nothing here takes keyboard focus, so the movement arrows are never
## swallowed (the "can't move after Make Camp" bug).
func _make_cell(a: Dictionary, icon_px: int, slot: int, selected: bool, cell_w := 0.0) -> Control:
	var cmd := String(a.get("command", ""))
	var tex: Texture2D = _tiles.texture_for(a, true)
	if cmd != "":
		_ability_tex[cmd] = tex
	# The click target + optional green selection frame is the outer PanelContainer; children ignore the
	# mouse so the click falls through to it, and nothing here grabs keyboard focus (movement-arrow bug).
	var frame := PanelContainer.new()
	# QUD'S WIDTH, not a share of the bar. Both apps size a cell to its content and share out the
	# slack, but Godot splits leftover space equally between expanding children where Unity
	# distributes it by flexible width -- so identical content lands on different widths and no
	# padding or spacing can reconcile them. cell_w is Qud's own laid-out width for this cell.
	if cell_w > 0.0:
		frame.custom_minimum_size = Vector2(cell_w, 0)
		frame.size_flags_horizontal = Control.SIZE_FILL
	else:
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # no bar seen yet: share equally
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The outer box PAINTS NOTHING: Qud's AbilityBarButton only pads (L5, R0) and the green box
	# belongs to the WorkableArea inside it, which is why the frame reads at x180 in a cell at 175.
	var obs := StyleBoxFlat.new()
	obs.bg_color = Color(0, 0, 0, 0)
	obs.set_border_width_all(0)
	obs.set_corner_radius_all(0)
	obs.content_margin_left = CELL_PAD_L_1TO1
	obs.content_margin_right = 0
	obs.content_margin_top = 0
	obs.content_margin_bottom = 0
	frame.add_theme_stylebox_override("panel", obs)
	# Qud's 1px Spacer, drawn rather than laid out: it sits at the button's left edge OUTSIDE the
	# padding (x+1.5 of a cell whose content starts at x+5), so a layout child would both consume
	# width and land in the wrong place.
	if slot > 1:
		frame.draw.connect(func() -> void:
			frame.draw_rect(Rect2(1.0, (frame.size.y - 42.0) * 0.5, 1.0, 42.0), CELL_DIVIDER_1TO1))
	var work := PanelContainer.new()                          # Qud's WorkableArea
	work.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	work.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(work)
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
	fs.content_margin_left = 0
	fs.content_margin_right = 0
	work.add_theme_stylebox_override("panel", fs)
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
	cell.add_theme_constant_override("separation", CELL_SPACING_1TO1)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	work.add_child(cell)
	if tex != null:
		var ir := TextureRect.new()
		ir.texture = tex
		ir.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel-art, no blur
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# Qud's TopHalf is a FIXED 32x48 element; the sprite is fitted inside it, which is why its ink
		# reads 24 wide for a narrow tile and 43 for a wide one while the element never changes.
		ir.custom_minimum_size = Vector2(ICON_W_1TO1, ICON_H_1TO1)
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
	# Only the NAME is flat here — the state tags and the quick slot each colour their own
	# delimiters the way Qud does. Both used to ride inside one grey, which is why 1:1 showed
	# "[off]", "[81]" and "<1>" in a single dead tone no matter what the constants said.
	lbl.text = "[color=%s]%s[/color]%s%s" % [
		NAME_1TO1, QudText.strip(String(a.get("name", ""))),
		_state_tag(a), _hotkey_cell_tag(a, slot)]
	cell.add_child(lbl)
	return frame

## Coloured quick slot for the 1:1 cell: grey chevrons around an amber digit, Qud's own split.
## Built from _hotkey_label so the two never disagree about WHICH key is shown — that stays the
## plain twin the pagination pass measures with (markup would be measured as literal characters).
func _hotkey_cell_tag(a: Dictionary, slot: int) -> String:
	var lbl := _hotkey_label(a, slot).strip_edges()
	if lbl == "":
		return ""
	var key := lbl.trim_prefix("<").trim_suffix(">")
	return " [color=#%s]<[/color][color=#%s]%s[/color][color=#%s]>[/color]" % [
		SLOT_CHEV.to_html(false), SLOT_NUM.to_html(false), key, SLOT_CHEV.to_html(false)]

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

## UNMARKED twin of _state_tag, for MEASUREMENT only (the pagination pass sizes each cell with
## `f.get_string_size`, and colour markup would be measured as literal characters — pages would
## break early and cells would be laid out to a width nothing renders at). Keep the two in sync:
## same suffixes, same order, one with tags and one without.
func _state_plain(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += " [%d]" % cd
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

## BBCode for one bracketed tag with Qud's two-tone treatment: brackets in `brk`, body in `body`.
## [lb]/[rb] rather than raw brackets — a literal "[" abutting a [/color] is exactly the shape
## Godot's parser is entitled to read as a tag, and the escape costs nothing.
func _tag(body: String, body_col: Color, brk_col: Color) -> String:
	return " [color=#%s][lb][/color][color=#%s]%s[/color][color=#%s][rb][/color]" % [
		brk_col.to_html(false), body_col.to_html(false), body, brk_col.to_html(false)]

func _state_tag(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += _tag(str(cd), CD, CD)          # cooldown: brackets share the digits' cyan
	if bool(a.get("toggleable", false)):
		var on := bool(a.get("toggle", false))
		s += _tag("on" if on else "off", TAG_ON if on else TAG_OFF, TAG_BRK)
	elif not bool(a.get("enabled", true)):
		s += _tag("disabled", Color.html(DIM), TAG_BRK)
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

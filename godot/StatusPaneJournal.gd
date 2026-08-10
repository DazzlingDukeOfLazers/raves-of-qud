extends Control

## The JOURNAL tab, mirroring Qud.UI.JournalStatusScreen's left-hand list.
##
## Geometry is Qud's own, read off the live RectTransforms with the mod's UiProbe:
##
##   header      "Locations" at x=187.5 y=182.6, font 24, flanked by rule ends
##   list        EntryScroller x=158.5 y=234 w=793.5; rows at x=174.5 w=777.5
##   row         caret x=175.6 +18.2 15x15 | header text x=190.5 font 20 with a dotted
##               leader filling right | body text x=190.5 below, font 16
##
## The WORLD MAP in the right half is Qud's own rendered texture, exported by the mod. It is the
## JOURNAL'S OWN file, not the Quests pane's: RefreshMap dims every cell outside `highlights`, and
## the Journal passes null (nothing dims) where Quests passes the quest locations (most of the world
## goes dark). Same world, different pixels. Qud shows
## it only on the tabs whose CategoryInfo sets UsesMap (Locations and Village Histories), which the
## export carries per tab, and centres it on the SELECTED entry's target rather than pinning.
##
## The seven sub-tabs are Qud's (JournalScreen's STR_ constants, in screen order), drawn as Qud's
## own ICON CAROUSEL: a row of FilterBarCategoryButtons flanked by the [Q]/[E] paging badges, which
## Q/E cycle. Same prefab, same 46x41 cell at a 58px pitch, as the inventory's filter strip -- the
## shared drawing is QudFilterBar. Each cell's tile comes from that button's own categoryImageMap,
## shipped per tab by the mod, so the seven paths cannot drift from the game's.

const HDR_X := 187.5
const HDR_Y := 182.6
const HDR_FONT := 24
const LIST_X := 174.5
const LIST_Y := 250.0
const LIST_W := 777.5
const LIST_H := 671.0
const CARET_DX := 1.1
const CARET_DY := 18.2
## The header block's two 1px vertical ticks. x/y/h are Qud's own (JournalHeader/Image (2)); the
## right one rides the text width, as Qud's ContentSizeFitter does.
const HDR_TICK_X := 170.5
const HDR_TICK_Y := 189.7
const HDR_TICK_H := 16.0
const HDR_ICON_W := 16.0      # the header's flanking icon slots (Image (3) / Image (1))
const ROW_TEXT_DX := 16.0     # header/body text sit 16 in from the row's left
const ROW_FONT := 20          # header row (category / recipe name / the empty-state line)
const BODY_FONT := 16
const ROW_GAP := 6.0
const STRIP_Y := 186.0        # the sub-tab strip, centred like Qud's icon row

# The map panel, measured off Qud's live RectTransforms (Journal's is its own rect, not Quests').
const MAP_X := 952.0
const MAP_Y := 234.0
const MAP_W := 793.5
const MAP_H := 687.0
const MAP_ZOOM := 2.0
const MAP_CELL_W := 16.0
const MAP_CELL_H := 24.0

const C_TEXT := Color8(0xaf, 0xc6, 0xc1)
const C_DIM := Color8(0x3b, 0x55, 0x5e)
## The header's two closing ticks are RULES, not dim text: Qud's elements are #4d6e7a like every
## other rule on these screens, landing at (68,99,111). Drawing them in the pane's C_DIM put them
## at (52,75,83) -- a different colour from the frame rule they sit on.
var C_TICK := QudChrome.q8(68, 99, 111)
const C_GOLD := Color8(0xcf, 0xc0, 0x41)
## The carousel's two frame states and the panel black the knob punches into, all SCREEN values
## (QudChrome.q8 takes what the capture shows, not the Unity property) — the same two the inventory
## strip calls C_FILT_ON and C_BOX, because it is the same button.
var C_CELL_ON := QudChrome.q8(122, 126, 71)    # #858951 — the current tab
var C_CELL_OFF := QudChrome.q8(51, 80, 91)     # the untouched prefab colour on the rest
var C_PANEL := QudChrome.q8(7, 29, 29)         # the knob's punch-out
var C_HOVER := QudChrome.q8(65, 106, 115)      # #4A757E — the cell under the pointer
## Qud's own, off the live element: JournalHeader/Header is #4383a4 at font 24 in
## SourceCodePro-Regular. Ours was a grey (#829ea8) and read as a different colour entirely.
const C_HDR := Color8(0x43, 0x83, 0xa4)

var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

var _tabs: Array = []
var _tab := 0
var _sel := 0
var _scroll := 0.0
var _palette := {}
var _font: Font
var _content: Control
var _tiles: RefCounted = null
var _bar: RefCounted = null
## The carousel's hit geometry, rebuilt by _draw_carousel: [[Rect2, tab index], …] for the cells,
## then the two badges as [Rect2, -1]/[Rect2, -2]. Owner-drawn panes cannot be hit-tested from
## outside, so the pane answers with the rects it actually drew — the same contract the inventory
## strip uses, and the reason a moved constant can never desync the clickable area from the paint.
var _cell_rects: Array = []
var _cell_hover := -1
var _map: Texture2D = null
var _map_tried := false
var _player_pos := Vector2(-1, -1)

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_font = UiFont.make_theme(get_viewport()).default_font
	_tiles = load("res://QudTiles.gd").new()
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	_bar = load("res://QudFilterBar.gd").new()
	_content = Control.new()
	_content.position = Vector2(0, 0)
	_content.size = Vector2(1920, 940)
	_content.clip_contents = false
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NEAREST or the carousel's tiles come out LINEAR-smeared -- draw_* inherits the
	# drawing Control's texture_filter, as the inventory pane's icons found first.
	_content.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_content.draw.connect(_draw_all)
	add_child(_content)

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	if _tiles != null:
		_tiles.palette = _palette
	_tabs = data.get("tabs", [])
	var pp: Dictionary = data.get("player", {})
	_player_pos = Vector2(float(pp.get("x", 0)), float(pp.get("y", 0))) if not pp.is_empty() \
		else Vector2(-1, -1)
	_tab = clampi(_tab, 0, maxi(0, _tabs.size() - 1))
	_sel = 0
	_scroll = 0.0
	if _content != null:
		_content.queue_redraw()

func _cur() -> Dictionary:
	if _tabs.is_empty():
		return {}
	return _tabs[clampi(_tab, 0, _tabs.size() - 1)]

func _draw_all() -> void:
	if _font == null or _tabs.is_empty():
		return
	var tab := _cur()
	if bool(tab.get("usesMap", false)):
		_draw_map(tab)

	# --- header: the current tab's display name, with Qud's rule ends either side
	var name := str(tab.get("name", ""))
	_draw_header_text(name, tab)
	# QUD'S OWN WIDTH when the frame carries it. Qud measures "Locations" at 143.04 where our
	# Source Code Pro at 24 measures 129.6 -- the extra 13.44 is either per-character tracking or a
	# fixed pad, and a single sample cannot tell those apart (they disagree on every other string).
	# So the mod asks the live TMP component to measure each sub-tab's header and ships the answer,
	# the same bargain as the picker's title tab. Ours is the fallback for a session where the
	# Journal tab has not been opened in Qud yet.
	var nw: float = float(tab.get("hdrW", 0.0))
	if nw <= 0.0:
		nw = _font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, HDR_FONT).x
	# BRACKETS, not rule ends: Qud closes the header block with two 1px VERTICAL ticks, one at each
	# edge (JournalHeader/Image (2) at x=170.5, y=189.7, 1x16, and its twin at the block's right
	# edge, 347.5 = 170.5 + the block's 177.04). We were drawing 16px HORIZONTAL dashes there, which
	# is what left the journal's header row disagreeing with Qud's after the top rule matched.
	_content.draw_rect(Rect2(HDR_TICK_X, HDR_TICK_Y, 1.0, HDR_TICK_H), C_TICK)
	# The right tick is not flush with the text: an ICON sits between them (JournalHeader's
	# Image (1), 16x16 at 330.54, mirroring Image (3) on the left). We do not draw those icons yet,
	# but their SPACE is part of the header's geometry -- without it the right tick came in 16px
	# early and the block read as too narrow.
	_content.draw_rect(Rect2(HDR_X + nw + HDR_ICON_W, HDR_TICK_Y, 1.0, HDR_TICK_H), C_TICK)

	# --- the sub-tab carousel
	_draw_carousel()

	# --- the entry list
	var entries: Array = tab.get("entries", [])
	var y := LIST_Y - _scroll
	if entries.is_empty():
		# Qud's empty state is a real ROW, header-styled, with the same dotted leader.
		_draw_header_row(str(tab.get("empty", "No entries found.")), y, true)
		return
	if bool(tab.get("usesCategories", false)):
		y = _draw_grouped(tab, entries, y)
	else:
		for i in entries.size():
			if y > LIST_Y + LIST_H:
				break
			var h := _draw_entry(entries[i], y, i == _sel)
			y += h + ROW_GAP

## Qud's category carousel: [Q] then one framed icon per sub-tab then [E], centred on the gap the
## top rule leaves for it (StatusScreens draws that gap at 959.5 +/- 233.5, i.e. 726..1193, and the
## run Qud lays out inside it is 450 wide and centred on 960 -- so the two agree without either
## being told about the other).
##
## FRAME COLOUR is a two-state read, not the four-state one FilterBarCategoryButton.LateUpdate
## describes. Those four only apply to a strip of FILTERS; the journal's cells are a single-select
## carousel, and Qud's live values are #858951 on the current tab and the untouched PREFAB colour on
## the rest -- measured on screen as (122,126,71) and (51,80,91), the same two the inventory pane
## calls C_FILT_ON and C_BOX. A tab you have visited and left can carry #134F4E instead, because
## LateUpdate writes only on a state CHANGE; that history-dependent third value is not modelled
## here, for the same reason the inventory pane prefers a live colour off the wire to deriving one.
func _draw_carousel() -> void:
	var n := _tabs.size()
	if n == 0:
		return
	_cell_rects.clear()
	var left: float = _bar.run_left(n, 960.0)
	var x0: float = left + _bar.BADGE.x + _bar.BADGE_GAP
	var green := QudText.color_of_code("g", _palette, Color8(0x00, 0x94, 0x03))
	_bar.badge(_content, _font, left, "Q", C_TICK, green)
	var ex: float = x0 + _bar.cells_width(n) + _bar.BADGE_GAP
	_bar.badge(_content, _font, ex, "E", C_TICK, green)
	_cell_rects.append([Rect2(Vector2(left, _bar.BADGE_Y), _bar.BADGE), -1])
	_cell_rects.append([Rect2(Vector2(ex, _bar.BADGE_Y), _bar.BADGE), -2])
	for i in n:
		var r: Rect2 = _bar.cell_rect(x0, i)
		_cell_rects.append([r, i])
		_bar.cell(_content, r, _cell_color(i), C_TICK, true, C_PANEL)
		var tile := str((_tabs[i] as Dictionary).get("icon", ""))
		if tile == "" or _tiles == null:
			continue
		var tex: Texture2D = _tiles.texture(tile,
			_bar.ICON_MAIN, _bar.ICON_DETAIL)
		if tex != null:
			_content.draw_texture_rect(tex, _bar.icon_rect(r), false)

## The sub-tab name, laid out on QUD'S pitch.
##
## Qud tracks this header wider than the font's own advance: fitting its measurements of all seven
## sub-tab names gives 16.079px per character at font 24, where Source Code Pro's nominal 0.6em
## advance is 14.4. Drawing the string in one call put every glyph after the first progressively
## left of Qud's, ~1.7px per character. Since the mod ships Qud's width for THIS name, the pitch
## comes straight out of it -- no tracking constant to carry, and it stays right if Qud restyles.
func _draw_header_text(name: String, tab: Dictionary) -> void:
	var w: float = float(tab.get("hdrW", 0.0))
	var n := name.length()
	if w <= 0.0 or n == 0:
		_content.draw_string(_font, Vector2(HDR_X, HDR_Y + 22.0), name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, HDR_FONT, C_HDR)
		return
	var pitch := w / float(n)
	for i in n:
		_content.draw_string(_font, Vector2(HDR_X + pitch * float(i), HDR_Y + 22.0), name[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HDR_FONT, C_HDR)


## A header-styled row (empty state / recipe name), with the leader running to the list's right.
func _draw_header_row(s: String, y: float, caret: bool) -> void:
	if caret:
		_content.draw_string(_font, Vector2(LIST_X + CARET_DX, y + CARET_DY + 12.0), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_GOLD)
	var tx := LIST_X + ROW_TEXT_DX
	_content.draw_string(_font, Vector2(tx, y + 24.0), " " + s,
		HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_TEXT)
	var w := _font.get_string_size(" " + s, HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT).x
	var lx := tx + w + 8.0
	while lx < LIST_X + LIST_W:
		_content.draw_rect(Rect2(lx, y + 18.0, 2.0, 1.0), C_DIM)
		lx += 6.0

## One entry. Returns its height.
func _draw_entry(e: Dictionary, y: float, selected: bool) -> float:
	if selected:
		_content.draw_string(_font, Vector2(LIST_X + CARET_DX, y + CARET_DY + 12.0), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_GOLD)
	# A RECIPE is the one entry kind with its own header: setData puts the recipe's display name
	# in the header row and the ingredients/effects in the body.
	var h := 0.0
	if e.has("recipe"):
		_draw_header_row(str(e.get("recipe", "")), y, false)
		h += 30.0
		h += _body(["{{K|Ingredients:}} " + str(e.get("ingredients", ""))], y + h)
		var eff := str(e.get("effects", ""))
		if eff != "":
			var lines := PackedStringArray()
			for ln in eff.split("\n"):
				lines.append("{{K|/}} {{y|" + ln + "}}")
			h += _body(lines, y + h)
		return h
	# Plain entry: setData's two prefixes, then the display text.
	var pre := ""
	if e.has("tracked"):
		pre += "[X] " if bool(e.get("tracked", false)) else "[ ] "
	pre += "{{G|$}} " if bool(e.get("tradable", false)) else "{{K|$}} "
	var body := str(e.get("text", ""))
	if bool(e.get("tomb", false)):
		body = "{{w|[tomb engraving] " + body + "}}"
	return _body([pre + body], y)

## Draw wrapped markup lines into the list column; returns the height used.
##
## An entry's text carries REAL NEWLINES ("…in the marsh.\nnear Joppa\nLast visited on…") and Qud
## renders them as separate lines. Splitting on them here is not cosmetic: _wrap only breaks on
## spaces, so a surviving \n reaches QudText.cp437, which maps 0x0A to "◙" and prints a glyph in
## the middle of the sentence. Same trap as the quest bodies.
func _body(lines: Array, y: float) -> float:
	var used := 0.0
	var flat := []
	for raw in lines:
		for part in str(raw).split("\n"):
			flat.append(part)
	for raw in flat:
		for seg in _wrap(str(raw), LIST_W - ROW_TEXT_DX - 40.0):
			_draw_markup(seg, Vector2(LIST_X + ROW_TEXT_DX + 32.0, y + used + 14.0), BODY_FONT)
			used += 18.0
	return used

func _wrap(s: String, w: float) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in QudText.strip(s).split(" ", false):
		var probe := word if line == "" else line + " " + word
		if _font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT).x > w:
			out.append(line)
			line = word
		else:
			line = probe
	if line != "":
		out.append(line)
	return out

func _draw_markup(s: String, pos: Vector2, px: int) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, C_TEXT):
		var txt: String = run[0]
		if txt == "":
			continue
		_content.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## A cell's frame colour -- FilterBarCategoryButton.LateUpdate's four states, verbatim:
##
##   enabled + focused -> #FFFFFF    enabled -> #858951    focused -> #4A757E    else -> prefab
##
## "enabled" is the CURRENT tab and "focused" is the pointer, because FrameworkHoverable makes the
## cell's navigation context active on pointer-enter. The four-state law is usable here in a way it
## is not on the inventory strip: there, focus history is Qud's and unobservable from outside, so
## that pane prefers a live colour off the wire. Here Raves owns the hover, so the state is known.
func _cell_color(i: int) -> Color:
	if i == _tab:
		return Color(1, 1, 1) if i == _cell_hover else C_CELL_ON
	return C_HOVER if i == _cell_hover else C_CELL_OFF

## Pointer handling for the carousel. Called by StatusScreens' gui_input (this pane is owner-drawn
## and takes no events of its own).
##
## Only the CELLS are clickable. Qud's [Q]/[E] are UIHotkeySkin labels, not buttons -- clicking one
## in Qud does nothing -- so they are hit-tested for the feedback tool's benefit and left inert
## rather than given an affordance the game does not have.
func handle_mouse(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var was := _cell_hover
		_cell_hover = -1
		for entry in _cell_rects:
			if int(entry[1]) >= 0 and (entry[0] as Rect2).has_point(e.position):
				_cell_hover = int(entry[1])
				break
		if _cell_hover != was:
			_content.queue_redraw()
		return
	if not (e is InputEventMouseButton and e.pressed):
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	for entry in _cell_rects:
		if int(entry[1]) >= 0 and (entry[0] as Rect2).has_point(e.position):
			_select_tab(int(entry[1]))
			return

## Switch sub-tabs. ONE path for the click and for Q/E, so the two cannot drift on the parts that
## are easy to forget: the selection and the scroll both reset, as they do in Qud when its
## CurrentCategory changes and the entry scroller is rebuilt.
func _select_tab(i: int) -> void:
	if _tabs.is_empty():
		return
	_tab = clampi(i, 0, _tabs.size() - 1)
	_sel = 0
	_scroll = 0.0
	_content.queue_redraw()

## FEEDBACK PROVIDER (FeedbackTool.feedback_element_at contract). Owner-drawn, so the tool's hit
## test cannot see inside -- the pane answers from the rects it drew.
func feedback_element_at(p: Vector2) -> Dictionary:
	if not is_visible_in_tree():
		return {}
	for entry in _cell_rects:
		if not (entry[0] as Rect2).has_point(p):
			continue
		var i := int(entry[1])
		if i < 0:
			var k := "Q" if i == -1 else "E"
			return {"label": "carousel · [" + k + "]", "rect": entry[0],
				"action": "previous sub-tab" if i == -1 else "next sub-tab"}
		var nm := str((_tabs[i] as Dictionary).get("name", ""))
		return {"label": "carousel · " + nm, "rect": entry[0],
			"action": "show the " + nm + " sub-tab"}
	return {}

## Q/E cycle the sub-tabs, matching the [Q]/[E] badges Qud puts either side of its icon strip.
func handle_key(e: InputEventKey) -> bool:
	if _tabs.is_empty():
		return false
	if e.keycode == KEY_Q:
		_select_tab((_tab - 1 + _tabs.size()) % _tabs.size())
	elif e.keycode == KEY_E:
		_select_tab((_tab + 1) % _tabs.size())
	else:
		return false
	return true


## Qud's world map, drawn only on the tabs that use it. Centred on the SELECTED entry's target
## when it has one (map notes carry parasang coords); otherwise the map's own middle. Clamped so
## the view never runs past the edges.
func _draw_map(tab: Dictionary) -> void:
	if _map == null and not _map_tried:
		_map_tried = true
		var path := InputModel.support_dir().path_join("map").path_join("journal_map.png")
		if FileAccess.file_exists(path):
			var img := Image.new()
			if img.load(path) == OK:
				_map = ImageTexture.create_from_image(img)
	if _map == null:
		return
	var tw := _map.get_width() * MAP_ZOOM
	var th := _map.get_height() * MAP_ZOOM
	# Default centre is the PLAYER's parasang, not the texture's middle — that is where Qud's
	# map sits with nothing selected, and the middle put us several parasangs away.
	var cx := tw * 0.5
	var cy := th * 0.5
	if _player_pos != Vector2(-1, -1):
		cx = (_player_pos.x + 0.5) * MAP_CELL_W * MAP_ZOOM
		cy = (_player_pos.y + 0.5) * MAP_CELL_H * MAP_ZOOM
	var entries: Array = tab.get("entries", [])
	if _sel >= 0 and _sel < entries.size() and entries[_sel].has("mx"):
		cx = (float(entries[_sel].get("mx", 0)) + 0.5) * MAP_CELL_W * MAP_ZOOM
		cy = (float(entries[_sel].get("my", 0)) + 0.5) * MAP_CELL_H * MAP_ZOOM
	var ox := clampf(MAP_X + MAP_W * 0.5 - cx, MAP_X + MAP_W - tw, MAP_X)
	var oy := clampf(MAP_Y + MAP_H * 0.5 - cy, MAP_Y + MAP_H - th, MAP_Y)

	var clip := Rect2(MAP_X, MAP_Y, MAP_W, MAP_H)
	_content.draw_rect(clip, Color8(4, 19, 18))   # RefreshMap's own backdrop
	var prev := _content.texture_filter
	_content.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var src := Rect2((MAP_X - ox) / MAP_ZOOM, (MAP_Y - oy) / MAP_ZOOM,
		MAP_W / MAP_ZOOM, MAP_H / MAP_ZOOM)
	_content.draw_texture_rect_region(_map, clip, src)
	_content.texture_filter = prev

	# the selected entry's location, marked the way the Quests pane marks a pin
	if _sel >= 0 and _sel < entries.size() and entries[_sel].has("mx"):
		var px := ox + (float(entries[_sel].get("mx", 0)) + 0.5) * MAP_CELL_W * MAP_ZOOM
		var py := oy + (float(entries[_sel].get("my", 0)) + 0.5) * MAP_CELL_H * MAP_ZOOM
		if clip.has_point(Vector2(px, py)):
			_content.draw_rect(Rect2(px - 5.0, py - 5.0, 10.0, 10.0), C_GOLD, false, 2.0)


## Grouped rendering for the tabs whose CategoryInfo sets UsesCategories.
##
## Qud builds a dictionary keyed by CategoryFor(entry), optionally sorts the KEYS A-Z
## (SortCategoriesAZ — every grouping tab but Sultan Histories, which keeps its natural order),
## and emits a category row followed by its entries. Sultans get a different header form.
func _draw_grouped(tab: Dictionary, entries: Array, y: float) -> float:
	var order := PackedStringArray()
	var groups := {}
	for e in entries:
		var c := str(e.get("category", "Unknown"))
		if not groups.has(c):
			groups[c] = []
			order.append(c)
		groups[c].append(e)
	if bool(tab.get("sortAZ", false)):
		var keys := Array(order)
		keys.sort()
		order = PackedStringArray(keys)

	var sultan := bool(tab.get("sultanHeaders", false))
	var idx := 0
	for c in order:
		if y > LIST_Y + LIST_H:
			break
		var head := ("HISTORY OF " + c.to_upper()) if sultan else c
		_draw_header_row("[-] " + head, y, idx == _sel)
		y += 30.0
		for e in groups[c]:
			if y > LIST_Y + LIST_H:
				break
			idx += 1
			y += _draw_entry(e, y, idx == _sel) + ROW_GAP
		idx += 1
	return y

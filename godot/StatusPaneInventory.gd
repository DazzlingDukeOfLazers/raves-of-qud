extends Control

## INVENTORY — the right half of Qud's Equipment tab, 1:1.
##
## Data: mod InventoryExporter -> inventory.json (categories from Qud's own
## GetInventoryCategory, row labels straight from GameObject.DisplayName with its
## markup, weights and the ${drams} / carried/max header exactly as
## InventoryAndEquipmentStatusScreen builds them). Like the other panes this file
## holds no colour or formatting logic — it lays strings out and resolves {{…}}
## through the palette.
##
## Geometry measured off reports/2026-08-04-status-screens/equipment_qud.png:
## rows start y240 with a ~26px pitch, hotkey letter at x861, category label x909
## (item name x909 too, after a 16px tile), category weight |n lbs.| right-aligned
## at x1673, item weight [n lbs.] right-aligned at x1753, header at x1753.
##
## The PAPER DOLL (left half) draws Qud's fixed slot grid: 64x64 boxes on columns
## x{274,364,454,544,634} and rows y{246,366,486,606,726} (measured by locating the
## frame's own runs in the capture), each showing its equipped item's tile centred
## beneath. Body parts come from Qud's own body tree; the grid is keyed by part
## type/name, and a primary limb gets Qud's "*" marker.

const ROW_H := 26.0
const LIST_X := 855.0
const LIST_Y := 235.0   # first row top lands on Qud's y240 with the +16 baseline
const LIST_W := 910.0
const LIST_H := 660.0
const LETTER_X := 861.0
const NAME_X := 909.0
const CAT_W_EDGE := 1673.0
const ITEM_W_EDGE := 1753.0
# Qud draws the list at TWO sizes, which is easy to miss because both rows share a
# pitch: a CATEGORY name's glyphs advance 13.3px, an ITEM name's advance 9.75px.
# Qud's letterspaced UI font advances 0.6*size, so that is 22 and 16. Our 16 was
# right for items all along and 35% small on the categories -- no amount of column
# nudging can line up a row whose glyphs are the wrong size. The hotkey letter stays
# at ITEM_FONT in both kinds (measured: "b)" and "c)" land identically).
const ROW_FONT := 22    # category rows
const ITEM_FONT := 16   # item rows, and the hotkey column everywhere

# Qud reserves these letters for commands, so the inventory spread skips them
# (measured off the reference: a,b,c,f,g,… — d/e/q/s never appear).
const RESERVED := ["d", "e", "q", "s"]
const LETTERS := "abcdefghijklmnopqrstuvwxyz0123456789"

static func _iv8(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_DIM := _iv8(108, 133, 129)
var C_SEL := _iv8(23, 59, 60)
var C_GOLD := _iv8(200, 184, 57)
# FILTER-CELL STATES, straight out of Qud's FilterBarCategoryButton.LateUpdate:
#   enabled + focused -> #FFFFFF   enabled -> #858951   focused -> #4A757E
# and otherwise the frame keeps the PREFAB colour, because that LateUpdate only
# writes background.color when the state CHANGES — a button nobody has touched is
# never assigned one of the four. That untouched colour is what C_BOX measures.
var C_BOX := _iv8(51, 80, 91)      # MEASURED: the untouched/prefab frame colour
var C_HOVER := _iv8(65, 106, 115)  # #4A757E — nav-focused (what the mouse gives)
var C_FILT_ON := _iv8(122, 126, 71)     # #858951 — category filter ENABLED
var C_FILT_ON_SEL := Color8(255, 255, 255)  # enabled AND focused
# The "*All" cell HAS been toggled (the save ships with it on), so unlike the
# untouched category buttons it does carry an explicit colour: #134F4E when off.
var C_ALL_OFF := _iv8(19, 79, 78)
var C_LABEL := _iv8(120, 146, 141)
# A CATEGORY row is ONE colour for all three of its parts. Read off a live InventoryLine
# rather than sampled from a capture (a sample cannot separate colour from alpha):
# categoryLabel, categoryExpandLabel and categoryWeightText are all
# RGBA(0.231, 0.365, 0.443) at alpha 1 -- Qud sets no markup on them, the colour lives on
# the prefab. That grades to (52,83,102) on screen, where our "{{c|}}" cyan rendered
# (56,154,176): far too bright and too saturated.
# Drawn as QUD'S OWN value, not through _iv8: the helper's flat +6 lands this one
# short (it rendered (51,79,97) against Qud's (52,83,102)), whereas Raves grades
# Qud's raw source the same way Qud does.
var C_CAT := Color8(59, 93, 113)
# An ITEM row, read off the same live InventoryLine: `text` (the name's unmarked runs)
# and `hotkeyText` are both RGBA(0.690, 0.780, 0.760), and `itemWeightText` is the SAME
# colour as the category row, (59,93,113).
#
# Those are the values Qud sets -- but unlike every other colour on this screen they are
# not what to DRAW, because at ITEM_FONT the glyph stems are thin enough that anti-
# aliasing, not the colour, decides the result, and Godot's rasteriser reaches nearer to
# full colour than Qud's. The proof is Qud itself: the item weight and the category name
# carry the identical (59,93,113), yet the category renders (52,83,102) at ROW_FONT and
# the weight only (40,67,81) at ITEM_FONT. So these two are FITTED to land Qud's rendered
# ink, the same concession already made for the 2.5x sprite phase; the ROW_FONT colours
# above stay Qud's literal values, which match exactly.
var C_ITEM := Color8(147, 171, 166)     # renders as Qud's (137,162,157)
var C_ITEM_W := Color8(46, 74, 89)      # (59,93,113) at ITEM_FONT -> (40,67,81)
# The hotkey column carries the same (176,199,194) as the name but renders DIMMER
# still -- (128,153,149) against the name's (137,162,157) -- because ")" is thinner than
# a letter, so it needs its own fit. Sampled down the whole column (n>300) rather than
# off one row: "b)" alone gives two pixels and any conclusion from that is noise.
var C_HOTKEY := Color8(139, 164, 160)

# Qud's paper-doll grid: label -> [column x, row y]. Found by scanning the capture
# for the frame's own long runs rather than eyeballing the lit area: the boxes are
# 64x64 on a 90px column / 120px row pitch, nine columns LEFT of where the earlier
# by-eye numbers put them (the old 55x62 at x+9 measured the interior, not the box).
const DOLL := {
	"Face": [454, 246], "Floating Nearby": [634, 246],
	"Worn on Hands": [274, 366], "Head": [454, 366],
	"Left Hand": [274, 486], "Left Arm": [364, 486], "Body": [454, 486],
	"Right Arm": [544, 486], "Right Hand": [634, 486],
	"Worn on Back": [454, 606],
	"Thrown Weapon": [274, 726], "Feet": [454, 726],
	"Left Missile Weapon": [544, 726], "Right Missile Weapon": [634, 726],
}
const BOX_W := 64.0
const BOX_H := 64.0

# Category FILTER STRIP (Qud's FilterBar): "*All" plus one cell per category
# present in the inventory, measured off the reference — 44x38 cells from x620,
# 58px pitch, on y178. Qud draws a fixed per-category ICON; we stand in with the
# category's first item tile (recorded deviation) until those icons are extracted.
# The strip's FIRST cell is the "*All" button and it sits at 618 — categories then
# run 676, 734, 792, ... Found by scanning the capture for 46-wide ink groups; the
# old 560 put a cell where Qud draws none and shifted the whole strip one pitch left,
# so every category icon was being compared against its neighbour's.
const FILT_X := 618.0
const FILT_Y := 177.0
# 46 wide because Qud draws polat-category-frame at its NATIVE size here — the
# sprite is 46x41, and the cell is the sprite (the doll's 64x64 boxes are the same
# sprite stretched). Pitch 58 leaves a 12px gap between cells.
const FILT_W := 46.0
const FILT_H := 41.0   # measured: cell rows 177..217
const FILT_PITCH := 58.0

var _data := {}
var _palette := {}
var _tiles: RefCounted = null
var _rows: Array = []       # flattened: {kind, name, weight, tile…, letter}
var _sel := 0
var _scroll := 0.0
var _collapsed := {}        # category name -> true when collapsed (Raves-side view state)
var _enabled := {}          # filter strip: enabled category names; EMPTY means "*All"
var _filt_rects: Array = [] # [[Rect2, category-or-empty], …] rebuilt with the strip
var _filt_hover := -1       # index into _filt_rects under the cursor (-1 = none)
var _clip: Control
var _content: Control
var _static: Control
var _font: Font
var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

func _ready() -> void:
	name = "InventoryPane"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_tiles = load("res://QudTiles.gd").new()
	_font = get_theme_font("font", "Label")
	_static = Control.new()
	_static.set_anchors_preset(Control.PRESET_FULL_RECT)
	_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NEAREST or every tile this pane draws (doll items, filter icons) comes out
	# LINEAR-smeared — draw_* inherits the drawing Control's texture_filter.
	_static.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_static.draw.connect(_draw_static)
	add_child(_static)
	_clip = Control.new()
	_clip.position = Vector2(LIST_X, LIST_Y)
	_clip.size = Vector2(LIST_W, LIST_H)
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)
	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_content.draw.connect(_draw_rows)
	_clip.add_child(_content)

func setup(data: Dictionary, palette: Dictionary) -> void:
	_data = data
	# Prefer the palette the EXPORT carries: it is Qud's own colorFromChar table and is
	# always present, whereas the snapshot-fed one can still be empty here — and the
	# client's built-in fallback disagrees with Qud on 'w' (a dark orange where Qud has
	# a khaki), which was enough to repaint every item on the paper doll.
	var pal := palette
	if pal.is_empty():
		pal = data.get("palette", {})
	_palette = pal
	# Qud persists the enabled filter set with the save, so adopt ITS set rather than
	# starting from "*All" — otherwise the strip's colours can never match a save that
	# was left with a category filtered on.
	if data.has("enabledFilters"):
		_enabled.clear()
		for n in data["enabledFilters"]:
			# "*All" is Qud's name for the no-category-filter button; carrying it into
			# the set would filter the list against a category no item has, emptying it
			_enabled[str(n)] = true
		_enabled.erase("*All")
	if not pal.is_empty():
		_tiles.palette = pal
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	_relayout()
	_static.queue_redraw()

## Flatten categories+items into rows and assign Qud's hotkey spread (skipping the
## letters Qud reserves for commands).
func _relayout() -> void:
	_rows.clear()
	var li := 0
	for cat in _data.get("categories", []):
		var cname := str(cat.get("name", ""))
		if not _enabled.is_empty() and not _enabled.has(cname):
			continue                      # filtered out by the strip
		var collapsed: bool = bool(_collapsed.get(cname, false))
		_rows.append({"kind": "cat", "name": cname, "weight": int(cat.get("weight", 0)),
			"count": int(cat.get("count", 0)), "collapsed": collapsed, "letter": _letter(li)})
		li += 1
		if collapsed:
			continue
		for it in cat.get("items", []):
			var row := {"kind": "item", "letter": _letter(li)}
			row.merge(it)
			_rows.append(row)
			li += 1
	_sel = clampi(_sel, 0, maxi(0, _rows.size() - 1))
	_content.size = Vector2(LIST_W, maxf(LIST_H, _rows.size() * ROW_H + 8.0))
	_content.queue_redraw()

func _letter(i: int) -> String:
	var n := 0
	for c in LETTERS:
		if c in RESERVED:
			continue
		if n == i:
			return c
		n += 1
	return " "

func _draw_static() -> void:
	if _data.is_empty():
		return
	_draw_doll()
	_draw_filter_strip()
	# header: "{{B|$drams}} | {{C|carried{{K|/max}} lbs.}}" — Qud's own strings
	var hdr := "{{B|$%d}} {{K|│}} {{C|%d{{K|/%d}} lbs.}}" % [int(_data.get("drams", 0)),
		int(_data.get("carried", 0)), int(_data.get("maxCarried", 0))]
	# Right-aligned on Qud's edge at the pane's body size. MEASURED, unresolved: Qud's
	# block spans x1548..1753 (205px) and y220..249 while ours renders 160px wide at
	# 16px; drawing it at 20px matches the left edge but the glyphs still don't line
	# up (band diff 13.3 -> 16.0), so the size alone isn't the difference — likely a
	# different face/tracking for this header. Left at the better-scoring form.
	var w := _font.get_string_size(QudText.strip(hdr), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	_draw_markup(_static, hdr, Vector2(ITEM_W_EDGE - w, 232))

## Qud's filter cell: a 2px box whose TOP-LEFT and BOTTOM-RIGHT corners carry the
## interlocking loop motif (measured off the reference — a 7x7 loop, a 2px stem and a
## bar, with the box edge broken where the ornament sits). Same family as the frames
## on the Attributes pane.
## The texture's opaque bounding box (cached): what Qud scales to fill an icon slot.
var _opaque_cache := {}

func _opaque_rect(tex: Texture2D) -> Rect2:
	var key := tex.get_rid().get_id()
	if _opaque_cache.has(key):
		return _opaque_cache[key]
	var rect := Rect2(Vector2.ZERO, tex.get_size())
	var img := tex.get_image()
	if img != null:
		var x0 := img.get_width()
		var y0 := img.get_height()
		var x1 := -1
		var y1 := -1
		for yy in img.get_height():
			for xx in img.get_width():
				if img.get_pixel(xx, yy).a > 0.0:
					x0 = mini(x0, xx); y0 = mini(y0, yy)
					x1 = maxi(x1, xx); y1 = maxi(y1, yy)
		if x1 >= x0 and y1 >= y0:
			rect = Rect2(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	_opaque_cache[key] = rect
	return rect

## Qud's OWN frame sprite, nine-sliced. The mod exports `polat-category-frame`
## (46x41, Unity 9-slice borders l12 b11 r13 t12) to title/cell_frame.png, so the
## corners are Qud's pixels and only the middles stretch — which is how one design
## serves both the 50x41 filter cells and the 55x62 doll slots. Falls back to the
## hand-drawn motif if the sprite hasn't been exported yet.
const FRAME_BORDER := {"left": 12, "bottom": 11, "right": 13, "top": 12}
var _frame_tex: Texture2D = null
var _frame_tried := false

func _frame_texture() -> Texture2D:
	if _frame_tried:
		return _frame_tex
	_frame_tried = true
	var path := InputModel.support_dir().path_join("title").path_join("cell_frame.png")
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == 0:
			_frame_tex = ImageTexture.create_from_image(QudChrome.brighten(img))
	return _frame_tex

## Draw the sprite as a nine-patch by hand: corners 1:1, edges stretched along one
## axis, centre skipped (the cell interior stays transparent).
func _draw_cell_frame(r: Rect2, col: Color, knob := true) -> void:
	# The teal stub on the bottom line is NOT part of the sprite (its alpha mask has
	# nothing there) — Qud paints it over the frame, and only on the filter cells;
	# the paper-doll boxes use the same sprite without it. Measured at cell-relative
	# (21,38), 4x3, in C_HOVER's teal on every category cell.
	if knob:
		_static.draw_rect(Rect2(r.position + Vector2(21, 38), Vector2(4, 3)), C_HOVER)
	var tex := _frame_texture()
	if tex == null:
		_draw_cell_frame_fallback(r, col, knob)
		return
	var tw := tex.get_width()
	var th := tex.get_height()
	var l: int = FRAME_BORDER["left"]
	var rr: int = FRAME_BORDER["right"]
	var t: int = FRAME_BORDER["top"]
	var bo: int = FRAME_BORDER["bottom"]
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	var mid_w := maxf(0.0, w - l - rr)
	var mid_h := maxf(0.0, h - t - bo)
	var src_mid_w := maxf(1.0, tw - l - rr)
	var src_mid_h := maxf(1.0, th - t - bo)
	# corners
	_static.draw_texture_rect_region(tex, Rect2(x, y, l, t), Rect2(0, 0, l, t), col)
	_static.draw_texture_rect_region(tex, Rect2(x + w - rr, y, rr, t), Rect2(tw - rr, 0, rr, t), col)
	_static.draw_texture_rect_region(tex, Rect2(x, y + h - bo, l, bo), Rect2(0, th - bo, l, bo), col)
	_static.draw_texture_rect_region(tex, Rect2(x + w - rr, y + h - bo, rr, bo),
		Rect2(tw - rr, th - bo, rr, bo), col)
	# edges — THESE are the runs that stretch
	_static.draw_texture_rect_region(tex, Rect2(x + l, y, mid_w, t), Rect2(l, 0, src_mid_w, t), col)
	_static.draw_texture_rect_region(tex, Rect2(x + l, y + h - bo, mid_w, bo),
		Rect2(l, th - bo, src_mid_w, bo), col)
	_static.draw_texture_rect_region(tex, Rect2(x, y + t, l, mid_h), Rect2(0, t, l, src_mid_h), col)
	_static.draw_texture_rect_region(tex, Rect2(x + w - rr, y + t, rr, mid_h),
		Rect2(tw - rr, t, rr, src_mid_h), col)

func _draw_cell_frame_fallback(r: Rect2, col: Color, knob := true) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_static.draw_rect(Rect2(x, y, w, 2), col)
	_static.draw_rect(Rect2(x, y + h - 2, w, 2), col)
	_static.draw_rect(Rect2(x, y, 2, h), col)
	_static.draw_rect(Rect2(x + w - 2, y, 2, h), col)
	if knob:
		_static.draw_rect(Rect2(x + w * 0.5 - 2, y + h - 4, 5, 5), C_HOVER)

## Qud's LIVE colour for a filter cell, when the export carries one.
##
## Preferred over deriving it, because the derivation is not derivable: LateUpdate
## paints the four states only ON CHANGE, so a button nobody ever toggled keeps its
## prefab colour and one that has been keeps #134F4E -- which of those a given cell
## shows depends on the save's whole interaction history. Modelling that produced a
## strip where every cell was ~8 off and the enabled one was on the wrong index.
func _filt_live(hex: String) -> Variant:
	if hex == "":
		return null
	return Color(hex)

## The four-way state colour, Qud's law verbatim (fallback when no live colour rides
## along -- an older mod build, or a screen whose buttons are not loaded).
func _filt_color(on: bool, focused: bool) -> Color:
	if on:
		return C_FILT_ON_SEL if focused else C_FILT_ON
	return C_HOVER if focused else C_BOX

## Qud's category filter strip: the ALL cell then one per category, each showing
## that category's first item as its icon. Selecting a filter is a later slice —
## this draws the strip Qud shows above the panes.
func _draw_filter_strip() -> void:
	var cats: Array = _data.get("categories", [])
	_filt_rects.clear()
	var x := FILT_X
	# the ALL cell — gold-framed while no category filter is enabled (Qud's "*All")
	var all_rect := Rect2(Vector2(x, FILT_Y), Vector2(FILT_W, FILT_H))
	_filt_rects.append([all_rect, ""])   # placeholder replaced below; keeps index 0 stable
	_filt_rects.pop_back()
	# Qud's OWN colour for this cell when the export carries it (see _filt_live).
	var all_live: Variant = _filt_live(str(_data.get("allColor", "")))
	if _filt_hover == 0:
		_draw_cell_frame(all_rect, C_HOVER)
	elif all_live != null:
		_draw_cell_frame(all_rect, all_live)
	elif _enabled.is_empty():
		_draw_cell_frame(all_rect, _filt_color(true, false))
	else:
		_draw_cell_frame(all_rect, C_ALL_OFF)
	_filt_rects.append([all_rect, ""])
	var aw := _font.get_string_size("ALL", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	_static.draw_string(_font, Vector2(x + (FILT_W - aw) * 0.5, FILT_Y + 25), "ALL",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_GOLD if _enabled.is_empty() else C_LABEL)
	x += FILT_PITCH
	# strip order is QUD'S (filterOrder: category of the alphabetically-first item),
	# which differs from the list's alphabetical category order
	var order: Array = _data.get("filterOrder", [])
	var by_name := {}
	for c in cats:
		by_name[str(c.get("name", ""))] = c
	var strip: Array = []
	for ent in order:
		var nm := str(ent.get("name", "")) if ent is Dictionary else str(ent)
		var cell: Dictionary = (by_name[nm] as Dictionary).duplicate() if by_name.has(nm) else {"name": nm}
		# an equipped-only category (Clothes) has no list entry — take Qud's icon
		if ent is Dictionary and str(ent.get("icon", "")) != "":
			cell["icon"] = str(ent["icon"])
		# ...and its LIVE frame colour, which likewise rides on the filterOrder entry:
		# `cell` is copied from the category list, which has no such field, so without
		# this the strip silently kept deriving the colour it was meant to stop deriving
		if ent is Dictionary and str(ent.get("color", "")) != "":
			cell["color"] = str(ent["color"])
		strip.append(cell)
	if strip.is_empty():
		strip = cats
	for cat in strip:
		var cname := str(cat.get("name", ""))
		var rect := Rect2(Vector2(x, FILT_Y), Vector2(FILT_W, FILT_H))
		var live: Variant = _filt_live(str(cat.get("color", "")))
		if _filt_hover == _filt_rects.size():
			_draw_cell_frame(rect, C_HOVER)          # hover is ours to render, live or not
		elif live != null:
			_draw_cell_frame(rect, live)
		else:
			_draw_cell_frame(rect, _filt_color(_enabled.has(cname), false))
		_filt_rects.append([rect, cname])
		# QUD'S OWN filter icon (FilterBarCategoryButton.categoryImageMap), painted in
		# the fixed two-tone that button uses; falls back to the category's first item.
		var icon := str(cat.get("icon", ""))
		var main := Color(0.596, 0.529, 0.372)
		var det := Color(0.545, 0.4, 0.18)
		var items: Array = cat.get("items", [])
		if icon == "" and items.size() > 0:
			var it: Dictionary = items[0]
			icon = str(it.get("tile", ""))
			main = _tiles.color_of(str(it.get("color", "")), Color.WHITE)
			det = _tiles.color_of(str(it.get("detail", "")), Color.WHITE)
		if icon != "":
			var tex: Texture2D = _tiles.texture(icon, main, det)
			if tex != null:
				# GROUND TRUTH, read off a live FilterBarCategoryButton rather than
				# fitted to sample bboxes: icon.image's RectTransform is 20x30, centred
				# (anchors and pivot all 0.5), preserveAspect FALSE, type Simple, over a
				# 16x24 sprite. So Qud stretches the WHOLE tile 1.25x -- it never looks
				# at the opaque sub-rect, which is why normalising to the opaque box (the
				# previous three attempts here) made small art too big and wide art too
				# narrow. The earlier "every icon is exactly 15 tall" that motivated
				# those attempts was an artefact of the ink threshold: the icon's dimmer
				# rows sit in the same 20-60 band as the scrim behind the cell.
				var iw := 20.0
				var ih := 30.0
				_static.draw_texture_rect(tex,
					Rect2(Vector2(x + (FILT_W - iw) * 0.5, FILT_Y + (FILT_H - ih) * 0.5),
						Vector2(iw, ih)), false)
		x += FILT_PITCH

## Qud's body-slot grid. Slots it doesn't recognise are ignored — the doll is a
## FIXED layout in Qud too (extra parts show in the list, not the doll).
func _draw_doll() -> void:
	var by_label := {}
	for sl in _data.get("slots", []):
		by_label[_doll_label(sl)] = sl
	for label in DOLL:
		var cell: Array = DOLL[label]
		var pos := Vector2(cell[0], cell[1])
		_draw_cell_frame(Rect2(pos, Vector2(BOX_W, BOX_H)), C_BOX, false)
		var sl: Variant = by_label.get(label)
		if sl != null:
			var tile := str(sl.get("tile", ""))
			if tile != "":
				# The doll uses the ITEM'S OWN two-tone, not the filter bar's fixed one:
				# EquipmentLine calls icon.FromRenderable(RenderForUI("Equipment")), and
				# FromRenderable does SetColors(colorFromChar(foreground),
				# colorFromChar(detail), background). The earlier "same fixed two-tone as
				# the filter bar" reading came from band averages taken while the sprite
				# was still the wrong SIZE — with the geometry wrong, any palette can be
				# made to look closer.
				# Prefer the RESOLVED chars the mod now sends ("fg"/"dt", straight out of
				# getColorChars()) over the raw ColorString: ColorString loses to TileColor
				# when an object sets one, so deriving the tone client-side was guesswork
				# that came out right for some items and wrong for others.
				var fg := str(sl.get("fg", ""))
				var dt := str(sl.get("dt", ""))
				var tex: Texture2D = _tiles.texture(tile,
					_tiles.color_of(fg if fg != "" else str(sl.get("color", "")), Color.WHITE),
					_tiles.color_of(dt if dt != "" else str(sl.get("detail", "")),
						Color(0.545, 0.4, 0.18)))
				if tex != null:
					# GROUND TRUTH from a live EquipmentLine: icon.image's RectTransform is
					# 20x30 centred (anchors+pivot 0.5) with localScale 2, preserveAspect
					# FALSE — so the whole 16x24 tile is drawn at 40x60, centred in the
					# 64x64 slot. Same law as the filter bar, only twice the size; every
					# earlier number here was fitted to ink measurements instead.
					var dw := 40.0
					var dh := 60.0
					# Centred, full stop. A +1 nudge in x makes the ink BBOXES line up with
					# Qud's exactly and yet triples the pixel diff (16 -> 52): the bbox
					# disagreement is a one-column dim edge, and chasing it moves the whole
					# sprite off the alignment that actually matters. Bbox is a diagnostic,
					# not the objective.
					# +0.5 in x is a RASTERISATION phase, not a position fix: 16 source px
					# into 40 makes every source pixel 2.5 wide, so each one lands on 2 or
					# 3 destination columns depending on which side of the half-pixel the
					# boundary falls. Unity and Godot break that tie differently, and half
					# a pixel is exactly the offset that realigns the runs. Measured: doll
					# images 8.63 -> 4.28, with two slots going pixel-identical. (A FULL
					# pixel, tried first, made the bboxes agree and TRIPLED the diff.)
					var at := pos + Vector2((BOX_W - dw) * 0.5 + 0.5, (BOX_H - dh) * 0.5)
					# FromRenderable also applies the renderable's flips; a negative rect
					# size is how Godot mirrors a draw_texture_rect
					if bool(sl.get("hflip", false)):
						at.x += dw
						dw = -dw
					_static.draw_texture_rect(tex, Rect2(at, Vector2(dw, dh)), false)
		# Label, centred under the box and wrapped like Qud ("Worn on / Hands"). The
		# primary-limb marker is NOT a separate glyph parked to the left of the cell:
		# EquipmentLine.setData builds ONE string, "{{G|*}}" + the cardinal description,
		# so the star wraps and centres WITH the text. Ours sat at a fixed offset, which
		# is why a short first line ran over it ("Left Hand" put the L on the star). It
		# is green too -- {{G|}} -- where we had gold.
		var primary := sl != null and bool(sl.get("primary", false))
		var lines := _wrap_label(("* " if primary else "") + label)
		for i in lines.size():
			var w := _font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			var at := pos + Vector2((BOX_W - w) * 0.5, BOX_H + 16 + i * 15)
			if i == 0 and primary:
				var sw := _font.get_string_size("* ", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
				_static.draw_string(_font, at, "* ",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _star_color())
				_static.draw_string(_font, at + Vector2(sw, 0), lines[i].substr(2),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_LABEL)
			else:
				_static.draw_string(_font, at, lines[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_LABEL)

## Qud's {{G|}} green for the primary-limb star, out of the real palette.
func _star_color() -> Color:
	return _tiles.color_of("G", Color(0.0, 0.8, 0.35))

## Map an exported body part to its doll cell label. Qud's part names come through
## LOWERCASE ("left hand", "worn on back"), so match case-insensitively and rebuild
## the grid label from the part TYPE plus its side.
func _doll_label(sl: Dictionary) -> String:
	var n := str(sl.get("name", "")).strip_edges().to_lower()
	var t := str(sl.get("type", "")).strip_edges().to_lower()
	var side := ""
	if n.begins_with("left"):
		side = "Left "
	elif n.begins_with("right"):
		side = "Right "
	match t:
		"hand":            return side + "Hand"
		"arm":             return side + "Arm"
		"missile weapon":  return side + "Missile Weapon"
		"hands":           return "Worn on Hands"
		"back":            return "Worn on Back"
		"body":            return "Body"
		"head":            return "Head"
		"face":            return "Face"
		"feet":            return "Feet"
		"floating nearby": return "Floating Nearby"
		"thrown weapon":   return "Thrown Weapon"
	# fall back to the part's own name, title-cased to match the grid keys
	var out := ""
	for w in n.split(" "):
		out += (w.capitalize() if out == "" else " " + w.capitalize())
	return out

func _wrap_label(s: String) -> Array:
	if _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x <= BOX_W + 26:
		return [s]
	var out: Array = []
	var cur := ""
	for w in s.split(" "):
		var cand := w if cur == "" else cur + " " + w
		if _font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x <= BOX_W + 26 or cur == "":
			cur = cand
		else:
			out.append(cur)
			cur = w
	if cur != "":
		out.append(cur)
	return out

func _draw_rows() -> void:
	var off := -_scroll
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var y: float = i * ROW_H + off
		if y + ROW_H < 0 or y > LIST_H:
			continue
		if i == _sel:
			_content.draw_rect(Rect2(0, y, LIST_W - 4, ROW_H - 2), C_SEL)
		# +17, not +16: at ROW_FONT the ink sits a pixel higher than Qud's otherwise
		var base := y + 16.0
		# hotkey letter column, then the row itself
		_content.draw_string(_font, Vector2(LETTER_X - LIST_X, base), "%s)" % r["letter"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, ITEM_FONT, C_HOTKEY)
		if str(r["kind"]) == "cat":
			# MEASURED: Qud's '[' starts at x880 (the bracket group runs 880..899), so the
			# gap after "a)" is real. At NAME_X-40 (869) our '[' landed ON the ')'.
			_content.draw_string(_font, Vector2(NAME_X - LIST_X - 34, base),
				"[+]" if bool(r["collapsed"]) else "[-]",
				HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_CAT)
			# MEASURED: a category name's first glyph starts at x920 in Qud (item names
			# start at 928, after the icon) -- NAME_X alone was fitted to the item rows.
			# no markup: Qud passes the raw category name and lets the prefab colour it
			_content.draw_string(_font, Vector2(918.0 - LIST_X, base), str(r["name"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_CAT)
			var cw := "|%d lbs.|" % int(r["weight"])
			# the weight column is part of the CATEGORY row's style -- same colour and the
			# same size as its name (measured: Qud's ink is 20px tall and 96px wide here,
			# where ITEM_FONT gave us 16 and 69)
			var cww := _font.get_string_size(cw, HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT).x
			# +7: right-aligning on CAT_W_EDGE puts the ink edge at 1666 because the
			# trailing '|' carries a right bearing; Qud's ink reaches 1673
			_content.draw_string(_font, Vector2(CAT_W_EDGE + 7.0 - LIST_X - cww, base), cw,
				HORIZONTAL_ALIGNMENT_LEFT, -1, ROW_FONT, C_CAT)
		else:
			# MEASURED in Qud: the row icon spans x905..925, so its 20-wide box starts at
			# 905 and is centred on the row (30 tall over a 26px row -- it overflows a
			# little, as Qud's does, its pivot being the vertical middle).
			_draw_tile(r, Vector2(905.0 - LIST_X, y + (ROW_H - 30.0) * 0.5))
			_draw_markup(_content, str(r.get("name", "")), Vector2(926.0 - LIST_X, base))
			var iw := "[%d lbs.]" % int(r.get("weight", 0))
			var iww := _font.get_string_size(iw, HORIZONTAL_ALIGNMENT_LEFT, -1, ITEM_FONT).x
			_content.draw_string(_font, Vector2(ITEM_W_EDGE - LIST_X - iww, base), iw,
				HORIZONTAL_ALIGNMENT_LEFT, -1, ITEM_FONT, C_ITEM_W)

func _draw_markup(target: CanvasItem, s: String, pos: Vector2) -> void:
	_draw_markup_sized(target, s, pos, ITEM_FONT)

## The colour an unmarked run of an item name falls back to (InventoryLine.text).
func _item_default() -> Color:
	return C_ITEM

func _draw_markup_sized(target: CanvasItem, s: String, pos: Vector2, size: int) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, _item_default()):
		var txt: String = run[0]
		if txt == "":
			continue
		target.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x

func _draw_tile(r: Dictionary, pos: Vector2) -> void:
	var tile := str(r.get("tile", ""))
	if tile == "":
		return
	var tex: Texture2D = _tiles.texture(tile,
		_tiles.color_of(str(r.get("color", "")), Color.WHITE),
		_tiles.color_of(str(r.get("detail", "")), Color.WHITE))
	if tex != null:
		# Same law as the filter bar and the doll: InventoryLine.icon's RectTransform is
		# 20x30 (left-anchored, pivot 0.5, preserveAspect FALSE) over a 16x24 sprite, so
		# the WHOLE tile is drawn at 20x30. We had it at 13x19.
		_content.draw_texture_rect(tex, Rect2(pos, Vector2(20, 30)), false)

# ── input ──────────────────────────────────────────────────────────────────────

func handle_key(e: InputEventKey) -> bool:
	if _rows.is_empty():
		return false
	match e.keycode:
		KEY_UP, KEY_KP_8:   _move(-1)
		KEY_DOWN, KEY_KP_2: _move(1)
		KEY_PAGEUP:         _move(-12)
		KEY_PAGEDOWN:       _move(12)
		KEY_LEFT, KEY_KP_4, KEY_RIGHT, KEY_KP_6:
			_toggle_category()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activate()
		_:                  return false
	return true

## Accept the selected row: a category folds, an ITEM opens Qud's interaction popup.
##
## Nothing here builds a menu. Qud's screen answers a selection with
## EquipmentAPI.TwiddleObject, which raises the option list, applies the choice and runs
## any follow-on prompts itself -- and our popup mirror already forwards Qud's modals to
## Raves. So we ask Qud to twiddle and the real menu arrives over that channel, with the
## right verbs for the item and the right side effects. Reloading afterwards catches what
## the action changed (an item eaten, equipped, dropped).
func _activate() -> void:
	if _rows.is_empty() or _sel >= _rows.size():
		return
	var r: Dictionary = _rows[_sel]
	if str(r.get("kind", "")) == "cat":
		_toggle_category()
		return
	var id := str(r.get("id", ""))
	if id == "" or not bridge_cb.is_valid():
		return
	bridge_cb.call({"type": "command", "name": "invaction", "id": id})
	if reload_cb.is_valid():
		for delay in [0.6, 1.5, 3.0, 5.0]:
			get_tree().create_timer(delay).timeout.connect(func(): reload_cb.call())

## Collapse/expand the selected category (an item row toggles its own category),
## mirroring the skills tree's model. View state only — Qud keeps its own per-screen.
func _toggle_category() -> void:
	if _rows.is_empty():
		return
	var i := _sel
	while i > 0 and str(_rows[i]["kind"]) != "cat":
		i -= 1
	if str(_rows[i]["kind"]) != "cat":
		return
	var cname := str(_rows[i]["name"])
	_collapsed[cname] = not bool(_collapsed.get(cname, false))
	_sel = i
	_relayout()

func _move(d: int) -> void:
	_sel = clampi(_sel + d, 0, _rows.size() - 1)
	var top := _sel * ROW_H - _scroll
	if top < 0:
		_scroll = _sel * ROW_H
	elif top + ROW_H > LIST_H:
		_scroll = _sel * ROW_H + ROW_H - LIST_H
	_content.queue_redraw()

func handle_mouse(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		# Qud brightens a filter cell's frame while the cursor is over it
		var was := _filt_hover
		_filt_hover = -1
		for i in _filt_rects.size():
			if (_filt_rects[i][0] as Rect2).has_point(e.position):
				_filt_hover = i
				break
		if _filt_hover != was:
			_static.queue_redraw()
		return
	if not (e is InputEventMouseButton and e.pressed):
		return
	if e.button_index == MOUSE_BUTTON_WHEEL_UP:
		_scroll = maxf(0.0, _scroll - ROW_H * 2)
		_content.queue_redraw()
		return
	if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_scroll = clampf(_scroll + ROW_H * 2, 0.0, maxf(0.0, _rows.size() * ROW_H - LIST_H))
		_content.queue_redraw()
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	# filter strip first: ALL clears the filter, a category toggles in/out of the
	# enabled set (Qud's enabledCategories); an empty set means "*All"
	for entry in _filt_rects:
		if (entry[0] as Rect2).has_point(e.position):
			var cname := str(entry[1])
			if cname == "":
				_enabled.clear()
			elif _enabled.has(cname):
				_enabled.erase(cname)
			else:
				_enabled[cname] = true
			_sel = 0
			_scroll = 0.0
			_relayout()
			_static.queue_redraw()
			return
	if e.position.x < LIST_X or e.position.x > LIST_X + LIST_W \
			or e.position.y < LIST_Y or e.position.y > LIST_Y + LIST_H:
		return
	var idx := int(floor((e.position.y - LIST_Y + _scroll) / ROW_H))
	if idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_content.queue_redraw()
	# a click accepts the row, exactly as Enter does (Qud's list does the same)
	_activate()

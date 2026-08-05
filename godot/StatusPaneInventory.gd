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
## The PAPER DOLL (left half) draws Qud's fixed slot grid: 55x62 boxes on columns
## x{283,373,463,553,643} and rows y{246,366,486,606,726} (measured off the same
## capture), each showing its equipped item's tile with the slot label centred
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

# Qud reserves these letters for commands, so the inventory spread skips them
# (measured off the reference: a,b,c,f,g,… — d/e/q/s never appear).
const RESERVED := ["d", "e", "q", "s"]
const LETTERS := "abcdefghijklmnopqrstuvwxyz0123456789"

static func _iv8(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_DIM := _iv8(108, 133, 129)
var C_SEL := _iv8(23, 59, 60)
var C_GOLD := _iv8(200, 184, 57)
var C_BOX := _iv8(70, 96, 100)
var C_LABEL := _iv8(120, 146, 141)

# Qud's paper-doll grid: label -> [column x, row y]. Columns/rows measured off
# equipment_qud.png (55x62 boxes, 90px column pitch, 120px row pitch).
const DOLL := {
	"Face": [463, 246], "Floating Nearby": [643, 246],
	"Worn on Hands": [283, 366], "Head": [463, 366],
	"Left Hand": [283, 486], "Left Arm": [373, 486], "Body": [463, 486],
	"Right Arm": [553, 486], "Right Hand": [643, 486],
	"Worn on Back": [463, 606],
	"Thrown Weapon": [283, 726], "Feet": [463, 726],
	"Left Missile Weapon": [553, 726], "Right Missile Weapon": [643, 726],
}
const BOX_W := 55.0
const BOX_H := 62.0

# Category FILTER STRIP (Qud's FilterBar): "*All" plus one cell per category
# present in the inventory, measured off the reference — 44x38 cells from x620,
# 58px pitch, on y178. Qud draws a fixed per-category ICON; we stand in with the
# category's first item tile (recorded deviation) until those icons are extracted.
const FILT_X := 560.0   # ALL cell; category cells then start at 618 (measured borders)
const FILT_Y := 177.0
const FILT_W := 50.0   # measured: cell cols 618..667
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
	_content.draw.connect(_draw_rows)
	_clip.add_child(_content)

func setup(data: Dictionary, palette: Dictionary) -> void:
	_data = data
	_palette = palette
	if not palette.is_empty():
		_tiles.palette = palette
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
func _draw_cell_frame(r: Rect2, col: Color) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	# box edges, broken at the two ornamented corners
	_static.draw_rect(Rect2(x + 9, y, w - 9, 2), col)          # top (gap at TL)
	_static.draw_rect(Rect2(x, y + h - 2, w - 9, 2), col)      # bottom (gap at BR)
	_static.draw_rect(Rect2(x, y + 9, 2, h - 9), col)          # left (gap at TL)
	_static.draw_rect(Rect2(x + w - 2, y, 2, h - 9), col)      # right (gap at BR)
	# top-left loop: 7x7 outline + stem + bar
	_static.draw_rect(Rect2(x, y, 7, 2), col)
	_static.draw_rect(Rect2(x, y, 2, 7), col)
	_static.draw_rect(Rect2(x + 5, y, 2, 7), col)
	_static.draw_rect(Rect2(x, y + 5, 11, 2), col)
	_static.draw_rect(Rect2(x + 5, y + 7, 2, 2), col)
	_static.draw_rect(Rect2(x, y + 9, 7, 2), col)
	# bottom-right loop, mirrored
	var bx := x + w - 7
	var by := y + h - 11
	_static.draw_rect(Rect2(bx, by, 7, 2), col)
	_static.draw_rect(Rect2(bx, by + 2, 2, 2), col)
	_static.draw_rect(Rect2(bx - 4, by + 4, 11, 2), col)
	_static.draw_rect(Rect2(bx, by + 4, 2, 7), col)
	_static.draw_rect(Rect2(bx + 5, by + 4, 2, 7), col)
	_static.draw_rect(Rect2(bx, by + 9, 7, 2), col)

## Qud's category filter strip: the ALL cell then one per category, each showing
## that category's first item as its icon. Selecting a filter is a later slice —
## this draws the strip Qud shows above the panes.
func _draw_filter_strip() -> void:
	var cats: Array = _data.get("categories", [])
	_filt_rects.clear()
	var x := FILT_X
	# the ALL cell — gold-framed while no category filter is enabled (Qud's "*All")
	var all_rect := Rect2(Vector2(x, FILT_Y), Vector2(FILT_W, FILT_H))
	_draw_cell_frame(all_rect, C_GOLD if _enabled.is_empty() else C_BOX)
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
		strip.append(cell)
	if strip.is_empty():
		strip = cats
	for cat in strip:
		var cname := str(cat.get("name", ""))
		var rect := Rect2(Vector2(x, FILT_Y), Vector2(FILT_W, FILT_H))
		_draw_cell_frame(rect, C_GOLD if _enabled.has(cname) else C_BOX)
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
				# MEASURED: Qud's icons fill ~x+14..x+31 by y+9..y+31 of the cell (its
				# sprites are 16x24 drawn at ~1.5x); ours were ~8x8 of ink — too small,
				# which read as a tint difference in the band average even though the
				# two-tone itself already matched to 1/255.
				# MEASURED and left alone: the two-tone already matches Qud to 1/255
				# (141,124,84 / 128,91,41 vs our 140,123,83 / 127,91,40), so "tint" was
				# never the problem. What differs is INK COVERAGE — Qud's icon ink spans
				# ~18x23 in a cell where ours spans ~13x13, i.e. we're drawing a sprite
				# whose opaque area is smaller, not one tinted differently. Enlarging the
				# draw rect (26x26, then an aspect-correct 18x27) made the band WORSE
				# (11.53 -> 11.89 / 11.61), so the sprite itself differs per cell — chase
				# WHICH sprite each cell gets, not its size or colour.
				_static.draw_texture_rect(tex,
					Rect2(Vector2(x + 13, FILT_Y + 6), Vector2(18, 26)), false)
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
		_static.draw_rect(Rect2(pos, Vector2(BOX_W, BOX_H)), C_BOX, false, 1.0)
		var sl: Variant = by_label.get(label)
		if sl != null:
			var tile := str(sl.get("tile", ""))
			if tile != "":
				var tex: Texture2D = _tiles.texture(tile,
					_tiles.color_of(str(sl.get("color", "")), Color.WHITE),
					_tiles.color_of(str(sl.get("detail", "")), Color.WHITE))
				if tex != null:
					# MEASURED, not guessed: Qud's equipped-item ink spans ~47x48 inside the
					# 55x62 slot (bark armor 47x48, torch 47x45, boots 47x43) where ours
					# spanned 22x25 — the sprite nearly fills the cell rather than sitting
					# small in the middle.
					_static.draw_texture_rect(tex,
						Rect2(pos + Vector2(4, 6), Vector2(47, 50)), false)
			if bool(sl.get("primary", false)):
				_static.draw_string(_font, pos + Vector2(-8, BOX_H + 14), "*",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_GOLD)
		# label, centred under the box and wrapped like Qud ("Worn on / Hands")
		var lines := _wrap_label(label)
		for i in lines.size():
			var w := _font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			_static.draw_string(_font, pos + Vector2((BOX_W - w) * 0.5, BOX_H + 16 + i * 15),
				lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_LABEL)

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
		var base := y + 16.0
		# hotkey letter column, then the row itself
		_content.draw_string(_font, Vector2(LETTER_X - LIST_X, base), "%s)" % r["letter"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_DIM)
		if str(r["kind"]) == "cat":
			_content.draw_string(_font, Vector2(NAME_X - LIST_X - 40, base),
				"[+]" if bool(r["collapsed"]) else "[-]", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_DIM)
			_draw_markup(_content, "{{c|%s}}" % r["name"], Vector2(NAME_X - LIST_X, base))
			var cw := "|%d lbs.|" % int(r["weight"])
			var cww := _font.get_string_size(cw, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			_content.draw_string(_font, Vector2(CAT_W_EDGE - LIST_X - cww, base), cw,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_DIM)
		else:
			_draw_tile(r, Vector2(NAME_X - LIST_X - 2, y + 3))
			_draw_markup(_content, str(r.get("name", "")), Vector2(NAME_X - LIST_X + 16, base))
			var iw := "[%d lbs.]" % int(r.get("weight", 0))
			var iww := _font.get_string_size(iw, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			_content.draw_string(_font, Vector2(ITEM_W_EDGE - LIST_X - iww, base), iw,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_DIM)

func _draw_markup(target: CanvasItem, s: String, pos: Vector2) -> void:
	_draw_markup_sized(target, s, pos, 16)

func _draw_markup_sized(target: CanvasItem, s: String, pos: Vector2, size: int) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, C_DIM):
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
		_content.draw_texture_rect(tex, Rect2(pos, Vector2(13, 19)), false)

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
		_:                  return false
	return true

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
	if str(_rows[idx]["kind"]) == "cat":
		_toggle_category()

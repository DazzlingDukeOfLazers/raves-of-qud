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
## The PAPER DOLL (left half: body slots) is the next slice — this round is the
## inventory list the user asked for.

const ROW_H := 26.0
const LIST_X := 855.0
const LIST_Y := 240.0
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

var _data := {}
var _palette := {}
var _tiles: RefCounted = null
var _rows: Array = []       # flattened: {kind, name, weight, tile…, letter}
var _sel := 0
var _scroll := 0.0
var _collapsed := {}        # category name -> true when collapsed (Raves-side view state)
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
	# header: "{{B|$drams}} | {{C|carried{{K|/max}} lbs.}}" — Qud's own strings
	var hdr := "{{B|$%d}} {{K|│}} {{C|%d{{K|/%d}} lbs.}}" % [int(_data.get("drams", 0)),
		int(_data.get("carried", 0)), int(_data.get("maxCarried", 0))]
	var w := _font.get_string_size(QudText.strip(hdr), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	_draw_markup(_static, hdr, Vector2(ITEM_W_EDGE - w, 234))

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
	var x := pos.x
	for run in QudText.runs(s, _palette, C_DIM):
		var txt: String = run[0]
		if txt == "":
			continue
		target.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x

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

extends Control

## The REPUTATION tab's faction list, mirroring Qud.UI.FactionsStatusScreen + FactionsLine.setData.
##
## Geometry is Qud's own, read off the live RectTransforms with the mod's UiProbe:
##
##   viewport   x=174.5 y=177 w=1580 h=760
##   header     h=30: caret x=174.5 w=15 | expander x=189.5 w=30 f=24
##              rep indicator x=227 y=+6.5 22x17 | name x=253.5 f=16
##              "Reputation: N" x=823.5 f=14
##   details    y=+36 h=80: emblem x=261.5 y=+10 40x60 | feeling x=361.5 w=220 f=14
##              divider x=588.5 w=7 | rank x=602.5 w=200 f=14
##              divider x=809.5 w=7 | secret x=823.5 w=931 f=14
##   rows are separated by 8px
##
## DRAWN ON A CANVAS, not built from nodes. There are ~98 visible factions; a RichTextLabel per
## field would be ~500 Controls, and StatusPaneSkills already established draw_string + QudText.runs
## for exactly this reason (its note: "far too many nodes"). Qud virtualises its own list.
##
## Every string is Qud's: feeling/rank/secret and the formatted reputation come from the game's own
## helpers via FactionsExporter, so the rank wording and reputation thresholds stay the game's.

const VIEW_X := 174.5
const VIEW_Y := 177.0
const VIEW_W := 1580.0
const VIEW_H := 760.0

const HEAD_H := 30.0
const CARET_X := 174.5
const EXP_X := 189.5
const EXP_FONT := 24
const IND_X := 227.0
const IND_DY := 6.5
const IND_W := 22.0
const IND_H := 17.0
const NAME_X := 253.5
const NAME_FONT := 16
const REP_X := 823.5
const REP_FONT := 14

const DET_DY := 36.0
const DET_H := 80.0
const ICON_X := 261.5
const ICON_DY := 10.0
const ICON_W := 40.0
const ICON_H := 60.0
const T1_X := 361.5
const T1_W := 220.0
const DIV1_X := 588.5
const T2_X := 602.5
const T2_W := 200.0
const DIV2_X := 809.5
const T3_X := 823.5
const T3_W := 931.0
const DET_FONT := 14
const DIV_W := 7.0
const ROW_GAP := 8.0
const SECRET_WRAP := 60   # FactionsLine.setData: detailsText3.blockWrap = 60 CHARACTERS

const C_TEXT := Color8(0xaf, 0xc6, 0xc1)
const C_GOLD := Color8(0xcf, 0xc0, 0x41)
const C_DIV := Color8(0x2c, 0x4a, 0x50)

var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

var _factions: Array = []
var _palette := {}
var _sel := 0
var _scroll := 0.0
var _expanded := {}          # id -> bool; Qud starts every faction expanded
var _font: Font
var _tiles: RefCounted = null
var _content: Control

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_font = UiFont.make_theme(get_viewport()).default_font
	_tiles = load("res://QudTiles.gd").new()
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	_content = Control.new()
	_content.position = Vector2(0, VIEW_Y)
	_content.size = Vector2(1920, VIEW_H)
	_content.clip_contents = true          # the list is longer than the viewport
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.draw.connect(_draw_rows)
	add_child(_content)
	queue_redraw()

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	if _tiles != null:
		_tiles.palette = _palette
	_factions = data.get("factions", [])
	for f in _factions:
		var id := str(f.get("id", ""))
		if not _expanded.has(id):
			_expanded[id] = true       # Qud's default: expanded unless collapsed by the player
	_sel = clampi(_sel, 0, maxi(0, _factions.size() - 1))
	if _content != null:
		_content.queue_redraw()

func _row_h(f: Dictionary) -> float:
	return HEAD_H + (DET_DY - HEAD_H + DET_H if bool(_expanded.get(str(f.get("id", "")), true)) else 0.0)

func _draw_rows() -> void:
	if _font == null:
		return
	var y := -_scroll
	for i in _factions.size():
		var f: Dictionary = _factions[i]
		var h := _row_h(f)
		if y + h >= 0.0 and y <= VIEW_H:     # only draw what's on screen
			_draw_row(f, i, y)
		y += h + ROW_GAP
		if y > VIEW_H:
			break

func _draw_row(f: Dictionary, i: int, y: float) -> void:
	var open := bool(_expanded.get(str(f.get("id", "")), true))
	if i == _sel:
		_content.draw_string(_font, Vector2(CARET_X, y + 21), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT, C_GOLD)
	_content.draw_string(_font, Vector2(EXP_X + 9, y + 23), "-" if open else "+",
		HORIZONTAL_ALIGNMENT_LEFT, -1, EXP_FONT, C_TEXT)

	# The reputation INDICATOR is a solid bar in the rep's own colour (Reputation.GetColor).
	var ind := QudText.color_of_code(str(f.get("repColor", "y")), _palette, C_TEXT)
	_content.draw_rect(Rect2(IND_X, y + IND_DY, IND_W, IND_H), ind)

	_draw_markup(str(f.get("label", "")), Vector2(NAME_X, y + 21), NAME_FONT)
	_draw_markup("Reputation: " + str(f.get("repText", "")), Vector2(REP_X, y + 20), REP_FONT)

	if not open:
		return
	var dy := y + DET_DY
	var tex: Texture2D = _tiles.texture_for(f, true)
	if tex != null:
		_content.draw_texture_rect(tex, Rect2(ICON_X, dy + ICON_DY, ICON_W, ICON_H), false)
	_content.draw_rect(Rect2(DIV1_X, dy, DIV_W, DET_H), C_DIV)
	_content.draw_rect(Rect2(DIV2_X, dy, DIV_W, DET_H), C_DIV)
	_wrapped(str(f.get("feeling", "")), T1_X, dy, T1_W)
	_wrapped(str(f.get("rank", "")), T2_X, dy, T2_W)
	# The secret column is the odd one out: its RectTransform is 931 wide but setData sets
	# detailsText3.blockWrap = 60, i.e. Qud wraps it by CHARACTER COUNT, not by the box. Wrapping
	# it to the box gave two long lines where Qud has four.
	_wrapped(str(f.get("secret", "")), T3_X, dy, T3_W, SECRET_WRAP)

## Word-wrap plain text and draw it line by line. `chars` wraps by character count (Qud's blockWrap)
## when > 0; otherwise the column's pixel width is used.
func _wrapped(s: String, x: float, y: float, w: float, chars := 0) -> void:
	var plain := QudText.strip(s).replace("\n", " ").strip_edges()
	if plain == "":
		return
	var line := ""
	var ly := y + 14.0
	for word in plain.split(" ", false):
		var probe := word if line == "" else line + " " + word
		var over := (probe.length() > chars) if chars > 0 \
			else (_font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, DET_FONT).x > w)
		if over:
			_content.draw_string(_font, Vector2(x, ly), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, DET_FONT, C_TEXT)
			ly += 16.0
			line = word
			if ly > y + DET_H:
				return   # clipped like Qud's fixed-height details box
		else:
			line = probe
	if line != "":
		_content.draw_string(_font, Vector2(x, ly), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, DET_FONT, C_TEXT)

func _draw_markup(s: String, pos: Vector2, px: int) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, C_TEXT):
		var txt: String = run[0]
		if txt == "":
			continue
		_content.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x

## Called by StatusScreens for wheel/click while this tab is up.
func handle_mouse(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll = minf(_scroll + 60.0, maxf(0.0, _total_h() - VIEW_H))
			_content.queue_redraw()
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll = maxf(_scroll - 60.0, 0.0)
			_content.queue_redraw()

func _total_h() -> float:
	var t := 0.0
	for f in _factions:
		t += _row_h(f) + ROW_GAP
	return t

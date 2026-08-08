extends Control

## The TINKERING tab, mirroring Qud.UI.TinkeringStatusScreen's build view + bit locker.
##
## Geometry is Qud's own, read off the live RectTransforms with the mod's UiProbe:
##
##   mode hint    x=192.1 y=222 font 14   ("[Ctrl+Tab] switch to modifications")
##   recipes      DataScroller x=158.5 y=230 w=623; rows x=174.5 w=607
##                category text x=192.5 font 18, then padding 8 and a dotted leader to x=781
##   bits         BitsScroller x=1361.5 y=230 w=400; rows 20.1 tall
##                swatch x=1361.5 +2.6 15x15 | label x=1384.5 font 16 | count RIGHT-aligned at 1745.5
##
## The COUNT is a right-aligned COLUMN, not a value trailing its label. Qud's Number box starts
## where the label's box ends (1384.5 + 9.6*len -- these rows are monospace, confirmed on all
## twelve: 201.61/21, 144.01/15, 124.80/13 ... every one exactly 9.600) and stretches with flex 1,
## so every box ends at the SAME 1745.5 and its text is right-aligned there. Reading 201.61 as a
## fixed label box and drawing the count at its end gave a ragged column jammed against the labels,
## with the long ones ("A scrap power systems5") abutting the digits.
##
## The bit LABEL is Qud's: UpdateBitlocker composes "{{Color|<char> <Description>}}" where the char
## comes from CharTranslateBit (A B C D 1..8 under the AlphanumericBits option) -- NOT the colour
## char. The mod ships both, and this draws the label.
##
## BOTH MODES are here. Ctrl+Tab toggles, as Qud's own hint says. Modifications is the inverse
## shape of build: a category row per MOD RECIPE, and beneath it every inventory/equipped item the
## mod applies to, each with ITS OWN cost (the cost depends on the object being modified).

const HINT_X := 192.1
const HINT_Y := 222.0
const HINT_FONT := 14
## Qud's Ctrl keycap, a Private Use Area codepoint it draws from its own icon font
## (QudText.GLYPHS maps the same value). Present in the extracted atlas as a 195x133 cell,
## so this renders as the real keycap once the mod has exported the glyphs.
const CTRL_GLYPH := 0xE816
const LIST_X := 174.5
const LIST_Y := 246.0
const LIST_W := 607.0
const CAT_X := 192.5
const CAT_FONT := 18
const LEADER_END := 781.5
const ROW_H := 22.6

const BITS_X := 1361.5
const BITS_Y := 246.0
const BITS_W := 400.0
const BIT_ROW_H := 20.1
const SWATCH := 15.0
const BIT_LABEL_X := 1384.5
const BIT_NUM_RIGHT := 1745.5      # every Number box ENDS here; the count is right-aligned to it
const BIT_FONT := 16

const C_TEXT := Color8(0xaf, 0xc6, 0xc1)
const C_DIM := Color8(0x3b, 0x55, 0x5e)
const C_GOLD := Color8(0xcf, 0xc0, 0x41)

var bridge_cb: Callable = Callable()
var reload_cb: Callable = Callable()

var _cats: Array = []
var _mods: Array = []
var _mode := 0          # 0 = build, 1 = modifications (Qud's CurrentCategory)
var _bits: Array = []
var _empty := ""
var _palette := {}
var _sel := 0
var _font: Font
var _content: Control

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_font = UiFont.make_theme(get_viewport()).default_font
	_content = Control.new()
	_content.size = Vector2(1920, 940)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.draw.connect(_draw_all)
	add_child(_content)

func setup(data: Dictionary, palette: Dictionary) -> void:
	_palette = palette
	var own: Dictionary = data.get("palette", {})
	if typeof(own) == TYPE_DICTIONARY and not own.is_empty():
		_palette = own
	_cats = data.get("categories", [])
	_mods = data.get("mods", [])
	_bits = data.get("bits", [])
	_empty = str(data.get("empty", ""))
	_sel = 0
	if _content != null:
		_content.queue_redraw()

func _draw_all() -> void:
	if _font == null:
		return
	# Qud's own hint string, with the Ctrl keycap glyph it emits (U+E816 — the extracted icon
	# font renders it; QudText falls back to the word when that font is missing).
	#
	# The glyph was MISSING and only this comment said otherwise: the literal read
	# "[{{W|+Tab}}]", so Raves drew "[+Tab]" against Qud's "[Ctrl+Tab]" for as long as the
	# screen has existed. Caught by a parity leaf, not by reading the code — the comment
	# described the intent convincingly enough that the string beside it looked right.
	# The codepoint has to be built, not typed, or it is invisible in the source too.
	_draw_markup("[{{W|%s+Tab}}] switch to %s"
			% [String.chr(CTRL_GLYPH), "build" if _mode == 1 else "modifications"],
		Vector2(HINT_X, HINT_Y + 13.0), HINT_FONT)

	var y := LIST_Y
	if _mode == 1:
		_draw_mods(y)
	elif _cats.is_empty():
		# Qud's empty state is a CATEGORY row: text + padding + the leader, with a caret.
		_draw_cat_row(_empty, y, true)
	else:
		for ci in _cats.size():
			var c: Dictionary = _cats[ci]
			_draw_cat_row("[-] %s [%d]" % [str(c.get("name", "")), int(c.get("count", 0))],
				y, ci == 0)
			y += ROW_H
			for it in c.get("items", []):
				# setData: "    " + DisplayName + " [" + costString + "]"
				_draw_markup("    %s [%s]" % [str(it.get("name", "")), str(it.get("cost", ""))],
					Vector2(CAT_X, y + 16.0), CAT_FONT)
				y += ROW_H

	# --- the bit locker, right-hand panel
	var by := BITS_Y
	for b in _bits:
		# NO COLOUR SWATCH. The probe shows a 15x15 Image at the row's left, but it draws nothing
		# in Qud — the colour lives in the TEXT, not a filled block. Painting one put a square in
		# front of every row that Qud doesn't have.
		# BitType.Description CARRIES MARKUP ("{{R|scrap power systems}}"), so it has to go through
		# the markup renderer — draw_string printed the braces verbatim.
		# No clip: Qud's label box is sized to its own text, so it cannot reach the count column
		# (the longest bit label is 22 chars = 211.2px, ending 150px clear of it).
		_draw_markup("%s %s" % [str(b.get("label", "")), str(b.get("desc", ""))],
			Vector2(BIT_LABEL_X, by + 15.0), BIT_FONT)
		# int(): JSON numbers reach GDScript as FLOATS, so a bare str() renders "0.0".
		#
		# THE COUNT IS DIM, not body text. TinkeringBitsLine.setData colours it by the ACTIVE COST:
		# "{{K|n}}" when there is no active cost or this bit costs nothing for the selected recipe,
		# "{{G|n}}" when you hold enough for it, "{{R|n}}" when you do not. Raves has no recipe
		# selection yet, so every row is the K branch -- which is what Qud draws in the same state.
		# Rendered through the markup path so the colour comes from Qud's shipped palette.
		var cnt := "%d" % int(b.get("count", 0))
		var cw := _font.get_string_size(cnt, HORIZONTAL_ALIGNMENT_LEFT, -1, BIT_FONT).x
		_draw_markup("{{K|%s}}" % cnt, Vector2(BIT_NUM_RIGHT - cw, by + 15.0), BIT_FONT)
		by += BIT_ROW_H

func _draw_cat_row(s: String, y: float, caret: bool) -> void:
	if caret:
		_content.draw_string(_font, Vector2(LIST_X, y + 17.0), ">",
			HORIZONTAL_ALIGNMENT_LEFT, -1, CAT_FONT, C_GOLD)
	_draw_markup(s, Vector2(CAT_X, y + 17.0), CAT_FONT)
	var w := _font.get_string_size(QudText.strip(s), HORIZONTAL_ALIGNMENT_LEFT, -1, CAT_FONT).x
	var lx := CAT_X + w + 8.0
	while lx < LEADER_END:
		_content.draw_rect(Rect2(lx, y + 11.0, 2.0, 1.0), C_DIM)
		lx += 6.0

## Draw Qud markup as coloured runs. `stop_x` clips the line so a long label can't run under
## the next column — Qud gives the bit label a fixed 201.6-wide box and lets it truncate.
func _draw_markup(s: String, pos: Vector2, px: int, stop_x := 0.0) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette, C_TEXT):
		var txt: String = run[0]
		if txt == "":
			continue
		if stop_x > 0.0 and x >= stop_x:
			return
		_content.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1],
			int(stop_x - x) if stop_x > 0.0 else -1)
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x


## MODIFICATIONS view: a row per mod recipe, then every item it can be applied to.
func _draw_mods(y: float) -> void:
	if _mods.is_empty():
		_draw_cat_row("You don't have any modifications.", y, true)
		return
	for mi in _mods.size():
		var m: Dictionary = _mods[mi]
		_draw_cat_row("[-] %s [%d]" % [str(m.get("name", "")), int(m.get("count", 0))], y, mi == 0)
		y += ROW_H
		var items: Array = m.get("items", [])
		if items.is_empty():
			# setData's own string for a mod with nothing to apply to.
			_draw_markup("    %s" % str(m.get("empty", "<no applicable items>")),
				Vector2(CAT_X, y + 16.0), CAT_FONT)
			y += ROW_H
		for it in items:
			# setData: "    " + modObject.DisplayName + " [" + costString + "]"
			_draw_markup("    %s [%s]" % [str(it.get("name", "")), str(it.get("cost", ""))],
				Vector2(CAT_X, y + 16.0), CAT_FONT)
			y += ROW_H

## Ctrl+Tab toggles build <-> modifications, which is what Qud's own hint advertises.
func handle_key(e: InputEventKey) -> bool:
	if e.keycode == KEY_TAB and (e.ctrl_pressed or e.meta_pressed):
		_mode = 1 - _mode
		_content.queue_redraw()
		return true
	return false

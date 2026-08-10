extends Control

## SKILLS & POWERS — the status screens' skill-tree tab, 1:1.
##
## Data: mod SkillsExporter -> skills.json, which carries QUD'S OWN markup per row
## (SPNode.ModernUIText for powers, SkillsAndPowersLine.setData's left/right strings
## for categories). This pane therefore contains NO colour or cost logic — it lays
## the strings out and resolves {{...}} through the palette, exactly like the other
## panes. Geometry measured off reports/2026-08-04-status-screens/skills_qud.png:
## header stat strip at (190,192) + "Skill Points (SP): n" at (806,192); tree rows
## 24px pitch from y229, category rows at x196 (cursor) / x210 ([-]) / x245 (icon) /
## x268 (name) with the right column at x934; detail pane icon at (1409,280) 112x150,
## title + learned banner centred ~x1465, description from (1218,562).
##
## INTERACTIVE (2026-08-04): Space accepts a row and Left/Right collapse/expand a
## category — Qud's own model (Accept -> SkillsAndPowersScreen.SelectNode, which owns
## the purchase flow and its popups; the X axis toggles Expand). Both ride the bridge
## `skill` command with the node's index in QUD'S list, and the pane reloads from the
## re-exported skills.json.

const ROW_H := 24.0
const LIST_X := 190.0
const LIST_Y := 229.0
const LIST_W := 1000.0
const LIST_H := 700.0
const RIGHT_EDGE := 1135.0   # Qud RIGHT-aligns the category column here
const DETAIL_X := 1218.0

static func _sk8(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_HEAD := _sk8(108, 133, 129)      # header strip + SP label
# Qud's chrome tint is authored #4d6e7a (uiprobe imgColor on every HLine/VBorder and the
# divider), which its compositing lands at (68,99,111) on screen — measured 2026-08-10.
var C_RULE := _sk8(68, 99, 111)
var C_GOLD := _sk8(200, 184, 57)
var C_SEL := _sk8(23, 59, 60)
# The header's own colours, from the live screen's text markup (uiprobe statBlock/SP):
# labels {{g}}, values AND the ■ separators {{K}}, the SP count {{C}}. Literal hexes as
# fallbacks so a pane built before the palette lands still shows Qud's colours.
var C_LAB := Color("#009403")          # attribute labels (palette g)
var C_VAL := Color("#155352")          # values + separators (palette K)
var C_SPV := Color("#77bfcf")          # the SP count (palette C)
var C_SPT := Color("#b1c9c3")          # "Skill Points (SP): " (palette y)

var _data := {}
var _palette := {}
var _tiles: RefCounted = null
var _rows: Array = []          # visible nodes (Qud's own order, collapsed ones dropped)
var _sel := 0
var _scroll := 0.0
var _clip: Control
var _content: Control
var _static: Control
var _detail_icon: TextureRect
var _detail_title: RichTextLabel
var _detail_learned: RichTextLabel
var _detail_desc: RichTextLabel
var _detail_req: RichTextLabel
var _font: Font
var _portrait: Texture2D = null        # the player tile, 2x, left of the stat strip (Qud's Icon)
var _knob_tex: Texture2D = null        # divider endcap diamond (deco_knob.png)
var _deco_tex: Texture2D = null        # divider centre emblem (skills_divider.png)
var bridge_cb: Callable = Callable()   # StatusScreens: send a bridge command
var reload_cb: Callable = Callable()   # StatusScreens: re-read skills.json

## StatusScreens hands over the portrait it already builds from character.json (the same
## texture the attributes tab and the tab-bar icon use). May arrive after setup — redraw.
func set_portrait(t: Texture2D) -> void:
	if t == _portrait:
		return
	_portrait = t
	if _static != null:
		_static.queue_redraw()

func _ready() -> void:
	name = "SkillsPane"
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

	# detail pane (right column)
	_detail_icon = TextureRect.new()
	_detail_icon.position = Vector2(1409, 280)
	_detail_icon.size = Vector2(112, 150)
	_detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_detail_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_detail_icon)
	_detail_title = _mk_label(Vector2(DETAIL_X, 462), 530, 26, true)
	_detail_learned = _mk_label(Vector2(DETAIL_X, 496), 530, 18, true)
	_detail_req = _mk_label(Vector2(DETAIL_X, 524), 530, 16, true)
	_detail_desc = _mk_label(Vector2(DETAIL_X, 562), 530, 16, false)

func _mk_label(pos: Vector2, w: int, size: int, centred: bool) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.position = pos
	rt.size = Vector2(w, 0)
	rt.custom_minimum_size = Vector2(w, 0)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_font_size_override("normal_font_size", size)
	rt.add_theme_color_override("default_color", C_HEAD)
	if centred:
		rt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(rt)
	return rt

## Feed from StatusScreens: the parsed skills.json + the snapshot palette.
func setup(data: Dictionary, palette: Dictionary) -> void:
	_data = data
	_palette = palette
	if not palette.is_empty():
		_tiles.palette = palette
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	# Divider chrome, off Qud's own sprites. NOT latched: the files appear on the first
	# `export` after the skills screen has existed in Qud, so keep retrying while null.
	if _knob_tex == null:
		_knob_tex = _chrome_png("deco_knob.png")
	if _deco_tex == null:
		_deco_tex = _chrome_png("skills_divider.png")
	_relayout()
	_static.queue_redraw()
	_refresh_detail()

static func _chrome_png(fname: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	# brighten: the raw sprite drawn 1:1 lands ~6/255 dim of Qud's capture, the same
	# correction every other exported chrome gets (QudFilterBar.frame_texture).
	return ImageTexture.create_from_image(QudChrome.brighten(img))

## Qud hides the powers of a collapsed category; its own `visible` flag says which.
func _relayout() -> void:
	_rows.clear()
	for n in _data.get("nodes", []):
		if bool(n.get("visible", true)):
			_rows.append(n)
	_sel = clampi(_sel, 0, maxi(0, _rows.size() - 1))
	_content.size = Vector2(LIST_W, maxf(LIST_H, _rows.size() * ROW_H + 8.0))
	_content.queue_redraw()

func _draw_static() -> void:
	if _data.is_empty():
		return
	# HEADER, from Qud's own layout model (uiprobe SkillsAndPowersStatusScreen, 2026-08-10):
	#   HLine (174.5,184.5) 32x1 · Icon (214.5,161) 32x48 · statBlock CENTRED in a 480px
	#   box at x258.5, font 12 · HLine (746.5,184.5) 32x1 · SP CENTRED in a 230px box at
	#   x786.5, font 16 · one long HLine 1024.5..1745.5. The old header was a left-aligned
	#   sketch of a 2026-08-04 capture: everything at font 15 in one colour, which Source
	#   Code Pro rasterises RAGGED at that off-size — the feedback's "weird distortions".
	#   Colours are the screen's own markup: labels {{g}}, values + ■ separators {{K}},
	#   the SP count {{C}} — and Qud's quirk that ONLY the first label keeps its colon in
	#   the label span ("STR:20" tight, "AGI: 18" spaced) is the markup's, kept verbatim.
	var st: Dictionary = _data.get("stats", {})
	var runs: Array = []
	var keys := ["STR", "AGI", "TOU", "INT", "WIL", "EGO"]
	for i in keys.size():
		var k: String = keys[i]
		if i == 0:
			runs.append(["%s:" % k, C_LAB])
			runs.append(["%d" % int(st.get(k, 0)), C_VAL])
		else:
			runs.append([k, C_LAB])
			runs.append([": %d" % int(st.get(k, 0)), C_VAL])
		if i < keys.size() - 1:
			runs.append([" ■ ", C_VAL])
	var total := 0.0
	for r in runs:
		total += _font.get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var hx := 258.5 + (480.0 - total) * 0.5
	var hy := 180.46 + _font.get_ascent(12)
	for r in runs:
		_static.draw_string(_font, Vector2(hx, hy).round(), r[0],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, r[1])
		hx += _font.get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	if _portrait != null:
		# rounded destination — a fractional blit BLENDS in Godot (docs/gotchas.md)
		_static.draw_texture_rect(_portrait, Rect2(Vector2(214.5, 161).round(), Vector2(32, 48)), false)
	var sp_runs := [["Skill Points (SP): ", C_SPT], ["%d" % int(_data.get("sp", 0)), C_SPV]]
	var sp_w := 0.0
	for r in sp_runs:
		sp_w += _font.get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var sx := 786.5 + (230.0 - sp_w) * 0.5
	for r in sp_runs:
		_static.draw_string(_font, Vector2(sx, 190).round(), r[0],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, r[1])
		sx += _font.get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	for seg in [[174.0, 32.0], [746.0, 32.0], [1024.0, 721.0]]:
		_static.draw_rect(Rect2(seg[0], 184, seg[1], 1), C_RULE)
	# THE TREE|DETAIL DIVIDER, Qud's own model (uiprobe): two 1px lines at x1181,
	# y205..504 and y626..925; a 7x7 diamond knob capping each FAR end (overlaying the
	# line's first/last pixels); and the 40x122 polat-vertical-divider-decoration emblem
	# — the tree/sword with its dot-triangles — bridging the y504..626 gap. Qud tints
	# the LINES #4d6e7a and leaves the sprites untinted. Until both sprites have been
	# exported (mod `export` after the skills screen exists), a plain full-height line
	# stands in — visibly wrong rather than half-dressed.
	if _knob_tex != null and _deco_tex != null:
		_static.draw_rect(Rect2(1181, 205, 1, 299), C_RULE)
		_static.draw_rect(Rect2(1181, 626, 1, 299), C_RULE)
		_static.draw_texture_rect(_knob_tex, Rect2(1178, 205, 7, 7), false)
		_static.draw_texture_rect(_knob_tex, Rect2(1178, 918, 7, 7), false)
		_static.draw_texture_rect(_deco_tex, Rect2(1161, 504, 40, 122), false)
	else:
		_static.draw_rect(Rect2(1181, 205, 1, 720), C_RULE)

func _draw_rows() -> void:
	var off := -_scroll
	for i in _rows.size():
		var n: Dictionary = _rows[i]
		var y: float = i * ROW_H + off
		if y + ROW_H < 0 or y > LIST_H:
			continue
		if i == _sel:
			_content.draw_rect(Rect2(0, y, LIST_W - 4, ROW_H - 2), C_SEL)
			_content.draw_string(_font, Vector2(6, y + 15), ">", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GOLD)
		var is_skill := str(n.get("kind", "")) == "skill"
		if is_skill:
			# "[-] " expander, icon, then Qud's own coloured name + right column
			_content.draw_string(_font, Vector2(20, y + 15),
				"[-]" if bool(n.get("expand", false)) else "[+]",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_HEAD)
			_draw_icon(n, Vector2(55, y + 1))
			_draw_markup(str(n.get("left", n.get("name", ""))), Vector2(78, y + 15))
			var rtxt := str(n.get("right", ""))
			var rw := _font.get_string_size(QudText.strip(rtxt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			_draw_markup(rtxt, Vector2(RIGHT_EDGE - LIST_X - rw, y + 15))
		else:
			_draw_markup(str(n.get("text", "")), Vector2(20, y + 15))

## Draw Qud markup as coloured runs on the canvas (the rows are far too many for a
## RichTextLabel each — this keeps the whole tree to one draw pass).
func _draw_markup(s: String, pos: Vector2) -> void:
	var x := pos.x
	for run in QudText.runs(s, _palette):
		var txt: String = run[0]
		if txt == "":
			continue
		_content.draw_string(_font, Vector2(x, pos.y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, run[1])
		x += _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x

func _draw_icon(n: Dictionary, pos: Vector2) -> void:
	var tile := str(n.get("iconTile", ""))
	if tile == "":
		return
	var tex: Texture2D = _tiles.texture(tile,
		_tiles.color_of(str(n.get("iconColor", "")), Color.WHITE),
		_tiles.color_of(str(n.get("iconDetail", "")), Color.WHITE))
	if tex != null:
		_content.draw_texture_rect(tex, Rect2(pos, Vector2(14, 21)), false)

func _refresh_detail() -> void:
	if _rows.is_empty():
		return
	var n: Dictionary = _rows[clampi(_sel, 0, _rows.size() - 1)]
	_detail_title.text = "[center]%s[/center]" % QudText.to_bbcode(str(n.get("name", "")), _palette)
	# Qud's banner: [Learned] green / [Unlearned] red (white when partial)
	var ls := str(n.get("learned", "None"))
	var banner := "{{G|[Learned]}}" if ls == "Learned" else ("{{W|[Unlearned]}}" if ls == "Partial" else "{{R|[Unlearned]}}")
	_detail_learned.text = "[center]%s[/center]" % QudText.to_bbcode(banner, _palette)
	_detail_req.text = "[center]%s[/center]" % QudText.to_bbcode(str(n.get("detail", "")), _palette)
	_detail_desc.text = QudText.to_bbcode(str(n.get("desc", "")), _palette)
	var tile := str(n.get("iconTile", ""))
	_detail_icon.texture = null
	if tile != "":
		_detail_icon.texture = _tiles.texture(tile,
			_tiles.color_of(str(n.get("iconColor", "")), Color.WHITE),
			_tiles.color_of(str(n.get("iconDetail", "")), Color.WHITE))

# ── input (navigation only; learning comes with the interactivity pass) ─────────

func handle_key(e: InputEventKey) -> bool:
	if _rows.is_empty():
		return false
	match e.keycode:
		KEY_UP, KEY_KP_8:   _move(-1)
		KEY_DOWN, KEY_KP_2: _move(1)
		KEY_PAGEUP:         _move(-12)
		KEY_PAGEDOWN:       _move(12)
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_send("accept")
		KEY_LEFT, KEY_KP_4, KEY_RIGHT, KEY_KP_6:
			_send("toggle")
		_:                  return false
	return true

## Fire Qud's own accept / expand for the selected row, then poll for the refresh
## (an accept may raise a mirrored popup first, so retry a few times).
func _send(mode: String) -> void:
	if _rows.is_empty() or _sel >= _rows.size():
		return
	var idx := int(_rows[_sel].get("idx", -1))
	if idx < 0:
		return
	if reload_cb.is_valid():
		bridge_cb.call({"type": "command", "name": "skill", "index": str(idx), "mode": mode})
		for delay in [0.6, 1.5, 3.0, 5.0]:
			get_tree().create_timer(delay).timeout.connect(func(): reload_cb.call())

func _move(d: int) -> void:
	_sel = clampi(_sel + d, 0, _rows.size() - 1)
	var top := _sel * ROW_H - _scroll
	if top < 0:
		_scroll = _sel * ROW_H
	elif top + ROW_H > LIST_H:
		_scroll = _sel * ROW_H + ROW_H - LIST_H
	_content.queue_redraw()
	_refresh_detail()

## Mouse comes from StatusScreens' modal root (a canvas-drawn pane has no per-row
## Controls to hit-test, and the root's STOP filter owns the events).
func handle_mouse(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
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
		_refresh_detail()
		# Qud's own mouse model (SkillsAndPowersLine): the [+]/[-] expander toggles the
		# category; a BODY click toggles it too when the skill is already LEARNED, and
		# otherwise accepts (which opens Qud's buy confirm — misclicks are protected).
		var n: Dictionary = _rows[idx]
		var is_skill := str(n.get("kind", "")) == "skill"
		var on_expander: bool = e.position.x >= LIST_X + 14 and e.position.x <= LIST_X + 50
		if is_skill and (on_expander or str(n.get("learned", "")) == "Learned"):
			_send("toggle")
		elif not on_expander:
			_send("accept")

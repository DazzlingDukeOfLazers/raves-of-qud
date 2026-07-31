extends Control

## CHARACTER CREATION — stage 0: GAME MODE, rebuilt to mirror Qud's actual ":choose game mode:"
## screen (QudGamemodeModuleWindow), measured off a 1920x1080 capture.
##
## Layout (frameless, on Qud's dark ground — NOT the framed-panel mock):
##   • top-left: a module icon + "Choose Game Mode"
##   • left edge: a "‹" page-back arrow + "[Esc] Back"; right edge: a dim "›" + "[9] Next"
##   • centre column, row by row: the character-creation emblem, "character creation" (gold),
##     ":choose game mode:" (teal), then a HORIZONTAL ROW OF CARDS (Tutorial/Classic/Roleplay/
##     Wander/Daily) — each a dashed-border box with an icon, a name, and a hotkey; the SELECTED
##     card gets a gold dashed border, a "›" caret, and brighter text.
##   • below: the selected mode's description, "[R] Randomize Selection", and the nav hint.
##
## Data-driven: reads chargen.json "gameModes" if the mod has slurped them, else the MODES fallback
## (names + descriptions verbatim from Qud's EmbarkModules.xml). Card icons load from the exported
## tiles dir when present (mode "tile"); absent, the card shows just its border + name (WIP).

signal closed
signal chose(mode: String)

# ── palette (measured off the Qud capture) ────────────────────────────────────────
const BG := Color8(0x04, 0x21, 0x20)          # dark ground ~ rgb(4,33,32)
const CC_GOLD := Color8(0xAC, 0xA3, 0x36)     # "character creation" ~ rgb(172,163,54)
const SUB_TEAL := Color8(0x29, 0x73, 0x82)    # ":choose game mode:" ~ rgb(41,115,130)
const MUTED := Color8(0x61, 0x7C, 0x78)       # top-left / description / hint ~ rgb(97,124,120)
const SEL_GOLD := Color8(0xC8, 0xB8, 0x39)    # selected card border + hotkey ~ rgb(200,184,57)
const DIM_BORDER := Color8(0x2C, 0x47, 0x47)  # unselected card border (dim teal)
const NAME_SEL := Color8(0xC5, 0xCE, 0xC6)    # selected mode name (bright)
const NAME_DIM := Color8(0x4E, 0x64, 0x60)    # unselected mode name
const HOTKEY_DIM := Color8(0x6B, 0x66, 0x3A)  # unselected hotkey (dim gold)
# Qud renders the card icons a NEUTRAL grey-teal (not their fg/detail colour codes), brightness
# for selection — measured off the capture: selected figure ~rgb(168,194,187) with ~rgb(21,73,72)
# detail; unselected ~rgb(58,89,101). We bake the SELECTED two-tone into the sprite and modulate
# down for the unselected state (per-channel factor lands rgb(168,194,187) on rgb(58,89,101)).
const ICON_MAIN := Color8(0xA8, 0xC2, 0xBB)     # selected figure ~ rgb(168,194,187)
const ICON_DETAIL := Color8(0x15, 0x49, 0x48)   # detail lines ~ rgb(21,73,72)
const ICON_SEL := Color(1, 1, 1, 1)             # selected: show the baked colours
const ICON_DIM := Color(0.35, 0.47, 0.54, 1.0)  # unselected: dim the baked main to ~rgb(58,89,101)
const DIM := Color(0.55, 0.62, 0.60, 0.35)    # very dim (the "[9] Next" affordance)

## Qud's 16-colour palette for {{code|text}} markup in the descriptions.
const QUD_COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),
}

## Fallback modes — names + descriptions verbatim from Qud's EmbarkModules.xml. `hotkey` matches
## Qud's per-card letter; `desc` keeps Qud's {{c|ù}} bullet markup.
const MODES := [
	{"name": "Tutorial", "display": "Tutorial", "hotkey": "A", "desc": "Learn the basics of Caves of Qud."},
	{"name": "Classic", "display": "Classic", "hotkey": "B", "desc": "Permadeath: lose your character when you die."},
	{"name": "Roleplay", "display": "Roleplay", "hotkey": "C", "desc": "Checkpointing at settlements."},
	{"name": "Wander", "display": "Wander", "hotkey": "D", "desc": "{{c|ù}} Most creatures begin neutral to you.\n{{c|ù}} No XP for killing.\n{{c|ù}} More XP for discoveries and performing the water ritual.\n{{c|ù}} Checkpointing at settlements."},
	{"name": "Daily", "display": "Daily", "hotkey": "E", "desc": "{{c|ù}} One chance with a fixed character and world seed."},
]

var selected := ""

var _modes: Array = []
var _sel := 1                  # default to Classic (Qud's default), like the reference
var _cards: Array = []         # [{border, icon, name, hotkey, caret}]
var _desc: RichTextLabel
var _palette := {}
var _border_tex: ImageTexture
# Bridge: ask the mod to (re)export chargen data so the card icons — Qud's own mode sprites — get
# written, then resolve them into the cards as the tile PNGs land. Data shows from the fallback
# immediately; icons fill in once exported.
var _peer := StreamPeerTCP.new()
var _sent := false
var _resolve_until := 0
var _poll_t := 0.0
var _emblem_rect: TextureRect     # the sheaf emblem (extracted sprite, or the procedural fallback)
var _emblem_extracted := false

func _ready() -> void:
	name = "GameModeScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_modes = _load()
	_sel = clampi(_sel, 0, maxi(0, _modes.size() - 1))

	var bg := ColorRect.new()   # Qud's game-mode screen is a flat dark ground (no cave art)
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	_build_topleft()
	_build_side_nav()
	_build_center()
	_apply_selection()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())   # trigger a fresh export for the icons

func _process(dt: float) -> void:
	_peer.poll()
	if not _sent and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_sent = true
		_send_bridge({"type": "command", "name": "export"})
		_resolve_until = Time.get_ticks_msec() + 6000   # give the mod time to write chargen.json + tiles
	if _resolve_until > 0:
		_poll_t += dt
		if _poll_t >= 0.4:
			_poll_t = 0.0
			_resolve_icons()
		if Time.get_ticks_msec() >= _resolve_until:
			_resolve_until = 0
			_resolve_icons()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

func _send_bridge(msg: Dictionary) -> void:
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF); frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF); frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## Reload the modes from chargen.json (once the mod has written it) and fill any card icon whose
## tile PNG has now been exported. Stops early once every card has its icon.
func _resolve_icons() -> void:
	var latest := _load()
	var all_done := true
	for i in range(mini(_cards.size(), latest.size())):
		var t := str(latest[i].get("tile", ""))
		var card: Dictionary = _cards[i]
		if card["icon"].texture == null:
			if t == "":
				all_done = false
			else:
				var tex := _mode_icon(t)
				if tex != null:
					card["icon"].texture = tex
				else:
					all_done = false
	if not _emblem_extracted:      # swap the real sheaf sprite in once the mod exports it
		var e := _load_emblem()
		if e != null:
			_set_emblem(e)
			_emblem_extracted = true
	if all_done and _emblem_extracted:
		_resolve_until = 0

## Qud's extracted sheaf emblem (title/chargen_emblem.png, written by the mod). Already the right
## muted colour, so it's used as-is. Null until exported.
func _load_emblem() -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chargen_emblem.png")
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Size + centre the emblem rect for a texture, at a fixed display height above the title.
func _set_emblem(tex: Texture2D) -> void:
	if _emblem_rect == null or tex == null:
		return
	var vp := get_viewport_rect().size
	_emblem_rect.texture = tex
	var eh: int = int(vp.y * 0.042)
	var ew: int = int(eh * float(tex.get_width()) / float(tex.get_height()))
	_emblem_rect.position = Vector2((vp.x - ew) * 0.5, vp.y * 0.432 - eh)
	_emblem_rect.size = Vector2(ew, eh)

func _load() -> Array:
	var path := InputModel.support_dir().path_join("chargen.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.get("gameModes", null) is Array and not data["gameModes"].is_empty():
				return data["gameModes"]
	return MODES.duplicate(true)

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── top-left header ───────────────────────────────────────────────────────────────

func _build_topleft() -> void:
	# a small module icon (a filled capsule in a dashed box, like Qud's), then the screen name
	var box := Control.new()
	box.position = Vector2(34, 30)
	box.size = Vector2(40, 42)
	var vp := get_viewport_rect().size
	var bt := _dashed_border_tex(40, 42)
	var b := TextureRect.new()
	b.texture = bt
	b.modulate = MUTED
	b.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(b)
	var cap := ColorRect.new()   # the capsule glyph inside
	cap.color = MUTED
	cap.position = Vector2(13, 9); cap.size = Vector2(14, 24)
	box.add_child(cap)
	add_child(box)
	var t := _text("Choose Game Mode", MUTED, "body")
	t.position = Vector2(86, 38)
	add_child(t)

# ── left / right page nav ─────────────────────────────────────────────────────────

func _build_side_nav() -> void:
	var vp := get_viewport_rect().size
	# LEFT: back arrow + [Esc] Back
	var la := _text("‹", MUTED, "big")
	la.add_theme_font_size_override("font_size", int(vp.y * 0.05))
	la.position = Vector2(vp.x * 0.033, vp.y * 0.485)
	add_child(la)
	var lb := _rich("[color=#%s][lb]Esc[rb] Back[/color]" % MUTED.to_html(false), "caption")
	lb.position = Vector2(vp.x * 0.02, vp.y * 0.525)
	add_child(lb)
	# RIGHT: dim forward arrow + [9] Next (advances to genotype)
	var ra := _text("›", DIM, "big")
	ra.add_theme_font_size_override("font_size", int(vp.y * 0.05))
	ra.position = Vector2(vp.x * 0.955, vp.y * 0.485)
	add_child(ra)
	var rb := _rich("[right][color=#%s][lb]9[rb] Next[/color][/right]" % DIM.to_html(false), "caption")
	rb.position = Vector2(vp.x * 0.90, vp.y * 0.525)
	rb.size = Vector2(vp.x * 0.085, 0)
	add_child(rb)

# ── centre column ───────────────────────────────────────────────────────────────

func _build_center() -> void:
	var vp := get_viewport_rect().size
	# the branching "sheaf" emblem above the title. Prefer Qud's OWN sprite (ChargenHeaderDecoration),
	# extracted from the player's install by the mod like the title art; until that lands, fall back to
	# a procedural take on the same sigil. _resolve_icons swaps the real one in once it's exported.
	var em := TextureRect.new()
	em.stretch_mode = TextureRect.STRETCH_SCALE
	em.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	em.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	em.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(em)
	_emblem_rect = em
	var etex := _load_emblem()
	_emblem_extracted = etex != null
	_set_emblem(etex if etex != null else _emblem_texture(MUTED))
	var cc := _text("character creation", CC_GOLD, "big")
	cc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cc.anchor_left = 0.0; cc.anchor_right = 1.0
	cc.position.y = vp.y * 0.435
	add_child(cc)
	var sub := _text(":choose game mode:", SUB_TEAL, "caption")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_left = 0.0; sub.anchor_right = 1.0
	sub.position.y = vp.y * 0.468
	add_child(sub)

	# the horizontal card row, centred
	var card_w := int(vp.x * 0.049)
	var card_h := int(vp.y * 0.086)
	_border_tex = _dashed_border_tex(card_w, card_h)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(vp.x * 0.014))
	row.anchor_left = 0.0; row.anchor_right = 1.0
	row.position.y = vp.y * 0.5
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	for i in range(_modes.size()):
		row.add_child(_build_card(_modes[i], i, card_w, card_h))

	# description
	_desc = _rich("", "body")
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc.anchor_left = 0.0; _desc.anchor_right = 1.0
	_desc.position.y = vp.y * 0.665
	add_child(_desc)

	# [R] Randomize Selection
	var rnd := _rich("[center][color=#%s][lb]R[rb][/color][color=#%s] Randomize Selection[/color][/center]" % [
		SEL_GOLD.to_html(false), MUTED.to_html(false)], "body")
	rnd.anchor_left = 0.0; rnd.anchor_right = 1.0
	rnd.position.y = vp.y * 0.905
	add_child(rnd)

	# nav hint: [arrow-keys] navigate  [Space] select
	var hint := _rich("", "caption")
	hint.anchor_left = 0.0; hint.anchor_right = 1.0
	hint.position.y = vp.y * 0.965
	var ih := int(round(UiFont.px(get_viewport(), "caption") * 1.15))
	hint.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
	var icon := _nav_icon_texture(ih, SEL_GOLD)
	hint.add_image(icon, icon.get_width(), icon.get_height())
	hint.append_text("[color=#%s] navigate      [/color][color=#%s][lb]Space[rb][/color][color=#%s] select[/color]" % [
		MUTED.to_html(false), SEL_GOLD.to_html(false), MUTED.to_html(false)])
	hint.pop()
	add_child(hint)

func _build_card(m: Dictionary, idx: int, cw: int, ch: int) -> Control:
	# a card = [caret slot] + [ VBox(border-box w/ icon, name, hotkey) ]
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 4)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.mouse_entered.connect(func(): _select(idx))
	cell.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(idx); _confirm())

	var caret := _text("›", SEL_GOLD, "big")   # shows only for the selected card (holds its slot)
	caret.custom_minimum_size = Vector2(12, 0)
	caret.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cell.add_child(caret)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	cell.add_child(col)

	var boxc := Control.new()   # the dashed border box holding the icon
	boxc.custom_minimum_size = Vector2(cw, ch)
	var border := TextureRect.new()
	border.texture = _border_tex
	border.modulate = DIM_BORDER
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boxc.add_child(border)
	var icon := TextureRect.new()   # mode tile if exported; else empty (WIP)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 12; icon.offset_right = -12; icon.offset_top = 10; icon.offset_bottom = -10
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.texture = _mode_icon(str(m.get("tile", "")))
	boxc.add_child(icon)
	col.add_child(boxc)

	var name := _text(str(m.get("display", m.get("name", "?"))), NAME_DIM, "caption")
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.custom_minimum_size = Vector2(cw, 0)
	col.add_child(name)
	var hk := _text("[%s]" % str(m.get("hotkey", "")), HOTKEY_DIM, "caption")
	hk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hk.custom_minimum_size = Vector2(cw, 0)
	col.add_child(hk)

	_cards.append({"border": border, "icon": icon, "name": name, "hotkey": hk, "caret": caret})
	return cell

# ── selection ─────────────────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx < 0 or idx >= _cards.size() or idx == _sel:
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	for i in range(_cards.size()):
		var on: bool = (i == _sel)
		var c: Dictionary = _cards[i]
		c["border"].modulate = SEL_GOLD if on else DIM_BORDER
		c["icon"].modulate = ICON_SEL if on else ICON_DIM
		c["name"].add_theme_color_override("font_color", NAME_SEL if on else NAME_DIM)
		c["hotkey"].add_theme_color_override("font_color", SEL_GOLD if on else HOTKEY_DIM)
		c["caret"].add_theme_color_override("font_color", SEL_GOLD if on else Color(0, 0, 0, 0))
	if _desc != null and _sel >= 0 and _sel < _modes.size():
		var lines := PackedStringArray()
		for line in str(_modes[_sel].get("desc", "")).split("\n", false):
			lines.append(QudText.to_bbcode(line, _palette))
		_desc.text = "[center][color=#%s]%s[/color][/center]" % [MUTED.to_html(false), "\n".join(lines)]

func _randomize() -> void:
	if _modes.size() > 1:
		var n := _sel
		while n == _sel:
			n = randi() % _modes.size()
		_select(n)

func _confirm() -> void:
	if _sel >= 0 and _sel < _modes.size():
		selected = str(_modes[_sel].get("name", ""))
		chose.emit(selected)

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit(); accept_event()
	elif e.is_action_pressed("ui_right"):
		_select(mini(_sel + 1, _cards.size() - 1)); accept_event()
	elif e.is_action_pressed("ui_left"):
		_select(maxi(_sel - 1, 0)); accept_event()
	elif e.is_action_pressed("ui_accept"):
		_confirm(); accept_event()
	elif e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_R:
		_randomize(); accept_event()

# ── helpers ──────────────────────────────────────────────────────────────────

## A dashed rectangle border as a white texture (tint per state via modulate). Qud draws the card
## frames as dashed/dotted lines; short dashes with gaps approximate that "ASCII" look.
func _dashed_border_tex(w: int, h: int) -> ImageTexture:
	var img := Image.create(maxi(2, w), maxi(2, h), false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var th := 2
	var dash := 5
	var gap := 4
	var c := Color(1, 1, 1, 1)
	var x := 0
	while x < w:
		for dx in range(mini(dash, w - x)):
			for t in range(th):
				img.set_pixel(x + dx, t, c)
				img.set_pixel(x + dx, h - 1 - t, c)
		x += dash + gap
	var y := 0
	while y < h:
		for dy in range(mini(dash, h - y)):
			for t in range(th):
				img.set_pixel(t, y + dy, c)
				img.set_pixel(w - 1 - t, y + dy, c)
		y += dash + gap
	return ImageTexture.create_from_image(img)

## Raves' own take on the character-creation "sheaf" sigil: a central stem with a dotted head, three
## fanning branch pairs, and a small base flare — drawn symmetrically at a small native grid (scaled
## up NEAREST for the pixel look). Original art, not Qud's sprite.
func _emblem_texture(color: Color) -> ImageTexture:
	var w := 21
	var h := 24
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := 10
	_line(img, cx, 8, cx, 23, color)            # stem
	for hy in [0, 2, 4, 6]:                      # dotted head
		_plot(img, cx, hy, color)
	# three fanning branch pairs (origin on the stem → up and out), mirrored
	var pairs := [[9, 1, 3], [13, 2, 7], [17, 3, 11]]   # [stem_y, tip_x_left, tip_y]
	for p in pairs:
		_line(img, cx, p[0], p[1], p[2], color)          # left branch
		_line(img, cx, p[0], w - 1 - p[1], p[2], color)  # right branch (mirror)
	_line(img, cx, 23, 6, 19, color)            # base flare (left)
	_line(img, cx, 23, 14, 19, color)           # base flare (right)
	return ImageTexture.create_from_image(img)

func _plot(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
		img.set_pixel(x, y, c)

func _line(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx - dy
	while true:
		_plot(img, x0, y0, c)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x0 += sx
		if e2 < dx:
			err += dx
			y0 += sy

## A small arrow-keys icon (gold d-pad cluster), same construction as MainMenu's hint icon.
func _nav_icon_texture(ih: int, color: Color) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))
	var k := int((ih - g) / 2)
	if k < 2:
		k = 2
	var w := 3 * k + 2 * g
	var h := 2 * k + g
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g
	img.fill_rect(Rect2i(mid, 0, k, k), color)
	img.fill_rect(Rect2i(0, k + g, k, k), color)
	img.fill_rect(Rect2i(mid, k + g, k, k), color)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), color)
	return ImageTexture.create_from_image(img)

## Load a mode's exported tile, recoloured to Qud's grey-teal card look. Qud's sw_*_mode sprites are
## near-black figures on transparent that Qud renders LIGHT; modulate (multiply) can't lighten black.
## Map each opaque pixel by its darkness — dark figure pixels → ICON_MAIN (light teal), bright
## highlight pixels → ICON_DETAIL (dark teal) — so it reads like Qud's two-tone icon; the card's
## modulate then dims it for the unselected state.
func _mode_icon(tile: String) -> Texture2D:
	if tile == "":
		return null
	var fname := tile.replace("/", "_").replace("\\", "_")
	var path := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		if img.load(path) != OK:
			return null
	img.convert(Image.FORMAT_RGBA8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var p := img.get_pixel(x, y)
			if p.a > 0.04:
				var cov: float = 1.0 - (p.r + p.g + p.b) / 3.0   # dark → 1 (main), light → 0 (detail)
				var col := ICON_DETAIL.lerp(ICON_MAIN, cov)
				img.set_pixel(x, y, Color(col.r, col.g, col.b, p.a))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

func _text(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _rich(bb: String, role := "body") -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = bb
	return l

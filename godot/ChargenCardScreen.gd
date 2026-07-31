extends Control

## Reusable CHARACTER-CREATION "card row" screen — the shared template behind Qud's guided chargen
## steps (Choose Game Mode, Choose Genotype, …). One horizontal row of dashed-frame cards on Qud's
## dark ground, with the sheaf emblem + "character creation" + a ":choose …:" subtitle above, the
## selected item's flavour text below, "[R] Randomize Selection", the nav hint, a top-left breadcrumb,
## and left/right page arrows. All the extracted-sprite chrome (frame, emblem, arrows, ornament) and
## the icon-recolour/selection machinery live here; a subclass supplies the DATA + a few strings by
## overriding the hooks in the "SUBCLASS HOOKS" section.

signal closed
signal chose(name: String)          # the confirmed item name (mode / genotype / …)
signal advance_page                 # the "Next" affordance (right arrow / [9]) — subclass decides

# ── palette (measured off Qud captures) ───────────────────────────────────────────
const BG := Color8(0x04, 0x21, 0x20)
const CC_GOLD := Color8(0xAC, 0xA3, 0x36)     # "character creation"
const SUB_TEAL := Color8(0x29, 0x73, 0x82)    # ":choose …:"
const MUTED := Color8(0x61, 0x7C, 0x78)       # breadcrumb / description / hint
const SEL_GOLD := Color8(0xC8, 0xB8, 0x39)    # selected card border + hotkey + caret
const DIM_BORDER := Color8(0x2C, 0x47, 0x47)  # unselected card border
const NAME_SEL := Color8(0xC5, 0xCE, 0xC6)    # selected name
const NAME_DIM := Color8(0x4E, 0x64, 0x60)    # unselected name
const HOTKEY_DIM := Color8(0x6B, 0x66, 0x3A)  # unselected hotkey
const ICON_MAIN := Color8(0xA8, 0xC2, 0xBB)   # neutral (unselected) icon body
const ICON_DETAIL := Color8(0x15, 0x49, 0x48) # neutral icon detail
const ICON_SEL := Color(1, 1, 1, 1)
const ICON_DIM := Color(0.35, 0.47, 0.54, 1.0)
const DIM := Color(0.55, 0.62, 0.60, 0.35)    # very dim ("[9] Next" when disabled)

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

var selected := ""

var _items: Array = []
var _sel := 0
var _cards: Array = []
var _desc: RichTextLabel
var _palette := {}
var _border_tex: ImageTexture
var _peer := StreamPeerTCP.new()
var _sent := false
var _resolve_until := 0
var _poll_t := 0.0
var _emblem_rect: TextureRect
var _emblem_extracted := false
var _frame_tex: Texture2D
var _frame_extracted := false

# ══ SUBCLASS HOOKS — override these ════════════════════════════════════════════════

## Node name (debug/inspection only).
func _screen_node_name() -> String: return "ChargenCardScreen"

## Breadcrumb crumbs shown top-left, left→right, e.g. [{"label": "Choose Game Mode", "current": true}].
func _breadcrumb_crumbs() -> Array: return [{"label": "Choose", "current": true}]

## The ":choose …:" subtitle line under "character creation".
func _subtitle() -> String: return ":choose:"

## The item list: [{name, display, hotkey, tile, desc}], in card order.
func _load_items() -> Array: return []

## Which card is selected on open.
func _default_index() -> int: return 0

## Is the "Next" (page-forward) affordance enabled? Disabled ⇒ drawn very dim, no advance.
func _next_enabled() -> bool: return false

## Build a card's [colored (selected), neutral (unselected)] icon textures from its tile. Default =
## the mode two-tone recolour; the genotype screen keeps native creature colours for `colored`.
func _card_icon(tile: String, item_name: String) -> Dictionary:
	var colored := _recolor_tile(tile, ICON_MAIN, ICON_DETAIL)
	return {"colored": colored, "neutral": colored}

# ══ lifecycle ══════════════════════════════════════════════════════════════════════

func _ready() -> void:
	name = _screen_node_name()
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_items = _load_items()
	_sel = clampi(_default_index(), 0, maxi(0, _items.size() - 1))

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	_build_topleft()
	_build_side_nav()
	_build_center()
	_apply_selection()
	_resolve_icons()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())

func _process(dt: float) -> void:
	_peer.poll()
	if not _sent and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_sent = true
		_send_bridge({"type": "command", "name": "export"})
		_resolve_until = Time.get_ticks_msec() + 6000
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

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ══ icon resolution (async tile export) ════════════════════════════════════════════

func _resolve_icons() -> void:
	var latest := _load_items()
	var all_done := true
	for i in range(mini(_cards.size(), latest.size())):
		if _cards[i].has("colored"):
			continue
		var t := str(latest[i].get("tile", ""))
		if t == "":
			all_done = false
			continue
		var icons := _card_icon(t, str(latest[i].get("name", "")))
		if icons.is_empty() or icons.get("colored") == null:
			all_done = false
			continue
		_cards[i]["colored"] = icons["colored"]
		_cards[i]["neutral"] = icons.get("neutral", icons["colored"])
	_apply_selection()
	if not _frame_extracted:
		var fr := _load_card_frame()
		if fr != null:
			_frame_tex = fr
			_frame_extracted = true
			for c in _cards:
				_apply_card_frame(c["border"])
	if not _emblem_extracted:
		var e := _load_emblem()
		if e != null:
			_set_emblem(e)
			_emblem_extracted = true
	if all_done and _emblem_extracted:
		_resolve_until = 0

# ══ layout: top-left breadcrumb ════════════════════════════════════════════════════

func _build_topleft() -> void:
	var frame := _load_card_frame()
	var x := 30.0
	for crumb in _breadcrumb_crumbs():
		var box := Control.new()
		box.position = Vector2(x, 28)
		box.size = Vector2(44, 46)
		_crumb_frame(box, frame)
		var glyph := Panel.new()   # the filled rounded-rect breadcrumb icon
		var gsb := StyleBoxFlat.new()
		gsb.bg_color = MUTED
		gsb.set_corner_radius_all(3)
		glyph.add_theme_stylebox_override("panel", gsb)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glyph.position = Vector2(14, 11); glyph.size = Vector2(16, 24)
		box.add_child(glyph)
		add_child(box)
		x += 52
		var cur: bool = bool(crumb.get("current", false))
		var t := _text(str(crumb.get("label", "")), NAME_SEL if cur else MUTED, "body")
		t.position = Vector2(x + 6, 40)
		add_child(t)
		x += t.get_theme_font("font").get_string_size(t.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, t.get_theme_font_size("font_size")).x + 22

func _crumb_frame(box: Control, frame: Texture2D) -> void:
	if frame != null:
		var np := NinePatchRect.new()
		np.texture = frame
		var m := int(round(frame.get_height() * 17.0 / 80.0))
		np.patch_margin_left = m; np.patch_margin_right = m
		np.patch_margin_top = m; np.patch_margin_bottom = m
		np.draw_center = false
		np.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		np.modulate = MUTED
		np.set_anchors_preset(Control.PRESET_FULL_RECT)
		np.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(np)
	else:
		var b := TextureRect.new()
		b.texture = _dashed_border_tex(44, 46)
		b.modulate = MUTED
		b.set_anchors_preset(Control.PRESET_FULL_RECT)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(b)

# ══ layout: left/right page nav ════════════════════════════════════════════════════

func _build_side_nav() -> void:
	var vp := get_viewport_rect().size
	var ah: int = int(vp.y * 0.04)
	var la := _make_arrow(true, MUTED, ah)
	la.position = Vector2(vp.x * 0.033, vp.y * 0.485)
	add_child(la)
	var lb := _rich("[color=#%s][lb]Esc[rb] Back[/color]" % MUTED.to_html(false), "caption")
	lb.position = Vector2(vp.x * 0.02, vp.y * 0.525)
	add_child(lb)
	var nxt: bool = _next_enabled()
	var ra := _make_arrow(false, MUTED if nxt else DIM, ah)
	ra.position = Vector2(vp.x * 0.955, vp.y * 0.485)
	add_child(ra)
	var rb := _rich("[right][color=#%s][lb]9[rb] Next[/color][/right]" % (MUTED if nxt else DIM).to_html(false), "caption")
	rb.position = Vector2(vp.x * 0.90, vp.y * 0.525)
	rb.size = Vector2(vp.x * 0.085, 0)
	add_child(rb)

func _make_arrow(left: bool, color: Color, h: int) -> Control:
	var tex := _load_title_sprite("nav_arrow.png")
	if tex != null:
		var r := TextureRect.new()
		r.texture = tex
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		r.flip_h = left
		r.modulate = color
		r.custom_minimum_size = Vector2(h, h)
		r.size = Vector2(h, h)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return r
	var l := _text("‹" if left else "›", color, "big")
	l.add_theme_font_size_override("font_size", h)
	return l

# ══ layout: centre column (emblem, titles, cards, flavour, hint) ═══════════════════

func _build_center() -> void:
	var vp := get_viewport_rect().size
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
	var sub := _text(_subtitle(), SUB_TEAL, "caption")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_left = 0.0; sub.anchor_right = 1.0
	sub.position.y = vp.y * 0.468
	add_child(sub)

	var card_w := int(vp.x * 0.049)
	var card_h := int(vp.y * 0.086)
	_border_tex = _dashed_border_tex(card_w, card_h)
	_frame_tex = _load_card_frame()
	_frame_extracted = _frame_tex != null
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(vp.x * 0.014))
	row.anchor_left = 0.0; row.anchor_right = 1.0
	row.position.y = vp.y * 0.5
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	for i in range(_items.size()):
		row.add_child(_build_card(_items[i], i, card_w, card_h))

	_desc = _rich("", "body")
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc.anchor_left = 0.0; _desc.anchor_right = 1.0
	_desc.position.y = vp.y * 0.665
	add_child(_desc)

	var knob := _load_title_sprite("deco_knob.png")
	if knob != null:
		var ks: int = maxi(6, int(vp.y * 0.009))
		var d: int = int(ks * 1.3)
		var cx: float = vp.x * 0.5
		var oy: float = vp.y * 0.775
		for off in [Vector2(0, -d), Vector2(-d, d), Vector2(d, d)]:
			var k := TextureRect.new()
			k.texture = knob
			k.stretch_mode = TextureRect.STRETCH_SCALE
			k.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			k.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			k.modulate = MUTED
			k.mouse_filter = Control.MOUSE_FILTER_IGNORE
			k.position = Vector2(cx + off.x - ks * 0.5, oy + off.y - ks * 0.5)
			k.size = Vector2(ks, ks)
			add_child(k)

	var rnd := _rich("[center][color=#%s][lb]R[rb][/color][color=#%s] Randomize Selection[/color][/center]" % [
		SEL_GOLD.to_html(false), MUTED.to_html(false)], "body")
	rnd.anchor_left = 0.0; rnd.anchor_right = 1.0
	rnd.position.y = vp.y * 0.905
	add_child(rnd)

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
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 4)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.mouse_entered.connect(func(): _select(idx))
	cell.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(idx); _confirm())
	var caret := _text("›", SEL_GOLD, "big")
	caret.custom_minimum_size = Vector2(12, 0)
	caret.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cell.add_child(caret)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	cell.add_child(col)
	var boxc := Control.new()
	boxc.custom_minimum_size = Vector2(cw, ch)
	var border := NinePatchRect.new()
	border.modulate = DIM_BORDER
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_card_frame(border)
	boxc.add_child(border)
	var icon := TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 12; icon.offset_right = -12; icon.offset_top = 10; icon.offset_bottom = -10
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boxc.add_child(icon)
	col.add_child(boxc)
	var nm := _text(str(m.get("display", m.get("name", "?"))), NAME_DIM, "caption")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.custom_minimum_size = Vector2(cw, 0)
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(nm)
	var hk := _text("[%s]" % str(m.get("hotkey", "")), HOTKEY_DIM, "caption")
	hk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hk.custom_minimum_size = Vector2(cw, 0)
	col.add_child(hk)
	_cards.append({"cell": cell, "boxc": boxc, "border": border, "icon": icon, "name": nm, "hotkey": hk, "caret": caret})
	return cell

# ══ selection ══════════════════════════════════════════════════════════════════════

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
		if c.has("colored"):
			c["icon"].texture = c["colored"] if on else c["neutral"]
			c["icon"].modulate = ICON_SEL if on else ICON_DIM
		c["name"].add_theme_color_override("font_color", NAME_SEL if on else NAME_DIM)
		c["hotkey"].add_theme_color_override("font_color", SEL_GOLD if on else HOTKEY_DIM)
		c["caret"].add_theme_color_override("font_color", SEL_GOLD if on else Color(0, 0, 0, 0))
	if _desc != null and _sel >= 0 and _sel < _items.size():
		var lines := PackedStringArray()
		for line in str(_items[_sel].get("desc", "")).split("\n", false):
			lines.append(QudText.to_bbcode(line, _palette))
		_desc.text = "[center][color=#%s]%s[/color][/center]" % [MUTED.to_html(false), "\n".join(lines)]

func _randomize() -> void:
	if _items.size() > 1:
		var n := _sel
		while n == _sel:
			n = randi() % _items.size()
		_select(n)

func _confirm() -> void:
	if _sel >= 0 and _sel < _items.size():
		selected = str(_items[_sel].get("name", ""))
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

# ══ extracted-sprite chrome ════════════════════════════════════════════════════════

func _apply_card_frame(np: NinePatchRect) -> void:
	if _frame_tex != null:
		np.texture = _frame_tex
		var m := int(round(_frame_tex.get_height() * 17.0 / 80.0))
		np.patch_margin_left = m; np.patch_margin_right = m
		np.patch_margin_top = m; np.patch_margin_bottom = m
	else:
		np.texture = _border_tex
		for s in ["left", "top", "right", "bottom"]:
			np.set("patch_margin_" + s, 0)
	np.draw_center = false
	np.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _load_card_frame() -> Texture2D:
	return _load_title_sprite("card_frame.png")

func _load_emblem() -> Texture2D:
	return _load_title_sprite("chargen_emblem.png")

func _set_emblem(tex: Texture2D) -> void:
	if _emblem_rect == null or tex == null:
		return
	var vp := get_viewport_rect().size
	_emblem_rect.texture = tex
	var eh: int = int(vp.y * 0.042)
	var ew: int = int(eh * float(tex.get_width()) / float(tex.get_height()))
	_emblem_rect.position = Vector2((vp.x - ew) * 0.5, vp.y * 0.432 - eh)
	_emblem_rect.size = Vector2(ew, eh)

func _load_title_sprite(fname: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Load an exported tile untouched (its native colours).
func _native_tile(tile: String) -> Texture2D:
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
	return ImageTexture.create_from_image(img)

## Load a tile and remap each opaque pixel two-tone by darkness (dark→main body, light→detail).
func _recolor_tile(tile: String, main: Color, detail: Color) -> Texture2D:
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
				var cov: float = 1.0 - (p.r + p.g + p.b) / 3.0
				var col := detail.lerp(main, cov)
				img.set_pixel(x, y, Color(col.r, col.g, col.b, p.a))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

# ══ procedural fallbacks (used until the extracted sprites land) ════════════════════

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

func _emblem_texture(color: Color) -> ImageTexture:
	var w := 21
	var h := 24
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := 10
	_line(img, cx, 8, cx, 23, color)
	for hy in [0, 2, 4, 6]:
		_plot(img, cx, hy, color)
	var pairs := [[9, 1, 3], [13, 2, 7], [17, 3, 11]]
	for p in pairs:
		_line(img, cx, p[0], p[1], p[2], color)
		_line(img, cx, p[0], w - 1 - p[1], p[2], color)
	_line(img, cx, 23, 6, 19, color)
	_line(img, cx, 23, 14, 19, color)
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

# ══ text helpers ═══════════════════════════════════════════════════════════════════

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

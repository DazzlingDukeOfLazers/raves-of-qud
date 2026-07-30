extends Control

## THE MAIN MENU — a 1:1 MIMIC of Caves of Qud's modern main menu.
##
## A deliberate, faithful RECONSTRUCTION of Qud's own title screen, measured against a
## real 1793x997 capture of it (build 2.0.211.59):
##   • the extracted cave-art background + "CAVES OF QUD" logo (the player's OWN install
##     art, exported by the mod — never redistributed; see TitleExporter.cs);
##   • a single CENTERED, gilded framed box holding the primary options (New Game /
##     Continue / Records / Options / Mods), centre-aligned;
##   • a BOTTOM-LEFT list of the secondary options (Redeem Code / Modding Toolkit /
##     Credits / Help);
##   • a bottom-centre hotkey hint and a bottom-right version corner.
## Item text + ordering are verbatim from the decompiled Qud.UI.MainMenu (LeftOptions =
## the box, RightOptions = the bottom-left list; "left/right" there are NAV names, not
## screen columns). Positions/colours below are MEASURED off the reference capture.
##
## Pixel-faithful "when possible" — what's approximated: the box's gilded frame and the
## hieroglyph HEADER strip are bespoke Qud art (a hatched gold border + glyph ornament);
## until they're extracted from the install like the bg/logo, they're approximated here
## with a gold-bordered dark panel + a header strip. Qud's menu type is a SANS baked into
## TMP atlases (no loose font ships), so options render in the app's Atkinson sans.
##
## The user's own custom launcher menu (Launch / Enter-viewer detect button, attribution
## corner, ORG_NAME) is preserved in `MainMenu.custom.gd.bak` for LATER restore. To keep
## this mimic usable, two of Qud's items map to Raves actions — New Game LAUNCHES the
## installed Qud, Continue ENTERS the viewer (and, like Qud disabling Continue without a
## save, lights up only while the mod bridge answers) — the rest are cosmetic for now.

# ── palette (measured off the reference capture) ─────────────────────────────────
const BG := Color8(0x0C, 0x1A, 0x16)              # dark teal — clear-colour fallback
const PANEL := Color(0.059, 0.082, 0.082, 0.90)   # #0F1515 box interior, semi-transparent
const FRAME := Color8(0xB6, 0xA1, 0x63)           # gilded frame border (tan-gold)
const HEADER_BG := Color(0.10, 0.13, 0.08, 0.92)  # header strip behind the (future) glyphs
const SEL := Color8(0xF6, 0xF6, 0xF6)             # selected option — near-white
const MUTED := Color8(0x5C, 0x66, 0x63)          # unselected / disabled / secondary — grey-green
const HINT := Color8(0x8F, 0xA6, 0x9E)           # hotkey hint text
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # keycap accents in the hint

## The box is built from Qud's OWN extracted frame sprites (title/chrome/, via the mod)
## composed as Qud composes them (Frame/Border): a tiled dark panel, gold woven side +
## bottom borders, and the gilded hieroglyph header on top. These fractions are each
## piece's thickness relative to the box, from the dump (borderTop 350x69, borderSide
## 18-wide, borderBot 339x18 on a 339x292 border). Absent sprites -> the styled fallback.
const HEADER_H_FRAC := 0.185   # borderTop height / box height
const SIDE_W_FRAC := 0.052     # borderSide width / box width
const BOT_H_FRAC := 0.052      # borderBot height / box height

## The box holds a FIXED aspect and scales with window HEIGHT (centered), like Qud's canvas
## scaler — so it reads the same shape at any window aspect instead of stretching. Width =
## height * BOX_ASPECT (Qud's ~330x334 box); position/height come from the "menu" layout rect.
const BOX_ASPECT := 0.99

## Qud's real menu items, verbatim from Qud.UI.MainMenu. LeftOptions = the centred box;
## RightOptions = the bottom-left list. `act` maps an item to a Raves action for this
## mimic phase; "" = cosmetic (no-op for now).
const BOX_ITEMS := [
	{"text": "New Game", "act": "new"},
	{"text": "Continue", "act": "continue"},
	{"text": "Records", "act": "records"},
	{"text": "Options", "act": "options"},
	{"text": "Mods", "act": "mods"},
]
const LINK_ITEMS := ["Redeem Code", "Modding Toolkit", "Credits", "Help"]

## Fallback if the cache file is missing. Normalized [x,y,w,h] window fractions, MEASURED
## off the reference capture. Tunable at runtime via title_layout.json (no rebuild).
const DEFAULT_LAYOUT := {
	"logo": [0.22, 0.145, 0.56, 0.13],
	"menu": [0.408, 0.405, 0.184, 0.335],
	"links": [0.033, 0.785, 0.22, 0.14],
	"hint": [0.20, 0.953, 0.60, 0.028],
	"version": [0.80, 0.892, 0.185, 0.052],
}

var _layout: Dictionary
var _hl: Texture2D             # buttonHighlight sprite behind the selected option (if extracted)
var _box: Control             # the centred option box (re-placed on resize to hold its aspect)
var _overlay: Control         # active sub-screen (Mods, …) over the menu, or null
var _rows: Array = []          # box options only: [{btn,cfg,enabled}]
var _sel := 0
var _peer := StreamPeerTCP.new()
var _retry := 0.0
var _qud_up := false
var _launching := false
var _game_live := false        # a snapshot has arrived = a game is actually live (not just a socket open)
var _continue_hint: Label      # "load a game in Qud" note, shown when Qud is up but no game is live

func _ready() -> void:
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())
	if Settings.one_to_one():
		# 1:1: Qud's title labels sit on NO background — clear the Label panel (base + role
		# variations) so the bottom-left list (Redeem Code … Help) and the version render as
		# plain text like Qud. User mode keeps Raves' framed look.
		var empty := StyleBoxEmpty.new()
		for tt in ["Label", "Caption", "Title", "Big"]:
			theme.set_stylebox("normal", tt, empty)
	get_viewport().size_changed.connect(_on_resize)
	get_window().title = Brand.title()
	RenderingServer.set_default_clear_color(BG)

	_layout = _load_layout()
	_hl = _chrome("buttonHighlight.png")
	_build_background()   # Qud's title cave-art from the install (if the mod exported it)
	_build_logo()         # Qud's "CAVES OF QUD" wordmark (extracted), else a text fallback
	_build_menu()         # the centred, gilded option box
	_build_continue_hint()  # "load a game in Qud" note under the box (hidden until relevant)
	_build_links()        # the bottom-left secondary list
	_build_hint()
	_build_version()

	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())  # start detecting Qud
	_refresh_enabled()

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())
	if _box != null:
		_place_box(_box)   # keep the box's aspect across any window shape

# ── layout cache ──────────────────────────────────────────────────────────────

func _load_layout() -> Dictionary:
	var out: Dictionary = DEFAULT_LAYOUT.duplicate(true)
	var path := InputModel.support_dir().path_join("title_layout.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.has("elements") and data["elements"] is Dictionary:
				for k in data["elements"]:
					out[k] = data["elements"][k]
	return out

func _place(c: Control, key: String) -> void:
	var r: Array = _layout.get(key, DEFAULT_LAYOUT.get(key, [0, 0, 1, 1]))
	c.anchor_left = r[0]
	c.anchor_top = r[1]
	c.anchor_right = r[0] + r[2]
	c.anchor_bottom = r[1] + r[3]
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0

# ── extracted art ───────────────────────────────────────────────────────────────

## Qud's title BACKGROUND (cave art) exported by the mod, rendered from the player's own
## install (never bundled). Behind everything. Absent until the mod has run in-game once.
func _build_background() -> void:
	var tex := _load_title_png("background.png")
	if tex == null:
		return
	var rect := TextureRect.new()
	rect.texture = tex
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	move_child(rect, 0)   # first child = behind everything

func _build_logo() -> void:
	var tex := _load_title_png("logo.png")
	if tex != null:
		var r := TextureRect.new()
		r.texture = tex
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(r)
		_place(r, "logo")
		return
	# fallback: wordmark as text (mod hasn't exported logo.png yet)
	var l := _label("CAVES OF QUD", SEL, "big")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(l)
	_place(l, "logo")

func _load_title_png(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:   # 0 == OK
		return null
	return ImageTexture.create_from_image(img)

# ── the centred option box ───────────────────────────────────────────────────────

func _build_menu() -> void:
	var box := Control.new()
	box.name = "MenuBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not _build_chrome_frame(box):
		_build_approx_frame(box)   # no extracted sprites yet — styled fallback

	# the options, inset within the frame (below the header, between the side borders)
	var opts := VBoxContainer.new()
	opts.alignment = BoxContainer.ALIGNMENT_CENTER
	opts.add_theme_constant_override("separation", 6)
	opts.anchor_left = 0.09
	opts.anchor_right = 0.91
	opts.anchor_top = HEADER_H_FRAC + 0.04
	opts.anchor_bottom = 1.0 - (BOT_H_FRAC + 0.03)
	for k in ["left", "top", "right", "bottom"]:
		opts.set("offset_" + k, 0.0)
	for cfg in BOX_ITEMS:
		var b := _option_button(cfg)
		opts.add_child(b)
		_rows.append({"btn": b, "cfg": cfg, "enabled": true})
	box.add_child(opts)

	_box = box
	add_child(box)
	_place_box(box)

## Place the box centred on the "menu" rect's centre, sized by window HEIGHT at a fixed
## aspect (Qud's canvas-scaler behaviour) so it never stretches. Re-run on resize.
func _place_box(c: Control) -> void:
	var r: Array = _layout.get("menu", DEFAULT_LAYOUT["menu"])
	var vh := get_viewport().get_visible_rect().size.y
	var cx: float = r[0] + r[2] * 0.5
	var cy: float = r[1] + r[3] * 0.5
	var bh: float = r[3] * vh
	var bw: float = bh * BOX_ASPECT
	c.anchor_left = cx
	c.anchor_right = cx
	c.anchor_top = cy
	c.anchor_bottom = cy
	c.offset_left = -bw * 0.5
	c.offset_right = bw * 0.5
	c.offset_top = -bh * 0.5
	c.offset_bottom = bh * 0.5

## A small note just under the option box, shown only when Qud is up but no game is live (see
## _update_continue_hint). Pure fractional anchors, so it tracks the box across window resizes.
func _build_continue_hint() -> void:
	if Settings.one_to_one():
		return   # Qud shows no such hint — it just greys Continue (mirrored via _refresh_enabled)
	_continue_hint = _label("Load a game in Caves of Qud to continue", MUTED, "caption")
	_continue_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_continue_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_continue_hint.visible = false
	add_child(_continue_hint)
	var r: Array = _layout.get("menu", DEFAULT_LAYOUT["menu"])
	var below: float = r[1] + r[3] + 0.012   # just under the box bottom
	_continue_hint.anchor_left = 0.14
	_continue_hint.anchor_right = 0.86
	_continue_hint.anchor_top = below
	_continue_hint.anchor_bottom = below + 0.06
	for k in ["left", "top", "right", "bottom"]:
		_continue_hint.set("offset_" + k, 0.0)

## Reconstruct Qud's box from its OWN extracted frame sprites (title/chrome/), composed
## the way Qud composes Frame/Border: tiled dark panel, woven gold side + bottom borders,
## and the gilded hieroglyph header on top. Returns false if the sprites aren't present.
func _build_chrome_frame(box: Control) -> bool:
	var top := _chrome("borderTop.png")
	if top == null:
		return false
	var bg := _chrome("panelBgTile.png")
	if bg != null:   # dark weave panel, inset within the borders, native-scale tiled
		var r := _edge(bg, TextureRect.STRETCH_TILE, SIDE_W_FRAC, HEADER_H_FRAC * 0.6,
			1.0 - SIDE_W_FRAC, 1.0 - BOT_H_FRAC)
		box.add_child(r)
	var side := _chrome("borderSide.png")
	if side != null:   # left + right woven borders (right mirrored)
		box.add_child(_edge(side, TextureRect.STRETCH_SCALE, 0.0, HEADER_H_FRAC * 0.6,
			SIDE_W_FRAC, 1.0 - BOT_H_FRAC * 0.4))
		var rt := _edge(side, TextureRect.STRETCH_SCALE, 1.0 - SIDE_W_FRAC, HEADER_H_FRAC * 0.6,
			1.0, 1.0 - BOT_H_FRAC * 0.4)
		rt.flip_h = true
		box.add_child(rt)
	var bot := _chrome("borderBot.png")
	if bot != null:   # bottom woven border
		box.add_child(_edge(bot, TextureRect.STRETCH_SCALE, 0.0, 1.0 - BOT_H_FRAC, 1.0, 1.0))
	# the gilded hieroglyph header last, on top (its ends carry the top corners)
	box.add_child(_edge(top, TextureRect.STRETCH_SCALE, 0.0, 0.0, 1.0, HEADER_H_FRAC))
	return true

## A TextureRect anchored to a fractional sub-rect of its parent (the box), mouse-transparent.
func _edge(tex: Texture2D, mode: int, al: float, at: float, ar: float, ab: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = mode
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.anchor_left = al
	r.anchor_top = at
	r.anchor_right = ar
	r.anchor_bottom = ab
	for k in ["left", "top", "right", "bottom"]:
		r.set("offset_" + k, 0.0)
	return r

## Styled fallback when Qud's frame sprites haven't been extracted yet: a gold-bordered
## dark panel with a header strip — the previous approximation.
func _build_approx_frame(box: Control) -> void:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(3)
	sb.border_color = FRAME
	sb.set_corner_radius_all(1)
	panel.add_theme_stylebox_override("panel", sb)
	box.add_child(panel)
	var header := Panel.new()
	header.anchor_left = 0.0; header.anchor_right = 1.0
	header.anchor_top = 0.0; header.anchor_bottom = HEADER_H_FRAC
	for k in ["left", "top", "right", "bottom"]:
		header.set("offset_" + k, 0.0)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = HEADER_BG
	hsb.border_width_bottom = 2
	hsb.border_color = FRAME
	header.add_theme_stylebox_override("panel", hsb)
	box.add_child(header)

func _chrome(file: String) -> Texture2D:
	return _load_title_png("chrome".path_join(file))

## One box option: focus-less, centre-aligned, transparent chrome. Selected = white,
## everything else = muted grey-green (Qud shows the selection by brightness, no bar).
func _option_button(cfg: Dictionary) -> Button:
	var b := Button.new()
	b.text = cfg.get("text", "")
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.theme_type_variation = "Big"
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, _transparent())
	var idx := _rows.size()
	b.mouse_entered.connect(func(): _select(idx))
	b.pressed.connect(func(): _activate(idx))
	return b

func _transparent() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

## The selected option's background: Qud's extracted buttonHighlight sprite if we have it,
## else a faint flat bar. Kept subtle — selection reads mostly through the white text.
func _highlight_box() -> StyleBox:
	if _hl != null:
		var st := StyleBoxTexture.new()
		st.texture = _hl
		st.modulate_color = Color(1, 1, 1, 0.62)   # soften — Qud's highlight is subtle
		st.content_margin_top = 2
		st.content_margin_bottom = 2
		return st
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.90, 0.86, 0.72, 0.10)
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

# ── the bottom-left secondary list ───────────────────────────────────────────────

func _build_links() -> void:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 6)
	for txt in LINK_ITEMS:
		var l := _label(txt, MUTED, "title")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		v.add_child(l)
	add_child(v)
	_place(v, "links")

# ── selection / enabled state ─────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx == _sel or idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _step(dir: int) -> void:
	var n := _rows.size()
	if n == 0:
		return
	var i := _sel
	for _k in range(n):
		i = (i + dir + n) % n
		if _rows[i]["enabled"]:
			_select(i)
			return

func _apply_selection() -> void:
	for i in range(_rows.size()):
		var b: Button = _rows[i]["btn"]
		var on: bool = (i == _sel) and _rows[i]["enabled"]
		var col: Color = SEL if on else MUTED
		for role in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
			b.add_theme_color_override(role, col)
		# Qud shows selection with its buttonHighlight sprite behind the option (if extracted)
		b.add_theme_stylebox_override("normal", _highlight_box() if on else _transparent())

## Qud disables Continue until there's a save; we mirror that against the live bridge —
## Continue lights up (becomes selectable) only while a modded Qud is running.
func _refresh_enabled() -> void:
	for row in _rows:
		var act: String = row["cfg"].get("act", "")
		var enabled := true
		if act == "continue":
			enabled = _game_live   # a LIVE game, not merely an open bridge socket
		row["enabled"] = enabled
		row["btn"].disabled = not enabled
	if _sel < _rows.size() and not _rows[_sel]["enabled"]:
		_step(1)
	_apply_selection()
	_update_continue_hint()

## Show "load a game in Qud" only when the bridge is up but no game is live — otherwise a greyed
## Continue looks broken. Hidden when Qud's down (nothing to say) or a game IS live (Continue works).
func _update_continue_hint() -> void:
	if _continue_hint != null:
		_continue_hint.visible = _qud_up and not _game_live

# ── hint bar + version corner ─────────────────────────────────────────────────────

func _build_hint() -> void:
	# Qud's hint: "navigate  [Space] select  [Esc] quit". Keycaps in gold via bbcode.
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gold := "#%s" % GOLD.to_html(false)
	var dim := "#%s" % HINT.to_html(false)
	var tail := "[color=%s] navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color]" % [dim, gold, dim, gold, dim]
	if Settings.one_to_one():
		# Qud shows an ARROW-KEYS icon (a gold d-pad cluster), not the literal "↑↓". Draw it and
		# inline it at the head of the centred hint.
		var ih := int(round(UiFont.px(get_viewport(), "caption") * 1.15))
		var icon := _nav_icon_texture(ih, GOLD)
		l.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
		l.add_image(icon, icon.get_width(), icon.get_height())
		l.append_text(tail)
		l.pop()
	else:
		l.text = "[center][color=%s]↑↓ navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color][/center]" % [dim, gold, dim, gold, dim]
	add_child(l)
	_place(l, "hint")

## A small arrow-keys icon (Qud's gold d-pad cluster) drawn procedurally: four keys in the
## inverted-T layout — up on top; left / down / right below — used in the 1:1 hint in place of "↑↓".
func _nav_icon_texture(ih: int, color: Color) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))
	var k := int((ih - g) / 2)          # key size (two rows tall)
	if k < 2:
		k = 2
	var w := 3 * k + 2 * g
	var h := 2 * k + g
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g                     # x of the centre column
	img.fill_rect(Rect2i(mid, 0, k, k), color)          # up (top centre)
	img.fill_rect(Rect2i(0, k + g, k, k), color)        # left
	img.fill_rect(Rect2i(mid, k + g, k, k), color)      # down (centre)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), color)  # right
	return ImageTexture.create_from_image(img)

func _build_version() -> void:
	if Settings.one_to_one():
		_build_version_qud()
		return
	var l := _label("%s\nbuild %s" % [Brand.GAME_NAME, Brand.LICENSE], MUTED, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(l)
	_place(l, "version")

## 1:1: Qud's own version corner — its release + build, right-aligned, in a READABLE colour.
## Qud draws the build line very dark (illegible); we lift it. A RichTextLabel so the two lines
## can differ in brightness AND so it carries none of the Label background panel.
func _build_version_qud() -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ver := "#%s" % SEL.to_html(false)     # release: near-white, like Qud
	var bld := "#%s" % HINT.to_html(false)    # build: readable teal-grey (Qud's is too dark)
	l.text = "[right][color=%s]%s[/color]\n[color=%s]build %s[/color][/right]" % [
		ver, Brand.QUD_VERSION, bld, Brand.QUD_BUILD]
	add_child(l)
	_place(l, "version")

# ── input ─────────────────────────────────────────────────────────────────────────

func _unhandled_input(e: InputEvent) -> void:
	if _overlay != null:
		return   # a sub-screen (Mods, …) owns input while it's open
	if e.is_action_pressed("ui_down"):
		_step(1); accept_event()
	elif e.is_action_pressed("ui_up"):
		_step(-1); accept_event()
	elif e.is_action_pressed("ui_accept"):
		_activate(_sel); accept_event()
	elif e.is_action_pressed("ui_cancel"):
		get_tree().quit(); accept_event()

func _activate(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	var row: Dictionary = _rows[idx]
	if not row["enabled"]:
		return
	match String(row["cfg"].get("act", "")):
		"continue":
			_enter_viewer()
		"new":
			if not _qud_up and not _launching:
				_launching = true
				OS.shell_open(Brand.URL_STEAM_RUN)   # launch the installed copy
			elif _qud_up:
				_open_chargen()   # chargen flow — WIP: genotype → subtype (drives Qud on Embark later)
		"mods":
			_open_overlay("res://ModsScreen.gd")
		"options":
			_open_overlay("res://OptionsScreen.gd")
		"records":
			_open_overlay("res://RecordsScreen.gd")
		_:
			pass  # cosmetic Qud item — no-op during the mimic phase

## Menu sub-screens (Mods, later Options/Records) open as a full-screen overlay over the
## menu; their `closed` signal tears them down and hands input back to the menu.
func _open_overlay(script_path: String) -> void:
	if _overlay != null:
		return
	var scr: Variant = load(script_path)
	if scr == null:
		return
	_overlay = scr.new()
	add_child(_overlay)
	if _overlay.has_signal("closed"):
		_overlay.closed.connect(_close_overlay)

func _close_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null

# ── chargen flow (WIP) ────────────────────────────────────────────────────────────
# The interactive character creator as a chain of stage screens: Genotype → Subtype → …
# Each screen emits `chose(x)`; we record the pick and open the next stage. Embark (driving
# Qud's builder) comes once the stages are in. State lives here for now.
var _cg_genotype := ""
var _cg_subtype := ""

func _open_chargen() -> void:
	if _overlay != null:
		return
	_cg_genotype = ""
	_cg_subtype = ""
	var geno: Variant = load("res://GenotypeScreen.gd").new()
	_overlay = geno
	add_child(geno)
	geno.closed.connect(_close_overlay)
	geno.chose.connect(_on_genotype_chosen)

func _on_genotype_chosen(genotype_name: String) -> void:
	_cg_genotype = genotype_name
	var cls := _genotype_subtype_class(genotype_name)   # "Castes" / "Callings"
	_close_overlay()
	var sub: Variant = load("res://SubtypeScreen.gd").new()
	sub.subtype_class = cls
	sub.genotype_name = genotype_name
	_overlay = sub
	add_child(sub)
	sub.closed.connect(_close_overlay)
	sub.chose.connect(_on_subtype_chosen)

func _on_subtype_chosen(subtype_name: String) -> void:
	_cg_subtype = subtype_name
	_close_overlay()
	# Vertical slice: genotype + subtype is enough to embark. (Attributes / Mutations /
	# Cybernetics / Summary stages will slot in BEFORE this step as they're built.)
	_embark()

## Send the assembled build to the mod, which skips Qud's chargen and boots straight into a
## running game (see mod/EmbarkDriver.cs), then switch Raves to the Holodeck to watch it.
func _embark() -> void:
	if _cg_genotype == "" or _cg_subtype == "":
		return
	if not _qud_up or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_warning("Raves: can't embark — bridge not connected")
		return
	_send_embark(_cg_genotype, _cg_subtype)
	_enter_viewer()   # data-first, same as Continue: MainFrame auto-connects once the game is live

func _send_embark(genotype: String, subtype: String) -> void:
	var msg := {"type": "command", "name": "embark", "genotype": genotype, "subtype": subtype}
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## The subtype family a genotype uses ("Castes"/"Callings"), from chargen.json's genotype entry.
func _genotype_subtype_class(genotype_name: String) -> String:
	var path := InputModel.support_dir().path_join("chargen.json")
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.get("genotypes", null) is Array:
		for g in data["genotypes"]:
			if g is Dictionary and str(g.get("name", "")) == genotype_name:
				return str(g.get("subtypes", ""))
	return ""

func _enter_viewer() -> void:
	if not _qud_up:
		return
	if _peer != null:
		_peer.disconnect_from_host()          # free the probe; MainFrame owns the bridge next
	# Resume: entering with the bridge up means "watch the running game", so tell MainFrame to
	# AUTO-CONNECT its data stage on load (stats/panels/minimap fill immediately) instead of
	# stranding the player at the empty "▶ Connect (data)" prompt. The 3D viewport stays a manual
	# opt-in ("▶ Turn on viewport") — its build has crash history, so we don't auto-fire it. The
	# SceneTree persists across change_scene, so a meta flag hands the intent to MainFrame._ready.
	get_tree().set_meta("holo_auto_connect", true)
	get_tree().change_scene_to_file("res://MainFrame.tscn")

# ── detect Qud (mod bridge) — drives Continue's enabled state ─────────────────────

func _process(dt: float) -> void:
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_set_qud_up(true)
			# DRAIN + detect. The mod force-publishes a snapshot the instant we connect, but ONLY if
			# a game is actually live — so ANY bytes here mean "a game is running" (the mod sends
			# nothing else to a client). That's how we tell a live game apart from a bare socket open
			# at Qud's own main menu. We discard the bytes (detection only) but must read them, else
			# our receive buffer fills and the mod's writer to us stalls.
			var avail := _peer.get_available_bytes()
			if avail > 0:
				_peer.get_data(avail)
				_set_game_live(true)
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_set_qud_up(false)
			_set_game_live(false)   # socket dropped → re-detect on the next connect (mod republishes)
			_retry += dt
			if _retry >= 1.0:   # retry ~1/s until Qud is up
				_retry = 0.0
				_peer = StreamPeerTCP.new()
				_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		_:
			pass  # STATUS_CONNECTING

func _set_qud_up(up: bool) -> void:
	if up == _qud_up:
		return
	_qud_up = up
	if up:
		_launching = false
	_refresh_enabled()

func _set_game_live(live: bool) -> void:
	if live == _game_live:
		return
	_game_live = live
	_refresh_enabled()

# ── UI helpers ──────────────────────────────────────────────────────────────────

func _label(txt: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()   # "Big" / "Title" / "Caption"
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	return l

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

## Qud's real menu items, verbatim from Qud.UI.MainMenu. LeftOptions = the centred box;
## RightOptions = the bottom-left list. `act` maps an item to a Raves action for this
## mimic phase; "" = cosmetic (no-op for now).
const BOX_ITEMS := [
	{"text": "New Game", "act": "new"},
	{"text": "Continue", "act": "continue"},
	{"text": "Records", "act": ""},
	{"text": "Options", "act": ""},
	{"text": "Mods", "act": ""},
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
var _rows: Array = []          # box options only: [{btn,cfg,enabled}]
var _sel := 0
var _peer := StreamPeerTCP.new()
var _retry := 0.0
var _qud_up := false
var _launching := false

func _ready() -> void:
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())
	get_viewport().size_changed.connect(_on_resize)
	get_window().title = Brand.title()
	RenderingServer.set_default_clear_color(BG)

	_layout = _load_layout()
	_build_background()   # Qud's title cave-art from the install (if the mod exported it)
	_build_logo()         # Qud's "CAVES OF QUD" wordmark (extracted), else a text fallback
	_build_menu()         # the centred, gilded option box
	_build_links()        # the bottom-left secondary list
	_build_hint()
	_build_version()

	_peer.connect_to_host(BridgeClient.HOST, BridgeClient.PORT)  # start detecting Qud
	_refresh_enabled()

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())

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
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(3)
	sb.border_color = FRAME
	sb.set_corner_radius_all(1)
	for side in ["left", "right", "top", "bottom"]:
		sb.set("content_margin_" + side, 0)
	panel.add_theme_stylebox_override("panel", sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)

	col.add_child(_build_header())   # hieroglyph strip (approximated until extracted)

	var opts := VBoxContainer.new()
	opts.alignment = BoxContainer.ALIGNMENT_CENTER
	opts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	opts.add_theme_constant_override("separation", 8)
	for side in ["left", "right"]:
		opts.add_theme_constant_override("margin_" + side, 22)
	for cfg in BOX_ITEMS:
		var b := _option_button(cfg)
		opts.add_child(b)
		_rows.append({"btn": b, "cfg": cfg, "enabled": true})
	# pad the option block with margins via a MarginContainer for breathing room
	var mc := MarginContainer.new()
	mc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		mc.add_theme_constant_override("margin_" + side, 18)
	mc.add_child(opts)
	col.add_child(mc)

	add_child(panel)
	_place(panel, "menu")

## The header strip that carries Qud's gilded hieroglyph ornament. Approximated here as a
## dark band under a gold rule; to be replaced by the extracted glyph sprite (TitleExporter).
func _build_header() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = HEADER_BG
	sb.border_width_bottom = 2
	sb.border_color = FRAME
	wrap.add_theme_stylebox_override("panel", sb)
	wrap.custom_minimum_size = Vector2(0, 34)
	return wrap

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

## Qud disables Continue until there's a save; we mirror that against the live bridge —
## Continue lights up (becomes selectable) only while a modded Qud is running.
func _refresh_enabled() -> void:
	for row in _rows:
		var act: String = row["cfg"].get("act", "")
		var enabled := true
		if act == "continue":
			enabled = _qud_up
		row["enabled"] = enabled
		row["btn"].disabled = not enabled
	if _sel < _rows.size() and not _rows[_sel]["enabled"]:
		_step(1)
	_apply_selection()

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
	l.text = "[center][color=%s]↑↓ navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color][/center]" % [dim, gold, dim, gold, dim]
	add_child(l)
	_place(l, "hint")

func _build_version() -> void:
	var l := _label("%s\nbuild %s" % [Brand.GAME_NAME, Brand.LICENSE], MUTED, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(l)
	_place(l, "version")

# ── input ─────────────────────────────────────────────────────────────────────────

func _unhandled_input(e: InputEvent) -> void:
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
				_enter_viewer()
		_:
			pass  # cosmetic Qud item — no-op during the mimic phase

func _enter_viewer() -> void:
	if not _qud_up:
		return
	if _peer != null:
		_peer.disconnect_from_host()          # free the probe; MainFrame owns the bridge next
	get_tree().change_scene_to_file("res://MainFrame.tscn")

# ── detect Qud (mod bridge) — drives Continue's enabled state ─────────────────────

func _process(dt: float) -> void:
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_set_qud_up(true)
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_set_qud_up(false)
			_retry += dt
			if _retry >= 1.0:   # retry ~1/s until Qud is up
				_retry = 0.0
				_peer = StreamPeerTCP.new()
				_peer.connect_to_host(BridgeClient.HOST, BridgeClient.PORT)
		_:
			pass  # STATUS_CONNECTING

func _set_qud_up(up: bool) -> void:
	if up == _qud_up:
		return
	_qud_up = up
	if up:
		_launching = false
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

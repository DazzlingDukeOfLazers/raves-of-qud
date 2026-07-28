extends Control

## THE MAIN MENU — a 1:1 MIMIC of Caves of Qud's modern main menu.
##
## This is a deliberate, faithful RECONSTRUCTION of Qud's own title screen so the two
## read as the same screen: the extracted cave-art background, Qud's "CAVES OF QUD"
## logo, and Qud's exact two-column option set over the top. The item text, ordering,
## and the two-column + hotkey-bar + version-corner structure are taken verbatim from
## the decompiled `Qud.UI.MainMenu` (LeftOptions / RightOptions / DoIntroTween / Show);
## the background.png + logo.png are the player's OWN install art, exported by the mod
## (never redistributed). See TitleExporter.cs.
##
## What we CAN'T extract, and so approximate ("pixel-faithful when possible"): Qud bakes
## its menu typeface into TextMeshPro SDF atlases (no loose font ships), so the text is
## rendered in the project's Atkinson face rather than Qud's serif; and the exact option
## colours are estimated from the logo palette. Positions are DATA — the normalized
## [x,y,w,h] rects live in `title_layout.json` in the RavesOfQud support dir, so tuning
## them is a JSON edit + relaunch, NO rebuild.
##
## The user's own custom launcher menu (Launch / Enter-viewer detect button, the
## attribution corner, ORG_NAME) is preserved verbatim in `MainMenu.custom.gd.bak` and
## is to be RESTORED later. To keep this mimic phase usable rather than a dead screen,
## two of Qud's items are wired to Raves' real actions — New Game LAUNCHES the installed
## Qud, Continue ENTERS the viewer (and, like Qud, is disabled until there's a world to
## continue, i.e. the mod bridge answers) — while the rest are cosmetic for now.

# ── palette (estimated from the extracted logo + Qud's dark-teal UI) ──────────────
const BG := Color8(0x0C, 0x1A, 0x16)              # dark teal — clear-colour fallback
const CREAM := Color8(0xE4, 0xD8, 0xB8)           # option text (Qud's warm parchment)
const CREAM_HI := Color8(0xFB, 0xF3, 0xDD)        # selected / hovered option
const RED := Color8(0x9E, 0x2B, 0x25)             # accent (the logo's rule bars)
const DIM := Color(0.89, 0.85, 0.72, 0.55)        # hint / version / secondary
const DIMMER := Color(0.89, 0.85, 0.72, 0.32)     # disabled option
const SEL_BAR := Color(0.90, 0.86, 0.72, 0.11)    # translucent highlight behind selection

## Qud's real menu items, verbatim from Qud.UI.MainMenu.LeftOptions / RightOptions.
## `act` names a Raves action for this mimic phase; "" = cosmetic (no-op for now).
const LEFT_ITEMS := [
	{"text": "New Game", "act": "new"},
	{"text": "Continue", "act": "continue"},
	{"text": "Records", "act": ""},
	{"text": "Options", "act": ""},
	{"text": "Mods", "act": ""},
]
const RIGHT_ITEMS := [
	{"text": "Redeem Code", "act": ""},
	{"text": "Modding Toolkit", "act": ""},
	{"text": "Credits", "act": ""},
	{"text": "Help", "act": ""},
]

## Fallback if the cache file is missing — kept in sync with title_layout.seed.json.
## Two option columns (left = primary, right = secondary) grouped under the logo,
## a bottom-centre hotkey bar, a bottom-right version corner — Qud's arrangement.
const DEFAULT_LAYOUT := {
	"logo": [0.22, 0.14, 0.56, 0.15],
	"left_menu": [0.335, 0.42, 0.20, 0.32],
	"right_menu": [0.545, 0.42, 0.20, 0.26],
	"hint": [0.20, 0.945, 0.60, 0.03],
	"version": [0.80, 0.95, 0.185, 0.04],
}

var _layout: Dictionary
var _rows: Array = []          # [{btn,label,cfg,enabled}]
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
	_build_menu()
	_build_hint()
	_build_version()

	_peer.connect_to_host(BridgeClient.HOST, BridgeClient.PORT)  # start detecting Qud
	_refresh_enabled()
	_apply_selection()

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

## Qud's title BACKGROUND (cave art) exported by the mod to the RavesOfQud support dir —
## rendered from the player's own install, never bundled. Behind everything. Absent
## until the mod has run in-game once; the flat BG is the fallback.
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
	var l := _label("CAVES OF QUD", CREAM, "big")
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

# ── the two option columns ───────────────────────────────────────────────────────

func _build_menu() -> void:
	var left := _column(LEFT_ITEMS)
	add_child(left)
	_place(left, "left_menu")
	var right := _column(RIGHT_ITEMS)
	add_child(right)
	_place(right, "right_menu")

func _column(items: Array) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 6)
	for cfg in items:
		var b := _option_button(cfg)
		v.add_child(b)
		_rows.append({"btn": b, "cfg": cfg, "enabled": true})
	return v

## One menu option: a left-aligned, focus-less button styled as bare cream text, with a
## faint highlight bar when selected/hovered — Qud's option look.
func _option_button(cfg: Dictionary) -> Button:
	var b := Button.new()
	b.text = cfg.get("text", "")
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.theme_type_variation = "Big"
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_color_override("font_color", CREAM)
	b.add_theme_color_override("font_hover_color", CREAM_HI)
	b.add_theme_color_override("font_pressed_color", CREAM_HI)
	b.add_theme_color_override("font_disabled_color", DIMMER)
	# transparent chrome; the highlight is applied per-selection in _apply_selection()
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, _flat(Color(0, 0, 0, 0)))
	var idx := _rows.size()
	b.mouse_entered.connect(func(): _select(idx))
	b.pressed.connect(func(): _activate(idx))
	return b

func _flat(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	sb.set_corner_radius_all(2)
	return sb

# ── selection / enabled state ─────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx == _sel or idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

## Move selection to the next/previous ENABLED row (keyboard nav), wrapping.
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
		b.add_theme_stylebox_override("normal", _flat(SEL_BAR if on else Color(0, 0, 0, 0)))
		b.add_theme_color_override("font_color", CREAM_HI if on else CREAM)

## Qud disables Continue until there's a save to continue; we mirror that against the
## live bridge — Continue lights up only while a modded Qud is running (a world to enter).
func _refresh_enabled() -> void:
	for row in _rows:
		var act: String = row["cfg"].get("act", "")
		var enabled := true
		if act == "continue":
			enabled = _qud_up
		row["enabled"] = enabled
		row["btn"].disabled = not enabled
	# keep the selection on an enabled row
	if _sel < _rows.size() and not _rows[_sel]["enabled"]:
		_step(1)
	_apply_selection()

# ── hint bar + version corner ─────────────────────────────────────────────────────

func _build_hint() -> void:
	var l := _label("↑↓  navigate      ↵  select      esc  quit", DIM, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(l)
	_place(l, "hint")

func _build_version() -> void:
	# Qud's corner is a two-line version block; here it honestly names Raves in that style.
	var l := _label("%s\nbuild %s" % [Brand.GAME_NAME, Brand.LICENSE], DIM, "caption")
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

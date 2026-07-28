extends Control

## THE MAIN MENU — a Qud-style title screen.
##
## The layout deliberately MIRRORS Caves of Qud's own title (logo top-centre, a
## single centred menu box, a bottom-centre hint, a bottom-right version, a
## bottom-left attribution corner) so the two read as siblings. We copy only the
## rough SIZE + PLACEMENT of those elements — never any Qud art. The rects are
## normalized [x, y, w, h] window fractions, loaded from a cache measured off
## Qud's real menu (`title_layout.json` in the RavesOfQud support dir; the checked-in
## default is `title_layout.seed.json`, mirrored by DEFAULT_LAYOUT below so the app
## always works without the file). Re-measure → overwrite the cache to re-tune.
##
## Raves' one affordance Qud's menu lacks: the launch button DETECTS a running Qud
## (the mod bridge on 127.0.0.1:PORT) and launches the installed copy if it's absent,
## flipping to "Enter viewer" once the bridge answers. Everything else the old
## launcher had (purchase/find/settings/credits/support, the legal panel) is tabled;
## the essential attribution survives as the bottom-left corner.

const BG := Color(0.03, 0.045, 0.06)
const PANEL := Color(0.02, 0.03, 0.045, 0.72)
const BORDER := Color(0.62, 0.80, 0.66, 0.35)   # sage frame, echoing Qud's gilt box
const ACCENT := Color(0.62, 0.84, 0.68)         # sage — title
const DIM := Color(1, 1, 1, 0.55)
const DIMMER := Color(1, 1, 1, 0.34)
const OK := Color(0.45, 0.85, 0.50)
const WARN := Color(0.90, 0.72, 0.38)

## Fallback if the cache file is missing — kept in sync with title_layout.seed.json.
const DEFAULT_LAYOUT := {
	"logo": [0.22, 0.14, 0.56, 0.15],
	"menu": [0.40, 0.40, 0.20, 0.34],
	"links": [0.04, 0.77, 0.16, 0.15],
	"hint": [0.28, 0.94, 0.44, 0.03],
	"version": [0.80, 0.955, 0.185, 0.035],
}

var _layout: Dictionary
var _launch_btn: Button
var _status: Label
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
	_build_logo()
	_build_menu()
	_build_footer()
	_build_hint()
	_build_version()

	_peer.connect_to_host(BridgeClient.HOST, BridgeClient.PORT)  # start detecting Qud
	_refresh_launch_ui()

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

## Qud's title BACKGROUND (cave art, no logo) exported by the mod to the RavesOfQud
## support dir — rendered from the player's own install, never bundled. Behind
## everything, so Raves' own "Raves of Qud" title sits on Qud's atmosphere. Absent
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
	rect.modulate = Color(1, 1, 1, 0.92)   # slight dim so the menu text stays legible
	add_child(rect)
	move_child(rect, 0)   # first child = behind everything

func _load_title_png(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:   # 0 == OK (the OK identifier here is a Color const)
		return null
	return ImageTexture.create_from_image(img)

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

# ── elements ──────────────────────────────────────────────────────────────────

func _build_logo() -> void:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	var t := _label(Brand.GAME_NAME, ACCENT, "big")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	var tag := _label(Brand.GAME_TAGLINE, DIM, "caption")
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(tag)
	add_child(box)
	_place(box, "logo")

func _build_menu() -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(2)
	sb.border_color = BORDER
	sb.set_corner_radius_all(2)
	for side in ["left", "right", "top", "bottom"]:
		sb.set("content_margin_" + side, 16)
	panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	_launch_btn = _menu_button("Checking for %s…" % Brand.BASE_GAME, _on_launch)
	v.add_child(_launch_btn)
	_status = _label("", DIM, "caption")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_status)
	v.add_child(_menu_button("Quit", func(): get_tree().quit()))

	add_child(panel)
	_place(panel, "menu")

func _build_footer() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.add_child(_label("Made by  %s" % Brand.ORG_NAME, DIM, "caption"))
	var note := _label(
		"Renders your own installed copy of %s.\n%s © %s.  %s is %s-licensed." % [
			Brand.BASE_GAME, Brand.BASE_GAME, Brand.BASE_GAME_RIGHTS_HOLDER,
			Brand.GAME_NAME, Brand.LICENSE],
		DIMMER, "caption")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	add_child(v)
	_place(v, "links")

func _build_hint() -> void:
	var l := _label("click to select", DIMMER, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(l)
	_place(l, "hint")

func _build_version() -> void:
	var l := _label("%s · %s" % [Brand.GAME_NAME, Brand.LICENSE], DIMMER, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(l)
	_place(l, "version")

# ── launch / detect Qud ─────────────────────────────────────────────────────────

## Poll the mod bridge: CONNECTED means a Qud with the Raves mod is running.
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
	_refresh_launch_ui()

func _refresh_launch_ui() -> void:
	if _launch_btn == null:
		return
	if _qud_up:
		_launch_btn.text = "Enter viewer"
		_set_status("%s is running" % Brand.BASE_GAME, OK)
	elif _launching:
		_launch_btn.text = "Launching %s…" % Brand.BASE_GAME
		_set_status("waiting for %s to start…" % Brand.BASE_GAME, WARN)
	else:
		_launch_btn.text = "Launch %s" % Brand.BASE_GAME
		_set_status("%s not detected" % Brand.BASE_GAME, DIM)

func _set_status(txt: String, col: Color) -> void:
	if _status != null:
		_status.text = txt
		_status.add_theme_color_override("font_color", col)

func _on_launch() -> void:
	if _qud_up:
		_enter_viewer()
	elif not _launching:
		_launching = true
		_refresh_launch_ui()
		OS.shell_open(Brand.URL_STEAM_RUN)   # launch the installed copy

func _enter_viewer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()          # free the probe; MainFrame owns the bridge next
	get_tree().change_scene_to_file("res://MainFrame.tscn")

# ── UI helpers ──────────────────────────────────────────────────────────────────

func _label(txt: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()   # "Big" / "Title" / "Caption"
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	return l

func _menu_button(txt: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b

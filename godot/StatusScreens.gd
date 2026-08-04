extends CanvasLayer

## THE STATUS SCREENS — Qud's 8-tab in-game menu (StatusScreensScreen), 1:1.
##
## One shared frame (V4 plan: docs/status-screens-plan.md): a per-channel multiply
## scrim dims the LIVE game behind (measured 0.41/0.575/0.567), an opaque tab-bar
## strip on (7,26,27) with icon+letterspaced-name tabs (active white, inactive dim
## slate), numpad-7/9 page keycaps with end-stop glyphs at the bar's ends, a bottom
## rule + search field + nav hint, and a content pane per tab. Tab icons are
## extracted per-install into title/chrome/statusIcon_<tab>_{on,off}.png.
##
## Panes port one at a time; MESSAGE LOG is built (session-accumulated raw lines —
## the side panel dedupes/collapses, this screen mirrors Qud's raw list). Unported
## tabs show an empty scrim pane. Created hidden at MainFrame build time so message
## accumulation runs from the first snapshot; F2 (placeholder opener) toggles it.
##
## A CanvasLayer (90 — under the CRT at 100): the scrim's hint_screen_texture only
## sees the 3D Holodeck from a layer above the base canvas (the CRT-shader lesson).

signal closed

const TABS := [
	{"id": "skills", "name": "SKILLS"},
	{"id": "attributes", "name": "ATTRIBUTES & POWERS"},
	{"id": "equipment", "name": "EQUIPMENT"},
	{"id": "tinkering", "name": "TINKERING"},
	{"id": "journal", "name": "JOURNAL"},
	{"id": "quests", "name": "QUESTS"},
	{"id": "reputation", "name": "REPUTATION"},
	{"id": "messagelog", "name": "MESSAGE LOG"},
]
# tab cell boundaries + bar band, measured at 1920x1080
const CELL_X := [205, 346, 636, 818, 1000, 1162, 1312, 1505, 1735]
const BAR_Y := 108.0
const BAR_H := 52.0
# the scrim's per-channel multiply (menu capture / in-game capture, measured)
const SCRIM := Color(0.41, 0.575, 0.567)

var S_BAR_BG := QudChrome.q8(7, 26, 27)
var S_ACTIVE := QudChrome.q8(218, 255, 218)
var S_INACTIVE := QudChrome.q8(65, 106, 115)
var S_KEYCAP := QudChrome.q8(68, 99, 111)
var S_KEYDIGIT := QudChrome.q8(30, 140, 60)
var S_DIM_TEXT := QudChrome.q8(81, 111, 127)     # log default text
var S_HINT := QudChrome.q8(167, 192, 186)
var S_GOLD := QudChrome.q8(195, 180, 56)         # the > cursor
var S_RULE := QudChrome.q8(60, 84, 92)

var _root: Control           # full-rect content root inside this layer
var _tab := "messagelog"
var _hover_tab := -1
var _palette := {}
var _icons := {}             # "<id>_on"/"<id>_off" -> Texture2D
var _bar: Control
var _pane_host: Control
var _log_scroll: ScrollContainer
var _log_box: VBoxContainer
var _search: LineEdit
var _hint: RichTextLabel     # bottom hint bar — content changes per tab, like Qud's
var _cursor: Label           # the gold > beside the newest log line
var _filter := ""

# raw session log (Qud's screen shows raw lines, repeats included)
var _all_lines: Array = []
var _msg_total := 0
var _seeded := false

# character sheet (Attributes & Powers): mod CharacterExporter -> character.json;
# we request a fresh export on open via our own bridge peer (Records pattern)
var _attr_pane: Control = null
var _char_mtime := 0
var _pane_pal_empty := true
var _portrait_tex: Texture2D = null   # live player tile — also the attributes tab's icon
var _peer := StreamPeerTCP.new()
var _tiles: RefCounted = null
var _last_player := {}
var _tiles_dir := ""

func _init() -> void:
	layer = 90                                   # above chrome+3D, under the CRT (100)
	visible = false

func _ready() -> void:
	name = "StatusScreens"
	_tiles = load("res://QudTiles.gd").new()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP     # modal while shown
	_root.theme = UiFont.make_theme(get_viewport())    # CanvasLayer theme-root trap
	add_child(_root)
	for t in TABS:
		for st in ["on", "off"]:
			var p := InputModel.support_dir().path_join("title").path_join("chrome").path_join(
				"statusIcon_%s_%s.png" % [t["id"], st])
			if FileAccess.file_exists(p):
				var img := Image.new()
				if img.load(p) == 0:
					_icons["%s_%s" % [t["id"], st]] = ImageTexture.create_from_image(QudChrome.brighten(img))
	_build()

func _build() -> void:
	# the multiply scrim: a screen-texture shader (a plain MUL ColorRect can't dim the
	# 3D Holodeck under the canvas hole — same reason the CRT overlay uses a shader)
	var scrim := ColorRect.new()
	var sh := Shader.new()
	# NOT a multiply: Qud's scrim is an ~82%-opaque dark-teal ALPHA BLEND — fitted
	# out = k*in + b per channel on dark ground AND the bright Joppa water pools
	# (a multiply matched the darks but left brights 2x too bright)
	sh.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture;
void fragment() {
	vec4 c = texture(screen_tex, SCREEN_UV);
	COLOR = vec4(c.rgb * vec3(0.190, 0.168, 0.170) + vec3(3.79, 21.27, 20.34) / 255.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	scrim.material = mat
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(scrim)

	# opaque tab-bar strip + tabs + keycap clusters (one draw pass)
	_bar = Control.new()
	_bar.position = Vector2(0, BAR_Y)
	_bar.size = Vector2(1920, BAR_H)
	_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	# NEAREST for everything the bar draws — the live tab icon scales 1.5x, and the
	# default LINEAR filter smears it soft/dim next to the crisp NEAREST portrait
	_bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bar.draw.connect(_draw_bar)
	_bar.gui_input.connect(_bar_input)
	_root.add_child(_bar)

	# content host (panes draw inside; the scrim already dimmed what's behind)
	_pane_host = Control.new()
	_pane_host.position = Vector2(0, BAR_Y + BAR_H)
	_pane_host.size = Vector2(1920, 940 - (BAR_Y + BAR_H))
	_pane_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_pane_host)
	_build_log_pane()

	# bottom rule + search + hint
	var bottom := Control.new()
	bottom.position = Vector2(0, 936)
	bottom.size = Vector2(1920, 60)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.draw.connect(func():
		bottom.draw_rect(Rect2(160, 1, 1600, 2), S_RULE)
		# magnifier
		bottom.draw_arc(Vector2(185, 24), 6, 0, TAU, 12, S_HINT, 1.5)
		bottom.draw_line(Vector2(190, 29), Vector2(196, 35), S_HINT, 1.5))
	_root.add_child(bottom)
	_search = LineEdit.new()
	_search.position = Vector2(205, 950)
	_search.size = Vector2(150, 24)
	_search.placeholder_text = "<search>"
	_search.add_theme_font_size_override("font_size", 14)
	_search.add_theme_color_override("font_color", S_HINT)
	_search.add_theme_color_override("font_placeholder_color", S_INACTIVE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.25)
	sb.set_border_width_all(1)
	sb.border_color = S_RULE
	sb.content_margin_left = 6
	_search.add_theme_stylebox_override("normal", sb)
	_search.text_changed.connect(func(t):
		_filter = t.strip_edges().to_lower()
		_refresh_log())
	_root.add_child(_search)
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.fit_content = true
	_hint.scroll_active = false
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("normal_font_size", 16)
	# Qud centres the hint row on x~1067 (measured on both tabs); a CenterContainer
	# keeps it centred as per-tab content changes its width
	var hc := CenterContainer.new()
	hc.position = Vector2(367, 950)
	hc.size = Vector2(1400, 28)
	hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hc.add_child(_hint)
	_root.add_child(hc)
	_build_hints()


## Rebuild the bottom hint bar for the active tab (Qud's changes per screen).
func _build_hints() -> void:
	if _hint == null:
		return
	_hint.clear()
	var wht := "#FFFFFF"
	var dimc := "#%s" % S_HINT.to_html(false)
	var goldc := "#%s" % QudChrome.q8(200, 184, 57).to_html(false)
	_hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	_hint.append_text("[color=%s][lb][/color]" % wht)
	_hint.add_image(_nav_icon(15), 22, 15)
	_hint.append_text("[color=%s][rb][/color]" % wht)
	_hint.append_text("[color=%s] navigation  [/color]" % dimc)
	var keys := [["Space", "Accept"]]
	if _tab == "attributes":
		keys.append(["E", "Show Effects"])
		keys.append(["M", "Buy Mutation"])
	for k in keys:
		_hint.append_text("[color=%s][lb][/color][color=%s]%s[/color][color=%s][rb][/color]" % [wht, goldc, k[0], wht])
		_hint.append_text("[color=%s] %s  [/color]" % [dimc, k[1]])
	_hint.pop()

func _nav_icon(ih: int) -> ImageTexture:
	var gold := QudChrome.q8(200, 184, 57)
	var g := maxi(1, int(round(ih * 0.10)))
	var k := maxi(2, int((ih - g) / 2.0))
	var img := Image.create(3 * k + 2 * g, 2 * k + g, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g
	img.fill_rect(Rect2i(mid, 0, k, k), gold)
	img.fill_rect(Rect2i(0, k + g, k, k), gold)
	img.fill_rect(Rect2i(mid, k + g, k, k), gold)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), gold)
	return ImageTexture.create_from_image(img)

# ── the tab bar ────────────────────────────────────────────────────────────────

func _draw_bar() -> void:
	_bar.draw_rect(Rect2(0, 0, 1920, BAR_H), S_BAR_BG)
	var f := _root.get_theme_font("font", "Label")
	for i in TABS.size():
		var t: Dictionary = TABS[i]
		var active: bool = (t["id"] == _tab)
		var cx0: int = CELL_X[i]
		var cw: int = CELL_X[i + 1] - cx0
		var icon: Texture2D = _icons.get("%s_%s" % [t["id"], "on" if active else "off"])
		var live: bool = (t["id"] == "attributes" and _portrait_tex != null)
		var tw := f.get_string_size(t["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		var iw := 0.0
		if live:
			iw = 24.0 + 10.0
		elif icon != null:
			iw = icon.get_width() + 10.0
		var x := cx0 + (cw - (iw + tw)) * 0.5
		if live:
			# Qud's Attributes tab icon IS the character sprite, same 24x36 as the
			# sheet portrait, facing left. Flip via TRANSFORM so the 1.5x NEAREST
			# duplicate-columns land like the portrait's flip_h (scale THEN mirror —
			# a pre-flipped image mirrors first and doubles the other side: derpy).
			_bar.draw_set_transform(Vector2(x + 24.0, 10.0), 0.0, Vector2(-1, 1))
			_bar.draw_texture_rect(_portrait_tex, Rect2(0, 0, 24, 36), false,
				Color.WHITE if active else Color(0.5, 0.62, 0.66))
			_bar.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		elif icon != null:
			_bar.draw_texture(icon, Vector2(x, (BAR_H - icon.get_height()) * 0.5 + 1))
		_bar.draw_string(f, Vector2(x + iw, 36), t["name"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, S_ACTIVE if active else S_INACTIVE)
		if _hover_tab == i and not active:
			_bar.draw_string(f, Vector2(x - 14, 36), ">", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, S_GOLD)
	# numpad 7/9 page keycaps with end-stop glyphs: "⊣ [7]" left, "[9] ⊢" right
	_draw_keycap(163, true)
	_draw_keycap(1722, false)

func _draw_keycap(x: float, left: bool) -> void:
	var box_x := x + (18.0 if left else 0.0)
	_bar.draw_rect(Rect2(box_x, 11, 20, 30), S_KEYCAP)
	var f := _root.get_theme_font("font", "Label")
	_bar.draw_string(f, Vector2(box_x + 6, 33), "7" if left else "9",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, S_KEYDIGIT)
	var gy := 26.0
	if left:
		_bar.draw_rect(Rect2(x - 16, gy - 1, 14, 2), S_KEYCAP)   # ⊣
		_bar.draw_rect(Rect2(x - 3, 14, 2, 24), S_KEYCAP)
	else:
		_bar.draw_rect(Rect2(box_x + 21, 14, 2, 24), S_KEYCAP)   # ⊢
		_bar.draw_rect(Rect2(box_x + 23, gy - 1, 14, 2), S_KEYCAP)

func _bar_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := _tab_at(e.position.x)
		if h != _hover_tab:
			_hover_tab = h
			_bar.queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var i := _tab_at(e.position.x)
		if i >= 0:
			_set_tab(TABS[i]["id"])

func _tab_at(x: float) -> int:
	for i in TABS.size():
		if x >= CELL_X[i] and x < CELL_X[i + 1]:
			return i
	return -1

func _set_tab(id: String) -> void:
	_tab = id
	_bar.queue_redraw()
	_log_scroll.visible = (id == "messagelog")
	if _cursor != null:
		_cursor.visible = (id == "messagelog")
	if id == "messagelog":
		_refresh_log()
	if _attr_pane != null:
		_attr_pane.visible = (id == "attributes")
	if id == "attributes":
		_request_export()
		_load_character()
	_build_hints()
	if visible:
		UiState.set_scene("status_" + _tab)

## Ask the mod for a fresh data export (character.json etc.); fire-and-forget.
func _request_export() -> void:
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		return
	var payload := JSON.stringify({"type": "command", "name": "export"}).to_utf8_buffer()
	var frame := PackedByteArray()
	var n := payload.size()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## (Re)build the Attributes & Powers pane from character.json when it changes.
func _load_character() -> void:
	var path := InputModel.support_dir().path_join("character.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	# rebuild despite an unchanged file if the pane was built before the palette
	# arrived (an early open rendered every colour code white)
	var pane_missing_portrait: bool = _attr_pane != null and _attr_pane.has_method("has_portrait") \
		and not _attr_pane.has_portrait() and not _last_player.is_empty()
	if _attr_pane != null and mt == _char_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()) and not pane_missing_portrait:
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)   # strip a UTF-8 BOM — JSON.parse_string rejects it
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_char_mtime = mt
	if _attr_pane == null:
		_attr_pane = load("res://StatusPaneAttributes.gd").new()
		_root.add_child(_attr_pane)
	# the player portrait: white tile + detail colour, like the frame's avatar
	# portrait straight from character.json (tile + detail code) — snapshots proved
	# an unreliable source (they only flow on turns/connect; a menu-opened pane raced)
	var tex: Texture2D = null
	var tile := String(data.get("tile", ""))
	if tile != "":
		_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
		if not _palette.is_empty():
			_tiles.palette = _palette
		tex = _tiles.texture(tile, Color.WHITE, _tiles.color_of(String(data.get("detail", "")), Color.WHITE))
	_portrait_tex = tex
	if _bar != null:
		_bar.queue_redraw()   # the attributes tab icon IS the live portrait
	_pane_pal_empty = _palette.is_empty()
	_attr_pane.setup(data, _palette, tex)
	_attr_pane.visible = (_tab == "attributes")
	# fresh export may land AFTER this read — poll the mtime once more shortly
	get_tree().create_timer(1.2).timeout.connect(func():
		if visible and _tab == "attributes":
			_load_character())

# ── open / close / input ───────────────────────────────────────────────────────

func open(tab := "") -> void:
	if tab != "":
		_tab = tab
	visible = true
	_hover_tab = -1
	_set_tab(_tab)

func close() -> void:
	visible = false
	UiState.set_scene("in_game")
	closed.emit()

func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_7, KEY_KP_7:
				_step_tab(-1); get_viewport().set_input_as_handled()
			KEY_9, KEY_KP_9:
				_step_tab(1); get_viewport().set_input_as_handled()
			# swallow the remaining digits so ability hotkeys can't fire underneath
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_8, \
			KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_8:
				get_viewport().set_input_as_handled()

func _step_tab(dir: int) -> void:
	var idx := 0
	for i in TABS.size():
		if TABS[i]["id"] == _tab:
			idx = i
	_set_tab(TABS[wrapi(idx + dir, 0, TABS.size())]["id"])

# ── MESSAGE LOG pane ───────────────────────────────────────────────────────────

func _build_log_pane() -> void:
	_log_scroll = ScrollContainer.new()
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_log_scroll.position = Vector2(192, 196 - (BAR_Y + BAR_H))
	_log_scroll.size = Vector2(1568, 936 - 196)
	_pane_host.add_child(_log_scroll)
	_log_box = VBoxContainer.new()
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_box.add_theme_constant_override("separation", 0)
	_log_scroll.add_child(_log_box)

## MainFrame feeds every snapshot (registered in _panels): accumulate the RAW line
## history via msgCount deltas — the side panel's collapsed entries are no use here.
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal   # same shape MessageLog/QudText already consume
	var pobj: Dictionary = data.get("player", {})
	if not pobj.is_empty():
		_last_player = pobj
	_tiles_dir = String(data.get("tilesDir", _tiles_dir))
	var lines: Array = data.get("messages", [])
	var total := int(data.get("msgCount", 0))
	if not _seeded:
		_seeded = true
		for l in lines:
			_all_lines.append(str(l))
		_msg_total = total
	elif total > _msg_total:
		var n := mini(total - _msg_total, lines.size())
		for i in range(lines.size() - n, lines.size()):
			_all_lines.append(str(lines[i]))
		_msg_total = total
	else:
		return
	if visible and _tab == "messagelog":
		_refresh_log()

func _refresh_log() -> void:
	for c in _log_box.get_children():
		c.queue_free()
	var shown: Array = []
	for l in _all_lines:
		if _filter == "" or str(l).to_lower().find(_filter) >= 0:
			shown.append(l)
	for i in shown.size():
		var rl := RichTextLabel.new()
		rl.bbcode_enabled = true
		rl.fit_content = true
		rl.scroll_active = false
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rl.add_theme_font_size_override("normal_font_size", 16)
		rl.add_theme_color_override("default_color", S_DIM_TEXT)
		rl.custom_minimum_size = Vector2(0, 20)
		rl.text = QudText.to_bbcode(str(shown[i]), _palette)
		_log_box.add_child(rl)
	# bottom-anchor like Qud: newest visible, gold > cursor beside the newest line
	await get_tree().process_frame
	if _log_scroll == null:
		return
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)
	if _cursor == null:
		_cursor = Label.new()
		_cursor.text = ">"
		_cursor.add_theme_color_override("font_color", S_GOLD)
		_cursor.add_theme_font_size_override("font_size", 16)
		_pane_host.add_child(_cursor)
	var content_h := minf(_log_box.size.y, _log_scroll.size.y)
	_cursor.position = Vector2(178, _log_scroll.position.y + content_h - 20.0)
	_cursor.visible = shown.size() > 0

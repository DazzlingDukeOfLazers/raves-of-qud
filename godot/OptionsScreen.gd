extends Control

## THE OPTIONS SCREEN — a 1:1 mirror of Caves of Qud's Options, in Qud's layout.
##
## A full-screen scrollable panel (OPTIONS header, left category sidebar, sections) over a
## darkened cave-art backdrop. A "RAVES" section of Raves' OWN settings (editable, persisted
## via [[Settings]]) sits on top; below it, QUD'S FULL OPTIONS TREE is mirrored from the mod's
## export (options.json — every category + option: label, type, current value, values), so the
## same categories/options/wording appear here as in Qud. Qud's options are DISPLAY (a mirror)
## for now — read from the player's install, never redistributed; write-back (updating Qud from
## Raves via Options.SetOption) is the next phase. Opened as an overlay by MainMenu; Back closes.

signal closed

const GOLD := Color8(0xC8, 0xA9, 0x4E)
const CYAN := Color8(0x6E, 0xB5, 0xC9)
const LABEL := Color8(0xE4, 0xD8, 0xB8)
const VALUE := Color8(0xC8, 0xA9, 0x4E)
const SEL := Color8(0xF6, 0xF6, 0xF6)
const DIM := Color(0.89, 0.85, 0.72, 0.5)
const FRAME := Color8(0xB6, 0xA1, 0x63)

## Raves' own editable settings (persisted to settings.json).
const RAVES_ITEMS := [
	{"key": "font_scale", "label": "Font scale", "type": "slider", "min": 0.7, "max": 1.5, "step": 0.05},
	{"key": "fullscreen", "label": "Fullscreen", "type": "toggle"},
	{"key": "full_info", "label": "Show full info by default", "type": "toggle"},
	{"key": "camera", "label": "Default camera", "type": "options",
		"options": ["Compass", "Follow", "First person", "Cinematic", "Mouse", "Keyboard", "Top follow"]},
	{"key": "bridge_host", "label": "Host", "type": "text"},
	{"key": "bridge_port", "label": "Port", "type": "text"},
]

var _scroll: ScrollContainer
var _anchors: Dictionary = {}          # category name -> its header Control (sidebar jumps)
var _qud_cats: Array = []              # Qud's options tree, from options.json
var _peer := StreamPeerTCP.new()       # bridge link for WRITE-BACK (setoption) while Qud is in-game
var _bridge := false
var _status: Label

func _ready() -> void:
	name = "OptionsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	_qud_cats = _load_qud_options()

	var bgtex := _load_png("title/background.png")
	if bgtex != null:
		var bg := TextureRect.new()
		bg.texture = bgtex
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(bg)
	var dark := ColorRect.new()
	dark.color = Color(0.02, 0.03, 0.035, 0.85 if bgtex != null else 1.0)
	dark.set_anchors_preset(Control.PRESET_FULL_RECT)
	dark.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dark)

	_build_header()
	_build_sidebar()
	_build_body()
	_build_footer()
	_add_back()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())   # for write-back to Qud

## Poll the bridge; Qud-option edits WRITE BACK only while a modded Qud is in-game (connected).
func _process(_dt: float) -> void:
	_peer.poll()
	_bridge = _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if _status != null:
		_status.text = "● editing Qud live" if _bridge else "○ Qud not connected — edits apply when it's in-game"
		_status.add_theme_color_override("font_color", Color8(0x5F, 0xC8, 0x5A) if _bridge else DIM)

## Write a Qud option back over the bridge (mod calls Options.SetOption). No-op if not connected.
func _set_qud_option(id: String, value) -> void:
	if id == "" or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var msg := JSON.stringify({"type": "command", "name": "setoption", "id": id, "value": str(value)})
	var payload := msg.to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

func _add_back() -> void:
	var b := Button.new()
	b.text = "‹ Back"
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", SEL)
	b.anchor_left = 0.02
	b.anchor_right = 0.14
	b.anchor_top = 0.93
	b.anchor_bottom = 0.985
	_zero(b)
	b.pressed.connect(func(): closed.emit())
	add_child(b)

# ── data ───────────────────────────────────────────────────────────────────────

func _load_qud_options() -> Array:
	var path := InputModel.support_dir().path_join("options.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.has("categories") and d["categories"] is Array:
		return d["categories"]
	return []

func _cat_names() -> Array:
	var out := ["Raves"]
	for c in _qud_cats:
		out.append(str(c.get("name", "?")))
	return out

func _load_png(rel: String) -> Texture2D:
	var path := InputModel.support_dir().path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

# ── layout ───────────────────────────────────────────────────────────────────────

func _build_header() -> void:
	var l := _label("OPTIONS", GOLD, "title")
	l.anchor_left = 0.17
	l.anchor_right = 0.6
	l.anchor_top = 0.045
	l.anchor_bottom = 0.095
	_zero(l)
	add_child(l)

func _build_sidebar() -> void:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.anchor_left = 0.0
	sc.anchor_right = 0.155
	sc.anchor_top = 0.11
	sc.anchor_bottom = 0.9
	_zero(sc)
	add_child(sc)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	sc.add_child(v)
	for cat in _cat_names():
		var b := Button.new()
		b.text = cat
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.flat = true
		b.theme_type_variation = "Caption"
		b.add_theme_color_override("font_color", CYAN)
		b.add_theme_color_override("font_hover_color", SEL)
		b.pressed.connect(func(): _jump_to(cat))
		v.add_child(b)

func _build_body() -> void:
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.anchor_left = 0.17
	_scroll.anchor_right = 0.96
	_scroll.anchor_top = 0.11
	_scroll.anchor_bottom = 0.9
	_zero(_scroll)
	add_child(_scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 5)
	_scroll.add_child(col)

	# RAVES section — editable settings
	_section_header(col, "Raves")
	for item in RAVES_ITEMS:
		col.add_child(_build_raves_setting(item))
	col.add_child(_spacer(12))

	# Qud's mirrored tree — display of the visible options in each category
	for cat in _qud_cats:
		_section_header(col, str(cat.get("name", "?")))
		var opts: Array = cat.get("options", [])
		var shown := 0
		for opt in opts:
			if bool(opt.get("visible", true)):
				col.add_child(_build_qud_option(opt))
				shown += 1
		if shown == 0:
			col.add_child(_label("(no options shown — enable advanced options in Qud)", DIM, "caption"))
		col.add_child(_spacer(12))

func _section_header(col: VBoxContainer, name: String) -> void:
	var h := _label("[-]  " + name.to_upper(), CYAN, "title")
	col.add_child(h)
	_anchors[name] = h

func _build_footer() -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = "[center][color=#%s][lb]Esc[rb][/color][color=#%s] Back      [/color][color=#%s]↑↓[/color][color=#%s] navigate[/color][/center]" % [
		GOLD.to_html(false), DIM.to_html(false), GOLD.to_html(false), DIM.to_html(false)]
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.93
	l.anchor_bottom = 0.985
	_zero(l)
	add_child(l)
	# live write-back status (updated in _process)
	_status = _label("", DIM, "caption")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.anchor_left = 0.6
	_status.anchor_right = 0.98
	_status.anchor_top = 0.93
	_status.anchor_bottom = 0.985
	_zero(_status)
	add_child(_status)

# ── Raves settings (editable, persisted) ───────────────────────────────────────────

func _build_raves_setting(item: Dictionary) -> Control:
	match String(item.get("type", "")):
		"slider": return _raves_slider(item)
		"toggle": return _raves_toggle(item)
		"options": return _raves_options(item)
		"text": return _raves_text(item)
		_: return _label(str(item.get("label", "?")), LABEL, "body")

func _raves_slider(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = float(item["min"]); s.max_value = float(item["max"]); s.step = float(item["step"])
	s.value = float(Settings.get_value(item["key"], 1.0))
	s.custom_minimum_size = Vector2(420, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := _label("%.2f" % s.value, VALUE, "body")
	s.value_changed.connect(func(v):
		val.text = "%.2f" % v
		Settings.set_value(item["key"], v); Settings.save()
		if item["key"] == "font_scale": _retheme())
	h.add_child(s); h.add_child(val)
	row.add_child(h)
	return row

func _raves_toggle(item: Dictionary) -> Control:
	var b := _flat_button()
	var on := bool(Settings.get_value(item["key"], false))
	b.text = _check(on) + str(item["label"])
	b.pressed.connect(func():
		var now := not bool(Settings.get_value(item["key"], false))
		Settings.set_value(item["key"], now); Settings.save()
		b.text = _check(now) + str(item["label"]))
	return b

func _raves_options(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var opts: Array = item["options"]
	var cur := int(Settings.get_value(item["key"], 0))
	var btns: Array = []
	for i in range(opts.size()):
		var b := _flat_button()
		b.text = str(opts[i])
		b.add_theme_color_override("font_color", SEL if i == cur else DIM)
		var idx := i
		b.pressed.connect(func():
			Settings.set_value(item["key"], idx); Settings.save()
			for j in range(btns.size()):
				btns[j].add_theme_color_override("font_color", SEL if j == idx else DIM))
		btns.append(b); h.add_child(b)
	row.add_child(h)
	return row

func _raves_text(item: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.add_child(_label(str(item["label"]) + ":", LABEL, "body"))
	var e := LineEdit.new()
	var raw: Variant = Settings.get_value(item["key"], "")
	e.text = str(int(raw)) if item["key"] == "bridge_port" else str(raw)
	e.custom_minimum_size = Vector2(320, 0)
	e.add_theme_color_override("font_color", VALUE)
	var commit := func(_t = null):
		var v: Variant = e.text
		if item["key"] == "bridge_port": v = int(e.text)
		Settings.set_value(item["key"], v); Settings.save()
	e.text_submitted.connect(commit); e.focus_exited.connect(commit)
	h.add_child(e)
	return h

# ── Qud options (mirror / display) ──────────────────────────────────────────────────

func _build_qud_option(opt: Dictionary) -> Control:
	match str(opt.get("type", "")):
		"Slider": return _qud_slider(opt)
		"Checkbox": return _qud_checkbox(opt)
		"Combo", "BigCombo": return _qud_combo(opt)
		"Button": return _qud_button(opt)
		_: return _label("%s  %s" % [str(opt.get("label", "?")), str(opt.get("value", ""))], LABEL, "body")

func _qud_slider(opt: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(opt.get("label", "")), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = float(opt.get("min", 0)); s.max_value = float(opt.get("max", 100))
	s.step = maxf(1.0, float(opt.get("increment", 1)))
	s.value = clampf(float(str(opt.get("value", "0")).to_float()), s.min_value, s.max_value)
	s.custom_minimum_size = Vector2(420, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var id := str(opt.get("id", ""))
	var val := _label(str(int(s.value)), VALUE, "body")
	s.value_changed.connect(func(v):
		var iv := int(round(v))
		val.text = str(iv)
		_set_qud_option(id, iv))
	h.add_child(s); h.add_child(val)
	row.add_child(h)
	return row

func _qud_checkbox(opt: Dictionary) -> Control:
	var id := str(opt.get("id", ""))
	var lbl := str(opt.get("label", ""))
	var state := {"on": str(opt.get("value", "No")).to_lower() == "yes"}
	var b := _flat_button()
	b.text = _check(state.on) + lbl
	b.pressed.connect(func():
		state.on = not state.on
		_set_qud_option(id, "Yes" if state.on else "No")
		b.text = _check(state.on) + lbl)
	return b

func _qud_combo(opt: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(opt.get("label", "")), LABEL, "body"))
	var vals: Array = opt.get("values", [])
	var id := str(opt.get("id", ""))
	if vals.is_empty():
		row.add_child(_label(str(opt.get("value", "")), VALUE, "body"))
		return row
	var cur := {"v": str(opt.get("value", ""))}
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16)
	flow.add_theme_constant_override("v_separation", 4)
	var btns: Array = []
	for v in vals:
		var sv := str(v)
		var b := _flat_button()
		b.theme_type_variation = "Caption"
		b.text = sv
		b.add_theme_color_override("font_color", SEL if sv == cur.v else DIM)
		b.pressed.connect(func():
			cur.v = sv
			_set_qud_option(id, sv)
			for bb in btns: bb.add_theme_color_override("font_color", SEL if bb.text == sv else DIM))
		btns.append(b); flow.add_child(b)
	row.add_child(flow)
	return row

func _qud_button(opt: Dictionary) -> Control:
	var l := _label("› " + str(opt.get("label", "")), CYAN, "body")
	return l

# ── behaviour + helpers ────────────────────────────────────────────────────────────

func _jump_to(name: String) -> void:
	var head: Control = _anchors.get(name)
	if head != null and _scroll != null:
		_scroll.ensure_control_visible(head)

func _retheme() -> void:
	theme = UiFont.make_theme(get_viewport())
	var parent := get_parent()
	if parent is Control:
		(parent as Control).theme = UiFont.make_theme(get_viewport())

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

func _check(on: bool) -> String:
	return "[■]  " if on else "[  ]  "

func _flat_button() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.add_theme_color_override("font_color", LABEL)
	b.add_theme_color_override("font_hover_color", SEL)
	return b

func _label(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	return l

func _spacer(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	return c

func _zero(c: Control) -> void:
	for k in ["left", "top", "right", "bottom"]:
		c.set("offset_" + k, 0.0)

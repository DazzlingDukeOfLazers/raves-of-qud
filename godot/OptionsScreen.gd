extends Control

## THE OPTIONS SCREEN — Raves' settings, laid out in the style of Caves of Qud's Options.
##
## A full-screen scrollable panel over the cave-art background: an "OPTIONS" header, a LEFT
## category sidebar (jump-to-section), and a scrollable main column of collapsible-looking
## sections (Display / Interface / Bridge), each with sliders / toggles / option-rows / text
## fields. Qud's Options is game settings that don't apply to a viewer, so the CONTENT is
## Raves-relevant (font scale, fullscreen, perceived-vs-full default, default camera, which
## Qud to render), persisted via the [[Settings]] autoload. Opened as an overlay by MainMenu;
## `closed` fires on Back.

signal closed

const SCRIM := Color(0.02, 0.03, 0.03, 0.60)
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # OPTIONS title, values, keycaps
const CYAN := Color8(0x6E, 0xB5, 0xC9)           # section headers, sidebar categories
const LABEL := Color8(0xE4, 0xD8, 0xB8)          # setting labels
const VALUE := Color8(0xC8, 0xA9, 0x4E)          # setting values
const SEL := Color8(0xF6, 0xF6, 0xF6)            # selected option
const DIM := Color(0.89, 0.85, 0.72, 0.5)
const FRAME := Color8(0xB6, 0xA1, 0x63)

## The settings model — sections of typed items keyed to Settings.
const SECTIONS := [
	{"name": "DISPLAY", "items": [
		{"key": "font_scale", "label": "Font scale", "type": "slider", "min": 0.7, "max": 1.5, "step": 0.05},
		{"key": "fullscreen", "label": "Fullscreen", "type": "toggle"},
	]},
	{"name": "INTERFACE", "items": [
		{"key": "full_info", "label": "Show full info by default", "type": "toggle"},
		{"key": "camera", "label": "Default camera", "type": "options",
			"options": ["Compass", "Follow", "First person", "Cinematic", "Mouse", "Keyboard", "Top follow"]},
	]},
	{"name": "BRIDGE", "items": [
		{"key": "bridge_host", "label": "Host", "type": "text"},
		{"key": "bridge_port", "label": "Port", "type": "text"},
	]},
]

var _scroll: ScrollContainer
var _anchors: Dictionary = {}   # section name -> its header Control (for sidebar jumps)

func _ready() -> void:
	name = "OptionsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())

	# Opaque background — hides the menu behind (Qud's Options replaces the menu). The cave
	# art heavily darkened, matching Qud's near-black Options backdrop; solid dark if absent.
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

## A clickable "‹ Back" at a fixed bottom-left spot (Esc also works) — the mouse route back
## to the menu, and a stable target for the regression suite's reset step.
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

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── layout ───────────────────────────────────────────────────────────────────────

func _build_header() -> void:
	var l := _label("OPTIONS", GOLD, "title")
	l.anchor_left = 0.17
	l.anchor_right = 0.6
	l.anchor_top = 0.06
	l.anchor_bottom = 0.11
	_zero(l)
	add_child(l)

func _build_sidebar() -> void:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 8)
	v.anchor_left = 0.02
	v.anchor_right = 0.15
	v.anchor_top = 0.13
	v.anchor_bottom = 0.9
	_zero(v)
	add_child(v)
	for sec in SECTIONS:
		var b := Button.new()
		b.text = String(sec["name"]).capitalize()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.flat = true
		b.add_theme_color_override("font_color", CYAN)
		b.add_theme_color_override("font_hover_color", SEL)
		b.pressed.connect(func(): _jump_to(sec["name"]))
		v.add_child(b)

func _build_body() -> void:
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.anchor_left = 0.17
	_scroll.anchor_right = 0.95
	_scroll.anchor_top = 0.13
	_scroll.anchor_bottom = 0.9
	_zero(_scroll)
	add_child(_scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	_scroll.add_child(col)
	for sec in SECTIONS:
		var head := _label("[-]  " + String(sec["name"]), CYAN, "title")
		col.add_child(head)
		_anchors[sec["name"]] = head
		for item in sec["items"]:
			col.add_child(_build_setting(item))
		col.add_child(_spacer(14))

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
	l.anchor_bottom = 0.98
	_zero(l)
	add_child(l)

# ── setting widgets ────────────────────────────────────────────────────────────────

func _build_setting(item: Dictionary) -> Control:
	match String(item.get("type", "")):
		"slider":
			return _setting_slider(item)
		"toggle":
			return _setting_toggle(item)
		"options":
			return _setting_options(item)
		"text":
			return _setting_text(item)
		_:
			return _label(str(item.get("label", "?")), LABEL, "body")

func _setting_slider(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = float(item["min"])
	s.max_value = float(item["max"])
	s.step = float(item["step"])
	s.value = float(Settings.get_value(item["key"], 1.0))
	s.custom_minimum_size = Vector2(420, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := _label("%.2f" % s.value, VALUE, "body")
	s.value_changed.connect(func(v):
		val.text = "%.2f" % v
		Settings.set_value(item["key"], v)
		Settings.save()
		if item["key"] == "font_scale":
			_retheme())
	h.add_child(s)
	h.add_child(val)
	row.add_child(h)
	return row

func _setting_toggle(item: Dictionary) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.add_theme_color_override("font_color", LABEL)
	b.add_theme_color_override("font_hover_color", SEL)
	var on := bool(Settings.get_value(item["key"], false))
	b.text = ("[■]  " if on else "[  ]  ") + str(item["label"])
	b.pressed.connect(func():
		var now := not bool(Settings.get_value(item["key"], false))
		Settings.set_value(item["key"], now)
		Settings.save()
		b.text = ("[■]  " if now else "[  ]  ") + str(item["label"]))
	return b

func _setting_options(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var opts: Array = item["options"]
	var cur := int(Settings.get_value(item["key"], 0))
	var btns: Array = []
	for i in range(opts.size()):
		var b := Button.new()
		b.text = str(opts[i])
		b.focus_mode = Control.FOCUS_NONE
		b.flat = true
		b.add_theme_color_override("font_color", SEL if i == cur else DIM)
		b.add_theme_color_override("font_hover_color", SEL)
		var idx := i
		b.pressed.connect(func():
			Settings.set_value(item["key"], idx)
			Settings.save()
			for j in range(btns.size()):
				btns[j].add_theme_color_override("font_color", SEL if j == idx else DIM))
		btns.append(b)
		h.add_child(b)
	row.add_child(h)
	return row

func _setting_text(item: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.add_child(_label(str(item["label"]) + ":", LABEL, "body"))
	var e := LineEdit.new()
	var raw: Variant = Settings.get_value(item["key"], "")
	e.text = str(int(raw)) if item["key"] == "bridge_port" else str(raw)   # JSON reads ints as floats
	e.custom_minimum_size = Vector2(320, 0)
	e.add_theme_color_override("font_color", VALUE)
	var commit := func(_t = null):
		var v: Variant = e.text
		if item["key"] == "bridge_port":
			v = int(e.text)
		Settings.set_value(item["key"], v)
		Settings.save()
	e.text_submitted.connect(commit)
	e.focus_exited.connect(commit)
	h.add_child(e)
	return h

# ── behaviour ────────────────────────────────────────────────────────────────────

func _jump_to(section: String) -> void:
	var head: Control = _anchors.get(section)
	if head != null and _scroll != null:
		_scroll.ensure_control_visible(head)

## Font scale changed — re-stamp this screen's theme and the menu behind it so it updates live.
func _retheme() -> void:
	theme = UiFont.make_theme(get_viewport())
	var parent := get_parent()
	if parent is Control:
		(parent as Control).theme = UiFont.make_theme(get_viewport())

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()

# ── helpers ──────────────────────────────────────────────────────────────────────

func _label(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	return l

func _load_png(rel: String) -> Texture2D:
	var path := InputModel.support_dir().path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _spacer(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	return c

func _zero(c: Control) -> void:
	for k in ["left", "top", "right", "bottom"]:
		c.set("offset_" + k, 0.0)

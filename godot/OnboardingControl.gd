extends Node
class_name OnboardingControl

## First-run / reconfigure control chooser. A modal wizard:
##   1. DEVICES        — which inputs you'll use (keyboard, mouse, gamepad, CLI).
##   2. KEYBOARD TYPE  — if keyboard: function-keys scheme or numpad scheme.
##   3. LAYOUT         — a keyboard drawn with the FUNCTION on each key (read live
##                       from InputModel), then the mouse gestures.
##
## Everything shown is read from InputModel — the same catalog the live handler is
## seeded from — so the layout can never claim a key does something it doesn't. Key
## REBINDING is the next step; this screen is the read-only view it will build on.

signal closed

# Sage palette, matched to TileReport/CellInspector so the app reads as one thing.
const BG := Color(0.03, 0.05, 0.04, 0.98)
const BORDER := Color(0.45, 0.85, 0.55, 0.9)
const TITLE := Color(0.65, 0.95, 0.7)
const BODY := Color(0.8, 0.9, 0.8)
const DIM := Color(0.55, 0.7, 0.55)
const ACCENT := Color(0.95, 0.85, 0.5)
const CAP_BG := Color(0.08, 0.13, 0.10, 1.0)
const CAP_BG_SEL := Color(0.12, 0.22, 0.15, 1.0)

enum Screen { DEVICES, KEYBOARD_TYPE, LAYOUT_KBD, LAYOUT_MOUSE }

# These sizes were tuned on a ~900px-tall window; on a big/4K display they read tiny. Scale every
# font size and fixed dimension by the window height so the wizard matches the rest of the UI. And
# route text through the bundled Atkinson font (a Theme default_font) — the bare default font was
# rendering pixelated next to the inspector's crisp Atkinson text.
const REF_H := 900.0
var _scale := 1.0
var _ui_theme: Theme
var _built := false

var _model: InputModel
var _layer: CanvasLayer
var _panel: PanelContainer
var _title: Label
var _subtitle: Label
var _content: VBoxContainer
var _nav: HBoxContainer
var _screen: int = Screen.DEVICES

func setup() -> void:
	_model = InputModel.new()
	# NB: the UI is built LAZILY on first open() — at setup() (startup) the viewport still reports
	# project.godot's 1600x900, so scaling here computed 1.0 and nothing grew. By the time the user
	# opens the wizard the window is maximized, so _ensure_built() reads the real height.

## Build the wizard once, on first open, scaled to the (now-maximized) window.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	var vp := get_viewport()
	var h: float = vp.get_visible_rect().size.y if vp else REF_H
	_scale = maxf(1.0, h / REF_H)
	_ui_theme = Theme.new()
	var font := load("res://fonts/AtkinsonHyperlegible-Regular.ttf")
	if font != null:
		_ui_theme.default_font = font   # crisp, matches the inspector; propagates to every child
	_build()

## Scaled font size / pixel dimension for the current window.
func _fs(base: int) -> int:
	return int(round(base * _scale))

func _px(base: float) -> float:
	return base * _scale

func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 3   # above the debug menu (layer 2)
	_layer.visible = false
	add_child(_layer)

	# Full-rect dim that also makes the wizard modal — a STOP mouse_filter eats clicks
	# so nothing leaks to the 3D view behind it.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(dim)

	_panel = PanelContainer.new()
	_panel.theme = _ui_theme   # Atkinson default_font + inherits to every label/button below
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(_px(760), 0)
	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	_layer.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_color_override("font_color", TITLE)
	_title.add_theme_font_size_override("font_size", _fs(24))
	box.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_color_override("font_color", DIM)
	_subtitle.add_theme_font_size_override("font_size", _fs(16))
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_subtitle)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(_px(720), _px(420))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	var sep := HSeparator.new()
	box.add_child(sep)

	_nav = HBoxContainer.new()
	_nav.add_theme_constant_override("separation", 8)
	box.add_child(_nav)

# --- open / close -----------------------------------------------------------

func open() -> void:
	_ensure_built()
	_model.load_config()
	_screen = Screen.DEVICES
	_goto(Screen.DEVICES)
	_layer.visible = true

func close() -> void:
	_model.save_config()
	_layer.visible = false
	closed.emit()

## Open directly to a named screen. Used by the remote command channel (control.py
## `onboard <screen>`) so each screen can be screenshotted without a human at F1.
## Does NOT save — a screenshot of the numpad layout shouldn't rewrite the user's
## chosen keyboard type.
func show_screen(name: String) -> void:
	_ensure_built()
	_model.load_config()
	match name:
		"ktype", "keyboard_type":
			_goto(Screen.KEYBOARD_TYPE)
		"layout", "function", "kbd":
			_model.keyboard_type = InputModel.KeyboardType.FUNCTION_KEYS
			_goto(Screen.LAYOUT_KBD)
		"numpad":
			_model.keyboard_type = InputModel.KeyboardType.NUMPAD
			_goto(Screen.LAYOUT_KBD)
		"mouse":
			_goto(Screen.LAYOUT_MOUSE)
		_:
			_goto(Screen.DEVICES)
	_layer.visible = true

func is_open() -> bool:
	return _layer != null and _layer.visible

## Swallow input while open so the arrows behind the wizard don't move the player.
## _input runs before Main._unhandled_input, so marking keys handled hides them.
func _input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_back_or_close()
		get_viewport().set_input_as_handled()

# --- navigation -------------------------------------------------------------

func _goto(screen: int) -> void:
	_screen = screen
	for c in _content.get_children():
		c.queue_free()
	for c in _nav.get_children():
		c.queue_free()
	match screen:
		Screen.DEVICES:       _build_devices()
		Screen.KEYBOARD_TYPE: _build_keyboard_type()
		Screen.LAYOUT_KBD:    _build_layout_kbd()
		Screen.LAYOUT_MOUSE:  _build_layout_mouse()

func _back_or_close() -> void:
	match _screen:
		Screen.DEVICES:       close()
		Screen.KEYBOARD_TYPE: _goto(Screen.DEVICES)
		Screen.LAYOUT_KBD:    _goto(Screen.KEYBOARD_TYPE)
		Screen.LAYOUT_MOUSE:
			_goto(Screen.LAYOUT_KBD if _model.has_device(InputModel.Device.KEYBOARD) else Screen.DEVICES)

## The next screen in the wizard, given which devices are selected. Keyboard drills
## into its type + layout; mouse into its gestures; otherwise we're done.
func _advance() -> void:
	match _screen:
		Screen.DEVICES:
			if _model.has_device(InputModel.Device.KEYBOARD):
				_goto(Screen.KEYBOARD_TYPE)
			elif _model.has_device(InputModel.Device.MOUSE):
				_goto(Screen.LAYOUT_MOUSE)
			else:
				close()
		Screen.KEYBOARD_TYPE:
			_goto(Screen.LAYOUT_KBD)
		Screen.LAYOUT_KBD:
			if _model.has_device(InputModel.Device.MOUSE):
				_goto(Screen.LAYOUT_MOUSE)
			else:
				close()
		Screen.LAYOUT_MOUSE:
			close()

func _add_nav(back_label: String, next_label: String) -> void:
	var back := Button.new()
	back.text = back_label
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_back_or_close)
	_nav.add_child(back)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nav.add_child(spacer)

	var next := Button.new()
	next.text = next_label
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_advance)
	_nav.add_child(next)

# --- screen 1: devices ------------------------------------------------------

const _DEVICE_INFO := [
	[InputModel.Device.KEYBOARD, "Keyboard", "Arrow/letter keys or the numpad"],
	[InputModel.Device.MOUSE, "Mouse", "Inspect, orbit, and zoom"],
	[InputModel.Device.GAMEPAD, "Gamepad", "Not yet mapped — coming soon"],
	[InputModel.Device.CLI, "Command line", "Drive headlessly via tools/capture/control.py"],
]

func _build_devices() -> void:
	_title.text = "How do you want to play?"
	_subtitle.text = "Pick every input you plan to use — you can combine them."
	for row in _DEVICE_INFO:
		var dev: int = row[0]
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = _model.has_device(dev)
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 48)
		b.add_theme_font_size_override("font_size", _fs(18))
		_style_device_button(b, row[1], row[2], b.button_pressed)
		b.toggled.connect(func(on: bool):
			_set_device(dev, on)
			_style_device_button(b, row[1], row[2], on))
		_content.add_child(b)
	_add_nav("Close", "Next  ›")

func _set_device(dev: int, on: bool) -> void:
	if on and not _model.devices.has(dev):
		_model.devices.append(dev)
	elif not on:
		_model.devices.erase(dev)

func _style_device_button(b: Button, name: String, desc: String, on: bool) -> void:
	b.text = "%s  %s\n     %s" % ["☑" if on else "☐", name, desc]
	b.add_theme_color_override("font_color", TITLE if on else BODY)

# --- screen 2: keyboard type ------------------------------------------------

const _KBD_TYPE_INFO := [
	[InputModel.KeyboardType.FUNCTION_KEYS, "Function & arrow keys", "Arrows move (relative to the camera); number row and letters for camera and tools. Best on laptops without a numpad."],
	[InputModel.KeyboardType.NUMPAD, "Numeric keypad", "Numpad 1-9 as an absolute 8-way compass — precise cardinal stepping. Needs a full keyboard."],
]

func _build_keyboard_type() -> void:
	_title.text = "What kind of keyboard?"
	_subtitle.text = "This chooses your default movement scheme. You can change it anytime."
	for row in _KBD_TYPE_INFO:
		var type: int = row[0]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 64)
		b.add_theme_font_size_override("font_size", _fs(18))
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_style_type_button(b, row[1], row[2], _model.keyboard_type == type)
		b.pressed.connect(func():
			_model.keyboard_type = type
			_goto(Screen.KEYBOARD_TYPE))   # redraw to show the new selection
		_content.add_child(b)
	_add_nav("‹ Back", "Show layout  ›")

func _style_type_button(b: Button, name: String, desc: String, on: bool) -> void:
	b.text = "%s  %s\n     %s" % ["●" if on else "○", name, desc]
	b.add_theme_color_override("font_color", TITLE if on else BODY)

# --- screen 3a: keyboard layout ---------------------------------------------

func _build_layout_kbd() -> void:
	var is_numpad := _model.keyboard_type == InputModel.KeyboardType.NUMPAD
	_title.text = "Numpad layout" if is_numpad else "Keyboard layout"
	_subtitle.text = "What each key does. Hover a key for detail. (Rebinding comes next.)"
	if is_numpad:
		_build_numpad_grid()
	else:
		_build_function_keys()

## The numpad drawn as its physical 3x3, each key showing the compass step it sends.
func _build_numpad_grid() -> void:
	_content.add_child(_section_label("Movement — absolute 8-way compass"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	var rows := [
		["step_nw", "step_n", "step_ne"],
		["step_w", "", "step_e"],
		["step_sw", "step_s", "step_se"],
	]
	for r in rows:
		for id in r:
			if id == "":
				grid.add_child(_blank_cap())
			else:
				grid.add_child(_cap(id))
	_content.add_child(grid)
	# camera + tools still apply under the numpad scheme
	_add_cluster("Camera", ["cam_compass", "cam_follow", "cam_first_person", "cam_cinematic", "cam_mouse", "cam_keyboard"])
	_add_cluster("Camera control", ["rotate_left", "rotate_right", "debug_menu"])
	_add_cluster("View & tools", ["inspect", "screenshot", "font_smaller", "font_larger", "cancel"])
	_add_nav("‹ Back", "Next  ›")

func _build_function_keys() -> void:
	_add_cluster("Camera modes (number row)", ["cam_compass", "cam_follow", "cam_first_person", "cam_cinematic", "cam_mouse", "cam_keyboard"])

	# arrows as an inverted-T
	_content.add_child(_section_label("Movement — relative to the camera"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.add_child(_blank_cap()); grid.add_child(_cap("move_forward")); grid.add_child(_blank_cap())
	grid.add_child(_cap("move_left")); grid.add_child(_cap("move_back")); grid.add_child(_cap("move_right"))
	_content.add_child(grid)

	_add_cluster("Camera control", ["rotate_left", "rotate_right", "debug_menu"])
	_add_cluster("Fly camera (mode 6)", ["fly_forward", "fly_left", "fly_back", "fly_right"])
	_add_cluster("View & tools", ["inspect", "screenshot", "font_smaller", "font_larger", "dump_profile", "cancel"])
	_add_nav("‹ Back", "Next  ›")

# --- screen 3b: mouse -------------------------------------------------------

func _build_layout_mouse() -> void:
	_title.text = "Mouse"
	_subtitle.text = "Gestures in the Raves viewport."
	for id in _model.mouse_actions():
		_content.add_child(_gesture_row(id))
	_add_nav("‹ Back", "Done")

# --- widgets ----------------------------------------------------------------

func _add_cluster(title: String, ids: Array) -> void:
	_content.add_child(_section_label(title))
	var flow := HBoxContainer.new()
	flow.add_theme_constant_override("separation", 6)
	for id in ids:
		flow.add_child(_cap(id))
	_content.add_child(flow)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", ACCENT)
	l.add_theme_font_size_override("font_size", _fs(15))
	return l

## One key cap: the legend printed big, the action's short label under it, the full
## description on hover. Reads the LIVE keycode so a rebind would show here too.
func _cap(id: String) -> Control:
	var a: Dictionary = InputModel.ACTIONS.get(id, {})
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(96, 60)
	pc.tooltip_text = String(a.get("desc", ""))
	var style := StyleBoxFlat.new()
	style.bg_color = CAP_BG
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	pc.add_theme_stylebox_override("panel", style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	pc.add_child(vb)

	var legend := Label.new()
	legend.text = String(a.get("legend", "?"))
	legend.add_theme_color_override("font_color", TITLE)
	legend.add_theme_font_size_override("font_size", _fs(20))
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(legend)

	var fn := Label.new()
	fn.text = String(a.get("label", id))
	fn.add_theme_color_override("font_color", BODY)
	fn.add_theme_font_size_override("font_size", _fs(12))
	fn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fn.custom_minimum_size = Vector2(84, 0)
	vb.add_child(fn)
	return pc

func _blank_cap() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(96, 60)
	return c

func _gesture_row(id: String) -> Control:
	var a: Dictionary = InputModel.ACTIONS.get(id, {})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var chip := Label.new()
	chip.text = String(a.get("legend", "?"))
	chip.add_theme_color_override("font_color", TITLE)
	chip.add_theme_font_size_override("font_size", _fs(16))
	chip.custom_minimum_size = Vector2(120, 0)
	row.add_child(chip)

	var desc := Label.new()
	desc.text = String(a.get("desc", ""))
	desc.add_theme_color_override("font_color", BODY)
	desc.add_theme_font_size_override("font_size", _fs(16))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(desc)
	return row

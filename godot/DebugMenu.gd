extends Node

## The backtick (`) debug menu — extracted from Main. A panel of camera-mode buttons, the all-views
## toggle, tuning sliders (first-person height, deep-water depth, level Z-gap), and toggles
## (Q/E step, look target, 2D/3D, font ruler).
##
## Stage 4 of the Main.gd decomposition. Holds refs to the CameraRig (fp height + compass/look toggles),
## the renderer (slider init values), and the Multiview (its toggle); reaches the rest through Main
## callbacks — set_mode, toggle_flat_2d (Main owns that: the O key + persistent button share it), the font
## ruler, and the live-apply water/level handlers (they re-render via Main's store). Enum-free: modes are
## ints matching CameraRig.CamMode's order. Main drives font sizing + placement through panel().

const MODES := [0, 1, 2, 3, 4, 5, 6]

var _cam_rig                       # CameraRig: _fp_height, _compass_45, _look_head, _mode
var _renderer                      # ZoneRenderer: deep_water_depth / level_height slider init values
var _panel: PanelContainer
var _title: Label
var _mode_buttons := {}
var _compass_step_btn: Button
var _look_btn: Button
var _wm_face_btn: Button

## `callbacks` = {set_mode(int), toggle_flat_2d(), font_ruler(), water_changed(float), level_changed(float)}.
func build(cam_rig, renderer_ref, multiview, mode_names: Dictionary, callbacks: Dictionary) -> void:
	_cam_rig = cam_rig
	_renderer = renderer_ref
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 34)
	panel.visible = false
	layer.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Debug · camera  (`)"
	_title = title
	vb.add_child(title)
	for m in MODES:
		var b := Button.new()
		b.text = "%d  %s" % [m + 1, String(mode_names[m]).split(" —")[0].split(" ·")[0]]
		# click-only: don't take keyboard focus, or a focused button swallows the movement arrows
		# (Godot uses them for UI focus navigation) after any click.
		b.focus_mode = Control.FOCUS_NONE
		var mv: int = m
		b.pressed.connect(func(): callbacks["set_mode"].call(mv))
		vb.add_child(b)
		_mode_buttons[m] = b
	# all-views grid (differential testing)
	var mvb := Button.new()
	mvb.text = "0  MULTI-VIEW (all)"
	mvb.focus_mode = Control.FOCUS_NONE
	mvb.pressed.connect(multiview.toggle)
	vb.add_child(mvb)
	# first-person eye-height slider
	var hl := Label.new()
	hl.text = "first-person height"
	vb.add_child(hl)
	var sld := HSlider.new()
	sld.min_value = 0.15
	sld.max_value = 3.0
	sld.step = 0.05
	sld.value = _cam_rig._fp_height
	sld.custom_minimum_size = Vector2(160, 0)
	sld.focus_mode = Control.FOCUS_NONE   # drag-only; keep arrows for the player
	sld.value_changed.connect(func(v): _cam_rig._fp_height = v)
	vb.add_child(sld)
	# deep-water depth slider (0 = swimmers ride the surface, 1 = a full tile under)
	var wl := Label.new()
	wl.text = "deep water depth"
	vb.add_child(wl)
	var wsld := HSlider.new()
	wsld.min_value = 0.0
	wsld.max_value = 1.0
	wsld.step = 0.05
	wsld.value = _renderer.deep_water_depth
	wsld.custom_minimum_size = Vector2(160, 0)
	wsld.focus_mode = Control.FOCUS_NONE
	wsld.value_changed.connect(callbacks["water_changed"])
	vb.add_child(wsld)
	# level height: vertical gap between stacked Z-levels (0 = coplanar)
	var ll := Label.new()
	ll.text = "level height (Z gap)"
	vb.add_child(ll)
	var lsld := HSlider.new()
	lsld.min_value = 0.0
	lsld.max_value = 16.0
	lsld.step = 0.5
	lsld.value = _renderer.level_height
	lsld.custom_minimum_size = Vector2(160, 0)
	lsld.focus_mode = Control.FOCUS_NONE
	lsld.value_changed.connect(callbacks["level_changed"])
	vb.add_child(lsld)
	# COMPASS Q/E rotation step: 45° (8-way) or 90° (cardinal)
	_compass_step_btn = Button.new()
	_compass_step_btn.focus_mode = Control.FOCUS_NONE
	_compass_step_btn.pressed.connect(_toggle_compass_step)
	vb.add_child(_compass_step_btn)
	_refresh_compass_step_btn()
	# camera look target: the head or the waist
	_look_btn = Button.new()
	_look_btn.focus_mode = Control.FOCUS_NONE
	_look_btn.pressed.connect(_toggle_look_target)
	vb.add_child(_look_btn)
	_refresh_look_btn()
	# font-size ruler (Lorem Ipsum at each px) — for tuning UiFont.FRAC / UiFont.MIN. Key: L.
	var fp_btn := Button.new()
	fp_btn.text = "Font-size ruler (L)"
	fp_btn.focus_mode = Control.FOCUS_NONE
	fp_btn.pressed.connect(callbacks["font_ruler"])
	vb.add_child(fp_btn)
	# 2D/3D: lay the whole world flat (classic 2D map) or stand it up as billboards. Key: O.
	_wm_face_btn = Button.new()
	_wm_face_btn.focus_mode = Control.FOCUS_NONE
	_wm_face_btn.pressed.connect(callbacks["toggle_flat_2d"])
	vb.add_child(_wm_face_btn)
	refresh_flat_2d(false)   # world starts 3D
	_panel = panel
	set_active_mode(_cam_rig._mode)

## The panel Control, so Main's font sizing + placement can reach it (it's under a CanvasLayer, a theme-root
## trap, so Main stamps it explicitly).
func panel() -> Control:
	return _panel

func toggle() -> void:
	if _panel != null:
		_panel.visible = not _panel.visible

func is_open() -> bool:
	return _panel != null and _panel.visible

func close() -> void:
	if _panel != null:
		_panel.visible = false

## Highlight the active camera-mode button (Main calls this from _update_mode_label).
func set_active_mode(mode: int) -> void:
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).modulate = Color(0.55, 1.0, 0.55) if m == mode else Color(1, 1, 1)

## Update the menu's 2D/3D face button. Main owns the flat state (also the O key + persistent button), so
## it passes the current value in whenever it flips.
func refresh_flat_2d(flat: bool) -> void:
	if _wm_face_btn != null:
		_wm_face_btn.text = "tiles (O): %s" % ("2D flat" if flat else "3D billboards")

func _refresh_compass_step_btn() -> void:
	if _compass_step_btn != null:
		_compass_step_btn.text = "Q/E rotate: %s" % ("45°" if _cam_rig._compass_45 else "90°")

func _refresh_look_btn() -> void:
	if _look_btn != null:
		_look_btn.text = "camera follows: %s" % ("head" if _cam_rig._look_head else "waist")

func _toggle_look_target() -> void:
	_cam_rig._look_head = not _cam_rig._look_head
	_refresh_look_btn()

func _toggle_compass_step() -> void:
	_cam_rig._compass_45 = not _cam_rig._compass_45
	_refresh_compass_step_btn()

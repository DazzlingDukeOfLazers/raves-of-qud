extends Node

## Multi-view camera grid — extracted from Main. A GridContainer of live SubViewports, one per camera
## mode, all sharing the main 3D world, so every view can be compared at once (differential testing).
## Toggle with `0` or the ` debug menu; click a pane to inspect that tile through that pane's camera.
##
## Stage 2 of the Main.gd decomposition. Depends only on the CameraRig (for the per-pane placement math)
## and a pane-inspect Callable (Main keeps that — it owns the inspector + report form). Enum-free: modes
## are plain ints matching CameraRig.CamMode's order.

const TOP_FOLLOW := 6              # CamMode.TOP_FOLLOW — the one orthographic mode (kept enum-free)
const MODES := [0, 1, 2, 3, 4, 5, 6]   # CamMode order: COMPASS, FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW

var _cam_rig                       # CameraRig: per-pane eye/look math + shared cam fov
var _mode_names: Dictionary        # mode int -> label string (Main's _MODE_NAMES), for the pane captions
var _on_pane_inspect: Callable     # Main._multiview_inspect(cam, pos) — it owns the inspector/reporter
var _on_pick_mode: Callable        # Main._set_mode(mode) — clicking a pane's TITLE switches to it
var _layer: CanvasLayer
var _on := false
var _cams: Array = []              # [{mode, cam, sv}]

## Build the grid. Call once, after the CameraRig's camera exists (we read its fov) and while in the tree
## (we bind the shared World3D off get_viewport()).
func setup(cam_rig, mode_names: Dictionary, on_pane_inspect: Callable,
		on_pick_mode := Callable()) -> void:
	_cam_rig = cam_rig
	_mode_names = mode_names
	_on_pane_inspect = on_pane_inspect
	_on_pick_mode = on_pick_mode
	_layer = CanvasLayer.new()
	_layer.layer = 4
	_layer.visible = false
	add_child(_layer)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	_layer.add_child(grid)
	var shared := get_viewport().find_world_3d()
	for m in MODES:
		var cell := Control.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell.custom_minimum_size = Vector2(320, 200)
		var svc := SubViewportContainer.new()
		svc.stretch = true
		svc.set_anchors_preset(Control.PRESET_FULL_RECT)
		svc.mouse_filter = Control.MOUSE_FILTER_IGNORE   # let clicks reach the cell
		var sv := SubViewport.new()
		sv.world_3d = shared
		sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
		svc.add_child(sv)
		var cam := Camera3D.new()
		cam.fov = _cam_rig._cam.fov
		# THE FIRST-PERSON PANE DROPS THE PLAYER, and only that pane. All seven panes render out
		# of ONE World3D, so the old trick -- not PLACING the player's cell while in first person
		# -- could only ever be right for every pane at once: it hid him from all seven, and with
		# any other mode active it left him standing in front of this camera. ZoneRenderer tags
		# the player's cell onto PLAYER_LAYER for exactly this.
		if m == 2:   # CamMode.FIRST_PERSON
			cam.cull_mask &= ~ZoneRenderer.PLAYER_LAYER
		sv.add_child(cam)
		cam.current = true   # the active camera for this sub-viewport
		cell.add_child(svc)
		# THE TITLE PICKS THE CAMERA; the pane body still inspects (below). Two actions on one
		# pane, split by where you click -- the caption is the only part of a live 3D view that is
		# safe to claim for a click, and "click the name of the camera you want" is what the name
		# already looks like it means.
		var lbl := Label.new()
		lbl.text = "%d  %s" % [m + 1, String(_mode_names.get(m, "?")).split(" —")[0]]
		lbl.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _on_pick_mode.is_valid():
			lbl.mouse_filter = Control.MOUSE_FILTER_STOP   # STOP, so the pane's inspect never also fires
			lbl.tooltip_text = "Switch to this camera"
			lbl.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			var pick_mode: int = m
			lbl.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					# _set_mode closes this grid itself (picking a mode leaves the multi-view), so
					# there is no toggle to do here -- doing one as well would reopen it.
					_on_pick_mode.call(pick_mode))
		cell.add_child(lbl)
		# Left-click a pane = inspect the tile under the cursor with THAT pane's camera; the marker lives
		# in the shared world, so it appears in every pane at once. Number keys (1-7) still switch full-screen.
		var pane_cam := cam
		cell.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_on_pane_inspect.call(pane_cam, e.position))
		grid.add_child(cell)
		_cams.append({"mode": m, "cam": cam, "sv": sv})

func is_on() -> bool:
	return _on

## Flip the grid on/off. Syncs the rig's multiview flag BEFORE it recomputes the zstretch (the shared
## world must read square in the grid; a single top-down view stretches).
func toggle() -> void:
	if _layer == null:
		return
	_on = not _on
	_cam_rig.set_multiview(_on)
	_layer.visible = _on
	for v in _cams:
		(v["sv"] as SubViewport).render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if _on else SubViewport.UPDATE_DISABLED
	_cam_rig.apply_zstretch()

## Per-frame while on: point each preview camera at its mode's view, off the shared rig math.
func update() -> void:
	for v in _cams:
		var m: int = v["mode"]
		var cam: Camera3D = v["cam"]
		var el: Array = _cam_rig.eye_look_for(m)
		var eye: Vector3 = el[0]
		var look: Vector3 = el[1]
		var top := m == TOP_FOLLOW
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL if top else Camera3D.PROJECTION_PERSPECTIVE
		if top:
			cam.size = _cam_rig._top_ortho_size()
		cam.position = eye
		if eye.distance_to(look) > 0.001:
			cam.look_at(look, _cam_rig.NORTH if top else Vector3.UP)

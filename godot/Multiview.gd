extends Node

## Multi-view camera grid — extracted from Main. A GridContainer of live SubViewports, one per camera
## mode, all sharing the main 3D world, so every view can be compared at once (differential testing).
## Toggle with `0` or the ` debug menu; click a pane to inspect that tile through that pane's camera.
##
## Stage 2 of the Main.gd decomposition. Depends only on the CameraRig (for the per-pane placement math)
## and a pane-inspect Callable (Main keeps that — it owns the inspector + report form). Enum-free: modes
## are plain ints matching CameraRig.CamMode's order.

const TOP_FOLLOW := 6              # CamMode.TOP_FOLLOW — the one orthographic mode (kept enum-free)
const MODES := [0, 1, 2, 3, 4, 5, 6]
const PANE_ZOOM_MIN := 0.25
const PANE_ZOOM_MAX := 4.0   # CamMode order: COMPASS, FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW

var _cam_rig                       # CameraRig: per-pane eye/look math + shared cam fov
var _mode_names: Dictionary        # mode int -> label string (Main's _MODE_NAMES), for the pane captions
var _on_pane_inspect: Callable     # Main._multiview_inspect(cam, pos) — it owns the inspector/reporter
var _on_pick_mode: Callable        # Main._set_mode(mode) — clicking a pane's TITLE switches to it
var _on_move: Callable             # Main: send a Qud move in a COMPASS direction ("N", "SE", …)
var _layer: CanvasLayer
var _on := false
var _cams: Array = []              # [{mode, cam, sv, st}] — st is this pane's own yaw/zoom
var _cells: Array = []             # the Control per pane, for hanging per-pane UI on

## Build the grid. Call once, after the CameraRig's camera exists (we read its fov) and while in the tree
## (we bind the shared World3D off get_viewport()).
func setup(cam_rig, mode_names: Dictionary, on_pane_inspect: Callable,
		on_pick_mode := Callable(), on_move := Callable()) -> void:
	_cam_rig = cam_rig
	_mode_names = mode_names
	_on_pane_inspect = on_pane_inspect
	_on_pick_mode = on_pick_mode
	_on_move = on_move
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
		# PER-PANE CAMERA STATE. A pane owns its heading and its distance and nothing else: the
		# position every mode derives from the player is shared for free, which is what makes all
		# seven panes follow a move together while each can be turned on its own. A fresh pane is
		# {yaw 0, zoom 1}, i.e. exactly the camera this pane showed before there was any state.
		# Cinematic panes get a phase offset so two of them do not orbit in lockstep.
		_cams.append({"mode": m, "cam": cam, "sv": sv,
			"st": _cam_rig.pane_state(0.0, 1.0, float(m) * 0.7),
			"btns": [], "cine_speed": 1.0})
		_cells.append(cell)
		_build_pane_ui(cell, _cams.size() - 1, m)
		for n in (_cams[_cams.size() - 1].get("ui", []) as Array):
			(n as CanvasItem).visible = false      # revealed on hover; the VIEW is the point


# --- per-pane widgets -----------------------------------------------------------
#
# Every pane carries its own controls because every pane now has its own camera state (see
# pane_state). They are deliberately small and cornered: a pane is 320x200 at minimum and the
# VIEW is the point — controls that crowd it would defeat the grid they sit in.

const DIR_NAMES := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
## The 3x3 ring, clockwise from the top-left cell, with the centre skipped. Index into DIR_NAMES
## is the SCREEN direction; which WORLD direction that is depends on where the pane is looking,
## which is the whole point of "normalize the arrows to the compass".
const RING := [[7, 0, 1], [6, -1, 2], [5, 4, 3]]
const ARROWS := ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]

func _small_btn(txt: String, tip: String, w := 26.0, h := 20.0) -> Button:
	var b := Button.new()
	b.text = txt
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(w, h)
	b.focus_mode = Control.FOCUS_NONE      # MainFrame's rule: never steal the movement keys
	b.add_theme_font_size_override("font_size", 10)
	return b

func _build_pane_ui(cell: Control, i: int, m: int) -> void:
	# COMPASS RING, bottom-left. Eight buttons around an empty centre; each MOVES the player in
	# the world direction that lies that way ON SCREEN in this pane, and is LABELLED with the
	# cardinal that turns out to be. Rotate the pane and the letters follow, which is what makes
	# the ring readable when two panes face different ways.
	var ring := GridContainer.new()
	ring.columns = 3
	ring.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ring.position = Vector2(6, -74)
	ring.add_theme_constant_override("h_separation", 1)
	ring.add_theme_constant_override("v_separation", 1)
	var btns: Array = []
	for row in RING:
		for d in row:
			if d < 0:
				var spacer := Control.new()
				spacer.custom_minimum_size = Vector2(26, 20)
				ring.add_child(spacer)
				btns.append(null)
				continue
			var b := _small_btn("", "move")
			var screen_dir: int = d
			var pane_i: int = i
			b.pressed.connect(func(): _pane_move(pane_i, screen_dir))
			ring.add_child(b)
			btns.append(b)
	cell.add_child(ring)
	_cams[i]["btns"] = btns
	_cams[i]["ui"] = [ring]

	# ROTATE + ZOOM, bottom-right. Rotation is per pane by design; the slider multiplies whatever
	# distance this pane's MODE computes, so it means the same thing in every pane without any
	# mode needing to know about it.
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	col.position = Vector2(-116, -52)
	col.add_theme_constant_override("separation", 1)
	var rot := HBoxContainer.new()
	rot.add_theme_constant_override("separation", 1)
	for step in [-90, -45, 45, 90]:
		var deg: float = float(step)
		var lb := ("%d°" % step) if step < 0 else ("+%d°" % step)
		var rb := _small_btn(lb, "turn this view %d°" % step, 27.0, 18.0)
		var pi2: int = i
		rb.pressed.connect(func(): pane_rotate(pi2, deg))
		rot.add_child(rb)
	col.add_child(rot)
	var zs := HSlider.new()
	zs.min_value = PANE_ZOOM_MIN
	zs.max_value = PANE_ZOOM_MAX
	zs.step = 0.05
	zs.value = 1.0
	zs.custom_minimum_size = Vector2(112, 14)
	zs.focus_mode = Control.FOCUS_NONE
	zs.tooltip_text = "zoom this view"
	var pi3: int = i
	zs.value_changed.connect(func(v: float): pane_zoom(pi3, v))
	col.add_child(zs)

	# CINEMATIC gets a speed control, pause included (0 = held still). Its own phase already keeps
	# two cinematic panes out of lockstep; this is how fast that phase advances.
	if m == 3:   # CamMode.CINEMATIC
		var ss := HSlider.new()
		ss.min_value = 0.0
		ss.max_value = 3.0
		ss.step = 0.05
		ss.value = 1.0
		ss.custom_minimum_size = Vector2(112, 14)
		ss.focus_mode = Control.FOCUS_NONE
		ss.tooltip_text = "orbit speed — drag to 0 to pause"
		var pi4: int = i
		ss.value_changed.connect(func(v: float): _cams[pi4]["cine_speed"] = v)
		col.add_child(ss)
	cell.add_child(col)
	(_cams[i]["ui"] as Array).append(col)

	# MOUSE gets a GLOBE: drag it to swing the view. A pane is not the focused viewport, so an
	# orbit you can drag has to live in a widget rather than in the pane's own mouse handling —
	# dragging the pane itself is already the inspector's gesture.
	if m == 4:   # CamMode.MOUSE
		var globe := _small_btn("🜨", "drag to turn this view", 30.0, 30.0)
		globe.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		globe.position = Vector2(-150, -34)
		globe.mouse_default_cursor_shape = Control.CURSOR_MOVE
		var pi5: int = i
		globe.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
				pane_rotate(pi5, -(e.relative.x) * 0.6))
		cell.add_child(globe)
		(_cams[i]["ui"] as Array).append(globe)

## Show a pane's controls only while the pointer is over that pane.
##
## BY GEOMETRY, NOT BY mouse_entered/mouse_exited. Those fire on the HOVERED control, so moving
## the pointer from the pane onto one of its own buttons makes the pane emit `exited` -- the
## controls would vanish the instant you reached for them, which is the one moment they must not.
## A rect test asks the question that was actually meant: is the pointer inside this pane.
func _update_hover() -> void:
	if _layer == null or not _on:
		return
	var mp := _layer.get_viewport().get_mouse_position()
	for i in _cams.size():
		if i >= _cells.size():
			continue
		var c: Control = _cells[i]
		var over := Rect2(c.global_position, c.size).has_point(mp)
		if bool(_cams[i].get("hover", false)) == over:
			continue
		_cams[i]["hover"] = over
		for n in (_cams[i].get("ui", []) as Array):
			if is_instance_valid(n):
				(n as CanvasItem).visible = over

## Move the player in whichever WORLD direction lies `screen_dir` away on this pane's screen.
func _pane_move(i: int, screen_dir: int) -> void:
	if not _on_move.is_valid():
		return
	var d := _world_dir_for(i, screen_dir)
	if d != "":
		_on_move.call(d)

## The compass name for a screen direction in one pane: take the pane's own heading, rotate it by
## the screen offset, and ask the rig what that is. Going through dir_to_compass rather than
## rounding a yaw keeps ONE definition of which way "SE" is.
func _world_dir_for(i: int, screen_dir: int) -> String:
	if i < 0 or i >= _cams.size():
		return ""
	var v: Dictionary = _cams[i]
	var el: Array = _cam_rig.eye_look_for(int(v["mode"]), v["st"])
	var fwd: Vector3 = (el[1] - el[0])
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = _cam_rig.NORTH
	fwd = fwd.normalized().rotated(Vector3.UP, -deg_to_rad(45.0 * float(screen_dir)))
	return _cam_rig.dir_to_compass(fwd)

## Re-letter every ring after the cameras have been placed, so the labels track the pane's heading.
func _refresh_rings() -> void:
	for i in _cams.size():
		if not bool(_cams[i].get("hover", false)):
			continue          # nobody can read a hidden ring; do not re-letter it every frame
		var btns: Array = _cams[i].get("btns", [])
		for sd in DIR_NAMES.size():
			var b = btns[RING_INDEX[sd]] if sd < RING_INDEX.size() else null
			if b == null:
				continue
			var nm := _world_dir_for(i, sd)
			(b as Button).text = "%s%s" % [ARROWS[sd], nm]
			(b as Button).tooltip_text = "move %s" % nm

## Where each screen direction sits in the flattened 3x3 ring.
const RING_INDEX := [1, 2, 5, 8, 7, 6, 3, 0]

## --- per-pane controls (what the camera menu's widgets drive) ---------------------
##
## Deliberately by INDEX rather than by mode: two panes could one day show the same mode, and a
## control belongs to the pane the user is pointing at, not to a mode.

## Turn one pane by `deg` degrees. Rotation is per pane by design — Daniel: "views rotate
## independently" — so this touches nothing else.
func pane_rotate(i: int, deg: float) -> void:
	if i < 0 or i >= _cams.size():
		return
	var st: Dictionary = _cams[i]["st"]
	st["yaw"] = fposmod(float(st.get("yaw", 0.0)) + deg_to_rad(deg), TAU)

## Set one pane's zoom (a multiplier on whatever distance its mode computes).
func pane_zoom(i: int, z: float) -> void:
	if i < 0 or i >= _cams.size():
		return
	_cams[i]["st"]["zoom"] = clampf(z, PANE_ZOOM_MIN, PANE_ZOOM_MAX)

func pane_zoom_of(i: int) -> float:
	if i < 0 or i >= _cams.size():
		return 1.0
	return float(_cams[i]["st"].get("zoom", 1.0))

func pane_yaw_deg(i: int) -> float:
	if i < 0 or i >= _cams.size():
		return 0.0
	return rad_to_deg(float(_cams[i]["st"].get("yaw", 0.0)))

func pane_count() -> int:
	return _cams.size()

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
	var dt := get_process_delta_time()
	for v in _cams:
		if int(v["mode"]) == 3:                      # CINEMATIC: its own speed, 0 = paused
			v["st"]["cine"] = float(v["st"].get("cine", 0.0)) + dt * float(v.get("cine_speed", 1.0))
	for v in _cams:
		var m: int = v["mode"]
		var cam: Camera3D = v["cam"]
		var el: Array = _cam_rig.eye_look_for(m, v["st"])
		var eye: Vector3 = el[0]
		var look: Vector3 = el[1]
		var top := m == TOP_FOLLOW
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL if top else Camera3D.PROJECTION_PERSPECTIVE
		if top:
			cam.size = _cam_rig._top_ortho_size(float(v["st"].get("zoom", 1.0)))
		cam.position = eye
		if eye.distance_to(look) > 0.001:
			cam.look_at(look, _cam_rig.NORTH if top else Vector3.UP)
	_update_hover()
	_refresh_rings()

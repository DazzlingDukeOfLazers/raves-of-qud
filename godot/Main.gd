extends Node3D

## Wires the bridge client to the renderer, drives the camera, and maps input to
## Qud movement commands. Built in code so the scene file stays a single node.
##
## CAMERA MODES — the mode decides what the arrow keys do, so it's on screen.
##   FOLLOW    (default)  rides behind the player, looking ahead. Arrows move the
##                        player. Nothing to set up each time you reload.
##   MOUSE     (Shift+C)  orbit/pan with the mouse, centred on the SELECTED tile
##                        (falls back to the player). Arrows still move the player.
##   KEYBOARD  (Shift+K)  free flight. WASD moves the camera, arrows AIM it —
##                        so arrows no longer reach the player.
##
##   Shift+F returns to FOLLOW (Esc does too, and dismisses the report).
##   Wheel zooms in every mode.
##   Ctrl/Cmd+click or I inspects a tile;  - / =  resize the report.
##   F12                    -> save the viewport to <tilesDir>/../shot.png
##
## Terminology: "tile" here means a map square (Qud's Cell). Note the collision —
## the `tile` field on the wire is the sprite-art path. Code touching Qud's API
## keeps the name Cell.

var client: BridgeClient
var renderer: ZoneRenderer
var inspector: CellInspector

enum CamMode { FOLLOW, MOUSE, KEYBOARD }
var _mode: int = CamMode.FOLLOW

var _pivot: Node3D
var _cam: Camera3D
var _yaw := 0.7
var _pitch := 0.9            # radians above the ground plane
var _dist := 14.0
var _zone_center := Vector3(40, 0, 12)
var _pan := Vector3.ZERO     # user pan offset (MOUSE mode); persists across turns

# --- follow-cam -------------------------------------------------------------
const TILES_BEHIND := 2.0    # how far back down the facing the camera sits
const FOCUS_AHEAD := 2.0     # look at a point this far in FRONT of the player
const FOLLOW_LERP := 6.0     # per-second approach; keeps steps from snapping
var _player := Vector3(40, 0, 12)
var _prev_tile := Vector2i(-9999, -9999)
var _facing := Vector2(0, 1)     # +z is south; Qud y grows southward
var _eye := Vector3.ZERO         # smoothed camera position
var _look := Vector3.ZERO        # smoothed look-at target
var _seeded := false

# --- free camera ------------------------------------------------------------
const FLY_SPEED := 9.0
const AIM_SPEED := 1.6
var _free_eye := Vector3.ZERO

var _orbiting := false
var _panning := false
var _mode_label: Label

const ORBIT_SENS := 0.006
const PITCH_MIN := 0.12
const PITCH_MAX := 1.45
const DIST_MIN := 3.0
const DIST_MAX := 140.0

func _ready() -> void:
	renderer = ZoneRenderer.new()
	add_child(renderer)

	client = BridgeClient.new()
	add_child(client)
	client.snapshot.connect(_on_snapshot)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -45, 0)
	sun.light_energy = 1.4
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	# Use the explicit ambient colour as fill (default source is the dark BG, which
	# left lit surfaces almost black). This is what makes the rock read as lit.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.62)
	env.ambient_light_energy = 0.65
	we.environment = env
	add_child(we)

	_pivot = Node3D.new()
	add_child(_pivot)
	_cam = Camera3D.new()
	_pivot.add_child(_cam)
	# Depth of field: a field of vinewafer reads as one flat colour blob without
	# it. Far blur only — near blur would smear the player.
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 18.0
	attrs.dof_blur_far_transition = 12.0
	attrs.dof_blur_amount = 0.10
	_cam.attributes = attrs

	_build_mode_label()
	_update_camera(0.0)

	inspector = CellInspector.new()
	add_child(inspector)
	inspector.setup(renderer, _cam)

func _on_snapshot(data: Dictionary) -> void:
	renderer.render_snapshot(data)
	inspector.on_snapshot(data)

	var z: Dictionary = data.get("zone", {})
	if z.has("width") and z.has("height"):
		_zone_center = Vector3(float(z["width"]) / 2.0, 0.0, float(z["height"]) / 2.0)

	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return
	var tile := Vector2i(px, py)
	# facing = the direction of the last actual step, so the camera trails behind
	if _prev_tile.x > -9999 and tile != _prev_tile:
		var d := Vector2(tile.x - _prev_tile.x, tile.y - _prev_tile.y)
		if d.length() > 0.0:
			_facing = d.normalized()
	_prev_tile = tile
	_player = Vector3(px, 0, py)
	if not _seeded:
		_seeded = true
		_free_eye = _follow_eye()
		_eye = _free_eye
		_look = _follow_look()

func _process(dt: float) -> void:
	if _mode == CamMode.KEYBOARD:
		_fly(dt)
	elif not Input.is_key_pressed(KEY_SHIFT):
		# Shift-guarded: Shift+F switches mode, and F alone lowers the pitch —
		# without this the mode switch would also tilt the camera on the way out.
		if Input.is_key_pressed(KEY_Q): _yaw -= 1.5 * dt
		if Input.is_key_pressed(KEY_E): _yaw += 1.5 * dt
		if Input.is_key_pressed(KEY_R): _pitch = clampf(_pitch + 1.0 * dt, PITCH_MIN, PITCH_MAX)
		if Input.is_key_pressed(KEY_F): _pitch = clampf(_pitch - 1.0 * dt, PITCH_MIN, PITCH_MAX)
	_update_camera(dt)

# --- camera placement -------------------------------------------------------

func _facing3() -> Vector3:
	return Vector3(_facing.x, 0, _facing.y).normalized()

## Behind the player along the facing, raised by the current zoom/pitch.
func _follow_eye() -> Vector3:
	var f := _facing3()
	var back := TILES_BEHIND + _dist * cos(_pitch)
	return _player - f * back + Vector3(0, _dist * sin(_pitch), 0)

func _follow_look() -> Vector3:
	return _player + _facing3() * FOCUS_AHEAD

## MOUSE mode orbits whatever tile is selected, so inspecting and then looking
## around don't fight each other. Falls back to the player.
func _orbit_center() -> Vector3:
	var sel = inspector.selected_tile() if inspector != null else null
	var c: Vector3 = _player
	if sel != null:
		c = Vector3(sel.x, 0, sel.y)
	return c + _pan

func _update_camera(dt: float) -> void:
	var target_eye: Vector3
	var target_look: Vector3
	match _mode:
		CamMode.KEYBOARD:
			target_eye = _free_eye
			target_look = _free_eye + _aim_dir()
		CamMode.MOUSE:
			var c := _orbit_center()
			target_eye = c + Vector3(
				_dist * cos(_pitch) * sin(_yaw),
				_dist * sin(_pitch),
				_dist * cos(_pitch) * cos(_yaw))
			target_look = c
		_:
			target_eye = _follow_eye()
			target_look = _follow_look()

	if dt <= 0.0 or not _seeded:
		_eye = target_eye
		_look = target_look
	else:
		var k: float = clampf(FOLLOW_LERP * dt, 0.0, 1.0)
		_eye = _eye.lerp(target_eye, k)
		_look = _look.lerp(target_look, k)

	_pivot.position = Vector3.ZERO
	_cam.position = _eye
	if _eye.distance_to(_look) > 0.001:
		_cam.look_at(_look, Vector3.UP)

func _aim_dir() -> Vector3:
	return Vector3(cos(_pitch) * sin(_yaw + PI), -sin(_pitch), cos(_pitch) * cos(_yaw + PI))

func _fly(dt: float) -> void:
	# arrows AIM in this mode; they do not reach the player
	if Input.is_key_pressed(KEY_LEFT):  _yaw -= AIM_SPEED * dt
	if Input.is_key_pressed(KEY_RIGHT): _yaw += AIM_SPEED * dt
	if Input.is_key_pressed(KEY_UP):    _pitch = clampf(_pitch + AIM_SPEED * dt, -PITCH_MAX, PITCH_MAX)
	if Input.is_key_pressed(KEY_DOWN):  _pitch = clampf(_pitch - AIM_SPEED * dt, -PITCH_MAX, PITCH_MAX)
	var fwd := _aim_dir()
	fwd.y = 0.0
	if fwd.length() > 0.001: fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move += fwd
	if Input.is_key_pressed(KEY_S): move -= fwd
	if Input.is_key_pressed(KEY_D): move -= right
	if Input.is_key_pressed(KEY_A): move += right
	if Input.is_key_pressed(KEY_SPACE): move += Vector3.UP
	if Input.is_key_pressed(KEY_Z): move -= Vector3.UP
	if move.length() > 0.001:
		_free_eye += move.normalized() * FLY_SPEED * dt

func _set_mode(m: int) -> void:
	if m == _mode:
		return
	# entering free flight, start from where the camera already is
	if m == CamMode.KEYBOARD:
		_free_eye = _eye
	if m == CamMode.MOUSE:
		_pan = Vector3.ZERO
	_mode = m
	_update_mode_label()

## Save the viewport to a known path so a collaborator can just read it.
##
## The OS-level `screencapture` is blocked without Screen Recording permission,
## and this is better anyway: it captures the rendered viewport exactly, with no
## window chrome and nothing overlapping it.
func _screenshot() -> void:
	var dir := renderer.tiles_dir().get_base_dir()
	if dir == "":
		return
	await RenderingServer.frame_post_draw      # let the frame finish first
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	var path := dir.path_join("shot.png")
	if img.save_png(path) == OK:
		# ask Qud to capture itself too, so the pair can be compared side by side
		client.send_command("shot", {})
		_mode_label.text = "saved shot.png + asked Qud for qud_shot.png"

func _build_mode_label() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_mode_label = Label.new()
	_mode_label.position = Vector2(14, 8)
	_mode_label.add_theme_font_size_override("font_size", 15)
	_mode_label.add_theme_color_override("font_color", Color(0.75, 0.9, 0.75))
	layer.add_child(_mode_label)
	_update_mode_label()

func _update_mode_label() -> void:
	match _mode:
		CamMode.KEYBOARD:
			_mode_label.text = "camera: KEYBOARD — WASD fly, arrows aim, Space/Z up-down  ·  Shift+F: follow"
		CamMode.MOUSE:
			_mode_label.text = "camera: MOUSE — drag to orbit/pan around the selected tile  ·  Shift+F: follow"
		_:
			_mode_label.text = "camera: FOLLOW  ·  Shift+C mouse  ·  Shift+K keyboard  ·  Shift+F follow"

# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# mode switches first — they reassign what the arrows mean
		if event.shift_pressed and event.keycode == KEY_C:
			_set_mode(CamMode.MOUSE); return
		if event.shift_pressed and event.keycode == KEY_K:
			_set_mode(CamMode.KEYBOARD); return
		if event.shift_pressed and event.keycode == KEY_F:
			_set_mode(CamMode.FOLLOW); return
		if event.keycode == KEY_ESCAPE:
			inspector.hide_panel()
			_set_mode(CamMode.FOLLOW); return
		if event.keycode == KEY_I:
			inspector.inspect_at_mouse(); return
		if event.keycode == KEY_F12:
			_screenshot(); return
		if event.keycode == KEY_MINUS:
			inspector.nudge_font(-2); return
		if event.keycode == KEY_EQUAL:
			inspector.nudge_font(2); return
		# in KEYBOARD mode the arrows drive the camera, not the player
		if _mode == CamMode.KEYBOARD:
			return
		match event.keycode:
			KEY_UP, KEY_KP_8:    client.send_command("move", {"dir": "N"})
			KEY_DOWN, KEY_KP_2:  client.send_command("move", {"dir": "S"})
			KEY_LEFT, KEY_KP_4:  client.send_command("move", {"dir": "W"})
			KEY_RIGHT, KEY_KP_6: client.send_command("move", {"dir": "E"})
			KEY_KP_7:            client.send_command("move", {"dir": "NW"})
			KEY_KP_9:            client.send_command("move", {"dir": "NE"})
			KEY_KP_1:            client.send_command("move", {"dir": "SW"})
			KEY_KP_3:            client.send_command("move", {"dir": "SE"})
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# Ctrl/Cmd+click inspects; a plain click orbits (MOUSE mode)
				if event.pressed and (event.ctrl_pressed or event.meta_pressed):
					inspector.inspect_at_mouse()
				else:
					_orbiting = event.pressed and _mode == CamMode.MOUSE
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed and _mode == CamMode.MOUSE
			MOUSE_BUTTON_WHEEL_UP:   if event.pressed: _dist = clampf(_dist * 0.9, DIST_MIN, DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN: if event.pressed: _dist = clampf(_dist * 1.1, DIST_MIN, DIST_MAX)
	elif event is InputEventMouseMotion:
		if _orbiting:
			_yaw += event.relative.x * ORBIT_SENS
			_pitch = clampf(_pitch + event.relative.y * ORBIT_SENS, PITCH_MIN, PITCH_MAX)
		elif _panning:
			# pan along the ground plane, scaled by zoom so it feels constant
			var right := _cam.global_transform.basis.x
			var fwd := -_cam.global_transform.basis.z
			right.y = 0.0; fwd.y = 0.0
			right = right.normalized(); fwd = fwd.normalized()
			var speed := _dist * 0.0016
			# grab-the-world: drag right moves the world right (camera goes left)
			_pan += (-right * event.relative.x - fwd * event.relative.y) * speed

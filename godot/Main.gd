extends Node3D

## Wires the bridge client to the renderer, builds an orbit/pan/zoom camera, and
## maps keyboard input to Qud movement commands. Built in code so the scene file
## stays a single node.
##
## Controls:
##   Arrows / numpad        -> move the player (sent to Qud)
##   Left-drag              -> orbit (yaw/pitch)      Q/E, R/F -> orbit by keyboard
##   Right- or middle-drag  -> pan across the zone
##   Mouse wheel            -> zoom

var client: BridgeClient
var renderer: ZoneRenderer

var _pivot: Node3D
var _cam: Camera3D
var _yaw := 0.7
var _pitch := 0.9            # radians above the ground plane
var _dist := 34.0
var _zone_center := Vector3(40, 0, 12)
var _pan := Vector3.ZERO     # user pan offset; persists across turns

var _orbiting := false
var _panning := false

const ORBIT_SENS := 0.006
const PITCH_MIN := 0.12
const PITCH_MAX := 1.45
const DIST_MIN := 4.0
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
	_apply_pivot()
	_update_camera()

func _on_snapshot(data: Dictionary) -> void:
	renderer.render_snapshot(data)
	var z: Dictionary = data.get("zone", {})
	if z.has("width") and z.has("height"):
		_zone_center = Vector3(float(z["width"]) / 2.0, 0.0, float(z["height"]) / 2.0)
		_apply_pivot()

func _process(dt: float) -> void:
	if Input.is_key_pressed(KEY_Q): _yaw -= 1.5 * dt
	if Input.is_key_pressed(KEY_E): _yaw += 1.5 * dt
	if Input.is_key_pressed(KEY_R): _pitch = clampf(_pitch + 1.0 * dt, PITCH_MIN, PITCH_MAX)
	if Input.is_key_pressed(KEY_F): _pitch = clampf(_pitch - 1.0 * dt, PITCH_MIN, PITCH_MAX)
	_update_camera()

func _apply_pivot() -> void:
	_pivot.position = _zone_center + _pan

func _update_camera() -> void:
	var offset := Vector3(
		_dist * cos(_pitch) * sin(_yaw),
		_dist * sin(_pitch),
		_dist * cos(_pitch) * cos(_yaw))
	_cam.position = offset
	_cam.look_at(_pivot.global_position, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
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
			MOUSE_BUTTON_LEFT:   _orbiting = event.pressed
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE: _panning = event.pressed
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
			_apply_pivot()

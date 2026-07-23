extends Node3D

## Wires the bridge client to the renderer, builds an orbit camera, and maps
## keyboard input to Qud movement commands. Everything is created in code so the
## scene file stays a single node.
##
## Controls:
##   Arrows / numpad  -> move (sent to Qud; the sim resolves the turn)
##   Q / E            -> orbit yaw      R / F -> orbit pitch
##   mouse wheel      -> zoom

var client: BridgeClient
var renderer: ZoneRenderer

var _pivot: Node3D
var _cam: Camera3D
var _yaw := 0.7
var _pitch := 0.9   # radians below horizontal
var _dist := 34.0

func _ready() -> void:
	renderer = ZoneRenderer.new()
	add_child(renderer)

	client = BridgeClient.new()
	add_child(client)
	client.snapshot.connect(_on_snapshot)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -40, 0)
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	env.ambient_light_color = Color(0.4, 0.4, 0.45)
	env.ambient_light_energy = 0.7
	we.environment = env
	add_child(we)

	_pivot = Node3D.new()
	_pivot.position = Vector3(40, 0, 12)  # center of an 80x25 zone
	add_child(_pivot)
	_cam = Camera3D.new()
	_pivot.add_child(_cam)
	_update_camera()

func _on_snapshot(data: Dictionary) -> void:
	renderer.render_snapshot(data)
	var z: Dictionary = data.get("zone", {})
	if z.has("width") and z.has("height"):
		_pivot.position = Vector3(float(z["width"]) / 2.0, 0.0, float(z["height"]) / 2.0)

func _process(dt: float) -> void:
	if Input.is_key_pressed(KEY_Q): _yaw -= 1.5 * dt
	if Input.is_key_pressed(KEY_E): _yaw += 1.5 * dt
	if Input.is_key_pressed(KEY_R): _pitch = clampf(_pitch + 1.0 * dt, 0.1, 1.45)
	if Input.is_key_pressed(KEY_F): _pitch = clampf(_pitch - 1.0 * dt, 0.1, 1.45)
	_update_camera()

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
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:   _dist = maxf(6.0, _dist - 2.0)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _dist = minf(90.0, _dist + 2.0)

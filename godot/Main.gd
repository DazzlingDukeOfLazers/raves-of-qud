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
##   F12                   -> save the viewport to <tilesDir>/../shot.png
##   Ctrl/Cmd + right-click -> inspect the tile AND photograph both apps
##
## Terminology: "tile" here means a map square (Qud's Cell). Note the collision —
## the `tile` field on the wire is the sprite-art path. Code touching Qud's API
## keeps the name Cell.

var client: BridgeClient
var renderer: ZoneRenderer
var inspector: CellInspector
var reporter: TileReport

# Day/night grade. The world is UNSHADED, so a real light does nothing; instead a
# full-screen MULTIPLY rect tints the whole viewport by time of day. It sits below
# the UI layer, so panels and text stay at full brightness.
var _grade: ColorRect
var _tint := Color.WHITE          # current, smoothed
var _tint_target := Color.WHITE
var _time_label := ""
var _day_frac := 0.5
var _dawn_h := 6.5
var _dusk_h := 20.0
var _sun: Sprite3D
var _moon: Sprite3D
var _sun_light: DirectionalLight3D   # follows the sun; drives future shadows
var _env: Environment
var _sky := Color(0.05, 0.05, 0.07)
var _sky_target := Color(0.05, 0.05, 0.07)
const SKY_NIGHT := Color(0.03, 0.05, 0.12)   # deep blue night void
const SKY_DAY := Color(0.32, 0.55, 0.85)     # daytime blue
const SKY_DUSK := Color(0.75, 0.45, 0.35)    # warm dawn/dusk horizon
const SKY_DIST := 180.0
const NIGHT_TINT := Color(0.34, 0.40, 0.62)   # cool moonlit blue (Qud has no moon phase)
const DAY_TINT := Color(1.0, 0.99, 0.96)       # near-neutral, a hair warm
const DUSK_TINT := Color(1.0, 0.72, 0.50)      # warm dawn/dusk

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

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	# Use the explicit ambient colour as fill (default source is the dark BG, which
	# left lit surfaces almost black). This is what makes the rock read as lit.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# high, near-neutral ambient so shaded surfaces keep their tile colour where the
	# sun does not reach; the sun then adds directional highlight + shadow on top.
	env.ambient_light_color = Color(0.72, 0.72, 0.74)
	env.ambient_light_energy = 0.72
	_env = env
	we.environment = env
	add_child(we)

	# MULTIPLY grade over the 3D, under the UI. layer 0 keeps it below the panels
	# (default layer 1), so the world dims at night but text does not.
	var glayer := CanvasLayer.new()
	glayer.layer = 0
	add_child(glayer)
	_grade = ColorRect.new()
	_grade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gmat := CanvasItemMaterial.new()
	gmat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_grade.material = gmat
	_grade.color = DAY_TINT
	glayer.add_child(_grade)

	# sky bodies: sun and moon, big bright discs far out on an arc set by the hour.
	# In a steep top-down view they sit high; tilt the camera down to see them rise
	# and set on the horizon.
	_sun = _make_sky_body(Color(1.0, 0.93, 0.6), 26.0)
	_moon = _make_sky_body(Color(0.82, 0.86, 1.0), 16.0)
	add_child(_sun)
	add_child(_moon)

	# a real sun light, aimed by the hour. It does little to the current UNSHADED
	# materials, but it is the hook directional shadows will hang on once walls
	# move to a shaded material.
	_sun_light = DirectionalLight3D.new()
	_sun_light.light_energy = 0.0            # set per hour in _update_sky
	_sun_light.shadow_enabled = true
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_sun_light.shadow_bias = 0.04
	_sun_light.shadow_normal_bias = 1.5
	add_child(_sun_light)

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

	reporter = TileReport.new()
	add_child(reporter)
	reporter.setup(renderer)
	reporter.dismissed.connect(_dismiss_selection)

func _on_snapshot(data: Dictionary) -> void:
	renderer.render_snapshot(data)
	inspector.on_snapshot(data)

	_update_time(data.get("time", {}))

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
	# ease the grade so time-of-day shifts smoothly between turns
	_tint = _tint.lerp(_tint_target, clampf(dt * 2.0, 0.0, 1.0))
	if _grade != null:
		_grade.color = _tint
	_sky = _sky.lerp(_sky_target, clampf(dt * 2.0, 0.0, 1.0))
	if _env != null:
		_env.background_color = _sky

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

## One gesture -> everything a collaborator needs about a tile: the report
## (selection.txt), this viewer's view (shot.png) and Qud's own view
## (qud_shot.png), all pointing at the same tile.
func _inspect_and_capture() -> void:
	_inspect()
	await _screenshot(true)

## Turn Qud's hour into a day/night tint. hour arrives as hour*1000 (int wire).
## Uses the calendar's own dawn/dusk boundaries, so it matches when Qud calls it
## day. Night is a cool moonlit blue; dawn and dusk are warm; midday is neutral.
func _update_time(t: Dictionary) -> void:
	if t.is_empty():
		return
	# everything arrives in day-SEGMENTS; normalise to a 0..24 hour here
	var spd: float = maxf(1.0, float(t.get("segmentsPerDay", 12000)))
	var hour: float = float(t.get("segment", spd * 0.5)) / spd * 24.0
	var dawn: float = float(t.get("startOfDay", 3250)) / spd * 24.0
	var dusk: float = float(t.get("startOfNight", 10000)) / spd * 24.0
	_time_label = String(t.get("label", ""))
	_day_frac = hour / 24.0
	_dawn_h = dawn
	_dusk_h = dusk
	_tint_target = _tint_for_hour(hour, dawn, dusk, 24.0)
	_sky_target = _sky_for_hour(hour, dawn, dusk)
	_update_sky(hour, dawn, dusk)
	_update_mode_label()

## A bright disc billboard for a celestial body.
func _make_sky_body(col: Color, size_units: float) -> Sprite3D:
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in n:
		for x in n:
			var d: float = Vector2(x - c, y - c).length() / c
			# solid disc with a soft glowing rim
			var a := 1.0 if d < 0.72 else clampf(1.0 - (d - 0.72) / 0.28, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	var spr := Sprite3D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.pixel_size = size_units / n
	spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	spr.shaded = false
	spr.transparent = true
	spr.no_depth_test = true            # always draw in the sky, behind nothing
	spr.render_priority = -1
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return spr

## Position sun and moon on a tilted arc: rise east, peak overhead, set west. The
## sun tracks day (dawn..dusk); the moon tracks the night span, opposite the sun.
## Fades each in/out across dawn and dusk so neither pops.
func _update_sky(hour: float, dawn: float, dusk: float) -> void:
	if _sun == null:
		return
	var sun_up := hour >= dawn and hour <= dusk
	var sun_p: float = clampf((hour - dawn) / maxf(0.01, dusk - dawn), 0.0, 1.0)
	# night runs dusk -> 24 -> dawn; fold it into 0..1 for the moon
	var nlen: float = (24.0 - dusk) + dawn
	var np: float = ((hour - dusk) if hour >= dusk else (hour + 24.0 - dusk)) / maxf(0.01, nlen)

	_sun.position = _body_pos(sun_p)
	_moon.position = _body_pos(np)

	# cross-fade over ~1h at each boundary
	var sun_a: float = clampf(minf(hour - dawn, dusk - hour) + 0.5, 0.0, 1.0) if sun_up else 0.0
	_sun.modulate = Color(1, 1, 1, sun_a)
	_moon.modulate = Color(1, 1, 1, 1.0 - sun_a)
	_sun.visible = sun_a > 0.01
	_moon.visible = sun_a < 0.99

	# aim the sun light down its arc and fade its energy with daylight, so shadows
	# appear during the day and vanish at night (ambient + grade carry the night).
	if _sun_light != null:
		var d := (_zone_center - _sun.position).normalized()
		_sun_light.rotation = Vector3(asin(clampf(d.y, -1.0, 1.0)), atan2(d.x, d.z), 0.0)
		_sun_light.light_energy = sun_a * 0.6

## A body's world position for arc progress 0(rise)..1(set), tilted so it clears
## the horizon in a tilted view rather than sitting straight overhead.
func _body_pos(p: float) -> Vector3:
	var theta: float = p * PI                         # 0..PI, east->zenith->west
	var dir := Vector3(cos(theta), sin(theta) * 0.85 + 0.12, -0.45).normalized()
	return _zone_center + dir * SKY_DIST

## Background sky colour by hour: night deep-blue, dawn/dusk warm, midday blue.
func _sky_for_hour(hour: float, dawn: float, dusk: float) -> Color:
	var w := 1.5
	if hour < dawn - w or hour > dusk + w:
		return SKY_NIGHT
	if hour < dawn:
		return SKY_NIGHT.lerp(SKY_DUSK, (hour - (dawn - w)) / w)
	if hour < dawn + w:
		return SKY_DUSK.lerp(SKY_DAY, (hour - dawn) / w)
	if hour < dusk - w:
		return SKY_DAY
	if hour < dusk:
		return SKY_DAY.lerp(SKY_DUSK, (hour - (dusk - w)) / w)
	return SKY_DUSK.lerp(SKY_NIGHT, (hour - dusk) / w)

func _tint_for_hour(hour: float, dawn: float, dusk: float, hpd: float) -> Color:
	# widths of the dawn/dusk transitions, in hours
	var w := 2.0
	if hour < dawn - w or hour > dusk + w:
		return NIGHT_TINT
	if hour < dawn:                                   # pre-dawn -> dawn glow
		return NIGHT_TINT.lerp(DUSK_TINT, (hour - (dawn - w)) / w)
	if hour < dawn + w:                               # dawn glow -> full day
		return DUSK_TINT.lerp(DAY_TINT, (hour - dawn) / w)
	if hour < dusk - w:                               # full day
		return DAY_TINT
	if hour < dusk:                                   # day -> dusk glow
		return DAY_TINT.lerp(DUSK_TINT, (hour - (dusk - w)) / w)
	return DUSK_TINT.lerp(NIGHT_TINT, (hour - dusk) / w)  # dusk glow -> night

## Clear everything a selection put on screen: report form, inspector panel, marker.
## Bound to Esc and to the form's Cancel button.
func _dismiss_selection() -> void:
	inspector.hide_panel()
	reporter.hide_panel()

## Inspect, and aim the report form at the same tile.
func _inspect() -> void:
	inspector.inspect_at_mouse()
	var sel = inspector.selected_tile()
	if sel != null:
		reporter.set_target(sel.x, sel.y, inspector.zone_id(),
			inspector.last_objects(), inspector.last_report())

## Save the viewport to a known path so a collaborator can just read it.
##
## The OS-level `screencapture` is blocked without Screen Recording permission,
## and this is better anyway: it captures the rendered viewport exactly, with no
## window chrome and nothing overlapping it.
func _screenshot(clean := false) -> void:
	var dir := renderer.tiles_dir().get_base_dir()
	if dir == "":
		return
	# `clean` drops the text report out of frame so the shot shows the scene; the
	# 3D marker stays, so the picture still says which tile was picked.
	var restore := false
	if clean and inspector.panel_visible():
		inspector.set_panel_visible(false)
		restore = true
	await RenderingServer.frame_post_draw      # let the frame finish first
	var img := get_viewport().get_texture().get_image()
	if restore:
		inspector.set_panel_visible(true)
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
	if _time_label != "":
		_mode_label.text += "     ⏱ " + _time_label

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
			_dismiss_selection()
			_set_mode(CamMode.FOLLOW); return
		if event.keycode == KEY_I:
			_inspect(); return
		if event.keycode == KEY_F12:
			_screenshot(); return
		if event.keycode == KEY_MINUS:
			inspector.nudge_font(-2)
			reporter.nudge_font(-2); return
		if event.keycode == KEY_EQUAL:
			inspector.nudge_font(2)
			reporter.nudge_font(2); return
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
					_inspect()
				else:
					_orbiting = event.pressed and _mode == CamMode.MOUSE
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				# Ctrl/Cmd + right-click = inspect AND photograph both apps, so a
				# single gesture hands over coordinates, wire data and the picture.
				if (event.pressed and event.button_index == MOUSE_BUTTON_RIGHT
						and (event.ctrl_pressed or event.meta_pressed)):
					_inspect_and_capture()
				else:
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

extends Node3D

## Wires the bridge client to the renderer, drives the camera, and maps input to
## Qud movement commands. Built in code so the scene file stays a single node.
##
## CAMERA MODES — pick with the ` debug menu or number keys 1-7; the current mode
## and its controls show on screen.
##   1 COMPASS  (default)  cardinal-LOCKED low-angle view. Follows the player's
##                         position but NEVER rotates on movement, so the world
##                         doesn't spin under you. Q/E rotate the heading 90°,
##                         R/F zoom. This is the stable, non-disorienting default.
##   2 FOLLOW              rides behind your heading, looking ahead (trails movement).
##   3 FIRST_PERSON        at the player, eye-level, looking along the locked heading.
##   4 CINEMATIC           frames you + the selected tile, slowly orbiting (v1;
##                         combat-aware framing via an event buffer is future work).
##   5 MOUSE               orbit/pan with the mouse around the SELECTED tile.
##   6 KEYBOARD            free flight. WASD moves the camera, arrows AIM it.
##   7 TOP_FOLLOW          Qud-classic overhead: orthographic, straight down, NORTH up,
##                         tracking the player; R/F or the wheel zoom in and out.
##
##   Esc returns to COMPASS (and dismisses the report). Shift+C/K/F still jump to
##   mouse/keyboard/follow. Wheel zooms. Ctrl/Cmd+click or I inspects a tile.
##   F12                   -> save the viewport to <tilesDir>/../shot.png
##   Ctrl/Cmd + right-click -> photograph the CLEAN scene, then inspect (+ Qud shot)
##
## Terminology: "tile" here means a map square (Qud's Cell). Note the collision —
## the `tile` field on the wire is the sprite-art path. Code touching Qud's API
## keeps the name Cell.

var client: BridgeClient
var renderer: ZoneRenderer
var store := WorldStore.new()   # Phase-0 world store; renderer reads the live zone from it
var _prof_turns := 0            # for the periodic profile auto-dump
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

enum CamMode { COMPASS, FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW }
var _mode: int = CamMode.COMPASS   # cardinal-locked: stable, doesn't spin on movement

# Top-down (Qud-classic) modes: orthographic, straight down, NORTH locked to the top
# of the screen, tracking the player at a fixed zoom (wheel / R-F). Height sits below the fog-begin
# distance so the flat map stays crisp; DOF is disabled while overhead.
const TOP_H := 20.0        # ortho eye height above the ground (scale is size, not H)
const TOP_FIT_MARGIN := 1.06   # padding so the framed zone isn't flush to the edges
const NORTH := Vector3(0, 0, -1)   # -z is north (Qud's y grows south); screen-up in top-down
const TOP_FOLLOW_SPAN := 18.0  # TOP_FOLLOW vertical span (cells) at zoom 1.0
const TOP_ZOOM_MIN := 0.15
const TOP_ZOOM_MAX := 3.5
var _top_zoom := 1.0           # wheel / R-F zoom for the top-down follow mode

# Remembered view/render settings, saved on exit and restored on launch (so Raves doesn't
# reset to "looking south" every run). In user:// — available at startup, before the mod
# sends the support-dir path.
const SETTINGS_PATH := "user://raves_settings.json"

var _pivot: Node3D
var _cam: Camera3D
var _yaw := 0.7
var _pitch := 0.9            # radians above the ground plane (MOUSE orbit)
var _dist := 14.0

# --- compass cam (cardinal-locked, the disorientation fix) -------------------
const COMPASS_PITCH := 0.61     # ~35° above the ground: a low, dramatic angle
var _compass_yaw := 0.0         # locked heading in radians; Q/E rotate in 90° steps
var _cine_t := 0.0              # cinematic auto-orbit phase
const FP_EYE_H := 0.55          # first-person default eye height above the ground
var _fp_height := FP_EYE_H      # live first-person eye height (debug-menu slider)
var _zone_center := Vector3(40, 0, 12)
var _zone_dims := Vector2(80, 25)   # live zone width x height in cells
var _pan := Vector3.ZERO     # user pan offset (MOUSE mode); persists across turns

# --- follow-cam -------------------------------------------------------------
const TILES_BEHIND := 2.0    # how far back down the facing the camera sits
const FOCUS_AHEAD := 2.0     # look at a point this far in FRONT of the player
const FOLLOW_LERP := 6.0     # per-second approach; keeps steps from snapping
var _player := Vector3(40, 0, 12)
var _prev_tile := Vector2i(-9999, -9999)
var _prev_zone_id := ""          # to detect zone crossings (shift the camera to stay continuous)
var _facing := Vector2(0, 1)     # +z is south; Qud y grows southward
var _eye := Vector3.ZERO         # smoothed camera position
var _look := Vector3.ZERO        # smoothed look-at target
var _seeded := false
var _snap_cam := false           # skip the lerp for one frame (top-down transitions)

# --- free camera ------------------------------------------------------------
const FLY_SPEED := 9.0
const AIM_SPEED := 1.6
var _free_eye := Vector3.ZERO

var _orbiting := false
var _panning := false
var _mode_label: Label
var _debug_menu_title: Label

# Responsive HUD text: a fraction of viewport height, but never below a floor —
# "min(px, %vh)" web sensibility, re-applied on window resize.
const FONT_FRAC := 0.024
const MIN_FONT := 20
func _ui_font_size() -> int:
	return maxi(MIN_FONT, int(get_viewport().get_visible_rect().size.y * FONT_FRAC))

func _apply_ui_fonts() -> void:
	var fs := _ui_font_size()
	if _mode_label != null:
		_mode_label.add_theme_font_size_override("font_size", fs)
	if _debug_menu_title != null:
		_debug_menu_title.add_theme_font_size_override("font_size", fs)
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).add_theme_font_size_override("font_size", fs)
	# keep the debug menu just BELOW the help label so they never overlap, even as
	# the responsive font grows the label's height
	if _debug_menu != null and _mode_label != null:
		var lh: float = maxf(_mode_label.get_minimum_size().y, float(fs))
		_debug_menu.position = Vector2(14, _mode_label.position.y + lh + 8.0)

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
	client.connected.connect(_on_bridge_connected)

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
	# Depth fog fades distant geometry into the sky, so remembered neighbour zones
	# read as "over the horizon" while the live zone around the player stays crisp.
	# Begins past most of the live zone (~80x25 cells), full a couple of zones out.
	# The fog colour tracks the sky (updated per hour in _process) for a seamless
	# horizon. Tunable: begin/end distance and the curve.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 60.0
	env.fog_depth_end = 240.0
	env.fog_depth_curve = 1.4     # >1: stay clear longer, then ramp up toward the end
	env.fog_light_color = env.background_color
	env.fog_sky_affect = 0.0      # the sky IS the fog colour; don't double-fog it
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

	_load_settings()   # restore camera heading/mode/zoom/depth/window before the UI reads them
	_build_mode_label()
	_build_debug_menu()
	_build_reset_button()
	_build_multiview()
	_apply_ui_fonts()
	get_viewport().size_changed.connect(_apply_ui_fonts)
	_update_camera(0.0)

	inspector = CellInspector.new()
	add_child(inspector)
	inspector.setup(renderer, _cam)

	reporter = TileReport.new()
	add_child(reporter)
	reporter.setup(renderer)
	reporter.dismissed.connect(_dismiss_selection)

## On (re)connect, wait one turn so Qud publishes a snapshot immediately and Raves has a
## zone to render — instead of a blank view until the player first moves. Passes a turn for
## now; a no-turn refresh will replace this later.
func _on_bridge_connected() -> void:
	client.send_command("wait", {})

func _on_snapshot(data: Dictionary) -> void:
	# Route the render through the store: draw the live zone plus any remembered
	# neighbours (same stratum) the player has visited, placed by global offset.
	Profiler.add_us("server", int(data.get("serverUs", 0)))
	Profiler.begin("ingest")
	store.ingest(data)
	Profiler.done("ingest")
	Profiler.begin("neighbors")
	var nbs := _neighbor_zones()
	Profiler.done("neighbors")
	# first-person: hide the player creature (the camera sits on its cell)
	var pc: Dictionary = data.get("player", {})
	renderer.set_hidden_cell(Vector2i(int(pc.get("x", -1)), int(pc.get("y", -1)))
			if _mode == CamMode.FIRST_PERSON else Vector2i(-9999, -9999))
	Profiler.begin("render")
	renderer.render_snapshot(store.live_snapshot(), nbs)
	Profiler.done("render")
	inspector.on_snapshot(data)

	# Auto-dump the profile every N turns (cumulative, no reset) so it's always fresh
	# without needing a keypress — the manual P key can be flaky (window focus / UI).
	_prof_turns += 1
	if _prof_turns % 40 == 0:
		_dump_profile(false)

	_update_time(data.get("time", {}))

	var z: Dictionary = data.get("zone", {})
	if z.has("width") and z.has("height"):
		_zone_center = Vector3(float(z["width"]) / 2.0, 0.0, float(z["height"]) / 2.0)
		_zone_dims = Vector2(float(z["width"]), float(z["height"]))

	# Crossing a zone edge re-anchors the live zone to local coords, so the player's
	# (px,py) jumps discontinuously (e.g. 0 -> 79) and everything on screen shifts.
	# Shift the camera by the SAME amount (the two zones' global-origin difference) so
	# it stays locked on the same world content — a seamless continuous crossing, no
	# cut or sweep. Also don't read the coord jump as a step (it flipped `_facing`).
	var zid := String(z.get("id", ""))
	var old_zid := _prev_zone_id
	var crossed := old_zid != "" and zid != old_zid
	_prev_zone_id = zid
	if crossed and store.has_zone(old_zid) and store.has_zone(zid):
		var oo: Vector3i = store.record(old_zid).get("origin", Vector3i.ZERO)
		var no: Vector3i = store.record(zid).get("origin", Vector3i.ZERO)
		var shift := Vector3(oo.x - no.x, 0.0, oo.y - no.y)
		_eye += shift
		_look += shift
		_free_eye += shift
		# _update_camera already ran THIS frame (Main._process precedes the client's),
		# positioning the camera from the pre-shift eye — but the world just re-anchored.
		# Shift the live camera transform too so this frame renders in sync (no 1-frame
		# flip); next frame's lerp continues seamlessly from the shifted eye.
		if _cam != null:
			_cam.position += shift
			if _cam.position.distance_to(_look) > 0.001:
				# top-down looks straight down, so its up-ref is NORTH, not world-up (which is
				# parallel to the view = a degenerate look_at → the zone-crossing flicker)
				var xtop := _mode == CamMode.TOP_FOLLOW
				_cam.look_at(_look, NORTH if xtop else Vector3.UP)
	elif crossed:
		print("[cross] SKIPPED shift: old=%s has=%s  new=%s has=%s" % [
			old_zid, store.has_zone(old_zid), zid, store.has_zone(zid)])

	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return
	var tile := Vector2i(px, py)
	if not crossed and _prev_tile.x > -9999 and tile != _prev_tile:
		# facing = the direction of the last actual step, so the camera trails behind
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

## Remembered zones to draw around the live one: every OTHER stored zone on the
## same stratum, offset by the difference of its global origin from the live zone's
## (in cells = world units). Cross-stratum stacking is Phase 2; a distance/eviction
## radius is Phase 1's freeze-unfreeze step — for now the store holds few zones.
func _neighbor_zones() -> Array:
	var out: Array = []
	var live_id := store.live_id()
	if live_id == "":
		return out
	var live_rec := store.live_record()
	var live_origin: Vector3i = live_rec.get("origin", Vector3i.ZERO)
	var live_z: int = int(live_rec.get("stratum", 0))
	for id in store.ids():
		if id == live_id:
			continue
		var rec: Dictionary = store.record(id)
		if int(rec.get("stratum", -9999)) != live_z:
			continue
		var o: Vector3i = rec.get("origin", Vector3i.ZERO)
		out.append({
			"id": id,
			"cells": rec.get("snapshot", {}).get("cells", []),
			"offset": Vector2i(o.x - live_origin.x, o.y - live_origin.y),
		})
	return out

# --- remote control (for automated dev loops) -------------------------------
# Claude can't send keys to Godot, only commands to Qud's bridge. So Godot polls a
# small command file: control.py writes lines, we execute + delete. Lets an external
# driver trigger Godot-side actions (screenshot, switch camera) to close the loop.
var _cmd_accum := 0.0
func _poll_godot_cmd(dt: float) -> void:
	_cmd_accum += dt
	if _cmd_accum < 0.1:
		return
	_cmd_accum = 0.0
	if renderer == null:
		return
	var base := renderer.tiles_dir().get_base_dir()
	if base == "":
		return
	var path := base.path_join("godot_cmd")
	if not FileAccess.file_exists(path):
		return
	var txt := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)   # consume it
	for line in txt.split("\n", false):
		_exec_godot_cmd(line.strip_edges())

func _exec_godot_cmd(cmd: String) -> void:
	if cmd == "":
		return
	var parts := cmd.split(" ", false)
	match parts[0]:
		"shot":
			_screenshot(false, true)   # forced: window is unfocused, no auto-draw
		"cam":
			if parts.size() > 1:
				_set_mode(clampi(int(parts[1]) - 1, 0, 7))   # 1-8 -> COMPASS..TOP_FOLLOW
		"fph":
			if parts.size() > 1:
				_fp_height = clampf(float(parts[1]), 0.15, 3.0)

var _bg_draw_accum := 0.0
const BG_DRAW_INTERVAL := 0.05   # ~20fps forced draws while unfocused

func _process(dt: float) -> void:
	_poll_godot_cmd(dt)
	# Keep the viewer rendering while its window is UNFOCUSED, so it stays live beside
	# Qud for side-by-side human testing (a human drives one window; both must move).
	# macOS pauses an unfocused window's draw, but _process still runs — so force a draw
	# at ~20fps (the same primitive the remote screenshot uses). Only when unfocused, to
	# avoid double-drawing over the normal focused render loop.
	if not get_window().has_focus():
		_bg_draw_accum += dt
		if _bg_draw_accum >= BG_DRAW_INTERVAL:
			_bg_draw_accum = 0.0
			RenderingServer.force_draw()
	# ease the grade so time-of-day shifts smoothly between turns
	_tint = _tint.lerp(_tint_target, clampf(dt * 2.0, 0.0, 1.0))
	if _grade != null:
		_grade.color = _tint
	_sky = _sky.lerp(_sky_target, clampf(dt * 2.0, 0.0, 1.0))
	if _env != null:
		_env.background_color = _sky
		_env.fog_light_color = _sky   # fade distant zones into the current sky colour

	if _mode == CamMode.KEYBOARD:
		_fly(dt)
	elif _mode == CamMode.MOUSE and not Input.is_key_pressed(KEY_SHIFT):
		# orbit params: Q/E yaw, R/F pitch
		if Input.is_key_pressed(KEY_Q): _yaw += 1.5 * dt
		if Input.is_key_pressed(KEY_E): _yaw -= 1.5 * dt
		if Input.is_key_pressed(KEY_R): _pitch = clampf(_pitch + 1.0 * dt, PITCH_MIN, PITCH_MAX)
		if Input.is_key_pressed(KEY_F): _pitch = clampf(_pitch - 1.0 * dt, PITCH_MIN, PITCH_MAX)
	elif _mode == CamMode.CINEMATIC and (inspector == null or inspector.selected_tile() == null):
		_cine_t += dt * 0.35   # slow auto-orbit ONLY with no target; a selected tile holds the framing still
	# R/F zoom (Shift-guarded so Shift+F still switches). Top-down modes zoom the ortho
	# span via _top_zoom; the perspective modes zoom the eye distance via _dist.
	var _td_zoom := _mode == CamMode.TOP_FOLLOW
	if _td_zoom and not Input.is_key_pressed(KEY_SHIFT):
		if Input.is_key_pressed(KEY_R): _top_zoom = clampf(_top_zoom * (1.0 - dt), TOP_ZOOM_MIN, TOP_ZOOM_MAX)
		if Input.is_key_pressed(KEY_F): _top_zoom = clampf(_top_zoom * (1.0 + dt), TOP_ZOOM_MIN, TOP_ZOOM_MAX)
	elif (_mode == CamMode.COMPASS or _mode == CamMode.FOLLOW or _mode == CamMode.FIRST_PERSON) \
			and not Input.is_key_pressed(KEY_SHIFT):
		if Input.is_key_pressed(KEY_R): _dist = clampf(_dist * (1.0 - dt), DIST_MIN, DIST_MAX)
		if Input.is_key_pressed(KEY_F): _dist = clampf(_dist * (1.0 + dt), DIST_MIN, DIST_MAX)
	_update_camera(dt)
	if _multiview_on:
		_update_multiview_cameras()

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

# The fixed compass heading as a unit direction (what the camera looks ALONG).
func _compass_dir() -> Vector3:
	return Vector3(sin(_compass_yaw), 0, cos(_compass_yaw))

# COMPASS: behind the player along the LOCKED heading at a low angle. Follows the
# player's position but never rotates on movement — this is the disorientation fix.
func _compass_eye() -> Vector3:
	var back := TILES_BEHIND + _dist * cos(COMPASS_PITCH)
	return _player - _compass_dir() * back + Vector3(0, _dist * sin(COMPASS_PITCH), 0)

# CINEMATIC v1: frame the player and the selected target tile (their midpoint), at a
# distance that fits both, slowly orbiting. Combat-aware framing (an event buffer of
# attackers) is future work once Qud sends combat events.
func _frame_center() -> Vector3:
	var sel = inspector.selected_tile() if inspector != null else null
	if sel != null:
		return (_player + Vector3(sel.x, 0.0, sel.y)) * 0.5
	return _player

func _frame_radius() -> float:
	var sel = inspector.selected_tile() if inspector != null else null
	if sel != null:
		return clampf(_player.distance_to(Vector3(sel.x, 0.0, sel.y)) * 0.9 + 7.0, 9.0, 40.0)
	return 13.0

## Eye + look-at for any camera mode, from the current shared state. Extracted so the
## multi-view picker can drive one camera per mode off the same math. Returns [eye, look].
func _mode_eye_look(mode: int) -> Array:
	match mode:
		CamMode.KEYBOARD:
			return [_free_eye, _free_eye + _aim_dir()]
		CamMode.MOUSE:
			var c := _orbit_center()
			return [c + Vector3(_dist * cos(_pitch) * sin(_yaw), _dist * sin(_pitch),
				_dist * cos(_pitch) * cos(_yaw)), c]
		CamMode.FOLLOW:
			return [_follow_eye(), _follow_look()]
		CamMode.FIRST_PERSON:
			var e := _player + Vector3(0, _fp_height, 0)
			return [e, e + _compass_dir() + Vector3(0, -0.15, 0)]
		CamMode.CINEMATIC:
			var cc := _frame_center()
			var r := _frame_radius()
			return [cc + Vector3(r * cos(COMPASS_PITCH) * sin(_cine_t),
				r * sin(COMPASS_PITCH) + 2.0, r * cos(COMPASS_PITCH) * cos(_cine_t)), cc]
		CamMode.TOP_FOLLOW:
			return [_player + Vector3(0, TOP_H, 0), _player]
		_:  # COMPASS — the default, stable, cardinal-locked view
			return [_compass_eye(), _player]

func _update_camera(dt: float) -> void:
	var el := _mode_eye_look(_mode)
	var target_eye: Vector3 = el[0]
	var target_look: Vector3 = el[1]

	if dt <= 0.0 or not _seeded or _snap_cam:
		_eye = target_eye
		_look = target_look
		_snap_cam = false
	else:
		var k: float = clampf(FOLLOW_LERP * dt, 0.0, 1.0)
		_eye = _eye.lerp(target_eye, k)
		_look = _look.lerp(target_look, k)

	var top := _mode == CamMode.TOP_FOLLOW
	_apply_top_down_camera(top)
	_pivot.position = Vector3.ZERO
	_cam.position = _eye
	if _eye.distance_to(_look) > 0.001:
		# top-down looks straight down, so the up reference is NORTH (screen-up), not
		# world-up (which is parallel to the view and would be degenerate).
		_cam.look_at(_look, NORTH if top else Vector3.UP)

## Orthographic + DOF-off while overhead (a flat classic map, no perspective skew and
## no distance blur), perspective otherwise. Ortho `size` is the view's vertical span
## in cells: the TOP_FOLLOW span scaled by the wheel/R-F zoom.
func _apply_top_down_camera(top: bool) -> void:
	if top:
		if _cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
			_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.size = _top_ortho_size()
	elif _cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	var attrs := _cam.attributes as CameraAttributesPractical
	if attrs != null:
		attrs.dof_blur_far_enabled = not top

func _top_ortho_size() -> float:
	return TOP_FOLLOW_SPAN * _top_zoom

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

# --- camera-relative movement (the Godot -> Qud control translation) ---------
# The player moves in Qud's absolute 8-way compass, but the arrow keys mean
# directions relative to the CAMERA — "up" is forward on screen no matter which
# way the camera faces. We take the camera's ground-plane heading, build the
# screen-space intent (forward/back/strafe), rotate it into world space, and snap
# to the nearest compass name before sending it to the bridge.

## The direction the camera looks ALONG on the ground plane, per mode. FOLLOW
## trails your last step; COMPASS / FIRST_PERSON use the locked compass heading.
func _camera_heading() -> Vector3:
	if _mode == CamMode.TOP_FOLLOW:
		return NORTH   # north-up map: screen-forward is always north, whatever the yaw
	var h: Vector3 = _facing3() if _mode == CamMode.FOLLOW else _compass_dir()
	h.y = 0.0
	if h.length() < 0.001:
		return Vector3(0, 0, 1)   # default: south (matches _facing seed)
	return h.normalized()

## Snap a world ground vector to the nearest of Qud's 8 compass directions.
## +x = east, +z = south (Godot z mirrors Qud's south-growing y). Angle 0 = East,
## increasing toward South; 45° sectors.
func _dir_to_compass(v: Vector3) -> String:
	var idx: int = int(round(atan2(v.z, v.x) / (PI / 4.0))) & 7
	return ["E", "SE", "S", "SW", "W", "NW", "N", "NE"][idx]

## Move the player relative to the camera. `intent` is (strafe, forward) in screen
## space: (0,1)=forward, (0,-1)=back, (1,0)=right, (-1,0)=left.
func _move_relative(intent: Vector2) -> void:
	var h := _camera_heading()
	var right := h.cross(Vector3.UP)   # camera/body right (world space)
	if right.length() < 0.001:
		right = Vector3(1, 0, 0)
	right = right.normalized()
	var v := h * intent.y + right * intent.x
	if v.length() < 0.001:
		return
	client.send_command("move", {"dir": _dir_to_compass(v.normalized())})

func _set_mode(m: int) -> void:
	if _multiview_on:
		_toggle_multiview()   # picking a mode leaves the multi-view grid
	if m == _mode:
		return
	# entering free flight, start from where the camera already is
	if m == CamMode.KEYBOARD:
		_free_eye = _eye
	if m == CamMode.MOUSE:
		_pan = Vector3.ZERO
	# snap (don't lerp) across a top-down boundary: the NORTH up-vector can be
	# parallel to a north/south view direction mid-lerp, a degenerate look_at
	var leaving_top := _mode == CamMode.TOP_FOLLOW
	var entering_top := m == CamMode.TOP_FOLLOW
	if leaving_top or entering_top:
		_snap_cam = true
	_mode = m
	if renderer != null:
		# lay tile billboards flat for the straight-down modes, stand them up otherwise
		renderer.set_top_down(m == CamMode.TOP_FOLLOW)
	_update_mode_label()

## One gesture -> everything a collaborator needs about a tile. Photograph the BARE
## scene FIRST (no selection overlay), then inspect — so shot.png is a clean plate
## of the tile, paired with the report (selection.txt) and Qud's view (qud_shot.png).
func _inspect_and_capture() -> void:
	await _screenshot(true)
	_inspect()

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
	if renderer != null:
		renderer.set_daylight(sun_a)   # fade additive torch glow so it doesn't blow out daytime
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

## Inspect from a multi-view pane: raycast with that pane's camera + the pane-local mouse
## position. The 3D marker is shared, so the pick shows across every pane.
func _multiview_inspect(cam: Camera3D, pos: Vector2) -> void:
	inspector.inspect_at(cam, pos)
	var sel = inspector.selected_tile()
	if sel != null:
		reporter.set_target(sel.x, sel.y, inspector.zone_id(),
			inspector.last_objects(), inspector.last_report())

## Write the Pareto timing report to profile.txt (Claude reads it). Auto-called every
## 40 turns (reset=false, cumulative), and by the P key (reset=true, fresh window).
func _dump_profile(reset := true) -> void:
	var dir := renderer.tiles_dir().get_base_dir()
	if dir == "":
		return
	var f := FileAccess.open(dir.path_join("profile.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string(Profiler.report())
		f.close()
	if reset:
		Profiler.reset()

## Save the viewport to a known path so a collaborator can just read it.
##
## The OS-level `screencapture` is blocked without Screen Recording permission,
## and this is better anyway: it captures the rendered viewport exactly, with no
## window chrome and nothing overlapping it.
func _screenshot(clean := false, forced := false) -> void:
	var dir := renderer.tiles_dir().get_base_dir()
	if dir == "":
		return
	# `clean` drops the WHOLE selection overlay — report panel and 3D marker — out of
	# frame, so the shot is a bare plate of the scene; restored right after.
	var restore := false
	if clean and inspector.overlay_visible():
		inspector.set_overlay_visible(false)
		restore = true
	if forced:
		# a remote (control.py) shot: the window is unfocused so no frame is being
		# drawn and `await frame_post_draw` would hang forever. Force one now.
		RenderingServer.force_draw()
	else:
		await RenderingServer.frame_post_draw      # let the frame finish first
	var img := get_viewport().get_texture().get_image()
	if restore:
		inspector.set_overlay_visible(true)
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

const _MODE_NAMES := {
	CamMode.COMPASS: "COMPASS — cardinal-locked · arrows move (↑=fwd) · Q/E rotate · R/F zoom",
	CamMode.FOLLOW: "FOLLOW — trails your heading · arrows move (↑=fwd) · R/F zoom",
	CamMode.FIRST_PERSON: "FIRST-PERSON — ↑↓ move · ←→ turn · Shift+←→ strafe",
	CamMode.CINEMATIC: "CINEMATIC — frames you + selected tile",
	CamMode.MOUSE: "ORBIT — drag around the selected tile",
	CamMode.KEYBOARD: "FLY — WASD move, arrows aim",
	CamMode.TOP_FOLLOW: "TOP-DOWN FOLLOW — classic overhead · north up · tracks you · R/F zoom",
}

func _update_mode_label() -> void:
	_mode_label.text = "camera: %s     ·  ` menu · 1-7 · 0 all-views" % _MODE_NAMES.get(_mode, "?")
	if _time_label != "":
		_mode_label.text += "     ⏱ " + _time_label
	_update_debug_menu()

# --- debug menu -------------------------------------------------------------

var _debug_menu: PanelContainer
var _mode_buttons := {}

# --- multi-view camera picker -----------------------------------------------
# A grid of live SubViewports, one per camera mode, all sharing the main 3D world so you
# can compare every view at once (differential testing). Click a pane or press its number
# to switch to that mode full-screen; toggle with `0` or the debug-menu button.
const MULTIVIEW_MODES := [CamMode.COMPASS, CamMode.FOLLOW, CamMode.FIRST_PERSON,
	CamMode.CINEMATIC, CamMode.MOUSE, CamMode.KEYBOARD, CamMode.TOP_FOLLOW]
var _multiview_layer: CanvasLayer
var _multiview_on := false
var _multiview_cams: Array = []   # [{mode, cam, sv}]

func _build_multiview() -> void:
	_multiview_layer = CanvasLayer.new()
	_multiview_layer.layer = 4
	_multiview_layer.visible = false
	add_child(_multiview_layer)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	_multiview_layer.add_child(grid)
	var shared := get_viewport().find_world_3d()
	for m in MULTIVIEW_MODES:
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
		cam.fov = _cam.fov
		sv.add_child(cam)
		cam.current = true   # the active camera for this sub-viewport
		cell.add_child(svc)
		var lbl := Label.new()
		lbl.text = "%d  %s" % [m + 1, String(_MODE_NAMES.get(m, "?")).split(" —")[0]]
		lbl.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(lbl)
		# Left-click a pane = inspect the tile under the cursor with THAT pane's camera; the
		# marker lives in the shared world, so it appears in every pane at once. Number keys
		# (1-7) still switch that mode full-screen.
		var pane_cam := cam
		cell.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_multiview_inspect(pane_cam, e.position))
		grid.add_child(cell)
		_multiview_cams.append({"mode": m, "cam": cam, "sv": sv})

func _toggle_multiview() -> void:
	if _multiview_layer == null:
		return
	_multiview_on = not _multiview_on
	_multiview_layer.visible = _multiview_on
	for v in _multiview_cams:
		(v["sv"] as SubViewport).render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if _multiview_on else SubViewport.UPDATE_DISABLED

## Per-frame: point each preview camera at its mode's view, off the shared camera math.
func _update_multiview_cameras() -> void:
	for v in _multiview_cams:
		var m: int = v["mode"]
		var cam: Camera3D = v["cam"]
		var el := _mode_eye_look(m)
		var eye: Vector3 = el[0]
		var look: Vector3 = el[1]
		var top := m == CamMode.TOP_FOLLOW
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL if top else Camera3D.PROJECTION_PERSPECTIVE
		if top:
			cam.size = _top_ortho_size()
		cam.position = eye
		if eye.distance_to(look) > 0.001:
			cam.look_at(look, NORTH if top else Vector3.UP)

func _build_debug_menu() -> void:
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
	_debug_menu_title = title
	vb.add_child(title)
	for m in [CamMode.COMPASS, CamMode.FOLLOW, CamMode.FIRST_PERSON, CamMode.CINEMATIC,
			CamMode.MOUSE, CamMode.KEYBOARD, CamMode.TOP_FOLLOW]:
		var b := Button.new()
		b.text = "%d  %s" % [m + 1, String(_MODE_NAMES[m]).split(" —")[0].split(" ·")[0]]
		# click-only: don't take keyboard focus, or a focused button would swallow the
		# movement arrows (Godot uses them for UI focus navigation) after any click.
		b.focus_mode = Control.FOCUS_NONE
		var mv: int = m
		b.pressed.connect(func(): _set_mode(mv))
		vb.add_child(b)
		_mode_buttons[m] = b
	# all-views grid (differential testing)
	var mvb := Button.new()
	mvb.text = "0  MULTI-VIEW (all)"
	mvb.focus_mode = Control.FOCUS_NONE
	mvb.pressed.connect(_toggle_multiview)
	vb.add_child(mvb)
	# first-person eye-height slider
	var hl := Label.new()
	hl.text = "first-person height"
	vb.add_child(hl)
	var sld := HSlider.new()
	sld.min_value = 0.15
	sld.max_value = 3.0
	sld.step = 0.05
	sld.value = _fp_height
	sld.custom_minimum_size = Vector2(160, 0)
	sld.focus_mode = Control.FOCUS_NONE   # drag-only; keep arrows for the player
	sld.value_changed.connect(func(v): _fp_height = v)
	vb.add_child(sld)
	# deep-water depth slider (0 = swimmers ride the surface, 1 = a full tile under)
	var wl := Label.new()
	wl.text = "deep water depth"
	vb.add_child(wl)
	var wsld := HSlider.new()
	wsld.min_value = 0.0
	wsld.max_value = 1.0
	wsld.step = 0.05
	wsld.value = renderer.deep_water_depth
	wsld.custom_minimum_size = Vector2(160, 0)
	wsld.focus_mode = Control.FOCUS_NONE
	wsld.value_changed.connect(_on_water_depth_changed)
	vb.add_child(wsld)
	_debug_menu = panel
	_update_debug_menu()

## Live-apply the deep-water depth: creatures are re-cropped in the dynamic pass, so
## re-render the current snapshot (same zone -> only the cheap dynamics rebuild) for
## instant feedback instead of waiting for the next turn.
func _on_water_depth_changed(v: float) -> void:
	renderer.deep_water_depth = v
	var live: Dictionary = store.live_snapshot()
	if not live.is_empty():
		renderer.render_snapshot(live, _neighbor_zones())

## A small reset button in the top-right corner: restarts the whole program (so code
## changes are picked up, not just a state reset) at the CURRENT window size.
func _build_reset_button() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	var btn := Button.new()
	btn.text = "⟳ Reset"
	btn.focus_mode = Control.FOCUS_NONE   # click-only; keep arrows for the player
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.offset_left = -96.0
	btn.offset_right = -10.0
	btn.offset_top = 10.0
	btn.offset_bottom = 38.0
	btn.pressed.connect(_reset_program)
	layer.add_child(btn)

## Relaunch the process, preserving the current window size via --resolution (a plain
## reload_current_scene would keep the old cached scripts; a restart re-reads them).
func _reset_program() -> void:
	_save_settings()   # persist before the restart (quit() doesn't fire WM_CLOSE_REQUEST)
	var sz := DisplayServer.window_get_size()
	OS.set_restart_on_exit(true, PackedStringArray(["--resolution", "%dx%d" % [sz.x, sz.y]]))
	get_tree().quit()

## Save on window close (the X); the Reset button saves explicitly in _reset_program.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_settings()

## Persist the view/render settings a run should remember.
func _save_settings() -> void:
	var sz := DisplayServer.window_get_size()
	var d := {
		"mode": _mode,
		"compass_yaw": _compass_yaw,
		"dist": _dist,
		"top_zoom": _top_zoom,
		"fp_height": _fp_height,
		"water_depth": (renderer.deep_water_depth if renderer != null else 0.6),
		"win": [sz.x, sz.y],
	}
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()

## Restore what _save_settings wrote. Sets values only (no _set_mode — the label isn't
## built yet); the mode's camera/renderer setup follows from _mode in _update_camera and
## the set_top_down call here. Missing/invalid keys keep the code defaults.
func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(d) != TYPE_DICTIONARY:
		return
	_compass_yaw = float(d.get("compass_yaw", _compass_yaw))
	_dist = clampf(float(d.get("dist", _dist)), DIST_MIN, DIST_MAX)
	_top_zoom = clampf(float(d.get("top_zoom", _top_zoom)), TOP_ZOOM_MIN, TOP_ZOOM_MAX)
	_fp_height = clampf(float(d.get("fp_height", _fp_height)), 0.15, 3.0)
	if renderer != null:
		renderer.deep_water_depth = clampf(float(d.get("water_depth", renderer.deep_water_depth)), 0.0, 1.0)
	var win = d.get("win", null)
	if win is Array and win.size() == 2 and int(win[0]) > 200 and int(win[1]) > 200:
		DisplayServer.window_set_size(Vector2i(int(win[0]), int(win[1])))
	var m := int(d.get("mode", _mode))
	if m >= 0 and m <= CamMode.TOP_FOLLOW:
		_mode = m
		if renderer != null:
			renderer.set_top_down(m == CamMode.TOP_FOLLOW)

func _toggle_debug_menu() -> void:
	if _debug_menu != null:
		_debug_menu.visible = not _debug_menu.visible

func _update_debug_menu() -> void:
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).modulate = Color(0.55, 1.0, 0.55) if m == _mode else Color(1, 1, 1)

# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# Shift+Space: wait a turn in Qud (a Godot->Qud passthrough). Takes a turn for now.
		if event.shift_pressed and event.keycode == KEY_SPACE:
			client.send_command("wait", {}); return
		# mode switches first — they reassign what the arrows mean
		if event.shift_pressed and event.keycode == KEY_C:
			_set_mode(CamMode.MOUSE); return
		if event.shift_pressed and event.keycode == KEY_K:
			_set_mode(CamMode.KEYBOARD); return
		if event.shift_pressed and event.keycode == KEY_F:
			_set_mode(CamMode.FOLLOW); return
		# camera modes by number (mirrored in the ` debug menu)
		if event.keycode == KEY_1: _set_mode(CamMode.COMPASS); return
		if event.keycode == KEY_2: _set_mode(CamMode.FOLLOW); return
		if event.keycode == KEY_3: _set_mode(CamMode.FIRST_PERSON); return
		if event.keycode == KEY_4: _set_mode(CamMode.CINEMATIC); return
		if event.keycode == KEY_5: _set_mode(CamMode.MOUSE); return
		if event.keycode == KEY_6: _set_mode(CamMode.KEYBOARD); return
		if event.keycode == KEY_7: _set_mode(CamMode.TOP_FOLLOW); return
		if event.keycode == KEY_0: _toggle_multiview(); return   # 0 = all-views grid
		if event.keycode == KEY_QUOTELEFT:      # ` toggles the debug menu
			_toggle_debug_menu(); return
		# Q/E rotate the locked compass heading 90° (COMPASS mode only)
		if _mode == CamMode.COMPASS and event.keycode == KEY_Q:
			_compass_yaw += PI * 0.5; return
		if _mode == CamMode.COMPASS and event.keycode == KEY_E:
			_compass_yaw -= PI * 0.5; return
		if event.keycode == KEY_ESCAPE:
			# close the camera/debug menu and any selection, but KEEP the current camera
			_dismiss_selection()
			if _debug_menu != null:
				_debug_menu.visible = false
			return
		if event.keycode == KEY_I:
			_inspect(); return
		if event.keycode == KEY_F12:
			_screenshot(); return
		if event.keycode == KEY_P:
			_dump_profile(); return   # P: macOS grabs F9 (Mission Control)
		if event.keycode == KEY_MINUS:
			inspector.nudge_font(-2)
			reporter.nudge_font(-2); return
		if event.keycode == KEY_EQUAL:
			inspector.nudge_font(2)
			reporter.nudge_font(2); return
		# in KEYBOARD mode the arrows drive the camera, not the player
		if _mode == CamMode.KEYBOARD:
			return
		# Arrows move the PLAYER relative to the camera heading — "up" is always
		# forward on screen, whichever way the camera faces (the Godot->Qud
		# translation). Numpad stays ABSOLUTE 8-way compass as a precise fallback.
		# FIRST-PERSON turns in place on L/R (Shift+L/R strafes) instead of moving.
		match event.keycode:
			KEY_UP:    _move_relative(Vector2(0, 1))    # forward
			KEY_DOWN:  _move_relative(Vector2(0, -1))   # back
			KEY_LEFT:
				if _mode == CamMode.FIRST_PERSON and not event.shift_pressed:
					_compass_yaw += PI * 0.25            # turn left 45°
				else:
					_move_relative(Vector2(-1, 0))       # strafe left
			KEY_RIGHT:
				if _mode == CamMode.FIRST_PERSON and not event.shift_pressed:
					_compass_yaw -= PI * 0.25            # turn right 45°
				else:
					_move_relative(Vector2(1, 0))        # strafe right
			KEY_KP_8: client.send_command("move", {"dir": "N"})
			KEY_KP_2: client.send_command("move", {"dir": "S"})
			KEY_KP_4: client.send_command("move", {"dir": "W"})
			KEY_KP_6: client.send_command("move", {"dir": "E"})
			KEY_KP_7: client.send_command("move", {"dir": "NW"})
			KEY_KP_9: client.send_command("move", {"dir": "NE"})
			KEY_KP_1: client.send_command("move", {"dir": "SW"})
			KEY_KP_3: client.send_command("move", {"dir": "SE"})
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
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					if _mode == CamMode.TOP_FOLLOW:
						_top_zoom = clampf(_top_zoom * 0.9, TOP_ZOOM_MIN, TOP_ZOOM_MAX)
					else:
						_dist = clampf(_dist * 0.9, DIST_MIN, DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					if _mode == CamMode.TOP_FOLLOW:
						_top_zoom = clampf(_top_zoom * 1.1, TOP_ZOOM_MIN, TOP_ZOOM_MAX)
					else:
						_dist = clampf(_dist * 1.1, DIST_MIN, DIST_MAX)
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

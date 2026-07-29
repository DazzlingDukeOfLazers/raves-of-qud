extends Node3D

## The Holodeck's camera rig — extracted from Main. Owns the `_pivot` + `_cam` (Camera3D) nodes, all
## camera modes/state/consts, and the per-frame placement math. Main feeds it the player position each
## snapshot and routes camera input to it; it drives where the eye sits and what it looks at.
##
## STAGE 1 of the Main.gd decomposition: this holds the state + math + nodes. Main still owns input,
## the snapshot step/cross detection, the mode label, the debug menu, multiview, and settings, and it
## reaches into this rig's members for those (later stages move those seams behind methods). Fields the
## outside touches are left un-underscored where practical; the pure-internal helpers keep their `_`.
##
## CAMERA MODES (see Main's header for the key bindings):
##   COMPASS (default, cardinal-locked), FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW.

enum CamMode { COMPASS, FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW }
var _mode: int = int(Settings.get_value("camera", CamMode.COMPASS))   # default from Options; COMPASS = cardinal-locked

# Top-down (Qud-classic): orthographic, straight down, NORTH locked to screen-top, tracking the player.
const TOP_H := 20.0        # ortho eye height above the ground (scale is size, not H)
const TOP_FIT_MARGIN := 1.06   # padding so the framed zone isn't flush to the edges
const NORTH := Vector3(0, 0, -1)   # -z is north (Qud's y grows south); screen-up in top-down
const TOP_FOLLOW_SPAN := 18.0  # TOP_FOLLOW vertical span (cells) at zoom 1.0 (user mode)
# 1:1 (parity) mode uses its OWN top-down span so a tile renders the same pixel size as Qud at
# 1600x900, separate from user TOP_FOLLOW (which stays 18). NOTE: this value is an initial estimate
# and needs LIVE CALIBRATION against Qud — enter 1:1 with the viewport on at 1600x900, R/F-zoom until
# a tile matches Qud, then set this to the matched span (R/F multiplies _top_zoom on top of it).
const ONE_TO_ONE_SPAN := 24.0
const TOP_ZOOM_MIN := 0.15
const TOP_ZOOM_MAX := 3.5
var _top_zoom := 1.0           # wheel / R-F zoom for the top-down follow mode
var _one_to_one := false       # parity mode: use ONE_TO_ONE_SPAN instead of TOP_FOLLOW_SPAN
# Qud tiles are 16x24, so top-down stretches the world's north-south (Z) axis by 24/16 = 1.5 so cells
# read 16:24 like Qud. Only in full-screen top-down (not perspective, not multi-view: shared world stays square).
const TILE_ASPECT := 1.5

var _pivot: Node3D
var _cam: Camera3D
var _yaw := 0.7
var _pitch := 0.9            # radians above the ground plane (MOUSE orbit)
var _dist := 14.0
# Vertical camera pan: S/D lower/raise the whole view at the current spot. Added to BOTH eye and look so
# the view slides straight up/down keeping its angle. Not saved (reset to 0 each run and on a mode change).
var _cam_lift := 0.0
const CAM_LIFT_SPEED := 6.0     # units/sec while a key is held
const CAM_LIFT_MIN := -30.0
const CAM_LIFT_MAX := 40.0
# Horizontal camera dolly: W/X step the view one tile forward/back along the heading. Discrete, transient.
var _cam_pan := Vector3.ZERO
const CAM_STEP := 1.0           # one tile per W/X press

# --- compass cam (cardinal-locked, the disorientation fix) -------------------
const COMPASS_PITCH := 0.61     # ~35° above the ground: the low, dramatic FAR/default angle
const COMPASS_PITCH_NEAR := 1.30 # ~74° at closest zoom: overhead, looking down at the head
const COMPASS_CLOSE_DIST := 8.0  # only BELOW this does the arc lift toward overhead; above it stays at COMPASS_PITCH
var _compass_yaw := 0.0         # locked heading in radians; Q/E rotate in _compass_step steps
var _compass_45 := true         # Q/E step: 45° (true, default — the 8-way) or 90°
func compass_step() -> float:
	return (PI * 0.25) if _compass_45 else (PI * 0.5)
var _cine_t := 0.0              # cinematic auto-orbit phase
const FP_EYE_H := 0.55          # first-person default eye height above the ground
var _fp_height := FP_EYE_H      # live first-person eye height (debug-menu slider)
var _pan := Vector3.ZERO     # user pan offset (MOUSE mode); persists across turns

# --- follow-cam -------------------------------------------------------------
const TILES_BEHIND := 0.5    # fixed camera standoff behind the player (small; at range _dist dominates)
const FOCUS_AHEAD := 2.0     # look at a point this far in FRONT of the player
const HEAD_LOOK_H := 0.9     # look-target height: the head (close overhead shot) ...
const WAIST_LOOK_H := 0.45   # ... or the waist (centres the whole body) — a ` menu toggle
var _look_head := true       # default: track the head (feet-aim buries the head when zoomed close)
const FOLLOW_LERP := 6.0     # per-second approach; keeps steps from snapping
var _player := Vector3(40, 0, 12)
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

const ORBIT_SENS := 0.006
const PITCH_MIN := 0.12
const PITCH_MAX := 1.45
const DIST_MIN := 2.1        # closest zoom: with COMPASS_PITCH_NEAR this puts the eye ~2 tiles up / 1 back
const DIST_MAX := 140.0

var _renderer: Node          # ZoneRenderer: cutaway, world zstretch scale, top-down billboard lay-down
var _inspector: Node         # CellInspector: the selected tile MOUSE/CINEMATIC orbit around

## Create the pivot + camera under `parent`, wire the render/inspect refs. `inspector` may be null at
## first (Main builds it after the camera) — set it later with set_inspector().
func setup(parent: Node3D, renderer_ref: Node, inspector_ref: Node) -> void:
	_renderer = renderer_ref
	_inspector = inspector_ref
	_pivot = Node3D.new()
	add_child(_pivot)
	_cam = Camera3D.new()
	_cam.far = 8000.0   # parasang-scale surface landmarks (the Spindle) tower thousands of units up
	_pivot.add_child(_cam)
	# Depth of field: a field of vinewafer reads as one flat colour blob without it. Far blur only —
	# near blur would smear the player.
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 18.0
	attrs.dof_blur_far_transition = 12.0
	attrs.dof_blur_amount = 0.10
	_cam.attributes = attrs
	# `parent` is accepted for call-site symmetry with SkyGrade.setup(); the rig is already added to the
	# tree by Main before setup(), and the pivot/cam are children of the rig itself.
	var _unused := parent

func set_inspector(inspector_ref: Node) -> void:
	_inspector = inspector_ref

# Public handles Main / multiview / inspector / screenshots need.
func cam() -> Camera3D:
	return _cam
func mode() -> int:
	return _mode

func _current_zstretch() -> float:
	return TILE_ASPECT if (_mode == CamMode.TOP_FOLLOW and not _multiview_active()) else 1.0

# Multiview is owned by Main (a later cut). It flips the shared world back to square and disables the
# top-down stretch/cutaway; Main tells us via process()/set_mode(), tracked here so zstretch() agrees.
var _mv_on := false
func _multiview_active() -> bool:
	return _mv_on
## Main keeps the multiview flag; it syncs us on toggle so apply_zstretch()/zstretch() see the live value
## even between process() frames. process() also refreshes it each frame.
func set_multiview(on: bool) -> void:
	_mv_on = on

## Public alias for the zstretch, for Main's pick/inspect projection math.
func zstretch() -> float:
	return _current_zstretch()

## Push the current Z-stretch onto the rendered world (renderer node + marker). Called on mode/multiview change.
func apply_zstretch() -> void:
	if _renderer != null:
		_renderer.scale = Vector3(1, 1, _current_zstretch())

## Place the camera immediately from current state, no lerp (startup / a forced re-seat).
func snap() -> void:
	_update_camera(0.0)

## Per-frame camera update: held-key fly/zoom, then place the eye, then wall cutaway. `multiview_on`
## disables the cutaway + top-down stretch (the shared grid stays square, nothing between eye and player).
func process(dt: float, multiview_on: bool) -> void:
	_mv_on = multiview_on
	if _mode == CamMode.KEYBOARD:
		_fly(dt)
	elif _mode == CamMode.MOUSE and not Input.is_key_pressed(KEY_SHIFT):
		# orbit params: Q/E yaw, R pitch-up. (F is Fire now, not pitch-down — see Main._unhandled_input.)
		if Input.is_key_pressed(KEY_Q): _yaw += 1.5 * dt
		if Input.is_key_pressed(KEY_E): _yaw -= 1.5 * dt
		if Input.is_key_pressed(KEY_R): _pitch = clampf(_pitch + 1.0 * dt, PITCH_MIN, PITCH_MAX)
	elif _mode == CamMode.CINEMATIC and (_inspector == null or _inspector.selected_tile() == null):
		_cine_t += dt * 0.35   # slow auto-orbit ONLY with no target; a selected tile holds the framing still
	# R zooms IN (Shift-guarded so Shift+ chords still switch). F is Fire now (was zoom-out); the wheel
	# still zooms both ways. Top-down zooms the ortho span via _top_zoom; perspective the eye distance via _dist.
	var _td_zoom := _mode == CamMode.TOP_FOLLOW
	if _td_zoom and not Input.is_key_pressed(KEY_SHIFT):
		if Input.is_key_pressed(KEY_R): _top_zoom = clampf(_top_zoom * (1.0 - dt), TOP_ZOOM_MIN, TOP_ZOOM_MAX)
	elif (_mode == CamMode.COMPASS or _mode == CamMode.FOLLOW or _mode == CamMode.FIRST_PERSON) \
			and not Input.is_key_pressed(KEY_SHIFT):
		if Input.is_key_pressed(KEY_R): _dist = clampf(_dist * (1.0 - dt), DIST_MIN, DIST_MAX)
	_update_camera(dt)
	# Fade walls between the camera and the player so rock doesn't block the view. Off in top-down
	# (looking straight down), first-person (you're inside it), free-fly, and the multi-view grid.
	if _renderer != null:
		var cut := not multiview_on and _mode != CamMode.TOP_FOLLOW \
			and _mode != CamMode.FIRST_PERSON and _mode != CamMode.KEYBOARD
		_renderer.apply_cutaway(_cam.global_position, _player + Vector3(0, look_h(), 0), dt, cut)

# --- camera placement -------------------------------------------------------

func _facing3() -> Vector3:
	return Vector3(_facing.x, 0, _facing.y).normalized()

## Behind the player along the facing, raised by the current zoom/pitch.
func _follow_eye() -> Vector3:
	var f := _facing3()
	var back := TILES_BEHIND + _dist * cos(_pitch)
	return _player - f * back + Vector3(0, _dist * sin(_pitch), 0)

func _follow_look() -> Vector3:
	return _player + _facing3() * FOCUS_AHEAD + Vector3(0, look_h(), 0)

## MOUSE mode orbits whatever tile is selected, so inspecting and then looking around don't fight. Falls
## back to the player.
func _orbit_center() -> Vector3:
	var sel = _inspector.selected_tile() if _inspector != null else null
	var c: Vector3 = _player
	if sel != null:
		c = Vector3(sel.x, 0, sel.y)
	return c + _pan

# The fixed compass heading as a unit direction (what the camera looks ALONG).
func _compass_dir() -> Vector3:
	return Vector3(sin(_compass_yaw), 0, cos(_compass_yaw))

## The camera's forward on the ground plane, for the W/X dolly. COMPASS/FIRST_PERSON use the locked
## heading; FOLLOW the player's facing; else the current view direction flattened to horizontal.
func cam_forward() -> Vector3:
	match _mode:
		CamMode.COMPASS, CamMode.FIRST_PERSON:
			return _compass_dir()
		CamMode.FOLLOW:
			return _facing3()
		_:
			var d := _look - _eye
			d.y = 0.0
			return d.normalized() if d.length() > 0.001 else _compass_dir()

# COMPASS: behind the player along the LOCKED heading at a low angle. Follows position, never rotates.
func _compass_eye() -> Vector3:
	var p := _compass_pitch()
	var back := TILES_BEHIND + _dist * cos(p)
	return _player - _compass_dir() * back + Vector3(0, _dist * sin(p), 0)

## COMPASS pitch varies with zoom: shallow (COMPASS_PITCH) from COMPASS_CLOSE_DIST outward, steepening to
## COMPASS_PITCH_NEAR (overhead) as you zoom inside it. Smoothstepped so it arcs up-and-over at the close end.
func _compass_pitch() -> float:
	if _dist >= COMPASS_CLOSE_DIST:
		return COMPASS_PITCH
	var t: float = (_dist - DIST_MIN) / (COMPASS_CLOSE_DIST - DIST_MIN)   # 0 at min .. 1 at close
	t = t * t * (3.0 - 2.0 * t)                                          # smoothstep
	return lerpf(COMPASS_PITCH_NEAR, COMPASS_PITCH, t)

## Look-target height above the player's feet: the head or the waist (` menu toggle).
func look_h() -> float:
	return HEAD_LOOK_H if _look_head else WAIST_LOOK_H

# CINEMATIC v1: frame the player and the selected target tile (their midpoint), at a fitting distance,
# slowly orbiting. Combat-aware framing is future work once Qud sends combat events.
func _frame_center() -> Vector3:
	var sel = _inspector.selected_tile() if _inspector != null else null
	if sel != null:
		return (_player + Vector3(sel.x, 0.0, sel.y)) * 0.5
	return _player

func _frame_radius() -> float:
	var sel = _inspector.selected_tile() if _inspector != null else null
	if sel != null:
		return clampf(_player.distance_to(Vector3(sel.x, 0.0, sel.y)) * 0.9 + 7.0, 9.0, 40.0)
	return 13.0

## Eye + look-at for any camera mode, from the current shared state. The multi-view picker drives one
## camera per mode off the same math. Returns [eye, look].
func eye_look_for(mode: int) -> Array:
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
			return [_compass_eye(), _player + Vector3(0, look_h(), 0)]

func _update_camera(dt: float) -> void:
	var el := eye_look_for(_mode)
	var target_eye: Vector3 = el[0]
	var target_look: Vector3 = el[1]
	# When the world is Z-stretched for top-down, aim at the stretched N-S position so the player stays centred.
	var zs := _current_zstretch()
	if zs != 1.0:
		target_eye.z *= zs
		target_look.z *= zs

	# S/D vertical pan + W/X horizontal dolly: slide the whole view (added to both eye and look, so the angle holds).
	if _cam_lift != 0.0:
		target_eye.y += _cam_lift
		target_look.y += _cam_lift
	if _cam_pan != Vector3.ZERO:
		target_eye += _cam_pan
		target_look += _cam_pan

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
		# top-down looks straight down, so the up reference is NORTH (screen-up), not world-up
		# (which is parallel to the view and would be degenerate).
		_cam.look_at(_look, NORTH if top else Vector3.UP)

## Orthographic + DOF-off while overhead (a flat classic map), perspective otherwise. Ortho `size` is the
## view's vertical span in cells: the TOP_FOLLOW span scaled by the wheel/R-F zoom.
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
	return (ONE_TO_ONE_SPAN if _one_to_one else TOP_FOLLOW_SPAN) * _top_zoom

## Enter/leave 1:1 (parity) framing. Resets the R/F zoom so the span is deterministic, and
## re-applies the ortho size immediately if we're already in top-down (the toggle-while-in-
## TOP_FOLLOW case, where set_mode is a no-op and wouldn't otherwise refresh the size).
func set_one_to_one(on: bool) -> void:
	_one_to_one = on
	_top_zoom = 1.0
	if _mode == CamMode.TOP_FOLLOW and _cam != null:
		_apply_top_down_camera(true)

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

# --- camera-relative movement helpers (the Godot -> Qud control translation; Main sends the command) ---

## The direction the camera looks ALONG on the ground plane, per mode. FOLLOW trails your last step;
## COMPASS / FIRST_PERSON use the locked compass heading.
func camera_heading() -> Vector3:
	if _mode == CamMode.TOP_FOLLOW:
		return NORTH   # north-up map: screen-forward is always north, whatever the yaw
	var h: Vector3 = _facing3() if _mode == CamMode.FOLLOW else _compass_dir()
	h.y = 0.0
	if h.length() < 0.001:
		return Vector3(0, 0, 1)   # default: south (matches _facing seed)
	return h.normalized()

## Snap a world ground vector to the nearest of Qud's 8 compass directions. +x = east, +z = south.
func dir_to_compass(v: Vector3) -> String:
	var idx: int = int(round(atan2(v.z, v.x) / (PI / 4.0))) & 7
	return ["E", "SE", "S", "SW", "W", "NW", "N", "NE"][idx]

## Switch camera mode (the camera part only — Main's wrapper leaves multiview + refreshes the label).
## Returns true if the mode actually changed.
func set_mode(m: int) -> bool:
	if m == _mode:
		return false
	_cam_lift = 0.0   # a fresh view on every camera switch (S/D + W/X pan is per-look-around)
	_cam_pan = Vector3.ZERO
	if m == CamMode.KEYBOARD:   # entering free flight, start from where the camera already is
		_free_eye = _eye
	if m == CamMode.MOUSE:
		_pan = Vector3.ZERO
	# snap (don't lerp) across a top-down boundary: the NORTH up-vector can be parallel to a north/south
	# view direction mid-lerp, a degenerate look_at
	var leaving_top := _mode == CamMode.TOP_FOLLOW
	var entering_top := m == CamMode.TOP_FOLLOW
	if leaving_top or entering_top:
		_snap_cam = true
	_mode = m
	if _renderer != null:
		_renderer.set_top_down(m == CamMode.TOP_FOLLOW)   # lay tiles flat for straight-down modes
	apply_zstretch()
	return true

## Snapshot feed (Main computes moved/crossed from the wire; we apply the camera consequences). -------

## A seamless zone crossing shifted the world by `delta`; move the eye/look with it so the camera stays
## locked on the same content. Also fix the live camera transform this frame (Main._process already ran).
func apply_cross_shift(delta: Vector3) -> void:
	_eye += delta
	_look += delta
	_free_eye += delta
	if _cam != null:
		_cam.position += delta
		if _cam.position.distance_to(_look) > 0.001:
			var xtop := _mode == CamMode.TOP_FOLLOW
			_cam.look_at(_look, NORTH if xtop else Vector3.UP)

## The player is at `pos`; if they actually stepped (`moved` and not a crossing) update the trailing facing.
func set_player(pos: Vector3, facing: Vector2, update_facing: bool) -> void:
	if update_facing and facing.length() > 0.0:
		_facing = facing.normalized()
	_player = pos
	if not _seeded:
		_seeded = true
		_free_eye = _follow_eye()
		_eye = _free_eye
		_look = _follow_look()

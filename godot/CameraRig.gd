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
const TOP_ZOOM_MIN := 0.15
const TOP_ZOOM_MAX := 3.5
var _top_zoom := 1.0           # wheel / R-F zoom for the top-down follow mode
var _one_to_one := false       # parity mode: fit the ZONE (biggest zoom-out) instead of TOP_FOLLOW_SPAN
var _zone_cells := Vector2(80, 25)   # live zone dims in cells (pushed from Main), for the 1:1 zone-fit
var _right_inset := 0.0        # 1:1: fraction of the viewport the side panels cover; lens-shifts the
							   # top-down view LEFT so the zone-fit centres in the visible play hole
# 1:1 pixel model — Qud's LetterboxCamera reproduced (decompiled 2.0.211.50):
#   stage = tilesWide*16 x tilesHigh*24 art px; base scale S = min(holeW/stageW, holeH/stageH) (the
#   "Fit" PlayScale, non-integer allowed); zoom factor steps by 0.25, min 1.0 (ZoomIn/ZoomOut round
#   to quarters); orthographicSize = base/zoom; at zoom > 1 the camera pans to the player, CLAMPED so
#   the view never leaves the stage (ClampPanPosition) — at fit-zoom the clamp pins dead centre.
# _play_hole is the on-screen px rect the playfield shows through (row 3's transparent hole, pushed
# from MainFrame); when it's set, 1:1 uses this model instead of the old margin'd _zone_fit_size.
const QUD_TILE_W := 16.0       # Qud tile art px (LetterboxCamera.tileWidth/Height)
const QUD_TILE_H := 24.0
const QUD_ZOOM_STEP := 0.25    # scroll-wheel zoom quantum (GameManager.ZoomIn/ZoomOut)
# Qud's zoomed-pan window (empirical, 18-row sweep at 1.5x — see _one_to_one_center):
# the pan space sits south of the hole centre and is narrower than the letterbox area.
const QUD_PAN_OFF_Y_PX := 54.0   # pan-space centre minus hole centre, screen px
const QUD_PAN_AREA_H_PX := 920.0 # pan-space effective height, screen px
var _play_hole := Rect2()      # px rect of the play hole; Rect2() = unset -> legacy zone-fit
var _zoom_q := 1.0             # Qud-style zoom factor (quarters, >= 1.0); only meaningful in 1:1
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
	var _td_zoom := _mode == CamMode.TOP_FOLLOW and not _one_to_one   # 1:1 zooms in Qud's quarter
	if _td_zoom and not Input.is_key_pressed(KEY_SHIFT):              # steps (wheel), not continuous R
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
			if _one_to_one and _play_hole.size.x > 0.0:
				var c := _one_to_one_center()
				return [c + Vector3(0, TOP_H, 0), c]
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
	# 1:1 lens shift: centre the view on the play HOLE, not the window. With the hole rect known, both
	# axes shift by (window centre - hole centre) in world units (px / px-per-unit; px-per-unit is
	# uniform = vp.y / ortho size). Sign: h_offset moves the frustum centre right -> the world appears
	# left, which is what a hole LEFT of the window centre needs; v symmetrically (screen-y down).
	# Without a hole rect yet, fall back to the old sidebar-fraction horizontal-only shift.
	var h_off := 0.0
	var v_off := 0.0
	if top and _one_to_one and _cam != null:
		var vp: Vector2 = _cam.get_viewport().get_visible_rect().size
		if _play_hole.size.x > 0.0 and vp.y > 0.0 and _cam.size > 0.0:
			var ppu := vp.y / _cam.size                     # px per world unit (= 16S)
			var hole_c := _play_hole.get_center()
			h_off = (vp.x * 0.5 - hole_c.x) / ppu
			v_off = (hole_c.y - vp.y * 0.5) / ppu
		elif _right_inset > 0.0 and vp.y > 0.0:
			var aspect := vp.x / vp.y
			h_off = _right_inset * 0.5 * _cam.size * aspect
	_cam.h_offset = h_off
	_cam.v_offset = v_off
	var attrs := _cam.attributes as CameraAttributesPractical
	if attrs != null:
		attrs.dof_blur_far_enabled = not top

func _top_ortho_size() -> float:
	if _one_to_one:
		if _play_hole.size.x > 0.0 and _play_hole.size.y > 0.0:
			# Qud pixel model: S = fit scale x quarter-stepped zoom; a cell renders 16S x 24S px.
			# ortho size is the FULL viewport's vertical span in (stretched) world units, and one
			# world unit = 16S px, so size = vp_h / (16S). The lens offsets then centre the stage
			# in the play hole (see _apply_top_down_camera).
			var vp: Vector2 = _cam.get_viewport().get_visible_rect().size if _cam != null else Vector2(1920, 1080)
			return vp.y / (QUD_TILE_W * _stage_scale())
		# fallback (no hole pushed yet): the old margin'd zone-fit
		return _zone_fit_size() * minf(_top_zoom, 1.0)
	return TOP_FOLLOW_SPAN * _top_zoom

## Qud's stage scale: screen px per tile-art px. Base = fit the whole stage (zone) into the play
## hole (min of the two axes, non-integer allowed — Qud's "Fit" PlayScale), then x the quarter-
## stepped zoom factor. One world unit (a cell's E-W extent) = 16 art px = 16S screen px.
func _stage_scale() -> float:
	var stage_w := _zone_cells.x * QUD_TILE_W
	var stage_h := _zone_cells.y * QUD_TILE_H
	var base := minf(_play_hole.size.x / stage_w, _play_hole.size.y / stage_h)
	return base * _zoom_q

## Scroll-wheel zoom in 1:1: quarter steps of the factor, floor 1.0 (= the whole-zone fit), exactly
## Qud's GameManager.ZoomIn/ZoomOut. Re-applies immediately so the step lands without waiting a frame.
## Set the 1:1 zoom factor outright (snapped to Qud's quarters, floor 1.0) — the godot_cmd
## `zoom1to1 <f>` test hook; the wheel/keys go through zoom_1to1_step.
func set_zoom_1to1(f: float) -> void:
	_zoom_q = maxf(1.0, snappedf(f, QUD_ZOOM_STEP))
	if _mode == CamMode.TOP_FOLLOW and _cam != null:
		_apply_top_down_camera(true)

func zoom_1to1_step(dir: int) -> void:
	_zoom_q = maxf(1.0, snappedf(_zoom_q + QUD_ZOOM_STEP * float(dir), QUD_ZOOM_STEP))
	if _mode == CamMode.TOP_FOLLOW and _cam != null:
		_apply_top_down_camera(true)

## MainFrame pushes the play hole's px rect (row 3's transparent area) whenever the layout moves.
func set_play_hole(r: Rect2) -> void:
	_play_hole = r
	if _one_to_one and _mode == CamMode.TOP_FOLLOW and _cam != null:
		_apply_top_down_camera(true)

## The 1:1 camera target: the zone centre plus a pan toward the player, CLAMPED so the visible hole
## never leaves the stage — Qud's ClampPanPosition. At fit-zoom the clamp is 0 on the binding axis
## (and the letterboxed axis centres too, exactly like Qud's letterbox), so the view is dead-centred;
## zoomed in, it follows the player until the view hits a zone edge. Unstretched world units — the
## caller (_update_camera) applies the N-S z-stretch afterward, so Z spans divide by TILE_ASPECT.
func _one_to_one_center() -> Vector3:
	var center := Vector3((_zone_cells.x - 1.0) * 0.5, 0.0, (_zone_cells.y - 1.0) * 0.5)
	var s := _stage_scale()
	if s <= 0.0:
		return center
	var ppu := QUD_TILE_W * s                                 # px per (unstretched E-W) world unit
	var half_view_x := _play_hole.size.x / ppu * 0.5
	var half_view_z := _play_hole.size.y / ppu / TILE_ASPECT * 0.5
	var slack_x := maxf(0.0, _zone_cells.x * 0.5 - half_view_x)
	# Qud's zoomed VERTICAL pan, measured with an 18-row blob-anchored sweep at 1.5x (the
	# user's "moving to the centre desyncs" report): the camera follows player - 5/24 cells at
	# slope 1, clamped to a pan window that is NOT centred on the stage — Qud's pan space sits
	# ~54 screen px south of the hole centre with an effective height of ~920 px (its dock
	# safe-area, which differs from the letterbox target area that centres the fit view).
	# Measured pins at 1.5x: centre range [8.43, 13.21] (follow releases rows ~8.6..13.4).
	# When the slack collapses (<= 0, e.g. the whole-zone fit) there is no panning at all and
	# the letterbox centring alone holds (centre = stage centre).
	var s_total := _stage_scale()
	var cellh_px := QUD_TILE_H * s_total
	var pan_shift_z := QUD_PAN_OFF_Y_PX / cellh_px
	var slack_z := (QUD_TILE_H * _zone_cells.y - QUD_PAN_AREA_H_PX / s_total) / (2.0 * QUD_TILE_H)
	var p_target := (_player.z - center.z) - 5.0 / 24.0
	if slack_z > 0.0:
		center.z += clampf(p_target, -pan_shift_z - slack_z, -pan_shift_z + slack_z)
	center.x += clampf(_player.x - center.x, -slack_x, slack_x)
	return center

## Ortho vertical size that frames the WHOLE current zone (both axes) within the view, with a small
## margin — the 1:1 "zone as border" biggest zoom-out. The zone is _zone_cells wide (E-W) and tall
## (N-S), and the N-S axis is z-stretched by TILE_ASPECT, so it's fit against the viewport aspect.
func _zone_fit_size() -> float:
	var aspect := 16.0 / 9.0
	if _cam != null:
		var vp: Vector2 = _cam.get_viewport().get_visible_rect().size
		if vp.y > 0.0:
			aspect = vp.x / vp.y
	var zh := _zone_cells.y * TILE_ASPECT   # zone N-S extent in world units (z-stretched)
	var zw := _zone_cells.x                  # zone E-W extent in world units
	# The side panels cover the right _right_inset of the window, so the zone must fit the play HOLE,
	# not the full width — shrink the usable width fraction. (The lens shift in _apply_top_down_camera
	# then recentres this hole-fit zone into the hole.) Clamped so a pathological inset can't blow up.
	var wfrac := maxf(0.25, 1.0 - _right_inset)
	return maxf(zh, zw / (aspect * wfrac)) * TOP_FIT_MARGIN

## The live zone's dimensions in cells (pushed from Main on each snapshot), for the 1:1 zone-fit.
func set_zone_cells(v: Vector2) -> void:
	if v.x > 0.0 and v.y > 0.0:
		_zone_cells = v

## Fraction of the viewport width the 1:1 side panels cover (MainFrame → Main → here). Drives the
## top-down lens shift so the zone-fit centres in the visible play hole. Re-applied immediately if
## we're already top-down.
func set_right_inset(frac: float) -> void:
	_right_inset = clampf(frac, 0.0, 0.6)
	if _mode == CamMode.TOP_FOLLOW and _cam != null:
		_apply_top_down_camera(true)

## Enter/leave 1:1 (parity) framing. Resets the zoom so the biggest zoom-out (the whole zone) is the
## default, and re-applies the ortho size immediately if we're already in top-down (the toggle-while-
## in-TOP_FOLLOW case, where set_mode is a no-op and wouldn't otherwise refresh the size).
func set_one_to_one(on: bool) -> void:
	_one_to_one = on
	_top_zoom = 1.0
	_zoom_q = 1.0     # 1:1 always re-enters at the whole-zone fit (Qud's default zoom factor 1.0)
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

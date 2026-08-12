extends Node3D

## Day/night atmosphere for the Holodeck — extracted from Main. Owns the WorldEnvironment (fog/ambient),
## the full-screen MULTIPLY grade (dims the 3D by time of day, UNDER the frame chrome), and the sun/moon
## disc billboards + a sun DirectionalLight on a per-hour arc. Main feeds it the snapshot's time + stratum
## (`update`) each turn; it eases the tint/sky toward their targets in `_process`.
##
## The world is UNSHADED, so the grade — not real lights — carries the time-of-day mood; per-cell night/
## cave dimming is the renderer's darkness overlay (`ZoneRenderer._build_darkness`), so these tints stay
## bright or they'd double-dark and kill the very light pools we want.

const SKY_NIGHT := Color(0.03, 0.05, 0.12)   # deep blue night void
const SKY_DAY := Color(0.32, 0.55, 0.85)     # daytime blue
const SKY_DUSK := Color(0.75, 0.45, 0.35)    # warm dawn/dusk horizon
const SKY_DIST := 180.0
const NIGHT_TINT := Color(0.62, 0.68, 0.88)  # cool moonlit cast — mood only (per-cell darkness does the dim)
const DAY_TINT := Color(1.0, 0.99, 0.96)     # near-neutral, a hair warm
const DUSK_TINT := Color(1.0, 0.72, 0.50)    # warm dawn/dusk

const SURFACE_Z := 10                        # Qud's surface stratum; > this is underground (no sun/moon)
const CAVE_TINT := Color(0.82, 0.85, 0.95)   # faintly cool underground; the per-cell darkness does the dim
const CAVE_SKY := Color(0.015, 0.02, 0.03)   # near-black rock void behind/into the fog

var _renderer: Node                # for set_daylight() — fades the additive torch glow so day doesn't blow out
var _grade: ColorRect
var _sun: Sprite3D
var _moon: Sprite3D
var _sun_light: DirectionalLight3D
var _env: Environment
var _tint := Color.WHITE
var _tint_target := Color.WHITE
var _sky := Color(0.05, 0.05, 0.07)
var _sky_target := Color(0.05, 0.05, 0.07)
var _zone_center := Vector3(40, 0, 12)       # sun/moon arc is centred on the live zone
var _depth := SURFACE_Z
var _underground := false

# Read by Main's mode label / debug HUD.
var time_label := ""
# DEPTH CUE (QoL "depthcue") — "make objects further away slightly darker". One fullscreen
# quad in the transparent pass reads the opaque depth buffer and mixes toward black with
# view distance. Camera-correct every frame in every mode (no per-sprite bookkeeping, no
# placement-time camera state — the depth-halo experiment's trap), and our sprites depth-write
# (ALPHA_CUT_DISCARD) so they participate like the walls do. The sky (far plane) is skipped;
# glows/smoke draw AFTER it (render_priority) so emissives are not dimmed.
const _DEPTHCUE_SHADER := "
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;
uniform sampler2D depth_tex : hint_depth_texture;
uniform float start_dist = 1.5;   // metres from the camera where darkening begins
uniform float span = 14.0;        // metres over which it ramps to max_dark
uniform float max_dark = 0.25;    // fraction of black mixed in at full distance
// Scale measured in-world (probe: dist/40 ramp): in first person MOST of the frame is
// under 8m — a 7m start confined the whole effect to a thin horizon strip (banded diff
// +0.98 there, 0.0 everywhere else). The ramp has to live inside 2..15m to separate
// one object from the next, not just near from far-horizon.

void vertex() {
	// z=0.5: comfortably inside NDC depth either side of the reversed-z change — exactly
	// ON the near plane (the documented 1.0) clipped the whole quad here and the pass
	// silently did nothing. Depth test is disabled, so the value only has to survive clip.
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
	float d = texture(depth_tex, SCREEN_UV).x;
	if (d <= 0.000001) { discard; }   // reversed-z far plane: the sky keeps its colour
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 vw = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vw.xyz /= vw.w;
	float dist = -vw.z;
	float k = clamp((dist - start_dist) / span, 0.0, 1.0);
	ALPHA = max_dark * k;
	ALBEDO = vec3(0.0);
}"
var _depthcue: MeshInstance3D = null

var day_frac := 0.5
var dawn_h := 6.5
var dusk_h := 20.0

## Build the environment, grade, and sky bodies. `embedded` = hosted in MainFrame (grade goes below the
## chrome on a negative CanvasLayer); `renderer_ref` receives the daylight fraction.
func setup(embedded: bool, renderer_ref: Node) -> void:
	_renderer = renderer_ref

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	# Explicit ambient as FILL (default source is the dark BG, which left lit surfaces almost black) — this
	# is what makes the rock read as lit; the sun adds directional highlight + shadow on top.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.72, 0.74)
	env.ambient_light_energy = 0.72
	# Depth fog fades distant/remembered zones into the sky (colour tracks the sky, updated in _process).
	# Off in the minimal 1:1 test (fog is a lighting/atmosphere effect Qud doesn't have).
	env.fog_enabled = not Settings.qud_shape("lighting")
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 60.0
	env.fog_depth_end = 240.0
	env.fog_depth_curve = 1.4     # >1: stay clear longer, then ramp up toward the end
	env.fog_light_color = env.background_color
	env.fog_sky_affect = 0.0      # the sky IS the fog colour; don't double-fog it
	# Bloom is OFF — a full-screen multi-pass post-process on top of DOF + fog tipped the M1 Pro past the
	# GPU timeout and HUNG. The Spindle reads bright via an HDR modulate instead. Flip on only if the
	# window is small or DOF is dropped.
	env.glow_enabled = false
	env.glow_intensity = 0.9
	env.glow_hdr_threshold = 1.05
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	_env = env
	we.environment = env
	add_child(we)

	# MULTIPLY grade over the 3D, under the UI. Full-window inside MainFrame it must sit BELOW the chrome
	# (root default canvas, layer 0), so a NEGATIVE layer keeps its MULTIPLY on the 3D only.
	var glayer := CanvasLayer.new()
	glayer.layer = -1 if embedded else 0
	add_child(glayer)
	_grade = ColorRect.new()
	_grade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gmat := CanvasItemMaterial.new()
	gmat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	_grade.material = gmat
	_grade.color = DAY_TINT
	glayer.add_child(_grade)

	# Sun and moon: big bright discs far out on a per-hour arc.
	_sun = _make_sky_body(Color(1.0, 0.93, 0.6), 26.0)
	_moon = _make_sky_body(Color(0.82, 0.86, 1.0), 16.0)
	add_child(_sun)
	add_child(_moon)

	# A real sun light, aimed by the hour — does little to the UNSHADED materials now, but it's the hook
	# directional shadows will hang on once walls move to a shaded material.
	_sun_light = DirectionalLight3D.new()
	_sun_light.light_energy = 0.0
	_sun_light.shadow_enabled = true
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_sun_light.shadow_bias = 0.04
	_sun_light.shadow_normal_bias = 1.5
	add_child(_sun_light)

	# The depth-cue pass (see the shader const). Always built; VISIBILITY is the live gate,
	# re-read each _process so the Options toggle applies without a rebuild and 1:1 forces
	# it off through qud_shape's short-circuit.
	var dc_sh := Shader.new()
	dc_sh.code = _DEPTHCUE_SHADER
	var dc_mat := ShaderMaterial.new()
	dc_mat.shader = dc_sh
	dc_mat.render_priority = -10       # first among transparents: glows and smoke stay bright
	_depthcue = MeshInstance3D.new()
	var dc_mesh := QuadMesh.new()
	dc_mesh.size = Vector2(2, 2)
	_depthcue.mesh = dc_mesh
	_depthcue.material_override = dc_mat
	# The vertex shader pins it fullscreen regardless of transform; the AABB just has to
	# survive frustum culling from anywhere.
	_depthcue.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	_depthcue.visible = false
	add_child(_depthcue)

## Fed each snapshot: Qud time dict, the player's stratum, and the live zone's centre (for the arc).
func update(t: Dictionary, depth: int, zone_center: Vector3) -> void:
	_depth = depth
	_underground = depth > SURFACE_Z
	_zone_center = zone_center
	_update_time(t)

func _process(dt: float) -> void:
	# Depth cue first: independent of the lighting feature, so it must precede that early return.
	if _depthcue != null:
		_depthcue.visible = not Settings.qud_shape("depthcue")
	# Lighting off -> no day/night MULTIPLY grade (true tile colours), no sky bodies, no fog.
	# ONE gate now: the `lighting` QoL feature. It used to be fx_lighting AND not qud_shape() --
	# fx_lighting was the older load-it-back experiment ("1:1 test · 3D lighting"), and once the
	# QoL registry existed the pair meant two switches for one divergence, which is the
	# half-exists confusion the registry was built to end. 1:1 still forces off via qud_shape's
	# short-circuit; Qud's lighting is the rectangular per-cell model in ZoneRenderer.
	if Settings.qud_shape("lighting"):
		if _grade != null:
			_grade.color = Color.WHITE
		if _sun != null:
			_sun.visible = false
		if _moon != null:
			_moon.visible = false
		# 1:1: the clear colour IS Qud's letterbox/area colour (measured 17,33,38 — everything
		# outside the 80x25 stage, which the clipped field plane now leaves exposed).
		# The letterbox belongs to the TILES question, not lighting: it is the area colour
		# around the CLIPPED 1:1 stage, and with tiles3d loaded back the huge user ground
		# replaces that stage -- painting the letterbox under it would tint the sky instead.
		if Settings.qud_shape("tiles3d") and _env != null:
			# Compensated like every other measured-from-Qud colour: the composited frame goes
			# through the same curve, which sagged a bare 17,33,38 to 18,30,34 on the glass.
			_env.background_color = QudChrome.q8(17, 33, 38)
		return
	# ease the grade + sky so time-of-day shifts smoothly between turns
	_tint = _tint.lerp(_tint_target, clampf(dt * 2.0, 0.0, 1.0))
	if _grade != null:
		_grade.color = _tint
	_sky = _sky.lerp(_sky_target, clampf(dt * 2.0, 0.0, 1.0))
	if _env != null:
		_env.background_color = _sky
		_env.fog_light_color = _sky   # fade distant zones into the current sky colour

## Turn Qud's hour into a day/night tint. Everything arrives in day-SEGMENTS; normalise to 0..24h. Uses
## the calendar's own dawn/dusk boundaries so it matches when Qud calls it day.
func _update_time(t: Dictionary) -> void:
	if _underground:
		_apply_cave_lighting()
		return
	if t.is_empty():
		return
	var spd: float = maxf(1.0, float(t.get("segmentsPerDay", 12000)))
	var hour: float = float(t.get("segment", spd * 0.5)) / spd * 24.0
	var dawn: float = float(t.get("startOfDay", 3250)) / spd * 24.0
	var dusk: float = float(t.get("startOfNight", 10000)) / spd * 24.0
	time_label = String(t.get("label", ""))
	day_frac = hour / 24.0
	dawn_h = dawn
	dusk_h = dusk
	_tint_target = _tint_for_hour(hour, dawn, dusk, 24.0)
	_sky_target = _sky_for_hour(hour, dawn, dusk)
	_update_sky(hour, dawn, dusk)

## Underground: no celestial bodies, so ignore the surface clock and hold a fixed dim cave ambient. The
## grade/sky still ease toward these targets, so a descent fades smoothly from daylight into the dark.
func _apply_cave_lighting() -> void:
	_tint_target = CAVE_TINT
	_sky_target = CAVE_SKY
	if _sun != null:
		_sun.visible = false
	if _moon != null:
		_moon.visible = false
	if _sun_light != null:
		_sun_light.light_energy = 0.0
	time_label = "Cavern -%d" % (_depth - SURFACE_Z)

## A bright disc billboard for a celestial body.
func _make_sky_body(col: Color, size_units: float) -> Sprite3D:
	var n := 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in n:
		for x in n:
			var d: float = Vector2(x - c, y - c).length() / c
			var a := 1.0 if d < 0.72 else clampf(1.0 - (d - 0.72) / 0.28, 0.0, 1.0)   # solid disc, soft rim
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

## Position sun and moon on a tilted arc: rise east, peak overhead, set west. The sun tracks day
## (dawn..dusk); the moon tracks the night span, opposite the sun. Fades each in/out so neither pops.
func _update_sky(hour: float, dawn: float, dusk: float) -> void:
	if _sun == null:
		return
	var sun_up := hour >= dawn and hour <= dusk
	var sun_p: float = clampf((hour - dawn) / maxf(0.01, dusk - dawn), 0.0, 1.0)
	var nlen: float = (24.0 - dusk) + dawn   # night runs dusk -> 24 -> dawn; fold into 0..1 for the moon
	var np: float = ((hour - dusk) if hour >= dusk else (hour + 24.0 - dusk)) / maxf(0.01, nlen)

	_sun.position = _body_pos(sun_p)
	_moon.position = _body_pos(np)

	var sun_a: float = clampf(minf(hour - dawn, dusk - hour) + 0.5, 0.0, 1.0) if sun_up else 0.0   # ~1h cross-fade
	if _renderer != null:
		_renderer.set_daylight(sun_a)   # fade additive torch glow so it doesn't blow out daytime
	_sun.modulate = Color(1, 1, 1, sun_a)
	_moon.modulate = Color(1, 1, 1, 1.0 - sun_a)
	_sun.visible = sun_a > 0.01
	_moon.visible = sun_a < 0.99

	if _sun_light != null:
		var d := (_zone_center - _sun.position).normalized()
		_sun_light.rotation = Vector3(asin(clampf(d.y, -1.0, 1.0)), atan2(d.x, d.z), 0.0)
		# lighting off: the directional sun stays dark (rectangular per-cell light only)
		var fx_on := not Settings.qud_shape("lighting")
		_sun_light.light_energy = (sun_a * 0.6) if fx_on else 0.0

## A body's world position for arc progress 0(rise)..1(set), tilted so it clears the horizon.
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

func _tint_for_hour(hour: float, dawn: float, dusk: float, _hpd: float) -> Color:
	var w := 2.0   # widths of the dawn/dusk transitions, in hours
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

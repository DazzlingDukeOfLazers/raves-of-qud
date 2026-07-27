extends Node3D

## Emitted every snapshot with the raw Qud data, so a host (MainFrame) can drive its status bar /
## panels off the same stream the Holodeck renders — no second bridge connection needed.
signal snapshot(data: Dictionary)

## Wires the bridge client to the renderer, drives the camera, and maps input to
## Qud movement commands. Built in code so the scene file stays a single node.
##
## CAMERA MODES — pick with the ` debug menu or number keys 1-7; the current mode
## and its controls show on screen.
##   1 COMPASS  (default)  cardinal-LOCKED low-angle view. Follows the player's
##                         position but NEVER rotates on movement, so the world
##                         doesn't spin under you. Q/E rotate the heading (45° default,
##                         90° toggle in the ` menu), R/F zoom. The stable, default view.
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
var _char_creator: CharacterCreator
var renderer: ZoneRenderer
var store := WorldStore.new()   # Phase-0 world store; renderer reads the live zone from it
var _prof_turns := 0            # for the periodic profile auto-dump
var inspector: CellInspector
var reporter: TileReport
var onboarding: OnboardingControl
var _font_preview: FontPreview

# Day/night atmosphere (sky bodies + MULTIPLY grade + time->tint) lives in SkyGrade.gd, fed each snapshot.
var _sky_grade                     # SkyGrade (Node3D); created in _ready

const SURFACE_Z := 10
var _depth := SURFACE_Z            # current stratum (zone.z); >SURFACE_Z is underground

# Vertical level stacking: how many strata BELOW the live zone still render (deeper
# ones cull off). Shallower levels never render (they'd occlude from above). The gap
# between levels is renderer.level_height (a ` menu slider).
const LEVEL_KEEP_DOWN := 2

# The camera rig (nodes + modes + placement math) lives in CameraRig.gd, created in _ready. Main keeps
# this enum as a MIRROR so its mode checks (input, snapshot, multiview) read `CamMode.X`; the values match
# CameraRig.CamMode exactly. `_cam_rig._mode` is the live mode. (Stage 1 of the Main.gd decomposition.)
enum CamMode { COMPASS, FOLLOW, FIRST_PERSON, CINEMATIC, MOUSE, KEYBOARD, TOP_FOLLOW }
var _cam_rig                    # CameraRig (Node3D, loaded); created in _ready. Untyped so the headless
                                # --check-only stays deterministic (a class_name's cache is flaky there);
                                # locals off _cam_rig.* therefore need explicit types, not `:=`.
var _multiview                  # Multiview (Node, loaded); the all-views grid. Created in _ready.

# Remembered view/render settings, saved on exit and restored on launch (so Raves doesn't
# reset to "looking south" every run). In user:// — available at startup, before the mod
# sends the support-dir path.
const SETTINGS_PATH := "user://raves_settings.json"

var _zone_center := Vector3(40, 0, 12)
var _zone_dims := Vector2(80, 25)   # live zone width x height in cells
var _prev_tile := Vector2i(-9999, -9999)
var _prev_zone_id := ""          # to detect zone crossings (shift the camera to stay continuous)
var _mode_label: Label
var _debug_menu_title: Label
var _reset_btn: Button
var _wm_cards_btn: Button   # persistent top-right world-map card toggle (mirrors O / the ` menu)
## Set true by MainFrame before this scene enters its SubViewport: the Holodeck is hosted inside the
## main UI frame, so hide its OWN chrome (mode label + Reset/2D buttons). The frame supplies its menu.
var embedded := false

## When false, skip ALL 3D build/render work in _on_snapshot — bridge + data (the snapshot signal)
## keep flowing with zero GPU/Metal work. The frame connects data-first with this off, then calls
## set_render_3d(true) to bring the viewport up separately. Default true = standalone renders normally.
var render_3d := true
var _ui_theme: Theme   # project-wide default theme (UiFont) on the root viewport — see _ready

# Responsive HUD text: a fraction of viewport height, but never below a floor —
# "min(px, %vh)" web sensibility, re-applied on window resize.
# Font sizes come from UiFont (the single source of truth). These stay as thin aliases so the rest
# of the file / the ruler read the same numbers.
func _ui_font_size() -> int:
	return UiFont.px(get_viewport(), "body")

## Size EVERY label/button in the top UI from the source of truth: the mode label, the whole debug
## menu (title, mode buttons, toggle buttons, slider labels), and the corner Reset button. Re-run on
## window resize so it tracks the viewport.
func _apply_ui_fonts() -> void:
	UiFont.refresh_theme(_ui_theme, get_viewport())   # keep the project-wide default in sync with the window
	_stamp_theme_roots(get_tree().root)               # make the default theme cross CanvasLayer boundaries
	var fs := _ui_font_size()
	if _mode_label != null:
		_mode_label.add_theme_font_size_override("font_size", fs)
	if _debug_menu != null:
		_apply_font_recursive(_debug_menu, fs)
	if _reset_btn != null:
		_reset_btn.add_theme_font_size_override("font_size", fs)
	if _wm_cards_btn != null:
		_wm_cards_btn.add_theme_font_size_override("font_size", fs)
	# keep the debug menu just BELOW the help label so they never overlap, even as
	# the responsive font grows the label's height
	if _debug_menu != null and _mode_label != null:
		var lh: float = maxf(_mode_label.get_minimum_size().y, float(fs))
		_debug_menu.position = Vector2(14, _mode_label.position.y + lh + 8.0)

## Make the project-wide default theme (UiFont) reach EVERY Control, even ones nested under a
## CanvasLayer or plain Node. In Godot 4 a Control whose direct parent is neither a Control nor a
## Window becomes its own "theme root" and does NOT inherit the root viewport's theme — so a single
## CanvasLayer in the chain (CharacterCreator, and any future pop-up UI) severs propagation and the
## controls fall back to the tiny built-in default. Assigning `_ui_theme` to each such theme-root
## Control reconnects the whole tree to the one source of truth. Idempotent; safe to re-run on resize
## or after new UI is built. Controls that set their OWN theme on purpose (OnboardingControl) are left
## alone so their explicit choice still wins.
func _stamp_theme_roots(node: Node) -> void:
	if node is Control:
		var p := node.get_parent()
		if not (p is Control) and (node as Control).theme == null:
			(node as Control).theme = _ui_theme
	for c in node.get_children():
		_stamp_theme_roots(c)

## Apply a font size to every Label/Button under `node` (recursively) — how the debug menu and any
## nested popups get sized uniformly from one call.
func _apply_font_recursive(node: Node, size: int) -> void:
	if node is Label or node is Button:
		node.add_theme_font_size_override("font_size", size)
	for c in node.get_children():
		_apply_font_recursive(c, size)

## Show/hide the font-size ruler (Lorem Ipsum at each px) with the current UI-font math in the header,
## so you can pick the MINIMUM and NORMAL sizes. Toggle: L, or the ` menu button.
func _toggle_font_preview() -> void:
	if _font_preview == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var hdr := "Font-size ruler — window %dx%d · current UI font %dpx  (UiFont.MIN=%d, FRAC=%.4f)" % [
		int(vp.x), int(vp.y), _ui_font_size(), UiFont.MIN, UiFont.FRAC]
	_font_preview.toggle(hdr)

func _ready() -> void:
	# Source-of-truth fonts, made AUTOMATIC: a project-wide default theme on the root viewport, so
	# every Control that doesn't override — CharacterCreator, and any future UI — inherits the UiFont
	# body size + the Atkinson font for free. Refreshed on resize in _apply_ui_fonts.
	_ui_theme = UiFont.make_theme(get_viewport())
	get_tree().root.theme = _ui_theme

	renderer = ZoneRenderer.new()
	add_child(renderer)

	client = BridgeClient.new()
	add_child(client)
	client.snapshot.connect(_on_snapshot)
	client.connected.connect(_on_bridge_connected)

	_sky_grade = load("res://SkyGrade.gd").new()   # day/night atmosphere: WorldEnvironment + grade + sun/moon
	add_child(_sky_grade)
	_sky_grade.setup(embedded, renderer)

	_cam_rig = load("res://CameraRig.gd").new()   # pivot + camera + modes + placement math
	add_child(_cam_rig)
	_cam_rig.setup(self, renderer, null)          # inspector wired in once it's built (below)

	# Multi-view grid (its own file). Built BEFORE the debug menu, whose button connects to its toggle.
	# Pane clicks call back into Main._multiview_inspect (Main owns the inspector + report form).
	_multiview = load("res://Multiview.gd").new()
	add_child(_multiview)
	_multiview.setup(_cam_rig, _MODE_NAMES, _multiview_inspect)

	_load_settings()   # restore camera heading/mode/zoom/depth/window before the UI reads them
	_build_mode_label()
	_build_debug_menu()
	_build_reset_button()
	_apply_ui_fonts()
	get_viewport().size_changed.connect(_apply_ui_fonts)
	_cam_rig.apply_zstretch()   # a restored top-down mode needs the stretch applied at startup
	_cam_rig.snap()             # place the camera from the restored state (was _update_camera(0.0))

	inspector = CellInspector.new()
	add_child(inspector)
	inspector.setup(renderer, _cam_rig._cam)
	_cam_rig.set_inspector(inspector)

	reporter = TileReport.new()
	add_child(reporter)
	reporter.setup(renderer)
	reporter.dismissed.connect(_dismiss_selection)

	onboarding = OnboardingControl.new()
	add_child(onboarding)
	onboarding.setup()

	_font_preview = FontPreview.new()
	add_child(_font_preview)

	_char_creator = CharacterCreator.new()
	_char_creator.client = client
	add_child(_char_creator)

	# Every UI subtree above is now in the tree; re-run so the theme stamp reaches the ones built
	# after the first _apply_ui_fonts() call (inspector, reporter, onboarding, font ruler, character
	# creator). Deferred so each node's own _ready()/_build has finished.
	_apply_ui_fonts.call_deferred()

	if embedded:
		_hide_holodeck_chrome()

## Hide the Holodeck's own on-screen chrome (mode label, ⟳ Reset, tiles-2D button) when it's hosted
## inside the main UI frame — the frame will provide these controls itself. The world, the debug menu
## (`), and the inspector still work; only the always-on HUD buttons go away.
## Turn the 3D build/render on or off at runtime. Turning it ON renders the current zone immediately
## (from the store the data-only path kept current) instead of waiting for the next turn.
func set_render_3d(on: bool) -> void:
	render_3d = on
	if on:
		var live: Dictionary = store.live_snapshot()
		if not live.is_empty():
			renderer.render_snapshot(live, _neighbor_zones())

func _hide_holodeck_chrome() -> void:
	if _mode_label != null:
		_mode_label.visible = false
	if _reset_btn != null:
		_reset_btn.visible = false
	if _wm_cards_btn != null:
		_wm_cards_btn.visible = false

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
	store.ingest(data)   # keep the store current even when not rendering, so 3D can start instantly
	Profiler.done("ingest")
	# The 3D build/render (meshes, SubViewport) is the heavy GPU work. When render_3d is off (the frame
	# hosts us data-first, viewport later) we skip ALL of it and just feed data — no Metal work at all.
	if render_3d:
		Profiler.begin("neighbors")
		var nbs := _neighbor_zones()
		Profiler.done("neighbors")
		# first-person: hide the player creature (the camera sits on its cell)
		var pc: Dictionary = data.get("player", {})
		renderer.set_hidden_cell(Vector2i(int(pc.get("x", -1)), int(pc.get("y", -1)))
				if _cam_rig._mode == CamMode.FIRST_PERSON else Vector2i(-9999, -9999))
		Profiler.begin("render")
		renderer.render_snapshot(store.live_snapshot(), nbs)
		Profiler.done("render")
	inspector.on_snapshot(data)
	snapshot.emit(data)   # let a host frame update its status bar / panels off the same data (always)

	# Auto-dump the profile every N turns (cumulative, no reset) so it's always fresh
	# without needing a keypress — the manual P key can be flaky (window focus / UI).
	_prof_turns += 1
	if _prof_turns % 40 == 0:
		_dump_profile(false)

	_depth = int(data.get("zone", {}).get("z", SURFACE_Z))
	_sky_grade.update(data.get("time", {}), _depth, _zone_center)   # day/night; uses last frame's zone centre
	_update_mode_label()   # refresh the ⏱ time label with the new time

	var z: Dictionary = data.get("zone", {})
	if z.has("width") and z.has("height"):
		_zone_center = Vector3(float(z["width"]) / 2.0, 0.0, float(z["height"]) / 2.0)
		_zone_dims = Vector2(float(z["width"]), float(z["height"]))

	# Read the player cell FIRST. An absent/invalid cell (a mid-teardown frame, or the
	# player briefly having no cell) reports (-1,-1) — hold the last good camera state and
	# ignore this frame entirely rather than re-anchoring the world off garbage coords.
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return
	var tile := Vector2i(px, py)
	var moved := _prev_tile.x > -9999 and tile != _prev_tile

	# Crossing a zone edge re-anchors the live zone to local coords, so the player's
	# (px,py) jumps discontinuously (e.g. 0 -> 79) and everything on screen shifts.
	# Shift the camera by the SAME amount (the two zones' global-origin difference) so
	# it stays locked on the same world content — a seamless continuous crossing, no
	# cut or sweep. Also don't read the coord jump as a step (it flipped `_facing`).
	#
	# GUARD — the shift only makes sense for a player who actually STEPPED over the edge:
	# a real crossing always jumps the local tile. If the zone id changes while the player
	# sits still (e.g. "become" swaps the body onto a stationary corpse and the reported
	# zone id flaps), applying the shift would yank the eye off a motionless player every
	# frame while the lerp scrolls it back — the reset-away / scroll-toward loop. So gate
	# the whole crossing on `moved`.
	var zid := String(z.get("id", ""))
	var old_zid := _prev_zone_id
	var crossed := moved and old_zid != "" and zid != old_zid
	_prev_zone_id = zid
	if crossed and store.has_zone(old_zid) and store.has_zone(zid):
		var oo: Vector3i = store.record(old_zid).get("origin", Vector3i.ZERO)
		var no: Vector3i = store.record(zid).get("origin", Vector3i.ZERO)
		# Shift the camera by the two zones' global-origin difference so it stays locked on the
		# same world content across the re-anchor — a seamless continuous crossing.
		_cam_rig.apply_cross_shift(Vector3(oo.x - no.x, 0.0, oo.y - no.y))
	elif crossed:
		print("[cross] SKIPPED shift: old=%s has=%s  new=%s has=%s" % [
			old_zid, store.has_zone(old_zid), zid, store.has_zone(zid)])

	# facing = the direction of the last actual step (a crossing's coord jump doesn't count), so the
	# camera trails behind. The rig applies it, tracks the player, and self-seeds on the first frame.
	var stepped := moved and not crossed
	var step_dir := Vector2(tile.x - _prev_tile.x, tile.y - _prev_tile.y) if stepped else Vector2.ZERO
	_prev_tile = tile
	_cam_rig.set_player(Vector3(px, 0, py), step_dir, stepped)

## Remembered zones to draw around the live one: every OTHER stored zone on the
## same stratum, offset by the difference of its global origin from the live zone's
## (in cells = world units). Cross-stratum stacking is Phase 2; a distance/eviction
## radius is Phase 1's freeze-unfreeze step — for now the store holds few zones.
func _neighbor_zones() -> Array:
	var out: Array = []
	# 2D mode floors EVERY object in EVERY cell, so a full surface zone plus its remembered
	# neighbours is far more geometry than the 3D path (walls are greedy-meshed there, most cells
	# hold nothing to floor). Rebuilding all of them flat in one re-render blew past the GPU timeout
	# and hung on the surface (the overworld is a single zone, so it never hit this). Render just the
	# live zone flat; neighbour context returns in 3D. (Incremental flat neighbours are a follow-up.)
	if _flat_2d:
		return out
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
		# Vertical stacking: keep same-stratum neighbours (dz==0, the horizontal
		# remembered zones) plus DEEPER levels (dz>0) up to LEVEL_KEEP_DOWN, which
		# _sync_neighbors offsets downward. Shallower levels (dz<0) are turned off —
		# they'd hang above as a terrain ceiling and occlude the current level.
		var dz: int = int(rec.get("stratum", -9999)) - live_z
		if dz < 0 or dz > LEVEL_KEEP_DOWN:
			continue
		var o: Vector3i = rec.get("origin", Vector3i.ZERO)
		# the player's position when this zone was last live (its final snapshot), so the
		# renderer can erase the sight-disc they carried out of it (see _build_darkness).
		var pl: Dictionary = rec.get("snapshot", {}).get("player", {})
		out.append({
			"id": id,
			"cells": rec.get("snapshot", {}).get("cells", []),
			"offset": Vector2i(o.x - live_origin.x, o.y - live_origin.y),
			"dz": dz,
			"px": int(pl.get("x", -9999)),
			"py": int(pl.get("y", -9999)),
		})
	return out

# --- remote control (for automated dev loops) -------------------------------
# Claude can't send keys to Godot, only commands to Qud's bridge. So Godot polls a
# small command file: control.py writes lines, we execute + delete. Lets an external
# driver trigger Godot-side actions (screenshot, switch camera) to close the loop.
## The RavesOfQud data dir. Prefer the renderer's tiles dir (proven correct once a
## turn has been taken), but fall back to the OS support dir so the command channel +
## screenshots work BEFORE Qud connects — e.g. to photograph the onboarding UI cold.
func _support_dir() -> String:
	if renderer != null:
		var b := renderer.tiles_dir().get_base_dir()
		if b != "":
			return b
	return InputModel.support_dir()

var _cmd_accum := 0.0
func _poll_godot_cmd(dt: float) -> void:
	_cmd_accum += dt
	if _cmd_accum < 0.1:
		return
	_cmd_accum = 0.0
	var base := _support_dir()
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
		"mv":
			_multiview.toggle()   # all-views grid (same as the 0 key / the ` menu button)
		"fph":
			if parts.size() > 1:
				_cam_rig._fp_height = clampf(float(parts[1]), 0.15, 3.0)
		"onboard":
			# `onboard` opens the chooser; `onboard <screen>` jumps to a screen
			# (devices/ktype/layout/numpad/mouse); `onboard close` dismisses it.
			if parts.size() > 1 and parts[1] == "close":
				onboarding.close()
			elif parts.size() > 1:
				onboarding.show_screen(parts[1])
			else:
				onboarding.open()

var _bg_draw_accum := 0.0
const BG_DRAW_INTERVAL := 0.05   # ~20fps forced draws while unfocused

func _process(dt: float) -> void:
	_poll_godot_cmd(dt)
	if _picking:
		_update_pick_cursor()
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

	# Camera modes, held-key zoom/fly, placement, and wall cutaway all live in the rig now.
	_cam_rig.process(dt, _multiview.is_on())
	if _multiview.is_on():
		_multiview.update()

## Move the player relative to the camera. `intent` is (strafe, forward) in screen
## space: (0,1)=forward, (0,-1)=back, (1,0)=right, (-1,0)=left.
func _move_relative(intent: Vector2) -> void:
	var h: Vector3 = _cam_rig.camera_heading()
	var right := h.cross(Vector3.UP)   # camera/body right (world space)
	if right.length() < 0.001:
		right = Vector3(1, 0, 0)
	right = right.normalized()
	var v := h * intent.y + right * intent.x
	if v.length() < 0.001:
		return
	client.send_command("move", {"dir": _cam_rig.dir_to_compass(v.normalized())})

## Send a named Qud command (CmdFire, CmdReload, …) over the bridge — from a Raves hotkey or a UI
## button. The mod injects it into Qud's input like a keypress, so any targeting UI opens in the Qud
## window. No-op until the bridge is up.
func request_command(cmd: String) -> void:
	if client != null:
		client.send_command("command", {"command": cmd})

## Invoke an inventory action (e.g. ReplaceSocketCell — "change the battery") on a specific equipped
## weapon, identified by its Qud GameObject id. Runs on Qud's main thread mod-side.
func request_item_action(item_id: String, action: String) -> void:
	if client != null:
		client.send_command("itemaction", {"item": item_id, "command": action})

# --- direction picker (for abilities like Make Camp that prompt for a direction) ----------------
# Qud's PickDirection blocks the turn thread waiting for a LeftClick at a CELL (it derives the
# direction). We show the ability's icon as a cursor over the Holodeck; clicking an adjacent tile
# sends that cell (mod injects the click), a non-adjacent click / right-click / Esc cancels (mod
# injects a RightClick so Qud UNBLOCKS). Only started for abilities that actually prompt, else Qud
# would freeze waiting.
var _picking := false
var _pick_layer: CanvasLayer
var _pick_icon: TextureRect
var _pick_x: Label
var _pick_hint: Label

func start_direction_picker(icon: Texture2D) -> void:
	if _pick_layer == null:
		_pick_layer = CanvasLayer.new()
		_pick_layer.layer = 50   # above the frame chrome
		add_child(_pick_layer)
		_pick_icon = TextureRect.new()
		_pick_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_pick_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_pick_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_icon.size = Vector2(64, 96)   # full-size, to sit on the tile
		_pick_layer.add_child(_pick_icon)
		_pick_x = Label.new()
		_pick_x.text = "✗"
		_pick_x.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		_pick_x.add_theme_font_size_override("font_size", 44)
		_pick_x.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_layer.add_child(_pick_x)
		_pick_hint = Label.new()
		_pick_hint.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
		_pick_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		_pick_hint.position = Vector2(16, 8)
		_pick_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_layer.add_child(_pick_hint)
	_pick_icon.texture = icon
	_pick_hint.text = "Pick a direction — click an adjacent tile   (right-click / Esc to cancel)"
	_picking = true
	_pick_layer.visible = true

## The zone cell under a screen point, via a ray to the ground plane (accounts for the top-down
## Z-stretch). Returns a sentinel when it can't resolve.
func _pick_cell(mp: Vector2) -> Vector2i:
	if _cam_rig._cam == null:
		return Vector2i(-9999, -9999)
	var o: Vector3 = _cam_rig._cam.project_ray_origin(mp)
	var d: Vector3 = _cam_rig._cam.project_ray_normal(mp)
	if absf(d.y) < 0.0001:
		return Vector2i(-9999, -9999)
	var t := -o.y / d.y
	if t <= 0.0:
		return Vector2i(-9999, -9999)
	var hit := o + d * t
	var zs: float = _cam_rig.zstretch()
	return Vector2i(int(round(hit.x)), int(round(hit.z / maxf(zs, 0.001))))

func _player_cell() -> Vector2i:
	return Vector2i(int(round(_cam_rig._player.x)), int(round(_cam_rig._player.z)))

## Valid = one of the 8 tiles AROUND the player (not the player's own tile, not further). Those are the
## tiles the picker snaps to; everything else is the freeform "✗".
func _pick_is_adjacent(c: Vector2i) -> bool:
	if c.x < -9000:
		return false
	var p := _player_cell()
	var dx := c.x - p.x
	var dy := c.y - p.y
	return (dx != 0 or dy != 0) and maxi(absi(dx), absi(dy)) == 1

## Screen position of a cell's ground point (accounts for the top-down Z-stretch).
func _cell_screen_pos(c: Vector2i) -> Vector2:
	if _cam_rig._cam == null:
		return get_viewport().get_mouse_position()
	return _cam_rig._cam.unproject_position(Vector3(c.x, 0.0, c.y * _cam_rig.zstretch()))

func _update_pick_cursor() -> void:
	if not _picking or _pick_icon == null:
		return
	var mp := get_viewport().get_mouse_position()
	var c := _pick_cell(mp)
	if _pick_is_adjacent(c):
		# SNAP the icon onto the adjacent tile at FULL (tile) size: project the cell's ground point and a
		# point one tile-sprite tall (16x24 -> 1.5 world units) above it; the pixel gap is the on-screen
		# tile height, so the icon matches the rendered tiles at any zoom. Stands on the tile.
		var zs: float = _cam_rig.zstretch()
		var base: Vector2 = _cam_rig._cam.unproject_position(Vector3(c.x, 0.0, c.y * zs))
		var top: Vector2 = _cam_rig._cam.unproject_position(Vector3(c.x, 1.5, c.y * zs))
		var ph := maxf(28.0, absf(base.y - top.y))
		_pick_icon.size = Vector2(round(ph * 16.0 / 24.0), round(ph))
		_pick_icon.position = Vector2(base.x - _pick_icon.size.x / 2.0, base.y - _pick_icon.size.y)
		_pick_icon.visible = true
		_pick_x.visible = false
	else:
		# Outside the valid ring: the ✗ follows the mouse freeform.
		_pick_x.position = mp - Vector2(14, 28)
		_pick_x.visible = true
		_pick_icon.visible = false

func _end_pick() -> void:
	_picking = false
	if _pick_layer != null:
		_pick_layer.visible = false

func _cancel_pick() -> void:
	if client != null:
		client.send_command("dircancel", {})   # unblock Qud's prompt
	_end_pick()

## Handle input while the direction picker is up. Returns true if the event was consumed.
func _handle_pick_input(event: InputEvent) -> bool:
	if not _picking:
		return false
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var c := _pick_cell(event.position)
			if _pick_is_adjacent(c) and client != null:
				client.send_command("dir", {"x": str(c.x), "y": str(c.y)})
				_end_pick()
			else:
				_cancel_pick()   # clicked out of range -> cancel so Qud doesn't stay blocked
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_pick()
			return true
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_pick()
		return true
	# swallow other input while picking, so a stray key can't move/act mid-prompt
	if event is InputEventKey and event.pressed and not event.echo:
		return true
	return false

func _set_mode(m: int) -> void:
	if _multiview.is_on():
		_multiview.toggle()   # picking a mode leaves the multi-view grid
	# The rig does the camera part (state reset, billboard lay-down, zstretch) and reports if it changed.
	if _cam_rig.set_mode(m):
		_update_mode_label()
		_refresh_wm_cards_btn()   # keep the 2D/3D button label in sync

## One gesture -> everything a collaborator needs about a tile. Photograph the BARE
## scene FIRST (no selection overlay), then inspect — so shot.png is a clean plate
## of the tile, paired with the report (selection.txt) and Qud's view (qud_shot.png).
func _inspect_and_capture() -> void:
	await _screenshot(true)
	_inspect()

## Clear everything a selection put on screen: report form, inspector panel, marker.
## Bound to Esc and to the form's Cancel button.
func _dismiss_selection() -> void:
	inspector.hide_panel()
	reporter.hide_panel()

## Inspect, and aim the report form at the same tile.
func _inspect() -> void:
	inspector.inspect_at(_cam_rig._cam, get_viewport().get_mouse_position(), _cam_rig.zstretch())
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
	var dir := _support_dir()
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
	_mode_label.add_theme_font_size_override("font_size", UiFont.px(get_viewport()))  # _apply_ui_fonts keeps it live
	_mode_label.add_theme_color_override("font_color", Color(0.75, 0.9, 0.75))
	layer.add_child(_mode_label)
	_update_mode_label()

const _MODE_NAMES := {
	CamMode.COMPASS: "COMPASS — cardinal-locked · arrows move (↑=fwd) · Q/E rotate · R/F zoom · S/D height · W/X dolly",
	CamMode.FOLLOW: "FOLLOW — trails your heading · arrows move (↑=fwd) · R/F zoom · S/D height · W/X dolly",
	CamMode.FIRST_PERSON: "FIRST-PERSON — ↑↓ move · ←→ turn · Ctrl+Shift+←→ strafe · Shift+arrows diagonal",
	CamMode.CINEMATIC: "CINEMATIC — frames you + selected tile",
	CamMode.MOUSE: "ORBIT — drag around the selected tile",
	CamMode.KEYBOARD: "FLY — WASD move, arrows aim",
	CamMode.TOP_FOLLOW: "TOP-DOWN FOLLOW — classic overhead · north up · tracks you · R/F zoom",
}

func _update_mode_label() -> void:
	_mode_label.text = "camera: %s     ·  ` menu · 1-7 · 0 all-views · F1 controls" % _MODE_NAMES.get(_cam_rig._mode, "?")
	if _sky_grade != null and _sky_grade.time_label != "":
		_mode_label.text += "     ⏱ " + _sky_grade.time_label
	_update_debug_menu()

# --- debug menu -------------------------------------------------------------

var _debug_menu: PanelContainer
var _mode_buttons := {}

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
	mvb.pressed.connect(_multiview.toggle)
	vb.add_child(mvb)
	# first-person eye-height slider
	var hl := Label.new()
	hl.text = "first-person height"
	vb.add_child(hl)
	var sld := HSlider.new()
	sld.min_value = 0.15
	sld.max_value = 3.0
	sld.step = 0.05
	sld.value = _cam_rig._fp_height
	sld.custom_minimum_size = Vector2(160, 0)
	sld.focus_mode = Control.FOCUS_NONE   # drag-only; keep arrows for the player
	sld.value_changed.connect(func(v): _cam_rig._fp_height = v)
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
	# level height: vertical gap between stacked Z-levels (0 = coplanar)
	var ll := Label.new()
	ll.text = "level height (Z gap)"
	vb.add_child(ll)
	var lsld := HSlider.new()
	lsld.min_value = 0.0
	lsld.max_value = 16.0
	lsld.step = 0.5
	lsld.value = renderer.level_height
	lsld.custom_minimum_size = Vector2(160, 0)
	lsld.focus_mode = Control.FOCUS_NONE
	lsld.value_changed.connect(_on_level_height_changed)
	vb.add_child(lsld)
	# COMPASS Q/E rotation step: 45° (8-way) or 90° (cardinal)
	_compass_step_btn = Button.new()
	_compass_step_btn.focus_mode = Control.FOCUS_NONE
	_compass_step_btn.pressed.connect(_toggle_compass_step)
	vb.add_child(_compass_step_btn)
	_refresh_compass_step_btn()
	# camera look target: the head or the waist
	_look_btn = Button.new()
	_look_btn.focus_mode = Control.FOCUS_NONE
	_look_btn.pressed.connect(_toggle_look_target)
	vb.add_child(_look_btn)
	_refresh_look_btn()
	# font-size ruler (Lorem Ipsum at each px) — for tuning UiFont.FRAC / UiFont.MIN. Key: L.
	var fp_btn := Button.new()
	fp_btn.text = "Font-size ruler (L)"
	fp_btn.focus_mode = Control.FOCUS_NONE
	fp_btn.pressed.connect(_toggle_font_preview)
	vb.add_child(fp_btn)
	# 2D/3D: lay the whole world flat (classic 2D map) or stand it up as billboards. Key: O.
	_wm_face_btn = Button.new()
	_wm_face_btn.focus_mode = Control.FOCUS_NONE
	_wm_face_btn.pressed.connect(_toggle_flat_2d)
	vb.add_child(_wm_face_btn)
	_refresh_wm_face_btn()
	_debug_menu = panel
	_update_debug_menu()

var _compass_step_btn: Button
var _look_btn: Button
var _wm_face_btn: Button
var _flat_2d := false   # false = 3D upright billboards, true = everything flat on the floor (2D map)

func _refresh_compass_step_btn() -> void:
	if _compass_step_btn != null:
		_compass_step_btn.text = "Q/E rotate: %s" % ("45°" if _cam_rig._compass_45 else "90°")

func _refresh_look_btn() -> void:
	if _look_btn != null:
		_look_btn.text = "camera follows: %s" % ("head" if _cam_rig._look_head else "waist")

func _refresh_wm_face_btn() -> void:
	if _wm_face_btn != null:
		_wm_face_btn.text = "tiles (O): %s" % ("2D flat" if _flat_2d else "3D billboards")

## Flip the WHOLE world — every stratum — between 3D (upright billboards + wall blocks) and 2D
## (everything laid flat on the floor, a classic top-down map). The renderer drops its frozen
## geometry, so re-render the current snapshot to rebuild the live zone (and neighbours) in the new
## mode — instant feedback instead of waiting for the next turn.
func _toggle_flat_2d() -> void:
	_flat_2d = not _flat_2d
	renderer.set_flat_2d(_flat_2d)
	var live: Dictionary = store.live_snapshot()
	if not live.is_empty():
		renderer.render_snapshot(live, _neighbor_zones())
	_refresh_wm_face_btn()
	_refresh_wm_cards_btn()

## Label for the persistent top-right button — the current tile mode (3D up vs 2D flat).
func _refresh_wm_cards_btn() -> void:
	if _wm_cards_btn == null:
		return
	_wm_cards_btn.text = "tiles (O): %s" % ("2D flat" if _flat_2d else "3D up")

func _toggle_look_target() -> void:
	_cam_rig._look_head = not _cam_rig._look_head
	_refresh_look_btn()

func _toggle_compass_step() -> void:
	_cam_rig._compass_45 = not _cam_rig._compass_45
	_refresh_compass_step_btn()

## Live-apply the deep-water depth: creatures are re-cropped in the dynamic pass, so
## re-render the current snapshot (same zone -> only the cheap dynamics rebuild) for
## instant feedback instead of waiting for the next turn.
func _on_water_depth_changed(v: float) -> void:
	renderer.deep_water_depth = v
	var live: Dictionary = store.live_snapshot()
	if not live.is_empty():
		renderer.render_snapshot(live, _neighbor_zones())

## Live-apply the level gap: only neighbour subtree positions change, so a re-render
## just repositions the already-built stacks (no rebuild) — instant feedback.
func _on_level_height_changed(v: float) -> void:
	renderer.level_height = v
	var live: Dictionary = store.live_snapshot()
	if not live.is_empty():
		renderer.render_snapshot(live, _neighbor_zones())

## Top-right corner buttons, stacked in a VBox so they never overlap at any font size:
##   ⟳ Reset            — restarts the whole program (picks up code changes) at the current size
##   WM cards (O)       — the world-map card orientation toggle, with its live state on the label
func _build_reset_button() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	# A VBox pinned to the top-right corner (grow LEFT to fit the widest label, DOWN to stack).
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_END
	box.offset_left = -10.0
	box.offset_right = -10.0
	box.offset_top = 10.0
	box.add_theme_constant_override("separation", 6)
	layer.add_child(box)

	_reset_btn = Button.new()
	_reset_btn.text = "⟳ Reset"
	_reset_btn.focus_mode = Control.FOCUS_NONE   # click-only; keep arrows for the player
	_reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_END   # hug the right edge under the anchor
	_reset_btn.pressed.connect(_reset_program)
	box.add_child(_reset_btn)

	# The 2D/3D toggle, surfaced as a persistent button (not just the ` debug menu and the O key) so
	# its effect is discoverable — the label shows the current tile mode (3D up vs 2D flat).
	_wm_cards_btn = Button.new()
	_wm_cards_btn.focus_mode = Control.FOCUS_NONE
	_wm_cards_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_wm_cards_btn.pressed.connect(_toggle_flat_2d)
	box.add_child(_wm_cards_btn)
	_refresh_wm_cards_btn()

	_reset_btn.add_theme_font_size_override("font_size", UiFont.px(get_viewport()))
	_wm_cards_btn.add_theme_font_size_override("font_size", UiFont.px(get_viewport()))

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
		"mode": _cam_rig._mode,
		"compass_yaw": _cam_rig._compass_yaw,
		"compass_45": _cam_rig._compass_45,
		"look_head": _cam_rig._look_head,
		"dist": _cam_rig._dist,
		"top_zoom": _cam_rig._top_zoom,
		"fp_height": _cam_rig._fp_height,
		"water_depth": (renderer.deep_water_depth if renderer != null else 0.6),
		"level_height": (renderer.level_height if renderer != null else 4.0),
		"win": [sz.x, sz.y],
	}
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()

## Restore what _save_settings wrote. Sets values only (no _set_mode — the label isn't
## built yet); the mode's camera/renderer setup follows from the rig's _mode in its _update_camera and
## the set_top_down call here. Missing/invalid keys keep the code defaults.
func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(d) != TYPE_DICTIONARY:
		return
	_cam_rig._compass_yaw = float(d.get("compass_yaw", _cam_rig._compass_yaw))
	_cam_rig._compass_45 = bool(d.get("compass_45", _cam_rig._compass_45))
	_cam_rig._look_head = bool(d.get("look_head", _cam_rig._look_head))
	_cam_rig._dist = clampf(float(d.get("dist", _cam_rig._dist)), _cam_rig.DIST_MIN, _cam_rig.DIST_MAX)
	_cam_rig._top_zoom = clampf(float(d.get("top_zoom", _cam_rig._top_zoom)), _cam_rig.TOP_ZOOM_MIN, _cam_rig.TOP_ZOOM_MAX)
	_cam_rig._fp_height = clampf(float(d.get("fp_height", _cam_rig._fp_height)), 0.15, 3.0)
	if renderer != null:
		renderer.deep_water_depth = clampf(float(d.get("water_depth", renderer.deep_water_depth)), 0.0, 1.0)
		renderer.level_height = clampf(float(d.get("level_height", renderer.level_height)), 0.0, 16.0)
	var win = d.get("win", null)
	if win is Array and win.size() == 2 and int(win[0]) > 200 and int(win[1]) > 200:
		DisplayServer.window_set_size(Vector2i(int(win[0]), int(win[1])))
	var m := int(d.get("mode", _cam_rig._mode))
	if m >= 0 and m <= CamMode.TOP_FOLLOW:
		_cam_rig._mode = m
		if renderer != null:
			renderer.set_top_down(m == CamMode.TOP_FOLLOW)

func _toggle_debug_menu() -> void:
	if _debug_menu != null:
		_debug_menu.visible = not _debug_menu.visible

func _update_debug_menu() -> void:
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).modulate = Color(0.55, 1.0, 0.55) if m == _cam_rig._mode else Color(1, 1, 1)

# --- input ------------------------------------------------------------------

## Direction-picker input is handled in _input (BEFORE the GUI), because the frame's container Controls
## consume mouse clicks over the Holodeck before they'd reach _unhandled_input. Only consumes while
## picking; otherwise events flow to the GUI / _unhandled_input as normal.
func _input(event: InputEvent) -> void:
	if _picking and _handle_pick_input(event):
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# Shift+Space: wait a turn in Qud (a Godot->Qud passthrough). Takes a turn for now.
		if event.shift_pressed and event.keycode == KEY_SPACE:
			client.send_command("wait", {}); return
		# F1 opens the controls chooser. (While it's open it swallows input via its
		# own _input, so this handler won't see keys until it closes.)
		if event.keycode == KEY_F1:
			onboarding.open(); return
		# mode switches first — they reassign what the arrows mean
		if event.shift_pressed and event.keycode == KEY_C:
			_set_mode(CamMode.MOUSE); return
		if event.shift_pressed and event.keycode == KEY_K:
			_set_mode(CamMode.KEYBOARD); return
		if event.shift_pressed and event.keycode == KEY_F:
			_set_mode(CamMode.FOLLOW); return
		# Plain F = FIRE (forwarded to Qud), NOT a camera key. Qud runs its own fire/targeting flow.
		# (Temporary Raves keybinds are being retired; Qud's own controls arrive next.)
		if event.keycode == KEY_F and not event.shift_pressed \
				and not (event.ctrl_pressed or event.meta_pressed or event.alt_pressed):
			request_command("CmdFire"); return
		# camera modes by number (mirrored in the ` debug menu)
		if event.keycode == KEY_1: _set_mode(CamMode.COMPASS); return
		if event.keycode == KEY_2: _set_mode(CamMode.FOLLOW); return
		if event.keycode == KEY_3: _set_mode(CamMode.FIRST_PERSON); return
		if event.keycode == KEY_4: _set_mode(CamMode.CINEMATIC); return
		if event.keycode == KEY_5: _set_mode(CamMode.MOUSE); return
		if event.keycode == KEY_6: _set_mode(CamMode.KEYBOARD); return
		if event.keycode == KEY_7: _set_mode(CamMode.TOP_FOLLOW); return
		if event.keycode == KEY_0: _multiview.toggle(); return   # 0 = all-views grid
		if event.keycode == KEY_QUOTELEFT:      # ` toggles the debug menu
			_toggle_debug_menu(); return
		# B: "become anything" character-creator menu (pick a blueprint to embody)
		if event.keycode == KEY_B and not event.shift_pressed \
				and not (event.ctrl_pressed or event.meta_pressed):
			_char_creator.toggle(renderer.tiles_dir().get_base_dir()); return
		# O: flip the whole world 3D (billboards) <-> 2D (flat on the floor). (Was B; moved off B
		# when the character-creator merge took B for "become".)
		if event.keycode == KEY_O:
			_toggle_flat_2d(); return
		# Q/E rotate the locked compass heading (COMPASS mode only), 45° or 90° per _compass_45
		if _cam_rig._mode == CamMode.COMPASS and event.keycode == KEY_Q:
			_cam_rig._compass_yaw += _cam_rig.compass_step(); return
		if _cam_rig._mode == CamMode.COMPASS and event.keycode == KEY_E:
			_cam_rig._compass_yaw -= _cam_rig.compass_step(); return
		# W / X dolly the camera one tile forward / back along its heading — move the
		# camera like the player. Discrete per press; pairs with S/D vertical pan. Not
		# in FLY (WASD drives the free camera there).
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_W:
			_cam_rig._cam_pan += _cam_rig.cam_forward() * _cam_rig.CAM_STEP; return
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_X:
			_cam_rig._cam_pan -= _cam_rig.cam_forward() * _cam_rig.CAM_STEP; return
		# S / D are forwarded to Qud as key presses (was: camera vertical pan). The mod injects
		# them through Qud's keymap, so they trigger whatever YOU'VE bound s/d to (soar/descend) —
		# drive the surface<->world-map transition from Raves without switching focus. One per
		# press. Skipped in FLY (KEYBOARD) mode, where WASD still flies the free camera.
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_S:
			client.send_command("key", {"key": "s"}); return
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_D:
			client.send_command("key", {"key": "d"}); return
		if event.keycode == KEY_ESCAPE:
			# close the camera/debug menu and any selection, but KEEP the current camera
			_dismiss_selection()
			if _debug_menu != null:
				_debug_menu.visible = false
			if _char_creator != null:
				_char_creator.visible = false
			return
		if event.keycode == KEY_I:
			_inspect(); return
		if event.keycode == KEY_L:
			_toggle_font_preview(); return   # L: font-size ruler (Lorem Ipsum at each px)
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
		if _cam_rig._mode == CamMode.KEYBOARD:
			return
		# Arrows move the PLAYER relative to the camera heading — "up" is always forward on
		# screen (the Godot->Qud translation). SHIFT+arrow = that direction rotated 45° to the
		# DIAGONAL (Up=NE, Right=SE, Down=SW, Left=NW). FIRST-PERSON turns in place on plain
		# L/R; Ctrl/Cmd+Shift+L/R strafes there. Numpad is the ABSOLUTE 8-way fallback.
		var mod: bool = event.ctrl_pressed or event.meta_pressed
		var diag: bool = event.shift_pressed and not mod    # Shift alone -> diagonal move
		var strafe_mod: bool = event.shift_pressed and mod  # Ctrl/Cmd+Shift -> strafe (first-person)
		match event.keycode:
			KEY_UP:    _move_relative(Vector2(1, 1) if diag else Vector2(0, 1))      # NE / forward
			KEY_DOWN:  _move_relative(Vector2(-1, -1) if diag else Vector2(0, -1))   # SW / back
			KEY_LEFT:
				if diag:
					_move_relative(Vector2(-1, 1))       # NW diagonal
				elif _cam_rig._mode == CamMode.FIRST_PERSON and not strafe_mod:
					_cam_rig._compass_yaw += PI * 0.25            # turn left 45°
				else:
					_move_relative(Vector2(-1, 0))       # strafe left (non-FP, or FP Ctrl+Shift)
			KEY_RIGHT:
				if diag:
					_move_relative(Vector2(1, -1))       # SE diagonal
				elif _cam_rig._mode == CamMode.FIRST_PERSON and not strafe_mod:
					_cam_rig._compass_yaw -= PI * 0.25            # turn right 45°
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
					_cam_rig._orbiting = event.pressed and _cam_rig._mode == CamMode.MOUSE
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				# Ctrl/Cmd + right-click = inspect AND photograph both apps, so a
				# single gesture hands over coordinates, wire data and the picture.
				if (event.pressed and event.button_index == MOUSE_BUTTON_RIGHT
						and (event.ctrl_pressed or event.meta_pressed)):
					_inspect_and_capture()
				else:
					_cam_rig._panning = event.pressed and _cam_rig._mode == CamMode.MOUSE
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					if _cam_rig._mode == CamMode.TOP_FOLLOW:
						_cam_rig._top_zoom = clampf(_cam_rig._top_zoom * 0.9, _cam_rig.TOP_ZOOM_MIN, _cam_rig.TOP_ZOOM_MAX)
					else:
						_cam_rig._dist = clampf(_cam_rig._dist * 0.9, _cam_rig.DIST_MIN, _cam_rig.DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					if _cam_rig._mode == CamMode.TOP_FOLLOW:
						_cam_rig._top_zoom = clampf(_cam_rig._top_zoom * 1.1, _cam_rig.TOP_ZOOM_MIN, _cam_rig.TOP_ZOOM_MAX)
					else:
						_cam_rig._dist = clampf(_cam_rig._dist * 1.1, _cam_rig.DIST_MIN, _cam_rig.DIST_MAX)
	elif event is InputEventMouseMotion:
		if _cam_rig._orbiting:
			_cam_rig._yaw += event.relative.x * _cam_rig.ORBIT_SENS
			_cam_rig._pitch = clampf(_cam_rig._pitch + event.relative.y * _cam_rig.ORBIT_SENS, _cam_rig.PITCH_MIN, _cam_rig.PITCH_MAX)
		elif _cam_rig._panning:
			# pan along the ground plane, scaled by zoom so it feels constant
			var right: Vector3 = _cam_rig._cam.global_transform.basis.x
			var fwd: Vector3 = -_cam_rig._cam.global_transform.basis.z
			right.y = 0.0; fwd.y = 0.0
			right = right.normalized(); fwd = fwd.normalized()
			var speed: float = _cam_rig._dist * 0.0016
			# grab-the-world: drag right moves the world right (camera goes left)
			_cam_rig._pan += (-right * event.relative.x - fwd * event.relative.y) * speed

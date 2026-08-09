extends Node3D

## Emitted every snapshot with the raw Qud data, so a host (MainFrame) can drive its status bar /
## panels off the same stream the Holodeck renders — no second bridge connection needed.
signal snapshot(data: Dictionary)
## Re-broadcast of PopupOverlay.closed so the frame's screens can refresh (see
## StatusScreens._refresh_after_popup).
signal popup_closed
signal popup_option(text: String)   # a mirrored menu popup's picked option (plain text)

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
var _wish_layer: CanvasLayer    # Ctrl+Shift+W wish prompt overlay (built lazily), sends "wish" to Qud
var _wish_edit: LineEdit
var _popup: PopupOverlay        # mirrors Qud modal popups forwarded by the mod (own file)
var _item_picker: PickerOverlay # mirrors Qud's PickGameObjectScreen (empty-slot equip picker)
var overlay_check: Callable = Callable()   # MainFrame: "is a frame overlay (status/controlmap) open?"
# Click-to-travel: where the left button went down, and how far it may travel and still count as a
# click rather than a camera-orbit drag. 6 px is a hand tremor at the trackpad; an orbit is tens.
var _travel_press = null        # Vector2 while the button is down, else null
const TRAVEL_SLOP := 6.0
var _binds := QudBinds.new()    # the player's Qud keybindings — custom-remap fallback routing
var _palette := QudPalette.markup()   # Qud colour map (code -> hex) for popup markup.
                                # Seeded from the canonical table, then replaced by the
                                # live one on the first snapshot -- see QudPalette.markup().
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
var _remote                     # RemoteControl (RefCounted); the godot_cmd file channel. Created in _ready.

# Remembered view/render settings, saved on exit and restored on launch (so Raves doesn't
# reset to "looking south" every run). In user:// — available at startup, before the mod
# sends the support-dir path.
const SETTINGS_PATH := "user://raves_settings.json"

var _zone_center := Vector3(40, 0, 12)
var _zone_dims := Vector2(80, 25)   # live zone width x height in cells
var _prev_tile := Vector2i(-9999, -9999)
var _prev_zone_id := ""          # to detect zone crossings (shift the camera to stay continuous)
var _mode_label: Label
var _dbg_menu                   # DebugMenu (Node, loaded); the ` panel. Created in _ready.
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
var _ui_right_inset := 0.0   # 1:1: fraction of the window the side panels cover; recentres the cam (MainFrame pushes it)

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
	# Re-assert the 1:1 (parity) camera span on any window resize — a resize otherwise reverts the
	# top-down ortho span toward user-mode framing, which breaks the 1:1 match at a fixed size.
	if _one_to_one and render_3d and _cam_rig != null:
		_cam_rig.set_one_to_one(true)
		_cam_rig.set_right_inset(_ui_right_inset)   # the inset is a fraction of the window — track resizes
	UiFont.refresh_theme(_ui_theme, get_viewport())   # keep the project-wide default in sync with the window
	_stamp_theme_roots(get_tree().root)               # make the default theme cross CanvasLayer boundaries
	var fs := _ui_font_size()
	if _mode_label != null:
		_mode_label.add_theme_font_size_override("font_size", fs)
	var dbg_panel: Control = _dbg_menu.panel() if _dbg_menu != null else null
	if dbg_panel != null:
		_apply_font_recursive(dbg_panel, fs)
	if _reset_btn != null:
		_reset_btn.add_theme_font_size_override("font_size", fs)
	if _wm_cards_btn != null:
		_wm_cards_btn.add_theme_font_size_override("font_size", fs)
	# keep the debug menu just BELOW the help label so they never overlap, even as
	# the responsive font grows the label's height
	if dbg_panel != null and _mode_label != null:
		var lh: float = maxf(_mode_label.get_minimum_size().y, float(fs))
		dbg_panel.position = Vector2(14, _mode_label.position.y + lh + 8.0)

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
	client.popup.connect(_on_popup)
	client.qud_view.connect(func(v: String) -> void: qud_view_changed.emit(v))
	client.picker.connect(_on_picker)
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

	# Remote-command channel (the godot_cmd file poller for control.py). Driven from _process; the dispatch
	# (_exec_godot_cmd) stays here since each command drives a Main subsystem.
	_remote = load("res://RemoteControl.gd").new()
	_remote.setup(_support_dir, _exec_godot_cmd)

	# Direction picker (ability-prompt cursor, its own file). Driven from _process/_input.
	_picker = load("res://DirectionPicker.gd").new()
	add_child(_picker)
	_picker.setup(_cam_rig, client)

	_binds.setup(_support_dir())   # custom-keybind fallback map (reloads on export change)

	# Popup overlay (its own file): mirrors Qud modals (message / yes-no / option list / text prompt)
	# forwarded by the mod, and ships the viewer's answer back so Qud's blocked turn thread unblocks.
	_popup = PopupOverlay.new()
	add_child(_popup)
	_popup.closed.connect(func(): popup_closed.emit())
	_popup.answered.connect(func(payload: Dictionary):
		client.send_command("popup", payload)
		if str(payload.get("action", "")) == "option":
			popup_option.emit(str(payload.get("text", ""))))

	# Item picker (its own file): Qud's PickGameObjectScreen — what an EMPTY paper-doll slot
	# raises. It is a screen, not a PopupMessage, so it arrives on its own channel.
	_item_picker = PickerOverlay.new()
	add_child(_item_picker)
	_item_picker.closed.connect(func(): popup_closed.emit())
	_item_picker.answered.connect(func(payload: Dictionary):
		client.send_command("picker", payload))

	_load_settings()   # restore camera heading/mode/zoom/depth/window before the UI reads them
	_build_mode_label()
	# The ` debug menu (its own file). It reaches Main actions through these callbacks; _toggle_flat_2d
	# stays here (the O key + persistent button share it), and it mirrors the flat state back via refresh_flat_2d.
	_dbg_menu = load("res://DebugMenu.gd").new()
	add_child(_dbg_menu)
	_dbg_menu.build(_cam_rig, renderer, _multiview, _MODE_NAMES, {
		"set_mode": _set_mode,
		"toggle_flat_2d": _toggle_flat_2d,
		"font_ruler": _toggle_font_preview,
		"water_changed": _on_water_depth_changed,
		"level_changed": _on_level_height_changed,
	})
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
		if _one_to_one:
			_cam_rig.set_one_to_one(true)         # robust: 1:1 span even if already TOP_FOLLOW
			_cam_rig.set_right_inset(_ui_right_inset)   # recentre the view in the play hole
			_set_mode(CamMode.TOP_FOLLOW, true)   # enter the 1:1 camera as the viewport comes up
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

## Qud's per-cell sprite flip (PartyFlip) is render-context state, so the mod can't read it stably for
## the player's CELL object — but the separate `player` block reads it reliably. Copy that flip onto the
## player's own cell creature so the renderer (flip_h = obj.hflip) faces the playfield player like Qud.
func _inject_player_facing(data: Dictionary) -> void:
	var pl: Dictionary = data.get("player", {})
	if not pl.has("hflip"):
		return
	var px := int(pl.get("x", -9999))
	var py := int(pl.get("y", -9999))
	for cell in data.get("cells", []):
		if int(cell.get("x", -2)) == px and int(cell.get("y", -2)) == py:
			for obj in cell.get("objs", []):
				if bool(obj.get("creature", false)):
					obj["hflip"] = pl.get("hflip")
			return

## A Qud modal (message / yes-no / option list / text prompt) mirrored by the mod. During a popup the turn
## thread is blocked, so NO snapshots arrive — this is the only channel that tells us it opened. The overlay
## is modal (eats input) until the viewer answers, which ships a "popup" command back to unblock Qud.
func _on_popup(data: Dictionary) -> void:
	if _popup == null:
		return
	if bool(data.get("active", false)):
		_popup.show_popup(data, _palette)
	else:
		_popup.hide_popup()

## Qud's item picker, mirrored. Same blocking story as a popup — the turn thread is parked inside
## PickGameObjectScreen.show(), so this channel is the only word we get that it opened. The viewer's
## row choice goes back as a "picker" command and Qud's own HandleSelectItem applies it.
func _on_picker(data: Dictionary) -> void:
	if _item_picker == null:
		return
	if bool(data.get("active", false)):
		_item_picker.show_picker(data, _palette)
	else:
		_item_picker.hide_picker()

func _on_snapshot(data: Dictionary) -> void:
	# Data-freshness beacon for the test rig: the UI heartbeat proves the
	# VIEWER is alive, not that the WIRE is — a dropped bridge connection
	# left stale zones (and stale dynamic creatures) on screen through a
	# certification band while raves_state.json read perfectly healthy.
	UiState.note_snapshot()
	# WORLD MAP is a distinct SCREEN, not a zone: Qud sends it as a negative
	# stratum (zone.z < 0 — the parasang overview ZoneRenderer already keys
	# _world_map off). Report it so the rig can tell "player is reading the
	# map" from "player is in a zone": they render in the same frame, so a
	# checker that only asks for in_game would happily pixel-score a world
	# map against a zone capture — the failure mode that poisoned a
	# certification band from the menus. MainFrame still owns the in_game
	# announcement; this only splits it while a snapshot says otherwise.
	# Same rule as ZoneRenderer._world_map — Qud's IsWorldMap(): a dotless ZoneID.
	var _zid := String((data.get("zone", {}) as Dictionary).get("id", ""))
	UiState.note_world_map(_zid != "" and not _zid.contains("."))
	# Cache the colour map so popup markup renders with the same palette. Do NOT
	# hide the popup here: ASYNC popups (ShowYesNoAsync / PickOptionAsync) never
	# block the turn thread, so snapshots keep flowing while they're up — the old
	# "snapshot == no popup" rule made the mirror FLICKER (show → snapshot-hide →
	# re-announce, forever). The watcher's active:false is the dismissal channel
	# (it force-rescans before declaring one), and a stranded overlay is always
	# escapable — Esc answers Cancel and hides locally.
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	# Route the render through the store: draw the live zone plus any remembered
	# neighbours (same stratum) the player has visited, placed by global offset.
	Profiler.add_us("server", int(data.get("serverUs", 0)))
	_inject_player_facing(data)   # the player's cell obj carries no reliable hflip; use the player block's
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
		_cam_rig.set_zone_cells(_zone_dims)   # 1:1 zone-fit tracks the live zone size

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

func _exec_godot_cmd(cmd: String) -> void:
	if cmd == "":
		return
	var parts := cmd.split(" ", false)
	match parts[0]:
		"shot":
			_screenshot(false, true)   # forced: window is unfocused, no auto-draw
		"census":
			# Rung 6a: dump the renderer's per-cell placement verdicts so the rig
			# can diff them against the wire's cells — "did we draw everything
			# the zone sent?" with no pixels, no calibration, no focus.
			var cs := FileAccess.open(_support_dir().path_join("census.json"), FileAccess.WRITE)
			if cs != null:
				var payload := {}
				if renderer != null:
					payload = {
						"zone": _prev_zone_id,
						"cells": renderer.placement_census(),
					}
				cs.store_string(JSON.stringify(payload))
				cs.close()
		"uidump":
			# dump the frame's bottom-row widget rects — who is taller than the 90px budget?
			var fr := get_parent()
			if fr != null and fr.get("_effects") != null:
				var ud := FileAccess.open(_support_dir().path_join("uidump.json"), FileAccess.WRITE)
				if ud != null:
					var d := {}
					for k in ["_effects", "_target", "_context", "_command", "_row_split", "_side", "_msglog"]:
						var n: Control = fr.get(k)
						if n != null:
							var r := n.get_global_rect()
							d[k] = [r.position.x, r.position.y, r.size.x, r.size.y]
					ud.store_string(JSON.stringify(d))
					ud.close()
		"camdump":
			# dump the camera/hole state to camdump.json — the deterministic probe for
			# "why is the 1:1 stage the wrong size" class of bugs.
			var cd := FileAccess.open(_support_dir().path_join("camdump.json"), FileAccess.WRITE)
			if cd != null and _cam_rig != null:
				var vpr := get_viewport().get_visible_rect().size
				cd.store_string(JSON.stringify({
					"mode": _cam_rig._mode, "main_1to1": _one_to_one, "rig_1to1": _cam_rig._one_to_one,
					"hole": [_cam_rig._play_hole.position.x, _cam_rig._play_hole.position.y,
						_cam_rig._play_hole.size.x, _cam_rig._play_hole.size.y],
					"zoom_q": _cam_rig._zoom_q, "top_zoom": _cam_rig._top_zoom,
					"ortho": (_cam_rig._cam.size if _cam_rig._cam != null else -1.0),
					"vp": [vpr.x, vpr.y], "render_3d": render_3d,
				}))
				cd.close()
		"zoom1to1":
			# `zoom1to1 <factor>` — set the 1:1 zoom factor directly (quarters, >= 1.0). The
			# deterministic test input: key/wheel injection proved unreliable for sweeps.
			if parts.size() >= 2 and _cam_rig != null:
				_cam_rig.set_zoom_1to1(float(parts[1]))
		"inspect":
			# `inspect CX CY` — run the cell inspector at a ZONE CELL from outside (writes
			# selection.txt like a Ctrl+click). Closes the loop for tooling: no window focus
			# or mouse warp needed to ask "what did this cell render as?".
			if parts.size() >= 3 and _cam_rig != null and _cam_rig._cam != null:
				var wp := Vector3(float(parts[1]), 0.0, float(parts[2]) * _cam_rig.zstretch())
				var sp: Vector2 = _cam_rig._cam.unproject_position(wp)
				inspector.inspect_at(_cam_rig._cam, sp, _cam_rig.zstretch())
		"cam":
			if parts.size() > 1:
				_set_mode(clampi(int(parts[1]) - 1, 0, 7))   # 1-8 -> COMPASS..TOP_FOLLOW
		"mv":
			_multiview.toggle()   # all-views grid (same as the 0 key / the ` menu button)
		"dbg":
			_dbg_menu.toggle()    # the ` debug menu (for headless UI checks)
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
	_remote.poll(dt)
	if _picker.is_picking():
		_picker.update_cursor()
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

## Write a Qud option (Options.SetOption + re-export, mod-side on the uiQueue) — the nav
## overlay toggles use this to flip the same option ids Qud's own buttons persist.
func request_setoption(id: String, value: String) -> void:
	if client != null:
		client.send_command("setoption", {"id": id, "value": value})

## Back Qud out of its current MODERN screen (options/keybinds/records…). Those screens ignore every
## OS-synthesized key, so this first-party command is the only way out — the in-game Options and
## Control Mapping overlays use it to keep Qud in step when they close.
func request_uiback() -> void:
	if client != null:
		client.send_command("uiback")

## Invoke an inventory action (e.g. ReplaceSocketCell — "change the battery") on a specific equipped
## weapon, identified by its Qud GameObject id. Runs on Qud's main thread mod-side.
func request_item_action(item_id: String, action: String) -> void:
	if client != null:
		client.send_command("itemaction", {"item": item_id, "command": action})

## A Nearby Objects row was clicked: Qud's item menu for THAT object. The id is the mod's own
## finder-list id (see mod/Navigator.TwiddleNearby), so the object acted on is the one drawn.
func request_nearby(object_id: String) -> void:
	if client != null:
		client.send_command("nearby", {"id": object_id})

## Press one of Qud's OWN top-bar buttons by name. For the window lock there is no Option to set —
## its state lives on the button — so the only honest way to flip it is Qud's own onClick.
func request_nav_click(button: String) -> void:
	if client != null:
		client.send_command("navclick", {"button": button})

## A raw key into Qud's own queue, by NAME ("escape") or as a single character. Legacy screens —
## the Looker — read keys directly and ignore commands, so this is the only way to answer them.
func request_key(key: String) -> void:
	if client != null:
		client.send_command("key", {"key": key})

# --- direction picker (for abilities like Make Camp that prompt for a direction) ----------------
# Qud's PickDirection blocks the turn thread waiting for a LeftClick at a CELL (it derives the
# direction). We show the ability's icon as a cursor over the Holodeck; clicking an adjacent tile
# sends that cell (mod injects the click), a non-adjacent click / right-click / Esc cancels (mod
# injects a RightClick so Qud UNBLOCKS). Only started for abilities that actually prompt, else Qud
# would freeze waiting. The picker itself lives in DirectionPicker.gd; Main drives it from _process/_input.
var _picker                     # DirectionPicker (Node, loaded); created in _ready

## Public entry point — MainFrame calls this on the Holodeck when an ability prompts for a direction.
func start_direction_picker(icon: Texture2D) -> void:
	_picker.start(icon)

func _set_mode(m: int, force := false) -> void:
	# 1:1 (parity) mode locks the camera to the Qud-faithful top-down view — user camera
	# switches (number keys, Shift+C/K/F, multi-view) are ignored until 1:1 is turned off.
	# `force` is the internal path (set_one_to_one) that is allowed to change it.
	if _one_to_one and not force:
		return
	if _multiview.is_on():
		_multiview.toggle()   # picking a mode leaves the multi-view grid
	# The rig does the camera part (state reset, billboard lay-down, zstretch) and reports if it changed.
	if _cam_rig.set_mode(m):
		_update_mode_label()
		_refresh_wm_cards_btn()   # keep the 2D/3D button label in sync

# --- 1:1 (parity) mode ------------------------------------------------------
# The master switch that flips Raves between the QoL "user" experience and a Qud-faithful
# "1:1" reproduction. Here it owns the CAMERA half (force + lock the top-down view) and
# announces changes; MainFrame owns the panel half + persistence via one_to_one_changed.
var _one_to_one := false
var _saved_cam_mode := -1      # user-mode camera, restored when leaving 1:1
var _saved_flat_2d := false    # user-mode tile mode (3D vs flat), restored when leaving 1:1
signal one_to_one_changed(on: bool)
## Qud moved to a different CurrentGameView — its legacy screens (the Looker) arrive here, on the
## popup mirror's channel rather than the snapshot, because those screens stop snapshots.
signal qud_view_changed(name: String)

func is_one_to_one() -> bool:
	return _one_to_one

func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	_cam_rig.set_one_to_one(on)   # 1:1 vs user ortho span (safe in data-only; guards a null camera)
	# Camera half — only meaningful with the 3D viewport up (data-only mode has no camera to
	# flip); set_render_3d re-applies TOP_FOLLOW when the viewport comes on.
	if on:
		_saved_cam_mode = _cam_rig._mode
		if render_3d:
			_set_mode(CamMode.TOP_FOLLOW, true)   # the Qud-faithful 1:1 top-down (ONE_TO_ONE_SPAN)
	elif render_3d and _saved_cam_mode >= 0:
		_set_mode(_saved_cam_mode, true)          # back to the user's camera
	# Lighting half: 1:1 uses Qud's rectangular model (see ZoneRenderer) — no glow pools, flames,
	# smoke or motes are LOADED, unexplored cells draw nothing, explored-dark cells get the flat
	# memory dim. Set BEFORE the flat rebuild below so the rebuild uses the 1:1 light rules.
	if renderer != null:
		renderer.set_one_to_one(on)
	# Tile half: Qud renders every tile FLAT, as loaded — the voxel walls / stretched-UV 3D look is a
	# user-mode feature. 1:1 forces the flat path (which also renders ONLY the live zone — see
	# _neighbor_zones); leaving 1:1 restores whatever the user had. Ordered after the camera flip so
	# the rebuild happens under the final top-down stretch. (Set _one_to_one first — _toggle_flat_2d
	# is locked while on, so go through _apply_flat_2d directly.)
	if on:
		_saved_flat_2d = _flat_2d
		_apply_flat_2d(true)               # rebuild even if already flat — the light rules changed
	else:
		_apply_flat_2d(_saved_flat_2d)     # ditto on exit
	one_to_one_changed.emit(on)

func toggle_one_to_one() -> void:
	set_one_to_one(not _one_to_one)

## MainFrame tells us how much of the window the 1:1 side panels cover (0..~0.4). The camera shifts its
## lens so the zone-fit centres in the visible play hole (left of the sidebar), not the full window.
func set_ui_right_inset(frac: float) -> void:
	_ui_right_inset = clampf(frac, 0.0, 0.6)
	if _cam_rig != null:
		_cam_rig.set_right_inset(_ui_right_inset)

## MainFrame pushes the play hole's actual px rect (row 3's transparent area). The 1:1 camera fits
## Qud's 80x25 stage into THIS rect (both axes) at Qud's letterbox scale — the pixel-1:1 model.
func set_play_hole_rect(r: Rect2) -> void:
	if _cam_rig != null:
		_cam_rig.set_play_hole(r)

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

## RIGHT-CLICK: Qud's context interaction on the clicked tile — the object's menu, which comes
## back over the popup mirror. Qud's own handler picks the object and decides what right-clicking
## it means (see mod/Navigator.Interact); all we carry is the cell.
func _interact_click(pos: Vector2) -> void:
	var cell = _playfield_cell(pos)
	if cell == null:
		return
	client.send_command("interact", {"x": cell.x, "y": cell.y})


## CLICK-TO-TRAVEL. Send the clicked cell to Qud, which walks the player there with its own
## MoveTo goal (see mod/Navigator.cs) -- pathing, doors and hostile-interrupts are Qud's, not ours.
##
## The cell comes from the INSPECTOR's picking, not a second mapping of our own: travel then lands
## on exactly the cell Ctrl+click reports, wall-snapping included.
func _travel_click(pos: Vector2) -> void:
	var cell = _playfield_cell(pos)
	if cell == null:
		return
	client.send_command("moveto", {"x": cell.x, "y": cell.y})


## The zone cell a playfield click lands on, or null if this click is not the playfield's to have.
## Shared by both buttons so travel and interact can never disagree about either half of that.
func _playfield_cell(pos: Vector2) -> Variant:
	if inspector == null or _cam_rig == null or _cam_rig._cam == null:
		return null
	# claims() is the same "is this UI chrome?" test the Cmd+right-click branch above uses -- the
	# play hole carries feedback_skip, every panel and screen does not.
	if FeedbackTool.claims(pos):
		return null
	# A modal owns the whole screen even where it does not paint: clicking the visible playfield
	# behind a popup must not quietly order a walk, or open a second menu behind the first.
	if (_popup != null and _popup.visible) or (_item_picker != null and _item_picker.visible) \
			or (overlay_check.is_valid() and bool(overlay_check.call())):
		return null
	return inspector.cell_at(_cam_rig._cam, pos, _cam_rig.zstretch())

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
	if _dbg_menu != null:
		_dbg_menu.set_active_mode(_cam_rig._mode)   # highlight the active mode button

# --- debug menu -------------------------------------------------------------

# --- world 2D/3D toggle (shared: the ` menu's face button, the O key, and the persistent top-right btn) ---
var _flat_2d := false   # false = 3D upright billboards, true = everything flat on the floor (2D map)

## Flip the WHOLE world — every stratum — between 3D (upright billboards + wall blocks) and 2D
## (everything laid flat on the floor, a classic top-down map). The renderer drops its frozen
## geometry, so re-render the current snapshot to rebuild the live zone (and neighbours) in the new
## mode — instant feedback instead of waiting for the next turn.
## 1:1 FORCES flat (Qud renders tiles flat, as loaded — the 3D wall stretch/UV mapping is a user-mode
## feature), so the toggle is locked out while 1:1 is on, like the camera modes.
func _toggle_flat_2d() -> void:
	if _one_to_one:
		return                       # 1:1 owns the tile mode (flat); O is a no-op until user mode
	_apply_flat_2d(not _flat_2d)

## The shared apply path (O toggle + the 1:1 master switch): set the renderer mode, rebuild the
## current snapshot in it, and sync the two UI mirrors of the state.
func _apply_flat_2d(on: bool) -> void:
	_flat_2d = on
	renderer.set_flat_2d(on)
	var live: Dictionary = store.live_snapshot()
	if not live.is_empty():
		renderer.render_snapshot(live, _neighbor_zones())
	if _dbg_menu != null:
		_dbg_menu.refresh_flat_2d(_flat_2d)   # the ` menu's mirror of this state
	_refresh_wm_cards_btn()

## Label for the persistent top-right button — the current tile mode (3D up vs 2D flat).
func _refresh_wm_cards_btn() -> void:
	if _wm_cards_btn == null:
		return
	_wm_cards_btn.text = "tiles (O): %s" % ("2D flat" if _flat_2d else "3D up")

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
	var restart := PackedStringArray(["--resolution", "%dx%d" % [sz.x, sz.y]])
	# If highvisor launched us in --launch-qud mode, re-pass those user args so the
	# restarted instance stays borderless and re-adopts the still-running Qud (the
	# quit() below doesn't fire WM_CLOSE_REQUEST, so QudLauncher leaves Qud alive).
	var qargs := QudLauncher.relaunch_args()
	if not qargs.is_empty():
		restart.append("--")
		restart.append_array(qargs)
	OS.set_restart_on_exit(true, restart)
	get_tree().quit()

## Save on window close (the X); the Reset button saves explicitly in _reset_program.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_settings()

## Persist the view/render settings a run should remember.
func _save_settings() -> void:
	var sz := DisplayServer.window_get_size()
	# In 1:1 mode the window size is the STAGE's, not the user's, so writing it back would
	# quietly overwrite the size they chose in user mode with whatever the last parity run
	# happened to use. Carry the stored value through instead of recording the stage's.
	var keep_win: Variant = null
	if Settings.one_to_one() and FileAccess.file_exists(SETTINGS_PATH):
		var pf := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		if pf != null:
			var prev: Variant = JSON.parse_string(pf.get_as_text())
			pf.close()
			if prev is Dictionary:
				keep_win = prev.get("win", null)
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
		"win": (keep_win if keep_win != null else [sz.x, sz.y]),
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
	# Skip in launch-qud mode: QudLauncher owns the window geometry there (borderless
	# quadrant), and a saved size would fight it when entering gameplay.
	#
	# Skip in 1:1 mode for the same reason, one layer out: the STAGE owns geometry there
	# (hv layout / the cockpit buttons), and Raves must match Qud's window exactly or every
	# parity leaf rect means a different thing in each app. This restore fired late enough
	# to look like something else entirely -- `hv restart raves` placed the window
	# correctly, then loading the Holodeck for a status tab resized it back to a saved
	# 4267x2400, so captures came back 2400 tall against a 1080-tall spec and the blame
	# went to the restart racing the window. It was this, on a completely different clock.
	if win is Array and win.size() == 2 and int(win[0]) > 200 and int(win[1]) > 200 \
			and not QudLauncher.active and not Settings.one_to_one():
		DisplayServer.window_set_size(Vector2i(int(win[0]), int(win[1])))
	var m := int(d.get("mode", _cam_rig._mode))
	if m >= 0 and m <= CamMode.TOP_FOLLOW:
		_cam_rig._mode = m
		if renderer != null:
			renderer.set_top_down(m == CamMode.TOP_FOLLOW)

# --- input ------------------------------------------------------------------

## Direction-picker input is handled in _input (BEFORE the GUI), because the frame's container Controls
## consume mouse clicks over the Holodeck before they'd reach _unhandled_input. Only consumes while
## picking; otherwise events flow to the GUI / _unhandled_input as normal.
func _input(event: InputEvent) -> void:
	if _picker.is_picking() and _picker.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	# Inspect clicks must be caught HERE (before the GUI): when the Holodeck is embedded in MainFrame, the
	# frame's container Controls eat mouse clicks over it before _unhandled_input — the same reason the
	# picker lives here. Ctrl/Cmd+click inspects; Ctrl/Cmd+right-click inspects AND photographs both apps.
	# (Non-inspect mouse — MOUSE-mode orbit/pan, wheel zoom — stays in _unhandled_input.)
	if event is InputEventMouseButton and event.pressed and (event.ctrl_pressed or event.meta_pressed):
		if event.button_index == MOUSE_BUTTON_LEFT:
			_inspect()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Cmd+Right-click over UI CHROME belongs to the element-feedback form, and the scene
			# sees _input before autoloads — consuming unconditionally here starved FeedbackTool
			# of every such click in-game. Over the playfield claims() is false and we inspect.
			if FeedbackTool.claims(event.position):
				return
			_inspect_and_capture()
			get_viewport().set_input_as_handled()
		return
	# CLICK-TO-TRAVEL. A plain left click on the playfield walks the player there, as in Qud.
	# Decided on RELEASE, and only when the mouse barely moved: in MOUSE mode this same button
	# drags the camera orbit, and a drag must not also be a travel order.
	# Deliberately NOT consumed -- the release still has to reach _unhandled_input to END that
	# orbit; swallowing it leaves the camera spinning with the button already up.
	# …and a plain RIGHT click is Qud's context interaction on that tile. Same click-not-drag
	# discipline (right-drag pans in MOUSE mode), same reason for not consuming it.
	if event is InputEventMouseButton \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] \
			and not (event.ctrl_pressed or event.meta_pressed or event.alt_pressed or event.shift_pressed):
		if event.pressed:
			_travel_press = event.position
		else:
			var press = _travel_press
			_travel_press = null
			if press != null and event.position.distance_to(press) <= TRAVEL_SLOP:
				if event.button_index == MOUSE_BUTTON_LEFT:
					_travel_click(event.position)
				else:
					_interact_click(event.position)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# TYPING GUARD, and it is NOT redundant here. `_unhandled_input` only sees keys the GUI did
		# not consume -- which is not "no keys while a field has focus": a field consumes what it
		# has a use for and ignores the rest, and modifier combos are exactly the rest. Measured
		# with the feedback note focused: letters landed in the box, and Ctrl+Shift+X ran Qud's xp
		# wish (0 -> 150 Exp). Everything below dispatches to QUD -- moves, waits, wishes, and
		# `_binds.match_event`, which runs whatever the player has bound -- so it is all off-limits
		# while someone is typing.
		if TypingGuard.typing(get_viewport()):
			return
		# Shift+Space: wait a turn in Qud (a Godot->Qud passthrough). Takes a turn for now.
		if event.shift_pressed and event.keycode == KEY_SPACE:
			client.send_command("wait", {}); return
		# F1 opens the controls chooser. (While it's open it swallows input via its
		# own _input, so this handler won't see keys until it closes.)
		if event.keycode == KEY_F1:
			onboarding.open(); return
		# Ctrl+M: toggle 1:1 (parity) mode — camera + panels flip to Qud-faithful, and back.
		# Ctrl (not Cmd, which is macOS "minimize"); the highvisor 1:1 button injects this same key.
		if event.keycode == KEY_M and event.ctrl_pressed \
				and not (event.meta_pressed or event.shift_pressed or event.alt_pressed):
			toggle_one_to_one(); return
		# Ctrl+Shift+W: Qud's wish shortcut. Opens a text prompt in Raves; on Enter we ship the wish
		# to Qud over the bridge (it runs Qud's own wish handler). Lets us grant xp, spawn items, etc.
		if event.keycode == KEY_W and event.ctrl_pressed and event.shift_pressed \
				and not event.meta_pressed:
			_open_wish(); return
		# Dedicated stress-test wishes (single combo, no text prompt) — bump the EXP / HP bars straight
		# from Qud's own wish handler. X = +150 xp, H = -3 hp (hurt), J = full heal.
		if event.ctrl_pressed and event.shift_pressed and not event.meta_pressed:
			if event.keycode == KEY_X:
				client.send_command("wish", {"wish": "xp:150"}); return
			if event.keycode == KEY_H:
				client.send_command("wish", {"wish": "statpenalty:Hitpoints:3"}); return
			if event.keycode == KEY_J:
				client.send_command("wish", {"wish": "statpenalty:Hitpoints:-9999"}); return
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
		if event.keycode == KEY_0 and not _one_to_one: _multiview.toggle(); return   # 0 = all-views grid (locked out in 1:1)
		if event.keycode == KEY_QUOTELEFT:      # ` toggles the debug menu
			_dbg_menu.toggle(); return
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
		# in FLY (WASD drives the free camera there), and not in 1:1 — Qud's camera is
		# the letterbox model only (zoom + clamped player follow), never a free dolly.
		if _cam_rig._mode != CamMode.KEYBOARD and not _one_to_one and event.keycode == KEY_W:
			_cam_rig._cam_pan += _cam_rig.cam_forward() * _cam_rig.CAM_STEP; return
		if _cam_rig._mode != CamMode.KEYBOARD and not _one_to_one and event.keycode == KEY_X:
			_cam_rig._cam_pan -= _cam_rig.cam_forward() * _cam_rig.CAM_STEP; return
		# S / D = go UP / DOWN stairs (Qud's climb commands CmdMoveU / CmdMoveD; Down also
		# pulls down from the world map). Direct command injection — NOT a raw keymap
		# forward, so it works whatever s/d are bound to in Qud. Mirrors the top-bar
		# ▲ Up / ▼ Down buttons. Skipped in FLY (KEYBOARD) mode, where WASD flies the camera.
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_S:
			client.send_command("command", {"command": "CmdMoveU"}); return
		if _cam_rig._mode != CamMode.KEYBOARD and event.keycode == KEY_D:
			client.send_command("command", {"command": "CmdMoveD"}); return
		if event.keycode == KEY_ESCAPE:
			# close the camera/debug menu and any selection, but KEEP the current camera.
			# With nothing to dismiss, 1:1 Esc = Qud's own binding (CmdSystemMenu,
			# Commands.xml): the system-menu POPUP opens in Qud and mirrors back into
			# Raves through the popup bridge — picking Save and Quit / Options there
			# round-trips like any popup.
			# NB .visible on the debug menu is useless — the NODE stays visible, only
			# its internal panel toggles (is_open() reads that). Same trap generally.
			var had_ui: bool = (inspector != null and inspector.selected_tile() != null) \
				or (_dbg_menu != null and _dbg_menu.is_open()) \
				or (_char_creator != null and _char_creator.visible)
			_dismiss_selection()
			if _dbg_menu != null:
				_dbg_menu.close()
			if _char_creator != null:
				_char_creator.visible = false
			# a MainFrame overlay (status screens / control mapping) owns Esc for its
			# own close — Main runs FIRST in _unhandled_input (later sibling), so
			# without this check Esc would ALSO pop Qud's system menu underneath
			var overlay_open: bool = overlay_check.is_valid() and bool(overlay_check.call())
			if not had_ui and _one_to_one and not overlay_open:
				client.send_command("command", {"command": "CmdSystemMenu"})
			return
		if event.keycode == KEY_I:
			_inspect(); return
		if event.keycode == KEY_L:
			_toggle_font_preview(); return   # L: font-size ruler (Lorem Ipsum at each px)
		if event.keycode == KEY_F12:
			_screenshot(); return
		if event.keycode == KEY_P:
			_dump_profile(); return   # P: macOS grabs F9 (Mission Control)
		if event.keycode == KEY_MINUS or event.keycode == KEY_KP_SUBTRACT:
			if _one_to_one and _cam_rig._mode == CamMode.TOP_FOLLOW:
				_cam_rig.zoom_1to1_step(-1); return   # Qud's CmdZoomOut (quarter step, floor = fit)
			inspector.nudge_font(-2)
			reporter.nudge_font(-2); return
		if event.keycode == KEY_EQUAL or event.keycode == KEY_KP_ADD:
			if _one_to_one and _cam_rig._mode == CamMode.TOP_FOLLOW:
				_cam_rig.zoom_1to1_step(1); return    # Qud's CmdZoomIn (quarter step)
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
		# LAST fallback: the player's own Qud keybindings (Control Mapping remaps).
		# Qud stores a remap fine but Raves' hardcoded keys never consulted it, so a
		# custom bind ("{" = Move east) died at our seam. Raves handlers above keep
		# precedence (movement keys just moved — bail before double-sending); any
		# unclaimed combo that matches a binding runs Qud's own command.
		if event.keycode in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_KP_8, KEY_KP_2,
				KEY_KP_4, KEY_KP_6, KEY_KP_7, KEY_KP_9, KEY_KP_1, KEY_KP_3]:
			return
		if not (_popup != null and _popup.visible) \
				and not (_item_picker != null and _item_picker.visible) \
				and not (overlay_check.is_valid() and bool(overlay_check.call())):
			var qcmd: String = _binds.match_event(event)
			if qcmd != "":
				client.send_command("command", {"command": qcmd})
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# Ctrl/Cmd+click inspect is handled in _input (containers eat it here when embedded);
				# a plain click orbits (MOUSE mode).
				_cam_rig._orbiting = event.pressed and _cam_rig._mode == CamMode.MOUSE
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				# Ctrl/Cmd+right-click inspect+capture is handled in _input; a plain right/middle pans.
				_cam_rig._panning = event.pressed and _cam_rig._mode == CamMode.MOUSE
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					if _one_to_one and _cam_rig._mode == CamMode.TOP_FOLLOW:
						_cam_rig.zoom_1to1_step(1)     # Qud's quarter-step zoom in (min factor 1.0 = fit)
					elif _cam_rig._mode == CamMode.TOP_FOLLOW:
						_cam_rig._top_zoom = clampf(_cam_rig._top_zoom * 0.9, _cam_rig.TOP_ZOOM_MIN, _cam_rig.TOP_ZOOM_MAX)
					else:
						_cam_rig._dist = clampf(_cam_rig._dist * 0.9, _cam_rig.DIST_MIN, _cam_rig.DIST_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					if _one_to_one and _cam_rig._mode == CamMode.TOP_FOLLOW:
						_cam_rig.zoom_1to1_step(-1)    # Qud's quarter-step zoom out (stops at the zone fit)
					elif _cam_rig._mode == CamMode.TOP_FOLLOW:
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

# ── Wish prompt (Ctrl+Shift+W) ───────────────────────────────────────────────
# A minimal text prompt that ships whatever you type to Qud's own wish handler over the bridge (grant
# xp, spawn items, …), no Qud-side prompt needed. A user-mode button will front this later; for now the
# shortcut is the entry point. send_command no-ops if the bridge isn't connected.
func _open_wish() -> void:
	if _wish_layer == null:
		_wish_layer = CanvasLayer.new()
		_wish_layer.layer = 128
		add_child(_wish_layer)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.theme = UiFont.make_theme(get_viewport())   # avoid the CanvasLayer tiny-font trap
		_wish_layer.add_child(center)
		var panel := PanelContainer.new()
		var pstyle := StyleBoxFlat.new()
		pstyle.bg_color = Color(0.05, 0.06, 0.07, 0.96)
		pstyle.set_content_margin_all(14)
		pstyle.border_color = Color(0.30, 0.40, 0.45)
		pstyle.set_border_width_all(1)
		panel.add_theme_stylebox_override("panel", pstyle)
		center.add_child(panel)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 6)
		panel.add_child(vb)
		var lbl := Label.new()
		lbl.text = "Wish  (Enter to send · Esc to cancel)"
		vb.add_child(lbl)
		_wish_edit = LineEdit.new()
		_wish_edit.custom_minimum_size = Vector2(460, 0)
		_wish_edit.placeholder_text = "e.g. xp:5000"
		_wish_edit.text_submitted.connect(_on_wish_submitted)
		_wish_edit.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
				_close_wish())
		vb.add_child(_wish_edit)
	_wish_layer.visible = true
	_wish_edit.text = ""
	_wish_edit.grab_focus()

func _on_wish_submitted(text: String) -> void:
	var w := text.strip_edges()
	if w != "" and client != null:
		client.send_command("wish", {"wish": w})
		# The wish drains on Qud's game thread (Tick), which does NOT run while Qud sits
		# unfocused with no turn passing — the wish silently pends and "wishing doesn't
		# work". Chase it with a wait: PushCommand wakes the parked input loop even
		# unfocused, the turn ticks, the wish applies, and the snapshot refreshes Raves.
		client.send_command("wait", {})
	_close_wish()

func _close_wish() -> void:
	if _wish_layer != null:
		_wish_layer.visible = false
	if _wish_edit != null:
		_wish_edit.release_focus()

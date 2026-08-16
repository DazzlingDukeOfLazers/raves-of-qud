extends Node

## Persistent Raves settings — the store behind the Options screen. Autoload "Settings".
##
## Mirrors the overrides.json / title_layout.json pattern: a JSON file in the RavesOfQud
## support dir, defaults in code so a wiped config still boots. Loaded at startup; the
## GLOBAL settings (font scale, fullscreen) are applied immediately so the whole app honors
## them before any UI builds. OptionsScreen reads/writes via get_value/set_value + save();
## the per-view defaults (full_info, camera, bridge host/port) are read by their own
## components (MainFrame, CameraRig, BridgeClient) via get_value at init.

const DEFAULTS := {
	"font_scale": 1.0,          # global UI size multiplier (UiFont.scale)
	"fullscreen": false,        # window mode
	"full_info": false,         # perceived (false) vs full/debug (true) info by default
	# 1:1 test — visual effects. MINIMAL by default (all off): start bare and build up to find
	# where Raves diverges from Qud. Each applies on (re)launch; toggle in Options.
	"fx_scanlines": false,      # CRT scanline interlace
	"fx_vignette": false,       # CRT corner vignette (Qud's HUD has none)
	"camera": 0,                # default CameraRig.CamMode index (user mode)
	"mode": "user",             # "user" = QoL Holodeck · "1to1" = Qud-faithful parity mode
	                            # (1to1 hard-overrides camera + panels; see MainFrame._apply_one_to_one)
	"bridge_host": "127.0.0.1", # which Qud to render (BridgeClient)
	"bridge_port": 48710,
}

## True when Raves was launched with --one-to-one (or --1to1): 1:1 is LOCKED for this
## run. The Options screen hides the RAVES section entirely — parity with Qud's options,
## and deliberately no toggle back to user mode (run without the flag for that). Doubles
## as the pressure valve that flushes out user-mode UI elements missing a 1:1 gate.
var one_to_one_only := false

## THE LITERAL MODE. Use this only where the answer must be "which mode did the viewer pick" —
## reporting it (UiState, the feedback record and its badge) and offering the way BACK from it
## (OptionsScreen, which builds a different screen per mode and is the only route to the toggle).
## For "should this surface take Qud's shape", use `qud_shape` below.
func one_to_one() -> bool:
	if one_to_one_only:
		return true
	return str(get_value("mode", "user")) == "1to1"

## USER MODE STARTS AS A 1:1 CLONE — Daniel, 2026-08-12: "Let's copy all the 1:1 settings to
## usermode. We'll load back in features 1 at a time."
##
## User mode had accumulated its own shape screen by screen, and testing it meant meeting those
## divergences one surprise at a time: a save name under Continue that Qud does not show, an
## in-game field Qud does not have, a "turn on viewport" step left over from before the 1:1 flow
## existed. Each was defensible alone and the pile was not, because nothing said what the pile
## contained — 55 call sites across 16 files, and no list of them anywhere.
##
## So the DEFAULT flips. A surface asks `qud_shape()` and gets Qud's form in both modes; a QoL
## feature comes back only when it is named here and switched on, which makes the set of
## divergences a list you can read instead of a thing you discover.
##
## `feature` is that name. Unnamed sites can never opt out, which is deliberate for now: they are
## the ones nobody has argued for yet.
## name -> [label, default]. EVERY entry is a divergence from Qud someone chose on purpose, and
## being in this dictionary is what makes it choosable rather than merely present. Off by default:
## user mode starts as a 1:1 clone and features are loaded back one at a time.
const QOL_FEATURES := {
	"titlebar": ["Window titlebar", false],
	"cameras": ["User cameras (Compass / Follow / First person / …)", false],
	"tiles3d": ["3D tiles (voxel walls + upright sprites)", false],
	"lighting": ["Day/night lighting (grade + sun/moon + fog)", false],
	"particles": ["Smoke plumes (sconces & torches at night)", false],
	"depthcue": ["Depth cue (farther is slightly darker)", false],
	"cutaway": ["Wall cutaway (fade rock between camera and you)", false],
	# ON by default, unlike its neighbours: Qud draws a tree in one cell because it has
	# only one cell to draw it in, and at 1x a 3D tree reads as a shrub. 1:1 mode is
	# unaffected — the renderer gates the scale out there, where pixels are measured.
	"bigtrees": ["Trees at 2x scale", true],
}

func qud_shape(feature := "") -> bool:
	if one_to_one():
		return true
	if feature != "" and qol_on(feature):
		return false      # this QoL feature has been loaded back in
	return true           # user mode: Qud's shape until told otherwise

## Is a named QoL feature switched back on? Unknown names are always off -- a typo must not
## silently re-enable a divergence.
func qol_on(feature: String) -> bool:
	if not QOL_FEATURES.has(feature):
		return false
	return bool(get_value("qol_" + feature, bool(QOL_FEATURES[feature][1])))

var _data: Dictionary = {}
var _rect_mtime := -1.0

func _ready() -> void:
	for a in Array(OS.get_cmdline_args()) + Array(OS.get_cmdline_user_args()):
		if a == "--one-to-one" or a == "--1to1":
			one_to_one_only = true
	_load()
	apply_global()
	# Window-placement channel: highvisor WRITES window_rect.json (the reverse of our
	# state reports) and we place ourselves via DisplayServer — macOS AX cannot
	# reliably move a borderless Godot window (readback showed sets landing at
	# y=-2196 / failing outright once 1:1 went chromeless).
	var t := Timer.new()
	t.wait_time = 0.5
	t.timeout.connect(_poll_window_rect)
	add_child(t)
	t.start()
	_poll_window_rect()

func _poll_window_rect() -> void:
	var path := InputModel.support_dir().path_join("window_rect.json")
	if not FileAccess.file_exists(path):
		return
	var m := FileAccess.get_modified_time(path)
	if float(m) == _rect_mtime:
		return
	_rect_mtime = float(m)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary):
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return   # never fight fullscreen
	var w := int(d.get("w", 0))
	var h := int(d.get("h", 0))
	# SANITY: refuse a placement that would land the window off every screen.
	# A rect computed on another machine's layout (the Mac's 4K stack docked us
	# at y=-1269 on the PC) silently broke the capture rig's calibrated
	# geometry mid-run. Validate the TRANSLATED rect against real screens;
	# skip the whole request when it doesn't intersect any of them.
	if d.has("x") and d.has("y") and w > 0 and h > 0:
		var off_chk := DisplayServer.screen_get_position(DisplayServer.get_primary_screen())
		var tx := int(d.get("x")) + off_chk.x
		var ty := int(d.get("y")) + off_chk.y
		var on_any := false
		for si in DisplayServer.get_screen_count():
			var sp := DisplayServer.screen_get_position(si)
			var ssz := DisplayServer.screen_get_size(si)
			if tx < sp.x + ssz.x and tx + w > sp.x and ty < sp.y + ssz.y and ty + h > sp.y:
				on_any = true
				break
		if not on_any:
			print("Settings: REJECTED off-screen window_rect ", d)
			return
	if w > 0 and h > 0:
		DisplayServer.window_set_size(Vector2i(w, h))
	if d.has("x") and d.has("y"):
		# The rect arrives in CG coordinates (origin = primary display's top-left);
		# Godot's virtual-desktop origin is the bounding box's top-left. The primary
		# screen's godot-space position IS the offset between the two spaces.
		var off := DisplayServer.screen_get_position(DisplayServer.get_primary_screen())
		DisplayServer.window_set_position(Vector2i(int(d.get("x")), int(d.get("y"))) + off)

func get_value(key: String, default_val = null) -> Variant:
	if _data.has(key):
		return _data[key]
	if DEFAULTS.has(key):
		return DEFAULTS[key]
	return default_val

func set_value(key: String, value) -> void:
	_data[key] = value

## Persist to disk, then re-apply the global settings (so a change takes effect live).
func save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_data, "  "))
	apply_global()

## Apply the settings that affect the whole app immediately (not per-view).
func apply_global() -> void:
	UiFont.scale = clampf(float(get_value("font_scale", 1.0)), 0.6, 2.0)
	var fs := bool(get_value("fullscreen", false))
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fs else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)
	# CHROMELESS, matching Qud's -popupwindow: the macOS title strip eats 32px of the frame and
	# shifts all content down, which ghosts every parity diff (2026-08-03 menu baseline) — measured
	# again 2026-08-12, when it was the ONLY thing left between the two modes' title screens. With
	# it aligned away they were pixel-identical, 0 of 1,950,720.
	#
	# It used to be 1:1 only ("user mode keeps the titlebar"). It is now the first named QoL
	# feature instead: off by default like the rest, switch `titlebar` on to get it back.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, qud_shape("titlebar"))

func _path() -> String:
	return InputModel.support_dir().path_join("settings.json")

func _load() -> void:
	_data = DEFAULTS.duplicate(true)
	var path := _path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		for k in d:
			_data[k] = d[k]

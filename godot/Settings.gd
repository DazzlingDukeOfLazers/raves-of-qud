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
	"fx_particles": false,      # 3D smoke / particle plumes
	"fx_lighting": false,       # 3D day/night colour grade + sky bodies + fog
	"camera": 0,                # default CameraRig.CamMode index (user mode)
	"mode": "user",             # "user" = QoL Holodeck · "1to1" = Qud-faithful parity mode
	                            # (1to1 hard-overrides camera + panels; see MainFrame._apply_one_to_one)
	"bridge_host": "127.0.0.1", # which Qud to render (BridgeClient)
	"bridge_port": 48710,
}

## True when the parity/1:1 mode is selected (overrides user-mode camera + panels).
func one_to_one() -> bool:
	return str(get_value("mode", "user")) == "1to1"

var _data: Dictionary = {}
var _rect_mtime := -1.0

func _ready() -> void:
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
	# 1:1 runs CHROMELESS, matching Qud's -popupwindow: the macOS title strip ate
	# ~28px of the frame, shifting all content down vs Qud and ghosting every
	# parity diff (2026-08-03 menu baseline). User mode keeps the titlebar.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, one_to_one())

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

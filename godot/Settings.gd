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
	"camera": 0,                # default CameraRig.CamMode index
	"bridge_host": "127.0.0.1", # which Qud to render (BridgeClient)
	"bridge_port": 48710,
}

var _data: Dictionary = {}

func _ready() -> void:
	_load()
	apply_global()

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

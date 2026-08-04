extends RefCounted
class_name InputModel

## The input SEAM: one data-driven catalog of every player-facing command and the
## key bound to it, so nothing has to read a hardcoded keycode `match` to know what
## a key does.
##
## Today the live handler in Main._unhandled_input() still owns dispatch; this model
## is seeded from EXACTLY those bindings so the two can't drift while the handler is
## migrated onto it. What reads the catalog now: the onboarding keyboard-layout screen
## ("what does this key do?"). What will read/write it next: key rebinding, and a
## Python-side importer that maps Caves of Qud's own keybinds into the same shape so
## Raves can replicate Qud's settings menus.
##
## Storage mirrors the overrides.json pattern — a JSON file in the RavesOfQud support
## dir. Only user CHOICES persist (which devices, which keyboard layout, any rebinds);
## the default bindings live in code so a wiped config still boots with the real map.

## Which input devices the player intends to use. Multi-select — a player may drive
## with keyboard + mouse together, or add a gamepad.
enum Device { KEYBOARD, MOUSE, GAMEPAD, CLI }

## Two real keyboard control schemes already in Main.gd, surfaced as a choice:
##   FUNCTION_KEYS — arrows move (camera-relative), letters/number-row for camera + view.
##   NUMPAD        — the numpad 1-9 as an absolute 8-way compass (precise fallback).
enum KeyboardType { FUNCTION_KEYS, NUMPAD }

## Scheme tags on actions, so the layout screen shows the right cluster:
##   "kbd"    — the arrows/letters scheme (KeyboardType.FUNCTION_KEYS)
##   "numpad" — the numpad compass scheme (KeyboardType.NUMPAD)
##   "any"    — works under either keyboard scheme (camera modes, inspect, etc.)
##   "mouse"  — mouse gesture (shown on the mouse screen, not the keyboard)

## The catalog. id -> { label, desc, cat, scheme, key, legend }.
## `key` is a Godot KEY_* constant (the DEFAULT binding); `legend` is what's printed
## on the physical key cap. Seeded verbatim from Main._unhandled_input()/_process.
const ACTIONS := {
	# --- movement: camera-relative arrows (FUNCTION_KEYS scheme) ---------------
	"move_forward": {"label": "Move forward", "desc": "Step toward the top of the screen", "cat": "Movement", "scheme": "kbd", "key": KEY_UP, "legend": "↑"},
	"move_back":    {"label": "Move back", "desc": "Step toward the bottom of the screen", "cat": "Movement", "scheme": "kbd", "key": KEY_DOWN, "legend": "↓"},
	"move_left":    {"label": "Move left", "desc": "Strafe left · turn left in first-person", "cat": "Movement", "scheme": "kbd", "key": KEY_LEFT, "legend": "←"},
	"move_right":   {"label": "Move right", "desc": "Strafe right · turn right in first-person", "cat": "Movement", "scheme": "kbd", "key": KEY_RIGHT, "legend": "→"},

	# --- movement: numpad absolute 8-way compass (NUMPAD scheme) ---------------
	"step_nw": {"label": "Step NW", "desc": "Move northwest", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_7, "legend": "7"},
	"step_n":  {"label": "Step N", "desc": "Move north", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_8, "legend": "8"},
	"step_ne": {"label": "Step NE", "desc": "Move northeast", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_9, "legend": "9"},
	"step_w":  {"label": "Step W", "desc": "Move west", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_4, "legend": "4"},
	"step_e":  {"label": "Step E", "desc": "Move east", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_6, "legend": "6"},
	"step_sw": {"label": "Step SW", "desc": "Move southwest", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_1, "legend": "1"},
	"step_s":  {"label": "Step S", "desc": "Move south", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_2, "legend": "2"},
	"step_se": {"label": "Step SE", "desc": "Move southeast", "cat": "Movement", "scheme": "numpad", "key": KEY_KP_3, "legend": "3"},

	# --- camera modes: number row, work under either scheme --------------------
	"cam_compass":      {"label": "Compass camera", "desc": "Cardinal-locked low-angle view (default)", "cat": "Camera", "scheme": "any", "key": KEY_1, "legend": "1"},
	"cam_follow":       {"label": "Follow camera", "desc": "Trails your heading", "cat": "Camera", "scheme": "any", "key": KEY_2, "legend": "2"},
	"cam_first_person": {"label": "First-person", "desc": "Eye-level along the locked heading", "cat": "Camera", "scheme": "any", "key": KEY_3, "legend": "3"},
	"cam_cinematic":    {"label": "Cinematic", "desc": "Frames you + the selected tile", "cat": "Camera", "scheme": "any", "key": KEY_4, "legend": "4"},
	"cam_mouse":        {"label": "Orbit camera", "desc": "Orbit/pan with the mouse", "cat": "Camera", "scheme": "any", "key": KEY_5, "legend": "5"},
	"cam_keyboard":     {"label": "Fly camera", "desc": "Free flight (WASD move, arrows aim)", "cat": "Camera", "scheme": "any", "key": KEY_6, "legend": "6"},

	# --- camera control -------------------------------------------------------
	"rotate_left":  {"label": "Rotate left", "desc": "Turn the compass heading left 90°", "cat": "Camera", "scheme": "any", "key": KEY_Q, "legend": "Q"},
	"rotate_right": {"label": "Rotate right", "desc": "Turn the compass heading right 90°", "cat": "Camera", "scheme": "any", "key": KEY_E, "legend": "E"},
	"debug_menu":   {"label": "Camera menu", "desc": "Toggle the camera debug menu", "cat": "Camera", "scheme": "any", "key": KEY_QUOTELEFT, "legend": "`"},

	# --- fly-mode movement (KEYBOARD cam), polled in _process -----------------
	"fly_forward": {"label": "Fly forward", "desc": "Move the free camera (fly mode)", "cat": "Camera", "scheme": "kbd", "key": KEY_W, "legend": "W"},
	"fly_left":    {"label": "Fly left", "desc": "Move the free camera (fly mode)", "cat": "Camera", "scheme": "kbd", "key": KEY_A, "legend": "A"},
	"fly_back":    {"label": "Fly back", "desc": "Move the free camera (fly mode)", "cat": "Camera", "scheme": "kbd", "key": KEY_S, "legend": "S"},
	"fly_right":   {"label": "Fly right", "desc": "Move the free camera (fly mode)", "cat": "Camera", "scheme": "kbd", "key": KEY_D, "legend": "D"},

	# --- view / tools ---------------------------------------------------------
	"inspect":      {"label": "Inspect tile", "desc": "Inspect the tile under the cursor", "cat": "View", "scheme": "any", "key": KEY_I, "legend": "I"},
	"screenshot":   {"label": "Screenshot", "desc": "Save the viewport (and ask Qud for its own)", "cat": "View", "scheme": "any", "key": KEY_F12, "legend": "F12"},
	"dump_profile": {"label": "Dump profile", "desc": "Write the frame-timing profile", "cat": "Debug", "scheme": "any", "key": KEY_P, "legend": "P"},
	"font_smaller": {"label": "Smaller text", "desc": "Shrink the inspector/report panels", "cat": "View", "scheme": "any", "key": KEY_MINUS, "legend": "-"},
	"font_larger":  {"label": "Larger text", "desc": "Grow the inspector/report panels", "cat": "View", "scheme": "any", "key": KEY_EQUAL, "legend": "="},
	"cancel":       {"label": "Cancel", "desc": "Dismiss selection · return to compass camera", "cat": "View", "scheme": "any", "key": KEY_ESCAPE, "legend": "Esc"},

	# --- mouse (shown on the mouse screen, not the keyboard) ------------------
	"mouse_inspect": {"label": "Inspect", "desc": "Ctrl/Cmd + left-click a tile to inspect it", "cat": "Mouse", "scheme": "mouse", "key": KEY_NONE, "legend": "Ctrl+LMB"},
	"mouse_capture": {"label": "Inspect + photograph", "desc": "Ctrl/Cmd + right-click: inspect and photograph both apps", "cat": "Mouse", "scheme": "mouse", "key": KEY_NONE, "legend": "Ctrl+RMB"},
	"mouse_orbit":   {"label": "Orbit", "desc": "Drag (orbit camera mode) to orbit the selected tile", "cat": "Mouse", "scheme": "mouse", "key": KEY_NONE, "legend": "Drag"},
	"mouse_zoom":    {"label": "Zoom", "desc": "Mouse wheel zooms in/out", "cat": "Mouse", "scheme": "mouse", "key": KEY_NONE, "legend": "Wheel"},
}

const SCHEMA_VERSION := 1
const CONFIG_FILE := "input_config.json"

## Persisted user choices (defaults below are the first-run state).
var devices: Array[int] = [Device.KEYBOARD, Device.MOUSE]
var keyboard_type: int = KeyboardType.FUNCTION_KEYS
## action id -> KEY_* keycode. Overlays ACTIONS[id].key; empty until rebinding lands.
var rebinds: Dictionary = {}

## Where the config lives — the RavesOfQud support dir, resolved the same way the mod
## does (SpecialFolder.UserProfile + /Library/Application Support/RavesOfQud), so it's
## the same folder as overrides.json on both Windows and macOS. Resolved WITHOUT the
## renderer's tiles_dir (which only exists after a turn) so onboarding works cold.
static func support_dir() -> String:
	var home := OS.get_environment("USERPROFILE")   # Windows
	if home == "":
		home = OS.get_environment("HOME")           # macOS / Linux
	if home == "":
		return ""
	return home.path_join("Library").path_join("Application Support").path_join("RavesOfQud")

static func config_path() -> String:
	var dir := support_dir()
	return "" if dir == "" else dir.path_join(CONFIG_FILE)

## QUD'S OWN data dir (Unity persistentDataPath) — not ours. The one resolver for
## every reader of Qud's saves/options on disk; a bare HOME read is empty on Windows
## and the bundle-id path is macOS-only (Windows: AppData/LocalLow/<company>/<product>).
static func qud_data_dir() -> String:
	if OS.get_name() == "Windows":
		var up := OS.get_environment("USERPROFILE")
		return "" if up == "" else up.path_join("AppData").path_join("LocalLow") \
			.path_join("Freehold Games").path_join("CavesOfQud")
	var home := OS.get_environment("HOME")
	return "" if home == "" else home.path_join("Library").path_join("Application Support") \
		.path_join("com.FreeholdGames.CavesOfQud")

static func qud_saves_dir() -> String:
	var d := qud_data_dir()
	return "" if d == "" else d.path_join("Synced").path_join("Saves")

## The live keycode for an action: a rebind if set, else the coded default.
func key_for(action_id: String) -> int:
	if rebinds.has(action_id):
		return int(rebinds[action_id])
	var a: Dictionary = ACTIONS.get(action_id, {})
	return int(a.get("key", KEY_NONE))

func has_device(d: int) -> bool:
	return devices.has(d)

## Action ids that belong on a keyboard-layout screen for `type`: that scheme's own
## actions plus the scheme-agnostic ones, minus mouse gestures. Preserves ACTIONS order.
func keyboard_actions(type: int) -> Array[String]:
	var want := "numpad" if type == KeyboardType.NUMPAD else "kbd"
	var out: Array[String] = []
	for id in ACTIONS:
		var scheme := String(ACTIONS[id].get("scheme", "any"))
		if scheme == want or scheme == "any":
			out.append(id)
	return out

func mouse_actions() -> Array[String]:
	var out: Array[String] = []
	for id in ACTIONS:
		if String(ACTIONS[id].get("scheme", "")) == "mouse":
			out.append(id)
	return out

# --- persistence (mirrors overrides.json: read-modify-write JSON) ------------

func load_config() -> void:
	var path := config_path()
	if path == "" or not FileAccess.file_exists(path):
		return
	var raw = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var data: Dictionary = raw
	var devs = data.get("devices", [])
	if devs is Array and not (devs as Array).is_empty():
		devices = []
		for d in devs:
			devices.append(int(d))
	keyboard_type = int(data.get("keyboard_type", keyboard_type))
	var rb = data.get("rebinds", {})
	if rb is Dictionary:
		rebinds = {}
		for k in rb:
			rebinds[String(k)] = int(rb[k])

func save_config() -> void:
	var dir := support_dir()
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var out := {
		"version": SCHEMA_VERSION,
		"devices": devices,
		"keyboard_type": keyboard_type,
		"rebinds": rebinds,
	}
	var f := FileAccess.open(config_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  ") + "\n")
		f.close()

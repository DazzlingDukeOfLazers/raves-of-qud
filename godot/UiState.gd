extends Node

## First-party UI-state report for highvisor's state tree ("scene" signal — beats OCR
## guessing). Writes raves_state.json {scene, mode, popup?, ts} into the support dir:
## immediately on every change, and re-written every 2s as a freshness heartbeat
## (highvisor only trusts a recently-touched file, so a crashed Raves can't pin the
## tree to its last screen). Same file contract as the mod's qud_state.json.
##
## Callers: MainMenu (title / overlays / chargen / quit dialog), MainFrame (in_game),
## PopupOverlay (popup up/down). Scenes highvisor maps today: title, records, options,
## mods, chargen_game_mode, chargen_genotype, chargen_subtype, quit_dialog, in_game.

var _scene := "title"
var _popup := ""     # popup kind while one is up (message / yesno / menu / input)

func set_scene(scene: String) -> void:
	if scene == _scene:
		return
	_scene = scene
	# a popup cannot survive a scene change — clear it with the scene, or the report
	# claims a modal is up on a screen that never had one
	_popup = ""
	_write()

func set_popup(kind: String) -> void:
	_popup = kind
	_write()

func clear_popup() -> void:
	if _popup == "":
		return
	_popup = ""
	_write()

func _ready() -> void:
	_write()
	var t := Timer.new()
	t.wait_time = 2.0
	t.timeout.connect(_heartbeat)
	add_child(t)
	t.start()

func _path() -> String:
	return OS.get_environment("HOME").path_join("Library/Application Support/RavesOfQud/raves_state.json")

## Scenes that CANNOT be true while the main menu is the live scene root. The
## heartbeat corrects those to "title" so a crashed or stale reporter can't pin
## highvisor's tree to a screen we already left.
##
## This is deliberately a list of GAMEPLAY scenes, not a list of allowed menus. It
## used to be the other way round -- correct unless the scene is one of
## title/chargen*/quit_dialog/records/options/mods -- and every menu screen added
## afterwards was silently reverted to "title" two seconds after it opened.
## LoadGameScreen was one: it reported "loadgame" correctly, the heartbeat undid it,
## and so highvisor drove title-menu recipes at a save picker, clicked for a
## "Continue" that wasn't on screen, and failed identically on every retry until a
## restart. An allow-list you must remember to extend is a trap; this direction only
## names the handful of scenes the check actually exists for.
const GAMEPLAY_SCENES := ["in_game"]

func _is_gameplay_scene(scene: String) -> bool:
	return scene in GAMEPLAY_SCENES or scene.begins_with("status_")

## Heartbeat + change writer.
func _heartbeat() -> void:
	var root := get_tree().current_scene if get_tree() != null else null
	if root != null and root.name == "MainMenu" and _is_gameplay_scene(_scene):
		_scene = "title"
		_popup = ""
	_write()

func _write() -> void:
	# EFFECTIVE mode — a --one-to-one LOCKED run behaves 1to1 regardless of the
	# stored setting (which the lock no longer overwrites); report what's true
	var d := {"scene": _scene, "mode": "1to1" if Settings.one_to_one() else "user",
		"ts": int(Time.get_unix_time_from_system())}
	if _popup != "":
		d["popup"] = _popup
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()

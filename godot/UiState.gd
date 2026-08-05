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
	# Resolve through InputModel (USERPROFILE first, then HOME) — a bare HOME read
	# is empty on Windows, which silently wrote the heartbeat to a relative path
	# and left highvisor blind to Raves' scene on the PC.
	return InputModel.support_dir().path_join("raves_state.json")

## Heartbeat + change writer. The scene string is only as good as its reporter, so
## the heartbeat ALSO sanity-checks the live scene root: if we claim an in-game /
## status scene but the tree's current scene is the main menu, correct the report
## rather than republishing a stale value every 2s.
func _heartbeat() -> void:
	var root := get_tree().current_scene if get_tree() != null else null
	if root != null and root.name == "MainMenu" and _scene != "title" \
			and not _scene.begins_with("chargen") and _scene != "quit_dialog" \
			and _scene != "records" and _scene != "options" and _scene != "mods":
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

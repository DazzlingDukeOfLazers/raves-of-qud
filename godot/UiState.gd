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
	t.timeout.connect(_write)
	add_child(t)
	t.start()

func _path() -> String:
	return OS.get_environment("HOME").path_join("Library/Application Support/RavesOfQud/raves_state.json")

func _write() -> void:
	var d := {"scene": _scene, "mode": str(Settings.get_value("mode", "user")),
		"ts": int(Time.get_unix_time_from_system())}
	if _popup != "":
		d["popup"] = _popup
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()

extends Node

## First-party UI-state report for highvisor's state tree ("scene" signal — beats OCR
## guessing). Writes raves_state.json AND a per-process raves_state.<pid>.json (see
## _pid_path — one shared file cannot survive two Raves instances) {scene, mode, pid,
## ui_age, popup?, ts} into the support dir:
## immediately on every change, and re-written every 2s as a freshness heartbeat
## (highvisor only trusts a recently-touched file, so a crashed Raves can't pin the
## tree to its last screen). Same file contract as the mod's qud_state.json.
##
## Callers: MainMenu (title / overlays / chargen / quit dialog), MainFrame (in_game),
## PopupOverlay (popup up/down). Scenes highvisor maps today: title, records, options,
## mods, chargen_game_mode, chargen_genotype, chargen_subtype, quit_dialog, in_game.

var _scene := "title"
var _popup := ""     # popup kind while one is up (message / yesno / menu / input)
## How many popups have been RAISED this run. The kind alone cannot tell one modal from
## the next of the same kind, and Qud's quit is exactly that: "are you sure?" then "save
## first?", both kind `message`. A driver that answers the first and re-reads sees an
## unchanged (scene, popup) pair and concludes nothing happened — measured 2026-08-07,
## where it failed the quit route on a step that had in fact worked. The serial makes
## "a DIFFERENT popup is up now" observable without inventing popup ids.
var _popup_n := 0
var _snap_ts := 0    # unix time of the last APPLIED snapshot (0 = none yet):
                     # proves the wire is flowing, not just that the UI is alive

## Seconds since this process last DREW A FRAME, mirroring the field of the same name in
## the mod's qud_state.json so `hv shot --live` can gate on either app the same way.
##
## WHY A CAPTURE NEEDS THIS. A window that has stopped rendering still screenshots — the
## compositor hands back its last frame — so a stale capture is indistinguishable from a
## good one by size, format or timing. On the Qud side that produced status-screen
## captures showing the bare playfield, and a whole evening of parity numbers measured
## against them. Age is the only cheap tell, and it has to be read AT the capture.
##
## Frames DRAWN, not `_process` ticks: Godot keeps running the main loop while the window
## is minimised or fully occluded, so a process-tick counter would read healthy for
## exactly the window where the capture is stale. `Engine.get_frames_drawn()` advances
## only when a frame is actually presented.
var _frame_n := 0
var _frame_t := 0.0

func _process(_dt: float) -> void:
	var n := Engine.get_frames_drawn()
	if n != _frame_n:
		_frame_n = n
		_frame_t = Time.get_ticks_msec() / 1000.0

## Whole seconds since the last presented frame. Rounded to match qud_state.json, whose
## ui_age is an integer, so one threshold works for both apps.
func _ui_age() -> int:
	if _frame_t <= 0.0:
		return 0                      # nothing drawn yet this run; not evidence of staleness
	return int(maxf(0.0, Time.get_ticks_msec() / 1000.0 - _frame_t))

## Split in_game into zone vs parasang overview. ONLY flips between those two —
## a status screen, popup or menu owns the scene while it's up, and a snapshot
## arriving underneath it must not steal the report back.
func note_world_map(on: bool) -> void:
	if _scene == "in_game" or _scene == "world_map":
		set_scene("world_map" if on else "in_game")

func note_snapshot() -> void:
	_snap_ts = int(Time.get_unix_time_from_system())
	# no _write(): snapshots can arrive every turn — the 2s heartbeat carries it

## The current scene, for tools that annotate with it (FeedbackTool).
func scene() -> String:
	return _scene

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
	_popup_n += 1
	_write()

## Re-assert the kind of the popup ALREADY up, without counting a new raise.
##
## `_popup_n` means "popups RAISED this run", and highvisor's dismiss steps diff it to tell
## "the key I sent landed" from "nothing happened" — two consecutive confirms both report kind
## `message`, so the counter is the only thing that separates them. Bumping it on a RE-announce
## therefore forges that evidence: the mod re-broadcasts the live popup to every client on each
## connect and highvisor's own state poller connects about twice a second, so a single untouched
## modal walked popup_n from 3 to 37 in 30s (measured 2026-08-07). Any dismiss conditioned on a
## popup then saw the fingerprint change on its own within a second — i.e. that step could not
## fail, which is the whole defect class this session has been unpicking.
func ensure_popup(kind: String) -> void:
	if _popup == kind:
		return
	_popup = kind
	_write()

func clear_popup() -> void:
	if _popup == "":
		return
	_popup = ""
	_write()

func _ready() -> void:
	_sweep_dead_reports()
	_write()
	var t := Timer.new()
	t.wait_time = 2.0
	t.timeout.connect(_heartbeat)
	add_child(t)
	t.start()

## THE one support-dir resolver. It used to hardcode $HOME/Library/... — mac-only, and on
## Windows a bare $HOME is EMPTY for GUI apps, so the reports silently went to a relative path
## and nothing upstream could find them. The PC line fixed that at `_path()`; doing it here
## instead fixes the pid sidecar and the dead-report sweep at the same time, which are the two
## callers that would otherwise have stayed mac-only.
func _dir() -> String:
	return InputModel.support_dir()

func _path() -> String:
	return _dir().path_join("raves_state.json")

## PER-PROCESS report. The shared path above is ONE file with as many writers as there
## are Raves processes: three live instances (a leaked pair plus the real one) had it
## cycling in_game -> status_tinkering -> title on every 2s heartbeat, so any single read
## was a coin flip. That is what made `hv state` report a screen Raves wasn't on and
## `hv goto` "need retries" -- the reader was sampling somebody ELSE's window.
##
## So each process also writes raves_state.<pid>.json and stamps `pid` into both. A reader
## that knows which pid owns the window it is looking at reads that process's own report
## and is immune to duplicates; the shared path stays for readers that don't (and for
## anything older than this change).
func _pid_path() -> String:
	return _dir().path_join("raves_state.%d.json" % OS.get_process_id())

## Drop sidecars belonging to processes that are gone. Without this the support dir
## accumulates one file per Raves that ever ran, and a reader chasing a dead pid gets a
## stale report instead of a missing one (missing is honest; stale is a lie).
func _sweep_dead_reports() -> void:
	var d := DirAccess.open(_dir())
	if d == null:
		return
	for f in d.get_files():
		if not (f.begins_with("raves_state.") and f.ends_with(".json")):
			continue
		var mid := f.trim_prefix("raves_state.").trim_suffix(".json")
		if not mid.is_valid_int():
			continue          # the shared raves_state.json itself
		var pid := int(mid)
		if pid != OS.get_process_id() and not OS.is_process_running(pid):
			d.remove(f)

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
		"pid": OS.get_process_id(),
		"ui_age": _ui_age(),
		"ts": int(Time.get_unix_time_from_system())}
	if _popup != "":
		d["popup"] = _popup
		d["popup_n"] = _popup_n
	# `snap_ts` (PC line): when the last snapshot arrived, so a reader can tell a live
	# heartbeat from a client that is connected but receiving nothing.
	if _snap_ts > 0:
		d["snap_ts"] = _snap_ts
	# Written to BOTH the shared path and this process's own sidecar — see _pid_path().
	var payload := JSON.stringify(d)
	for p in [_path(), _pid_path()]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(payload)
			f.close()

extends Node

## QudLauncher (autoload) — binds Caves of Qud's lifecycle to Raves.
##
## When highvisor launches Raves with, as USER args (after a `--`):
##     --launch-qud <coq-exec> [coq-args...]
## this spawns Caves of Qud as a CHILD process and:
##   • makes Raves' own window borderless (this whole mode is highvisor-driven and
##     externally positioned, so both windows lose their titlebars → no overlap);
##   • kills Qud when Raves is really closed (the X / Cmd-Q).
##
## Why the kill keys off NOTIFICATION_WM_CLOSE_REQUEST specifically: that fires ONLY
## on a genuine window close. The in-app Reset button uses get_tree().quit(), which
## does NOT fire it (see Main._reset_program) — so a Reset-restart deliberately
## leaves Qud running, and the restarted instance re-adopts it (bridge already up →
## no double-spawn; PID recovered from the pidfile so a later close still kills it).
##
## The Qud exec PATH + args come FROM highvisor, never hardcoded here, so no
## macOS-specific path lands in shared Godot code (CLAUDE.md OS-seam rule).

const FLAG := "--launch-qud"
const PIDFILE := "user://qud_child.pid"

var _pid := -1
var _owns := false                    # true once we spawn OR adopt a managed Qud
var _argv: PackedStringArray = []     # [FLAG, exec, args...] — preserved for Reset re-pass


func _ready() -> void:
	var uargs := OS.get_cmdline_user_args()
	var i := uargs.find(FLAG)
	if i == -1 or i + 1 >= uargs.size():
		return                                       # not in launch-qud mode — do nothing
	_argv = uargs.slice(i)                            # from the flag onward
	_owns = true

	# Borderless: highvisor positions these windows; no titlebar to overlap.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)

	var exe := uargs[i + 1]
	var coq_args := uargs.slice(i + 2)                # everything after the exec

	if _bridge_up():
		# Qud is already running (typically a Reset-restart) — adopt it, don't
		# double-spawn. Recover its PID from the pidfile so a later close can kill it.
		_pid = _read_pidfile()
		print("QudLauncher: Qud bridge already up; adopting (pid=%d)" % _pid)
		return

	_pid = OS.create_process(exe, coq_args)
	if _pid <= 0:
		push_warning("QudLauncher: failed to spawn Qud: %s %s" % [exe, coq_args])
		_pid = -1
	else:
		_write_pidfile(_pid)
		print("QudLauncher: spawned Qud pid=%d" % _pid)


## Preserved launch args (from --launch-qud onward), so Main._reset_program can
## re-pass them and keep Qud + borderless alive across a script-reload restart.
func relaunch_args() -> PackedStringArray:
	return _argv


func _notification(what: int) -> void:
	# ONLY a real window close fires WM_CLOSE_REQUEST; the Reset button's quit()
	# does not — so Reset intentionally leaves Qud alive (see the class comment).
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _owns:
		_kill_qud()


func _kill_qud() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
		print("QudLauncher: killed Qud pid=%d" % _pid)
	_pid = -1
	_owns = false
	if FileAccess.file_exists(PIDFILE):
		DirAccess.remove_absolute(PIDFILE)


## Bounded probe (~250 ms): is the Qud bridge already listening? Used to avoid a
## double-spawn when a Reset-restart brings Raves back up while Qud still runs.
func _bridge_up() -> bool:
	var h := str(Settings.get_value("bridge_host", "127.0.0.1"))
	var p := int(Settings.get_value("bridge_port", 48710))
	var sock := StreamPeerTCP.new()
	if sock.connect_to_host(h, p) != OK:
		return false
	var up := false
	for _n in 25:
		sock.poll()
		var st := sock.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			up = true
			break
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			break
		OS.delay_msec(10)
	sock.disconnect_from_host()
	return up


func _write_pidfile(pid: int) -> void:
	var f := FileAccess.open(PIDFILE, FileAccess.WRITE)
	if f != null:
		f.store_string(str(pid))


func _read_pidfile() -> int:
	if not FileAccess.file_exists(PIDFILE):
		return -1
	var f := FileAccess.open(PIDFILE, FileAccess.READ)
	if f == null:
		return -1
	var pid := int(f.get_as_text().strip_edges())
	# Trust it only if that process is actually alive.
	return pid if (pid > 0 and OS.is_process_running(pid)) else -1

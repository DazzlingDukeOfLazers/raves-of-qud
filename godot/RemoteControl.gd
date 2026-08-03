extends RefCounted

## Remote-command channel — extracted from Main. Claude can't send keys to the Godot window, only commands
## to Qud's bridge; so Godot polls a small `godot_cmd` file (~10x/sec) that external tooling
## (tools/capture/control.py) writes lines to, and hands each command LINE to Main's handler. We execute
## then delete the file, closing the automated dev loop.
##
## This is just the CHANNEL — throttle, path resolution, read + consume. Main owns what each command DOES
## (its _exec_godot_cmd drives the screenshot / camera / multiview / onboarding). Stage 3 of the Main.gd
## decomposition. RefCounted (not a Node): Main drives poll(dt) from its _process, preserving order.

const POLL_INTERVAL := 0.1   # seconds between polls (~10x/sec)
var _accum := 0.0
var _support_dir_fn: Callable   # () -> String: the RavesOfQud data dir (renderer tiles dir, else OS support)
var _on_command: Callable       # (String) -> void: Main._exec_godot_cmd, one call per command line

func setup(support_dir_fn: Callable, on_command: Callable) -> void:
	_support_dir_fn = support_dir_fn
	_on_command = on_command

## Call once per frame from Main._process. Reads + consumes the command file on the throttle and dispatches
## each non-empty line to the handler.
func poll(dt: float) -> void:
	_accum += dt
	if _accum < POLL_INTERVAL:
		return
	_accum = 0.0
	var base: String = _support_dir_fn.call()
	if base == "":
		return
	var path := base.path_join("godot_cmd")
	if not FileAccess.file_exists(path):
		return
	var txt := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)   # consume it
	for line in txt.split("\n", false):
		_on_command.call(line.strip_edges())

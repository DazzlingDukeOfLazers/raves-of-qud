extends Node

## THE STATE GRAPH, in Raves (Ctrl+wheel) — slice 1: read-only.
##
## What it is for: the question "where are both apps right now?" was only answerable by alt-tabbing
## to highvisor's cockpit, which means leaving the thing you were looking at. This puts the same
## answer on top of Raves. It reads highvisor's canonical game tree and its live per-app state, and
## draws both apps' position in it.
##
## SLICE 1 IS READ-ONLY ON PURPOSE. Clicking a state to drive there (slice 2) and the test tree
## (slice 3) are separate, because this slice alone replaces the alt-tab and can be judged on its
## own. Design + the three slices: docs/decisions/state-tree-panel.md.
##
## THE GESTURE. Ctrl+wheel-up opens, Ctrl+wheel-down closes. It has to be claimed in `_input`:
## Main.gd's wheel branch lives in `_unhandled_input` and does not test modifiers, so without
## set_input_as_handled() the tree would open AND the camera would zoom underneath it. Autoloads see
## `_input` after the current scene but before `_unhandled_input`, which is exactly the window we
## need — and Main's own `_input` only claims Ctrl+LEFT/RIGHT clicks, so the wheel reaches us.
## A PLAIN wheel is left alone, so it still scrolls the panel (GUI pass) or zooms the camera.
##
## THE DEV GATE. highvisor is a localhost development tool and Raves is meant to become
## distributable (Phase 2). So: nothing here does anything unless the daemon actually answers on
## 48720. When it does not, Ctrl+wheel is NOT consumed and the camera zooms exactly as it always
## did — a player never sees a dead debug panel, an error, or a swallowed gesture. The probe is
## cached and refreshed in the background because it cannot be done on the main thread (see below).
##
## THREADING. Every highvisor call blocks — `gamestate` probes Qud's bridge port with a 0.4s
## connect and a 0.35s read PER APP, so doing it inline would freeze the game for over a second
## each poll. All RPC runs on a worker Thread and comes back via call_deferred. One request in
## flight at a time: overlapping polls would interleave their answers and make the highlight jump.

const REFRESH_S := 2.0        # how often the "you are here" markers re-poll while open
const PROBE_S := 30.0         # how often to re-check for a daemon while CLOSED (dev gate)
const PANEL_W_FRAC := 0.52
const PANEL_H_FRAC := 0.78

var _layer: CanvasLayer = null
var _body: RichTextLabel = null
var _head: RichTextLabel = null

var _thread: Thread = null
var _busy := false
var _daemon := false          # last known: is highvisor answering? (the dev gate)
var _since_refresh := 0.0
var _since_probe := 0.0

var _tree := {}               # last gametree response
var _states := {}             # last gamestate response: {app: {node,label,path,off,via}}
var _targets := {}            # {app: {node_id: true}} — states the graph can actually DRIVE to


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # usable while a modal has the tree paused
	_probe()


func _exit_tree() -> void:
	_join()


func is_open() -> bool:
	return _layer != null and is_instance_valid(_layer)


# --- input -------------------------------------------------------------------

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		if e.keycode == KEY_ESCAPE and is_open():
			# Only while open. Escape is CmdSystemMenu in 1:1 and belongs to the game the rest of
			# the time; an overlay may claim it, an autoload sitting idle may not.
			get_viewport().set_input_as_handled()
			close()
			return
		# F6 TOGGLES the same panel. Not a convenience: Ctrl+wheel is a MOUSE gesture, and the
		# harness (`hv key`) can drive keys reliably where a synthetic modified wheel is at the
		# mercy of whether the OS delivers the modifier flag — so without a key the panel could
		# only ever be tested by hand, and a gesture that can only be tested by hand stops being
		# tested. It is also simply the better opener once you know the panel exists.
		if e.keycode == KEY_F6 and _daemon and not TypingGuard.typing(get_viewport()):
			get_viewport().set_input_as_handled()
			if is_open():
				close()
			else:
				open()
			return
		return
	if not (e is InputEventMouseButton and e.pressed and e.ctrl_pressed):
		return
	if e.button_index != MOUSE_BUTTON_WHEEL_UP and e.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if TypingGuard.typing(get_viewport()):
		return
	if not _daemon:
		# THE GATE. Not our gesture: let it fall through to the camera zoom exactly as before.
		# Kick a probe so a daemon started mid-session is picked up without a restart.
		_probe()
		return
	get_viewport().set_input_as_handled()
	if e.button_index == MOUSE_BUTTON_WHEEL_UP:
		if not is_open():
			open()
	else:
		close()


func _process(delta: float) -> void:
	if is_open():
		_since_refresh += delta
		if _since_refresh >= REFRESH_S:
			_since_refresh = 0.0
			_refresh()
	else:
		_since_probe += delta
		if _since_probe >= PROBE_S:
			_since_probe = 0.0
			_probe()


# --- open / close ------------------------------------------------------------

## Fetch FIRST, build only on a good answer. The panel never appears empty and never appears at
## all if the daemon went away between the probe and the gesture — which is the same silence a
## shipped build gets, so there is one behaviour to reason about instead of two.
func open() -> void:
	_run(func() -> Dictionary:
		return {"tree": HighvisorClient.request("gametree"),
				"state": HighvisorClient.request("gamestate")},
		_on_opened)


func _on_opened(res: Dictionary) -> void:
	var tree := _dict(res.get("tree"))
	var state := _dict(res.get("state"))
	if not tree.get("ok", false) or not state.get("ok", false):
		_daemon = false          # it answered the probe and then did not answer this: treat as gone
		return
	_tree = _dict(tree.get("tree"))
	_states = _dict(state.get("states"))
	_index_targets()
	_build()
	_render()


func close() -> void:
	# FREED, not hidden. A hidden CanvasLayer still delivers input to its children — that is how a
	# closed overlay went on eating Esc app-wide once (docs/gotchas.md).
	if is_open():
		_layer.queue_free()
	_layer = null
	_body = null
	_head = null


func _refresh() -> void:
	_run(func() -> Dictionary:
		return {"state": HighvisorClient.request("gamestate")},
		_on_refreshed)


func _on_refreshed(res: Dictionary) -> void:
	var state := _dict(res.get("state"))
	if not state.get("ok", false):
		return                    # a missed poll is not news; keep the last good picture
	_states = _dict(state.get("states"))
	_render()


func _probe() -> void:
	_run(func() -> Dictionary:
		return {"alive": HighvisorClient.alive()},
		func(res: Dictionary) -> void: _daemon = bool(res.get("alive", false)))


# --- worker thread -----------------------------------------------------------

## Run `work` (blocking, off-thread) and hand its result to `done` on the main thread.
## Silently drops the request when one is already in flight: every caller here is a poll, and a
## queue of stale polls is worse than a skipped one.
func _run(work: Callable, done: Callable) -> void:
	if _busy:
		return
	_join()
	_busy = true
	_thread = Thread.new()
	_thread.start(func() -> void:
		var res: Dictionary = work.call()
		_finish.bind(res, done).call_deferred())


func _finish(res: Dictionary, done: Callable) -> void:
	_busy = false
	done.call(res)


func _join() -> void:
	if _thread != null:
		if _thread.is_started():
			_thread.wait_to_finish()
		_thread = null


# --- the panel ---------------------------------------------------------------

func _build() -> void:
	close()
	_layer = CanvasLayer.new()
	_layer.layer = 190        # under QudSync's toast (200) so a resync message is never hidden
	add_child(_layer)

	# A full-rect CenterContainer does the centring. Anchoring the panel itself with PRESET_CENTER
	# and then setting `position` fights the preset — the offsets it wrote get overwritten and the
	# panel lands with its CENTRE at the window's top-left corner, which is exactly what happened.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE   # only the panel itself takes the mouse
	# THE CANVASLAYER THEME TRAP (docs/gotchas.md, CLAUDE.md): a Control whose direct parent is
	# neither a Control nor a Window becomes its own theme root and silently falls back to Godot's
	# tiny built-in font — which is why the first build drew a correctly-sized panel with no
	# readable text in it. Stamping the app theme on the subtree root fixes the whole subtree.
	center.theme = UiFont.make_theme(get_viewport())
	_layer.add_child(center)

	var panel := PanelContainer.new()
	var vp := get_viewport().get_visible_rect().size
	panel.custom_minimum_size = Vector2(vp.x * PANEL_W_FRAC, vp.y * PANEL_H_FRAC)

	var sb := StyleBoxFlat.new()
	sb.bg_color = QudChrome.q8(9, 11, 12)          # Qud's near-black chrome, not the world viridian
	sb.border_color = QudChrome.q8(11, 148, 71)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	_head = RichTextLabel.new()
	_head.bbcode_enabled = true
	_head.fit_content = true
	_head.scroll_active = false
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_head)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true          # a plain wheel over the panel scrolls it (GUI pass)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_body)


func _render() -> void:
	if not is_open():
		return
	_head.text = _header()
	# Keep the scroll position across a refresh, or the every-2s poll yanks the view back to the
	# top while you are reading the bottom of the tree.
	var vs := _body.get_v_scroll_bar()
	var at := vs.value if vs != null else 0.0
	_body.text = _rows()
	if vs != null:
		vs.value = at


const C_DIM := "6b7a78"       # a state nobody is in and nothing can drive to
const C_TEXT := "b1c9c3"      # Qud's y — ordinary UI text
const C_HERE := "ffffff"
const C_QUD := "77bfcf"       # C — cyan
const C_RAVES := "00c420"     # G — green
const C_ACCENT := "cfc041"    # W — gold, for headings


func _header() -> String:
	var apps := _dict(_tree.get("apps"))
	var lines := ["[color=#%s]STATE GRAPH[/color]  [color=#%s]highvisor · read-only (slice 1)[/color]"
			% [C_ACCENT, C_DIM]]
	for app in [_APP_QUD, _APP_RAVES]:
		if not apps.has(app):
			continue
		var col := C_QUD if app == _APP_QUD else C_RAVES
		var st := _dict(_states.get(app))
		var where := "— not running" if st.get("off", true) \
				else String(st.get("label", "running · unknown screen"))
		var via := String(st.get("via", ""))
		lines.append("[color=#%s]●[/color] [color=#%s]%-6s[/color] [color=#%s]%s[/color]  [color=#%s]%s[/color]"
				% [col, col, String(apps[app].get("label", app)), C_HERE, where, C_DIM,
				   ("via " + via) if via != "" else ""])
	lines.append("[color=#%s]%d states · %d transitions · ctrl+wheel-down or Esc to close[/color]"
			% [C_DIM, _count_nodes(), _arr(_tree.get("transitions")).size()])
	return "\n".join(lines)


const _APP_QUD := "qud"
const _APP_RAVES := "raves"


func _rows() -> String:
	var root := _dict(_tree.get("root"))
	var out: Array[String] = []
	for ch in _arr(root.get("children")):
		_walk(ch, 0, out)
	return "\n".join(out)


func _walk(node: Dictionary, depth: int, out: Array[String]) -> void:
	var id := String(node.get("id", ""))
	var label := String(node.get("label", id))
	var qm := _mark(id, _dict(_states.get(_APP_QUD)), C_QUD)
	var rm := _mark(id, _dict(_states.get(_APP_RAVES)), C_RAVES)
	var here := _is_here(id, _dict(_states.get(_APP_QUD))) or _is_here(id, _dict(_states.get(_APP_RAVES)))
	# A node nothing can DRIVE to is a scoreboard-only row (the per-element 1:1 leaves). Dimming
	# them says, before slice 2 exists, which rows will ever be clickable — and makes a state that
	# SHOULD be drivable but has no inbound transition visible as a gap rather than a silence.
	var drivable: bool = _targets.get(_APP_QUD, {}).has(id) or _targets.get(_APP_RAVES, {}).has(id)
	var col := C_HERE if here else (C_TEXT if drivable else C_DIM)
	out.append("%s%s  %s[color=#%s]%s[/color]"
			% [qm, rm, "  ".repeat(depth), col, label])
	for ch in _arr(node.get("children")):
		_walk(ch, depth + 1, out)


func _is_here(id: String, st: Dictionary) -> bool:
	return not st.is_empty() and String(st.get("node", "")) == id


## ● exactly here · ┃ an ancestor of where the app is · blank otherwise. The ancestor mark matters:
## detection returns the DEEPEST match, so an app on the Journal tab reports `status_journal`, and
## without the trail its branch would look untouched.
func _mark(id: String, st: Dictionary, col: String) -> String:
	if st.is_empty() or st.get("off", false):
		return " "
	if String(st.get("node", "")) == id:
		return "[color=#%s]●[/color]" % col
	if id in _arr(st.get("path")):
		return "[color=#%s]|[/color]" % col
	return " "


# --- shape guards ----------------------------------------------------------

## THE GDSCRIPT TRAP THIS EXISTS FOR: `some_dict.get(k) or {}` does NOT do what it does in
## Python. GDScript's `or` is a BOOLEAN operator — it returns `true`/`false`, never the operand
## — so the familiar `x or default` idiom silently evaluates to `true`, and the next line either
## fails to assign it to a Dictionary or tries to iterate a bool. Every row of this panel went
## through that idiom, which is why the first build drew a correctly framed, perfectly EMPTY
## panel: the frame is Godot's, the contents were three separate runtime errors.
##
## These also survive a null or a wrong type, which a `.get(k, default)` does not — `get` only
## substitutes when the KEY IS ABSENT, so a JSON null still comes back as null. Data off the wire
## deserves the stronger guarantee.
static func _dict(v) -> Dictionary:
	return v if v is Dictionary else {}


static func _arr(v) -> Array:
	return v if v is Array else []


func _index_targets() -> void:
	_targets = {}
	for tr in _arr(_tree.get("transitions")):
		var app := String(tr.get("app", ""))
		if not _targets.has(app):
			_targets[app] = {}
		_targets[app][String(tr.get("to", ""))] = true


func _count_nodes() -> int:
	var n := [0]
	var walk := func(x, f):
		if String(x.get("id", "")) != "root":
			n[0] += 1
		for c in _arr(x.get("children")):
			f.call(c, f)
	walk.call(_dict(_tree.get("root")), walk)
	return n[0]

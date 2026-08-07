extends Node

## THE STATE GRAPH, in Raves (Ctrl+wheel / F6).
##
## What it is for: the question "where are both apps right now?" was only answerable by alt-tabbing
## to highvisor's cockpit, which means leaving the thing you were looking at. This puts the same
## answer on top of Raves. It reads highvisor's canonical game tree and its live per-app state, and
## draws both apps' position in it.
##
## Slice 1 drew the tree and both apps' position in it. Slice 2 made each row's two gutter cells
## click targets — clicking drives that app to that state, with the cost previewed on hover so a
## route that can only go via the RESTART edge is visible before you commit to it. The test tree
## (slice 3) is still separate. Design: docs/decisions/state-tree-panel.md.
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
var _costs := {}              # {app: {node_id: cost}} — what driving there would cost FROM HERE
var _status := ""             # the bottom line: hover preview, drive progress, or the last trace
var _driving := ""            # "<app>:<node>" while a gogo is in flight; "" when idle
var _drive_thread: Thread = null
var _status_label: RichTextLabel = null
var _last_nodes := {}         # {app: node} at the last cost fetch — refetch only when it moves


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
	var work := func() -> Dictionary:
		return {"tree": HighvisorClient.request("gametree"),
				"state": HighvisorClient.request("gamestate"),
				"cost_qud": HighvisorClient.request("plan_route", {"app": _APP_QUD}),
				"cost_raves": HighvisorClient.request("plan_route", {"app": _APP_RAVES})}
	_run(work, _on_opened)


func _on_opened(res: Dictionary) -> void:
	var tree := _dict(res.get("tree"))
	var state := _dict(res.get("state"))
	if not tree.get("ok", false) or not state.get("ok", false):
		print("[state-graph] open failed: tree.ok=%s state.ok=%s — treating highvisor as gone"
				% [tree.get("ok", false), state.get("ok", false)])
		_daemon = false          # it answered the probe and then did not answer this: treat as gone
		return
	_tree = _dict(tree.get("tree"))
	_states = _dict(state.get("states"))
	_index_targets()
	_take_costs(res)
	_status = "click a cell in the left gutter to drive that app there"
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


## Poll the live state. The reachability maps are re-fetched ONLY when an app has actually
## changed node: they are pure computation server-side, but they are also only wrong when the
## start state moves, and a poll that always refetches everything makes the panel the busiest
## client on the socket for no gain.
func _refresh() -> void:
	if not is_open():
		return
	var want_costs := _driving != ""
	var work := func() -> Dictionary:
		var out := {"state": HighvisorClient.request("gamestate")}
		if want_costs:
			# While a drive is in flight the start state is moving under us, so the costs are
			# worth re-reading every tick rather than only when a node change is observed.
			out["cost_qud"] = HighvisorClient.request("plan_route", {"app": _APP_QUD})
			out["cost_raves"] = HighvisorClient.request("plan_route", {"app": _APP_RAVES})
		return out
	_run(work, _on_refreshed)


func _on_refreshed(res: Dictionary) -> void:
	var state := _dict(res.get("state"))
	if not state.get("ok", false):
		return                    # a missed poll is not news; keep the last good picture
	_states = _dict(state.get("states"))
	_take_costs(res)
	if _costs_stale():
		_fetch_costs()
	_render()


## The reachability maps, keyed by app. Absent keys leave the previous map in place — a missed
## poll should not blank the greying and make every state look unreachable.
func _take_costs(res: Dictionary) -> void:
	for app in [_APP_QUD, _APP_RAVES]:
		var r := _dict(res.get("cost_" + app))
		if r.get("ok", false):
			_costs[app] = _dict(r.get("costs"))
			_last_nodes[app] = String(_dict(_states.get(app)).get("node", ""))


func _costs_stale() -> bool:
	for app in [_APP_QUD, _APP_RAVES]:
		if String(_dict(_states.get(app)).get("node", "")) != String(_last_nodes.get(app, "<never-fetched>")):
			return true
	return false


func _fetch_costs() -> void:
	if not is_open():
		return
	var work := func() -> Dictionary:
		return {"cost_qud": HighvisorClient.request("plan_route", {"app": _APP_QUD}),
				"cost_raves": HighvisorClient.request("plan_route", {"app": _APP_RAVES})}
	var done := func(res: Dictionary) -> void:
		_take_costs(res)
		_render()
	_run(work, done)


func _probe() -> void:
	var work := func() -> Dictionary:
		return {"alive": HighvisorClient.alive()}
	var done := func(res: Dictionary) -> void:
		var was := _daemon
		_daemon = bool(res.get("alive", false))
		if was != _daemon:
			# The dev gate flipping is the one thing worth a log line: it decides whether the
			# panel exists at all, and when it is wrong the symptom is a keypress that does
			# nothing — indistinguishable from a key that never arrived.
			print("[state-graph] highvisor %s" % ("reachable" if _daemon else "unreachable"))
	_run(work, done)


# --- worker thread -----------------------------------------------------------

## Run `work` (blocking, off-thread) and hand its result to `done` on the main thread.
## Silently drops the request when one is already in flight: every caller here is a poll, and a
## queue of stale polls is worse than a skipped one.
func _run(work: Callable, done: Callable) -> void:
	# Outside the tree there is nobody to run the deferred callback, so the thread would do its
	# work and then hang around waiting to hand the result to nothing — which is exactly what
	# wedged the headless test the moment a code path started re-probing. A thread whose result
	# can never be delivered should not be started.
	if _busy or not is_inside_tree():
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
	# INTERACTIVE as of slice 3. It was MOUSE_FILTER_IGNORE while it was pure decoration, and
	# that silently killed the harness-check links the moment they moved in here — hover did
	# nothing, clicks did nothing, and the panel looked fine. Same signals as the body.
	_head.meta_underlined = true       # these ARE links, unlike the body's gutter cells
	_head.meta_clicked.connect(_on_meta_clicked)
	_head.meta_hover_started.connect(_on_meta_hover)
	_head.meta_hover_ended.connect(_on_meta_unhover)
	vb.add_child(_head)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true          # a plain wheel over the panel scrolls it (GUI pass)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The gutter cells are BBCode [url] spans, which is why the whole tree can stay one
	# RichTextLabel: no per-row Control, no layout to keep in sync, and hover/click arrive as
	# signals carrying the meta string we encoded ("<app>:<node>").
	_body.meta_underlined = false
	_body.meta_clicked.connect(_on_meta_clicked)
	_body.meta_hover_started.connect(_on_meta_hover)
	_body.meta_hover_ended.connect(_on_meta_unhover)
	vb.add_child(_body)

	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.custom_minimum_size = Vector2(0, 0)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_status_label)


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
	if _status_label != null:
		_status_label.text = (_status if _status.begins_with("[color=")
				else "[color=#%s]%s[/color]" % [C_DIM, _status])


const C_DIM := "6b7a78"       # a state nobody is in and nothing can drive to
const C_TEXT := "b1c9c3"      # Qud's y — ordinary UI text
const C_HERE := "ffffff"
const C_QUD := "77bfcf"       # C — cyan
const C_RAVES := "00c420"     # G — green
const C_ACCENT := "cfc041"    # W — gold, for headings
const C_TEST := "77bfcf"      # C — cyan, the [T] run-a-check markers
const SCORE_LOW := "d74200"   # R
const SCORE_MID := "e99f10"   # O
const SCORE_HIGH := "00c420"  # G
## Column layout, in monospace character cells. Measured against the real panel: the label
## column at 58 pushed a row carrying a [T] past the right edge and RichTextLabel WRAPPED it
## onto its own line — the marker was rendered and unusable. The test marker now sits in a
## fixed column BEFORE the scores, so the scores stay flush right whether a node has a check
## or not, and the widest possible row is a constant.
const LABEL_COLS := 52        # where the fixed columns begin
const TEST_COLS := 4          # " [T]" or blank


func _header() -> String:
	var apps := _dict(_tree.get("apps"))
	var lines := ["[color=#%s]STATE GRAPH[/color]  [color=#%s]highvisor · click a gutter cell to drive[/color]"
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
	# HARNESS-WIDE checks live at the top level of the tree, not on any node — they test the
	# supervisor, not a screen, and hanging them off an arbitrary node would misdescribe what
	# they cover. Per-node checks appear as [T] on their own row instead.
	var harness := _arr(_tree.get("tests"))
	if not harness.is_empty():
		var marks := ""
		for t in harness:
			var td := _dict(t)
			marks += " [url=run::%s][color=#%s][T] %s[/color][/url]" % [
				String(td.get("id", "")), C_TEST, String(td.get("id", ""))]
		lines.append("[color=#%s]checks:[/color]%s" % [C_DIM, marks])
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
	var qm := _cell(id, _APP_QUD, C_QUD)
	var rm := _cell(id, _APP_RAVES, C_RAVES)
	var here := _is_here(id, _dict(_states.get(_APP_QUD))) or _is_here(id, _dict(_states.get(_APP_RAVES)))
	# A node nothing can DRIVE to is a scoreboard-only row (the per-element 1:1 leaves). Dimming
	# them says, before slice 2 exists, which rows will ever be clickable — and makes a state that
	# SHOULD be drivable but has no inbound transition visible as a gap rather than a silence.
	var drivable: bool = _targets.get(_APP_QUD, {}).has(id) or _targets.get(_APP_RAVES, {}).has(id)
	var col := C_HERE if here else (C_TEXT if drivable else C_DIM)
	# Pad to a fixed COLUMN so the scores line up. Safe because the panel inherits Source Code
	# Pro (Qud's own UI font) and it is monospace — the padding is counted on the PLAIN text,
	# never on the BBCode, or the markup length would shift every row differently.
	var indent := "  ".repeat(depth)
	var plain_len := indent.length() + label.length()
	var pad := " ".repeat(maxi(1, LABEL_COLS - plain_len))
	out.append("%s%s %s[color=#%s]%s[/color]%s%s%s"
			% [qm, rm, indent, col, label, pad, _test_marks(node), _scores(node)])
	for ch in _arr(node.get("children")):
		_walk(ch, depth + 1, out)


## A gutter CELL: the app's position mark, wrapped in a click target when the graph can
## actually get that app there from where it is now.
##
## Two cells per row rather than one click on the label, because "go there" is meaningless
## without saying WHICH app — and the two columns already mean Qud and Raves in slice 1, so the
## gesture reads off the existing layout instead of adding a mode. Unreachable cells are drawn
## but NOT wrapped: a click that cannot work should not look like one that can.
func _cell(id: String, app: String, col: String) -> String:
	var mark := _mark(id, _dict(_states.get(app)), col)
	var cost = _dict(_costs.get(app)).get(id)
	if mark == "":
		# Nothing to say about position. A dim dot marks a cell you CAN click; blank marks one
		# you cannot. The dot has to mean something, or the only way to learn a cell is dead is
		# to click it and watch nothing happen.
		if cost == null:
			return "  "
		mark = "[color=#%s]\u00b7[/color]" % C_DIM
	# WHERE THE APP IS is drawn regardless of reachability — position is information, and
	# conflating it with clickability once blanked the ● on the app's own node.
	if cost == null:
		return mark + " "
	return "[url=%s:%s]%s [/url]" % [app, id, mark]


## The 1:1 SCOREBOARD: each node's `done` per app, 0..1. This is the number the whole parity
## effort is tracked against, and it lived only in a JSON file and the cockpit — putting it on
## the same row as the state it describes is the point of a "test tree".
##
## Coloured by value rather than printed plain: 66 numbers in a column is a wall, but a column
## of red/amber/green is a punch-list you can read in one look.
func _scores(node: Dictionary) -> String:
	var done := _dict(node.get("done"))
	var out := ""
	for app in [_APP_QUD, _APP_RAVES]:
		if not done.has(app):
			out += "[color=#%s]  - [/color]" % C_DIM
			continue
		var v := float(done[app])
		var c := SCORE_LOW if v < 0.34 else (SCORE_MID if v < 0.75 else SCORE_HIGH)
		out += "[color=#%s]%4.1f[/color]" % [c, v]
	return out


## A click target per REGISTERED check on this node. The command itself lives in
## gametree.json — the click names WHICH check, never what to run.
func _test_marks(node: Dictionary) -> String:
	var tests := _arr(node.get("tests"))
	if tests.is_empty():
		return " ".repeat(TEST_COLS)     # hold the column so the scores stay aligned
	var td := _dict(tests[0])
	# One marker per row. A node with several checks is not a shape the tree has yet, and a
	# variable-width column would undo the alignment this layout exists for; the extras stay
	# reachable from `hv test`.
	return " [url=run:%s:%s][color=#%s][T][/color][/url]" % [
		String(node.get("id", "")), String(td.get("id", "")), C_TEST]


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
	return ""       # neither here nor on the way; _cell decides what (if anything) to draw


# --- slice 2: click to navigate ----------------------------------------------

## Cost at or above this is only achievable through the "*" -> title RESTART edge (priced 120
## in highvisor's cost table), so it is worth shouting BEFORE the click rather than after: a
## restart takes minutes and throws away whatever the app was showing.
const RESTART_COST := 100


func _split_meta(meta) -> Array:
	var parts := String(meta).split(":", true, 1)
	return parts if parts.size() == 2 else []


## Hovering a cell answers "what would this cost me?" from the reachability map already in
## hand — no round trip, so it can be instant and cannot lag behind the cursor. The cost is a
## real number out of the planner, not a guess: it is the sum of the edges it would run.
func _on_meta_hover(meta) -> void:
	if _driving != "":
		return                       # a running action owns the status line
	var t := _split_run(meta)
	if not t.is_empty():
		var td := _find_test(t[0], t[1])
		if td.is_empty():
			_set_status("no registered check %s" % t[1])
		else:
			_set_status("run check %s (%s) — %s" % [t[1], String(td.get("tier", "?")),
					String(td.get("cmd", ""))])
		return
	var p := _split_meta(meta)
	if p.is_empty():
		return
	var app: String = p[0]
	var node: String = p[1]
	var cost = _dict(_costs.get(app)).get(node)
	if cost == null:
		_set_status("%s cannot reach %s from here" % [app, node])
		return
	if int(cost) == 0:
		_set_status("%s is already at %s" % [app, node])
	elif int(cost) >= RESTART_COST:
		_set_status("drive %s -> %s   cost %d — via RESTART (minutes; the app is relaunched)"
				% [app, node, int(cost)])
	else:
		_set_status("drive %s -> %s   cost %d" % [app, node, int(cost)])


func _on_meta_unhover(_meta) -> void:
	if _driving == "":
		_set_status("click a cell in the left gutter to drive that app there")


func _on_meta_clicked(meta) -> void:
	if _driving != "":
		_set_status("already running %s — wait for it to finish" % _driving)
		return
	var t := _split_run(meta)
	if not t.is_empty():
		_run_check(t[0], t[1])
		return
	var p := _split_meta(meta)
	if p.is_empty():
		return
	_drive(p[0], p[1])


## "run:<node>:<test>" -> [node, test]; node is empty for a harness-wide check. Returns [] for
## anything else, so the drive metas ("<app>:<node>") fall through untouched.
func _split_run(meta) -> Array:
	var m := String(meta)
	if not m.begins_with("run:"):
		return []
	var rest := m.substr(4).split(":", true, 1)
	return rest if rest.size() == 2 else []


func _find_test(node_id: String, test_id: String) -> Dictionary:
	var pool: Array = _arr(_tree.get("tests")) if node_id == "" else _arr(_node_by_id(node_id).get("tests"))
	for t in pool:
		if String(_dict(t).get("id", "")) == test_id:
			return _dict(t)
	return {}


## A plain recursive function, NOT a lambda. GDScript closures capture locals BY VALUE, so the
## obvious `var found := {}` + a lambda that assigns to it writes to the lambda's own copy and
## the caller sees nothing — this returned {} for a node that was plainly in the tree.
## (`_count_nodes` gets away with a lambda only because it accumulates into an ARRAY, which is
## a reference. Same trap, hidden by the workaround.)
func _node_by_id(node_id: String, from: Variant = null) -> Dictionary:
	var here := _dict(from) if from != null else _dict(_tree.get("root"))
	if String(here.get("id", "")) == node_id:
		return here
	for c in _arr(here.get("children")):
		var hit := _node_by_id(node_id, c)
		if not hit.is_empty():
			return hit
	return {}


## Run a registered check and show its verdict plus the TAIL of its output. The tail, not the
## head: a check that fails says so at the end, and the front is the part you already know.
func _run_check(node_id: String, test_id: String) -> void:
	if _drive_thread != null and _drive_thread.is_alive():
		return
	if _drive_thread != null:
		_drive_thread.wait_to_finish()
	_driving = "check %s" % test_id
	_set_status("running %s …" % test_id)
	_drive_thread = Thread.new()
	_drive_thread.start(func() -> void:
		var r := HighvisorClient.request("run_test", {"node": node_id, "test": test_id},
				HighvisorClient.DRIVE_REPLY_MS)
		_check_done.bind(test_id, r).call_deferred())


func _check_done(test_id: String, res: Dictionary) -> void:
	_driving = ""
	if res.is_empty():
		_set_status("check %s: no answer within the wait — it may still be running" % test_id)
		return
	if not res.has("exit"):
		_set_status("check %s: %s" % [test_id, String(res.get("error", "did not run"))])
		return
	var head := "check %s: %s" % [test_id, String(res.get("detail", ""))]
	var col := SCORE_HIGH if res.get("ok", false) else SCORE_LOW
	var tail := _arr(res.get("tail"))
	var shown := tail.slice(maxi(0, tail.size() - 4))
	var body := ""
	for ln in shown:
		body += "\n[color=#%s]  %s[/color]" % [C_DIM, String(ln)]
	_set_status("[color=#%s]%s[/color]%s" % [col, head, body])


## Send the goto and report what came back. Deliberately NOT reduced to ok/fail: the step trace
## is the useful part when a route breaks — which transition, which step, and the engine's own
## error — and it is already structured, so throwing it away here would mean going back to the
## cockpit for exactly the case you opened this panel to avoid.
##
## Runs on its OWN thread rather than the shared poll slot. A goto can take minutes (a restart
## edge relaunches the app), and blocking the poller behind it would freeze the very markers
## that show it working.
func _drive(app: String, node: String) -> void:
	if _drive_thread != null and _drive_thread.is_alive():
		return
	if _drive_thread != null:
		_drive_thread.wait_to_finish()
	_driving = "%s -> %s" % [app, node]
	_set_status("driving %s …" % _driving)
	_drive_thread = Thread.new()
	_drive_thread.start(func() -> void:
		var r := HighvisorClient.request("gamego", {"app": app, "node": node},
				HighvisorClient.DRIVE_REPLY_MS)
		_drive_done.bind(app, node, r).call_deferred())


func _drive_done(app: String, node: String, res: Dictionary) -> void:
	_driving = ""
	if res.is_empty():
		# A drive that did not answer is NOT proof the daemon died — it may simply have taken
		# longer than we waited, and the app may well have arrived anyway. Declaring the daemon
		# gone here also switched the whole panel off, which is a bad way to react to a timeout.
		# Say what is actually known, re-probe, and re-read the state.
		# NB: explicit `+`. GDScript has no implicit adjacent-string concatenation — two string
		# literals side by side is a parse error, not one string.
		_set_status(("%s -> %s: no answer within the wait — it may still be running. "
				+ "Re-reading the state…") % [app, node])
		_probe()
		if is_open():
			_fetch_costs()
			_refresh()
		return
	var steps := _arr(res.get("steps"))
	var ran := 0
	var failed := []
	for st in steps:
		var d := _dict(st)
		if _dict(d.get("step")).has("verify"):
			continue                 # the per-edge arrival check, not a move the user asked for
		ran += 1
		if not d.get("ok", false):
			failed.append("%s: %s" % [_step_name(_dict(d.get("step"))),
									  String(d.get("error", "failed"))])
	var head := "%s -> %s" % [app, node]
	if res.get("ok", false):
		var detail := String(res.get("detail", ""))
		if detail != "":
			_set_status("%s: %s" % [head, detail])
		else:
			_set_status("%s: OK  (%s · %d steps)" % [head, String(res.get("route", "")), ran])
	else:
		# Name the transition that broke and the step inside it. `route` is the plan it was
		# following, which is half the diagnosis on its own.
		var why := String(res.get("error", "failed"))
		if not failed.is_empty():
			why = String(failed[0])
		_set_status("%s: FAILED — %s\n[color=#%s]plan was: %s[/color]"
				% [head, why, C_DIM, String(res.get("route", "?"))])
	# The app has moved, so the reachability maps are stale by definition — but only bother if
	# anyone is still looking. A drive can outlive the panel (they take minutes), and polling on
	# behalf of a closed overlay is pure noise on the socket.
	if is_open():
		_fetch_costs()
		_refresh()


## A step's action, for the failure line — the first key that is not a modifier.
func _step_name(step: Dictionary) -> String:
	for k in step:
		if k not in ["window", "note", "args", "timeout", "unless_running", "unless_within",
					 "offset"]:
			return String(k)
	return "step"


## The status line. Text that already carries its own [color] tags is passed through as-is —
## wrapping it in the dim default would swallow the pass/fail colour of a check result.
func _set_status(text: String) -> void:
	_status = text
	if _status_label != null:
		_status_label.text = (text if text.begins_with("[color=")
				else "[color=#%s]%s[/color]" % [C_DIM, text])


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

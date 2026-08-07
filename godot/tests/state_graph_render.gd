extends SceneTree

## SPOT test — StateGraphPanel's text generation, headless, no daemon, no apps.
##
##   Godot --headless --path godot/ --script res://tests/state_graph_render.gd
##
## WHY IT EXISTS. The panel's first live build drew a correctly framed, perfectly EMPTY box. The
## frame is Godot's, so it looked like a layout or theme problem; it was three separate runtime
## errors inside the text builders, invisible because a RichTextLabel handed nothing just draws
## nothing. Each round of guessing at it cost a two-minute export. This reproduces the whole
## rendering path from a fixture in about a second, and it found the bug on its first run:
##
##   GDScript's `or` is a BOOLEAN operator. `some_dict.get(k) or {}` — the Python idiom — does not
##   return the operand, it returns `true`. Every `for x in (d.get(k) or [])` in the panel was
##   iterating a bool.
##
## So the assertions below are deliberately about SHAPE, not appearance: rows exist, one per node,
## the markers land on the right nodes. Appearance still needs a screenshot; this does not pretend
## otherwise. It covers the half that a screenshot is a terrible way to debug.
##
## The fixture is inline so the test is dependency-free (it must run on the PC branch, where the
## highvisor checkout may not exist). When highvisor IS next door, its REAL gametree.json is
## exercised too — that is the input that actually ships, and it is the one that would drift.

const HV_TREE := "/Users/homefolder/personal-git/highvisor/highvisor/gametree.json"

var _failed: Array[String] = []


func _init() -> void:
	var sgp = load("res://StateGraphPanel.gd").new()
	_fixture(sgp)
	_slice2(sgp)
	_slice3(sgp)
	_real(sgp)
	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
	# FREE it. StateGraphPanel extends Node, so `.new()` hands back an unparented object that
	# nothing will collect — Godot then reports "resources still in use at exit" and dumps a
	# crash backtrace AFTER a clean pass. A test whose success looks like a segfault is a test
	# people stop trusting.
	sgp.free()
	quit(1 if not _failed.is_empty() else 0)


func _check(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok   %s" % name)
	else:
		print("  FAIL %s%s" % [name, ("  — " + detail) if detail != "" else ""])
		_failed.append(name)


const FIXTURE := {
	"apps": {"qud": {"label": "Qud"}, "raves": {"label": "Raves"}},
	"transitions": [
		{"app": "qud", "from": "title", "to": "in_game"},
		{"app": "raves", "from": "title", "to": "in_game"},
	],
	"root": {"id": "root", "children": [
		{"id": "title", "label": "Title Screen", "children": [
			{"id": "logo", "label": "Logo"},
		]},
		{"id": "in_game", "label": "In-Game", "children": [
			{"id": "world", "label": "Play Field"},
		]},
	]},
}


func _fixture(sgp) -> void:
	print("fixture tree")
	sgp._tree = FIXTURE.duplicate(true)
	sgp._states = {
		"qud": {"node": "world", "path": ["in_game", "world"], "off": false,
				"label": "Play Field", "via": "scene"},
		"raves": {"node": "title", "path": ["title"], "off": false,
				  "label": "Title Screen", "via": "scene"},
	}
	sgp._index_targets()

	var head: String = sgp._header()
	_check("header is non-empty", head.length() > 0)
	_check("header names both apps", head.contains("Qud") and head.contains("Raves"), head)
	_check("header reports each app's screen",
		head.contains("Play Field") and head.contains("Title Screen"), head)

	var rows: String = sgp._rows()
	var lines := rows.split("\n")
	_check("one row per node", lines.size() == 4, "%d rows: %s" % [lines.size(), rows])
	_check("rows carry the labels",
		rows.contains("Title Screen") and rows.contains("Play Field"), rows)

	# The markers are the whole point of the panel, so assert WHICH row they land on.
	var by_label := {}
	for ln in lines:
		for key in ["Title Screen", "Logo", "In-Game", "Play Field"]:
			if ln.contains(key):
				by_label[key] = ln
	_check("qud ● is on its exact node", by_label.get("Play Field", "").contains("●"),
		String(by_label.get("Play Field", "")))
	_check("qud ancestor gets the trail mark, not a ●",
		by_label.get("In-Game", "").contains("|") and not by_label.get("In-Game", "").contains("●"),
		String(by_label.get("In-Game", "")))
	_check("an untouched branch has neither mark",
		not by_label.get("Logo", "").contains("●") and not by_label.get("Logo", "").contains("|"),
		String(by_label.get("Logo", "")))

	# A node no transition can reach is drawn dim — it is a scoreboard row, never clickable.
	_check("a drivable node and a scoreboard node differ in colour",
		by_label.get("In-Game", "").contains(sgp.C_TEXT)
		and by_label.get("Logo", "").contains(sgp.C_DIM),
		"%s / %s" % [by_label.get("In-Game", ""), by_label.get("Logo", "")])

	_check("node count matches the tree", sgp._count_nodes() == 4, str(sgp._count_nodes()))

	# The regression that started all this: an EMPTY or malformed tree must render an honest empty
	# panel, not throw three errors into the void.
	sgp._tree = {}
	sgp._states = {}
	sgp._index_targets()
	_check("an empty tree still produces a header", sgp._header().length() > 0)
	_check("an empty tree produces no rows", sgp._rows() == "")
	sgp._tree = {"root": null, "apps": null, "transitions": null}
	sgp._index_targets()
	_check("null members do not throw", sgp._header().length() > 0 and sgp._rows() == "")


func _slice2(sgp) -> void:
	print("\nslice 2 — click targets, costs, failure reporting")
	sgp._tree = FIXTURE.duplicate(true)
	sgp._states = {
		"qud": {"node": "title", "path": ["title"], "off": false, "label": "Title", "via": "scene"},
		"raves": {"node": "title", "path": ["title"], "off": false, "label": "Title", "via": "scene"},
	}
	sgp._index_targets()
	# in_game costs 6 to reach; `logo` is a scoreboard node with no inbound transition at all.
	sgp._costs = {"qud": {"title": 0, "in_game": 6}, "raves": {"title": 0, "in_game": 130}}
	sgp._driving = ""

	var rows: String = sgp._rows()
	_check("a reachable cell is a click target",
		rows.contains("[url=qud:in_game]"), rows)
	_check("an UNREACHABLE cell is drawn but not clickable",
		not rows.contains("[url=qud:logo]") and not rows.contains("[url=raves:logo]"), rows)
	_check("the app already there is still clickable (goto is idempotent)",
		rows.contains("[url=qud:title]"), rows)

	# The dot is the affordance: it must appear only where a click would do something, or the
	# only way to learn a cell is dead is to click it and watch nothing happen.
	var by_row := {}
	for ln in rows.split("\n"):
		for key in ["In-Game", "Logo"]:
			if ln.contains(key):
				by_row[key] = ln
	_check("a clickable cell draws a mark", String(by_row.get("In-Game", "")).contains("\u00b7")
		or String(by_row.get("In-Game", "")).contains("●"), String(by_row.get("In-Game", "")))
	_check("an unreachable cell draws NO mark",
		not String(by_row.get("Logo", "")).contains("\u00b7"), String(by_row.get("Logo", "")))

	# Hover reads the cost straight out of the map — no round trip, so it cannot lag the cursor.
	sgp._on_meta_hover("qud:in_game")
	_check("hover names the app, target and cost",
		sgp._status.contains("qud") and sgp._status.contains("in_game")
		and sgp._status.contains("6"), sgp._status)
	sgp._on_meta_hover("qud:title")
	_check("hover says so when the app is already there",
		sgp._status.to_lower().contains("already"), sgp._status)
	# The one that matters before you click: cost >= 100 means it routes through the restart
	# edge, i.e. minutes and the app relaunched.
	sgp._on_meta_hover("raves:in_game")
	_check("hover WARNS when the only route is a restart",
		sgp._status.to_upper().contains("RESTART"), sgp._status)
	sgp._on_meta_hover("qud:logo")
	_check("hover says plainly when there is no route",
		sgp._status.to_lower().contains("cannot reach"), sgp._status)

	_check("a malformed meta is ignored, not crashed on", sgp._split_meta("nonsense").is_empty())
	_check("a well-formed meta splits into app + node",
		sgp._split_meta("raves:status_skills") == ["raves", "status_skills"])

	# A drive in flight must not be stomped by a second click, and the hover preview must not
	# scribble over the progress line.
	sgp._driving = "qud -> in_game"
	sgp._on_meta_clicked("raves:title")
	# "already running", not "already driving" — the same guard now covers a check run too.
	_check("a second click while an action is in flight is refused, with a reason",
		sgp._status.to_lower().contains("already running"), sgp._status)
	sgp._on_meta_hover("qud:in_game")
	_check("hover does not overwrite the in-flight status",
		sgp._status.to_lower().contains("already running"), sgp._status)
	sgp._driving = ""

	# The failure path is the reason the trace is kept at all — it must name the transition and
	# the step, not collapse to "failed".
	sgp._drive_done("raves", "in_game", {
		"ok": false, "route": "title -> in_game (18)",
		"error": "raves:title->in_game#27: ocr failed",
		"steps": [
			{"step": {"activate": "Raves of Qud"}, "ok": true},
			{"step": {"click_text": "Continue", "window": "Raves of Qud"}, "ok": false,
			 "error": "text 'continue' not on screen"},
		]})
	_check("a failed drive reports the failing STEP, not just ok/fail",
		sgp._status.contains("click_text") and sgp._status.contains("not on screen"), sgp._status)
	_check("a failed drive also shows the plan it was following",
		sgp._status.contains("title -> in_game"), sgp._status)

	sgp._drive_done("qud", "status_skills", {
		"ok": true, "route": "in_game -> status_screens (5) -> status_skills (1)",
		"steps": [{"step": {"bridge": "statustab"}, "ok": true},
				  {"step": {"verify": {"node": "status_skills"}}, "ok": true}]})
	_check("a successful drive reports the route it took",
		sgp._status.contains("status_skills") and not sgp._status.contains("FAILED"),
		sgp._status)

	# A drive that times out must not switch the panel off: the daemon may be perfectly fine and
	# the goto may have SUCCEEDED (it did, the first time this happened — Qud moved and the panel
	# said "no answer from highvisor").
	sgp._daemon = true
	sgp._drive_done("qud", "status_skills", {})
	_check("a timed-out drive does not declare the daemon dead", sgp._daemon, str(sgp._daemon))
	_check("a timed-out drive says it may still be running",
		sgp._status.to_lower().contains("may still be running"), sgp._status)

	_check("step naming skips modifier keys",
		sgp._step_name({"window": "x", "note": "y", "key": "f6"}) == "key",
		sgp._step_name({"window": "x", "note": "y", "key": "f6"}))


func _slice3(sgp) -> void:
	print("\nslice 3 — scores and registered checks")
	var tree: Dictionary = FIXTURE.duplicate(true)
	tree["tests"] = [{"id": "plan", "tier": "spot", "cmd": "python3 tools/selftest_plan.py"}]
	tree["root"]["children"][1]["done"] = {"qud": 1.0, "raves": 0.3}
	tree["root"]["children"][1]["tests"] = [
		{"id": "typing_guard", "tier": "spot", "cmd": "python3 tools/regression/typing_guard_audit.py"}]
	tree["root"]["children"][0]["done"] = {"qud": 1.0, "raves": 0.9}
	sgp._tree = tree
	sgp._states = {"qud": {"node": "title", "path": ["title"], "off": false, "via": "scene"},
				   "raves": {"node": "title", "path": ["title"], "off": false, "via": "scene"}}
	sgp._index_targets()
	sgp._costs = {"qud": {"title": 0, "in_game": 6}, "raves": {"title": 0, "in_game": 6}}
	sgp._driving = ""

	var head: String = sgp._header()
	_check("harness checks are offered in the header",
		head.contains("[url=run::plan]"), head)

	var rows: String = sgp._rows()
	var by := {}
	for ln in rows.split("\n"):
		for key in ["Title Screen", "In-Game", "Logo"]:
			if ln.contains(key):
				by[key] = ln
	_check("a node's done scores are rendered",
		String(by.get("In-Game", "")).contains("1.0") and String(by.get("In-Game", "")).contains("0.3"),
		String(by.get("In-Game", "")))
	_check("a low score is coloured differently from a high one",
		String(by.get("In-Game", "")).contains(sgp.SCORE_LOW)
		and String(by.get("In-Game", "")).contains(sgp.SCORE_HIGH),
		String(by.get("In-Game", "")))
	_check("a node with no done shows a placeholder, not a number",
		String(by.get("Logo", "")).contains("-"), String(by.get("Logo", "")))
	_check("a node with a registered check gets a [T] click target",
		String(by.get("In-Game", "")).contains("[url=run:in_game:typing_guard]"),
		String(by.get("In-Game", "")))
	_check("a node with no check gets no [T]",
		not String(by.get("Title Screen", "")).contains("[url=run:"),
		String(by.get("Title Screen", "")))

	# The score columns only line up if the padding counts PLAIN text; a regression here would
	# make every row's numbers land in a different place.
	var cols := []
	for key in ["Title Screen", "In-Game"]:
		var ln: String = by.get(key, "")
		# The test marker is a LITERAL "[T]", which the naive stripper below would eat as if it
		# were a tag — that made an aligned row measure 3 short and look like a layout bug.
		# Swap it for something unbracketed first.
		ln = ln.replace("[T]", "@T@")
		# strip bbcode, then find where the score field starts
		var plain := ""
		var inside := false
		for i in ln.length():
			var ch := ln[i]
			if ch == "[":
				inside = true
			elif ch == "]":
				inside = false
			elif not inside:
				plain += ch
		cols.append(plain.rstrip(" ").length())
	_check("score columns align across rows of different label length",
		cols.size() == 2 and absi(cols[0] - cols[1]) <= 1, str(cols))

	_check("a run meta splits into node + test",
		sgp._split_run("run:in_game:typing_guard") == ["in_game", "typing_guard"])
	_check("a harness run meta has an empty node",
		sgp._split_run("run::plan") == ["", "plan"])
	_check("a drive meta is NOT mistaken for a run",
		sgp._split_run("qud:in_game").is_empty())

	sgp._on_meta_hover("run:in_game:typing_guard")
	_check("hovering a check shows the command it would run",
		sgp._status.contains("typing_guard_audit.py"), sgp._status)

	sgp._check_done("typing_guard", {"ok": true, "exit": 0, "detail": "passed in 0.4s",
		"tail": ["OK: every _input key dispatcher is guarded or explicitly exempt."]})
	_check("a passing check reports pass + its tail",
		sgp._status.contains("passed") and sgp._status.contains("OK:"), sgp._status)
	sgp._check_done("plan", {"ok": false, "exit": 1, "detail": "FAILED (exit 1)",
		"tail": ["  FAIL qud: all 17 targets reachable", "FAILED (1 checks failed)"]})
	_check("a failing check reports FAILED and is coloured as such",
		sgp._status.contains("FAILED") and sgp._status.contains(sgp.SCORE_LOW), sgp._status)
	sgp._check_done("plan", {"ok": false, "error": "no registered test 'plan' on 'the harness'"})
	_check("an unknown check reports the lookup error, not a crash",
		sgp._status.contains("no registered test"), sgp._status)


func _real(sgp) -> void:
	if not FileAccess.file_exists(HV_TREE):
		print("\nreal gametree.json — SKIPPED (no highvisor checkout at %s)" % HV_TREE)
		return
	print("\nreal gametree.json")
	var f := FileAccess.open(HV_TREE, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	_check("parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	sgp._tree = parsed
	sgp._states = {"qud": {"node": "status_journal", "off": false, "label": "journal",
						   "path": ["in_game", "status_screens", "status_journal"], "via": "tab"},
				   "raves": {"node": "in_game", "off": false, "label": "In-Game",
							 "path": ["in_game"], "via": "scene"}}
	sgp._index_targets()
	var rows: String = sgp._rows()
	var n := rows.split("\n").size()
	_check("every node gets a row", n == sgp._count_nodes(), "%d rows vs %d nodes" % [n, sgp._count_nodes()])
	_check("the tree is not trivially small", sgp._count_nodes() > 20, str(sgp._count_nodes()))
	_check("both apps have drivable targets",
		sgp._targets.has("qud") and sgp._targets.has("raves")
		and sgp._targets["qud"].size() > 5 and sgp._targets["raves"].size() > 5,
		str(sgp._targets.keys()))
	_check("the marked node appears exactly once",
		rows.count("●") == 2, "%d ● marks (expect one per app)" % rows.count("●"))
	print("  ---- first rows ----")
	for ln in rows.split("\n").slice(0, 5):
		print("  " + ln)

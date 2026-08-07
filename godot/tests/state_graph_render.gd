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
	_real(sgp)
	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
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

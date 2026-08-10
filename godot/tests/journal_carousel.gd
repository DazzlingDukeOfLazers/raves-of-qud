extends Node

## SPOT test — a click on the journal's category carousel selects THAT cell's sub-tab.
##
##   Godot --headless --path godot/ --quit-after 400 res://tests/journal_carousel.tscn
##
## Run as a SCENE (the pane reaches for autoloads — see popup_overlay_render.gd).
##
## WHY IT EXISTS. The carousel is owner-drawn: one Control paints seven cells and the hit rects
## are whatever `_draw_carousel` appended on its last pass. Nothing on screen distinguishes "the
## rects match the paint" from "the rects are one pitch off" — both look like seven icons in a row,
## and the second opens the wrong sub-tab, which is worse than opening none. It is the same failure
## the nearby-row test exists for, one screen along.
##
## It also pins the two things a later parity nudge would quietly break: the run stays centred on
## 960 (Qud's CategoryBar centres it in the gap the top rule leaves at 726..1193), and the gaps
## BETWEEN cells resolve to nothing rather than to a neighbour.

var _failed: Array[String] = []
var _pane: Control

const TABS := ["Locations", "Gossip and Lore", "Sultan Histories", "Village Histories",
	"Chronology", "General Notes", "Recipes"]


func _ready() -> void:
	_pane = load("res://StatusPaneJournal.gd").new()
	add_child(_pane)
	_pane.size = Vector2(1920, 1080)
	var tabs: Array = []
	for t in TABS:
		tabs.append({"id": t, "name": t, "entries": [], "count": 0,
			"empty": " No entries found.", "usesMap": false, "usesCategories": false})
	_pane.setup({"tabs": tabs}, {"y": "#b1c9c3", "g": "#009403"})
	await get_tree().process_frame
	await get_tree().process_frame

	var bar: RefCounted = load("res://QudFilterBar.gd").new()
	var n := TABS.size()
	var x0: float = bar.run_left(n, 960.0) + bar.BADGE.x + bar.BADGE_GAP

	# The run is centred. Qud's own container lands at x=763 for seven cells (probed off the live
	# CategoryBar), and that has to fall out of the layout arithmetic rather than be pinned here.
	_eq(x0, 763.0, "first cell x")
	_eq(x0 + bar.cells_width(n), 1157.0, "container right edge")

	# Every cell resolves to its OWN tab, at the centre and at both horizontal edges.
	for i in n:
		var r: Rect2 = bar.cell_rect(x0, i)
		for probe in [r.get_center(), Vector2(r.position.x + 1, r.get_center().y),
				Vector2(r.end.x - 1, r.get_center().y)]:
			var got: Dictionary = _pane.feedback_element_at(probe)
			if str(got.get("label", "")) != "carousel · " + TABS[i]:
				_failed.append("cell %d at %s -> '%s'" % [i, probe, got.get("label", "(none)")])

	# …and the 12px gap between two cells resolves to NOTHING. A hit test built from a pitch
	# instead of the cell width passes every assertion above and still swallows the gaps.
	var g := Vector2(x0 + bar.CELL_W + 6.0, bar.CELL_Y + bar.CELL_H * 0.5)
	var gap: Dictionary = _pane.feedback_element_at(g)
	if not gap.is_empty():
		_failed.append("gap between cells 0 and 1 resolved to '%s'" % gap.get("label", "?"))

	# The badges are hit-tested but INERT: they report, and a click on one changes nothing.
	var qb: Dictionary = _pane.feedback_element_at(
		Vector2(bar.run_left(n, 960.0) + 4.0, bar.BADGE_Y + 4.0))
	if str(qb.get("label", "")) != "carousel · [Q]":
		_failed.append("Q badge -> '%s'" % qb.get("label", "(none)"))
	_click(Vector2(bar.run_left(n, 960.0) + 4.0, bar.BADGE_Y + 4.0))
	_eq(float(_pane._tab), 0.0, "a click on [Q] leaves the tab alone")

	# A click selects, and resets the selection and scroll with it.
	_pane._sel = 3
	_pane._scroll = 120.0
	_click((bar.cell_rect(x0, 4) as Rect2).get_center())
	_eq(float(_pane._tab), 4.0, "click on cell 4 selects tab 4")
	_eq(float(_pane._sel), 0.0, "selection resets with the tab")
	_eq(_pane._scroll, 0.0, "scroll resets with the tab")

	# Q/E go through the SAME path, so they cannot drift from the click.
	var e := InputEventKey.new()
	e.keycode = KEY_E
	e.pressed = true
	_pane.handle_key(e)
	_eq(float(_pane._tab), 5.0, "E advances")
	e.keycode = KEY_Q
	_pane.handle_key(e)
	_eq(float(_pane._tab), 4.0, "Q goes back")

	if _failed.is_empty():
		print("journal_carousel: OK")
	else:
		for f in _failed:
			print("journal_carousel: FAIL ", f)
	get_tree().quit(0 if _failed.is_empty() else 1)


func _click(p: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = p
	_pane.handle_mouse(e)


func _eq(got: float, want: float, what: String) -> void:
	if absf(got - want) > 0.01:
		_failed.append("%s: got %s want %s" % [what, got, want])

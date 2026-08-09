extends Node

## SPOT test — a click on a Nearby Objects row resolves to THAT row's object id.
##
##   Godot --headless --path godot/ res://tests/nearby_rows.tscn
##
## Run as a SCENE (the panel reaches for autoloads — see popup_overlay_render.gd).
##
## WHY IT EXISTS. Qud's nearby list is interactive: NearbyItemsWindow.OnSelect twiddles the
## object the row was drawn from. Ours was display-only, and the fix is a hit-test — arithmetic
## over ROW0_TOP/ROW_H that is invisible from a screenshot and silently off by one row if either
## constant moves. Getting it wrong does not look broken; it opens the menu for the WRONG object,
## which is worse than opening none. So the mapping is asserted per row, at both edges of each,
## and the non-row parts of the panel are asserted to resolve to nothing at all.

var _failed: Array[String] = []
var _panel: Control


func _ready() -> void:
	_panel = load("res://NearbyObjects.gd").new()
	add_child(_panel)
	_panel.size = Vector2(300, 400)
	_panel.set_one_to_one(true)
	_panel.set_snapshot({
		"palette": {"y": "#b1c9c3"}, "tilesDir": "",
		"player": {"x": 40, "y": 12}, "cells": [],
		"nearby": [
			{"id": "aaa", "name": "fulcrete", "dir": "N", "arrow": "↑"},
			{"id": "bbb", "name": "waterskin", "dir": "SE", "arrow": "↘", "weight": 3},
			{"id": "ccc", "name": "glowpad", "dir": "W", "arrow": "←"},
		],
	})

	var top: float = _panel.ROW0_TOP_1TO1
	var h: float = _panel.ROW_H_1TO1
	var x: float = float(_panel.SEP_MARGIN_1TO1) + 40.0
	await get_tree().process_frame
	await get_tree().process_frame
	# The hit-test translates panel-local y into LIST-local y, and in 1:1 that offset is currently
	# ZERO — the heading is drawn on the list surface at Qud's own baseline (so `_title` is hidden)
	# and the 1:1 panel box has no top margin, which puts `_list` at the panel's origin. Stated as
	# an assertion rather than left implicit: the row assertions below cannot tell a correct
	# translation from a missing one while it is 0 (checked — deleting the term passes them all),
	# so this is the check that notices if the layout ever gives the list an offset again.
	var dy: float = _panel._list.global_position.y - _panel.global_position.y
	_check("1:1 puts the list at the panel origin (the hit-test's translation is a no-op today)",
		absf(dy) < 0.01, "list offset %.1f — the translation now MATTERS; exercise it here" % dy)

	for i in 3:
		var want: String = ["aaa", "bbb", "ccc"][i]
		# just inside the top edge, the middle, and just inside the bottom edge of row i
		for off in [1.0, h * 0.5, h - 1.0]:
			var got: String = _panel._row_id_at(Vector2(x, dy + top + i * h + off))
			_check("row %d at +%.0fpx -> %s" % [i, off, want], got == want, "got %s" % got)

	# …and everything that is NOT a row resolves to nothing.
	_check("the heading is not a row", _panel._row_id_at(Vector2(x, dy + top - 4.0)) == "")
	_check("below the last row is not a row",
		_panel._row_id_at(Vector2(x, dy + top + 3.0 * h + 4.0)) == "")
	_check("the ||| grab bar is not a row (it drags)",
		_panel._row_id_at(Vector2(4.0, dy + top + h * 0.5)) == "")
	_panel.set_one_to_one(false)
	_check("user mode has no Qud rows to hit",
		_panel._row_id_at(Vector2(x, dy + top + h * 0.5)) == "")

	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _check(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok   %s" % name)
	else:
		print("  FAIL %s%s" % [name, "  — " + detail if detail != "" else ""])
		_failed.append(name)

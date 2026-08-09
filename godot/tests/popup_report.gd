extends Node

## SPOT test — the popup REPORT survives more than one popup being up.
##
##   Godot --headless --path godot/ res://tests/popup_report.tscn
##
## WHY IT EXISTS. Three overlays raise popups — Qud's mirrored modals (PopupOverlay, layer 130),
## the item picker (129) and the feedback note (FeedbackTool, 120) — and they all wrote one
## string. Whoever moved last spoke for all of them, so closing a Qud popup wiped the feedback
## form's report while the form was still on screen and being typed into. Reported as
## "raves_state.json drops popup: feedback", and it makes `hv assert --popup feedback` a coin flip.
##
## Reads UiState directly rather than the file: the file is the same values one _write() later,
## and going through it would only add a disk round-trip to what is a bookkeeping question.

var _failed: Array[String] = []


func _ready() -> void:
	UiState.set_scene("in_game")
	for src in ["qud", "picker", "feedback"]:
		UiState.clear_popup(src)
	_check("nothing up -> no popup reported", UiState._popup_kind() == "")

	# THE REAL LAYERS, read off the overlays themselves rather than copied here — a report that
	# ranks by layer is only as honest as the numbers, and the last time they were written down by
	# hand the note said "above game popups" over a 120 that sat under PopupOverlay's 130.
	var pov := PopupOverlay.new()
	add_child(pov)
	var qud_layer: int = pov.layer
	var fb_layer: int = FeedbackTool.layer
	pov.queue_free()
	_check("the note form really does draw above Qud's modals (%d > %d)" % [fb_layer, qud_layer],
		fb_layer > qud_layer, "feedback %d, popup %d — a Qud modal covers the form" % [fb_layer, qud_layer])

	# The form goes up on its own: reported.
	UiState.set_popup("feedback", "feedback", fb_layer, true)
	_check("the note form is reported", UiState._popup_kind() == "feedback", UiState._popup_kind())

	# A Qud modal opens under it: the form is still what the viewer is looking at.
	UiState.set_popup("qud", "menu", qud_layer)
	_check("a Qud modal under the form does not steal the report",
		UiState._popup_kind() == "feedback", UiState._popup_kind())

	# …and when the Qud modal closes, the form is STILL UP. This is the bug.
	UiState.clear_popup("qud")
	_check("closing the Qud modal leaves the form reported",
		UiState._popup_kind() == "feedback",
		"got %s — one source cleared another's report" % UiState._popup_kind())

	# The picker is a third source and clears only itself. Ranked by ITS layer, under the form.
	UiState.set_popup("picker", "itempicker", 129)
	_check("the picker ranks under the form too", UiState._popup_kind() == "feedback",
		UiState._popup_kind())
	UiState.clear_popup("picker")
	_check("…and clearing it leaves the form", UiState._popup_kind() == "feedback", UiState._popup_kind())

	# A SCENE CHANGE kills the screen's own modals but not an autoload overlay.
	UiState.set_popup("qud", "message", qud_layer)
	UiState.set_scene("status_skills")
	_check("a scene change drops the screen's modal",
		UiState._popup_kind() == "feedback", UiState._popup_kind())
	UiState.clear_popup("feedback")
	_check("…and the form clears itself", UiState._popup_kind() == "")

	# popup_n counts RAISES, and a re-assert of the same kind is not one (highvisor diffs it).
	UiState.set_scene("in_game")
	var n0: int = UiState._popup_n
	UiState.set_popup("qud", "input", qud_layer)
	UiState.ensure_popup("qud", "input", qud_layer)
	UiState.ensure_popup("qud", "input", qud_layer)
	_check("popup_n counts one raise, not three re-asserts", UiState._popup_n == n0 + 1,
		"%d -> %d" % [n0, UiState._popup_n])
	UiState.clear_popup("qud")

	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _check(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok   %s" % name)
	else:
		print("  FAIL %s%s" % [name, "  — " + detail if detail != "" else ""])
		_failed.append(name)

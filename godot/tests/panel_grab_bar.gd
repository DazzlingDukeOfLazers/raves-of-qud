extends Node

## SPOT test — the ||| grab-bar's resize CURSOR covers the bar and nothing else.
##
##   Godot --headless --path godot/ res://tests/panel_grab_bar.tscn
##
## Run as a SCENE (the panels reach for autoloads; --script has none — see popup_overlay_render.gd).
##
## WHY IT EXISTS. `mouse_default_cursor_shape` is per-CONTROL, so setting it for the 20px bar set it
## for the whole panel: every row of Nearby Objects and every line of the message log showed a
## horizontal-resize cursor, over a drag that only the left edge performs. Reported from use as
## "I can't select nearby objects — the resize icon dominates", which is what a cursor promising the
## wrong gesture does. A child strip the width of the bar carries the cursor now.
##
## The panel's own shape is asserted too, not just the strip's: leaving HSIZE on the panel would
## look identical on screen while making the strip pointless.

const BAR_W := 20.0     # SEP_MARGIN_1TO1 in both panels

var _failed: Array[String] = []


func _ready() -> void:
	for entry in [["Nearby objects", "res://NearbyObjects.gd"], ["Message log", "res://MessageLog.gd"]]:
		_panel(String(entry[0]), String(entry[1]))
	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _check(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok   %s" % name)
	else:
		print("  FAIL %s%s" % [name, "  — " + detail if detail != "" else ""])
		_failed.append(name)


func _panel(label: String, path: String) -> void:
	var p: Control = load(path).new()
	add_child(p)
	p.size = Vector2(300, 400)
	p.set_one_to_one(true)

	# The panel itself must NOT claim to be a resize handle — this is the actual bug.
	_check("%s: the PANEL is not a resize cursor" % label,
		p.mouse_default_cursor_shape == Control.CURSOR_ARROW,
		"panel cursor %d (CURSOR_HSIZE is %d)" % [p.mouse_default_cursor_shape, Control.CURSOR_HSIZE])

	var bar: Control = p.get_node_or_null("GrabBar")
	_check("%s: the bar has its own hit strip" % label, bar != null,
		"no GrabBar child — the cursor would have to live on the whole panel")
	if bar == null:
		p.queue_free()
		return
	_check("%s: …carrying the resize cursor" % label,
		bar.mouse_default_cursor_shape == Control.CURSOR_HSIZE, str(bar.mouse_default_cursor_shape))
	_check("%s: …only as wide as the bar" % label, absf(bar.offset_right - BAR_W) < 0.01,
		"offset_right %.1f, expected %.1f" % [bar.offset_right, BAR_W])
	_check("%s: …and passing clicks through to the panel's drag handler" % label,
		bar.mouse_filter == Control.MOUSE_FILTER_PASS, str(bar.mouse_filter))
	# 1:1 only: there is no grab-bar in user mode, so there is nothing to resize and nothing to say.
	p.set_one_to_one(false)
	_check("%s: the strip is gone in user mode" % label, not bar.visible)
	p.set_one_to_one(true)
	_check("%s: …and back, without stacking a second one" % label,
		bar.visible and p.get_children().filter(func(c): return c.name == "GrabBar").size() == 1)
	p.queue_free()

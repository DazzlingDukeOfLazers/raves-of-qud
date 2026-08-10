extends Node

## SPOT test — PopupOverlay actually SHOWS a mirrored popup, headless, no daemon, no apps.
##
##   Godot --headless --path godot/ res://tests/popup_overlay_render.tscn
##
## Run as a SCENE, not with `--script`: PopupOverlay references the `UiState` autoload, and
## `--script` starts a bare SceneTree with no autoloads registered, so the script cannot even
## compile ("Identifier not found: UiState" — the same false positive `--check-only` reports).
## A scene run loads the autoloads the real app has.
##
## WHY IT EXISTS. The mirror had two halves and only one of them was ever checked. The mod's
## side is observable from outside (tap the bridge and read the `popup` frames), so it got
## measured; the CLIENT's side was only ever confirmed by eye, through
## `raves_state.json`'s `popup` field or a screenshot. That is exactly backwards: a runtime
## error inside `show_popup` aborts the function silently, the overlay stays `visible = false`,
## and every outside signal reads "Raves never heard about it" — indistinguishable from a mod
## that never announced it, from a watcher that never armed, and from a Qud that never raised
## a popup. All three were hunted, in that order, before anyone suspected the client.
##
## So this drives the real `show_popup` over the real frame shapes the mod emits — untitled
## menu, TITLED menu, message, and AskString input — and asserts the overlay came up. Any
## runtime error on that path fails the run instead of turning into a blank screen.
##
## Fixtures are the actual wire frames, copied from a bridge tap, so they carry Qud's markup
## and the `{{W|…}}` hotkey spans rather than a tidied-up approximation.

var _failed: Array[String] = []


func _ready() -> void:
	_case("untitled option menu (cloth robe, 8 options)", _item_menu())
	_case("TITLED option menu (Select Controller, 2 options)", _titled_menu())
	_case("plain message (quest notice)", _message())
	_case("AskString input (wish prompt)", _input_prompt())
	_case("death popup (message WITH newlines + 4 options)", _death_menu())
	_newlines_are_line_breaks()
	_markup_palette_is_seeded()
	_box_heights_match_qud()
	_long_message_wraps_like_qud()
	await _last_line_survives_the_clip()
	_answer_names_the_popup()
	await _outside_field_owns_the_keyboard()
	_doubled_sigil_is_a_literal()
	print("\n%s (%d checks failed)" % ["all good" if _failed.is_empty() else "FAILED", _failed.size()])
	get_tree().quit(1 if not _failed.is_empty() else 0)


func _check(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("  ok   %s" % name)
	else:
		print("  FAIL %s%s" % [name, "  — " + detail if detail != "" else ""])
		_failed.append(name)


## Build an overlay, hand it a frame, and require that it is on screen afterwards.
func _case(name: String, frame: Dictionary) -> void:
	var ov := PopupOverlay.new()
	add_child(ov)
	ov.show_popup(frame, _palette())
	_check("%s → overlay visible" % name, ov.visible,
		"show_popup returned without raising the overlay (a runtime error on that path "
		+ "aborts the function and leaves visible = false)")
	ov.hide_popup()
	_check("%s → hide_popup clears it" % name, not ov.visible)
	ov.queue_free()


## `&&` / `^^` on the wire are Qud's ESCAPES for a literal `&` / `^`, not colour codes.
## Popup.NewPopupMessageAsync doubles them on the way out, so "Keyboard & Mouse" arrives as
## "Keyboard && Mouse"; reading the pair as a colour code ate BOTH characters and Raves drew
## "Keyboard  Mouse". All three QudText parsers have to agree, so all three are checked.
func _doubled_sigil_is_a_literal() -> void:
	var pal := _palette()
	_check("to_bbcode un-escapes &&",
		QudText.to_bbcode("Keyboard && Mouse", pal).contains("Keyboard & Mouse"),
		QudText.to_bbcode("Keyboard && Mouse", pal))
	_check("strip un-escapes &&",
		QudText.strip("{{y|Keyboard && Mouse}}") == "Keyboard & Mouse",
		QudText.strip("{{y|Keyboard && Mouse}}"))
	var text := ""
	for run in QudText.runs("{{y|Keyboard && Mouse}}", pal):
		text += String(run[0])
	_check("runs un-escapes &&", text == "Keyboard & Mouse", text)
	_check("strip un-escapes ^^", QudText.strip("50^^2") == "50^2", QudText.strip("50^^2"))
	# …and a SINGLE sigil is still a colour code, i.e. still consumed.
	_check("a single &y is still a colour code",
		QudText.strip("&yhello") == "hello", QudText.strip("&yhello"))


## The answer must NAME the popup it is answering: the mod refuses an id that does not belong
## to the modal on screen, so an unstamped payload would be refused for every popup.
func _answer_names_the_popup() -> void:
	var ov := PopupOverlay.new()
	add_child(ov)
	var frame := _item_menu()
	ov.show_popup(frame, _palette())
	var seen := {}
	ov.answered.connect(func(p: Dictionary): seen.merge(p, true))
	ov._cancel()
	_check("answer payload carries the popup id",
		int(seen.get("id", -1)) == int(frame["id"]),
		"got %s, expected %s" % [seen.get("id", "<missing>"), frame["id"]])
	ov.queue_free()


## Qud's own line breaks must STAY line breaks. CP437 has glyphs for bytes 9/10/13 (○ ◙ ♪)
## and QudText.cp437 substituted them, so the death popup's "You died.\n\nYou were killed by
## an ogre ape.\n" drew as ONE line reading "You died.◙◙You were killed by an ogre ape.◙" --
## against Qud's three. It also mis-sized the box, which was measured off that one long line.
func _newlines_are_line_breaks() -> void:
	var msg := "{{y|You died.\n\nYou were killed by an {{W|ogre ape}}.\n}}"
	var stripped := QudText.strip(msg)
	# cp437() is the function that had the bug, so check IT, not a caller that never
	# routed through it -- `strip` does not, and a check on `strip` passed with the bug in.
	_check("cp437 leaves tab/LF/CR alone",
		QudText.cp437("a\tb\nc\rd") == "a\tb\nc\rd", QudText.cp437("a\tb\nc\rd"))
	_check("a newline survives to_bbcode",
		QudText.to_bbcode(msg, _palette()).contains("\n") \
			and not QudText.to_bbcode(msg, _palette()).contains("◙"))
	# …and the box is sized by the LONGEST line, not by every line laid end to end.
	var ov := PopupOverlay.new()
	add_child(ov)
	ov.show_popup(_death_menu(), _palette())
	var longest := 0
	for ln in stripped.split("\n"):
		longest = maxi(longest, String(ln).length())
	_check("message box is sized by the longest line",
		ov._msg_w < ov._pitch(ov._root.get_theme_font("font", "Label"), 16) * (stripped.length() - 2),
		"msg_w %.1f for a %d-char message whose longest line is %d"
			% [ov._msg_w, stripped.length(), longest])
	ov.queue_free()


## The markup palette must be Qud's colours BEFORE any snapshot arrives. A popup parks Qud's
## turn thread, so snapshots stop while one is up -- a client that connects (or restarts) then
## never gets the live palette, and every {{code|...}} span fell back to white. Measured on the
## death screen: Qud drew "{{W|ogre ape}}" gold (164,157,53 on screen), Raves drew it white.
func _markup_palette_is_seeded() -> void:
	var pal := QudPalette.markup()
	_check("markup palette resolves W to gold, not white",
		String(pal.get("W", "")).to_lower() == "#cfc041", str(pal.get("W", "<missing>")))
	_check("markup palette covers every canonical code",
		pal.size() == QudPalette.COLORS.size(), "%d of %d" % [pal.size(), QudPalette.COLORS.size()])
	_check("a {{W|…}} span uses it",
		QudText.to_bbcode("{{W|ogre ape}}", pal).contains("cfc041"),
		QudText.to_bbcode("{{W|ogre ape}}", pal))


## Qud's own box heights, read off `MenuControll` with `uiprobe target=PopupMessage` (the death
## screen) and off the six-popup table in reports/2026-08-05-item-popup. These are MEASURED
## numbers, not ones this model produced — which is the only reason they are worth asserting.
##
## The death screen is here because it is the one popup with NO bottom commands: its MenuCrome
## holds just the two line sprites and stands 15 tall, not 20. A fixed 20 put 5px into the box
## height, and a centred box spread that over every row (~4px off Qud's, uniformly).
func _box_heights_match_qud() -> void:
	var cases := [
		["death screen (no bottom commands)", _death_menu(), 202.34],
		["quest notice (1 command)", _message(), 57.12],
		["cloth robe menu (context + 1 command)", _item_menu(), 407.12],
	]
	for c in cases:
		var ov := PopupOverlay.new()
		add_child(ov)
		ov.show_popup(c[1], _palette())
		_check("box height, %s: %.2f" % [c[0], float(c[2])],
			absf(ov._box_h - float(c[2])) <= 0.05, "got %.2f, Qud measures %.2f" % [ov._box_h, c[2]])
		ov.queue_free()


## A Qud message popup answers to SPACE ("press [Space]"), and this handler runs in `_input`,
## before the GUI pass, exempt from the typing guard so Qud's own AskString can submit while
## typing. That exemption is about THIS overlay's field. It used to read as "act while anyone is
## typing anywhere", so with the feedback note open, every space the viewer typed answered the
## popup instead of reaching the note — the text came out "Securiabc", both spaces gone.
func _outside_field_owns_the_keyboard() -> void:
	var ov := PopupOverlay.new()
	add_child(ov)
	ov.show_popup(_message(), _palette())
	var answered: Array = []
	ov.answered.connect(func(p: Dictionary): answered.append(p))
	var outside := LineEdit.new()
	add_child(outside)
	outside.grab_focus()
	await get_tree().process_frame
	_check("the outside field really has focus (else this proves nothing)",
		get_viewport().gui_get_focus_owner() == outside)

	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	ov._input(space)
	_check("a space does NOT answer the popup while another field has focus",
		answered.is_empty() and ov.visible,
		"answered %s" % [answered])

	# …and the popup is not simply deaf: with nothing being typed into, Space still answers it.
	outside.release_focus()
	await get_tree().process_frame
	ov._input(space)
	_check("…and Space still answers it once nothing is being typed into",
		not answered.is_empty())
	outside.queue_free()
	ov.queue_free()


## A LONG message wraps at Qud's cap and the box then takes the longest line that came out.
## Numbers measured off Qud's own live popup (`uiprobe target=PopupMessage`, security door):
##
##     MenuControll 789.20x285.68     Message 739.20x100.56  (5 lines at 20.12)
##
## Raves drew that message as one 1250px slab: it capped at a flat 1240 and never re-measured the
## wrapped result. Reported through the feedback form — "Let's fix the 1:1 width to match Qud".
func _long_message_wraps_like_qud() -> void:
	var ov := PopupOverlay.new()
	add_child(ov)
	ov.show_popup(_security_door(), _palette())
	_check("long message: box width 789.20", absf(ov._box_w - 789.20) <= 0.05,
		"got %.2f, Qud measures 789.20" % ov._box_w)
	_check("long message: box height 285.68", absf(ov._box_h - 285.68) <= 0.05,
		"got %.2f, Qud measures 285.68" % ov._box_h)
	_check("long message: text block 739.20 wide", absf(ov._msg_w - 739.20) <= 0.05,
		"got %.2f, Qud measures 739.20" % ov._msg_w)
	_check("long message: 5 wrapped lines (100.56 tall)", absf(ov._msg_h - 100.60) <= 0.10,
		"got %.2f, Qud measures 100.56" % ov._msg_h)
	ov.queue_free()

	# The wrapper itself, since the sizes above only see its longest line.
	_wrap_checks()


## The item popup's wear/tear line ("Perfect") vanished — feedback 2026-08-10. The frame is
## the apron's Look popup off a live bridge tap, and it needs BOTH label fixes at once:
## Godot's RichTextLabel counts a candidate line's trailing space when breaking (Qud does
## not), so at exactly msg_w the 77-column description line broke one word early and the
## whole message came out one line taller than `_wrap` counted; and the label advances 21px
## a line against Qud's 20.12 slot, so by 8 lines the deficit alone pushes the last line
## under `clip_contents`. Either regression alone re-clips the tail and fails here.
## NEEDS TWO FRAMES: the label reflows after show_popup returns, so the checks await.
func _last_line_survives_the_clip() -> void:
	var ov := PopupOverlay.new()
	add_child(ov)
	ov.show_popup({
		"type": "popup", "active": true, "id": 10, "kind": "message",
		"message": "{{y|Boar hide was brined, limed, and put in a tanning drum. It was cut and fitted into an apron, and now it's a brown canvas for knife scars and tong burns.\n\n{{R|+12 Heat Resistance}}\n\n{{K|Weight: 5 lbs.}}\n\n{{Y|Perfect}}}}",
		"title": "", "input": false, "inputDefault": "",
		"buttons": [{"text": "press [Space]", "command": "Cancel", "hotkey": "Space"}],
		"options": [],
	}, _palette())
	await get_tree().process_frame
	await get_tree().process_frame
	_check("apron look: label wraps to Qud's 8 lines, not 9",
		ov._msg.get_line_count() == 8, "got %d" % ov._msg.get_line_count())
	_check("apron look: rendered text fits the slot (nothing clipped)",
		ov._msg.get_content_height() <= ov._msg_slot.custom_minimum_size.y,
		"content %d in a %.0f slot" % [ov._msg.get_content_height(),
			ov._msg_slot.custom_minimum_size.y])
	_check("apron look: the wear/tear line is the last thing in the label",
		ov._msg.get_parsed_text().strip_edges().ends_with("Perfect"),
		JSON.stringify(ov._msg.get_parsed_text().right(20)))
	ov.queue_free()


func _wrap_checks() -> void:
	var wrapped := PopupOverlay._wrap(PackedStringArray(["aaa bbb ccc ddd"]), 7)
	_check("wrap breaks on words, not mid-word",
		Array(wrapped) == ["aaa bbb", "ccc ddd"], str(Array(wrapped)))
	var unbreakable := PopupOverlay._wrap(PackedStringArray(["short enormouslylongunbreakableword"]), 10)
	_check("a word longer than the column count is left whole, not split",
		Array(unbreakable) == ["short", "enormouslylongunbreakableword"], str(Array(unbreakable)))


## Qud's look-at for a security door — the message the feedback names, verbatim off the wire.
func _security_door() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 140, "kind": "message",
		"message": "{{y|A furrowed metal plate is fit to the arch of the doorway, and a sliding "
			+ "panel sits recessed in the center. The panel is impressed with the mold of a key "
			+ "card.\n\nPerfect}}",
		"title": "", "input": false, "inputDefault": "",
		"buttons": [{"text": "{{W|press [Space]}}", "command": "Accept", "hotkey": "Accept"}],
		"options": [],
		"context": {"frame": true, "text": "{{y|security door}}", "textColor": "#b1c9c3",
			"fg": "#b1c9c3", "dt": "#4fa8c4"},
	}


func _palette() -> Dictionary:
	return {"y": "#e8d9a0", "W": "#ffffff", "K": "#404040", "c": "#4fa8c4", "r": "#a04040"}


func _cancel_button() -> Array:
	return [{"text": "{{W|[Esc]}} Cancel", "command": "Cancel", "hotkey": "Cancel"}]


func _item_menu() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 71, "kind": "menu",
		"message": "{{y|}}", "title": "", "input": false, "inputDefault": "",
		"buttons": _cancel_button(),
		"options": [
			{"text": "{{W|[d]}} {{y|{{hotkey|d}}rop}}", "command": "option:0", "hotkey": ""},
			{"text": "{{W|[e]}} {{y|{{hotkey|e}}quip (auto)}}", "command": "option:1", "hotkey": ""},
			{"text": "{{W|[E]}} {{y|{{hotkey|E}}quip (manual)}}", "command": "option:2", "hotkey": ""},
			{"text": "{{W|[i]}} {{y|mark {{hotkey|i}}mportant}}", "command": "option:3", "hotkey": ""},
			{"text": "{{W|[l]}} {{y|{{hotkey|l}}ook}}", "command": "option:4", "hotkey": ""},
			{"text": "{{W|[n]}} {{y|add {{hotkey|n}}otes}}", "command": "option:5", "hotkey": ""},
			{"text": "{{W|[t]}} {{y|mod with {{hotkey|t}}inkering}}", "command": "option:6", "hotkey": ""},
			{"text": "{{W|[w]}} {{y|sho{{hotkey|w}} effects}}", "command": "option:7", "hotkey": ""},
		],
		"context": {"frame": true, "text": "{{y|cloth robe}}", "textColor": "#b1c9c3",
			"fg": "#b1c9c3", "dt": "#4fa8c4"},
	}


func _titled_menu() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 85, "kind": "menu",
		"message": "{{y|}}", "title": "{{W|Select Controller}}", "input": false,
		"inputDefault": "",
		"buttons": _cancel_button(),
		"options": [
			{"text": "{{y|Keyboard && Mouse}}", "command": "option:0", "hotkey": ""},
			{"text": "{{y|Gamepad}}", "command": "option:1", "hotkey": ""},
		],
	}


func _message() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 91, "kind": "message",
		"message": "{{y|You have received a new quest.}}", "title": "", "input": false,
		"inputDefault": "",
		"buttons": [{"text": "{{W|[Space]}} OK", "command": "Accept", "hotkey": "Accept"}],
		"options": [],
	}


## Qud's death screen: a multi-LINE message above an option list. The only mirrored popup
## that carries real newlines, and the reason they are checked at all.
func _death_menu() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 60, "kind": "menu",
		"message": "{{y|You died.\n\nYou were killed by an {{W|ogre ape}}.\n}}",
		"title": "", "input": false, "inputDefault": "",
		"buttons": [],
		"options": [
			{"text": "{{y|View final messages}}", "command": "option:0", "hotkey": ""},
			{"text": "{{y|Reload from checkpoint}}", "command": "option:1", "hotkey": ""},
			{"text": "{{y|Retire character}}", "command": "option:2", "hotkey": ""},
			{"text": "{{y|Quit to main menu}}", "command": "option:3", "hotkey": ""},
		],
	}


func _input_prompt() -> Dictionary:
	return {
		"type": "popup", "active": true, "id": 97, "kind": "input",
		"message": "{{y|Enter your wish.}}", "title": "", "input": true, "inputDefault": "",
		"buttons": [
			{"text": "{{W|[Enter]}} Accept", "command": "Accept", "hotkey": "Accept"},
			{"text": "{{W|[Esc]}} Cancel", "command": "Cancel", "hotkey": "Cancel"},
		],
		"options": [],
	}

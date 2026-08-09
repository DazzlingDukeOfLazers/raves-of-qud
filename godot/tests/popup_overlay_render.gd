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
	_answer_names_the_popup()
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

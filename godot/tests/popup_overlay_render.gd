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
	_answer_names_the_popup()
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

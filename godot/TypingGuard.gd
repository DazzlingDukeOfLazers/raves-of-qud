class_name TypingGuard
extends RefCounted

## Is the viewer TYPING right now? One answer, for every keyboard hotkey in the app.
##
## THE BUG THIS EXISTS FOR (Daniel, 2026-08-07): "Add a typing guard in all text fields so typed
## characters don't trigger other menus." Typing a note in the feedback form, or a name in the
## options search, ALSO fired the in-game hotkeys — an "e" opened the Equipment screen, a "j" the
## Journal, a digit activated an ability.
##
## WHY the text field alone does not stop it. A LineEdit/TextEdit consumes the key in the GUI input
## pass and marks the event handled. That is enough to stop `_unhandled_input` and
## `_unhandled_key_input` — but the GUI pass runs AFTER `_input`, so any handler that dispatches
## from `_input` has already fired by then, and `get_viewport().is_input_handled()` is still false
## when it looks. Handlers in `_input` therefore have to ask this question themselves.
##
## Rule of thumb for new code: dispatch a hotkey from `_unhandled_input` where you can — it is
## guarded for free. Use `_input` only when you must beat Godot's own handling (Tab, arrow-key focus
## traversal, a modal that owns everything), and then guard with this.
static func typing(vp: Viewport) -> bool:
	if vp == null:
		return false
	var f := vp.gui_get_focus_owner()
	if f == null:
		return false
	# LineEdit / TextEdit / CodeEdit (CodeEdit extends TextEdit). Checked by TYPE, not by a `text`
	# property — Buttons and Labels carry `text` too and must not count as typing.
	return f is LineEdit or f is TextEdit

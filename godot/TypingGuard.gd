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
## pass and marks the event handled — but the GUI pass runs AFTER `_input`, so any handler that
## dispatches from `_input` has already fired by then, and `get_viewport().is_input_handled()` is
## still false when it looks. Handlers in `_input` therefore have to ask this question themselves.
##
## AND SO DO HANDLERS IN `_unhandled_input` (Daniel, 2026-08-09: "It's still sending keys to Qud").
## An earlier version of this note said `_unhandled_input` was "guarded for free". It is not, and
## the half-truth is worse than no rule: a field consumes the keys it has a USE for — text, caret
## movement, its own editing shortcuts — and everything else falls straight through it. Modifier
## combos and function keys are exactly the class it ignores. Measured with the feedback note
## focused and typed into: plain letters landed in the box and reached nothing else, and
## `Ctrl+Shift+X` ran Qud's xp wish, 0 -> 150 Exp. Main also routes any unclaimed combo through the
## player's own Qud bindings, so the reachable set there is "whatever they have bound".
##
## Rule for new code: `_input` or `_unhandled_input`, if the handler reads a keycode and does
## something a typist would not want, ask this first. The only exemptions are handlers that must
## act WHILE typing (a form's own Esc / Cmd+Enter), and they say so where they are exempted.
static func typing(vp: Viewport) -> bool:
	if vp == null:
		return false
	var f := vp.gui_get_focus_owner()
	if f == null:
		return false
	# LineEdit / TextEdit / CodeEdit (CodeEdit extends TextEdit). Checked by TYPE, not by a `text`
	# property — Buttons and Labels carry `text` too and must not count as typing.
	return f is LineEdit or f is TextEdit

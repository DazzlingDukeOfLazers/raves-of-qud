extends CanvasLayer

## ELEMENT FEEDBACK — Cmd+Right-click any UI element to name it and file feedback on it.
##
## The point is a feedback loop on the UI itself: a tester Cmd+Right-clicks the thing that looks
## wrong, sees what Raves calls it ("title · Continue"), types a note, and it lands in a file the
## team can read — one JSON line per note in <support>/feedback.jsonl. Server submission comes
## later; the JSONL shape is chosen so those lines can be POSTed as-is when it does.
##
## Scope rules:
##   - the HOLODECK PLAYFIELD is not an element. Cmd+Right-click there stays the tile inspector's
##     gesture (inspect + photograph both apps) — any hit node carrying meta "feedback_skip"
##     (MainFrame sets it on the play hole) falls through untouched.
##   - while the form is open it is MODAL: every input is consumed, Esc cancels, Cmd+Enter saves.
##     UiState reports popup="feedback" so `hv assert --popup feedback` can see it, same contract
##     as the game popups.
##
## Element naming: the deepest visible Control whose global rect contains the click, walked by
## hand — Godot's own hover resolution skips MOUSE_FILTER_IGNORE nodes, and most of our display
## leaves ignore the mouse (the command-bar rule), so asking the picker would name a container
## three levels up. A node's display name is its scene-tree name when hand-given, else its own
## text (a Button's caption is its best name), else its class; the display path is the scene plus
## the last two meaningful names, the record carries the full raw path too.

const FILE_NAME := "feedback.jsonl"

var _form: Control = null          # the open form, null when closed
var _target_path := ""             # full raw node path of the clicked element
var _target_label := ""            # human name shown in the form + record
var _target_pos := Vector2.ZERO
var _edit: TextEdit = null
var _prev_focus: Control = null

func _ready() -> void:
	layer = 120   # above game popups (PopupOverlay) — feedback can be ABOUT a popup

func _input(event: InputEvent) -> void:
	# Modal while open: the form owns every event except its own editing.
	if _form != null:
		if event is InputEventKey and event.pressed:
			var k := event as InputEventKey
			if k.keycode == KEY_ESCAPE:
				_close(false)
				get_viewport().set_input_as_handled()
				return
			if k.keycode == KEY_ENTER and (k.meta_pressed or k.ctrl_pressed):
				_close(true)
				get_viewport().set_input_as_handled()
				return
		return

	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT or not mb.meta_pressed:
		return
	var hit := _deepest_control_at(mb.position)
	if hit == null:
		return
	# The playfield keeps its inspector gesture — fall through without consuming.
	var n: Node = hit
	while n != null:
		if n.has_meta("feedback_skip"):
			return
		n = n.get_parent()
	# Snap to the interactive ancestor: the deepest node under a click is usually a Button's
	# DECORATION (its label, its underline bars) — "Continue", not "Continue · hlbars", is the
	# element the feedback is about. The click pixel is still in `pos`.
	var up: Node = hit
	for _i in 4:
		if up == null:
			break
		if up is BaseButton:
			hit = up
			break
		up = up.get_parent()
	_target_pos = mb.position
	_target_path = String(hit.get_path())
	_target_label = _display_label(hit)
	_open_form()
	get_viewport().set_input_as_handled()

## Would this point open the feedback form? TRUE when the deepest element under it is UI chrome,
## FALSE over the playfield (feedback_skip) or nothing. Main's inspect gesture asks this before
## consuming a Cmd+Right-click: the scene gets _input BEFORE autoloads, so without the handoff the
## inspector claimed every such click window-wide and the form could never open in-game.
func claims(p: Vector2) -> bool:
	var hit := _deepest_control_at(p)
	if hit == null:
		return false
	var n: Node = hit
	while n != null:
		if n.has_meta("feedback_skip"):
			return false
		n = n.get_parent()
	return true

# --- element resolution --------------------------------------------------------------------------

## The deepest visible Control containing the point. By hand, because the built-in picker skips
## MOUSE_FILTER_IGNORE nodes and most display leaves here ignore the mouse.
func _deepest_control_at(p: Vector2) -> Control:
	var best: Control = null
	var best_depth := -1
	var stack: Array = [[get_tree().root, 0]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node: Node = top[0]
		var depth: int = top[1]
		if node == self:
			continue   # never name our own form
		var c := node as Control
		if c != null:
			if not c.is_visible_in_tree():
				continue
			if c.get_global_rect().has_point(p) and depth >= best_depth:
				best = c
				best_depth = depth
		for ch in node.get_children():
			stack.push_back([ch, depth + 1])
	return best

## A node's human name: its hand-given scene-tree name, else its own text, else its class.
func _node_label(n: Node) -> String:
	var nm := String(n.name)
	if not nm.begins_with("@"):
		return nm
	if n is Button and (n as Button).text.strip_edges() != "":
		return (n as Button).text.strip_edges()
	if n is Label and (n as Label).text.strip_edges() != "":
		return (n as Label).text.strip_edges().left(24)
	if n is RichTextLabel and (n as RichTextLabel).get_parsed_text().strip_edges() != "":
		return (n as RichTextLabel).get_parsed_text().strip_edges().left(24)
	return n.get_class()

## "scene · parent · leaf", keeping only names that say something (skip bare class names of
## anonymous containers on the way up, keep at most the last two meaningful ancestors).
func _display_label(c: Control) -> String:
	var parts: Array[String] = []
	var n: Node = c
	while n != null and not (n is Viewport) and parts.size() < 2:
		var l := _node_label(n)
		var generic := String(n.name).begins_with("@") and l == n.get_class()
		if not generic:
			parts.push_front(l)
		n = n.get_parent()
	var head := UiState.scene()
	if head == "":
		head = "?"
	if parts.is_empty():
		return head + " · " + c.get_class()
	return head + " · " + " · ".join(parts)

# --- the form ------------------------------------------------------------------------------------

func _open_form() -> void:
	_prev_focus = get_viewport().gui_get_focus_owner()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UiFont.make_theme(get_viewport())   # CanvasLayer theme trap — set explicitly
	root.mouse_filter = Control.MOUSE_FILTER_STOP    # modal: swallow clicks behind the form
	add_child(root)
	_form = root

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudChrome.q8(6, 37, 37)            # the popup glass colour
	sb.border_color = QudChrome.q8(68, 99, 111)      # the rule colour
	sb.set_border_width_all(1)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(560, 0)
	root.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var title := Label.new()
	title.text = "FEEDBACK"
	title.add_theme_color_override("font_color", QudChrome.q8(207, 192, 65))   # Qud gold
	v.add_child(title)

	var elem := Label.new()
	elem.text = _target_label
	elem.add_theme_color_override("font_color", QudChrome.q8(67, 131, 164))   # header blue
	elem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(elem)

	_edit = TextEdit.new()
	_edit.custom_minimum_size = Vector2(0, 120)
	_edit.placeholder_text = "What should be different about this element?"
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	v.add_child(_edit)

	var hint := Label.new()
	hint.text = "[Cmd+Enter] save    [Esc] cancel"
	hint.add_theme_color_override("font_color", QudChrome.q8(96, 156, 170))
	v.add_child(hint)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	var save := Button.new()
	save.text = "Save"
	save.pressed.connect(func() -> void: _close(true))
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: _close(false))
	buttons.add_child(cancel)
	buttons.add_child(save)
	v.add_child(buttons)

	# DEFERRED: grabbing during the opening click's _input frame does not stick — the click's own
	# gui pass still runs after us and the TextEdit ends the frame unfocused (typed keys then fall
	# through to nothing; Cmd+Enter still worked because the modal reads it in _input, which made
	# the miss easy to misread as a delivery problem rather than a focus one).
	_edit.grab_focus.call_deferred()
	UiState.set_popup("feedback")

func _close(save: bool) -> void:
	if save and _edit != null and _edit.text.strip_edges() != "":
		_append_record(_edit.text.strip_edges())
	if _form != null:
		_form.queue_free()
		_form = null
	_edit = null
	UiState.clear_popup()
	if _prev_focus != null and is_instance_valid(_prev_focus):
		_prev_focus.grab_focus()
	_prev_focus = null

# --- persistence ---------------------------------------------------------------------------------

func _append_record(text: String) -> void:
	var rec := {
		"ts": Time.get_datetime_string_from_system(true),   # UTC, sortable
		"scene": UiState.scene(),
		"mode": "1to1" if Settings.one_to_one() else "user",
		"element": _target_label,
		"path": _target_path,
		"pos": [int(_target_pos.x), int(_target_pos.y)],
		"text": text,
	}
	var path := InputModel.support_dir().path_join(FILE_NAME)
	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("feedback: cannot open " + path)
		return
	f.store_line(JSON.stringify(rec))
	f.close()
	print("[feedback] %s -> %s" % [_target_label, path])

class_name PopupOverlay
extends CanvasLayer

## Mirrors a Qud modal popup that the mod forwarded over the bridge — message, Yes/No, an option list
## (PickOption), or a text prompt (AskString). While visible it is MODAL: it consumes keyboard input in
## `_input` (which runs before the Holodeck's `_unhandled_input`), so movement / wishes don't leak through.
## The viewer's answer is emitted as `answered`; Main relays it as a "popup" command, which invokes Qud's
## own popup callback and unblocks the turn thread the real popup is parked on.
##
## Answer payloads (→ mod PopupBridge.HandleCommand):
##   {"action":"button","btn":<command>}   dismiss with a bottom button (Accept/Yes/No/Cancel/…)
##   {"action":"option","index":<i>}        pick option i from a PickOption list
##   {"action":"input","text":<s>}          submit AskString text

signal answered(payload: Dictionary)

var _palette := {}
var _cur_id := -1             # id of the popup currently shown (or last answered) — dedupes resends
var _content_sig := ""        # content fingerprint — a flap re-announce must not reset typed input
var _buttons: Array = []      # [{text,command,hotkey}] — the bottom button row
var _options: Array = []      # [{text,command}] — PickOption items (empty for a plain message)
var _sel := 0                 # highlighted option index (menu mode)
var _built := false

var _root: Control
var _title: RichTextLabel
var _msg: RichTextLabel
var _opt_box: VBoxContainer
var _edit: LineEdit
var _btn_row: HBoxContainer

func _init() -> void:
	layer = 130                # above the chrome; below nothing that matters
	visible = false

func _ready() -> void:
	_build()

func _build() -> void:
	if _built:
		return
	_built = true
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP       # eat clicks headed for the Holodeck
	_root.theme = UiFont.make_theme(get_viewport())      # dodge the CanvasLayer tiny-font trap
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.047, 0.059, 0.063, 0.98)       # Qud near-black chrome
	st.set_content_margin_all(18)
	st.border_color = Color(0.30, 0.40, 0.45)
	st.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", st)
	panel.custom_minimum_size = Vector2(440, 0)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	_title = _mk_rt()
	vb.add_child(_title)
	_msg = _mk_rt()
	vb.add_child(_msg)

	_opt_box = VBoxContainer.new()
	_opt_box.add_theme_constant_override("separation", 2)
	vb.add_child(_opt_box)

	_edit = LineEdit.new()
	_edit.custom_minimum_size = Vector2(400, 0)
	_edit.text_submitted.connect(func(_t: String): _submit_input())
	_edit.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			_cancel())
	vb.add_child(_edit)

	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 10)
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(_btn_row)

func _mk_rt() -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.custom_minimum_size = Vector2(404, 0)
	return rt

## Show / update the overlay from a mod popup frame. `palette` is the Qud colour map from the last snapshot.
func show_popup(data: Dictionary, palette: Dictionary) -> void:
	if not _built:
		_build()
	if not palette.is_empty():
		_palette = palette
	var id := int(data.get("id", -1))
	if id == _cur_id:
		return                      # same popup (or one we already answered) — don't rebuild/reshow
	# a re-announced popup with IDENTICAL content (watcher flap / reconnect): keep the
	# user's half-typed input instead of rebuilding — the reset-while-typing bug
	var content_sig := "%s|%s|%s|%s|%s" % [str(data.get("message", "")), str(data.get("title", "")),
		str(data.get("buttons", [])), str(data.get("options", [])), str(data.get("input", false))]
	if content_sig == _content_sig and bool(data.get("input", false)) and _edit != null and _edit.text != "":
		_cur_id = id
		visible = true
		UiState.set_popup("input")
		_edit.grab_focus()
		return
	_content_sig = content_sig
	_cur_id = id
	_buttons = data.get("buttons", [])
	_options = data.get("options", [])
	var is_input := bool(data.get("input", false))

	var title_markup := str(data.get("title", "")).strip_edges()
	_title.visible = title_markup != ""
	if _title.visible:
		_title.text = "[b]%s[/b]" % QudText.to_bbcode(title_markup, _palette)
	_msg.text = QudText.to_bbcode(str(data.get("message", "")), _palette)

	_build_options()
	_build_buttons()

	_edit.visible = is_input
	if is_input:
		_edit.text = str(data.get("inputDefault", ""))
	_opt_box.visible = _options.size() > 0
	_sel = 0
	_highlight_option()

	visible = true
	if is_input:
		_edit.grab_focus()
		_edit.caret_column = _edit.text.length()
	else:
		_edit.release_focus()
	# highvisor state report: a popup is up (kind feeds `hv assert --popup …`)
	UiState.set_popup("input" if is_input else ("menu" if _options.size() > 0 else "message"))

func _build_buttons() -> void:
	for c in _btn_row.get_children():
		c.queue_free()
	for b in _buttons:
		var bt := Button.new()
		bt.text = QudText.strip(str(b.get("text", "")))
		bt.focus_mode = Control.FOCUS_NONE
		var cmd := str(b.get("command", ""))
		bt.pressed.connect(func(): _answer_button(cmd))
		_btn_row.add_child(bt)

func _build_options() -> void:
	for c in _opt_box.get_children():
		c.queue_free()
	for i in _options.size():
		var row := Button.new()
		row.text = QudText.strip(str(_options[i].get("text", "")))
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.flat = true
		var idx := i
		row.pressed.connect(func(): _answer_option(idx))
		row.mouse_entered.connect(func(): _sel = idx; _highlight_option())
		_opt_box.add_child(row)

func _highlight_option() -> void:
	var kids := _opt_box.get_children()
	for i in kids.size():
		var b: Button = kids[i]
		b.add_theme_color_override("font_color", Color(1, 1, 1) if i == _sel else Color(0.69, 0.79, 0.76))
		# a subtle selected background so the caret is obvious
		if i == _sel:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.12, 0.20, 0.20)
			b.add_theme_stylebox_override("normal", sb)
		else:
			b.remove_theme_stylebox_override("normal")

# --- input -----------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if _edit.visible:
		return                      # text prompt: let the LineEdit type; Enter/Esc via its gui_input
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var kc: int = event.keycode
	if _options.size() > 0:
		match kc:
			KEY_UP, KEY_KP_8:   _sel = max(0, _sel - 1); _highlight_option()
			KEY_DOWN, KEY_KP_2: _sel = min(_options.size() - 1, _sel + 1); _highlight_option()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _answer_option(_sel)
			KEY_ESCAPE: _cancel()
			_:
				if not _try_button_hotkey(kc):
					return          # let unrelated keys through (nothing else should, but be safe)
	else:
		match kc:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _answer_token("Accept")
			KEY_ESCAPE: _answer_token("Cancel")
			_:
				if not _try_button_hotkey(kc):
					return
	get_viewport().set_input_as_handled()

## Map a letter key to a bottom button whose hotkey lists that letter (e.g. Y → the "Yes" button).
func _try_button_hotkey(kc: int) -> bool:
	if kc < KEY_A or kc > KEY_Z:
		return false
	var letter := char(kc)          # Godot letter keycodes equal ASCII uppercase
	for b in _buttons:
		for tok in str(b.get("hotkey", "")).split(","):
			if tok.strip_edges().to_upper() == letter:
				_answer_button(str(b.get("command", "")))
				return true
	return false

## Dismiss via the button carrying a named hotkey token ("Accept" for Space/Enter, "Cancel" for Esc).
func _answer_token(token: String) -> void:
	for b in _buttons:
		for tok in str(b.get("hotkey", "")).split(","):
			if tok.strip_edges() == token:
				_answer_button(str(b.get("command", "")))
				return
	if token == "Accept" and _buttons.size() > 0:
		_answer_button(str(_buttons[0].get("command", "")))
	# "Cancel" with no cancel button → this popup can't be escaped; ignore.

func _answer_button(command: String) -> void:
	_finish({"action": "button", "btn": command})

func _answer_option(index: int) -> void:
	if index < 0 or index >= _options.size():
		return
	# the chosen option's plain text rides along (the mod ignores it) so Main can
	# mirror menu picks locally — e.g. "Control Mapping" opens Raves' own screen
	_finish({"action": "option", "index": index,
		"text": QudText.strip(str(_options[index].get("text", "")))})

func _submit_input() -> void:
	_finish({"action": "input", "text": _edit.text})

func _cancel() -> void:
	_answer_token("Cancel")

## Emit the answer and hide locally. We keep `_cur_id` so a stale resend of the same popup can't reshow it;
## a fresh popup (new id) or a normal snapshot (via hide) resets it.
func _finish(payload: Dictionary) -> void:
	visible = false
	_edit.release_focus()
	UiState.clear_popup()
	answered.emit(payload)

## Called on `active:false` and on any normal snapshot (a snapshot can only publish once Qud's turn thread
## has unblocked — i.e. the popup is gone) so a coalesced-away dismissal can't strand the overlay.
func hide_popup() -> void:
	if visible:
		visible = false
		_edit.release_focus()
	UiState.clear_popup()
	_cur_id = -1

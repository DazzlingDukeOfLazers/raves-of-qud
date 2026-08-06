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
var _target_rect := Rect2()        # the element's on-screen rect (the thumbnail's crop)
var _thumb: ImageTexture = null    # a crop of the LAST DRAWN FRAME around the element
var _target_image := ""            # the element's image name (icon file / texture resource)
var _target_action := ""           # what the element does — its (or an ancestor's) tooltip
var _edit: TextEdit = null
var _prev_focus: Control = null
var _providers: Array = []         # registered feedback_element_at providers (owner-drawn panes)


## Owner-drawn panes register here (they cannot be found by walking up from a hit: late
## full-window overlays shadow them out of the ancestor chain entirely). Providers self-gate
## on visibility by returning {} when their surface is not showing.
func register_provider(n: Node) -> void:
	if not _providers.has(n):
		_providers.append(n)

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
	# RESOLUTION: an anonymous, textless hit (the ability cell's icon, a decorated container) says
	# nothing on its own — but the CELL it lives in does. Walk up a few levels looking for the first
	# subtree that carries text ("Sprint [off] <1>"), and let that node be the element: its text is
	# the leaf label and its rect is what the thumbnail crops. Clicking Sprint's icon then reads
	# "Sprint", not "TextureRect".
	var elem: Control = hit
	var leaf := _node_label(hit)
	if leaf == hit.get_class():
		var n2: Node = hit
		for _j in 3:
			if n2 == null:
				break
			var t := _subtree_text(n2)
			if t != "":
				leaf = t
				if n2 is Control:
					elem = n2
				break
			n2 = n2.get_parent()
	# Still a bare class name (an icon-only element, no text anywhere)? Its ACTION is its best name:
	# the tooltip on it or a near ancestor — "Go up (stairs) — s" beats "TextureRect".
	if leaf == hit.get_class():
		var n3: Node = hit
		for _k in 4:
			if n3 == null:
				break
			var c3 := n3 as Control
			if c3 != null and c3.tooltip_text.strip_edges() != "":
				leaf = c3.tooltip_text.strip_edges().left(32)
				elem = c3
				break
			n3 = n3.get_parent()
	# OWNER-DRAWN panes see none of this: one Control paints their whole surface, so the walk can
	# only name the pane. A node in the hit chain that implements feedback_element_at(point) knows
	# its own internal geometry (it drew it) and answers with the element the point is really on —
	# a paper-doll slot, an inventory row, a tab cell. First non-empty answer wins.
	var prov_action := ""
	var prov_rect := Rect2()
	var prov: Node = hit
	for _p in 8:
		if prov == null:
			break
		if prov.has_method("feedback_element_at"):
			var pd: Dictionary = prov.feedback_element_at(mb.position)
			if not pd.is_empty():
				leaf = str(pd.get("label", leaf))
				if prov is Control:
					elem = prov
				if pd.has("rect"):
					prov_rect = pd["rect"]
				prov_action = str(pd.get("action", ""))
				break
		prov = prov.get_parent()
	_target_image = _elem_image(elem)
	_target_action = prov_action if prov_action != "" else _elem_action(elem)
	_target_pos = mb.position
	_target_path = String(elem.get_path())
	_target_label = _display_label(elem, leaf)
	_target_rect = prov_rect if prov_rect.size.x > 0.0 else elem.get_global_rect()
	# The viewport texture is the last DRAWN frame — the form is not in it yet, so grabbing here
	# (before _open_form adds nodes) is what makes the thumbnail show the element, not the dialog.
	_thumb = _grab_thumb(_target_rect)
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

## The TOPMOST visible Control containing the point — by paint order, not tree depth. By hand,
## because the built-in picker skips MOUSE_FILTER_IGNORE nodes and most display leaves here ignore
## the mouse. Paint order matters because whole screens ride CanvasLayers: the status screens draw
## on layer 90 over MainFrame's layer-0 chrome, but MainFrame's tree is DEEPER, so a deepest-wins
## walk named the chrome BEHIND the status screen — and when the deepest thing behind was the play
## hole, its feedback_skip silently handed the whole gesture to the tile inspector.
##
## Ordering: higher CanvasLayer wins; within a layer, later document order wins (later siblings
## draw on top, and a child draws over its parent — which also preserves the old deepest-wins
## behaviour for lineal chains). z_index and top_level are not modelled.
func _deepest_control_at(p: Vector2) -> Control:
	var best: Control = null
	var best_layer := -2147483648
	var best_order := -1
	var order := 0
	var stack: Array = [[get_tree().root, 0]]
	# document-order walk: push children reversed so the stack pops them first-to-last
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node: Node = top[0]
		var layer: int = top[1]
		if node == self:
			continue   # never name our own form
		if node is CanvasLayer:
			# A hidden LAYER hides its subtree, but its child Controls still answer
			# is_visible_in_tree() true (a CanvasLayer is not a CanvasItem ancestor for that
			# check) — without this, a CLOSED status screen would shadow the whole window.
			if not (node as CanvasLayer).visible:
				continue
			layer = (node as CanvasLayer).layer
		order += 1
		var c := node as Control
		if c != null:
			if not c.is_visible_in_tree():
				continue
			# "feedback_pass": full-window chrome hosts (a screen's scrim, its rule-drawing frame)
			# paint late and would shadow every real element under them; they are never what the
			# user means, so they are transparent to the hit test (their subtree still walks).
			if not c.has_meta("feedback_pass"):
				var contains := c.get_global_rect().has_point(p)
				var on_top := layer > best_layer or (layer == best_layer and order > best_order)
				if contains and on_top:
					best = c
					best_layer = layer
					best_order = order
		var kids := node.get_children()
		for i in range(kids.size() - 1, -1, -1):
			stack.push_back([kids[i], layer])
	return best

## The first TEXT anywhere in a node's subtree — a cell's caption, whatever leaf carries it.
## Breadth-first and bounded, so a click on a huge container cannot walk the world.
func _subtree_text(n: Node) -> String:
	var q: Array = [n]
	var seen := 0
	while not q.is_empty() and seen < 48:
		var cur: Node = q.pop_front()
		seen += 1
		var c := cur as Control
		if c != null and not c.is_visible_in_tree():
			continue
		if cur is Button and (cur as Button).text.strip_edges() != "":
			return (cur as Button).text.strip_edges().left(24)
		if cur is Label and (cur as Label).text.strip_edges() != "":
			return (cur as Label).text.strip_edges().left(24)
		if cur is RichTextLabel and (cur as RichTextLabel).get_parsed_text().strip_edges() != "":
			return (cur as RichTextLabel).get_parsed_text().strip_edges().left(24)
		for ch in cur.get_children():
			q.push_back(ch)
	return ""


## The element's IMAGE name: the first textured node in its subtree, by the "feedback_image" meta
## (runtime-loaded textures carry no resource_path) or the resource's own basename.
func _elem_image(n: Node) -> String:
	var q: Array = [n]
	var seen := 0
	while not q.is_empty() and seen < 48:
		var cur: Node = q.pop_front()
		seen += 1
		if cur.has_meta("feedback_image"):
			return str(cur.get_meta("feedback_image"))
		var tex: Texture2D = null
		if cur is TextureRect:
			tex = (cur as TextureRect).texture
		elif cur is TextureButton:
			tex = (cur as TextureButton).texture_normal
		elif cur is BaseButton and cur is Button and (cur as Button).icon != null:
			tex = (cur as Button).icon
		if tex != null and tex.resource_path != "":
			return tex.resource_path.get_file().get_basename()
		for ch in cur.get_children():
			q.push_back(ch)
	return ""


## The element's ACTION: the tooltip on it or a near ancestor — the strongest statement of what the
## thing DOES that the tree can offer without a registry.
func _elem_action(n: Node) -> String:
	var cur: Node = n
	for _i in 4:
		if cur == null:
			return ""
		var c := cur as Control
		if c != null and c.tooltip_text.strip_edges() != "":
			return c.tooltip_text.strip_edges()
		cur = cur.get_parent()
	return ""


## A crop of the last drawn frame around the element, padded a little for context.
func _grab_thumb(rect: Rect2) -> ImageTexture:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return null
	var r := rect.grow(6).intersection(Rect2(Vector2.ZERO, Vector2(img.get_width(), img.get_height())))
	if r.size.x < 4.0 or r.size.y < 4.0:
		return null
	img = img.get_region(Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)))
	return ImageTexture.create_from_image(img)


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
func _display_label(c: Control, leaf_override := "") -> String:
	var parts: Array[String] = []
	var n: Node = c
	if leaf_override != "":
		parts.append(leaf_override)
		# start the walk AT the element (not its parent): a hand-named cell ("NavUp") is the most
		# specific ancestor there is — but skip it when it IS the leaf, or Continue reads twice.
		if _node_label(c) == leaf_override:
			n = c.get_parent()
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

	if _target_image != "" or _target_action != "":
		var det := Label.new()
		var bits: Array[String] = []
		if _target_image != "":
			bits.append("image: " + _target_image)
		if _target_action != "":
			bits.append("action: " + _target_action)
		det.text = "  ·  ".join(bits)
		det.add_theme_color_override("font_color", QudChrome.q8(96, 156, 170))
		det.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(det)

	# The element itself, cropped from the frame the user was looking at. Small elements draw 2x so
	# an ability cell is readable; anything is capped so a full-panel click cannot swallow the form.
	if _thumb != null:
		var shot := TextureRect.new()
		shot.texture = _thumb
		shot.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		shot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		shot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		var tsz := _thumb.get_size()
		var scale := 2.0 if (tsz.x <= 266.0 and tsz.y <= 70.0) else 1.0
		var w2 := minf(tsz.x * scale, 532.0)
		var h2 := minf(tsz.y * scale, 150.0)
		shot.custom_minimum_size = Vector2(w2, h2)
		shot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(shot)

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
		"rect": [int(_target_rect.position.x), int(_target_rect.position.y),
			int(_target_rect.size.x), int(_target_rect.size.y)],
		"text": text,
	}
	if _target_image != "":
		rec["image"] = _target_image
	if _target_action != "":
		rec["action"] = _target_action
	# The crop rides along as a PNG — the note plus the pixels it was about, ready for the same
	# server submission later. Named by the record's timestamp so the pair is self-associating.
	if _thumb != null:
		var dir := InputModel.support_dir().path_join("feedback")
		DirAccess.make_dir_recursive_absolute(dir)
		var fname := String(rec["ts"]).replace(":", "-") + ".png"
		var img := _thumb.get_image()
		if img != null and img.save_png(dir.path_join(fname)) == OK:
			rec["shot"] = "feedback/" + fname
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

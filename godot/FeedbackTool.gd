extends CanvasLayer

## ELEMENT FEEDBACK — Cmd+Right-click any UI element to name it and file feedback on it.
##
## The point is a feedback loop on the UI itself: a tester Cmd+Right-clicks the thing that looks
## wrong, sees what Raves calls it ("title · Continue"), types a note, and it lands in a file the
## team can read — one JSON line per note in <support>/feedback.jsonl.
##
## THE FILE IS AN OUTBOX, NOT A DESTINATION. Reports are POSTed to Brand.FEEDBACK_ENDPOINT by the
## FeedbackSubmitter this builds in _ready, and a line is deleted only once the server has taken
## it — so an offline session, a captive portal or a dead endpoint costs nothing but a delay. The
## envelope is the feedback-service contract (schema/envelope.v1.md in that repo): `v`, app,
## app_version, platform, install_id, ts, then the per-product fields.
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
var _element_key_cached := ""      # stable grouping key, resolved when the form opens
var _attach_shot := true           # the reporter's choice — see the consent row in _open_form
var _prev_focus: Control = null
var _providers: Array = []         # registered feedback_element_at providers (owner-drawn panes)
var _submitter: FeedbackSubmitter = null   # drains the outbox to Brand.FEEDBACK_ENDPOINT


## Owner-drawn panes register here (they cannot be found by walking up from a hit: late
## full-window overlays shadow them out of the ancestor chain entirely). Providers self-gate
## on visibility by returning {} when their surface is not showing.
func register_provider(n: Node) -> void:
	if not _providers.has(n):
		_providers.append(n)

func _ready() -> void:
	# ABOVE game popups (PopupOverlay is 130): feedback can be ABOUT a popup, so the popup must not
	# cover the form describing it. This said 120 while claiming to be above -- the comment was the
	# intent and the number was left behind when PopupOverlay moved up, which is how a Qud modal
	# ended up drawn over the note field.
	layer = 140
	# THE OUTBOX GETS A DRAIN. Until now `feedback.jsonl` only ever grew: the form wrote a report,
	# said "Sends: …", and nothing sent it. Submission lives beside the writer deliberately -- the
	# same object owns filling the queue and emptying it, so neither can be wired without the other.
	_submitter = FeedbackSubmitter.new()
	_submitter.name = "FeedbackSubmitter"
	_submitter.endpoint = Brand.FEEDBACK_ENDPOINT
	_submitter.outbox_path = InputModel.support_dir().path_join(FILE_NAME)
	_submitter.finished.connect(func(sent: int, discarded: int, failed: int) -> void:
		if sent or discarded or failed:
			print("[feedback] submitted %d, discarded %d, held %d" % [sent, discarded, failed]))
	add_child(_submitter)
	# On start, because a report filed offline yesterday should leave today without being re-filed.
	_submitter.flush.call_deferred()

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
	# EXPLICIT NAMES FIRST: a builder that knows what a row IS stamps it with a feedback_label
	# meta (Options rows: "option · Music volume"). The nearest carrier up the chain names the
	# element and becomes it (label, rect, thumbnail) — the text harvest below never has to
	# guess, so a row's VALUE label ("50") can't hijack its name. A provider further down still
	# overrides: point-resolution inside one Control beats a whole-node name.
	var nm: Node = hit
	for _m in 6:
		if nm == null:
			break
		if nm.has_meta("feedback_label"):
			leaf = str(nm.get_meta("feedback_label"))
			if nm is Control:
				elem = nm
			break
		nm = nm.get_parent()
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
	var prov_key := ""
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
				# ...AND ITS SUB-ELEMENT KEY. Without this the whole pane is one key: `elem`
				# becomes the pane Control above, so every doll slot, filter cell and list row in
				# StatusPaneInventory grouped as `status_equipment/MainFrame/StatusScreens/Control`
				# — which is most of Raves' UI arriving indistinguishable. The provider drew the
				# thing, so it is the only one that can name it; `key` is its half of the contract
				# and must be STABLE and CONTENT-FREE, like the rest of element_key.
				prov_key = str(pd.get("key", ""))
				break
		prov = prov.get_parent()
	_target_image = _elem_image(elem)
	_target_action = prov_action if prov_action != "" else _elem_action(elem)
	_target_pos = mb.position
	_target_path = String(elem.get_path())
	# A PROVIDER KEY REPLACES THE TREE WALK, it does not extend it. The walk exists for elements
	# nobody can name; a provider that answers HAS named it, and prefixing its answer with the
	# node chain only adds a path that changes when the pane is re-parented — and which resolved
	# two different ways for the same pane depending on whether the hit landed on the pane or on
	# StatusScreens above it (`.../Control/doll.right_hand` vs `.../Control/InventoryPane/…`).
	# `status_equipment/doll.right_hand` is shorter, readable, and survives a reorganisation.
	_element_key_cached = _element_key(elem) if prov_key == "" \
		else (UiState.scene() if UiState.scene() != "" else "?") + "/" + prov_key
	_attach_shot = true                       # opt-OUT, per form; reset for every report
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
		# feedback_action meta beats tooltips: builders stamp it alongside feedback_label
		# (tooltips would also pop on hover, which the Options screen doesn't want).
		if cur.has_meta("feedback_action"):
			return str(cur.get_meta("feedback_action"))
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

## A STABLE, CONTENT-FREE KEY for the element — the field reports GROUP on.
##
## `path` cannot do this job and never could. Godot names anonymous nodes `@Class@<instance>`,
## and the instance counter is per-RUN: measured across 37 local records, one element reported
## twice came back as `.../StatusScreens/@Control@6773` and `.../StatusScreens/@Control@265`, and
## 95 distinct auto-names appeared for a handful of real nodes. Two users reporting the same
## button produce different paths; so does one user across two launches. Dedupe, "14 people hit
## this", and per-element history all collapse on that. The path stays in the record because it
## is useful when debugging ONE report locally — it is just not an identity.
##
## `element` cannot do it either: it embeds live text, so it drifts with game state and is where
## character names and world strings leak into a payload that leaves the machine.
##
## Two rules, in order:
##   1. the nearest ancestor (or the element) carrying a `feedback_id` meta wins — the same idiom
##      as `feedback_skip`/`feedback_pass`. Put one on anything you want to track by name across
##      redesigns; the tree can then be rearranged under it without breaking the key.
##   2. otherwise the ancestor chain with every auto-name collapsed to its bare CLASS. Derived
##      from tree SHAPE, so it survives relaunches, machines and builds that do not restructure
##      the screen.
func _element_key(c: Control) -> String:
	var scene := UiState.scene()
	if scene == "":
		scene = "?"
	var parts: Array[String] = []
	var n: Node = c
	while n != null and not (n is Viewport):
		if n.has_meta("feedback_id"):
			parts.push_front(String(n.get_meta("feedback_id")))
			return scene + "/" + "/".join(parts)
		var nm := String(n.name)
		parts.push_front(n.get_class() if nm.begins_with("@") else nm)
		n = n.get_parent()
	return scene + "/" + "/".join(parts)

## A random per-INSTALL id, so reports can be grouped ("this reporter has filed nine") and a bad
## actor dropped, without accounts and without anything identifying. Generated once, kept beside
## the outbox. Not a user id: reinstalling makes a new one, and that is fine.
func _install_id() -> String:
	var p := InputModel.support_dir().path_join("install_id.txt")
	if FileAccess.file_exists(p):
		var rf := FileAccess.open(p, FileAccess.READ)
		if rf != null:
			var got := rf.get_as_text().strip_edges()
			if got != "":
				return got
	var made := str(randi()).sha256_text().substr(0, 16)
	var wf := FileAccess.open(p, FileAccess.WRITE)
	if wf != null:
		wf.store_string(made)
		wf.close()
	return made

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
	panel.custom_minimum_size = Vector2(560, 0)
	# A CENTERCONTAINER, not PRESET_CENTER. The preset anchors all four sides to 0.5 and the panel
	# then GROWS DOWNWARD from the middle of the screen — so a form taller than half the window
	# runs off the bottom. It always did: at 1080 the hint row and the Save/Cancel buttons were
	# already past the edge, which went unnoticed because the shortcuts in the hint (Cmd+Enter /
	# Esc) work without them. Adding the consent rows made it obvious by pushing the checkbox out
	# too. CenterContainer centres on BOTH axes and respects the child's minimum size.
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	centre.add_child(panel)

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

	# The element itself, cropped from the frame the user was looking at, in a zoom/pan
	# viewer: wheel zooms around the cursor, drag pans, [Fit]/[1:1] snap the view.
	if _thumb != null:
		v.add_child(_make_shot_viewer())

	_edit = TextEdit.new()
	_edit.custom_minimum_size = Vector2(0, 120)
	_edit.placeholder_text = "What should be different about this element?"
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	v.add_child(_edit)

	# WHAT LEAVES THE MACHINE, SPELLED OUT, BEFORE IT DOES. This is the whole reason in-game
	# feedback beats "screenshot it yourself and post it": the report carries state the reporter
	# never had to assemble — which means it also carries state they never consciously chose to
	# send. Nobody reads a JSON line before submitting. So the form says it in a sentence, and the
	# one component that can hold something unintended (the picture) is the one they can drop.
	# Cheap as a label now; a migration and an apology after launch.
	# Names the KINDS of thing, not their values: the element is already displayed above, and a
	# raw element_key is both long enough to wrap the panel off the bottom of the screen and
	# meaningless to the person being asked to consent to it.
	var manifest := Label.new()
	manifest.text = "Sends: your note, the element you picked, and %s %s on %s." % [
		Brand.GAME_NAME, Brand.RAVES_VERSION, OS.get_name()]
	manifest.add_theme_color_override("font_color", QudChrome.q8(96, 156, 170))
	manifest.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(manifest)

	if _thumb != null:
		var shot_box := CheckBox.new()
		shot_box.text = "Include image"
		shot_box.button_pressed = _attach_shot
		shot_box.focus_mode = Control.FOCUS_NONE   # never steal the ACCEPT key from the note
		shot_box.add_theme_color_override("font_color", QudChrome.q8(96, 156, 170))
		shot_box.toggled.connect(func(on: bool): _attach_shot = on)
		v.add_child(shot_box)

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
	UiState.set_popup("feedback", "feedback", layer, true)

## The crop viewer: a clipped window onto the element image with zoom + pan. Wheel zooms
## about the cursor (the texture point under it stays put), left-drag pans, and the two
## buttons snap the classic views — Fit (contain, upscaling allowed so a tiny ability cell
## reads) and 1:1 (one texture pixel per screen pixel). Buttons are FOCUS_NONE so keyboard
## focus never leaves the note field; nearest filtering keeps zoomed pixels crisp.
func _make_shot_viewer() -> Control:
	var tsz := _thumb.get_size()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)

	var view := Control.new()
	view.clip_contents = true
	# 150, not 200: the consent rows below the note field cost ~50px, and PRESET_CENTER grows a
	# panel off the bottom of a 1080 screen without complaining — the manifest and the checkbox
	# were both drawn past y=1080 and invisible. A consent control you cannot see is worse than
	# none, since it reads as agreement nobody was offered.
	view.custom_minimum_size = Vector2(532, 150)
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	var img := TextureRect.new()
	img.texture = _thumb
	img.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	img.stretch_mode = TextureRect.STRETCH_SCALE
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.add_child(img)

	var st := {"scale": 1.0, "drag": false}
	# scale to s, keeping the texture point tex_px under the viewport point at
	var apply := func(s: float, tex_px: Vector2, at: Vector2) -> void:
		st.scale = clampf(s, 0.1, 16.0)
		img.size = tsz * st.scale
		img.position = at - tex_px * st.scale
	var vsize := func() -> Vector2:
		return view.size if view.size.x > 0.0 else view.custom_minimum_size
	var fit := func() -> void:
		var vs: Vector2 = vsize.call()
		apply.call(minf(vs.x / tsz.x, vs.y / tsz.y), tsz * 0.5, vs * 0.5)
	var one := func() -> void:
		apply.call(1.0, tsz * 0.5, vsize.call() * 0.5)

	view.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				apply.call(st.scale * 1.25, (mb.position - img.position) / st.scale, mb.position)
			elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				apply.call(st.scale / 1.25, (mb.position - img.position) / st.scale, mb.position)
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				st.drag = mb.pressed
		elif e is InputEventMouseMotion and st.drag:
			img.position += (e as InputEventMouseMotion).relative)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 8)
	var bfit := Button.new()
	bfit.text = "Fit"
	bfit.focus_mode = Control.FOCUS_NONE
	bfit.pressed.connect(fit)
	var b11 := Button.new()
	b11.text = "1:1"
	b11.focus_mode = Control.FOCUS_NONE
	b11.pressed.connect(one)
	bar.add_child(bfit)
	bar.add_child(b11)
	col.add_child(bar)
	col.add_child(view)
	# initial view = Fit, deferred so the container has laid the viewer out first
	fit.call_deferred()
	return col

func _close(save: bool) -> void:
	if save and _edit != null and _edit.text.strip_edges() != "":
		_append_record(_edit.text.strip_edges())
	if _form != null:
		_form.queue_free()
		_form = null
	_edit = null
	UiState.clear_popup("feedback")
	if _prev_focus != null and is_instance_valid(_prev_focus):
		_prev_focus.grab_focus()
	_prev_focus = null

# --- persistence ---------------------------------------------------------------------------------

func _append_record(text: String) -> void:
	# THE ENVELOPE. Deliberately product-agnostic in its first six fields so the same shape can
	# carry feedback from other apps later: what/where/who-installed/which-build, then the
	# app-specific bits. `v` is the schema version — a reader that meets an envelope it does not
	# understand should keep it, not drop it, and the number is how it decides.
	#
	# app_version and platform are not optional extras. A report you cannot pin to an exact build
	# is close to worthless: "it's broken" against an unknown binary is a conversation, not a bug.
	var rec := {
		"v": 1,
		"app": Brand.GAME_NAME,
		"app_version": Brand.RAVES_VERSION,
		"platform": OS.get_name(),
		"install_id": _install_id(),
		"ts": Time.get_datetime_string_from_system(true),   # UTC, sortable
		"scene": UiState.scene(),
		"mode": "1to1" if Settings.one_to_one() else "user",
		"element": _target_label,
		"element_key": _element_key_cached,
		# NOT an identity — a per-run instance path, kept for local debugging only. See _element_key.
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
	#
	# ...unless the reporter said not to. A screenshot is the one part of this payload that can
	# carry something they did not mean to send, so it is the one part they can drop, and the
	# record says which they chose rather than leaving a reader to infer it from an absent file.
	# [deleteme] — THE TEST-REPORT MARKER. Verifying this feature means filing reports through it,
	# and ten of those landed in the real outbox on 2026-08-10 and had to be picked out by hand
	# afterwards. A marker in the NOTE is the affordance (anyone can type it, on any machine, with
	# no tooling); `test` is the machine contract, resolved once here so no consumer has to
	# string-match. Readers skip these — see tools/feedback.py — and the server should drop them at
	# the door rather than store and filter.
	if text.to_lower().contains("[deleteme]"):
		rec["test"] = true
	rec["shot_attached"] = _attach_shot
	if _thumb != null and _attach_shot:
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
	# ...and try to send it NOW. A report is most worth having while the thing it describes is still
	# on screen, and flushing here means the common case never waits for a restart. Offline or a
	# dead endpoint costs nothing: the line stays in the outbox and the next flush picks it up.
	if _submitter != null:
		_submitter.flush()

extends CanvasLayer

## THE CONTROL MAPPING SCREEN — Qud's keybinds view (system menu → Control Mapping), 1:1.
##
## Read-only v1: renders bindings.json (mod BindingsExporter — Qud's own formatted bind
## strings via CommandBindingManager.GetCommandBindings) as Qud draws it: gold letter-
## spaced title + search, "Configuring Controller:" line, the right-aligned category
## rail, per-category "[-] NAME" sections with 4 bind columns (║ separators), dim
## "None" for unbound slots, a pale frame on the selected cell, and the bottom hint
## bar. Rebinding stays in Qud for now — Space/Delete/+ are drawn but inert.
##
## DELIBERATE DEVIATION (Daniel, 2026-08-04): behind the modern list Qud leaves its
## legacy console view stuck on "Control Mapping / Loading… / [Esc] Back" inside a
## pale frame with a translucent tint (the modern screen never finishes the console
## handoff). We ported it faithfully first (measured from reports/2026-08-04-status-
## screens/controlmap_qud.png, converged at 5.56 mean-diff), then HID it — it makes
## the real content hard to read. SHOW_GHOST=true restores full parity for measuring.
##
## CanvasLayer 90 (under the CRT at 100), same slot as StatusScreens. Esc closes AND
## sends the bridge "uiback" so Qud leaves its KeybindsScreen in step.

signal closed

# Qud's bind strings carry CP437 arrows — map to the real glyphs client-side
const ARROWS := {24: "↑", 25: "↓", 26: "→", 27: "←"}

# Godot keycode → Unity InputSystem <Keyboard>/ control name, for rebinding. The mod
# validates with InputSystem.FindControl and pops a visible error on a bad name.
const UNITY_KEYS := {
	KEY_SPACE: "space", KEY_ENTER: "enter", KEY_TAB: "tab", KEY_BACKSPACE: "backspace",
	KEY_DELETE: "delete", KEY_INSERT: "insert", KEY_HOME: "home", KEY_END: "end",
	KEY_PAGEUP: "pageUp", KEY_PAGEDOWN: "pageDown",
	KEY_UP: "upArrow", KEY_DOWN: "downArrow", KEY_LEFT: "leftArrow", KEY_RIGHT: "rightArrow",
	KEY_QUOTELEFT: "backquote", KEY_APOSTROPHE: "quote", KEY_SEMICOLON: "semicolon",
	KEY_COMMA: "comma", KEY_PERIOD: "period", KEY_SLASH: "slash", KEY_BACKSLASH: "backslash",
	KEY_BRACKETLEFT: "leftBracket", KEY_BRACKETRIGHT: "rightBracket",
	KEY_MINUS: "minus", KEY_EQUAL: "equals",
	KEY_KP_ADD: "numpadPlus", KEY_KP_SUBTRACT: "numpadMinus", KEY_KP_MULTIPLY: "numpadMultiply",
	KEY_KP_DIVIDE: "numpadDivide", KEY_KP_PERIOD: "numpadPeriod", KEY_KP_ENTER: "numpadEnter",
}

# Measured colours. NOT q8: capture-fitting THIS screen (solid border/bg/text pairs,
# round 2) gave `captured ≈ drawn - 6` above the dark knee — q8's ×1.13 overshoots
# every pale here. Local compensation: +6 per channel above 20, identity below.
static func _cm8(r8: int, g8: int, b8: int) -> Color:
	return Color8(r8 if r8 <= 20 else r8 + 6, g8 if g8 <= 20 else g8 + 6, b8 if b8 <= 20 else b8 + 6)

var C_BG := _cm8(17, 33, 38)
var C_GHOST_TINT := _cm8(17, 52, 51)
var C_GHOST_FRAME := _cm8(168, 194, 187)
var C_GHOST_TEXT := _cm8(137, 122, 83)
var C_TITLE := _cm8(200, 184, 57)
var C_LABEL := _cm8(108, 183, 200)      # config line + section headers
var C_NAME := _cm8(100, 172, 188)       # command names
var C_BIND := _cm8(56, 154, 176)        # bound key strings
var C_NONE := _cm8(21, 73, 72)          # unbound "None"
var C_RAIL := _cm8(70, 130, 140)        # category rail items
var C_SEP := _cm8(65, 106, 115)         # ║ separators / rail markers / dotted divider
var C_SEL := _cm8(168, 194, 187)        # selected-cell frame
var C_HINT := _cm8(167, 192, 186)

# the ghost legacy-console view — see the deviation note in the header
const SHOW_GHOST := false

# geometry (1920x1080 design space, measured)
const BG_RECT := Rect2(0, 90, 1620, 900)
const GHOST_RECT := Rect2(8, 173, 1604, 734)
const LIST_X := 325.0            # clip left edge
const LIST_Y := 140.0            # clip top
const LIST_H := 908.0            # clip height — Qud's rows overflow the bg down to ~y1048
const LIST_W := 1295.0
const NAME_X := 380.0            # command-name column (abs)
const NAME_W := 250.0            # wrap width before a row doubles
const CELL_X0 := 645.0           # first bind cell left (abs)
const CELL_PITCH := 127.0
const CELL_W := 110.0
const ROW_H := 27.0
const HEADER_H := 27.0
const SECTION_GAP := 14.0

var _root: Control
var _static: Control             # bg + ghost + title + rail (redraws only on data change)
var _clip: Control
var _content: Control
var _search: LineEdit
var _hint: RichTextLabel

var _cats: Array = []            # bindings.json categories, arrows mapped
var _mtime := 0
var _filter := ""
var _scroll := 0.0
var _content_h := 0.0
var _sel_row := 0                # index into the VISIBLE row list
var _sel_col := 0
var _rows: Array = []            # layout: {y,h,display,binds} rows only (headers drawn separately)
var _blocks: Array = []          # layout: headers + section extents for separators
var _rail_rects: Array = []      # per-category hover hit areas (built in _draw_static)
var _rail_active := 0            # category the list last jumped to — its marker draws gold
var _capture := false            # true while the selected cell waits for the new key
var _peer := StreamPeerTCP.new()
var _out_queue: Array = []       # edits waiting for the bridge socket to reconnect
var _flush_tries := 0
var _font_bold: Font = null

func _init() -> void:
	layer = 90
	visible = false

func _ready() -> void:
	name = "ControlMappingScreen"
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
	_font_bold = load("res://fonts/SourceCodePro-Semibold.ttf")   # Qud's title weight (Bold measured too heavy)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP     # modal while shown
	_root.theme = UiFont.make_theme(get_viewport())    # CanvasLayer theme-root trap
	_root.gui_input.connect(_root_input)
	add_child(_root)

	_static = Control.new()
	_static.set_anchors_preset(Control.PRESET_FULL_RECT)
	_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_static.draw.connect(_draw_static)
	_root.add_child(_static)

	_clip = Control.new()
	_clip.position = Vector2(LIST_X, LIST_Y)
	_clip.size = Vector2(LIST_W, LIST_H)
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_clip)
	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.draw.connect(_draw_content)
	_clip.add_child(_content)

	_search = LineEdit.new()
	_search.position = Vector2(612, 76)
	_search.size = Vector2(146, 26)
	_search.placeholder_text = "<search>"
	_search.add_theme_font_size_override("font_size", 14)
	_search.add_theme_color_override("font_color", C_HINT)
	_search.add_theme_color_override("font_placeholder_color", C_SEP)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(2, 22, 22)          # measured: Qud's box interior is DARKER than the bg
	sb.set_border_width_all(1)
	sb.border_color = _cm8(60, 84, 92)
	sb.content_margin_left = 6
	_search.add_theme_stylebox_override("normal", sb)
	_search.text_changed.connect(func(t: String):
		_filter = t.strip_edges().to_lower()
		_relayout())
	_root.add_child(_search)

	_build_hints()

# ── open / close ───────────────────────────────────────────────────────────────

func open() -> void:
	visible = true
	_scroll = 0.0
	_sel_row = 0
	_sel_col = 0
	UiState.set_scene("control_mapping")
	_request_export()
	_load_bindings()
	# the fresh export may land AFTER the first read — poll the mtime once more
	get_tree().create_timer(1.2).timeout.connect(func():
		if visible:
			_load_bindings())

## `sync_qud=false` when Qud already left the screen on its own (avoid a double back).
func close(sync_qud := true) -> void:
	visible = false
	UiState.set_scene("in_game")
	if sync_qud:
		_send_bridge({"type": "command", "name": "uiback"})
	closed.emit()

func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	# CAPTURE MODE: the selected cell owns the next keypress (Esc cancels; bare
	# modifiers wait for the real key — same feel as Qud's own capture)
	if _capture:
		if e is InputEventKey and e.pressed and not e.echo:
			_capture_key(e)
			get_viewport().set_input_as_handled()
		return
	if e.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed:
		var used := true
		match e.keycode:
			KEY_UP, KEY_KP_8:    _move_sel(-1)
			KEY_DOWN, KEY_KP_2:  _move_sel(1)
			KEY_LEFT, KEY_KP_4:  _sel_col = maxi(0, _sel_col - 1)
			KEY_RIGHT, KEY_KP_6: _sel_col = mini(3, _sel_col + 1)
			KEY_PAGEUP:          _scroll_by(-LIST_H * 0.9)
			KEY_PAGEDOWN:        _scroll_by(LIST_H * 0.9)
			KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
				_start_capture()
			KEY_DELETE, KEY_BACKSPACE:
				_send_edit({"action": "remove"})
			KEY_KP_ADD, KEY_PLUS:
				_send_edit({"action": "defaults"})
			KEY_EQUAL:
				if e.shift_pressed:              # "+" on a US layout
					_send_edit({"action": "defaults"})
				else:
					used = false
			_:                   used = false
		if used:
			_content.queue_redraw()
			get_viewport().set_input_as_handled()

# ── rebinding (mod KeybindApplier applies via Qud's own CommandBindingManager;
#    confirm/conflict popups mirror back through the popup bridge) ─────────────

func _start_capture() -> void:
	if _rows.is_empty() or _sel_row >= _rows.size():
		return
	if _rows[_sel_row].has("action"):
		_send_edit({"action": str(_rows[_sel_row]["action"])})   # RAVES action row
		return
	_capture = true
	_content.queue_redraw()

func _capture_key(e: InputEventKey) -> void:
	var kc := e.keycode
	if kc == KEY_ESCAPE:
		_capture = false
		_content.queue_redraw()
		return
	if kc in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK]:
		return   # modifier alone — keep waiting for the real key
	var uname := ""
	if kc >= KEY_A and kc <= KEY_Z:
		uname = char(kc).to_lower()
	elif kc >= KEY_0 and kc <= KEY_9:
		uname = char(kc)
	elif kc >= KEY_KP_0 and kc <= KEY_KP_9:
		uname = "numpad%d" % (kc - KEY_KP_0)
	elif kc >= KEY_F1 and kc <= KEY_F12:
		uname = "f%d" % (kc - KEY_F1 + 1)
	elif UNITY_KEYS.has(kc):
		uname = UNITY_KEYS[kc]
	if uname == "":
		_capture = false   # unmappable key — drop out visibly rather than mis-bind
		_content.queue_redraw()
		return
	_capture = false
	_send_edit({"action": "set", "key": uname,
		"ctrl": "1" if e.ctrl_pressed else "0",
		"shift": "1" if e.shift_pressed else "0",
		"alt": "1" if e.alt_pressed else "0"})
	_content.queue_redraw()

## Send a rebind edit for the SELECTED cell and poll for the refreshed export.
func _send_edit(fields: Dictionary) -> void:
	if _rows.is_empty() or _sel_row >= _rows.size():
		return
	# an action row has no cell to set/remove — only its own action (or defaults) applies
	if _rows[_sel_row].has("action") and str(fields.get("action", "")) in ["set", "remove"]:
		return
	var msg := {"type": "command", "name": "rebind",
		"id": str(_rows[_sel_row]["id"]), "slot": str(_sel_col)}
	msg.merge(fields)
	_send_bridge(msg)
	# the apply is async in Qud (may raise a mirrored confirm popup first) — poll
	# the export a few times so the new value shows up whenever it lands
	for delay in [0.8, 1.8, 3.5, 6.0]:
		get_tree().create_timer(delay).timeout.connect(func():
			if visible:
				_load_bindings())

func _root_input(e: InputEvent) -> void:
	# CONSUME MOUSE EVENTS — MOUSE_FILTER_STOP does not stop the WHEEL, which Godot
	# propagates up the Control chain until someone calls accept_event(). Found by the
	# modal-input audit after the same leak was reported on the skills screen
	# (2026-08-10): scrolling this list would otherwise zoom the playfield behind it.
	if e is InputEventMouseButton or e is InputEventMouseMotion:
		_root.accept_event()
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_by(-ROW_H * 2)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_by(ROW_H * 2)
		elif e.button_index == MOUSE_BUTTON_LEFT and not _capture:
			_click_select(e.position)
	elif e is InputEventMouseMotion:
		for i in _rail_rects.size():
			if _rail_rects[i].has_point(e.position):
				if i != _rail_active:
					_rail_active = i
					_jump_to_cat(i)
					_static.queue_redraw()
				return

## Click a bind cell to select it; a second click on the selected cell starts capture.
func _click_select(pos: Vector2) -> void:
	if pos.x < LIST_X or pos.x > LIST_X + LIST_W or pos.y < LIST_Y or pos.y > LIST_Y + LIST_H:
		return
	var cy := pos.y - LIST_Y + _scroll
	for ri in _rows.size():
		var r: Dictionary = _rows[ri]
		if cy >= r["y"] and cy < r["y"] + r["h"]:
			if r.has("action"):
				# action rows have no cells — a second click on the selected row RUNS it
				if ri == _sel_row:
					_start_capture()
				else:
					_sel_row = ri
				_content.queue_redraw()
				return
			var col := int(floor((pos.x - CELL_X0) / CELL_PITCH))
			if pos.x >= CELL_X0 and col >= 0 and col <= 3 \
					and pos.x - (CELL_X0 + col * CELL_PITCH) <= CELL_W:
				if ri == _sel_row and col == _sel_col:
					_start_capture()
				else:
					_sel_row = ri
					_sel_col = col
			else:
				_sel_row = ri   # clicking the name selects the row, keeps the column
			_content.queue_redraw()
			return

## Scroll the list so category `ci`'s section header sits at the top of the view.
func _jump_to_cat(ci: int) -> void:
	for b in _blocks:
		if int(b["cat"]) == ci:
			_scroll = clampf(b["y"] - 8.0, 0.0, maxf(0.0, _content_h - LIST_H))
			_content.queue_redraw()
			return

func _move_sel(dir: int) -> void:
	if _rows.is_empty():
		return
	_sel_row = clampi(_sel_row + dir, 0, _rows.size() - 1)
	# keep the selected row in view
	var r: Dictionary = _rows[_sel_row]
	var top: float = r["y"] - _scroll
	if top < 0:
		_scroll = maxf(0.0, r["y"])
	elif top + r["h"] > LIST_H:
		_scroll = r["y"] + r["h"] - LIST_H

func _scroll_by(dy: float) -> void:
	_scroll = clampf(_scroll + dy, 0.0, maxf(0.0, _content_h - LIST_H))
	_content.queue_redraw()

# ── data ───────────────────────────────────────────────────────────────────────

## Send over our own bridge peer; a dead socket (Qud restarted) queues the message
## and flushes once reconnected — an edit must never be silently dropped.
func _send_bridge(msg: Dictionary) -> void:
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_out_queue.append(msg)
		_peer.disconnect_from_host()
		_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		_flush_tries = 0
		get_tree().create_timer(0.5).timeout.connect(_flush_queue)
		return
	_put_frame(msg)

func _flush_queue() -> void:
	if _out_queue.is_empty():
		return
	_peer.poll()
	if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		for m in _out_queue:
			_put_frame(m)
		_out_queue.clear()
		return
	_flush_tries += 1
	if _flush_tries < 10:
		_peer.disconnect_from_host()
		_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		get_tree().create_timer(0.5).timeout.connect(_flush_queue)
	else:
		_out_queue.clear()   # Qud is gone — dropping beats replaying stale edits later

func _put_frame(msg: Dictionary) -> void:
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var frame := PackedByteArray()
	var n := payload.size()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

func _request_export() -> void:
	_send_bridge({"type": "command", "name": "export"})

func _load_bindings() -> void:
	var path := InputModel.support_dir().path_join("bindings.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if mt == _mtime and not _cats.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)   # strip a UTF-8 BOM — JSON.parse_string rejects it
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_mtime = mt
	_cats = []
	for cat in data.get("categories", []):
		var cmds: Array = []
		for c in cat.get("commands", []):
			cmds.append({
				"id": str(c.get("id", "")),
				"display": str(c.get("display", "")),
				"binds": [_map_arrows(str(c.get("b1", ""))), _map_arrows(str(c.get("b2", ""))),
					_map_arrows(str(c.get("b3", ""))), _map_arrows(str(c.get("b4", "")))],
			})
		_cats.append({"name": str(cat.get("name", "")), "commands": cmds})
	_relayout()
	_static.queue_redraw()

func _map_arrows(s: String) -> String:
	var out := s
	for code in ARROWS:
		out = out.replace(String.chr(code), ARROWS[code])
	return out

# ── layout ─────────────────────────────────────────────────────────────────────

func _relayout() -> void:
	_rows = []
	_blocks = []
	var fnt := _root.get_theme_font("font", "Label")
	var y := 8.0
	for ci in _cats.size():
		var cat: Dictionary = _cats[ci]
		var shown: Array = []
		for c in cat["commands"]:
			if _filter == "" or str(c["display"]).to_lower().find(_filter) >= 0:
				shown.append(c)
		if shown.is_empty():
			continue
		_blocks.append({"y": y, "cat": ci, "title": "[-] " + str(cat["name"]).to_upper()})
		y += HEADER_H
		var first_row_y := y
		for c in shown:
			var lines := _wrap(fnt, str(c["display"]), NAME_W, 16)
			var h := ROW_H * maxf(1.0, lines.size())
			_rows.append({"y": y, "h": h, "id": c["id"], "lines": lines, "binds": c["binds"]})
			y += h
		_blocks[_blocks.size() - 1]["rows_y0"] = first_row_y
		_blocks[_blocks.size() - 1]["rows_y1"] = y
		y += SECTION_GAP
	# USER MODE ONLY (hidden in 1:1 — no Qud counterpart): a Raves category with
	# the golden-restore action (the mod snapshots the original map before the
	# first Raves-side edit; this puts it back wholesale).
	if not Settings.qud_shape() and not _cats.is_empty() and _filter == "":
		_blocks.append({"y": y, "cat": _cats.size(), "title": "[-] RAVES", "plain": true})
		y += HEADER_H
		_blocks[_blocks.size() - 1]["rows_y0"] = y
		for act in [["golden", "Restore golden control mapping"],
				["regolden", "Save current bindings as golden"]]:
			_rows.append({"y": y, "h": ROW_H, "id": "", "action": act[0],
				"lines": [act[1]], "binds": ["", "", "", ""]})
			y += ROW_H
		_blocks[_blocks.size() - 1]["rows_y1"] = y
		y += SECTION_GAP
	_content_h = y
	_content.size = Vector2(LIST_W, maxf(LIST_H, _content_h))
	_scroll = clampf(_scroll, 0.0, maxf(0.0, _content_h - LIST_H))
	_sel_row = clampi(_sel_row, 0, maxi(0, _rows.size() - 1))
	_content.queue_redraw()

func _wrap(fnt: Font, text: String, width: float, size: int) -> Array:
	if fnt.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width:
		return [text]
	var lines: Array = []
	var cur := ""
	for w in text.split(" "):
		var cand := w if cur == "" else cur + " " + w
		if fnt.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width or cur == "":
			cur = cand
		else:
			lines.append(cur)
			cur = w
	if cur != "":
		lines.append(cur)
	return lines

# ── drawing ────────────────────────────────────────────────────────────────────

func _draw_static() -> void:
	var fnt := _root.get_theme_font("font", "Label")
	_static.draw_rect(BG_RECT, C_BG)

	# the ghost legacy-console view: tint + frame + stuck text (hidden by default —
	# deliberate deviation, see the header comment)
	if SHOW_GHOST:
		_static.draw_rect(GHOST_RECT, C_GHOST_TINT)
		var g := GHOST_RECT
		_static.draw_rect(Rect2(g.position.x, g.position.y, g.size.x, 5), C_GHOST_FRAME)
		_static.draw_rect(Rect2(g.position.x, g.end.y - 5, g.size.x, 5), C_GHOST_FRAME)
		_static.draw_rect(Rect2(g.position.x, g.position.y, 5, g.size.y), C_GHOST_FRAME)
		_static.draw_rect(Rect2(g.end.x - 5, g.position.y, 5, g.size.y), C_GHOST_FRAME)
		_static.draw_string(fnt, Vector2(304, 185), "Control Mapping", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, C_GHOST_TEXT)
		_static.draw_string(fnt, Vector2(59, 489), "Loading...", HORIZONTAL_ALIGNMENT_LEFT, -1, 35, C_GHOST_TEXT)
		_static.draw_string(fnt, Vector2(57, 552), "<", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, C_GHOST_TEXT)
		_static.draw_string(fnt, Vector2(29, 583), "[Esc] Back", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GHOST_TEXT)

	# title + magnifier + config line (Qud's "letterspacing" is just the bigger font —
	# SCP advance = 0.6*size lands the measured 15.7px/char at size 26 exactly; the
	# weight is the BOLD face, not tracking)
	_static.draw_string(_font_bold if _font_bold != null else fnt, Vector2(331, 97),
		"CONTROL MAPPING", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, C_TITLE)
	_static.draw_arc(Vector2(590, 83), 5, 0, TAU, 12, C_HINT, 1.5)
	_static.draw_line(Vector2(594, 87), Vector2(599, 93), C_HINT, 1.5)
	var lbl := "Configuring Controller: "
	_static.draw_string(fnt, Vector2(333, 121), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_LABEL)
	var lw := fnt.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	_static.draw_string(fnt, Vector2(333 + lw, 121), "Keyboard & Mouse",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_BIND)

	# category rail: right-aligned at x279, wrap at 130, small marker beside each item.
	# Hovering an item jumps the list to that category (its marker goes gold) — the
	# hit rects are rebuilt here so they always match what was actually drawn.
	_rail_rects.clear()
	var ry := 173.0
	for ci in _cats.size():
		var lines := _wrap(fnt, str(_cats[ci]["name"]), 130.0, 16)
		for i in lines.size():
			var w := fnt.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			_static.draw_string(fnt, Vector2(279 - w, ry + i * 21), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_RAIL)
		_static.draw_rect(Rect2(285, ry - 8, 3, 3),
			C_TITLE if ci == _rail_active else C_SEP)
		_rail_rects.append(Rect2(149, ry - 14, 146, lines.size() * 21 + 6))
		ry += lines.size() * 21 + 9
	# the user-mode-only RAVES section's rail entry (see _relayout)
	if not Settings.qud_shape() and not _cats.is_empty():
		var rw := fnt.get_string_size("Raves", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_static.draw_string(fnt, Vector2(279 - rw, ry), "Raves",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_RAIL)
		_static.draw_rect(Rect2(285, ry - 8, 3, 3),
			C_TITLE if _rail_active == _cats.size() else C_SEP)
		_rail_rects.append(Rect2(149, ry - 14, 146, 27))

	# dotted rail divider
	var dy := 150.0
	while dy < 985.0:
		_static.draw_rect(Rect2(317, dy, 1, 4), C_SEP)
		dy += 8.0

func _draw_content() -> void:
	var fnt := _root.get_theme_font("font", "Label")
	var off := -_scroll
	for b in _blocks:
		var hy: float = b["y"] + off
		if hy + HEADER_H >= 0 and hy <= LIST_H:
			_content.draw_string(fnt, Vector2(378 - LIST_X, hy + 17), b["title"],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 22, C_LABEL)
		# ║ column separators span the section's rows
		var s0: float = clampf(b["rows_y0"] + off, 0.0, LIST_H)
		var s1: float = clampf(b["rows_y1"] + off, 0.0, LIST_H)
		if s1 > s0 and not b.get("plain", false):
			for i in range(1, 4):
				var sx := CELL_X0 + CELL_PITCH * i - 11.0 - LIST_X
				_content.draw_rect(Rect2(sx, s0, 1, s1 - s0), C_SEP)
				_content.draw_rect(Rect2(sx + 3, s0, 1, s1 - s0), C_SEP)
	for ri in _rows.size():
		var r: Dictionary = _rows[ri]
		var ry: float = r["y"] + off
		if ry + r["h"] < 0 or ry > LIST_H:
			continue
		var lines: Array = r["lines"]
		for i in lines.size():
			_content.draw_string(fnt, Vector2(NAME_X - LIST_X, ry + 16 + i * 21), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_NAME)
		if r.has("action"):
			# action row (RAVES section): no bind cells — selection frames the name,
			# Space / a second click runs it
			if ri == _sel_row:
				var nw := fnt.get_string_size(str(lines[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
				_content.draw_rect(Rect2(NAME_X - LIST_X - 6, ry, nw + 12, 23),
					C_TITLE if _capture else C_SEL, false, 1.0)
			continue
		var mid: float = ry + r["h"] * 0.5 - 2.0
		for col in 4:
			var cx := CELL_X0 + CELL_PITCH * col - LIST_X
			var t: String = r["binds"][col]
			var bound := t != ""
			var col_color := C_BIND if bound else C_NONE
			if not bound:
				t = "None"
			if _capture and ri == _sel_row and col == _sel_col:
				t = "press key"
				col_color = C_TITLE
			var size := 16
			if fnt.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x > CELL_W - 4:
				size = 11
			var tw := fnt.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			_content.draw_string(fnt, Vector2(cx + (CELL_W - tw) * 0.5, mid + size * 0.36), t,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, col_color)
			if ri == _sel_row and col == _sel_col:
				var fr := Rect2(cx + 1, ry, CELL_W, 23)
				_content.draw_rect(fr, C_TITLE if _capture else C_SEL, false, 1.0)

# ── bottom hints ───────────────────────────────────────────────────────────────

func _build_hints() -> void:
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.fit_content = true
	_hint.scroll_active = false
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("normal_font_size", 16)
	var wht := "#FFFFFF"
	var dimc := "#%s" % C_HINT.to_html(false)
	var goldc := "#%s" % C_TITLE.to_html(false)
	_hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	_hint.append_text("[color=%s][lb][/color]" % wht)
	_hint.add_image(QudChrome.nav_icon(15), 22, 15)
	_hint.append_text("[color=%s][rb][/color]" % wht)
	_hint.append_text("[color=%s] navigate  [/color]" % dimc)
	for k in [["Space", "select"], ["Delete", "remove keybind"], ["+", "restore defaults"]]:
		_hint.append_text("[color=%s][lb][/color][color=%s]%s[/color][color=%s][rb][/color]" % [wht, goldc, k[0], wht])
		_hint.append_text("[color=%s] %s  [/color]" % [dimc, k[1]])
	_hint.pop()
	# Qud centres this row on x~745, BELOW the ability-label line (hints y≈1058-1075)
	var hc := CenterContainer.new()
	hc.position = Vector2(-9, 1052)
	hc.size = Vector2(1400, 28)
	hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hc.add_child(_hint)
	_root.add_child(hc)
extends Control

## THE OPTIONS SCREEN — a 1:1 mirror of Caves of Qud's Options, in Qud's layout.
##
## A full-screen scrollable panel (OPTIONS header, left category sidebar, sections) over a
## darkened cave-art backdrop. A "RAVES" section of Raves' OWN settings (editable, persisted
## via [[Settings]]) sits on top; below it, QUD'S FULL OPTIONS TREE is mirrored from the mod's
## export (options.json — every category + option: label, type, current value, values), so the
## same categories/options/wording appear here as in Qud. Qud's options are DISPLAY (a mirror)
## for now — read from the player's install, never redistributed; write-back (updating Qud from
## Raves via Options.SetOption) is the next phase. Opened as an overlay by MainMenu; Back closes.

signal closed

const GOLD := Color8(0xC8, 0xA9, 0x4E)
const CYAN := Color8(0x6E, 0xB5, 0xC9)
const LABEL := Color8(0xE4, 0xD8, 0xB8)
const VALUE := Color8(0xC8, 0xA9, 0x4E)
const SEL := Color8(0xF6, 0xF6, 0xF6)
const DIM := Color(0.89, 0.85, 0.72, 0.5)
const FRAME := Color8(0xB6, 0xA1, 0x63)

## Raves' own editable settings (persisted to settings.json).
const RAVES_ITEMS := [
	{"key": "font_scale", "label": "Font scale", "type": "slider", "min": 0.7, "max": 1.5, "step": 0.05},
	{"key": "fullscreen", "label": "Fullscreen", "type": "toggle"},
	{"key": "full_info", "label": "Show full info by default", "type": "toggle"},
	{"key": "camera", "label": "Default camera", "type": "options",
		"options": ["Compass", "Follow", "First person", "Cinematic", "Mouse", "Keyboard", "Top follow"]},
	{"key": "bridge_host", "label": "Host", "type": "text"},
	{"key": "bridge_port", "label": "Port", "type": "text"},
]

var _scroll: ScrollContainer
var _body_col: VBoxContainer            # the reloadable option column (rebuilt on refresh)
var _anchors: Dictionary = {}          # category name -> its header Control (sidebar jumps)
var _qud_cats: Array = []              # Qud's options tree, from options.json
var _peer := StreamPeerTCP.new()       # bridge link for WRITE-BACK (setoption) while Qud is in-game
var _bridge := false
var _status: Label
# Auto-refresh-on-open: when the bridge connects, ask Qud to re-export NOW and reload the live tree.
var _refreshed := false                # export fired once this open
var _options_mtime := 0                # options.json mtime when we asked, to detect the rewrite
var _reload_deadline := 0             # ms fallback: reload even if the mtime second didn't tick
# Live fuzzy search + Advanced toggle. We filter by flipping each row's `visible` (no rebuild —
# keeps widget state and stays snappy across ~194 options); a category header/spacer hides when empty.
var _search := ""                      # current query (raw); matched case-insensitively
var _show_advanced := false            # reveal options Qud currently hides (visible=false)
var _sections: Array = []              # [{header, spacer, rows:[{node,label,hay,adv}]}]
var _search_edit: LineEdit
var _adv_btn: Button

func _ready() -> void:
	name = "OptionsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	_qud_cats = _load_qud_options()

	var bgtex := _load_png("title/background.png")
	if bgtex != null:
		var bg := TextureRect.new()
		bg.texture = bgtex
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(bg)
	var dark := ColorRect.new()
	dark.color = Color(0.02, 0.03, 0.035, 0.85 if bgtex != null else 1.0)
	dark.set_anchors_preset(Control.PRESET_FULL_RECT)
	dark.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dark)

	_build_header()
	_build_sidebar()
	_build_body()
	_build_footer()
	_add_back()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())   # for write-back to Qud

## Poll the bridge; Qud-option edits WRITE BACK only while a modded Qud is in-game (connected).
func _process(_dt: float) -> void:
	_peer.poll()
	_bridge = _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if _status != null:
		_status.text = "● editing Qud live" if _bridge else "○ Qud not connected — edits apply when it's in-game"
		_status.add_theme_color_override("font_color", Color8(0x5F, 0xC8, 0x5A) if _bridge else DIM)

	# Auto-refresh on open: the moment the bridge is up, ask Qud to re-export its options tree, then
	# reload options.json so the screen shows LIVE values (not whatever the last export left on disk).
	if _bridge and not _refreshed:
		_refreshed = true
		_options_mtime = _qud_json_mtime()
		_send_bridge({"type": "command", "name": "export"})
		_reload_deadline = Time.get_ticks_msec() + 1200   # fallback if the mtime second doesn't tick
	elif _refreshed and _reload_deadline > 0:
		if _qud_json_mtime() > _options_mtime or Time.get_ticks_msec() >= _reload_deadline:
			_reload_deadline = 0
			_reload_options()

## options.json modified time (seconds); 0 if absent. Used to detect Qud rewriting it after `export`.
func _qud_json_mtime() -> int:
	var path := InputModel.support_dir().path_join("options.json")
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0

## Reload the mirrored tree from disk and rebuild just the option column (sidebar/categories persist).
func _reload_options() -> void:
	_qud_cats = _load_qud_options()
	if _body_col == null:
		return
	for c in _body_col.get_children():
		c.queue_free()
	_anchors.clear()
	_populate_body()

## Write a Qud option back over the bridge (mod calls Options.SetOption). No-op if not connected.
func _set_qud_option(id: String, value) -> void:
	if id == "":
		return
	_send_bridge({"type": "command", "name": "setoption", "id": id, "value": str(value)})

## Frame + send one bridge message ([4-byte BE len][JSON]). No-op unless Qud is connected.
func _send_bridge(msg: Dictionary) -> void:
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

func _add_back() -> void:
	var b := Button.new()
	b.text = "‹ Back"
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", SEL)
	b.anchor_left = 0.02
	b.anchor_right = 0.14
	b.anchor_top = 0.93
	b.anchor_bottom = 0.985
	_zero(b)
	b.pressed.connect(func(): closed.emit())
	add_child(b)

# ── data ───────────────────────────────────────────────────────────────────────

func _load_qud_options() -> Array:
	var path := InputModel.support_dir().path_join("options.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.has("categories") and d["categories"] is Array:
		return d["categories"]
	return []

func _cat_names() -> Array:
	var out := ["Raves"]
	for c in _qud_cats:
		out.append(str(c.get("name", "?")))
	return out

func _load_png(rel: String) -> Texture2D:
	var path := InputModel.support_dir().path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

# ── layout ───────────────────────────────────────────────────────────────────────

func _build_header() -> void:
	var l := _label("OPTIONS", GOLD, "title")
	l.anchor_left = 0.17
	l.anchor_right = 0.45
	l.anchor_top = 0.045
	l.anchor_bottom = 0.095
	_zero(l)
	add_child(l)

	# Inline fuzzy search — Qud pops a modal "Enter search text" dialog (an extra step); Raves filters
	# the tree LIVE as you type, no dialog. Fuzzy: substring anywhere, or a subsequence of the label.
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search options…"
	_search_edit.clear_button_enabled = true
	_search_edit.add_theme_color_override("font_color", LABEL)
	_search_edit.anchor_left = 0.47
	_search_edit.anchor_right = 0.80
	_search_edit.anchor_top = 0.048
	_search_edit.anchor_bottom = 0.092
	_zero(_search_edit)
	_search_edit.text_changed.connect(_on_search)
	add_child(_search_edit)

	# Advanced toggle — reveal options Qud currently hides (Requires/capability not met, visible=false).
	_adv_btn = Button.new()
	_adv_btn.focus_mode = Control.FOCUS_NONE
	_adv_btn.flat = true
	_adv_btn.add_theme_color_override("font_color", CYAN)
	_adv_btn.add_theme_color_override("font_hover_color", SEL)
	_adv_btn.anchor_left = 0.82
	_adv_btn.anchor_right = 0.98
	_adv_btn.anchor_top = 0.048
	_adv_btn.anchor_bottom = 0.092
	_zero(_adv_btn)
	_adv_btn.text = _adv_label()
	_adv_btn.pressed.connect(_toggle_advanced)
	add_child(_adv_btn)

func _build_sidebar() -> void:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.anchor_left = 0.0
	sc.anchor_right = 0.155
	sc.anchor_top = 0.11
	sc.anchor_bottom = 0.9
	_zero(sc)
	add_child(sc)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	sc.add_child(v)
	for cat in _cat_names():
		var b := Button.new()
		b.text = cat
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.flat = true
		b.theme_type_variation = "Caption"
		b.add_theme_color_override("font_color", CYAN)
		b.add_theme_color_override("font_hover_color", SEL)
		b.pressed.connect(func(): _jump_to(cat))
		v.add_child(b)

func _build_body() -> void:
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.anchor_left = 0.17
	_scroll.anchor_right = 0.96
	_scroll.anchor_top = 0.11
	_scroll.anchor_bottom = 0.9
	_zero(_scroll)
	add_child(_scroll)
	_body_col = VBoxContainer.new()
	_body_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_col.add_theme_constant_override("separation", 5)
	_scroll.add_child(_body_col)
	_populate_body()

## Fill _body_col from the current _qud_cats. Split out of _build_body so a live refresh (after the
## bridge re-export) can clear + rebuild the column without touching the scroll/sidebar/header.
func _populate_body() -> void:
	_sections.clear()
	var col := _body_col

	# RAVES section — editable settings (searchable, never "advanced")
	var rheader := _section_header_node("Raves")
	col.add_child(rheader)
	var rrows: Array = []
	for item in RAVES_ITEMS:
		var rrow := _build_raves_setting(item)
		col.add_child(rrow)
		rrows.append(_row_meta(rrow, str(item.get("label", "")),
			str(item.get("label", "")) + " " + str(item.get("key", "")), false))
	var rsp := _spacer(12)
	col.add_child(rsp)
	_sections.append({"header": rheader, "spacer": rsp, "rows": rrows})

	# Qud's mirrored tree — every option is built once; the Advanced toggle + search decide what shows.
	for cat in _qud_cats:
		var header := _section_header_node(str(cat.get("name", "?")))
		col.add_child(header)
		var rows: Array = []
		for opt in cat.get("options", []):
			var row := _build_qud_option(opt)
			col.add_child(row)
			rows.append(_row_meta(row, str(opt.get("label", "")), _opt_hay(opt),
				not bool(opt.get("visible", true))))
		var sp := _spacer(12)
		col.add_child(sp)
		_sections.append({"header": header, "spacer": sp, "rows": rows})

	_apply_filter()

func _section_header_node(name: String) -> Label:
	var h := _label("[-]  " + name.to_upper(), CYAN, "title")
	_anchors[name] = h
	return h

# ── search + advanced filtering ─────────────────────────────────────────────────────

func _row_meta(node: Control, label: String, hay: String, adv: bool) -> Dictionary:
	return {"node": node, "label": label.to_lower(), "hay": hay.to_lower(), "adv": adv}

## Everything an option can be matched on. `keywords` arrives once the exporter ships it (older
## exports omit it — harmless, we just fall back to label/help/id/category).
func _opt_hay(opt: Dictionary) -> String:
	return " ".join([str(opt.get("label", "")), str(opt.get("id", "")), str(opt.get("category", "")),
		str(opt.get("keywords", "")), str(opt.get("help", ""))])

func _on_search(txt: String) -> void:
	_search = txt
	_apply_filter()

func _toggle_advanced() -> void:
	_show_advanced = not _show_advanced
	if _adv_btn != null:
		_adv_btn.text = _adv_label()
	_apply_filter()

func _adv_label() -> String:
	return ("[■]  " if _show_advanced else "[  ]  ") + "Advanced"

## Show/hide each row for the current query + Advanced state; collapse a category with no matches.
func _apply_filter() -> void:
	var q := _search.strip_edges().to_lower()
	for sec in _sections:
		var shown := 0
		for r in sec["rows"]:
			var vis: bool = (_show_advanced or not r["adv"]) and (q == "" or _match(q, r))
			r["node"].visible = vis
			if vis:
				shown += 1
		sec["header"].visible = shown > 0
		sec["spacer"].visible = shown > 0

func _match(q: String, r: Dictionary) -> bool:
	if String(r["hay"]).contains(q):
		return true
	return _subseq(q, String(r["label"]))

## True if q is a COMPACT subsequence of hay (chars appear in order, not scattered across the whole
## label) — the fuzzy part, e.g. "mvol"→"main volume". The span cap rejects loose hits like
## "volume" landing on "display verbose level up messages". Exact substrings are handled by the caller.
func _subseq(q: String, hay: String) -> bool:
	if q == "":
		return true
	if hay.length() < q.length():
		return false
	var i := 0
	var first := -1
	for ci in hay.length():
		if hay[ci] == q[i]:
			if first < 0:
				first = ci
			i += 1
			if i == q.length():
				return (ci - first + 1) <= q.length() * 3
	return false

func _build_footer() -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = "[center][color=#%s][lb]Esc[rb][/color][color=#%s] Back      [/color][color=#%s]↑↓[/color][color=#%s] navigate[/color][/center]" % [
		GOLD.to_html(false), DIM.to_html(false), GOLD.to_html(false), DIM.to_html(false)]
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.93
	l.anchor_bottom = 0.985
	_zero(l)
	add_child(l)
	# live write-back status (updated in _process)
	_status = _label("", DIM, "caption")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.anchor_left = 0.6
	_status.anchor_right = 0.98
	_status.anchor_top = 0.93
	_status.anchor_bottom = 0.985
	_zero(_status)
	add_child(_status)

# ── Raves settings (editable, persisted) ───────────────────────────────────────────

func _build_raves_setting(item: Dictionary) -> Control:
	match String(item.get("type", "")):
		"slider": return _raves_slider(item)
		"toggle": return _raves_toggle(item)
		"options": return _raves_options(item)
		"text": return _raves_text(item)
		_: return _label(str(item.get("label", "?")), LABEL, "body")

func _raves_slider(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = float(item["min"]); s.max_value = float(item["max"]); s.step = float(item["step"])
	s.value = float(Settings.get_value(item["key"], 1.0))
	s.custom_minimum_size = Vector2(420, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := _label("%.2f" % s.value, VALUE, "body")
	s.value_changed.connect(func(v):
		val.text = "%.2f" % v
		Settings.set_value(item["key"], v); Settings.save()
		if item["key"] == "font_scale": _retheme())
	h.add_child(s); h.add_child(val)
	row.add_child(h)
	return row

func _raves_toggle(item: Dictionary) -> Control:
	var b := _flat_button()
	var on := bool(Settings.get_value(item["key"], false))
	b.text = _check(on) + str(item["label"])
	b.pressed.connect(func():
		var now := not bool(Settings.get_value(item["key"], false))
		Settings.set_value(item["key"], now); Settings.save()
		b.text = _check(now) + str(item["label"]))
	return b

func _raves_options(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var opts: Array = item["options"]
	var cur := int(Settings.get_value(item["key"], 0))
	var btns: Array = []
	for i in range(opts.size()):
		var b := _flat_button()
		b.text = str(opts[i])
		b.add_theme_color_override("font_color", SEL if i == cur else DIM)
		var idx := i
		b.pressed.connect(func():
			Settings.set_value(item["key"], idx); Settings.save()
			for j in range(btns.size()):
				btns[j].add_theme_color_override("font_color", SEL if j == idx else DIM))
		btns.append(b); h.add_child(b)
	row.add_child(h)
	return row

func _raves_text(item: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.add_child(_label(str(item["label"]) + ":", LABEL, "body"))
	var e := LineEdit.new()
	var raw: Variant = Settings.get_value(item["key"], "")
	e.text = str(int(raw)) if item["key"] == "bridge_port" else str(raw)
	e.custom_minimum_size = Vector2(320, 0)
	e.add_theme_color_override("font_color", VALUE)
	var commit := func(_t = null):
		var v: Variant = e.text
		if item["key"] == "bridge_port": v = int(e.text)
		Settings.set_value(item["key"], v); Settings.save()
	e.text_submitted.connect(commit); e.focus_exited.connect(commit)
	h.add_child(e)
	return h

# ── Qud options (mirror / display) ──────────────────────────────────────────────────

func _build_qud_option(opt: Dictionary) -> Control:
	match str(opt.get("type", "")):
		"Slider": return _qud_slider(opt)
		"Checkbox": return _qud_checkbox(opt)
		"Combo", "BigCombo": return _qud_combo(opt)
		"Button": return _qud_button(opt)
		_: return _label("%s  %s" % [str(opt.get("label", "?")), str(opt.get("value", ""))], LABEL, "body")

func _qud_slider(opt: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(opt.get("label", "")), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var s := HSlider.new()
	s.min_value = float(opt.get("min", 0)); s.max_value = float(opt.get("max", 100))
	s.step = maxf(1.0, float(opt.get("increment", 1)))
	s.value = clampf(float(str(opt.get("value", "0")).to_float()), s.min_value, s.max_value)
	s.custom_minimum_size = Vector2(420, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var id := str(opt.get("id", ""))
	var val := _label(str(int(s.value)), VALUE, "body")
	s.value_changed.connect(func(v):
		var iv := int(round(v))
		val.text = str(iv)
		_set_qud_option(id, iv))
	h.add_child(s); h.add_child(val)
	row.add_child(h)
	return row

func _qud_checkbox(opt: Dictionary) -> Control:
	var id := str(opt.get("id", ""))
	var lbl := str(opt.get("label", ""))
	var state := {"on": str(opt.get("value", "No")).to_lower() == "yes"}
	var b := _flat_button()
	b.text = _check(state.on) + lbl
	b.pressed.connect(func():
		state.on = not state.on
		_set_qud_option(id, "Yes" if state.on else "No")
		b.text = _check(state.on) + lbl)
	return b

func _qud_combo(opt: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(opt.get("label", "")), LABEL, "body"))
	var vals: Array = opt.get("values", [])
	var id := str(opt.get("id", ""))
	if vals.is_empty():
		row.add_child(_label(str(opt.get("value", "")), VALUE, "body"))
		return row
	var cur := {"v": str(opt.get("value", ""))}
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 16)
	flow.add_theme_constant_override("v_separation", 4)
	var btns: Array = []
	for v in vals:
		var sv := str(v)
		var b := _flat_button()
		b.theme_type_variation = "Caption"
		b.text = sv
		b.add_theme_color_override("font_color", SEL if sv == cur.v else DIM)
		b.pressed.connect(func():
			cur.v = sv
			_set_qud_option(id, sv)
			for bb in btns: bb.add_theme_color_override("font_color", SEL if bb.text == sv else DIM))
		btns.append(b); flow.add_child(b)
	row.add_child(flow)
	return row

func _qud_button(opt: Dictionary) -> Control:
	var l := _label("› " + str(opt.get("label", "")), CYAN, "body")
	return l

# ── behaviour + helpers ────────────────────────────────────────────────────────────

func _jump_to(name: String) -> void:
	var head: Control = _anchors.get(name)
	if head != null and _scroll != null:
		_scroll.ensure_control_visible(head)

func _retheme() -> void:
	theme = UiFont.make_theme(get_viewport())
	var parent := get_parent()
	if parent is Control:
		(parent as Control).theme = UiFont.make_theme(get_viewport())

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		if _search != "":                      # first Esc clears the search, second closes
			_search = ""
			if _search_edit != null:
				_search_edit.text = ""
			_apply_filter()
		else:
			closed.emit()
		accept_event()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

func _check(on: bool) -> String:
	return "[■]  " if on else "[  ]  "

func _flat_button() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.add_theme_color_override("font_color", LABEL)
	b.add_theme_color_override("font_hover_color", SEL)
	return b

func _label(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	return l

func _spacer(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	return c

func _zero(c: Control) -> void:
	for k in ["left", "top", "right", "bottom"]:
		c.set("offset_" + k, 0.0)

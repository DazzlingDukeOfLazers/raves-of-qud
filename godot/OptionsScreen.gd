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
	{"key": "mode", "label": "Mode", "type": "choice",
		"options": ["User", "1:1"], "values": ["user", "1to1"]},   # 1:1 overrides camera + panels
	{"key": "font_scale", "label": "Font scale", "type": "slider", "min": 0.7, "max": 1.5, "step": 0.05},
	{"key": "fullscreen", "label": "Fullscreen", "type": "toggle"},
	{"key": "full_info", "label": "Show full info by default", "type": "toggle"},
	# 1:1 test — visual effects, minimal by default; turn on to build up toward Qud (apply on relaunch).
	{"key": "fx_scanlines", "label": "1:1 test · CRT scanlines", "type": "toggle"},
	{"key": "fx_vignette", "label": "1:1 test · CRT vignette", "type": "toggle"},
	{"key": "fx_particles", "label": "1:1 test · 3D particles", "type": "toggle"},
	{"key": "fx_lighting", "label": "1:1 test · 3D lighting", "type": "toggle"},
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
# Save/Load option presets — a whole options set (Raves settings + Qud option values) as one named
# file in <support>/option_presets/, so you can jump deterministically between configs. See presets.py.
var _preset_overlay: Control

func _ready() -> void:
	name = "OptionsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	_qud_cats = _load_qud_options()

	if Settings.one_to_one():
		_build_1to1()
	else:
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
		_build_preset_bar()
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
	var out := []
	if not Settings.one_to_one_only:
		out.append("Raves")   # hidden under --one-to-one: Qud's options has no such section
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
	var mag := Control.new()   # the magnifier glyph left of the field
	mag.position = Vector2(472, 80)
	mag.size = Vector2(20, 20)
	mag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mag.draw.connect(func():
		mag.draw_arc(Vector2(8, 8), 6.0, 0.0, TAU, 20, O_TEXT, 2.0)
		mag.draw_line(Vector2(12, 12), Vector2(18, 18), O_TEXT, 2.0))
	add_child(mag)

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

	# RAVES section — editable settings (searchable, never "advanced"). Hidden entirely
	# under --one-to-one: Qud's options has no such section, and hiding it is what locks
	# the mode (no toggle back to user; run without the flag for that).
	if not Settings.one_to_one_only:
		var rheader := _section_header_node("Raves")
		col.add_child(rheader)
		var rrows: Array = []
		for item in RAVES_ITEMS:
			var rrow := _build_raves_setting(item)
			# name for the feedback tool: the whole row IS this option (see FeedbackTool's
			# feedback_label walk) — without it a click names the row's value widget instead
			rrow.set_meta("feedback_label", "option · " + str(item.get("label", "")))
			rrow.set_meta("feedback_action", "set the RAVES option: " + str(item.get("label", "")))
			col.add_child(rrow)
			rrows.append(_row_meta(rrow, str(item.get("label", "")),
				str(item.get("label", "")) + " " + str(item.get("key", "")), false))
		var rsp := _spacer(12)
		col.add_child(rsp)
		_sections.append({"header": rheader, "spacer": rsp, "rows": rrows})

	# Qud's mirrored tree — every option is built once; the Advanced toggle + search decide what shows.
	var one := Settings.one_to_one()
	var first_cat := true
	for cat in _qud_cats:
		var header := _section_header_1to1(str(cat.get("name", "?")), first_cat) if one \
			else _section_header_node(str(cat.get("name", "?")))
		first_cat = false
		col.add_child(header)
		var rows: Array = []
		for opt in cat.get("options", []):
			var row := _qud_option_1to1(opt) if one else _build_qud_option(opt)
			row.set_meta("feedback_label", "option · " + str(opt.get("label", "")))
			row.set_meta("feedback_action", "set option: %s (%s category)" % [
				str(opt.get("label", "")), str(cat.get("name", ""))])
			col.add_child(row)
			rows.append(_row_meta(row, str(opt.get("label", "")), _opt_hay(opt),
				not bool(opt.get("visible", true))))
		var sp := _spacer(12)
		col.add_child(sp)
		_sections.append({"header": header, "spacer": sp, "rows": rows})

	_apply_filter()

func _section_header_node(name: String) -> Label:
	var h := _label("[-]  " + name.to_upper(), CYAN, "title")
	h.set_meta("feedback_label", "section · " + name)
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
		"choice": return _raves_choice(item)
		"text": return _raves_text(item)
		_: return _label(str(item.get("label", "?")), LABEL, "body")

## Like _raves_options, but the stored value is a STRING drawn from `values` (parallel to
## `options`, the display labels) — for settings whose key holds a string, e.g. mode "user"/"1to1".
## Persist-only: OptionsScreen is a MainMenu overlay (no live Holodeck), so the mode takes effect
## when you next enter the Holodeck; the Ctrl+M hotkey / highvisor button flip it live in-game.
func _raves_choice(item: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.add_child(_label(str(item["label"]), LABEL, "body"))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var opts: Array = item["options"]
	var vals: Array = item["values"]
	var cur := str(Settings.get_value(item["key"], vals[0]))
	var btns: Array = []
	for i in range(opts.size()):
		var b := _flat_button()
		b.text = str(opts[i])
		var sv := str(vals[i])
		b.add_theme_color_override("font_color", SEL if sv == cur else DIM)
		b.pressed.connect(func():
			Settings.set_value(item["key"], sv); Settings.save()
			for j in range(btns.size()):
				btns[j].add_theme_color_override("font_color", SEL if str(vals[j]) == sv else DIM))
		btns.append(b); h.add_child(b)
	row.add_child(h)
	return row

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
	# TYPING GUARD. Not "free" here -- see TypingGuard: a field consumes the keys it has a USE
	# for and lets the rest fall through, and the feedback form can be open over ANY screen.
	# Esc still passes: the form takes its own in _input before this runs.
	if TypingGuard.typing(get_viewport()) and not e.is_action_pressed("ui_cancel"):
		return
	if e.is_action_pressed("ui_cancel"):
		if _preset_overlay != null:            # a preset dialog is open — close it first
			_close_preset_overlay()
		elif _search != "":                    # then the search, second closes
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

# ── option presets (save/load a whole options set) ──────────────────────────────────

const RAVES_KEYS := ["font_scale", "fullscreen", "full_info", "fx_scanlines", "fx_vignette", "fx_particles", "fx_lighting", "camera", "mode", "bridge_host", "bridge_port"]

func _build_preset_bar() -> void:
	var save_b := _preset_bar_button("Save preset", 0.155, 0.285)
	save_b.pressed.connect(_open_save_overlay)
	add_child(save_b)
	var load_b := _preset_bar_button("Load preset", 0.295, 0.425)
	load_b.pressed.connect(_open_load_overlay)
	add_child(load_b)

func _preset_bar_button(txt: String, al: float, ar: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", SEL)
	b.anchor_left = al
	b.anchor_right = ar
	b.anchor_top = 0.93
	b.anchor_bottom = 0.985
	_zero(b)
	return b

func _presets_dir() -> String:
	var d := InputModel.support_dir().path_join("option_presets")
	DirAccess.make_dir_recursive_absolute(d)
	return d

## Read every preset file into [{name, description, raves, qud, path}], sorted by name.
func _list_presets() -> Array:
	var out: Array = []
	var dir := DirAccess.open(_presets_dir())
	if dir == null:
		return out
	for fn in dir.get_files():
		if not fn.ends_with(".json"):
			continue
		var f := FileAccess.open(_presets_dir().path_join(fn), FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			d["path"] = _presets_dir().path_join(fn)
			if not d.has("name"):
				d["name"] = fn.trim_suffix(".json")
			out.append(d)
	out.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	return out

func _current_raves_settings() -> Dictionary:
	var out := {}
	for k in RAVES_KEYS:
		out[k] = Settings.get_value(k, null)
	return out

func _current_qud_values() -> Dictionary:
	var out := {}
	for cat in _qud_cats:
		for opt in cat.get("options", []):
			var id := str(opt.get("id", ""))
			if id != "":
				out[id] = opt.get("value")
	return out

## Apply a preset live: Raves settings via Settings, Qud options over the bridge (one deferred batch
## + a single export), then reload so the screen reflects the new values.
func _apply_preset(preset: Dictionary) -> void:
	var raves: Dictionary = preset.get("raves", {})
	for k in raves:
		Settings.set_value(k, raves[k])
	if not raves.is_empty():
		Settings.save()      # persists + apply_global (font scale / fullscreen take effect live)
		_retheme()
	var qud: Dictionary = preset.get("qud", {})
	var applied_qud := false
	if not qud.is_empty() and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		for id in qud:
			var v = qud[id]
			_send_bridge({"type": "command", "name": "setoption", "id": str(id),
				"value": "" if v == null else str(v), "defer": "1"})
		_send_bridge({"type": "command", "name": "export"})
		_rearm_reload()      # _process reloads options.json once Qud rewrites it
		applied_qud = true
	_close_preset_overlay()
	if not applied_qud:
		_reload_options()    # still rebuild so the RAVES section shows the applied settings

## Re-arm the on-open reload watcher so a fresh export (after applying qud options) gets picked up.
func _rearm_reload() -> void:
	_options_mtime = _qud_json_mtime()
	_reload_deadline = Time.get_ticks_msec() + 1500

func _save_preset(name: String, desc: String) -> void:
	name = name.strip_edges()
	if name == "":
		return
	var safe := name.to_lower().replace(" ", "-").replace("/", "-")
	var preset := {
		"name": name,
		"description": desc.strip_edges(),
		"created": Time.get_datetime_string_from_system(),
		"raves": _current_raves_settings(),
		"qud": _current_qud_values(),
	}
	var f := FileAccess.open(_presets_dir().path_join(safe + ".json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(preset, "  "))
	_close_preset_overlay()

# ── preset overlays (modal, centered) ────────────────────────────────────────────────

func _close_preset_overlay() -> void:
	if _preset_overlay != null:
		_preset_overlay.queue_free()
		_preset_overlay = null

## A dim scrim + a centered gilded panel holding `body`; returns the panel's inner VBox to fill.
func _preset_modal(title: String) -> VBoxContainer:
	_close_preset_overlay()
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.6)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_close_preset_overlay())
	add_child(scrim)
	_preset_overlay = scrim
	# A fixed-anchored Panel (NOT PanelContainer) so the box keeps a bounded width and long
	# descriptions wrap inside it instead of stretching the panel across the screen.
	var panel := Panel.new()
	panel.anchor_left = 0.30
	panel.anchor_right = 0.70
	panel.anchor_top = 0.26
	panel.anchor_bottom = 0.74
	_zero(panel)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(func(_e): accept_event())   # clicks inside don't dismiss
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.055, 0.98)
	sb.set_border_width_all(1)
	sb.border_color = FRAME
	panel.add_theme_stylebox_override("panel", sb)
	scrim.add_child(panel)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_zero(margin)
	for k in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + k, 18)
	panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	margin.add_child(v)
	v.add_child(_label(title, GOLD, "title"))
	return v

func _open_load_overlay() -> void:
	var v := _preset_modal("Load preset")
	var presets := _list_presets()
	if presets.is_empty():
		v.add_child(_label("No presets yet. Save one here, or run  presets.py sync  to pull the committed fixtures.", DIM, "caption"))
	else:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 6)
		scroll.add_child(list)
		v.add_child(scroll)
		for p in presets:
			var b := _flat_button()
			b.text = "›  " + str(p.get("name", "?"))
			b.tooltip_text = str(p.get("description", ""))
			var desc := str(p.get("description", ""))
			var row := VBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_theme_constant_override("separation", 0)
			row.add_child(b)
			if desc != "":
				var dl := _label("      " + desc, DIM, "caption")
				dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				row.add_child(dl)
			var preset: Dictionary = p
			b.pressed.connect(func(): _apply_preset(preset))
			list.add_child(row)
	v.add_child(_preset_cancel_row())

func _open_save_overlay() -> void:
	var v := _preset_modal("Save preset")
	v.add_child(_label("Snapshot the current Raves settings + all Qud option values.", DIM, "caption"))
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "name (e.g. compass-fullinfo)"
	name_edit.add_theme_color_override("font_color", LABEL)
	v.add_child(name_edit)
	var desc_edit := LineEdit.new()
	desc_edit.placeholder_text = "description — why this preset exists"
	desc_edit.add_theme_color_override("font_color", LABEL)
	v.add_child(desc_edit)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	var save_b := _flat_button()
	save_b.text = "Save"
	save_b.add_theme_color_override("font_color", GOLD)
	save_b.pressed.connect(func(): _save_preset(name_edit.text, desc_edit.text))
	name_edit.text_submitted.connect(func(_t): _save_preset(name_edit.text, desc_edit.text))
	row.add_child(save_b)
	var cancel_b := _flat_button()
	cancel_b.text = "Cancel"
	cancel_b.pressed.connect(_close_preset_overlay)
	row.add_child(cancel_b)
	v.add_child(row)

func _preset_cancel_row() -> Control:
	var b := _flat_button()
	b.text = "Cancel"
	b.add_theme_color_override("font_color", DIM)
	b.pressed.connect(_close_preset_overlay)
	return b

# ── 1:1 build — Qud's OPTIONS console screen (same framework as Records) ─────────
# Interlaced bg, dotted rail divider, right-aligned category rail, OPTIONS header
# with search field + advanced toggle, full-width option rows (sliders with dotted
# tracks, [■] checkboxes, value lists), scroll track, [Esc] Back chevron, hint bar.
# Rows are VISUAL parity first; write-back interactions stay in user mode for now.

## Same 2D-canvas gamma pre-compensation as RecordsScreen._q (see there).
static func _q(r8: int, g8: int, b8: int) -> Color:
	var f := func(v: int) -> int: return v if v <= 20 else mini(255, int(round(v * 1.13)))
	return Color8(f.call(r8), f.call(g8), f.call(b8))

var O_BG := _q(6, 44, 42)
var O_LINE := _q(58, 89, 101)
var O_GOLD := _q(200, 184, 57)
var O_CYAN_SEL := _q(108, 183, 200)
var O_CYAN := _q(56, 154, 176)
var O_TEXT := _q(167, 192, 186)
var O_DIM := _q(21, 73, 72)

func _build_1to1() -> void:
	var bg := ColorRect.new()
	bg.color = O_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# dotted rail divider + end caps (x325, like Records at 331)
	var div := Control.new()
	div.set_anchors_preset(Control.PRESET_FULL_RECT)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	div.draw.connect(func():
		var y := 25.0
		while y < 1040.0:
			div.draw_rect(Rect2(325, y, 1, minf(5, 1040 - y)), O_LINE)
			y += 6.0
		for cy in [25.0, 1035.0]:
			div.draw_rect(Rect2(322, cy, 7, 6), _q(53, 90, 98)))
	add_child(div)

	# header: OPTIONS + search field + advanced toggle
	var title := Label.new()
	title.text = "OPTIONS"
	title.add_theme_color_override("font_color", O_GOLD)
	var fv := FontVariation.new()
	fv.base_font = get_theme_font("font", "Label")
	fv.spacing_glyph = 3
	title.add_theme_font_override("font", fv)
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(339, 72)
	add_child(title)
	# search field (functional: filters rows via the existing _on_search)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "<search>"
	_search_edit.position = Vector2(498, 75)
	_search_edit.size = Vector2(162, 30)
	_search_edit.add_theme_font_size_override("font_size", 16)
	_search_edit.add_theme_color_override("font_color", O_TEXT)
	_search_edit.add_theme_color_override("font_placeholder_color", O_DIM)
	var sb := StyleBoxFlat.new()
	sb.bg_color = O_BG
	sb.set_border_width_all(1)
	sb.border_color = O_LINE
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	for st in ["normal", "focus"]:
		_search_edit.add_theme_stylebox_override(st, sb)
	_search_edit.text_changed.connect(_on_search)
	add_child(_search_edit)
	var mag := Control.new()   # the magnifier glyph left of the field
	mag.position = Vector2(472, 80)
	mag.size = Vector2(20, 20)
	mag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mag.draw.connect(func():
		mag.draw_arc(Vector2(8, 8), 6.0, 0.0, TAU, 20, O_TEXT, 2.0)
		mag.draw_line(Vector2(12, 12), Vector2(18, 18), O_TEXT, 2.0))
	add_child(mag)
	var adv := RichTextLabel.new()
	adv.bbcode_enabled = true
	adv.fit_content = true
	adv.scroll_active = false
	adv.autowrap_mode = TextServer.AUTOWRAP_OFF
	adv.add_theme_font_size_override("normal_font_size", 16)
	adv.text = "[color=#%s][lb]■[rb][/color][color=#%s] Show advanced options[/color]" % [
		O_TEXT.to_html(false), O_TEXT.to_html(false)]
	adv.position = Vector2(656, 82)
	adv.mouse_filter = Control.MOUSE_FILTER_STOP
	adv.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _toggle_advanced())
	add_child(adv)

	# right-aligned category rail with markers
	var names := _cat_names()
	for i in range(names.size()):
		var l := Label.new()
		l.text = str(names[i])
		l.add_theme_color_override("font_color", O_CYAN_SEL)
		l.add_theme_font_size_override("font_size", 16)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.position = Vector2(54, 166 + i * 30)
		l.size = Vector2(234, 22)
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		var nm := str(names[i])
		l.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.pressed and _anchors.has(nm):
				_scroll.ensure_control_visible(_anchors[nm]))
		add_child(l)
		var dot := ColorRect.new()
		dot.color = O_LINE
		dot.position = Vector2(296, 173 + i * 30)
		dot.size = Vector2(5, 5)
		add_child(dot)

	# content scroller
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.position = Vector2(332, 115)
	_scroll.size = Vector2(1420, 880)
	add_child(_scroll)
	_body_col = VBoxContainer.new()
	_body_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_col.add_theme_constant_override("separation", 5)
	_scroll.add_child(_body_col)
	_populate_body()

	# scroll track (x1764, 10px)
	var track := Control.new()
	track.position = Vector2(1760, 110)
	track.size = Vector2(10, 865)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.draw.connect(func():
		track.draw_rect(Rect2(0, 0, 10, track.size.y), _q(29, 41, 46))
		var vsb := _scroll.get_v_scroll_bar()
		var content := maxf(1.0, float(vsb.max_value))
		var vis := float(vsb.page) if vsb.page > 0 else _scroll.size.y
		var frac := clampf(vis / content, 0.05, 1.0)
		var pos := 0.0
		if content > vis:
			pos = float(vsb.value) / (content - vis)
		var th := track.size.y * frac
		track.draw_rect(Rect2(0, (track.size.y - th) * pos, 10, th), O_LINE))
	add_child(track)
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v): track.queue_redraw())

	# [Esc] Back chevron
	var back := Control.new()
	back.position = Vector2(30, 520)
	back.size = Vector2(110, 75)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	back.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: closed.emit())
	back.draw.connect(func():
		back.draw_line(Vector2(48, 12), Vector2(36, 24), _q(120, 140, 138), 3.0)
		back.draw_line(Vector2(36, 24), Vector2(48, 36), _q(120, 140, 138), 3.0))
	add_child(back)
	var bl := RichTextLabel.new()
	bl.bbcode_enabled = true
	bl.fit_content = true
	bl.scroll_active = false
	bl.autowrap_mode = TextServer.AUTOWRAP_OFF
	bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl.add_theme_font_size_override("normal_font_size", 16)
	bl.text = "[color=#%s][lb]Esc[rb][/color][color=#%s] Back[/color]" % [
		O_GOLD.to_html(false), O_TEXT.to_html(false)]
	bl.position = Vector2(4, 48)
	back.add_child(bl)

	# bottom hint
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.scroll_active = false
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override("normal_font_size", 16)
	var wht := "#FFFFFF"
	var dimc := "#%s" % O_TEXT.to_html(false)
	var goldc := "#%s" % O_GOLD.to_html(false)
	hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	hint.append_text("[color=%s][lb][/color]" % wht)
	hint.add_image(QudChrome.nav_icon(15), 22, 15)
	hint.append_text("[color=%s][rb][/color]" % wht)
	hint.append_text("[color=%s] navigate  [/color]" % dimc)
	hint.append_text("[color=%s][lb]-[rb][/color][color=%s] Collapse All  [/color]" % [goldc, dimc])
	hint.append_text("[color=%s][lb]+[rb][/color][color=%s] Expand All  [/color]" % [goldc, dimc])
	hint.append_text("[color=%s][lb]Space[rb][/color][color=%s] Toggle Visibilty[/color]" % [goldc, dimc])
	hint.pop()
	hint.position = Vector2(365, 1005)
	add_child(hint)

	# interlace LAST, over everything (Qud console-screen scanlines)
	var scan := ColorRect.new()
	# transparent to the feedback hit test — a full-rect drawn last otherwise shadows
	# every element on the screen (same treatment as MainFrame's CRT rect)
	scan.set_meta("feedback_pass", true)
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture;
void fragment() {
	vec4 c = texture(screen_tex, SCREEN_UV);
	float row = floor(FRAGCOORD.y);
	if (mod(row, 2.0) >= 1.0) {
		// Qud's scanline is LUMINANCE-WEIGHTED: dark bg halves, bright text is
		// barely touched (measured: bg x0.50, text x0.92-0.99). A flat 50% cut
		// shreds glyphs into stripes.
		float lum = max(c.r, max(c.g, c.b)) * 255.0;
		float f = mix(0.5, 1.0, smoothstep(30.0, 180.0, lum));
		COLOR = vec4(c.rgb * f, 1.0);
	} else {
		COLOR = vec4(c.rgb, 1.0);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	scan.material = mat
	add_child(scan)

## The 7x7 border weave recoloured to the console slider palette (bright
## (58,89,101) / dark (29,41,46), gamma-compensated) — Qud uses it for both the
## slider ribbon and the thumb block. Derived from the extracted band tile;
## generated fallback keeps the pattern family.
var _slider_tile_cache: ImageTexture
func _slider_weave_tile() -> ImageTexture:
	if _slider_tile_cache != null:
		return _slider_tile_cache
	var bright := _q(58, 89, 101)
	var dark := _q(29, 41, 46)
	var img: Image
	var bandtex: Texture2D = _chrome_opt("modsBandTop.png")
	if bandtex != null:
		img = bandtex.get_image()
		img.convert(Image.FORMAT_RGB8)
		var base := Color8(0x35, 0x55, 0x5C)
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				var near := absf(c.r - base.r) + absf(c.g - base.g) + absf(c.b - base.b) < 0.15
				img.set_pixel(x, y, bright if near else dark)
	else:
		img = Image.create(7, 7, false, Image.FORMAT_RGB8)
		img.fill(bright)
		for i in range(7):
			img.set_pixel(i, (i * 3) % 7, dark)
	_slider_tile_cache = ImageTexture.create_from_image(img)
	return _slider_tile_cache
## Section header: "[-] SOUND" — big cyan caps; the FIRST section carries Qud's
## fresh-open selection dither bar across the content width.
func _section_header_1to1(name: String, selected: bool) -> Control:
	var wrap := Control.new()
	wrap.set_meta("feedback_label", "section · " + name)
	wrap.custom_minimum_size = Vector2(0, 24)
	if selected:
		var hl := TextureRect.new()
		var htex: Texture2D = null
		var hpath := InputModel.support_dir().path_join("title").path_join("chrome").path_join("modsHoverTile.png")
		if FileAccess.file_exists(hpath):
			var himg := Image.new()
			if himg.load(hpath) == 0:
				htex = ImageTexture.create_from_image(QudChrome.brighten(himg))
		if htex != null:
			hl.texture = htex
			hl.stretch_mode = TextureRect.STRETCH_TILE
		hl.position = Vector2(0, 0)
		hl.size = Vector2(772, 26)
		hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.add_child(hl)
	var pre := Label.new()
	pre.text = "[-]"
	pre.add_theme_color_override("font_color", O_CYAN)
	pre.add_theme_font_size_override("font_size", 16)
	pre.position = Vector2(8, 5)
	wrap.add_child(pre)
	var l := Label.new()
	l.text = name.to_upper()
	l.add_theme_color_override("font_color", O_CYAN_SEL)
	l.add_theme_font_size_override("font_size", 24)
	l.position = Vector2(48, 0)
	wrap.add_child(l)
	_anchors[name] = wrap
	return wrap

func _chrome_opt(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

## One option row, Qud console style. Sliders: label line + dotted track with a
## square thumb and the value at the right. Checkboxes: "[■]/[ ]" + label.
## Combos: label + value list with the current one highlighted.
func _qud_option_1to1(opt: Dictionary) -> Control:
	var t := str(opt.get("type", ""))
	var wrap := Control.new()
	var label := str(opt.get("label", ""))
	match t:
		"Slider":
			wrap.custom_minimum_size = Vector2(0, 46)
			var l := Label.new()
			l.text = label
			l.add_theme_color_override("font_color", O_TEXT)
			l.add_theme_font_size_override("font_size", 16)
			l.position = Vector2(53, 0)
			wrap.add_child(l)
			var vmin := float(opt.get("min", 0))
			var vmax := maxf(1.0, float(opt.get("max", 100)))
			var inc := maxf(1.0, float(opt.get("increment", 0)))
			var oid := str(opt.get("id", ""))
			# FUNCTIONAL: click/drag sets the value and writes back to Qud over the
			# bridge (setoption; defer=1 during the drag, a final full apply+re-export
			# on release). st is a Dictionary so the lambdas share mutable state.
			var st := {"val": float(str(opt.get("value", "0")).to_float()), "drag": false, "sent": ""}
			var tr := Control.new()
			tr.position = Vector2(53, 26)
			tr.size = Vector2(671, 22)
			tr.mouse_filter = Control.MOUSE_FILTER_STOP
			var v := Label.new()
			v.text = str(int(st.val))
			v.add_theme_color_override("font_color", O_GOLD)   # Qud renders slider values gold
			v.add_theme_font_size_override("font_size", 16)
			v.position = Vector2(716, 16)
			tr.draw.connect(func():
				# Qud's track AND thumb are the 7x7 border WEAVE in the console
				# palette — a 4px weave ribbon with a 20x20 weave block thumb;
				# endcaps are 4px-wide columns at the thumb's height
				var wt := _slider_weave_tile()
				var fracv := clampf((float(st.val) - vmin) / (vmax - vmin), 0.0, 1.0)
				if wt != null:
					tr.draw_texture_rect(wt, Rect2(0, 7, 4, 20), true)
					tr.draw_texture_rect(wt, Rect2(2, 15, 653, 4), true)
					tr.draw_texture_rect(wt, Rect2(653, 7, 4, 20), true)
				else:
					tr.draw_rect(Rect2(0, 7, 4, 20), O_LINE)
					tr.draw_rect(Rect2(2, 16, 653, 2), O_LINE)
					tr.draw_rect(Rect2(653, 7, 4, 20), O_LINE)
				var tx := 2.0 + (653.0 - 20.0) * fracv
				if wt != null:
					tr.draw_texture_rect(wt, Rect2(tx, 7, 20, 20), true)
				else:
					tr.draw_rect(Rect2(tx, 7, 20, 20), O_CYAN))
			var apply := func(mx: float, final: bool):
				var fr := clampf((mx - 2.0) / 651.0, 0.0, 1.0)
				var nv := clampf(roundf((vmin + fr * (vmax - vmin)) / inc) * inc, vmin, vmax)
				if nv != float(st.val) or final:
					st.val = nv
					v.text = str(int(nv))
					tr.queue_redraw()
					var sval := str(int(nv))
					if oid != "" and (final or sval != str(st.sent)):
						st.sent = sval
						_send_bridge({"type": "command", "name": "setoption",
							"id": oid, "value": sval, "defer": "0" if final else "1"})
			tr.gui_input.connect(func(e):
				if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
					st.drag = e.pressed
					apply.call(e.position.x, not e.pressed)
				elif e is InputEventMouseMotion and st.drag:
					apply.call(e.position.x, false))
			wrap.add_child(tr)
			wrap.add_child(v)
		"Checkbox":
			wrap.custom_minimum_size = Vector2(0, 20)
			# FUNCTIONAL: click toggles Yes/No and writes back over the bridge.
			var cst := {"on": str(opt.get("value", "")) == "Yes"}
			var coid := str(opt.get("id", ""))
			var rl := RichTextLabel.new()
			rl.bbcode_enabled = true
			rl.fit_content = true
			rl.scroll_active = false
			rl.autowrap_mode = TextServer.AUTOWRAP_OFF
			rl.mouse_filter = Control.MOUSE_FILTER_STOP
			rl.add_theme_font_size_override("normal_font_size", 16)
			var paint := func():
				var box := "[lb]■[rb]" if cst.on else "[lb] [rb]"
				rl.text = "[color=#%s]%s[/color][color=#%s] %s[/color]" % [
					O_TEXT.to_html(false), box, O_TEXT.to_html(false), label]
			paint.call()
			rl.gui_input.connect(func(e):
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					cst.on = not cst.on
					paint.call()
					if coid != "":
						_send_bridge({"type": "command", "name": "setoption",
							"id": coid, "value": "Yes" if cst.on else "No"}))
			rl.position = Vector2(53, 0)
			wrap.add_child(rl)
		"Combo", "BigCombo":
			var vals: Array = opt.get("values", [])
			var shown: Array = opt.get("displayValues", [])
			if shown.is_empty():
				shown = vals
			var l2 := Label.new()
			l2.text = label
			l2.add_theme_color_override("font_color", O_TEXT)
			l2.add_theme_font_size_override("font_size", 16)
			l2.position = Vector2(53, 0)
			wrap.add_child(l2)
			# FUNCTIONAL: each value is its own clickable Label in a flow container —
			# clicking selects it (gold) and writes back over the bridge.
			var xst := {"cur": str(opt.get("value", ""))}
			var xoid := str(opt.get("id", ""))
			var flow := HFlowContainer.new()
			flow.position = Vector2(61, 24)
			flow.size = Vector2(690, 0)
			flow.add_theme_constant_override("h_separation", 19)
			flow.add_theme_constant_override("v_separation", 6)
			var vlabels: Array = []
			for i2 in range(shown.size()):
				var raw := str(vals[i2]) if i2 < vals.size() else str(shown[i2])
				var vl := Label.new()
				vl.text = str(shown[i2])
				vl.add_theme_font_size_override("font_size", 16)
				vl.add_theme_color_override("font_color", O_GOLD if raw == str(xst.cur) else O_CYAN)
				vl.mouse_filter = Control.MOUSE_FILTER_STOP
				vlabels.append(vl)
				var rawc := raw
				vl.gui_input.connect(func(e):
					if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
						xst.cur = rawc
						for j2 in range(vlabels.size()):
							var rj := str(vals[j2]) if j2 < vals.size() else str(shown[j2])
							vlabels[j2].add_theme_color_override("font_color",
								O_GOLD if rj == rawc else O_CYAN)
						if xoid != "":
							_send_bridge({"type": "command", "name": "setoption",
								"id": xoid, "value": rawc}))
				flow.add_child(vl)
			wrap.add_child(flow)
			var rl2 := flow   # the sizing hook below reads rl2.size
			wrap.custom_minimum_size = Vector2(0, 30)
			wrap.ready.connect(func():
				await get_tree().process_frame
				wrap.custom_minimum_size = Vector2(0, 24 + rl2.size.y))
		_:
			wrap.custom_minimum_size = Vector2(0, 26)
			var l3 := Label.new()
			l3.text = label
			l3.add_theme_color_override("font_color", O_TEXT)
			l3.add_theme_font_size_override("font_size", 16)
			l3.position = Vector2(53, 2)
			wrap.add_child(l3)
	return wrap

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

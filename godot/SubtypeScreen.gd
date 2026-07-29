extends Control

## CHARACTER CREATION — stage 2: SUBTYPE (Caste for True Kin / Calling for Mutated Human).
##
## Second vertical slice. The subtype family is chosen by the genotype: set `subtype_class` to the
## genotype's `subtypes` field ("Castes"/"Callings") before adding this screen. Reads the subtype
## tree the mod slurps to chargen.json — class → category (arcology/region) → subtype — and shows,
## Qud-style: a LEFT list grouped by category (icon + name) and a RIGHT detail panel with the
## subtype's stat bonuses + Qud's own chargen bullets (from GetChargenInfo). The pick is captured
## into `selected` and emitted via `chose` for the next stage.
##
## Same chrome + auto-refresh pattern as the other chargen/menu screens.

signal closed
signal chose(subtype: String)

## Set by the flow before _ready: which class to show ("Castes" / "Callings"), + the genotype name
## for the header. Defaults to the first class if unset.
var subtype_class := ""
var genotype_name := ""

const FRAME := Color8(0xB6, 0xA1, 0x63)
const PANEL := Color(0.055, 0.078, 0.078, 0.96)
const SCRIM := Color(0.02, 0.03, 0.03, 0.55)
const TITLE := Color8(0xF0, 0xEA, 0xD8)
const LABEL := Color8(0x6E, 0xB5, 0xC9)
const VALUE := Color8(0xC9, 0xC2, 0xA8)
const GOLD := Color8(0xC8, 0xA9, 0x4E)
const CATEGORY := Color8(0x9C, 0xC7, 0x7A)
const DIM := Color(0.89, 0.85, 0.72, 0.5)

const QUD_COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),
}

const SIDE_W_FRAC := 0.016
const BAR_H_FRAC := 0.022

var selected := ""

var _class := {}               # the chosen subtypeClass dict {id, chargenTitle, categories:[...]}
var _flat: Array = []          # flat list of subtypes in display order (for selection/nav)
var _sel := 0
var _rows: Array = []          # [{panel, subtype}] parallel to _flat
var _list: VBoxContainer
var _detail: VBoxContainer
var _palette := {}
var _peer := StreamPeerTCP.new()
var _refreshed := false
var _mtime := 0
var _reload_deadline := 0

func _ready() -> void:
	name = "SubtypeScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_class = _load_class()

	var scrim := ColorRect.new()
	scrim.color = SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var frame := Control.new()
	frame.anchor_left = 0.035
	frame.anchor_right = 0.965
	frame.anchor_top = 0.05
	frame.anchor_bottom = 0.95
	for k in ["left", "top", "right", "bottom"]:
		frame.set("offset_" + k, 0.0)
	add_child(frame)
	_build_frame(frame)
	_build_header(frame)
	_build_body(frame)
	_build_footer(frame)
	_apply_selection()
	_add_back()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())

func _process(_dt: float) -> void:
	_peer.poll()
	var connected := _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if connected and not _refreshed:
		_refreshed = true
		_mtime = _json_mtime()
		_send_bridge({"type": "command", "name": "export"})
		_reload_deadline = Time.get_ticks_msec() + 1200
	elif _refreshed and _reload_deadline > 0:
		if _json_mtime() > _mtime or Time.get_ticks_msec() >= _reload_deadline:
			_reload_deadline = 0
			_class = _load_class()
			_populate()
			_sel = clampi(_sel, 0, maxi(0, _flat.size() - 1))
			_apply_selection()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

func _json_mtime() -> int:
	var path := InputModel.support_dir().path_join("chargen.json")
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0

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

func _add_back() -> void:
	var b := Button.new()
	b.text = "‹ Back"
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", TITLE)
	b.anchor_left = 0.02
	b.anchor_right = 0.14
	b.anchor_top = 0.93
	b.anchor_bottom = 0.985
	for k in ["left", "top", "right", "bottom"]:
		b.set("offset_" + k, 0.0)
	b.pressed.connect(func(): closed.emit())
	add_child(b)

func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── data ───────────────────────────────────────────────────────────────────────

## Load the subtypeClass matching `subtype_class` (or the first one), from chargen.json.
func _load_class() -> Dictionary:
	var path := InputModel.support_dir().path_join("chargen.json")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary and data.has("subtypeClasses") and data["subtypeClasses"] is Array):
		return {}
	var classes: Array = data["subtypeClasses"]
	for c in classes:
		if c is Dictionary and str(c.get("id", "")) == subtype_class:
			return c
	return classes[0] if not classes.is_empty() else {}

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _tile(tile: String) -> Texture2D:
	if tile == "":
		return null
	var fname := tile.replace("/", "_").replace("\\", "_")
	var path := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	# TileExporter always writes PNG data even into a ".bmp"-named file; decode from the buffer as PNG
	# (Image.load picks its decoder by extension, so a .bmp-named PNG would fail).
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		if img.load(path) != OK:
			return null
	return ImageTexture.create_from_image(img)

# ── frame / header / body / footer ───────────────────────────────────────────────

func _build_frame(frame: Control) -> void:
	var bg_tex := _chrome("panelBgTile.png")
	if bg_tex != null:
		var bg := _edge(bg_tex, TextureRect.STRETCH_TILE, 0.0, 0.0, 1.0, 1.0)
		bg.modulate = Color(1, 1, 1, 0.98)
		frame.add_child(bg)
	else:
		var flat := ColorRect.new()
		flat.color = PANEL
		flat.set_anchors_preset(Control.PRESET_FULL_RECT)
		flat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(flat)
	var side := _chrome("borderSide.png")
	var bar := _chrome("borderBot.png")
	if side != null:
		frame.add_child(_edge(side, TextureRect.STRETCH_SCALE, 0.0, 0.0, SIDE_W_FRAC, 1.0))
		var r := _edge(side, TextureRect.STRETCH_SCALE, 1.0 - SIDE_W_FRAC, 0.0, 1.0, 1.0)
		r.flip_h = true
		frame.add_child(r)
	if bar != null:
		var top := _edge(bar, TextureRect.STRETCH_SCALE, 0.0, 0.0, 1.0, BAR_H_FRAC)
		top.flip_v = true
		frame.add_child(top)
		frame.add_child(_edge(bar, TextureRect.STRETCH_SCALE, 0.0, 1.0 - BAR_H_FRAC, 1.0, 1.0))
	if side == null and bar == null:
		var ol := Panel.new()
		ol.set_anchors_preset(Control.PRESET_FULL_RECT)
		ol.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.set_border_width_all(2)
		sb.border_color = FRAME
		ol.add_theme_stylebox_override("panel", sb)
		frame.add_child(ol)

func _edge(tex: Texture2D, mode: int, al: float, at: float, ar: float, ab: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = mode
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.anchor_left = al
	r.anchor_top = at
	r.anchor_right = ar
	r.anchor_bottom = ab
	for k in ["left", "top", "right", "bottom"]:
		r.set("offset_" + k, 0.0)
	return r

func _build_header(frame: Control) -> void:
	var title := str(_class.get("chargenTitle", "choose subtype")).capitalize()
	var l := Label.new()
	l.text = "◈  %s  ◈" % title
	l.theme_type_variation = "Title"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", GOLD)
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.02
	l.anchor_bottom = 0.09
	for k in ["left", "top", "right", "bottom"]:
		l.set("offset_" + k, 0.0)
	frame.add_child(l)

func _build_body(frame: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0.03
	scroll.anchor_right = 0.46
	scroll.anchor_top = 0.11
	scroll.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		scroll.set("offset_" + k, 0.0)
	frame.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)
	_populate()

	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.anchor_left = 0.49
	sc.anchor_right = 0.97
	sc.anchor_top = 0.11
	sc.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		sc.set("offset_" + k, 0.0)
	frame.add_child(sc)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 8)
	sc.add_child(_detail)

## LEFT list: category header, then a row per subtype under it. _flat/_rows stay index-parallel.
func _populate() -> void:
	_rows.clear()
	_flat.clear()
	for c in _list.get_children():
		c.queue_free()
	var cats: Array = _class.get("categories", [])
	if cats.is_empty():
		var empty := _text("No chargen data yet. Run Caves of Qud once with Raves connected to populate it.", VALUE, "body")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
		return
	var show_cat_headers := cats.size() > 1   # a single category (Callings) needs no header
	for cat in cats:
		if show_cat_headers:
			var h := _rich("[color=#%s]%s[/color]" % [CATEGORY.to_html(false), QudText.to_bbcode(str(cat.get("display", cat.get("name", ""))), _palette)], "caption")
			h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			var pad := MarginContainer.new()
			pad.add_theme_constant_override("margin_top", 6)
			pad.add_theme_constant_override("margin_left", 2)
			pad.add_child(h)
			_list.add_child(pad)
		for st in cat.get("subtypes", []):
			var idx := _flat.size()
			var row := _subtype_row(st, idx)
			_list.add_child(row)
			_flat.append(st)
			_rows.append({"panel": row, "subtype": st})

func _subtype_row(st: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 6)
	panel.add_child(pad)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	pad.add_child(hb)
	var itex := _tile(str(st.get("tile", "")))
	if itex != null:
		var icon := TextureRect.new()
		icon.texture = itex
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel art
		icon.custom_minimum_size = Vector2(40, 40)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(icon)
	hb.add_child(_rich("[color=#%s]%s[/color]" % [TITLE.to_html(false), _esc(str(st.get("display", st.get("name", "?"))))], "body"))
	_style_row(panel, false)
	return panel

func _build_footer(frame: Control) -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = "[center][color=#%s][lb]Esc[rb][/color][color=#%s] Back      [/color][color=#%s]↑↓[/color][color=#%s] choose      [/color][color=#%s][lb]Enter[rb][/color][color=#%s] confirm[/color][/center]" % [
		GOLD.to_html(false), DIM.to_html(false), GOLD.to_html(false), DIM.to_html(false), GOLD.to_html(false), DIM.to_html(false)]
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.92
	l.anchor_bottom = 0.98
	for k in ["left", "top", "right", "bottom"]:
		l.set("offset_" + k, 0.0)
	frame.add_child(l)

# ── selection + details ────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	for i in range(_rows.size()):
		_style_row(_rows[i]["panel"], i == _sel)
	_build_detail()

func _build_detail() -> void:
	if _detail == null:
		return
	for c in _detail.get_children():
		c.queue_free()
	if _sel < 0 or _sel >= _flat.size():
		return
	var st: Dictionary = _flat[_sel]
	_detail.add_child(_rich("[color=#%s]%s[/color]" % [GOLD.to_html(false), _esc(str(st.get("display", st.get("name", "?"))))], "big"))

	# Qud's own ready-made chargen bullets (formatted stat/save/skill lines, with markup)
	var info: Array = st.get("info", [])
	if info is Array and not info.is_empty():
		_detail.add_child(_gap(4))
		for line in info:
			var r := _rich(QudText.to_bbcode(str(line), _palette), "body")
			r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_detail.add_child(r)
	else:
		# fallback if GetChargenInfo was unavailable: show raw stat bonuses
		var bonuses: Array = st.get("statBonuses", [])
		for b in bonuses:
			_detail.add_child(_rich("[color=#%s]+%d %s[/color]" % [GOLD.to_html(false), int(b.get("bonus", 0)), str(b.get("name", ""))], "body"))

func _style_row(panel: PanelContainer, on: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.90, 0.86, 0.72, 0.10) if on else Color(1, 1, 1, 0.02)
	sb.set_corner_radius_all(2)
	sb.border_width_left = 3 if on else 0
	sb.border_color = GOLD
	panel.add_theme_stylebox_override("panel", sb)

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()
	elif e.is_action_pressed("ui_down"):
		_select(mini(_sel + 1, _rows.size() - 1)); accept_event()
	elif e.is_action_pressed("ui_up"):
		_select(maxi(_sel - 1, 0)); accept_event()
	elif e.is_action_pressed("ui_accept"):
		if _sel >= 0 and _sel < _flat.size():
			selected = str(_flat[_sel].get("name", ""))
			chose.emit(selected)
		accept_event()

# ── helpers ──────────────────────────────────────────────────────────────────

func _text(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	return l

func _rich(bb: String, role := "body") -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = bb
	return l

func _gap(px: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	return c

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")

extends Control

## CHARACTER CREATION — stage 1: GENOTYPE (Mutated Human / True Kin).
##
## First vertical slice of the interactive chargen mock (see the raves-chargen plan). Reads the
## genotype data the mod slurps from Qud's own GenotypeFactory to chargen.json (name, tile, stat/
## mutation/cybernetics point budgets, the 6 attribute ranges, and the perk bullets Qud shows), and
## presents Qud's genotype choice: a LEFT list of genotypes (icon + name) and a RIGHT detail panel
## (perks + point budgets + attribute ranges). The pick is captured into `selected` for the next
## stage / the eventual Embark that drives Qud's builder.
##
## Same chrome + auto-refresh-on-open pattern as the Records/Mods/Options screens.

signal closed
signal chose(genotype: String)   # emitted when the player confirms a genotype (Enter) — for the flow

# palette — shared with the other menu screens
const FRAME := Color8(0xB6, 0xA1, 0x63)
const PANEL := Color(0.055, 0.078, 0.078, 0.96)
const SCRIM := Color(0.02, 0.03, 0.03, 0.55)
const TITLE := Color8(0xF0, 0xEA, 0xD8)
const LABEL := Color8(0x6E, 0xB5, 0xC9)
const VALUE := Color8(0xC9, 0xC2, 0xA8)
const GOLD := Color8(0xC8, 0xA9, 0x4E)
const GREEN := Color8(0x5F, 0xC8, 0x5A)
const DIM := Color(0.89, 0.85, 0.72, 0.5)

# Qud's 16-colour palette for rendering {{code|text}} markup in the perk bullets (baked; no live
# snapshot at the menu). Same values as ZoneRenderer.COLORS.
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
const ATTR_ORDER := ["Strength", "Agility", "Toughness", "Intelligence", "Willpower", "Ego"]

## The confirmed genotype name (or "" until confirmed), read by the chargen flow.
var selected := ""

var _genotypes: Array = []
var _sel := 0
var _rows: Array = []          # [{panel, geno}]
var _list: VBoxContainer
var _detail: VBoxContainer
var _palette := {}
var _peer := StreamPeerTCP.new()
var _refreshed := false
var _mtime := 0
var _reload_deadline := 0

func _ready() -> void:
	name = "GenotypeScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_genotypes = _load()

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

## Auto-refresh on open: ask the mod to re-export, reload chargen.json when it's rewritten. No-op if
## the bridge is down (pre-game) — the screen still shows the cached export.
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
			_reload()

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

func _reload() -> void:
	_genotypes = _load()
	if _list == null:
		return
	_populate()
	_sel = clampi(_sel, 0, maxi(0, _genotypes.size() - 1))
	_apply_selection()

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

func _load() -> Array:
	var path := InputModel.support_dir().path_join("chargen.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.has("genotypes") and data["genotypes"] is Array:
		return data["genotypes"]
	return []

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

## The genotype's icon PNG, exported by the mod into tilesDir (slashes→underscores). Null if not
## yet exported (falls back to no icon), like the Mods screen's preview.
func _tile(tile: String) -> Texture2D:
	if tile == "":
		return null
	var fname := tile.replace("/", "_").replace("\\", "_")
	var path := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	var tex := ImageTexture.create_from_image(img)
	return tex

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
	var l := Label.new()
	l.text = "◈  Genotype  ◈"
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
	# LEFT: the genotype choices
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0.03
	scroll.anchor_right = 0.40
	scroll.anchor_top = 0.11
	scroll.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		scroll.set("offset_" + k, 0.0)
	frame.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)
	_populate()

	# RIGHT: details of the selected genotype
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.anchor_left = 0.43
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

func _populate() -> void:
	_rows.clear()
	for c in _list.get_children():
		c.queue_free()
	if _genotypes.is_empty():
		var empty := _text("No chargen data yet. Run Caves of Qud once with Raves connected to populate it.", VALUE, "body")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
	for i in range(_genotypes.size()):
		var row := _geno_card(_genotypes[i], i)
		_list.add_child(row)
		_rows.append({"panel": row, "geno": _genotypes[i]})

func _geno_card(g: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 10)
	panel.add_child(pad)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	pad.add_child(hb)

	# icon (genotype tile)
	var itex := _tile(str(g.get("tile", "")))
	if itex != null:
		var icon := TextureRect.new()
		icon.texture = itex
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(64, 64)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(icon)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	hb.add_child(v)
	v.add_child(_rich("[color=#%s]%s[/color]" % [TITLE.to_html(false), _esc(str(g.get("display", g.get("name", "?"))))], "title"))
	# a one-line summary of what this genotype is about
	var kind := "Mutations" if bool(g.get("supportsMutations", false)) else ("Cybernetics" if bool(g.get("supportsCybernetics", false)) else "")
	v.add_child(_rich("[color=#%s]%d attribute points%s[/color]" % [
		VALUE.to_html(false), int(g.get("statPoints", 0)),
		("   ·   " + kind) if kind != "" else ""], "caption"))

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

## Right panel: perk bullets + point budgets + the 6 attribute ranges for the selected genotype.
func _build_detail() -> void:
	if _detail == null:
		return
	for c in _detail.get_children():
		c.queue_free()
	if _sel < 0 or _sel >= _genotypes.size():
		return
	var g: Dictionary = _genotypes[_sel]

	_detail.add_child(_rich("[color=#%s]%s[/color]" % [GOLD.to_html(false), _esc(str(g.get("display", g.get("name", "?"))))], "big"))

	# point budgets
	var budgets := PackedStringArray()
	budgets.append("[color=#%s]Attributes[/color] [color=#%s]%d[/color]" % [LABEL.to_html(false), VALUE.to_html(false), int(g.get("statPoints", 0))])
	if int(g.get("mutationPoints", 0)) > 0:
		budgets.append("[color=#%s]Mutations[/color] [color=#%s]%d[/color]" % [LABEL.to_html(false), VALUE.to_html(false), int(g.get("mutationPoints", 0))])
	if int(g.get("cyberLicensePoints", 0)) > 0:
		budgets.append("[color=#%s]Cybernetics license[/color] [color=#%s]%d[/color]" % [LABEL.to_html(false), VALUE.to_html(false), int(g.get("cyberLicensePoints", 0))])
	_detail.add_child(_rich("      ".join(budgets), "caption"))

	# perk bullets (Qud markup)
	var extra: Array = g.get("extraInfo", [])
	if extra is Array and not extra.is_empty():
		_detail.add_child(_gap(6))
		for x in extra:
			var bb := "[color=#%s]•[/color] %s" % [GREEN.to_html(false), QudText.to_bbcode(str(x), _palette)]
			var r := _rich(bb, "body")
			r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_detail.add_child(r)

	# the 6 attribute ranges
	var stats: Array = g.get("stats", [])
	if stats is Array and not stats.is_empty():
		_detail.add_child(_gap(8))
		_detail.add_child(_rich("[color=#%s]Attribute ranges[/color]" % LABEL.to_html(false), "caption"))
		var by_name := {}
		for s in stats:
			by_name[str(s.get("name", ""))] = s
		for attr in ATTR_ORDER:
			if by_name.has(attr):
				var s: Dictionary = by_name[attr]
				_detail.add_child(_rich("[color=#%s]%s[/color]  [color=#%s]%d–%d[/color]" % [
					VALUE.to_html(false), attr, GOLD.to_html(false), int(s.get("min", 0)), int(s.get("max", 0))], "caption"))

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
		if _sel >= 0 and _sel < _genotypes.size():
			selected = str(_genotypes[_sel].get("name", ""))
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

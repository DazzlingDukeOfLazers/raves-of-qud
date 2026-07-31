extends Control

## CHARACTER CREATION — stage 0: GAME MODE (Qud's ":choose game mode:").
##
## Qud's chargen opens on the game-mode module (EmbarkModules.xml → QudGamemodeModule) BEFORE
## genotype; Raves was skipping straight to Genotype. This is that first step: a LEFT list of the
## modes (Tutorial / Classic / Roleplay / Wander / Daily) and a RIGHT detail panel with Qud's own
## description for the selected mode. The pick is captured into `selected` for the flow.
##
## Data-driven where possible: reads a "gameModes" array from chargen.json if the mod has slurped
## it, else falls back to MODES below (names + descriptions verbatim from EmbarkModules.xml, so the
## screen is faithful even before a slurp exists). Same chrome as GenotypeScreen.

signal closed
signal chose(mode: String)   # emitted when the player confirms a game mode (Enter)

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

## Qud's 16-colour palette for {{code|text}} markup in the descriptions (baked). Same as ZoneRenderer.
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

## Fallback modes — names + descriptions verbatim from Qud's EmbarkModules.xml (QudGamemodeModule),
## used when chargen.json carries no "gameModes" yet. `desc` keeps Qud's {{c|ù}} bullet markup.
const MODES := [
	{"name": "Tutorial", "display": "Tutorial", "desc": "Learn the basics of Caves of Qud."},
	{"name": "Classic", "display": "Classic", "desc": "Permadeath: lose your character when you die."},
	{"name": "Roleplay", "display": "Roleplay", "desc": "Checkpointing at settlements."},
	{"name": "Wander", "display": "Wander", "desc": "{{c|ù}} Most creatures begin neutral to you.\n{{c|ù}} No XP for killing.\n{{c|ù}} More XP for discoveries and performing the water ritual.\n{{c|ù}} Checkpointing at settlements."},
	{"name": "Daily", "display": "Daily", "desc": "{{c|ù}} One chance with a fixed character and world seed."},
]

## The confirmed mode name (or "" until confirmed), read by the chargen flow.
var selected := ""

var _modes: Array = []
var _sel := 0
var _rows: Array = []          # [{panel, mode}]
var _list: VBoxContainer
var _detail: VBoxContainer
var _palette := {}

func _ready() -> void:
	name = "GameModeScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_modes = _load()

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

## Prefer the mod's slurped modes (chargen.json "gameModes"); else Qud's XML-verbatim MODES.
func _load() -> Array:
	var path := InputModel.support_dir().path_join("chargen.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.get("gameModes", null) is Array and not data["gameModes"].is_empty():
				return data["gameModes"]
	return MODES.duplicate(true)

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
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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
	l.text = "◈  Game Mode  ◈"
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
	# LEFT: the mode choices
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

	# RIGHT: description of the selected mode
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
	for i in range(_modes.size()):
		var row := _mode_card(_modes[i], i)
		_list.add_child(row)
		_rows.append({"panel": row, "mode": _modes[i]})

func _mode_card(m: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 10)
	panel.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	pad.add_child(v)
	v.add_child(_rich("[color=#%s]%s[/color]" % [TITLE.to_html(false), _esc(str(m.get("display", m.get("name", "?"))))], "title"))
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
	if _sel < 0 or _sel >= _modes.size():
		return
	var m: Dictionary = _modes[_sel]
	_detail.add_child(_rich("[color=#%s]%s[/color]" % [GOLD.to_html(false), _esc(str(m.get("display", m.get("name", "?"))))], "big"))
	_detail.add_child(_gap(6))
	var desc := str(m.get("desc", ""))
	for line in desc.split("\n", false):
		var r := _rich(QudText.to_bbcode(line, _palette), "body")
		r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_detail.add_child(r)

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
		if _sel >= 0 and _sel < _modes.size():
			selected = str(_modes[_sel].get("name", ""))
			chose.emit(selected)
		accept_event()

# ── helpers ──────────────────────────────────────────────────────────────────

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

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

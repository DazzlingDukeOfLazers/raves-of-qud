extends Control

## THE MODS SCREEN — a 1:1-styled mimic of Caves of Qud's "Installed Mod Configuration".
##
## A full-screen Qud-style window (woven gold border + dark weave panel, reusing the frame
## sprites the mod extracted to title/chrome/) over the cave-art background: a titled header,
## a LEFT list of the player's installed mods (icon, title, author, version / size / tags,
## location, ENABLED badge) and a RIGHT preview panel, with a Back footer. The mod data is
## the player's OWN install — Qud's ModManager list, exported to mods.json by the bridge mod
## (ModsExporter), never redistributed. Read-only for now (view, not enable/disable).
##
## Opened as an overlay by MainMenu (over the menu box); `closed` fires when Back is chosen.

signal closed

# palette — measured off Qud's Mods screen
const FRAME := Color8(0xB6, 0xA1, 0x63)          # woven gold border
const PANEL := Color(0.055, 0.078, 0.078, 0.96)  # dark weave interior
const SCRIM := Color(0.02, 0.03, 0.03, 0.55)     # dims the menu/bg behind
const TITLE := Color8(0xF0, 0xEA, 0xD8)          # mod title
const AUTHOR := Color8(0x7E, 0xC8, 0xC0)         # "by <author>"
const LABEL := Color8(0x6E, 0xB5, 0xC9)          # "Version:" / "Size:" / "Tags:" / "Location:"
const VALUE := Color8(0xC9, 0xC2, 0xA8)          # field values
const GREEN := Color8(0x5F, 0xC8, 0x5A)          # ENABLED
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # header title, keycaps
const DIM := Color(0.89, 0.85, 0.72, 0.5)

const SIDE_W_FRAC := 0.016    # border thickness as a fraction of the panel
const BAR_H_FRAC := 0.022

var _mods: Array = []
var _sel := 0
var _rows: Array = []          # [{panel, mod}]
var _preview: TextureRect
var _preview_name: Label

func _ready() -> void:
	name = "ModsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	_mods = _load_mods()

	var scrim := ColorRect.new()
	scrim.color = SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks to the menu behind
	add_child(scrim)

	var frame := Control.new()          # the window panel, inset from the screen edges
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

## A clickable "‹ Back" at a fixed bottom-left spot (Esc also works) — the mouse route back
## to the menu, and a stable target for the regression suite's reset step.
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

## Fill the whole viewport explicitly — as an added-at-runtime overlay we can't rely on the
## parent propagating its size, so we anchor top-left and size to the viewport (and on resize).
func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── data ───────────────────────────────────────────────────────────────────────

func _load_mods() -> Array:
	var path := InputModel.support_dir().path_join("mods.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.has("mods") and data["mods"] is Array:
		return data["mods"]
	return []

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _png(path: String) -> Texture2D:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

# ── frame (reuse Qud's woven gold border + weave panel) ──────────────────────────

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
	if side == null and bar == null:   # no extracted sprites — flat gold outline
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

# ── header / body / footer ───────────────────────────────────────────────────────

func _build_header(frame: Control) -> void:
	var l := Label.new()
	l.text = "◈  Mods  ◈"
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
	# LEFT: scrollable mod list
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0.03
	scroll.anchor_right = 0.70
	scroll.anchor_top = 0.11
	scroll.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		scroll.set("offset_" + k, 0.0)
	frame.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	if _mods.is_empty():
		var empty := _text("No mods found. Play Caves of Qud once with Raves connected to populate this list.", VALUE, "body")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(empty)
	for i in range(_mods.size()):
		var row := _mod_row(_mods[i], i)
		list.add_child(row)
		_rows.append({"panel": row, "mod": _mods[i]})

	# RIGHT: preview panel for the selected mod
	var right := VBoxContainer.new()
	right.anchor_left = 0.72
	right.anchor_right = 0.97
	right.anchor_top = 0.11
	right.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		right.set("offset_" + k, 0.0)
	right.add_theme_constant_override("separation", 10)
	frame.add_child(right)
	_preview = TextureRect.new()
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.custom_minimum_size = Vector2(0, 220)
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pb := StyleBoxFlat.new()
	pb.bg_color = Color(0, 0, 0, 0.4)
	pb.set_border_width_all(1)
	pb.border_color = FRAME
	var pw := PanelContainer.new()
	pw.add_theme_stylebox_override("panel", pb)
	pw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw.add_child(_preview)
	right.add_child(pw)
	_preview_name = _text("", TITLE, "caption")
	_preview_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_preview_name)

func _mod_row(mod: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 8)
	panel.add_child(pad)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	pad.add_child(hb)

	# icon
	var icon := TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE   # scale to OUR size, not the texture's
	icon.custom_minimum_size = Vector2(72, 72)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var itex := _png(str(mod.get("preview", "")))
	if itex != null:
		icon.texture = itex
	else:
		var ib := StyleBoxFlat.new()
		ib.bg_color = Color(0, 0, 0, 0.35)
		ib.set_border_width_all(1)
		ib.border_color = FRAME
		var iw := PanelContainer.new()
		iw.add_theme_stylebox_override("panel", ib)
		iw.custom_minimum_size = Vector2(72, 72)
		hb.add_child(iw)
	if itex != null:
		hb.add_child(icon)

	# text block
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	hb.add_child(v)
	# title + author
	var head := _rich("[color=#%s]%s[/color]  [color=#%s]by %s[/color]" % [
		TITLE.to_html(false), _esc(str(mod.get("title", mod.get("id", "?")))),
		AUTHOR.to_html(false), _esc(str(mod.get("author", "unknown")))], "title")
	v.add_child(head)
	# version / size / tags
	var tags: Array = mod.get("tags", [])
	var meta := _rich("[color=#%s]Version:[/color] [color=#%s]%s[/color]    [color=#%s]Size:[/color] [color=#%s]%s[/color]    [color=#%s]Tags:[/color] [color=#%s]%s[/color]" % [
		LABEL.to_html(false), VALUE.to_html(false), _esc(str(mod.get("version", "—"))),
		LABEL.to_html(false), VALUE.to_html(false), _esc(str(mod.get("size", "—"))),
		LABEL.to_html(false), VALUE.to_html(false), _esc(", ".join(tags) if tags is Array else "—")], "caption")
	v.add_child(meta)
	# location
	var loc := _rich("[color=#%s]Location:[/color] [color=#%s]%s[/color]" % [
		LABEL.to_html(false), VALUE.to_html(false), _esc(_shorten(str(mod.get("path", ""))))], "caption")
	v.add_child(loc)
	# enabled badge
	var enabled: bool = bool(mod.get("enabled", true))
	var badge := _text("ENABLED" if enabled else "DISABLED", GREEN if enabled else DIM, "caption")
	v.add_child(badge)

	_style_row(panel, false)
	return panel

func _build_footer(frame: Control) -> void:
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
	l.anchor_top = 0.92
	l.anchor_bottom = 0.98
	for k in ["left", "top", "right", "bottom"]:
		l.set("offset_" + k, 0.0)
	frame.add_child(l)

# ── selection + input ────────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	for i in range(_rows.size()):
		_style_row(_rows[i]["panel"], i == _sel)
	if _sel >= 0 and _sel < _mods.size():
		var mod: Dictionary = _mods[_sel]
		var tex := _png(str(mod.get("preview", "")))
		if _preview != null:
			_preview.texture = tex
		if _preview_name != null:
			_preview_name.text = str(mod.get("title", mod.get("id", "")))

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

# ── small helpers ──────────────────────────────────────────────────────────────

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

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")

func _shorten(p: String) -> String:
	var home := OS.get_environment("HOME")
	if home != "" and p.begins_with(home):
		p = "~" + p.substr(home.length())
	if p.length() > 64:
		p = "…" + p.substr(p.length() - 63)
	return p

extends PanelContainer

## Command bar — row 5. The player's activated abilities (the mod's `abilities` block, in Qud's bar
## order): each shows its icon + name + [state] + <hotkey>, and the name is clickable to activate it
## (sends the ability's command over the bridge, like fire/reload). Horizontal, wraps if needed.

signal command_requested(payload: Dictionary)   # {type:"command", command:"..."} — MainFrame forwards it

# Abilities whose command opens a Qud direction prompt (PickDirection). Clicking these shows Raves'
# direction picker. Only gate KNOWN ones — activating a direction ability BLOCKS Qud until answered,
# so we must not show/cancel the picker for abilities that don't actually prompt. Extend as found.
const DIR_ABILITIES := ["CommandSurvivalCamp"]   # Make Camp

const DIM := "#8a8f9a"
const KEY := "#ffd200"       # hotkey — UI yellow
const ON := "#59d38a"        # toggled-on green
const OFF := "#8a8f9a"       # toggled-off / dim
const CD := "#e08a4a"        # cooling-down amber

var _tiles: RefCounted       # shared tile recolouring for ability icons (set in _ready)
var _rt: RichTextLabel       # user (QoL) layout: all abilities inline, left-packed
var _cells: HBoxContainer    # 1:1 layout: one equal-width cell per ability, spread across the bar (Qud)
var _abilities_btn: Button   # far-left: opens Qud's Abilities menu (the 'a' command)
var _palette := {}
var _ability_tex := {}       # command -> recoloured icon texture, for the direction picker cursor
var _last_data := {}         # last snapshot, so a mode toggle re-renders without waiting for a new one
var _one_to_one := false     # 1:1: spread abilities in equal cells (Qud) vs the inline QoL list

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	add_child(h)

	# Far-left: the Abilities menu (Qud's 'a' = CmdAbilities), sent over the bridge like any command.
	_abilities_btn = Button.new()
	_abilities_btn.text = "Ⓐ Abilities"
	_abilities_btn.focus_mode = Control.FOCUS_NONE
	_abilities_btn.tooltip_text = "Open the Abilities menu (a)"
	_abilities_btn.pressed.connect(func() -> void:
		command_requested.emit({"type": "command", "command": "CmdAbilities"}))
	h.add_child(_abilities_btn)

	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true
	_rt.fit_content = true
	_rt.scroll_active = false
	# NOT focusable and NOT selectable: an ability [url] click must NOT grab keyboard focus, or the
	# focused label swallows the movement arrows (Godot uses them for UI focus nav) — that was the
	# "can't move after Make Camp" bug. meta_clicked still fires on FOCUS_NONE. (Same rule as the buttons.)
	_rt.focus_mode = Control.FOCUS_NONE
	_rt.selection_enabled = false
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rt.meta_clicked.connect(_on_meta)      # ability names are clickable [url] links
	h.add_child(_rt)

	# 1:1 layout: equal-width cells spread across the bar (hidden until 1:1). Populated per snapshot.
	_cells = HBoxContainer.new()
	_cells.add_theme_constant_override("separation", 0)   # dividers come from VSeparators between cells
	_cells.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cells.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cells.visible = false
	h.add_child(_cells)

## MainFrame calls this each snapshot with the full data (needs abilities + palette + tilesDir).
func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.palette = _palette
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_ability_tex.clear()
	if _one_to_one:
		_render_cells(data.get("abilities", []))
	else:
		_render_inline(data.get("abilities", []))

## 1:1 (parity) mode: spread abilities in equal-width bordered cells across the bar, like Qud (vs the
## QoL inline list). Master switch is MainFrame/Holodeck; here we swap the layout + re-render.
func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	_rt.visible = not on
	_cells.visible = on
	if not _last_data.is_empty():
		set_snapshot(_last_data)

## USER (QoL): all abilities inline in one label, left-packed, names clickable.
func _render_inline(abilities: Array) -> void:
	_rt.clear()
	if abilities.is_empty():
		_rt.append_text("[color=%s]No abilities[/color]" % DIM)
		return
	var img_h := int(UiFont.px(get_viewport(), "body") * 3.0)   # 2x the previous size, per request
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	for a in abilities:
		var tex: Texture2D = _tiles.texture_for(a, true)   # abilities have no perceived variant
		var cmd := String(a.get("command", ""))
		if cmd != "":
			_ability_tex[cmd] = tex        # remember the icon for the direction-picker cursor
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(String(a.get("glyph", "")).replace("[", "[lb]"))
		var name_bb := QudText.to_bbcode(String(a.get("name", "")), _palette)
		_rt.append_text(" [url=cmd:%s]%s[/url]%s%s     " % [cmd, name_bb, _state_tag(a), _hotkey_tag(a)])

## 1:1 (Qud): one equal-width cell per ability, spread across the whole bar with dividers between.
func _render_cells(abilities: Array) -> void:
	for c in _cells.get_children():
		c.queue_free()
	if abilities.is_empty():
		var empty := Label.new()
		empty.text = "No abilities"
		empty.add_theme_color_override("font_color", Color.html(DIM))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cells.add_child(empty)
		return
	var icon_px := int(UiFont.px(get_viewport(), "body") * 1.8)   # visible tile icon (crisp, nearest)
	for i in abilities.size():
		if i > 0:
			_cells.add_child(VSeparator.new())   # divider between cells, like Qud
		_cells.add_child(_make_cell(abilities[i], icon_px))

## One ability as a centred, equal-share, clickable cell: a nearest-filtered tile icon + a name/state/
## hotkey label, both centred. The cell (an HBox) catches the click via gui_input; children IGNORE the
## mouse so it falls through. Nothing here takes keyboard focus, so the movement arrows are never
## swallowed (the "can't move after Make Camp" bug).
func _make_cell(a: Dictionary, icon_px: int) -> Control:
	var cmd := String(a.get("command", ""))
	var tex: Texture2D = _tiles.texture_for(a, true)
	if cmd != "":
		_ability_tex[cmd] = tex
	var cell := HBoxContainer.new()
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # equal share of the bar width
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 6)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.tooltip_text = QudText.strip(String(a.get("name", "")))
	cell.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_activate(cmd))
	if tex != null:
		var ir := TextureRect.new()
		ir.texture = tex
		ir.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixel-art, no blur
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.custom_minimum_size = Vector2(round(icon_px * 16.0 / 24.0), icon_px)
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE   # click falls through to the cell
		cell.add_child(ir)
	var lbl := Label.new()
	lbl.text = "%s%s%s" % [QudText.strip(String(a.get("name", ""))), _state_plain(a), _hotkey_plain(a)]
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(lbl)
	return cell

## Plain-text state/hotkey suffixes for the button label (no bbcode in Button.text).
func _state_plain(a: Dictionary) -> String:
	if bool(a.get("toggleable", false)):
		return " [on]" if bool(a.get("toggle", false)) else " [off]"
	var cd := int(a.get("cooldown", 0))
	if cd > 0:
		return " [cd %d]" % cd
	if not bool(a.get("enabled", true)):
		return " [disabled]"
	return ""

func _hotkey_plain(a: Dictionary) -> String:
	var hk := String(a.get("hotkey", ""))
	return " <%s>" % hk if hk != "" else ""

## Shared activate path for a cell click (mirrors _on_meta): send the command + direction-picker hint.
func _activate(cmd: String) -> void:
	if cmd == "":
		return
	command_requested.emit({
		"type": "command", "command": cmd,
		"icon": _ability_tex.get(cmd),
		"pick_dir": DIR_ABILITIES.has(cmd),
	})

func _state_tag(a: Dictionary) -> String:
	if bool(a.get("toggleable", false)):
		var on := bool(a.get("toggle", false))
		return " [color=%s][%s][/color]" % [ON if on else OFF, "on" if on else "off"]
	var cd := int(a.get("cooldown", 0))
	if cd > 0:
		return " [color=%s][cd %d][/color]" % [CD, cd]
	if not bool(a.get("enabled", true)):
		return " [color=%s][disabled][/color]" % DIM
	return ""

func _hotkey_tag(a: Dictionary) -> String:
	var hk := String(a.get("hotkey", ""))
	return " [color=%s]<%s>[/color]" % [KEY, hk] if hk != "" else ""

func _on_meta(meta: Variant) -> void:
	var s := String(meta)
	if s.begins_with("cmd:"):
		var c := s.substr(4)
		if c != "":
			command_requested.emit({
				"type": "command", "command": c,
				"icon": _ability_tex.get(c),           # cursor for the direction picker
				"pick_dir": DIR_ABILITIES.has(c),      # only known direction abilities open the picker
			})

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
var _abilities: Array = []   # current abilities in bar order, for the 1-9 hotkeys (1:1)

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudPalette.CHROME
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
	_abilities = data.get("abilities", [])   # keep for the 1-9 hotkeys
	if _one_to_one:
		_render_cells(_abilities)
	else:
		_render_inline(_abilities)

## 1:1 (parity) mode: spread abilities in equal-width bordered cells across the bar, like Qud (vs the
## QoL inline list). Master switch is MainFrame/Holodeck; here we swap the layout + re-render.
func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	_rt.visible = not on
	_cells.visible = on
	# drop the rounded QoL box in 1:1 — the continuous bottom-strip chrome + the VSeparator dividers ARE
	# Qud's look; the framed box floated on the playfield. Restore it in user mode.
	var cur := get_theme_stylebox("panel")
	if cur is StyleBoxFlat:
		var f: StyleBoxFlat = (cur as StyleBoxFlat).duplicate()
		if on:
			f.bg_color = Color(0, 0, 0, 0)
			f.set_border_width_all(0)
			f.set_corner_radius_all(0)
		else:
			f.bg_color = QudPalette.CHROME
			f.set_border_width_all(1)
			f.border_color = Color(1, 1, 1, 0.12)
			f.set_corner_radius_all(3)
		add_theme_stylebox_override("panel", f)
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
		_cells.add_child(_make_cell(abilities[i], icon_px, i + 1))   # slot = 1-based hotkey

## One ability as a centred, equal-share, clickable cell: a nearest-filtered tile icon + a name/state/
## hotkey label, both centred. The cell (an HBox) catches the click via gui_input; children IGNORE the
## mouse so it falls through. Nothing here takes keyboard focus, so the movement arrows are never
## swallowed (the "can't move after Make Camp" bug).
func _make_cell(a: Dictionary, icon_px: int, slot: int) -> Control:
	var cmd := String(a.get("command", ""))
	var tex: Texture2D = _tiles.texture_for(a, true)
	if cmd != "":
		_ability_tex[cmd] = tex
	var cell := HBoxContainer.new()
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # equal share of the bar width
	cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 6)
	cell.tooltip_text = QudText.strip(String(a.get("name", "")))
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
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
	lbl.text = "%s%s%s" % [QudText.strip(String(a.get("name", ""))), _state_plain(a), _hotkey_label(a, slot)]
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(lbl)
	return cell

## The cell's hotkey tag: the mod's own hotkey if it sends one, else the positional bar slot (1-9),
## which is what the 1-9 keys activate in 1:1. Matches Qud's " <1>".. quick-slot labels.
func _hotkey_label(a: Dictionary, slot: int) -> String:
	var hk := String(a.get("hotkey", ""))
	if hk == "" and slot >= 1 and slot <= 9:
		hk = str(slot)
	return " <%s>" % hk if hk != "" else ""

## Cooldown in TURNS as Qud displays it. The mod sends the raw ActivatedAbilityEntry.Cooldown, which is
## 10x the shown turns (Qud renders `Cooldown / 10` — e.g. 950 -> 95). 0 = not cooling.
func _cooldown_turns(a: Dictionary) -> int:
	var cd := int(a.get("cooldown", 0))
	return maxi(1, int(cd / 10.0)) if cd > 0 else 0   # never show "cd 0" while still cooling

## Plain-text state suffixes for the cell label. Cooldown first, then toggle/disabled — matching Qud's
## "[95] [off]" (a toggleable ability can be BOTH cooling down AND toggled off, so show both).
func _state_plain(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += " [cd %d]" % cd
	if bool(a.get("toggleable", false)):
		s += " [on]" if bool(a.get("toggle", false)) else " [off]"
	elif not bool(a.get("enabled", true)):
		s += " [disabled]"
	return s

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

## 1:1 ability hotkeys: the 1-9 keys activate the matching bar slot. Only in 1:1 (where the camera-mode
## 1-7 bindings are locked out, so the digits are free); user mode leaves them to the camera. Runs in
## _unhandled_key_input, which fires BEFORE Main's _unhandled_input, so a handled digit never reaches
## the (locked) camera switch. Nothing here grabs focus.
func _unhandled_key_input(e: InputEvent) -> void:
	if not _one_to_one or _abilities.is_empty():
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var slot := -1
	if e.keycode >= KEY_1 and e.keycode <= KEY_9:
		slot = e.keycode - KEY_1                       # top-row digits
	elif e.keycode >= KEY_KP_1 and e.keycode <= KEY_KP_9:
		slot = e.keycode - KEY_KP_1                    # numpad digits
	if slot < 0 or slot >= _abilities.size():
		return
	_activate(String(_abilities[slot].get("command", "")))
	get_viewport().set_input_as_handled()

func _state_tag(a: Dictionary) -> String:
	var s := ""
	var cd := _cooldown_turns(a)
	if cd > 0:
		s += " [color=%s][cd %d][/color]" % [CD, cd]
	if bool(a.get("toggleable", false)):
		var on := bool(a.get("toggle", false))
		s += " [color=%s][%s][/color]" % [ON if on else OFF, "on" if on else "off"]
	elif not bool(a.get("enabled", true)):
		s += " [color=%s][disabled][/color]" % DIM
	return s

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

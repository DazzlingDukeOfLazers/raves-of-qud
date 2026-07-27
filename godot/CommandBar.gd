extends PanelContainer

## Command bar — row 5. The player's activated abilities (the mod's `abilities` block, in Qud's bar
## order): each shows its icon + name + [state] + <hotkey>, and the name is clickable to activate it
## (sends the ability's command over the bridge, like fire/reload). Horizontal, wraps if needed.

signal command_requested(payload: Dictionary)   # {type:"command", command:"..."} — MainFrame forwards it

const DIM := "#8a8f9a"
const KEY := "#ffd200"       # hotkey — UI yellow
const ON := "#59d38a"        # toggled-on green
const OFF := "#8a8f9a"       # toggled-off / dim
const CD := "#e08a4a"        # cooling-down amber

var _tiles: RefCounted       # shared tile recolouring for ability icons (set in _ready)
var _rt: RichTextLabel
var _abilities_btn: Button   # far-left: opens Qud's Abilities menu (the 'a' command)
var _palette := {}

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
	_rt.selection_enabled = true
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rt.meta_clicked.connect(_on_meta)      # ability names are clickable [url] links
	h.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs abilities + palette + tilesDir).
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.palette = _palette
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	var abilities: Array = data.get("abilities", [])

	_rt.clear()
	if abilities.is_empty():
		_rt.append_text("[color=%s]No abilities[/color]" % DIM)
		return

	var img_h := int(UiFont.px(get_viewport(), "body") * 3.0)   # 2x the previous size, per request
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	for a in abilities:
		var tex: Texture2D = _tiles.texture_for(a, true)   # abilities have no perceived variant
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(String(a.get("glyph", "")).replace("[", "[lb]"))
		var cmd := String(a.get("command", ""))
		var name_bb := QudText.to_bbcode(String(a.get("name", "")), _palette)
		_rt.append_text(" [url=cmd:%s]%s[/url]%s%s     " % [cmd, name_bb, _state_tag(a), _hotkey_tag(a)])

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
			command_requested.emit({"type": "command", "command": c})

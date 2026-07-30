extends PanelContainer

## Active effects view — its own scene in MainFrame's row-4 left cell. Shows the player's current
## effects (buffs/debuffs) from the snapshot's `effects` array, each rendered in its Qud colour
## (the effect's DisplayName markup — e.g. wet = blue), with a dim turn count. Qud already colours
## debuffs, so we keep the game's own DisplayName rather than recolouring; the `bad` flag is available
## on each entry for future grouping/emphasis but isn't needed to get the colours right.

const DIM := "#8a8f9a"    # dim grey for the duration + separators

var _rt: RichTextLabel
var _palette := {}

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudPalette.CHROME
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var title := Label.new()
	title.text = "Active effects"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true               # effect names carry Qud {{colour|...}} markup
	_rt.scroll_active = true
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## Uniform panel entry (MainFrame feeds every panel via set_snapshot).
func set_snapshot(data: Dictionary) -> void:
	set_effects(data.get("effects", []), data.get("palette", {}))

func set_effects(effects: Array, palette: Dictionary) -> void:
	if not palette.is_empty():
		_palette = palette
	if effects.is_empty():
		_rt.text = "[color=%s]— none —[/color]" % DIM
		return
	var chips: Array[String] = []
	for e in effects:
		var nm := String(e.get("name", ""))
		if nm == "":
			continue
		chips.append(QudText.to_bbcode(nm, _palette))         # coloured name only, as Qud draws it (no turn count)
	var sep := "[color=%s]   ·   [/color]" % DIM
	_rt.text = sep.join(chips)

extends PanelContainer

## Context menu view — its own scene in MainFrame's row-4 right cell. Mirrors Qud's bottom missile-weapon
## area (the mod's `context` block): for each equipped missile weapon, its coloured name + ammo
## (remaining/total), with Fire/Reload action chips; "No missile weapons equipped." when there are none.
## Actions are display-only for now (a future step can drive them over the bridge).

const DIM := "#8a8f9a"
const AMMO_COL := Color(1.00, 0.82, 0.00)   # warm/amber, like Qud's ammo readout

var _rt: RichTextLabel
var _actions: HBoxContainer
var _palette := {}

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13)
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
	title.text = "Context menu"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)

	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true                # weapon names carry Qud {{colour|...}} markup
	_rt.fit_content = true
	_rt.scroll_active = false
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

	_actions = HBoxContainer.new()           # Fire / Reload chips
	_actions.add_theme_constant_override("separation", 6)
	v.add_child(_actions)

## MainFrame calls this each snapshot with the `context` block + palette.
func set_context(ctx: Dictionary, palette: Dictionary) -> void:
	if not palette.is_empty():
		_palette = palette
	_clear_actions()
	if String(ctx.get("kind", "none")) != "missile":
		_rt.text = "[color=%s]%s[/color]" % [DIM, String(ctx.get("text", "—"))]
		_actions.visible = false
		return

	var lines: Array[String] = []
	for w in ctx.get("weapons", []):
		var name_bb := QudText.to_bbcode(String(w.get("name", "")), _palette)
		var total := int(w.get("ammoTotal", 0))
		if total > 0:
			var rem := int(w.get("ammoRemaining", 0))
			name_bb += "   [color=%s]%d/%d[/color]" % [AMMO_COL.to_html(false), rem, total]
		lines.append(name_bb)
	_rt.text = "\n".join(lines)

	for a in ctx.get("actions", []):
		_actions.add_child(_chip(String(a)))
	_actions.visible = _actions.get_child_count() > 0

func _chip(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.17)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.14)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	p.add_child(l)
	return p

func _clear_actions() -> void:
	for c in _actions.get_children():
		c.queue_free()

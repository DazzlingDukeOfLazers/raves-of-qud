extends PanelContainer

## Target view — its own scene in MainFrame's row-4 middle cell. Shows Qud's current combat target
## (the mod's `target` block, from XRL.UI.Sidebar.CurrentTarget): the coloured name, an HP bar, and the
## direction + distance from the player. "[none]" when nothing is targeted. Client-side distance/arrow
## from the player + target cell (same idea as NearbyObjects), so it updates as either one moves.

const DIM := "#8a8f9a"
const HP_COL := Color(0.25, 0.80, 0.32)     # green, matching the player HP bar
const HOSTILE_COL := Color(1.00, 0.30, 0.30)

var _rt_name: RichTextLabel
var _hp_row: HBoxContainer
var _l_hp: Label
var _bar_hp: ProgressBar
var _l_dir: Label
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
	title.text = "Target"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)

	_rt_name = RichTextLabel.new()
	_rt_name.bbcode_enabled = true          # name carries Qud {{colour|...}} markup
	_rt_name.fit_content = true
	_rt_name.scroll_active = false
	_rt_name.selection_enabled = true
	_rt_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt_name)

	_hp_row = HBoxContainer.new()
	_hp_row.add_theme_constant_override("separation", 8)
	_l_hp = Label.new()
	_l_hp.add_theme_color_override("font_color", HP_COL)
	_l_hp.custom_minimum_size = Vector2(96, 0)
	_hp_row.add_child(_l_hp)
	_bar_hp = ProgressBar.new()
	_bar_hp.show_percentage = false
	_bar_hp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar_hp.custom_minimum_size = Vector2(0, 12)
	var bgs := StyleBoxFlat.new()
	bgs.bg_color = Color(0, 0, 0, 0.35)
	bgs.set_corner_radius_all(3)
	var fills := StyleBoxFlat.new()
	fills.bg_color = HP_COL
	fills.set_corner_radius_all(3)
	_bar_hp.add_theme_stylebox_override("background", bgs)
	_bar_hp.add_theme_stylebox_override("fill", fills)
	_hp_row.add_child(_bar_hp)
	v.add_child(_hp_row)

	_l_dir = Label.new()
	_l_dir.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	v.add_child(_l_dir)

## MainFrame calls this each snapshot with the full data (needs target + player + palette).
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	var t: Dictionary = data.get("target", {})
	if t.is_empty() or not bool(t.get("present", false)):
		_show_none()
		return

	var raw := String(t.get("display", ""))
	var name_bb := QudText.to_bbcode(raw, _palette)
	if bool(t.get("hostile", false)):
		name_bb += "   [color=#%s]HOSTILE[/color]" % HOSTILE_COL.to_html(false)
	_rt_name.text = name_bb

	if t.has("hp") and t.has("hpMax"):
		var hp := int(t.get("hp", 0))
		var hpmax := maxi(1, int(t.get("hpMax", 1)))
		_l_hp.text = "HP: %d/%d" % [hp, hpmax]
		_bar_hp.max_value = hpmax
		_bar_hp.value = clampi(hp, 0, hpmax)
		_hp_row.visible = true
	else:
		_hp_row.visible = false

	_l_dir.text = _direction_text(data, t)
	_l_dir.visible = _l_dir.text != ""

func _show_none() -> void:
	_rt_name.text = "[color=%s][none][/color]" % DIM
	_hp_row.visible = false
	_l_dir.visible = false

## Arrow + Chebyshev distance from the player to the target (both cells are in the live zone). Empty
## when either position is missing (e.g. target is off-zone).
func _direction_text(data: Dictionary, t: Dictionary) -> String:
	var p: Dictionary = data.get("player", {})
	if not (t.has("x") and t.has("y") and p.has("x") and p.has("y")):
		return ""
	var dx := int(t.get("x", 0)) - int(p.get("x", 0))
	var dy := int(t.get("y", 0)) - int(p.get("y", 0))
	var dist: int = maxi(absi(dx), absi(dy))
	if dist == 0:
		return "· here"
	return "%s  %d tile%s" % [_arrow(dx, dy), dist, "" if dist == 1 else "s"]

func _arrow(dx: int, dy: int) -> String:
	if dx == 0:
		return "↑" if dy < 0 else "↓"
	if dy == 0:
		return "→" if dx > 0 else "←"
	if dx > 0:
		return "↗" if dy < 0 else "↘"
	return "↖" if dy < 0 else "↙"

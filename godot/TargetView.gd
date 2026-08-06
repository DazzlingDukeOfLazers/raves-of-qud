extends PanelContainer

## Qud's row-3 face against our body size, measured off its strip.
const ROW3_FONT_SCALE := 0.667

## Target view — its own scene in MainFrame's row-4 middle cell. Shows Qud's current combat target
## (the mod's `target` block, from XRL.UI.Sidebar.CurrentTarget).
##
## PERCEIVED (default): exactly what a player sees — the coloured name, then Qud's descriptor line
## "<wound>, <feeling>, <toughness>" (e.g. "Perfect, Neutral, Average"). Exact HP is HIDDEN in Qud
## unless you have scanning gear/skills, so the wound WORD stands in for it (the mod already applies
## Qud's own rule). Plus the direction + distance from the player (spatial, not hidden).
##
## FULL (debug, via the top-menu toggle): adds the exact HP bar + numbers, and reveals the real icon.

const DIM := "#8a8f9a"
const HP_COL := Color(0.25, 0.80, 0.32)     # green, matching the player HP bar

var _tiles: RefCounted                          # shared tile recolouring for the sprite column (set in _ready)

var _sprite: TextureRect
var _rt_name: RichTextLabel
var _rt_desc: RichTextLabel
var _hp_row: HBoxContainer
var _l_hp: Label
var _bar_hp: ProgressBar
var _l_dir: Label
var _palette := {}
var _full := false            # debug: false = perceived (what the player sees), true = full info
var _last_data := {}          # so the toggle re-renders without waiting for a new snapshot

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
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

	_title = Label.new()
	_title.text = "Target"
	_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(_title)

	# Two columns: the target SPRITE (left) and its info (right).
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)

	_sprite = TextureRect.new()             # recoloured target tile; Qud tiles are 16x24
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_sprite.custom_minimum_size = Vector2(44, 66)
	_sprite.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(_sprite)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(right)

	_rt_name = RichTextLabel.new()          # name carries Qud {{colour|...}} markup
	_rt_name.bbcode_enabled = true
	_rt_name.fit_content = true
	_rt_name.scroll_active = false
	_rt_name.selection_enabled = false   # selectable RTLs grab focus on click -> arrows stop (command-bar rule)
	_rt_name.focus_mode = Control.FOCUS_NONE
	_rt_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_rt_name)

	_rt_desc = RichTextLabel.new()          # "<wound>, <feeling>, <toughness>", each in its Qud colour
	_rt_desc.bbcode_enabled = true
	_rt_desc.fit_content = true
	_rt_desc.scroll_active = false
	_rt_desc.selection_enabled = false
	_rt_desc.focus_mode = Control.FOCUS_NONE
	_rt_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_rt_desc)

	_hp_row = HBoxContainer.new()           # exact HP — shown only in FULL (debug) mode
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
	right.add_child(_hp_row)

	_l_dir = Label.new()
	_l_dir.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	right.add_child(_l_dir)

## MainFrame calls this each snapshot with the full data (needs target + player + palette).
## 1:1: drop the rounded QoL box so the continuous bottom-strip chrome shows through (Qud has no per-panel
## box). Keeps the content margins. User mode restores the framed look.
var _title: Label
var _one_to_one := false

func set_one_to_one(on: bool) -> void:
	# QUD'S ROW-3 TEXT IS SMALL. Measured off its strip: "ACTIVE EFFECTS:" spans 122px for 15
	# characters (~8.1 each, a ~13.5px face) where ours ran 183px at the theme's body size (~21).
	# That is also why row 3 came out 31 tall against Qud's 28 -- the row is sized by this text.
	# A scaled THEME rather than per-label overrides: each of these strips has several labels.
	if on:
		theme = UiFont.scaled_theme(get_viewport(), ROW3_FONT_SCALE)
	else:
		theme = null
	_one_to_one = on
	if _title != null:
		_title.visible = not on   # 1:1: title folds into the name row ("Target: [none]")
	if not _last_data.is_empty():
		_render()
	var cur := get_theme_stylebox("panel")
	if cur is StyleBoxFlat:
		var f: StyleBoxFlat = (cur as StyleBoxFlat).duplicate()
		if on:
			f.bg_color = Color(0, 0, 0, 0)
			f.set_border_width_all(0)
			f.set_corner_radius_all(0)
			# 5, so the ink lands on Qud's row (1000..1009). This only works now that the text is
			# small enough for the row's pinned 28 to be the binding height: while the CONTENT set
			# the height, padding here just grew the row upward and the text never moved.
			f.content_margin_top = 5
			# ZERO at the bottom, not 2. Row 3 is anchored to the ability bar above it, so its TOP
			# moves with its height: padding above the text buys nothing (the row grows upward by the
			# same amount), and only the bottom padding decides how far the text sits off the bar.
			f.content_margin_bottom = 0
		else:
			f.bg_color = QudPalette.CHROME
			f.set_border_width_all(1)
			f.border_color = Color(1, 1, 1, 0.12)
			f.set_corner_radius_all(3)
		add_theme_stylebox_override("panel", f)

func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_render()

func _render() -> void:
	var data := _last_data
	var t: Dictionary = data.get("target", {})
	if t.is_empty() or not bool(t.get("present", false)):
		_show_none()
		return

	var _pfx := "[color=#3b596b]TARGET:[/color] " if _one_to_one else ""
	_rt_name.text = _pfx + QudText.to_bbcode(String(t.get("display", "")), _palette)

	# Left column: the recoloured target sprite — perceived icon by default, real icon in full mode.
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_tiles.palette = _palette
	var tex: Texture2D = _tiles.texture_for(t, _full)
	_sprite.texture = tex
	_sprite.visible = tex != null

	# Qud's descriptor line: wound (health word), feeling (disposition), difficulty (toughness) — each
	# already colour-marked up by the game; join the non-empty ones with a dim comma.
	var parts: Array[String] = []
	for key in ["wound", "feeling", "difficulty"]:
		var s := String(t.get(key, "")).strip_edges()
		if s != "":
			parts.append(QudText.to_bbcode(s, _palette))
	var sep := "[color=%s], [/color]" % DIM
	_rt_desc.text = sep.join(parts)
	_rt_desc.visible = not parts.is_empty()

	# Exact HP only in FULL (debug) mode — it's hidden info in Qud.
	if _full and t.has("hp") and t.has("hpMax"):
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
	var _pfx := "[color=#3b596b]TARGET:[/color] " if _one_to_one else ""
	_rt_name.text = _pfx + "[color=%s][none][/color]" % DIM
	_sprite.visible = false
	_rt_desc.visible = false
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

## Driven by MainFrame's global top-menu toggle.
func set_full_info(full: bool) -> void:
	_full = full
	if not _last_data.is_empty():
		_render()

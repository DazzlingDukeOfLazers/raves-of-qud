extends PanelContainer

## Qud's row-3 face against our body size, measured off its strip.
const ROW3_FONT_SCALE := 0.667

## Active effects view — its own scene in MainFrame's row-4 left cell. Shows the player's current
## effects (buffs/debuffs) from the snapshot's `effects` array, each rendered in its Qud colour
## (the effect's DisplayName markup — e.g. wet = blue), with a dim turn count. Qud already colours
## debuffs, so we keep the game's own DisplayName rather than recolouring; the `bad` flag is available
## on each entry for future grouping/emphasis but isn't needed to get the colours right.

const DIM := "#8a8f9a"    # dim grey for the duration + separators
const LABEL_1TO1 := "[color=#3b596b]ACTIVE EFFECTS:[/color]"   # Qud's inline uppercase label

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
	_title = Label.new()
	_title.text = "Active effects"
	_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(_title)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true               # effect names carry Qud {{colour|...}} markup
	_rt.scroll_active = true
	_rt.selection_enabled = false   # a selectable RTL grabs focus on click and the arrows stop
	_rt.focus_mode = Control.FOCUS_NONE   # reaching the player (the command-bar rule)
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## Uniform panel entry (MainFrame feeds every panel via set_snapshot).
## 1:1: drop the rounded QoL box so the continuous bottom-strip chrome shows through (Qud has no per-panel
## box — just plain sections). Keeps the content margins. User mode restores the framed look.
var _one_to_one := false
var _title: Label

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
		_title.visible = not on   # 1:1: Qud's strip is ONE line — the label goes inline (uppercase)
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
	set_effects(data.get("effects", []), data.get("palette", {}))

func set_effects(effects: Array, palette: Dictionary) -> void:
	if not palette.is_empty():
		_palette = palette
	if effects.is_empty():
		# 1:1: Qud's one-line strip is 'ACTIVE EFFECTS:' with nothing after when none
		_rt.text = LABEL_1TO1 if _one_to_one else "[color=%s]— none —[/color]" % DIM
		return
	var chips: Array[String] = []
	for e in effects:
		var nm := String(e.get("name", ""))
		if nm == "":
			continue
		chips.append(QudText.to_bbcode(nm, _palette))         # coloured name only, as Qud draws it (no turn count)
	var sep := "[color=%s]   ·   [/color]" % DIM
	_rt.text = (LABEL_1TO1 + " " if _one_to_one else "") + sep.join(chips)

extends PanelContainer

## Qud's row-3 face against our body size, measured off its strip.
const ROW3_FONT_SCALE := 0.667

## Context menu view — its own scene in MainFrame's row-4 right cell. Mirrors Qud's bottom missile-weapon
## area (the mod's `context` block): each equipped missile weapon as its recoloured tile + coloured name
## + ammo (remaining/total), then the actions with their Qud hotkeys ("[F] fire   [R] reload").
## "No missile weapons equipped." when there are none. Actions are display-only for now.

## Emitted when the user clicks an action. Payload is either
##   {type:"command", command:"CmdFire"}  or  {type:"itemaction", item:<id>, command:"ReplaceSocketCell"}.
## MainFrame forwards it to the Holodeck's bridge.
signal command_requested(payload: Dictionary)

const DIM := "#8a8f9a"
const AMMO := "#ffd200"     # amber ammo count, like Qud's readout
const KEY := "#ffd200"      # hotkey letter — UI yellow
const LABEL := "#8fd3ff"    # action label — light blue

var _tiles: RefCounted     # shared tile recolouring for the weapon sprites (set in _ready)
var _rt: RichTextLabel
var _palette := {}
var _full := false         # perceived (default) vs full icon — driven by MainFrame's top-menu toggle
var _last_data := {}       # last snapshot, so a mode toggle re-renders without waiting for a new one

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
	_title.text = "Context menu"
	_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(_title)

	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true                # names carry Qud {{colour|...}} markup; sprites are inline images
	_rt.scroll_active = false                # everything fits on one row; never scroll the weapon out of view
	_rt.selection_enabled = false   # a selectable RTL grabs focus on click and the arrows stop
	_rt.focus_mode = Control.FOCUS_NONE   # reaching the player (the command-bar rule)
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rt.meta_clicked.connect(_on_meta)     # fire / reload / [?] are clickable [url] links
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs context + palette + tilesDir).
## 1:1: drop the rounded QoL box so the continuous bottom-strip chrome shows through (Qud has no per-panel
## box). Keeps the content margins. User mode restores the framed look.
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
	if _title != null:
		_title.visible = not on   # Qud shows the context text with no "Context menu" heading
	var cur := get_theme_stylebox("panel")
	if cur is StyleBoxFlat:
		var f: StyleBoxFlat = (cur as StyleBoxFlat).duplicate()
		if on:
			f.bg_color = Color(0, 0, 0, 0)
			f.set_border_width_all(0)
			f.set_corner_radius_all(0)
			f.content_margin_top = 2
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
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_tiles.palette = _palette
	_render()

## Driven by MainFrame's global top-menu toggle: perceived icon (default) vs the real one.
func set_full_info(full: bool) -> void:
	_full = full
	if not _last_data.is_empty():
		_render()

func _render() -> void:
	var ctx: Dictionary = _last_data.get("context", {})
	_rt.clear()
	if String(ctx.get("kind", "none")) != "missile":
		_rt.append_text("[color=%s]%s[/color]" % [DIM, String(ctx.get("text", "—"))])
		return

	var acts: Array = ctx.get("actions", [])
	var weapons: Array = ctx.get("weapons", [])
	# Actions FIRST — matches Qud's horizontal "[F] fire  [R] reload …" and keeps them from being
	# dropped by any per-weapon render issue. Clickable; key = UI yellow, label = light blue.
	for a in acts:
		var key := String(a.get("key", ""))
		var aname := String(a.get("name", ""))
		var cmd := String(a.get("command", ""))
		var keytag := ""
		if key != "":
			keytag = "[color=%s][lb]%s][/color]" % [KEY, key]
		_rt.append_text("[url=cmd:%s]%s [color=%s]%s[/color][/url]    " % [cmd, keytag, LABEL, aname])

	# Then the weapon(s) INLINE on the same row (Qud-style: "… fire  reload  <sprite> name [?]"). One
	# row, so it can't be scrolled/clipped out of the panel. Perceived icon by default, real in full mode.
	var img_h := int(UiFont.px(get_viewport(), "body") * 2.2)
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	for w in weapons:
		var tex: Texture2D = _tiles.texture_for(w, _full)
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(_tiles.glyph_for(w, _full).replace("[", "[lb]"))
		_rt.append_text(" " + QudText.to_bbcode(String(w.get("name", "")), _palette))
		var total := int(w.get("ammoTotal", 0))
		if total > 0:
			_rt.append_text("   [color=%s]%d/%d[/color]" % [AMMO, int(w.get("ammoRemaining", 0)), total])
		if bool(w.get("canReplaceCell", false)):
			# "[?]" — click to change this weapon's energy cell (ReplaceSocketCell).
			_rt.append_text("   [url=cell:%s][color=%s][lb]?][/color][/url]" % [String(w.get("id", "")), KEY])
		_rt.append_text("    ")   # gap before the next weapon (rare) / trailing padding

## A fire/reload/[?] link was clicked — decode its meta and ask MainFrame to send it to Qud.
func _on_meta(meta: Variant) -> void:
	var s := String(meta)
	if s.begins_with("cmd:"):
		var c := s.substr(4)
		if c != "":
			command_requested.emit({"type": "command", "command": c})
	elif s.begins_with("cell:"):
		command_requested.emit({"type": "itemaction", "item": s.substr(5), "command": "ReplaceSocketCell"})

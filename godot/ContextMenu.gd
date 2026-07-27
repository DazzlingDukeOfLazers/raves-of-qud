extends PanelContainer

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
var _last_shape := ""      # last (actions,weapons) counts — logged only on change, to catch a dropped row

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
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
	_rt.bbcode_enabled = true                # names carry Qud {{colour|...}} markup; sprites are inline images
	_rt.scroll_active = true
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rt.meta_clicked.connect(_on_meta)     # fire / reload / [?] are clickable [url] links
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs context + palette + tilesDir).
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_tiles.palette = _palette
	var ctx: Dictionary = data.get("context", {})

	_rt.clear()
	if String(ctx.get("kind", "none")) != "missile":
		_rt.append_text("[color=%s]%s[/color]" % [DIM, String(ctx.get("text", "—"))])
		return

	var acts: Array = ctx.get("actions", [])
	var weapons: Array = ctx.get("weapons", [])
	# Diagnostic, logged only when the shape changes (no per-frame spam): the actions row should persist
	# whenever a weapon is present. actions=0 with weapons>0 would mean the mod dropped them.
	var shape := "%d,%d" % [acts.size(), weapons.size()]
	if shape != _last_shape:
		_last_shape = shape
		print("[context] missile: actions=%d weapons=%d" % [acts.size(), weapons.size()])

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

	# Then each weapon on its own line: recoloured tile (Qud draws it fairly large) + name + ammo + "[?]".
	var img_h := int(UiFont.px(get_viewport(), "body") * 2.2)
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	for w in weapons:
		_rt.append_text("\n")
		var tex: Texture2D = _tiles.texture(String(w.get("tile", "")), _tiles.main_color(w), _tiles.detail_color(w))
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(String(w.get("glyph", "")).replace("[", "[lb]"))
		_rt.append_text(" " + QudText.to_bbcode(String(w.get("name", "")), _palette))
		var total := int(w.get("ammoTotal", 0))
		if total > 0:
			_rt.append_text("   [color=%s]%d/%d[/color]" % [AMMO, int(w.get("ammoRemaining", 0)), total])
		if bool(w.get("canReplaceCell", false)):
			# "[?]" — click to change this weapon's energy cell (ReplaceSocketCell).
			_rt.append_text("   [url=cell:%s][color=%s][lb]?][/color][/url]" % [String(w.get("id", "")), KEY])

## A fire/reload/[?] link was clicked — decode its meta and ask MainFrame to send it to Qud.
func _on_meta(meta: Variant) -> void:
	var s := String(meta)
	if s.begins_with("cmd:"):
		var c := s.substr(4)
		if c != "":
			command_requested.emit({"type": "command", "command": c})
	elif s.begins_with("cell:"):
		command_requested.emit({"type": "itemaction", "item": s.substr(5), "command": "ReplaceSocketCell"})

extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column. Computed CLIENT-SIDE from the
## snapshot's cells + player position: the objects within RADIUS, deduped by display name, showing the
## NEAREST one's arrow direction, its TILE image (tinted by its colour), and a count. Sorted nearest.
##
## NOTE: the whole-zone scan (RADIUS = zone size) is the basis for the future Points of Interest menu.

const MAX_ROWS := 25
const RADIUS := 1   # king-move radius; 1 = the 3x3 (9 tiles) around the player

var _rt: RichTextLabel
var _tiles_dir := ""
var _palette := {}
var _tex_cache := {}   # tile filename -> Texture2D

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
	title.text = "Nearby objects"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = false
	_rt.scroll_active = true
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs cells + player + tilesDir + palette).
func set_snapshot(data: Dictionary) -> void:
	_tiles_dir = String(data.get("tilesDir", _tiles_dir))
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return

	var found := {}   # display name -> {arrow, glyph, tile, color, dist, count}
	for cell in data.get("cells", []):
		var dx := int(cell.get("x", 0)) - px
		var dy := int(cell.get("y", 0)) - py
		var dist: int = maxi(absi(dx), absi(dy))
		if dist > RADIUS:
			continue
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue
			if dist == 0 and bool(obj.get("creature", false)):
				continue                   # the player, on their own cell
			var nm := String(obj.get("display", ""))
			if nm == "":
				nm = String(obj.get("name", ""))
			if nm == "" or nm == "[painted ground]":
				continue
			if found.has(nm):
				found[nm]["count"] += 1
				if dist < found[nm]["dist"]:
					found[nm]["dist"] = dist
					found[nm]["arrow"] = _arrow(dx, dy)
			else:
				found[nm] = {
					"arrow": _arrow(dx, dy), "glyph": String(obj.get("glyph", "")),
					"tile": String(obj.get("tile", "")), "color": _obj_color(obj),
					"dist": dist, "count": 1,
				}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])

	var img_h := UiFont.px(get_viewport(), "body")
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	_rt.clear()
	for i in mini(names.size(), MAX_ROWS):
		var e: Dictionary = found[names[i]]
		_rt.add_text(String(e["arrow"]) + " ")
		var tex: Texture2D = _load_tile(String(e["tile"]))
		if tex != null:
			_rt.add_image(tex, img_w, img_h, e["color"])
		else:
			_rt.add_text(String(e["glyph"]))   # fallback when the tile isn't exported
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		_rt.add_text(" " + String(names[i]) + suffix + "\n")

## Load a tile mask PNG (they're PNG despite the .bmp name) from tilesDir, tinted at draw time by the
## caller. Cached; only successful loads are cached so an export-race miss can appear next snapshot.
func _load_tile(tile: String) -> Texture2D:
	if tile == "" or _tiles_dir == "":
		return null
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	if _tex_cache.has(fname):
		return _tex_cache[fname]
	var path := _tiles_dir.path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[fname] = tex
	return tex

## The object's foreground colour: the resolved fgHex if painted, else the &X code via the palette.
func _obj_color(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	var code := String(obj.get("tilecolor", ""))
	if code == "":
		code = String(obj.get("color", ""))
	return _qud_color(code)

func _qud_color(code: String) -> Color:
	if code == "":
		return Color.WHITE
	var fg := ""
	var amp := code.find("&")
	if amp >= 0 and amp + 1 < code.length():
		fg = code[amp + 1]
	else:
		fg = code[0]
	if _palette.has(fg):
		return Color(String(_palette[fg]))
	return Color.WHITE

## Compass ARROW from a cell offset (y increases SOUTH). Within RADIUS 1 this is exactly the 8
## neighbours plus the centre.
func _arrow(dx: int, dy: int) -> String:
	if dx == 0 and dy == 0:
		return "·"
	if dx == 0:
		return "↑" if dy < 0 else "↓"
	if dy == 0:
		return "→" if dx > 0 else "←"
	if dx > 0:
		return "↗" if dy < 0 else "↘"
	return "↖" if dy < 0 else "↙"

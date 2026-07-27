extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column. Computed CLIENT-SIDE from the
## snapshot's cells + player position: objects within RADIUS, deduped by (stripped) display name,
## showing the NEAREST one's arrow direction, its recoloured TILE image, and a count. Sorted nearest.
##
## NOTE: the whole-zone scan (RADIUS = zone size) is the basis for the future Points of Interest menu.

const MAX_ROWS := 25
const RADIUS := 1   # king-move radius; 1 = the 3x3 (9 tiles) around the player

# Fallback colour table (mirrors ZoneRenderer.COLORS) for when the mod's palette lacks a code.
const COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),
}

var _rt: RichTextLabel
var _tiles_dir := ""
var _palette := {}
var _mask_cache := {}   # tile filename -> Image (the raw grayscale mask)
var _tex_cache := {}    # "fname|main|detail" -> ImageTexture (recoloured)

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
	_rt.bbcode_enabled = true             # names are rendered in their Qud colours
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

	var found := {}   # display name -> {arrow, glyph, tile, main, detail, dist, count}
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
			var raw := String(obj.get("display", ""))
			var nm := QudText.strip(raw)      # stripped = stable dedup key
			if nm == "":
				nm = String(obj.get("name", ""))
				raw = nm
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
					"tile": String(obj.get("tile", "")), "raw": raw,
					"main": _obj_main(obj), "detail": _obj_detail(obj),
					"dist": dist, "count": 1,
				}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])

	var img_h := UiFont.px(get_viewport(), "body")
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	_rt.clear()
	for i in mini(names.size(), MAX_ROWS):
		var e: Dictionary = found[names[i]]
		_rt.append_text(String(e["arrow"]) + " ")
		var tex: Texture2D = _tile_tex(String(e["tile"]), e["main"], e["detail"])
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(String(e["glyph"]).replace("[", "[lb]"))   # fallback glyph
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		_rt.append_text(" " + QudText.to_bbcode(String(e["raw"]), _palette) + suffix + "\n")

# --- tile recolouring (mirrors ZoneRenderer: grayscale mask -> main.lerp(detail, luminance)) --------

func _tile_tex(tile: String, main: Color, detail: Color) -> Texture2D:
	if tile == "":
		return null
	var fname := tile.replace("/", "_").replace("\\", "_").replace(":", "_")
	var key := "%s|%s|%s" % [fname, main.to_html(), detail.to_html()]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var mask := _mask(fname)
	if mask == null:
		return null
	var w := mask.get_width()
	var h := mask.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var pix := mask.get_pixel(x, y)
			if pix.a < 0.5:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				var lum := (pix.r + pix.g + pix.b) / 3.0
				var c := main.lerp(detail, lum)
				img.set_pixel(x, y, Color(c.r, c.g, c.b, pix.a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex

func _mask(fname: String) -> Image:
	if _mask_cache.has(fname):
		return _mask_cache[fname]
	if _tiles_dir == "":
		return null
	var path := _tiles_dir.path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mask_cache[fname] = img
	return img

# --- colour resolution (mirrors ZoneRenderer._obj_main/_obj_detail/_qud_color) ----------------------

func _obj_main(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	var c := String(obj.get("tilecolor", ""))
	if c == "":
		c = String(obj.get("color", ""))
	return _qud_color(c)

func _obj_detail(obj: Dictionary) -> Color:
	var hex := String(obj.get("detailHex", ""))
	if hex != "":
		return Color(hex)
	return _qud_color(String(obj.get("detail", "")))

func _qud_color(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return Color.WHITE
	if _palette.has(ch):
		return Color(String(_palette[ch]))
	return COLORS.get(ch, Color.WHITE)

## Foreground letter of a Qud colour code: drop the ^background half and the &, take the last char.
func _fg_letter(code: String) -> String:
	var c := code.strip_edges()
	var caret := c.find("^")
	if caret >= 0:
		c = c.substr(0, caret)
	c = c.replace("&", "")
	if c.is_empty():
		return ""
	return c.substr(c.length() - 1, 1)

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

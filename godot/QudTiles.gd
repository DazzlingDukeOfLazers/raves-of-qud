extends RefCounted

## Shared Qud tile recolouring + colour resolution, so views don't each re-inline it. Exported tiles are
## GRAYSCALE MASKS; recolour per pixel via main.lerp(detail, luminance), mirroring ZoneRenderer._recolor_rgb.
## Colours resolve from an object's fgHex/tilecolor/color (+ the snapshot palette, else the COLORS
## fallback). Create one per view (`load("res://QudTiles.gd").new()`); the caches are per-instance.
##
## (NearbyObjects still inlines the same logic; it can migrate onto this later.)

# Fallback colour table (mirrors ZoneRenderer.COLORS) for when the palette lacks a code.
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

var tiles_dir := ""
var palette := {}
var _mask_cache := {}   # fname -> Image (raw grayscale mask)
var _tex_cache := {}    # "fname|main|detail" -> ImageTexture (recoloured)

## Recoloured tile texture for a tile path + main/detail colours, or null if there's no tile/mask.
func texture(tile: String, main: Color, detail: Color) -> Texture2D:
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
	if _tex_cache.size() > 96:
		_tex_cache.clear()   # bound GPU memory: painted colours shift with lighting, so keys accumulate
	_tex_cache[key] = tex
	return tex

func _mask(fname: String) -> Image:
	if _mask_cache.has(fname):
		return _mask_cache[fname]
	if tiles_dir == "":
		return null
	var path := tiles_dir.path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:   # exported tiles are PNG despite the .bmp name
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mask_cache[fname] = img
	return img

## Main (foreground) colour of a serialized object/tile dict.
func main_color(obj: Dictionary) -> Color:
	var hex := String(obj.get("fgHex", ""))
	if hex != "":
		return Color(hex)
	var c := String(obj.get("tilecolor", ""))
	if c == "":
		c = String(obj.get("color", ""))
	return color_of(c)

## Detail (secondary) colour of a serialized object/tile dict.
func detail_color(obj: Dictionary) -> Color:
	var hex := String(obj.get("detailHex", ""))
	if hex != "":
		return Color(hex)
	return color_of(String(obj.get("detail", "")))

func color_of(code: String) -> Color:
	var ch := _fg_letter(code)
	if ch == "":
		return Color.WHITE
	if palette.has(ch):
		return Color(String(palette[ch]))
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

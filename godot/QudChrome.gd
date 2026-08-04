class_name QudChrome
extends RefCounted

## Shared 1:1 colour pipeline helpers.
##
## Raves' 2D canvas renders mid-tones ~×0.885 darker than the specified colour (a
## pipeline gamma the 3D playfield never showed — its colours were tuned empirically
## against captures and absorbed the transform; discovered on the Records screen).
## Everything that draws MEASURED-FROM-QUD colours or Qud-extracted sprites must
## pre-compensate so the CAPTURED pixels land back on Qud's values.

## Compensate one 0-255 channel. Channels ≤20 render ~faithfully already (the
## pipeline's curve flattens near black); scaling them overshoots.
static func qch(v: int) -> int:
	return v if v <= 20 else mini(255, int(round(v * 1.13)))


## Compensated colour from 8-bit components.
static func q8(r8: int, g8: int, b8: int) -> Color:
	return Color8(qch(r8), qch(g8), qch(b8))


## Compensated copy of an existing colour (alpha preserved).
static func q(c: Color) -> Color:
	var out := Color8(qch(c.r8), qch(c.g8), qch(c.b8))
	out.a = c.a
	return out


## Brighten an extracted-sprite image in place so its Qud-native pixels survive the
## canvas transform (tiles, pictographs, frames, title art). Alpha untouched.
static func brighten(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			var out := Color8(qch(c.r8), qch(c.g8), qch(c.b8))
			out.a = c.a
			img.set_pixel(x, y, out)
	return img

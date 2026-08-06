class_name QudChrome
extends RefCounted

## Shared 1:1 colour pipeline helpers.
##
## Raves' 2D canvas renders mid-tones ~×0.885 darker than the specified colour (a
## pipeline gamma the 3D playfield never showed — its colours were tuned empirically
## against captures and absorbed the transform; discovered on the Records screen).
## Everything that draws MEASURED-FROM-QUD colours or Qud-extracted sprites must
## pre-compensate so the CAPTURED pixels land back on Qud's values.

## MEASURED, not modelled. The canvas transform is one curve shared by all three channels (checked
## per-channel: R, G and B ramps rendered identically), and it is not a gain: it SAGS in the middle
## and LIFTS near black -- 96 renders 85, while 8 renders 10. A single ×1.13 above 20 was exact
## around 68 and 3 out by 111, which is where the status rules' residual came from.
##
## INV[target] is the value to DRAW so the captured pixel lands on `target`. It round-trips every one
## of the 256 targets to within 0.5.
##
## TO RE-MEASURE (do this if the CRT pass or the canvas setup changes): draw a grey ramp through
## THIS pipeline -- 64 swatches of Color8(v,v,v) for v in 0,4,..252, via draw_rect on the status
## screens' frame -- capture the window with `hv shot raves`, read the dominant colour of each
## swatch to get forward(in)->out, then invert it by linear interpolation. Two things that matter:
## sample the swatch INTERIOR (the CRT pass dirties edges), and check all three channels once --
## they were identical here, so one table serves.
const INV := [
	  0,   1,   2,   2,   3,   4,   5,   6,   6,   7,   8,   9,  10,  10,  11,  12,
	 14,  16,  17,  19,  20,  21,  23,  24,  25,  27,  28,  29,  31,  32,  33,  34,
	 35,  36,  37,  39,  40,  41,  43,  44,  45,  47,  48,  49,  50,  51,  52,  53,
	 55,  56,  57,  58,  59,  60,  61,  63,  64,  65,  66,  67,  68,  69,  71,  72,
	 73,  74,  75,  76,  77,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,
	 90,  91,  92,  93,  95,  96,  97,  98,  99, 100, 101, 102, 103, 104, 105, 106,
	107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122,
	123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138,
	139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154,
	155, 156, 157, 158, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169,
	170, 171, 172, 173, 174, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184,
	185, 186, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 198,
	199, 200, 201, 202, 203, 204, 205, 206, 206, 207, 208, 209, 210, 211, 212, 213,
	214, 214, 215, 216, 217, 218, 219, 220, 221, 222, 222, 223, 224, 225, 226, 227,
	228, 229, 230, 231, 232, 233, 234, 234, 235, 236, 237, 238, 238, 239, 240, 241,
	242, 243, 244, 245, 246, 246, 247, 248, 249, 250, 250, 251, 252, 253, 254, 255,
]

static func qch(v: int) -> int:
	return INV[clampi(v, 0, 255)]


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

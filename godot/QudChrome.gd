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

## ---------------------------------------------------------------------- the popup emblem
##
## Qud's tree emblem — the glyph it draws ABOVE a popup box, and the same art the chargen
## header carries (byte-identical 434-pixel mask, checked against `chargen_emblem.png`).
## Raves drew nothing there at all.
##
## ONE COPY FOR THE WHOLE APP. This is a shared accessor rather than a per-screen loader on
## purpose: the emblem shows up on more than one 1:1 screen, and `nav_icon` above records what
## happens otherwise — seven screens grew seven copies of the same glyph and they drifted.
## Decoded once, cached in a static, handed out by reference.
##
## THE SOURCE is Qud's own `polat-frame-top`, extracted off the LIVE popup by the mod
## (`hv bridge popupchrome` → `mod/PopupBridge.ExportChrome`). First-party pixels from the
## player's install, never redistributed and never redrawn by hand.
##
## WHAT IS CARVED OUT OF IT, and why it is not the whole sprite: `polat-frame-top` is 183x60
## and Qud draws it at the top of `PolatFrame`, but the extracted region is a SUPERSET of what
## Unity renders — a wide (60,96,103) band across its middle rows is in the PNG and provably
## absent from Qud's screen (measured against a live capture: outside the glyph, Qud and Raves
## differ nowhere in those rows). So the glyph is taken by its own tone, which is the one thing
## in the sprite that IS on screen, and the rest is dropped.
static var _emblem: Texture2D = null
static var _emblem_tried := false

## The sprite as Qud lays it out: 183x60, centred on the popup box, its BOTTOM on the box top.
const EMBLEM_W := 183
const EMBLEM_H := 60
## The glyph's flat tone in the extracted PNG. It is also exactly `q8(68,99,111)` — the value
## this pipeline says to DRAW so the captured pixel lands on Qud's rendered (68,99,111) — so the
## extracted pixels are already in pre-compensated space and must NOT be run through
## `brighten()` a second time. Verified by round-trip, not assumed.
const EMBLEM_TONE := Color8(77, 110, 122)
## The glyph's own size, and where it sits inside that 183x60 topping frame.
const EMBLEM_GLYPH_W := 40
const EMBLEM_GLYPH_H := 45
const EMBLEM_IN_TOPPING := Vector2(71, 0)
## WHY QUD'S POPUP INKS 39 COLUMNS AND ITS CHARGEN SCREEN INKS 40, off the SAME 40-column glyph.
## Measured on Qud itself: the item popup draws x940..978, 453 px (reports/2026-08-05-item-popup);
## Choose Caste draws x940..979, 434 px. Two different pixel counts cannot come from two blits of
## one bitmap at whole-pixel offsets -- but they come straight out of a HALF-pixel one. Qud centres
## the topping on the popup box at x=868.5 (see PopupOverlay._draw_emblem), and a nearest-sampled
## blit off a half pixel duplicates some columns and drops others, which both narrows the inked
## span and changes the count. Chargen centres on the screen and lands whole.
##
## So it is ONE piece of artwork rendered at two subpixel origins, NOT two crowns. The old carve
## read that artifact as a property of the sprite and baked a 1-column clip into the asset; the
## artifact belongs to the placement, and each surface now reproduces its own.


## THE CROWN — the sheaf glyph Qud hangs over its popups and its character-creation screens.
##
## ONE SOURCE, because there were THREE and they disagreed. The popup carved its own copy out of
## `polat-frame-top.png` (tone-matched, then trimmed by two hand-measured fudge constants); chargen
## loaded a separate `chargen_emblem.png`; and when nothing was extracted yet, chargen drew a
## hand-coded Bresenham approximation that was simply a different picture. Daniel filed both ends of
## that: an "incorrect crown" on a popup, and the chargen one as "the crown image" to copy — "fix it
## once and reuse it everywhere".
##
## `chargen_emblem.png` IS the one that is right, and not by preference: measured against Qud's own
## Choose Caste screen it is PIXEL-IDENTICAL — 40x45, 434 px at the rendered tone, bbox and every
## pixel matching, zero differences. The polat carve missed by 50 px (1px shifts through the stem
## and the right-hand roots), which is why it needed fudge constants to look close.
##
## Returned in the GLYPH'S OWN 40x45 frame. Callers place it with `EMBLEM_IN_TOPPING` when they are
## working in Qud's 183x60 topping frame (the popup) or centre it directly (chargen). Null until the
## sprite has been extracted — callers draw NOTHING rather than invent artwork.
static func emblem() -> Texture2D:
	if _emblem_tried:
		return _emblem
	_emblem_tried = true
	var path := InputModel.support_dir().path_join("title").path_join("chargen_emblem.png")
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	if img.get_width() != EMBLEM_GLYPH_W or img.get_height() != EMBLEM_GLYPH_H:
		return null                      # not the sprite we measured; draw nothing over a guess
	_emblem = ImageTexture.create_from_image(img)
	return _emblem


## THE navigation-keys icon — the inverted-T d-pad Qud puts in its hint bars ("[⊞] navigate").
##
## ONE source, because there were SEVEN. Every screen that needed it grew its own copy, and they
## drifted: only MainMenu and LoadGameScreen etched the cardinal arrows at all, and those two used
## different etch colours, while ChargenCard / ControlMapping / Options / Records / StatusScreens
## drew bare squares. Daniel filed it off the status screens' bar — "it's supposed to have cardinal
## arrows … derive it from a common source."
##
## Qud's own glyph (measured off its Load Game hint bar): four gold keys, up on the top centre and
## left/down/right beneath, each carrying a DARK triangular arrow pointing its own way. The etch is
## a colour rather than a cutout on purpose — Qud bakes the dark into the glyph, so it reads the
## same over the title artwork as over the near-black chrome.
static func nav_icon(ih: int, key := Color8(200, 184, 57), etch := Color8(20, 34, 34)) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))          # gap between keys
	var k := maxi(2, int((ih - g) / 2.0))            # one key, two rows tall overall
	var img := Image.create(3 * k + 2 * g, 2 * k + g, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g                                  # x of the centre column
	img.fill_rect(Rect2i(mid, 0, k, k), key)          # up
	img.fill_rect(Rect2i(0, k + g, k, k), key)        # left
	img.fill_rect(Rect2i(mid, k + g, k, k), key)      # down
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), key)  # right
	# the arrows: a triangle growing from each key's pointing edge
	var ctr := int(k / 2.0)
	for i in range(maxi(1, int(k / 3.0))):
		var w2 := 1 + 2 * i
		var x0 := ctr - i
		img.fill_rect(Rect2i(mid + x0, 1 + i, w2, 1), etch)                  # up
		img.fill_rect(Rect2i(mid + x0, k + g + k - 2 - i, w2, 1), etch)      # down
		img.fill_rect(Rect2i(1 + i, k + g + x0, 1, w2), etch)                # left
		img.fill_rect(Rect2i(2 * mid + k - 2 - i, k + g + x0, 1, w2), etch)  # right
	return ImageTexture.create_from_image(img)

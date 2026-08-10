extends RefCounted

## Qud's FILTER BAR cell, in one place.
##
## `Qud.UI.FilterBarCategoryButton` is one prefab used by more than one screen: the inventory's
## category filter strip and the journal's category carousel are the same 46x41 button at the same
## 58px pitch, with the same `polat-category-frame` background, the same 20x30 icon slot and the
## same [Q]/[E] paging badges either side. Only the meaning differs — the inventory's cells are
## multi-select filters, the journal's are a single-select carousel.
##
## StatusPaneInventory measured all of that first and drew it inline; this file is that drawing
## lifted out so the journal gets the same pixels instead of a second, drifting copy. The pane
## keeps its own colours and hit-testing — this owns the SPRITE and the geometry only.

## Cell metrics, measured off the live buttons on both screens (they agree).
const CELL_W := 46.0
const CELL_H := 41.0      # cell rows 177..217
const CELL_PITCH := 58.0  # 46 + a 12px gap
const CELL_Y := 177.0
## The icon slot. GROUND TRUTH off a live button rather than fitted to sample bboxes:
## `icon`'s RectTransform is 20x30, centred (anchors and pivot all 0.5), preserveAspect FALSE,
## type Simple, over a 16x24 sprite — so Qud stretches the WHOLE tile 1.25x and never looks at
## the opaque sub-rect. Normalising to the opaque box makes small art too big and wide art too
## narrow, which cost three attempts on the inventory strip.
const ICON := Vector2(20, 30)
## The paging badge either side of the strip.
const BADGE := Vector2(20, 27)
const BADGE_Y := 184.0
const BADGE_GAP := 8.0    # Qud's "8px Spacer" between badge and container

## The two tones `SetCategory` hands the icon (`icon.SetColors(...)`), fixed for every category —
## the tile's own colours are NOT used here, which is why every cell in the strip is the same brass.
const ICON_MAIN := Color(0.596, 0.529, 0.372)
const ICON_DETAIL := Color(0.545, 0.4, 0.18)

## Qud's OWN frame sprite, nine-sliced. The mod exports `polat-category-frame` (46x41, Unity
## 9-slice borders l12 b11 r13 t12) to title/cell_frame.png, so the corners are Qud's pixels and
## only the middles stretch — which is how one design serves both the 46x41 cells and the 55x62
## paper-doll slots. Falls back to a hand-drawn box if the sprite has not been exported yet.
const FRAME_BORDER := {"left": 12, "bottom": 11, "right": 13, "top": 12}

var _frame_tex: Texture2D = null
var _frame_tried := false

func frame_texture() -> Texture2D:
	if _frame_tried:
		return _frame_tex
	_frame_tried = true
	var path := InputModel.support_dir().path_join("title").path_join("cell_frame.png")
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == 0:
			_frame_tex = ImageTexture.create_from_image(QudChrome.brighten(img))
	return _frame_tex

## Where the whole run starts, for `n` cells centred on `centre`: badge, gap, cells, gap, badge.
## Qud lays the bar out with a HorizontalLayoutGroup, so the answer is the group's own arithmetic
## rather than a measured constant — and it has to be, because the journal's 7 cells and the
## inventory's variable count cannot share one.
static func run_left(n: int, centre: float) -> float:
	return centre - run_width(n) * 0.5

static func run_width(n: int) -> float:
	return BADGE.x * 2.0 + BADGE_GAP * 2.0 + cells_width(n)

static func cells_width(n: int) -> float:
	return 0.0 if n <= 0 else float(n) * CELL_W + float(n - 1) * (CELL_PITCH - CELL_W)

## The cell rect for index `i` in a strip whose first cell starts at `x0`.
static func cell_rect(x0: float, i: int, y := CELL_Y) -> Rect2:
	return Rect2(x0 + float(i) * CELL_PITCH, y, CELL_W, CELL_H)

## The 20x30 icon box, centred in a cell.
static func icon_rect(cell: Rect2) -> Rect2:
	return Rect2(cell.position + (cell.size - ICON) * 0.5, ICON)

## Draw one cell's frame into `ci`, tinted `col`.
##
## `knob` is the stub hanging off the bottom line. It is NOT part of the sprite (the alpha mask
## has nothing there) — Qud paints it over the frame, and only on these category cells; the
## paper-doll boxes use the same sprite without one. Qud's own is an 8x8 punch-out in the panel
## black with a 4x4 tone inside it, at cell-relative (19,36.3) and (21,38.3); pass `knob_bg`
## transparent and `knob_size` (4,3) for the inventory strip's older, thinner approximation of
## the same stub, which is what that pane has been shipping.
func cell(ci: CanvasItem, r: Rect2, col: Color, knob_col: Color, knob := true,
		knob_bg := Color(0, 0, 0, 0), knob_size := Vector2(4, 4)) -> void:
	if knob:
		if knob_bg.a > 0.0:
			ci.draw_rect(Rect2(r.position + Vector2(19, 36.3), Vector2(8, 8)), knob_bg)
		ci.draw_rect(Rect2(r.position + Vector2(21, 38.3), knob_size), knob_col)
	var tex := frame_texture()
	if tex == null:
		_fallback(ci, r, col)
		return
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	var l: float = FRAME_BORDER["left"]
	var rr: float = FRAME_BORDER["right"]
	var t: float = FRAME_BORDER["top"]
	var bo: float = FRAME_BORDER["bottom"]
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	var mid_w := maxf(0.0, w - l - rr)
	var mid_h := maxf(0.0, h - t - bo)
	var src_mid_w := maxf(1.0, tw - l - rr)
	var src_mid_h := maxf(1.0, th - t - bo)
	# corners, 1:1
	ci.draw_texture_rect_region(tex, Rect2(x, y, l, t), Rect2(0, 0, l, t), col)
	ci.draw_texture_rect_region(tex, Rect2(x + w - rr, y, rr, t), Rect2(tw - rr, 0, rr, t), col)
	ci.draw_texture_rect_region(tex, Rect2(x, y + h - bo, l, bo), Rect2(0, th - bo, l, bo), col)
	ci.draw_texture_rect_region(tex, Rect2(x + w - rr, y + h - bo, rr, bo),
		Rect2(tw - rr, th - bo, rr, bo), col)
	# edges — THESE are the runs that stretch
	ci.draw_texture_rect_region(tex, Rect2(x + l, y, mid_w, t), Rect2(l, 0, src_mid_w, t), col)
	ci.draw_texture_rect_region(tex, Rect2(x + l, y + h - bo, mid_w, bo),
		Rect2(l, th - bo, src_mid_w, bo), col)
	ci.draw_texture_rect_region(tex, Rect2(x, y + t, l, mid_h), Rect2(0, t, l, src_mid_h), col)
	ci.draw_texture_rect_region(tex, Rect2(x + w - rr, y + t, rr, mid_h),
		Rect2(tw - rr, t, rr, src_mid_h), col)

func _fallback(ci: CanvasItem, r: Rect2, col: Color) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	ci.draw_rect(Rect2(x, y, w, 2), col)
	ci.draw_rect(Rect2(x, y + h - 2, w, 2), col)
	ci.draw_rect(Rect2(x, y, 2, h), col)
	ci.draw_rect(Rect2(x + w - 2, y, 2, h), col)

## One of the strip's paging hotkey badges: a filled teal box with a green letter. Qud's own is a
## 1px border over a darker interior, but the interior is only 2px in from a 20x27 box and both
## tones grade to within a few units of each other on screen — a sample of the live badge is 469
## of its 540 pixels in one colour, so a flat fill is what it actually looks like.
func badge(ci: CanvasItem, font: Font, x: float, letter: String, box_col: Color,
		letter_col: Color, y := BADGE_Y) -> void:
	ci.draw_rect(Rect2(Vector2(x, y), BADGE), box_col)
	var lw := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	ci.draw_string(font, Vector2(x + (BADGE.x - lw) * 0.5, y + 21), letter,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, letter_col)

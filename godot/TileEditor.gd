extends Node

## A 16x24 pixel paint editor inside the feedback flow (Daniel, 2026-08-13: "Let's
## build a 16x24 paint program inside the feedback. Include the Qud palette.").
##
## Opened from TileReport's "Edit art" button for the selected tile. Left: the paint
## canvas on a checkered ground (transparent pixels read as checker). Right: the Qud
## palette (the renderer's live letter->colour map, the same one sprites recolour
## with) plus an eraser swatch, and TWO live previews of the working sprite — one
## over the Qud default background colour, one over checker — per the request:
## "There should be 2 examples, one with a Qud-background and one with a checkered
## background." Save writes tiles_custom/<flattened-name>; the renderer hot-reloads
## it (mtime-keyed caches + directory watch), so the game shows the edit at once.
## Revert deletes the custom file, restoring Qud's art. Mouse-only: no text fields,
## every control FOCUS_NONE (the movement-arrows rule).

const CELL := 32          # canvas pixels per art pixel (doubled 2026-08-13: "same pixel size, just bigger")
const ART_W := 16
const ART_H := 24
const QUD_BG := Color8(17, 33, 38)   # the measured letterbox/cell background

var _renderer: ZoneRenderer
var _panel: PanelContainer
var _canvas: Control
var _palette_ctl: Control
var _preview_qud: TextureRect
var _preview_alpha: TextureRect
var _status: Label
var _drop_btn: Button
var _img: Image
var _tile := ""
var _colors := []          # [[letter, Color], ...] in palette order
var _sel := 0              # selected swatch index; -1 = eraser; -2 = picked colour
var _picked := Color.WHITE # the eyedropped colour when _sel == -2
var _dropper := false      # next canvas click picks instead of painting
var _painting := false
var _dirty := false
var _obj := {}             # the inspected object (colours for the recoloured base)
var _undo := []            # stroke-level snapshots (Image), newest last

const LETTERS := ["r", "R", "o", "O", "w", "W", "y", "Y", "g", "G",
	"b", "B", "c", "C", "m", "M", "k", "K"]

func setup(renderer: ZoneRenderer, host: CanvasLayer) -> void:
	_renderer = renderer
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.position = Vector2(60, 90)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.04, 0.97)
	style.border_color = Color(0.45, 0.85, 0.55, 0.9)
	style.set_border_width_all(1)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	host.add_child(_panel)
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	_panel.add_child(root)
	# the paint canvas
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(ART_W * CELL, ART_H * CELL)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_canvas_input)
	root.add_child(_canvas)
	# right column: palette, previews, buttons
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	root.add_child(col)
	var title := Label.new()
	title.text = "Tile paint (16x24)"
	col.add_child(title)
	_palette_ctl = Control.new()
	_palette_ctl.custom_minimum_size = Vector2(6 * 26, 4 * 26)
	_palette_ctl.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette_ctl.draw.connect(_draw_palette)
	_palette_ctl.gui_input.connect(_palette_input)
	col.add_child(_palette_ctl)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	col.add_child(prow)
	prow.add_child(_make_preview_box("qud bg", true))
	prow.add_child(_make_preview_box("alpha", false))
	_status = Label.new()
	_status.text = ""
	col.add_child(_status)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	col.add_child(tools)
	_drop_btn = _make_button("Eyedrop", _toggle_dropper)
	tools.add_child(_drop_btn)
	tools.add_child(_make_button("Undo", _undo_stroke))
	col.add_child(_make_button("Save -> game", _save))
	col.add_child(_make_button("Revert to Qud art", _revert))
	col.add_child(_make_button("Close", close))

func _make_button(text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b

func _make_preview_box(caption: String, qud_bg: bool) -> VBoxContainer:
	var box := VBoxContainer.new()
	var cap := Label.new()
	cap.text = caption
	box.add_child(cap)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(ART_W * 4, ART_H * 4)
	box.add_child(holder)
	if qud_bg:
		var bg := ColorRect.new()
		bg.color = QUD_BG
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		holder.add_child(bg)
	else:
		var ck := TextureRect.new()
		ck.texture = _checker_tex(ART_W * 4, ART_H * 4, 4)
		ck.set_anchors_preset(Control.PRESET_FULL_RECT)
		holder.add_child(ck)
	var tr := TextureRect.new()
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(tr)
	if qud_bg:
		_preview_qud = tr
	else:
		_preview_alpha = tr
	return box

func open(tile: String, obj := {}) -> void:
	if _renderer == null or tile == "":
		return
	_tile = tile
	_obj = obj
	_colors = []
	for ch in LETTERS:
		_colors.append([ch, _renderer.qud_palette_color(ch)])
	_sel = 0
	_dropper = false
	_undo = []
	# The editing base comes RECOLOURED through the renderer (custom art as-is, else
	# the mask painted with this object's colours) — loading the raw file showed the
	# black/white mask, which is what "it goes black and white" was.
	_img = null
	var im: Image = _renderer.tile_display_image(tile, obj)
	if im != null and im.get_width() == ART_W and im.get_height() == ART_H:
		im.convert(Image.FORMAT_RGBA8)
		_img = im
	if _img == null:
		_img = Image.create(ART_W, ART_H, false, Image.FORMAT_RGBA8)
	_dirty = false
	_status.text = _flat(tile)
	_panel.visible = true
	_refresh()

func close() -> void:
	_panel.visible = false

func is_open() -> bool:
	return _panel != null and _panel.visible

func _flat(tile: String) -> String:
	return tile.replace("/", "_").replace("\\", "_").replace(":", "_")

func _checker_tex(w: int, h: int, sq: int) -> ImageTexture:
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var on := (int(x / sq) + int(y / sq)) % 2 == 0
			im.set_pixel(x, y, Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	return ImageTexture.create_from_image(im)

# --- painting ---------------------------------------------------------------

func _draw_canvas() -> void:
	# checker ground so transparency reads while painting
	var sq := CELL / 2
	for y in ART_H * 2:
		for x in ART_W * 2:
			var on := (x + y) % 2 == 0
			_canvas.draw_rect(Rect2(x * sq, y * sq, sq, sq),
				Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	if _img != null:
		for y in ART_H:
			for x in ART_W:
				var c := _img.get_pixel(x, y)
				if c.a > 0.01:
					_canvas.draw_rect(Rect2(x * CELL, y * CELL, CELL, CELL), c)
	# grid lines
	for x in ART_W + 1:
		_canvas.draw_line(Vector2(x * CELL, 0), Vector2(x * CELL, ART_H * CELL), Color(0, 0, 0, 0.35))
	for y in ART_H + 1:
		_canvas.draw_line(Vector2(0, y * CELL), Vector2(ART_W * CELL, y * CELL), Color(0, 0, 0, 0.35))

func _canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_canvas.accept_event()
		if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			_pick_at(event.position)   # middle-click always eyedrops
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _dropper:
				_pick_at(event.position)
				_toggle_dropper()      # one pick per activation
				return
			_painting = event.pressed
			if event.pressed:
				_push_undo()
				_paint_at(event.position, false)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_push_undo()
			_paint_at(event.position, true)   # right-click always erases
	elif event is InputEventMouseMotion and _painting:
		_canvas.accept_event()
		_paint_at(event.position, false)

func _paint_at(pos: Vector2, erase: bool) -> void:
	var x := int(pos.x / CELL)
	var y := int(pos.y / CELL)
	if x < 0 or x >= ART_W or y < 0 or y >= ART_H or _img == null:
		return
	var c := Color(0, 0, 0, 0)
	if not erase:
		if _sel >= 0:
			c = _colors[_sel][1]
		elif _sel == -2:
			c = _picked
	_img.set_pixel(x, y, c)
	_dirty = true
	_refresh()

func _pick_at(pos: Vector2) -> void:
	var x := int(pos.x / CELL)
	var y := int(pos.y / CELL)
	if x < 0 or x >= ART_W or y < 0 or y >= ART_H or _img == null:
		return
	var c := _img.get_pixel(x, y)
	if c.a < 0.01:
		_sel = -1   # picking a transparent pixel selects the eraser
	else:
		_picked = c
		_sel = -2
	_refresh()

func _toggle_dropper() -> void:
	_dropper = not _dropper
	if _drop_btn != null:
		_drop_btn.text = "Eyedrop ON" if _dropper else "Eyedrop"

func _push_undo() -> void:
	if _img == null:
		return
	_undo.append(_img.duplicate())
	if _undo.size() > 40:
		_undo.pop_front()

func _undo_stroke() -> void:
	if _undo.is_empty():
		return
	_img = _undo.pop_back()
	_dirty = true
	_refresh()

# --- palette ----------------------------------------------------------------

const SW := 26   # swatch pitch (24px swatch + 2 gap)

func _draw_palette() -> void:
	for i in _colors.size():
		var r := _swatch_rect(i)
		_palette_ctl.draw_rect(r, _colors[i][1])
		if i == _sel:
			_palette_ctl.draw_rect(r.grow(1), Color.WHITE, false, 2.0)
	# eraser swatch: checkered
	var er := _swatch_rect(_colors.size())
	var sq := 6
	for yy in 4:
		for xx in 4:
			var on := (xx + yy) % 2 == 0
			_palette_ctl.draw_rect(Rect2(er.position + Vector2(xx * sq, yy * sq), Vector2(sq, sq)),
				Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	if _sel == -1:
		_palette_ctl.draw_rect(er.grow(1), Color.WHITE, false, 2.0)
	# the eyedropped colour, as a chip after the eraser
	if _sel == -2:
		var pr := _swatch_rect(_colors.size() + 1)
		_palette_ctl.draw_rect(pr, _picked)
		_palette_ctl.draw_rect(pr.grow(1), Color.WHITE, false, 2.0)

func _swatch_rect(i: int) -> Rect2:
	return Rect2(Vector2((i % 6) * SW, int(i / 6.0) * SW), Vector2(SW - 2, SW - 2))

func _palette_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_palette_ctl.accept_event()
		for i in _colors.size() + 1:
			if _swatch_rect(i).has_point(event.position):
				_sel = i if i < _colors.size() else -1
				_refresh()
				return

# --- previews / io ----------------------------------------------------------

func _refresh() -> void:
	if _img == null:
		return
	var tex := ImageTexture.create_from_image(_img)
	if _preview_qud != null:
		_preview_qud.texture = tex
	if _preview_alpha != null:
		_preview_alpha.texture = tex
	_canvas.queue_redraw()
	_palette_ctl.queue_redraw()

func _save() -> void:
	if _img == null or _tile == "" or _renderer == null:
		return
	var dir := _renderer.tiles_dir().get_base_dir().path_join("tiles_custom")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(_flat(_tile))
	if _img.save_png(path) == OK:
		_status.text = "saved -> %s" % _flat(_tile)
		_dirty = false
	else:
		_status.text = "SAVE FAILED"

func _revert() -> void:
	if _tile == "" or _renderer == null:
		return
	var path := _renderer.tiles_dir().get_base_dir().path_join("tiles_custom").path_join(_flat(_tile))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		open(_tile, _obj)   # reload the original, RECOLOURED (not the raw mask)
		_status.text = "custom art removed — Qud's art restored"

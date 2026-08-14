extends Node

## The WALL VOXEL editor (Daniel, 2026-08-13: "I think we need a voxel editor
## 16x16x24height. The ability to rotate the faces. A way to do corners. The
## ability to see how the tiling tiles. The ability to set the core color in
## addition to face/roof pixel colors.")
##
## Walls are one watertight voxel volume per cell whose ROOF and FACADE come
## from the tile art's two bands, with a CORE colour filling every carve
## (docs/rendering.md). This editor edits exactly that model, per autotile
## variant:
##   - ROOF canvas: the art's cap band, top-down; FACE canvas: the face band.
##     Qud walls carry ONE face elevation that all four sides wear, so painting
##     the face dresses every side. Transparent (eraser) = CARVE.
##   - variant hopping (prev/next) to edit corner/run/isolated variants — the
##     way to do corners;
##   - a live voxel PREVIEW drawn from the renderer's own volume rules
##     (wall_preview_arrangement — the same code the game meshes), rotatable in
##     90° steps, arrangements single / run / corner / block — how the tiling
##     tiles, with unsaved edits applied wherever the arrangement resolves to
##     the variant being edited;
##   - CORE colour: writes overrides.json tiles[<family>].core (live channel).
## Save writes tiles_custom/<variant>; the renderer hot-reloads (custom watch
## clears the wall caches and rebuilds statics). Every control FOCUS_NONE.

const C := 22              # canvas pixels per art pixel
const QUD_BG := Color8(17, 33, 38)
const LETTERS := ["r", "R", "o", "O", "w", "W", "y", "Y", "g", "G",
	"b", "B", "c", "C", "m", "M", "k", "K"]
const ARRANGEMENTS := {
	"single": [Vector2i(0, 0)],
	"run": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
	"corner": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)],
	"block": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
}

var _renderer: ZoneRenderer
var _panel: PanelContainer
var _roof: Control
var _face: Control
var _preview: Control
var _palette_ctl: Control
var _status: Label
var _variant_lbl: Label
var _core_chip: Control
var _drop_btn: Button
var _arr_btns := {}

var _tile := ""            # the variant being edited
var _obj := {}
var _img: Image            # the full 16x24 working buffer
var _split := Vector2i(16, 16)
var _variants := []        # every exported variant of the family, sorted
var _colors := []
var _sel := 0
var _picked := Color.WHITE
var _dropper := false
var _painting := false
var _paint_target := ""    # "roof" | "face" while a stroke is live
var _undo := []
var _arrangement := "single"
var _yaw := 0.0            # preview rotation, degrees, 90 steps

func setup(renderer: ZoneRenderer, host: CanvasLayer) -> void:
	_renderer = renderer
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.position = Vector2(40, 60)
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
	# left: the two band canvases
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	root.add_child(left)
	left.add_child(_caption("roof (top-down)"))
	_roof = _make_canvas(func(): _draw_band(_roof, 0, _split.x),
		func(ev): _band_input(ev, "roof"))
	left.add_child(_roof)
	left.add_child(_caption("face (all four sides wear this)"))
	_face = _make_canvas(func(): _draw_band(_face, _split.y, 24),
		func(ev): _band_input(ev, "face"))
	left.add_child(_face)
	# right: variant, palette, tools, preview, core, io
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	root.add_child(col)
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 6)
	col.add_child(vrow)
	vrow.add_child(_make_button("<", func(): _hop_variant(-1)))
	_variant_lbl = Label.new()
	_variant_lbl.text = ""
	vrow.add_child(_variant_lbl)
	vrow.add_child(_make_button(">", func(): _hop_variant(1)))
	_palette_ctl = Control.new()
	_palette_ctl.custom_minimum_size = Vector2(6 * 26, 4 * 26)
	_palette_ctl.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette_ctl.draw.connect(_draw_palette)
	_palette_ctl.gui_input.connect(_palette_input)
	col.add_child(_palette_ctl)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	col.add_child(tools)
	_drop_btn = _make_button("Eyedrop", _toggle_dropper)
	tools.add_child(_drop_btn)
	tools.add_child(_make_button("Undo", _undo_stroke))
	tools.add_child(_make_button("Rotate", func():
		_yaw = fmod(_yaw + 90.0, 360.0)
		_preview.queue_redraw()))
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 6)
	col.add_child(arow)
	for a in ARRANGEMENTS:
		var b := _make_button(a, func(): _set_arrangement(a))
		_arr_btns[a] = b
		arow.add_child(b)
	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(470, 430)
	_preview.draw.connect(_draw_preview)
	col.add_child(_preview)
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 6)
	col.add_child(crow)
	crow.add_child(_make_button("Set core = selected colour", _set_core))
	crow.add_child(_make_button("Clear core", _clear_core))
	_core_chip = Control.new()
	_core_chip.custom_minimum_size = Vector2(24, 24)
	_core_chip.draw.connect(func():
		_core_chip.draw_rect(Rect2(0, 0, 24, 24), _current_core()))
	crow.add_child(_core_chip)
	_status = Label.new()
	_status.text = ""
	col.add_child(_status)
	var iorow := HBoxContainer.new()
	iorow.add_theme_constant_override("separation", 6)
	col.add_child(iorow)
	iorow.add_child(_make_button("Save -> game", _save))
	iorow.add_child(_make_button("Revert to Qud art", _revert))
	iorow.add_child(_make_button("Close", close))

func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _make_canvas(draw_fn: Callable, input_fn: Callable) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	c.draw.connect(draw_fn)
	c.gui_input.connect(input_fn)
	return c

func _make_button(text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b

# --- open / variants --------------------------------------------------------

## A wall variant tile: family-...-XXXXXXXX.<ext>
static func is_wall_variant(tile: String) -> bool:
	var dash := tile.rfind("-")
	var dot := tile.rfind(".")
	if dash < 0 or dot <= dash:
		return false
	var bits := tile.substr(dash + 1, dot - dash - 1)
	if bits.length() != 8:
		return false
	for i in 8:
		if bits[i] != "0" and bits[i] != "1":
			return false
	return true

func open(tile: String, obj := {}) -> void:
	if _renderer == null or not is_wall_variant(tile):
		return
	_obj = obj
	_colors = []
	for ch in LETTERS:
		_colors.append([ch, _renderer.qud_palette_color(ch)])
	_sel = 0
	_dropper = false
	_scan_variants(tile)
	_load_variant(tile)
	_panel.visible = true

func _scan_variants(tile: String) -> void:
	_variants = []
	var flat_base := _flat(tile).substr(0, _flat(tile).rfind("-") + 1)
	var ext := tile.substr(tile.rfind("."))
	var seen := {}
	for dir in [_renderer.tiles_dir(), _custom_dir()]:
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for f in da.get_files():
			if f.begins_with(flat_base) and f.ends_with(ext) and not seen.has(f):
				seen[f] = true
	var names := seen.keys()
	names.sort()
	# store as TILE names (the un-flattened prefix survives only in `tile`); the
	# flat name IS the tile name for our purposes since _flat is stable
	var prefix := tile.substr(0, tile.rfind("-") + 1)
	for f in names:
		_variants.append(prefix + f.substr(flat_base.length()))

func _hop_variant(dir: int) -> void:
	if _variants.is_empty():
		return
	var i := _variants.find(_tile)
	i = (i + dir + _variants.size()) % _variants.size()
	_load_variant(_variants[i])

func _load_variant(tile: String) -> void:
	_tile = tile
	_undo = []
	_img = null
	var custom := _custom_dir().path_join(_flat(tile))
	if FileAccess.file_exists(custom):
		var im := Image.new()
		if im.load_png_from_buffer(FileAccess.get_file_as_bytes(custom)) == OK:
			im.convert(Image.FORMAT_RGBA8)
			_img = im
	if _img == null:
		var im2: Image = _renderer.tile_display_image(tile, _obj)
		if im2 != null:
			im2.convert(Image.FORMAT_RGBA8)
			_img = im2
	if _img == null:
		_img = Image.create(16, 24, false, Image.FORMAT_RGBA8)
	_split = _renderer.wall_art_split(_img)
	var w := _img.get_width()
	_roof.custom_minimum_size = Vector2(w * C, _split.x * C)
	_face.custom_minimum_size = Vector2(w * C, maxi(1, 24 - _split.y) * C)
	var bits := tile.substr(tile.rfind("-") + 1)
	_variant_lbl.text = "%s  (%d/%d)" % [bits.substr(0, bits.find(".")),
		_variants.find(tile) + 1, _variants.size()]
	_status.text = _flat(tile) + ("  (CUSTOM)" if FileAccess.file_exists(custom) else "")
	_refresh()

func close() -> void:
	_panel.visible = false

func is_open() -> bool:
	return _panel != null and _panel.visible

func _flat(tile: String) -> String:
	return tile.replace("/", "_").replace("\\", "_").replace(":", "_")

func _custom_dir() -> String:
	return _renderer.tiles_dir().get_base_dir().path_join("tiles_custom")

# --- band canvases ----------------------------------------------------------

func _draw_band(ctl: Control, row0: int, row1: int) -> void:
	if _img == null:
		return
	var w := _img.get_width()
	var rows := mini(row1, _img.get_height()) - row0
	var sq := C / 2
	for y in rows * 2:
		for x in w * 2:
			var on := (x + y) % 2 == 0
			ctl.draw_rect(Rect2(x * sq, y * sq, sq, sq),
				Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	for y in rows:
		for x in w:
			var c := _img.get_pixel(x, row0 + y)
			if c.a > 0.01:
				ctl.draw_rect(Rect2(x * C, y * C, C, C), c)
	for x in w + 1:
		ctl.draw_line(Vector2(x * C, 0), Vector2(x * C, rows * C), Color(0, 0, 0, 0.35))
	for y in rows + 1:
		ctl.draw_line(Vector2(0, y * C), Vector2(w * C, y * C), Color(0, 0, 0, 0.35))

func _band_input(event: InputEvent, which: String) -> void:
	var ctl: Control = _roof if which == "roof" else _face
	var row0: int = 0 if which == "roof" else _split.y
	if event is InputEventMouseButton:
		ctl.accept_event()
		if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			_pick_at(ctl, event.position, row0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _dropper:
				_pick_at(ctl, event.position, row0)
				_toggle_dropper()
				return
			_painting = event.pressed
			_paint_target = which
			if event.pressed:
				_push_undo()
				_paint_at(ctl, event.position, row0, false)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_push_undo()
			_paint_at(ctl, event.position, row0, true)
	elif event is InputEventMouseMotion and _painting and _paint_target == which:
		ctl.accept_event()
		_paint_at(ctl, event.position, row0, false)

func _paint_at(ctl: Control, pos: Vector2, row0: int, erase: bool) -> void:
	var x := int(pos.x / C)
	var y := row0 + int(pos.y / C)
	if _img == null or x < 0 or x >= _img.get_width() or y < row0 or y >= _img.get_height():
		return
	if int(pos.y / C) >= int(ctl.custom_minimum_size.y / C):
		return
	var c := Color(0, 0, 0, 0)
	if not erase:
		if _sel >= 0:
			c = _colors[_sel][1]
		elif _sel == -2:
			c = _picked
	_img.set_pixel(x, y, c)
	_refresh()

func _pick_at(ctl: Control, pos: Vector2, row0: int) -> void:
	var x := int(pos.x / C)
	var y := row0 + int(pos.y / C)
	if _img == null or x < 0 or x >= _img.get_width() or y < row0 or y >= _img.get_height():
		return
	var c := _img.get_pixel(x, y)
	if c.a < 0.01:
		_sel = -1
	else:
		_picked = c
		_sel = -2
	_refresh()

func _toggle_dropper() -> void:
	_dropper = not _dropper
	if _drop_btn != null:
		_drop_btn.text = "Eyedrop ON" if _dropper else "Eyedrop"

func _push_undo() -> void:
	if _img != null:
		_undo.append(_img.duplicate())
		if _undo.size() > 40:
			_undo.pop_front()

func _undo_stroke() -> void:
	if _undo.is_empty():
		return
	_img = _undo.pop_back()
	_refresh()

# --- palette (the TileEditor look) ------------------------------------------

const SW := 26

func _draw_palette() -> void:
	for i in _colors.size():
		var r := _swatch_rect(i)
		_palette_ctl.draw_rect(r, _colors[i][1])
		if i == _sel:
			_palette_ctl.draw_rect(r.grow(1), Color.WHITE, false, 2.0)
	var er := _swatch_rect(_colors.size())
	var sq := 6
	for yy in 4:
		for xx in 4:
			var on := (xx + yy) % 2 == 0
			_palette_ctl.draw_rect(Rect2(er.position + Vector2(xx * sq, yy * sq), Vector2(sq, sq)),
				Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	if _sel == -1:
		_palette_ctl.draw_rect(er.grow(1), Color.WHITE, false, 2.0)
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

# --- the voxel preview ------------------------------------------------------

func _set_arrangement(a: String) -> void:
	_arrangement = a
	for k in _arr_btns:
		_arr_btns[k].modulate = Color(1, 1, 1) if k != a else Color(0.6, 1.0, 0.7)
	_preview.queue_redraw()

## Software dimetric render of the arrangement, from the renderer's OWN volume
## rules — what you see is what the game meshes. Painter-sorted; 90-degree yaw
## steps orbit the piece so every face can be inspected.
func _draw_preview() -> void:
	if _img == null or _renderer == null or _tile == "":
		return
	var faces: Array = _renderer.wall_preview_arrangement(_tile, _obj,
		ARRANGEMENTS[_arrangement], _img, _tile)
	if faces.is_empty():
		return
	var cells: Array = ARRANGEMENTS[_arrangement]
	var cx := 0.0
	var cz := 0.0
	for k in cells:
		cx += k.x; cz += k.y
	cx /= cells.size(); cz /= cells.size()
	var yawr := deg_to_rad(_yaw)
	var cyaw := cos(yawr)
	var syaw := sin(yawr)
	var items := []
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for f in faces:
		var pts := PackedVector2Array()
		var depth := 0.0
		var ymid := 0.0
		for p_v in f["q"]:
			var p: Vector3 = p_v
			var wx := p.x - cx
			var wz := p.z - cz
			var rx := wx * cyaw - wz * syaw
			var rz := wx * syaw + wz * cyaw
			var sx := rx - rz
			var sy := (rx + rz) * 0.5 - p.y
			pts.append(Vector2(sx, sy))
			depth += rx + rz
			ymid += p.y
			lo = lo.min(Vector2(sx, sy))
			hi = hi.max(Vector2(sx, sy))
		# world-fixed light: rotate the normal with the piece so the sun stays put
		var n: Vector3 = f["n"]
		var rn := Vector3(n.x * cyaw - n.z * syaw, n.y, n.x * syaw + n.z * cyaw)
		var shade := 1.0
		if rn.y > 0.5: shade = 1.0
		elif rn.y < -0.5: shade = 0.45
		elif rn.z > 0.5 or rn.x > 0.5: shade = 0.82
		else: shade = 0.62
		var col: Color = f["c"]
		items.append({"pts": pts, "d": depth / 4.0 + (ymid / 4.0) * 0.001,
			"c": Color(col.r * shade, col.g * shade, col.b * shade, 1.0)})
	items.sort_custom(func(a, b): return a["d"] < b["d"])
	var size := _preview.custom_minimum_size
	var span := hi - lo
	var scale := minf((size.x - 20) / maxf(span.x, 0.01), (size.y - 20) / maxf(span.y, 0.01))
	var off := (size - span * scale) * 0.5 - lo * scale
	_preview.draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.08, 0.08))
	for it in items:
		var pts2 := PackedVector2Array()
		for p in it["pts"]:
			pts2.append(p * scale + off)
		_preview.draw_colored_polygon(pts2, it["c"])

# --- core colour ------------------------------------------------------------

func _overrides_path() -> String:
	return _renderer.tiles_dir().get_base_dir().path_join("overrides.json")

func _current_core() -> Color:
	var data := _read_overrides()
	var fam: String = _renderer.tile_family(_tile)
	var entry = data.get("tiles", {}).get(fam, {})
	var core := String(entry.get("core", "")) if typeof(entry) == TYPE_DICTIONARY else ""
	if core.begins_with("#"):
		return Color.html(core)
	return Color(0.2, 0.2, 0.2)

func _read_overrides() -> Dictionary:
	var path := _overrides_path()
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else {}

func _write_core(value: String) -> void:
	var data := _read_overrides()
	if not data.has("tiles") or typeof(data["tiles"]) != TYPE_DICTIONARY:
		data["tiles"] = {}
	var fam: String = _renderer.tile_family(_tile)
	if not data["tiles"].has(fam) or typeof(data["tiles"][fam]) != TYPE_DICTIONARY:
		data["tiles"][fam] = {}
	if value == "":
		data["tiles"][fam].erase("core")
		if data["tiles"][fam].is_empty():
			data["tiles"].erase(fam)
	else:
		data["tiles"][fam]["core"] = value
	var f := FileAccess.open(_overrides_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()
	_core_chip.queue_redraw()
	_preview.queue_redraw()

func _set_core() -> void:
	var c := Color.WHITE
	if _sel >= 0:
		c = _colors[_sel][1]
	elif _sel == -2:
		c = _picked
	else:
		_status.text = "select a colour first (eraser can't be a core)"
		return
	_write_core("#" + c.to_html(false))
	_status.text = "core colour set for %s" % _renderer.tile_family(_tile)

func _clear_core() -> void:
	_write_core("")
	_status.text = "core colour cleared (back to derived shadow)"

# --- io ---------------------------------------------------------------------

func _refresh() -> void:
	_roof.queue_redraw()
	_face.queue_redraw()
	_palette_ctl.queue_redraw()
	_preview.queue_redraw()

func _save() -> void:
	if _img == null or _tile == "":
		return
	DirAccess.make_dir_recursive_absolute(_custom_dir())
	var path := _custom_dir().path_join(_flat(_tile))
	if _img.save_png(path) == OK:
		_status.text = "saved -> %s (game reloads live)" % _flat(_tile)
	else:
		_status.text = "SAVE FAILED"

func _revert() -> void:
	if _tile == "":
		return
	var path := _custom_dir().path_join(_flat(_tile))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		_load_variant(_tile)
		_status.text = "custom art removed — Qud's art restored"

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

var _tile := ""            # the variant being edited (its group's representative)
var _obj := {}
var _img: Image            # the full 16x24 working buffer (ROOF edits live here)
var _split := Vector2i(16, 16)
var _variants := []        # GROUPS of pixel-identical variant names, first-seen order
var _group := []           # the current group's tile names (save/revert hit all)
# The face is FAMILY-WIDE: every face of every cell renders from just the four
# horizontal-run variants (mid-run, end-framed x2, isolated). One surface edits
# them all; Save writes the edited band into each of the four VERBATIM, so the
# design tiles uniformly through run ends and corners (one-direction wrap).
var _face_img: Image       # the family-wide face band being edited (W x F)
var _face_dirty := false   # face painted this session? A roof-only save must
                           # NOT rewrite the family's faces: a stale surface
                           # stomped Daniel's newer design (design A over B)
var _colors := []
var _sel := 0
var _picked := Color.WHITE
var _dropper := false
var _painting := false
var _paint_target := ""    # "roof" | "face" while a stroke is live
var _undo := []
var _arrangement := "single"
var _yaw := 0.0            # preview rotation, degrees, 90 steps
var _pv_items := []        # last projected faces (for picking)
var _pv_scale := 1.0
var _pv_off := Vector2.ZERO
var _pick := {}            # the picked face item ({} = none)

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
	left.add_child(_caption("face (family-wide: every face of every wall)"))
	_face = _make_canvas(_draw_face, func(ev): _band_input(ev, "face"))
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
		_pick = {}
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
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.draw.connect(_draw_preview)
	_preview.gui_input.connect(_preview_input)
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
	_load_face(tile)
	_load_variant(tile)
	_panel.visible = true

## Variants are grouped by DISTINCT PIXEL CONTENT, not by name. Qud names wall
## art by the raw 8-bit neighbourhood byte, but a diagonal only changes the
## drawing when both flanking cardinals are walls — so the export cache holds
## many pixel-identical files under different names (measured: 108 wall_metal
## names, 37 distinct images). The hopper walks the distinct drawings; Save
## writes the edit to EVERY name in the group, so visually-identical cells
## can never disagree over an invisible diagonal.
func _scan_variants(tile: String) -> void:
	_variants = []
	var flat_base := _flat(tile).substr(0, _flat(tile).rfind("-") + 1)
	var ext := tile.substr(tile.rfind("."))
	var prefix := tile.substr(0, tile.rfind("-") + 1)
	var tiles_dir: String = _renderer.tiles_dir()
	var names := []
	var da := DirAccess.open(tiles_dir)
	if da != null:
		for f in da.get_files():
			if f.begins_with(flat_base) and f.ends_with(ext):
				names.append(f)
	names.sort()
	var by_key := {}
	var order := []
	var known := {}
	for f in names:
		known[f] = true
		# group by decoded pixel identity of the QUD art (custom edits must not
		# change which group a name belongs to)
		var key := 0
		var img := Image.new()
		if img.load_png_from_buffer(FileAccess.get_file_as_bytes(tiles_dir.path_join(f))) == OK:
			img.convert(Image.FORMAT_RGBA8)
			key = hash(img.get_data()) * 31 + img.get_width()
		else:
			key = f.hash()
		if not by_key.has(key):
			by_key[key] = []
			order.append(key)
		by_key[key].append(prefix + f.substr(flat_base.length()))
	# custom-only names (edits whose Qud art never exported) stand alone
	var dc := DirAccess.open(_custom_dir())
	if dc != null:
		for f in dc.get_files():
			if f.begins_with(flat_base) and f.ends_with(ext) and not known.has(f):
				var key2: int = ("custom|" + f).hash()
				by_key[key2] = [prefix + f.substr(flat_base.length())]
				order.append(key2)
	for k in order:
		_variants.append(by_key[k])

## The group (Array of equivalent tile names) the current tile belongs to.
func _group_index() -> int:
	for i in _variants.size():
		if (_variants[i] as Array).has(_tile):
			return i
	return -1

func _hop_variant(dir: int) -> void:
	if _variants.is_empty():
		return
	var i := _group_index()
	i = (i + dir + _variants.size()) % _variants.size()
	_load_variant(_variants[i][0])

## The full 16x24 image for a tile: the custom file when present (and wanted),
## else Qud's art recoloured for this object. Null if neither exists.
func _full_image_of(tile: String, custom_first: bool) -> Image:
	if custom_first:
		var custom := _custom_dir().path_join(_flat(tile))
		if FileAccess.file_exists(custom):
			var im := Image.new()
			if im.load_png_from_buffer(FileAccess.get_file_as_bytes(custom)) == OK:
				im.convert(Image.FORMAT_RGBA8)
				return im
	var im2: Image = _renderer.tile_display_image(tile, _obj)
	if im2 != null:
		im2.convert(Image.FORMAT_RGBA8)
	return im2

## A tile image's face band (the rows below the cap/face split).
func _band_of(img: Image) -> Image:
	var sp: Vector2i = _renderer.wall_art_split(img)
	if sp.y >= img.get_height():
		return Image.create(img.get_width(), 1, false, Image.FORMAT_RGBA8)
	return img.get_region(Rect2i(0, sp.y, img.get_width(), img.get_height() - sp.y))

func _with_bits(tile: String, bits: String) -> String:
	return tile.substr(0, tile.rfind("-") + 1) + bits + tile.substr(tile.rfind("."))

## The four tiles every face renders from (see _face_variant in ZoneRenderer).
func _run_tiles() -> Array:
	var out := []
	for bits in ["00100010", "00100000", "00000010", "00000000"]:
		out.append(_with_bits(_tile, bits))
	return out

## Load the FAMILY-WIDE face surface: the mid-run band (custom-first), falling
## back to the isolated tile, then the current variant.
func _load_face(tile: String) -> void:
	_tile = tile
	_face_img = null
	for cand in [_with_bits(tile, "00100010"), _with_bits(tile, "00000000"), tile]:
		var im := _full_image_of(cand, true)
		if im != null:
			_face_img = _band_of(im)
			break
	if _face_img == null:
		_face_img = Image.create(16, 10, false, Image.FORMAT_RGBA8)
	_face_dirty = false
	_face.custom_minimum_size = Vector2(_face_img.get_width() * C, _face_img.get_height() * C)

## The band Save writes into EVERY run variant: the edited surface, VERBATIM.
## An earlier version preserved each variant's stock end-frame pixels, but run
## ends and corners wear exactly the framed variants — so the design's last
## columns were swapped back to stock right where the wall turns, breaking the
## tiling rhythm (Daniel's annotated screenshot). Under the one-direction
## wallpaper wrap the design tiles UNIFORMLY: every cell shows the identical
## 16 columns; paint your own frames if you want them.
func _merged_band(_t: String) -> Image:
	return _face_img.duplicate()

## A full 16x24 file image: `cap_src`'s cap band over `band` as the face band.
func _composed(cap_src: Image, band: Image) -> Image:
	var out: Image = cap_src.duplicate()
	var sp: Vector2i = _renderer.wall_art_split(cap_src)
	for y in band.get_height():
		var fy := sp.y + y
		if fy >= out.get_height():
			break
		for x in mini(band.get_width(), out.get_width()):
			out.set_pixel(x, fy, band.get_pixel(x, y))
	return out

func _load_variant(tile: String) -> void:
	_tile = tile
	_undo = []
	_pick = {}
	_img = _full_image_of(tile, true)
	if _img == null:
		_img = Image.create(16, 24, false, Image.FORMAT_RGBA8)
	_split = _renderer.wall_art_split(_img)
	var w := _img.get_width()
	_roof.custom_minimum_size = Vector2(w * C, _split.x * C)
	var gi := _group_index()
	_group = _variants[gi] if gi >= 0 else [tile]
	var any_custom := false
	for t in _group:
		if FileAccess.file_exists(_custom_dir().path_join(_flat(t))):
			any_custom = true
			break
	var bits := tile.substr(tile.rfind("-") + 1)
	var extra := " +%d alike" % (_group.size() - 1) if _group.size() > 1 else ""
	_variant_lbl.text = "%s%s  (%d/%d)" % [bits.substr(0, bits.find(".")),
		extra, gi + 1, _variants.size()]
	_status.text = _flat(tile) + ("  (CUSTOM)" if any_custom else "")
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

## The ROOF canvas edits _img's cap band; the FACE canvas edits the family-wide
## _face_img. `_edit_target(which)` -> [Image, row offset into it].
func _edit_target(which: String) -> Array:
	if which == "roof":
		return [_img, 0, _split.x]              # image, row0, row count
	return [_face_img, 0, _face_img.get_height() if _face_img != null else 0]

func _draw_band(ctl: Control, row0: int, row1: int) -> void:
	_draw_grid(ctl, _img, row0, mini(row1, _img.get_height() if _img != null else 0) - row0)

func _draw_face() -> void:
	if _face_img != null:
		_draw_grid(_face, _face_img, 0, _face_img.get_height())

func _draw_grid(ctl: Control, img: Image, row0: int, rows: int) -> void:
	if img == null or rows <= 0:
		return
	var w := img.get_width()
	var sq := C / 2
	for y in rows * 2:
		for x in w * 2:
			var on := (x + y) % 2 == 0
			ctl.draw_rect(Rect2(x * sq, y * sq, sq, sq),
				Color(0.32, 0.32, 0.34) if on else Color(0.18, 0.18, 0.20))
	for y in rows:
		for x in w:
			var c := img.get_pixel(x, row0 + y)
			if c.a > 0.01:
				ctl.draw_rect(Rect2(x * C, y * C, C, C), c)
	for x in w + 1:
		ctl.draw_line(Vector2(x * C, 0), Vector2(x * C, rows * C), Color(0, 0, 0, 0.35))
	for y in rows + 1:
		ctl.draw_line(Vector2(0, y * C), Vector2(w * C, y * C), Color(0, 0, 0, 0.35))

func _band_input(event: InputEvent, which: String) -> void:
	var ctl: Control = _roof if which == "roof" else _face
	if event is InputEventMouseButton:
		ctl.accept_event()
		if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			_pick_at(event.position, which)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _dropper:
				_pick_at(event.position, which)
				_toggle_dropper()
				return
			_painting = event.pressed
			_paint_target = which
			if event.pressed:
				_push_undo()
				_paint_at(event.position, which, false)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_push_undo()
			_paint_at(event.position, which, true)
	elif event is InputEventMouseMotion and _painting and _paint_target == which:
		ctl.accept_event()
		_paint_at(event.position, which, false)

func _paint_at(pos: Vector2, which: String, erase: bool) -> void:
	var t := _edit_target(which)
	var img: Image = t[0]
	var x := int(pos.x / C)
	var y: int = t[1] + int(pos.y / C)
	if img == null or x < 0 or x >= img.get_width() \
			or int(pos.y / C) < 0 or int(pos.y / C) >= int(t[2]):
		return
	var c := Color(0, 0, 0, 0)
	if not erase:
		if _sel >= 0:
			c = _colors[_sel][1]
		elif _sel == -2:
			c = _picked
	img.set_pixel(x, y, c)
	if which == "face":
		_face_dirty = true
	_refresh()

func _pick_at(pos: Vector2, which: String) -> void:
	var t := _edit_target(which)
	var img: Image = t[0]
	var x := int(pos.x / C)
	var y: int = t[1] + int(pos.y / C)
	if img == null or x < 0 or x >= img.get_width() \
			or int(pos.y / C) < 0 or int(pos.y / C) >= int(t[2]):
		return
	var c := img.get_pixel(x, y)
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
	if _img != null and _face_img != null:
		_undo.append({"img": _img.duplicate(), "face": _face_img.duplicate()})
		if _undo.size() > 40:
			_undo.pop_front()

func _undo_stroke() -> void:
	if _undo.is_empty():
		return
	var s: Dictionary = _undo.pop_back()
	_img = s["img"]
	_face_img = s["face"]
	_face_dirty = true
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
	_pick = {}
	for k in _arr_btns:
		_arr_btns[k].modulate = Color(1, 1, 1) if k != a else Color(0.6, 1.0, 0.7)
	_preview.queue_redraw()

## Software dimetric render of the arrangement, from the renderer's OWN volume
## rules — what you see is what the game meshes. Painter-sorted; 90-degree yaw
## steps orbit the piece so every face can be inspected.
func _draw_preview() -> void:
	if _img == null or _renderer == null or _tile == "":
		return
	var fo := {}
	for t in _run_tiles():
		fo[t] = _merged_band(t)
	var faces: Array = _renderer.wall_preview_arrangement(_tile, _obj,
		ARRANGEMENTS[_arrangement], _img, _tile, fo)
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
			"c": Color(col.r * shade, col.g * shade, col.b * shade, 1.0),
			"m": f.get("m", {}), "c0": col})
	items.sort_custom(func(a, b): return a["d"] < b["d"])
	var size := _preview.custom_minimum_size
	var span := hi - lo
	var scale := minf((size.x - 20) / maxf(span.x, 0.01), (size.y - 20) / maxf(span.y, 0.01))
	var off := (size - span * scale) * 0.5 - lo * scale
	_pv_items = items
	_pv_scale = scale
	_pv_off = off
	_preview.draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.08, 0.08))
	for it in items:
		var pts2 := PackedVector2Array()
		for p in it["pts"]:
			pts2.append(p * scale + off)
		_preview.draw_colored_polygon(pts2, it["c"])
	# picked-face highlight, re-projected with the current transform
	if not _pick.is_empty():
		var hp := PackedVector2Array()
		for p in _pick["pts"]:
			hp.append(p * scale + off)
		hp.append(hp[0])
		_preview.draw_polyline(hp, Color(1.0, 1.0, 0.3), 2.0)

## Click a face in the 3D preview to SELECT it: highlights it and writes
## voxel_selection.txt (voxel coords, face kind, owner, art pixel, colour) —
## the channel for reporting exactly which face is wrong (Daniel: "add the
## ability to select tiles on the 3d view so I can communicate the issues").
func _preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_preview.accept_event()
		for i in range(_pv_items.size() - 1, -1, -1):
			var it: Dictionary = _pv_items[i]
			var pts := PackedVector2Array()
			for p in it["pts"]:
				pts.append(p * _pv_scale + _pv_off)
			if Geometry2D.is_point_in_polygon(event.position, pts):
				_pick = it
				_write_pick_report(it)
				_preview.queue_redraw()
				return
		_pick = {}
		_preview.queue_redraw()

func _write_pick_report(it: Dictionary) -> void:
	var m: Dictionary = it.get("m", {})
	var path := _renderer.tiles_dir().get_base_dir().path_join("voxel_selection.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var c0: Color = it.get("c0", Color.BLACK)
	var c: Color = it.get("c", Color.BLACK)
	f.store_line("=== voxel pick (editor 3D preview) ===")
	f.store_line("editing   %s" % _tile)
	f.store_line("arrangement %s   yaw %d   cell %s" % [_arrangement, int(_yaw), str(m.get("cell", "?"))])
	f.store_line("variant   %s" % String(m.get("variant", "?")))
	f.store_line("face kind %s" % String(m.get("k", "?")))
	f.store_line("voxel     %s  (x, z, row; row 0 = cap layer)" % str(m.get("v", m.get("edge_a", "?"))))
	if m.has("ax"):
		f.store_line("art px    col %d, band row %d" % [int(m["ax"]), int(m["fr"])])
	f.store_line("colour    #%s baked, #%s with preview shade" % [c0.to_html(false), c.to_html(false)])
	f.close()
	_status.text = "picked %s %s -> voxel_selection.txt" % [String(m.get("k", "?")), str(m.get("v", ""))]

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
	# ROOF: every name in the current group — visually-identical cells must
	# never disagree over an invisible diagonal bit. Each file also carries the
	# family face band (merged for run tiles so their end frames survive).
	var wrote := 0
	var written := {}
	for t in (_group if not _group.is_empty() else [_tile]):
		var band: Image = _face_img
		if _composed(_img, band).save_png(_custom_dir().path_join(_flat(t))) == OK:
			wrote += 1
			written[t] = true
	# FACE: the family-wide surface lands on all four run variants (the only
	# face sources) — but ONLY when the face was painted this session. Fanning
	# out an untouched surface let one session's stale face overwrite a newer
	# design saved by another (design A stomped design B).
	var faces_written := 0
	if _face_dirty:
		for t in _run_tiles():
			if written.has(t):
				faces_written += 1
				continue
			var base := _full_image_of(t, true)
			if base == null:
				continue
			if _composed(base, _merged_band(t)).save_png(_custom_dir().path_join(_flat(t))) == OK:
				faces_written += 1
	if wrote > 0 or faces_written > 0:
		var facemsg := ("face -> %d run variant%s" % [faces_written, "" if faces_written == 1 else "s"]) \
			if _face_dirty else "face untouched (not rewritten)"
		_status.text = "saved: roof -> %d name%s, %s (game reloads live)" \
			% [wrote, "" if wrote == 1 else "s", facemsg]
		_face_dirty = false
	else:
		_status.text = "SAVE FAILED"

func _revert() -> void:
	if _tile == "":
		return
	var targets := {}
	for t in (_group if not _group.is_empty() else [_tile]):
		targets[t] = true
	for t in _run_tiles():
		targets[t] = true
	var removed := 0
	for t in targets:
		var path := _custom_dir().path_join(_flat(t))
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
			removed += 1
	if removed > 0:
		_load_face(_tile)
		_load_variant(_tile)
		_status.text = "custom art removed from %d name%s — Qud's art restored" \
			% [removed, "" if removed == 1 else "s"]

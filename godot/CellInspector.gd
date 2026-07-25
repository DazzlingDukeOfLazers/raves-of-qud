extends Node3D
class_name CellInspector

## Point at a cell, get a report you can hand straight to a collaborator (human or
## AI) instead of describing what you see in words.
##
## The report pairs the two things that matter and that can disagree:
##   WIRE     — exactly what Qud sent for that cell (tiles, colours, flags)
##   RENDERED — what ZoneRenderer actually did with each object, and at what Y
## Every rendering bug so far has lived in the gap between those two.
##
## It also resolves each tile to its exported PNG on disk, with dimensions and
## the opaque-row band, so tiles can be decoded directly without a screenshot.
##
## Controls:  Ctrl/Cmd + Left-click, or hover and press I
##            - / =  shrink or grow the panel text   (Esc dismisses)
##
## Output (all three, so it's there however you want to grab it):
##   - on-screen panel
##   - the clipboard
##   - <tilesDir>/../selection.txt   (latest)  and  selections.log  (history)

const FONT_SIZE_DEFAULT := 22
const FONT_SIZE_MIN := 10
const FONT_SIZE_MAX := 48
const LINE_HEIGHT_RATIO := 1.35   # approximate, for fitting lines to the viewport

var _renderer: ZoneRenderer
var _cam: Camera3D
var _snap := {}
var _by_cell := {}          # Vector2i -> cell dictionary from the snapshot

const PREVIEW_PX := 260          # on-screen size of the sprite preview
const PREVIEW_SPIN := 0.9        # radians/sec
const CHECKER_PX := 10           # checkerboard square size

var _panel: PanelContainer
var _label: RichTextLabel
var _mark_box: MeshInstance3D   # dashed wireframe outlining the whole 3D tile
var _mark_pin: MeshInstance3D   # dashed finder line rising from the tile top
var _font_size := FONT_SIZE_DEFAULT
var _last_report := ""
var _selected = null      # Vector2i of the last inspected tile
var _saved_overlay := {}  # visibility snapshot while a clean screenshot is taken

# sprite preview (upper right): the real billboard texture turning over a
# checkerboard, so filled-vs-transparent is visible rather than inferred
var _preview: Control
var _preview_sprite: Sprite3D
var _preview_caption: Label

func setup(renderer: ZoneRenderer, cam: Camera3D) -> void:
	_renderer = renderer
	_cam = cam
	_build_ui()
	_build_marker()
	_build_preview()

func _process(dt: float) -> void:
	if _preview_sprite != null and _preview.visible:
		_preview_sprite.rotate_y(PREVIEW_SPIN * dt)

func on_snapshot(data: Dictionary) -> void:
	_snap = data
	_by_cell.clear()
	for cell in data.get("cells", []):
		_by_cell[Vector2i(int(cell.get("x", 0)), int(cell.get("y", 0)))] = cell

# --- picking ----------------------------------------------------------------

## Ray from the cursor onto the ground plane (y = 0). NOTE: this picks the cell
## the ray lands on, so clicking the *top* of a tall wall reports the cell behind
## it. Aim at the ground, or orbit overhead, when picking near walls.
func _ground_hit() -> Variant:
	return _ground_hit_cam(_cam, get_viewport().get_mouse_position())

## Ground-plane hit for an arbitrary camera + viewport-local mouse position (so a
## multi-view pane can pick with its own camera).
func _ground_hit_cam(cam: Camera3D, mp: Vector2) -> Variant:
	if cam == null:
		return null
	var from := cam.project_ray_origin(mp)
	var dir := cam.project_ray_normal(mp)
	if absf(dir.y) < 1e-6:
		return null
	var t := -from.y / dir.y
	if t <= 0.0:
		return null
	return from + dir * t

## The report text and tile of the last inspection, for the report form.
func last_report() -> String:
	return _last_report

## Objects in the last inspected tile, TOPMOST FIRST — sorted by RenderLayer,
## not by array position. Qud sends objects in cell-stack order, which is not
## render order: taking the last entry here picked the water under a water wheel.
func last_objects() -> Array:
	if _selected == null or not _by_cell.has(_selected):
		return []
	var objs: Array = _by_cell[_selected].get("objs", []).duplicate()
	objs.sort_custom(func(a, b): return int(a.get("layer", 0)) > int(b.get("layer", 0)))
	return objs

func zone_id() -> String:
	return String(_snap.get("zone", {}).get("id", "?"))

## The tile the user last inspected, or null. MOUSE camera mode orbits this.
func selected_tile() -> Variant:
	return _selected

func inspect_at_mouse() -> void:
	inspect_at(_cam, get_viewport().get_mouse_position())

## Inspect using a specific camera + viewport-local mouse position. The main view passes
## its camera + the window mouse; a multi-view pane passes its own camera + pane-local pos.
## The marker is a node in the shared 3D world, so it shows in every pane at once.
func inspect_at(cam: Camera3D, mp: Vector2) -> void:
	var hit = _ground_hit_cam(cam, mp)
	if hit == null:
		return
	var cell := _pick_cell(hit, cam, mp)
	_selected = cell
	var report := build_report(cell.x, cell.y, hit)
	_show(report, cell.x, cell.y)
	DisplayServer.clipboard_set(report)
	_write(report)

func _occupied(c: Vector2i) -> bool:
	return _by_cell.has(c) and (_by_cell[c].get("objs", []) as Array).size() > 0

## Ground-plane picking lands the ray on the cell the ray reaches at y=0. For a
## raised wall that is the empty cell BEHIND it (away from the camera) — the parallax
## noted on _ground_hit. Because that overshoot is always away from the camera, when
## the hit cell is empty we march the hit point back TOWARD the camera and snap to the
## first occupied cell: the wall the user actually clicked. Accurate picks (overhead,
## or clicking bare ground with nothing between) return the hit cell unchanged.
func _pick_cell(hit: Vector3, cam: Camera3D, mp: Vector2) -> Vector2i:
	var cell := Vector2i(roundi(hit.x), roundi(hit.z))
	if _occupied(cell) or cam == null:
		return cell
	var dir := cam.project_ray_normal(mp)
	var back := Vector2(-dir.x, -dir.z)      # toward the camera, on the ground plane
	if back.length() < 1e-6:
		return cell
	back = back.normalized()
	var p := Vector2(hit.x, hit.z)
	const STEP := 0.34
	for i in range(1, 13):                    # up to ~4 cells toward the camera
		var c := Vector2i(roundi(p.x + back.x * STEP * i), roundi(p.y + back.y * STEP * i))
		if c != cell and _occupied(c):
			return c
	return cell

# --- the report -------------------------------------------------------------

func build_report(cx: int, cy: int, hit: Vector3) -> String:
	var L: Array[String] = []
	var zone: Dictionary = _snap.get("zone", {})
	var player: Dictionary = _snap.get("player", {})

	L.append("=== Raves of Qud — cell %d,%d ===" % [cx, cy])
	L.append("mod build: %s" % String(_snap.get("mod", "?? (pre-marker build — restart Qud)")))
	L.append("zone %s  %sx%s   player (%s,%s)   picked at world (%.2f, %.2f)" % [
		zone.get("id", "?"), zone.get("width", "?"), zone.get("height", "?"),
		player.get("x", "?"), player.get("y", "?"), hit.x, hit.z])

	if not _by_cell.has(Vector2i(cx, cy)):
		L.append("")
		L.append("EMPTY — nothing here. In Qud a bare tile holds no object at all;")
		L.append("the background colour you see is the world, not a floor sprite.")
		L.append("")
		L.append("Nearest tiles that DO hold something (so you can retarget):")
		for line in _neighbours(cx, cy):
			L.append("  " + line)
		_preview.visible = false
		return "\n".join(L)

	var cell: Dictionary = _by_cell[Vector2i(cx, cy)]
	_update_preview(cell)
	var sink := _renderer.cell_sink(cell) if _renderer != null else 0.0
	L.append("cell flags: bridge=%s wade=%s swim=%s   -> sink %.2f" % [
		cell.get("bridge", false), cell.get("wade", false), cell.get("swim", false), sink])

	# what the renderer did, keyed by object index so it lines up below
	var acts := {}
	if _renderer != null:
		for p in _renderer.placements_at(cx, cy):
			var i := int(p["idx"])
			if not acts.has(i):
				acts[i] = []
			acts[i].append(p)

	var objs: Array = cell.get("objs", [])
	L.append("")
	L.append("%d object(s), bottom -> top:" % objs.size())
	for i in objs.size():
		var o: Dictionary = objs[i]
		var tile := String(o.get("tile", ""))
		L.append("")
		L.append(" [%d] %s  %s" % [i,
			_q(String(o.get("display", ""))), String(o.get("name", "?"))])
		L.append("     layer=%s  glyph=%s" % [o.get("layer", "?"), _q(String(o.get("glyph", "")))])
		L.append("     tile     %s" % (_q(tile) if tile != "" else "(none)"))
		L.append("     png      %s" % _png_line(tile))
		L.append("     colour   color=%s tilecolor=%s detail=%s" % [
			_q(String(o.get("color", ""))), _q(String(o.get("tilecolor", ""))), _q(String(o.get("detail", "")))])
		L.append("     flags    wall=%d occluding=%d solid=%d bridge=%d sinks=%d" % [
			int(bool(o.get("wall", false))), int(bool(o.get("occluding", false))),
			int(bool(o.get("solid", false))), int(bool(o.get("bridge", false))),
			int(bool(o.get("sinks", false)))])
		if _renderer != null and tile != "":
			var ov := _renderer.override_summary(tile)
			if ov != "":
				L.append("     OVERRIDE %s  (from overrides.json)" % ov)
		if acts.has(i):
			for p in acts[i]:
				L.append("     RENDERED %s  y=%.3f" % [p["kind"], p["y"]])
		else:
			L.append("     RENDERED (nothing — object was dropped)")
	return "\n".join(L)

## Populated tiles nearest an empty pick, closest first. Clicking bare ground is
## normal and common, so "EMPTY" alone can't distinguish a miss from a genuinely
## empty tile — this gives you somewhere to aim instead.
func _neighbours(cx: int, cy: int, radius := 3, limit := 6) -> Array:
	var found := []
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue    # ring at exactly distance r, so results come out sorted
				var k := Vector2i(cx + dx, cy + dy)
				if not _by_cell.has(k):
					continue
				var objs: Array = _by_cell[k].get("objs", [])
				var what := "?"
				if objs.size() > 0:
					var top: Dictionary = objs[objs.size() - 1]
					what = String(top.get("display", ""))
					if what == "":
						what = String(top.get("name", "?"))
					if objs.size() > 1:
						what += " (+%d more)" % (objs.size() - 1)
				found.append("(%d,%d)  %+d,%+d   %s" % [k.x, k.y, dx, dy, what])
				if found.size() >= limit:
					return found
	if found.is_empty():
		found.append("nothing within %d tiles either" % radius)
	return found

func _png_line(tile: String) -> String:
	if tile == "" or _renderer == null:
		return "(no tile)"
	var fname := _renderer.tile_filename(tile)
	var img := _renderer.tile_image(tile)
	if img == null:
		return "%s  MISSING — not exported yet (renders as a glyph)" % fname
	var band := _renderer.tile_opaque_band(tile)
	var h := img.get_height()
	return "%s  %dx%d  opaque rows %d..%d" % [
		fname, img.get_width(), h, int(band.x * h), int((band.x + band.y) * h) - 1]

func _q(s: String) -> String:
	return "'%s'" % s

# --- output sinks -----------------------------------------------------------

func _write(report: String) -> void:
	if _renderer == null:
		return
	var dir := _renderer.tiles_dir().get_base_dir()
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("selection.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string(report + "\n")
		f.close()
	# append-only history ("hist", not "log" — log() is a GDScript builtin)
	var hist := FileAccess.open(dir.path_join("selections.log"), FileAccess.READ_WRITE)
	if hist == null:
		hist = FileAccess.open(dir.path_join("selections.log"), FileAccess.WRITE)
	if hist != null:
		hist.seek_end()
		hist.store_string("\n[%s]\n%s\n" % [Time.get_datetime_string_from_system(), report])
		hist.close()

func _show(report: String, cx: int, cy: int) -> void:
	_last_report = report
	_repaint()
	_panel.visible = true
	_mark_box.position = Vector3(cx, 0.0, cy)
	_mark_pin.position = Vector3(cx, 0.0, cy)
	_mark_box.visible = true
	_mark_pin.visible = true

## Re-flow the current report for the current font size. How many lines fit
## depends on the font size, so this is recomputed rather than a fixed cap.
func _repaint() -> void:
	if _last_report == "":
		return
	var lines := _last_report.split("\n")
	var avail := get_viewport().get_visible_rect().size.y - 48.0
	var fits := maxi(6, floori(avail / (_font_size * LINE_HEIGHT_RATIO)))
	if lines.size() <= fits:
		_label.text = _last_report
	else:
		_label.text = "\n".join(lines.slice(0, fits - 1))
		_label.text += "\n… %d more lines — full report is on the clipboard and in selection.txt" % (
			lines.size() - (fits - 1))

## '-' / '=' while the panel is up. Sizing is a matter of the user's display, not
## something to hard-code and hope for.
func nudge_font(delta: int) -> void:
	if not _panel.visible:
		return
	_font_size = clampi(_font_size + delta, FONT_SIZE_MIN, FONT_SIZE_MAX)
	_label.add_theme_font_size_override("normal_font_size", _font_size)
	_repaint()

## Temporarily hide the report so a screenshot shows the scene, not the text.
## The 3D marker stays up — the point of the shot is to see WHAT was selected.
func panel_visible() -> bool:
	return _panel != null and _panel.visible

func set_panel_visible(v: bool) -> void:
	if _panel != null:
		_panel.visible = v

func hide_panel() -> void:
	_panel.visible = false
	_preview.visible = false
	_mark_box.visible = false
	_mark_pin.visible = false

## Hide the ENTIRE selection overlay — report panel, preview, AND the 3D marker —
## then restore exactly what was showing. The capture gesture uses this to shoot a
## bare plate of the scene before the selection is drawn.
func overlay_visible() -> bool:
	return panel_visible() or (_mark_box != null and _mark_box.visible)

func set_overlay_visible(v: bool) -> void:
	if not v:
		_saved_overlay = {
			"panel": _panel.visible, "preview": _preview.visible,
			"box": _mark_box.visible, "pin": _mark_pin.visible,
		}
		set_panel_visible(false)
		_preview.visible = false
		_mark_box.visible = false
		_mark_pin.visible = false
	elif not _saved_overlay.is_empty():
		set_panel_visible(_saved_overlay["panel"])
		_preview.visible = _saved_overlay["preview"]
		_mark_box.visible = _saved_overlay["box"]
		_mark_pin.visible = _saved_overlay["pin"]
		_saved_overlay = {}

# --- scaffolding ------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(12, 12)
	_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.04, 0.90)
	style.border_color = Color(0.45, 0.85, 0.55, 0.9)
	style.set_border_width_all(1)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(_panel)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = false
	_label.fit_content = true
	_label.scroll_active = false
	# no wrapping: the report is column-aligned, and a wrap destroys the alignment
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.add_theme_color_override("default_color", Color(0.85, 0.95, 0.85))
	_label.add_theme_font_size_override("normal_font_size", _font_size)
	# monospace, so tile names and flag columns line up
	# Atkinson Hyperlegible Mono (bundled). The report is column-aligned — tile
	# names, flag columns — so the label needs a MONOSPACE cut, not the project's
	# proportional default. Falls back to a system mono if the file is ever missing.
	var mono := load("res://fonts/AtkinsonHyperlegibleMono-Regular.ttf")
	if mono == null:
		var sys := SystemFont.new()
		sys.font_names = PackedStringArray(["Menlo", "SF Mono", "Monaco", "monospace"])
		mono = sys
	_label.add_theme_font_override("normal_font", mono)
	_panel.add_child(_label)

# Upper-right preview: the actual billboard texture, turning, over a
# checkerboard. Transparency is otherwise invisible against the dark ground —
# a filled gap and a see-through one both just look dark.
func _build_preview() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_preview = Control.new()
	_preview.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_preview.offset_left = -(PREVIEW_PX + 16)
	_preview.offset_top = 16
	_preview.offset_right = -16
	_preview.offset_bottom = 16 + PREVIEW_PX + 22
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.visible = false
	layer.add_child(_preview)

	var checker := TextureRect.new()
	checker.texture = _checker_texture()
	checker.stretch_mode = TextureRect.STRETCH_TILE
	# explicit, since the project canvas default is linear for text
	checker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	checker.size = Vector2(PREVIEW_PX, PREVIEW_PX)
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.add_child(checker)

	var holder := SubViewportContainer.new()
	holder.size = Vector2(PREVIEW_PX, PREVIEW_PX)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.add_child(holder)

	var vp := SubViewport.new()
	vp.size = Vector2i(PREVIEW_PX, PREVIEW_PX)
	vp.transparent_bg = true          # so the checkerboard shows through
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	holder.add_child(vp)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.5
	cam.position = Vector3(0, 0.15, 2.2)
	vp.add_child(cam)

	_preview_sprite = Sprite3D.new()
	_preview_sprite.pixel_size = 0.045
	_preview_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_preview_sprite.shaded = false
	_preview_sprite.double_sided = true   # stays visible through the back half
	_preview_sprite.transparent = true
	_preview_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	vp.add_child(_preview_sprite)

	_preview_caption = Label.new()
	_preview_caption.position = Vector2(0, PREVIEW_PX + 2)
	_preview_caption.add_theme_font_size_override("font_size", 13)
	_preview_caption.add_theme_color_override("font_color", Color(0.8, 0.92, 0.8))
	_preview.add_child(_preview_caption)

func _checker_texture() -> ImageTexture:
	var n := CHECKER_PX * 2
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var a := Color(0.32, 0.32, 0.34)
	var b := Color(0.20, 0.20, 0.22)
	for y in n:
		for x in n:
			var odd := (x < CHECKER_PX) != (y < CHECKER_PX)
			img.set_pixel(x, y, a if odd else b)
	return ImageTexture.create_from_image(img)

## Preview the topmost object in the cell that has a tile.
func _update_preview(cell: Dictionary) -> void:
	if _renderer == null:
		return
	var objs: Array = cell.get("objs", [])
	for i in range(objs.size() - 1, -1, -1):
		var o: Dictionary = objs[i]
		var tile := String(o.get("tile", ""))
		if tile == "":
			continue
		var main_c := String(o.get("tilecolor", ""))
		if main_c == "": main_c = String(o.get("color", ""))
		var tex := _renderer.billboard_texture(tile, main_c, String(o.get("detail", "")))
		if tex == null:
			continue
		_preview_sprite.texture = tex
		_preview_sprite.rotation = Vector3.ZERO
		var gaps := _renderer.tile_fill_px(tile, _renderer.fill_mode_for(tile))
		_preview_caption.text = "%s  ·  %s" % [
			tile.replace("\\", "/").get_file(),
			("%d px gap filled" % gaps) if gaps > 0 else "no gaps filled"]
		_preview.visible = true
		return
	_preview.visible = false

# Selection marker geometry. No fill: the marker is the tile's 3D volume drawn as
# dashed edges (footprint just above the floor, up to a cell-tall top) plus a dashed
# finder line rising from the top so the pick stays locatable behind walls.
const MARK_FLOOR_LIFT := 0.01   # sit the footprint ring just clear of the floor quads
const MARK_PIN_RISE := 1.6      # finder-line height above the tile top
const MARK_DASH := 0.12         # dash length, world units
const MARK_GAP := 0.09          # gap between dashes
const MARK_COLOR := Color(1.0, 0.95, 0.3, 0.9)

func _build_marker() -> void:
	_mark_box = MeshInstance3D.new()
	_mark_box.mesh = _prism_outline_mesh()
	_mark_box.material_override = _marker_material(MARK_COLOR)
	_mark_box.visible = false
	add_child(_mark_box)

	# a finder line so the selection stays findable behind walls / at a shallow pitch
	_mark_pin = MeshInstance3D.new()
	_mark_pin.mesh = _pin_mesh()
	_mark_pin.material_override = _marker_material(MARK_COLOR)
	_mark_pin.visible = false
	add_child(_mark_pin)

## Dashed wireframe of the tile's 3D volume: a footprint ring just above the floor,
## a matching ring at cell height, and the four vertical edges — the whole prism in
## dashes, no fill. Built in cell-local space; _show sets the instance to the cell.
func _prism_outline_mesh() -> ArrayMesh:
	var y0 := ZoneRenderer.FLOOR_Y + MARK_FLOOR_LIFT
	var y1 := ZoneRenderer.WALL_H
	var h := 0.5
	var c := [
		Vector3(-h, y0, -h), Vector3(h, y0, -h), Vector3(h, y0, h), Vector3(-h, y0, h),
		Vector3(-h, y1, -h), Vector3(h, y1, -h), Vector3(h, y1, h), Vector3(-h, y1, h),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],   # footprint, just above the floor
		[4, 5], [5, 6], [6, 7], [7, 4],   # top ring at cell height
		[0, 4], [1, 5], [2, 6], [3, 7],   # vertical edges of the prism
	]
	var pts := PackedVector3Array()
	for e in edges:
		_dash_into(c[e[0]], c[e[1]], pts)
	return _lines_mesh(pts)

## A vertical dashed line from the tile top upward — the behind-walls finder.
func _pin_mesh() -> ArrayMesh:
	var top := ZoneRenderer.WALL_H
	var pts := PackedVector3Array()
	_dash_into(Vector3(0, top, 0), Vector3(0, top + MARK_PIN_RISE, 0), pts)
	return _lines_mesh(pts)

## Split a->b into dashes, appending each dash's two endpoints to `out`.
func _dash_into(a: Vector3, b: Vector3, out: PackedVector3Array) -> void:
	var seg := b - a
	var total := seg.length()
	if total < 1e-5:
		return
	var dir := seg / total
	var step := MARK_DASH + MARK_GAP
	var t := 0.0
	while t < total:
		out.append(a + dir * t)
		out.append(a + dir * minf(t + MARK_DASH, total))
		t += step

## Each consecutive pair in `pts` is one dash, built as a thin 3D BOX with a world-unit
## thickness (not a 1px line primitive). In perspective, near dashes then draw thicker than
## far ones — a depth cue for the pick — and a box is visible from any angle. Plain geometry,
## no shader (the earlier ribbon+shader version rendered nothing).
const MARK_LINE_W := 0.02   # world half-thickness of the marker lines
func _lines_mesh(pts: PackedVector3Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	var i := 0
	while i + 1 < pts.size():
		if _box_segment(st, pts[i], pts[i + 1], MARK_LINE_W):
			any = true
		i += 2
	if not any:
		return ArrayMesh.new()
	return st.commit()

## Append a thin rectangular prism from a→b (half-thickness w) to the SurfaceTool. Returns
## false for a degenerate (zero-length) segment.
func _box_segment(st: SurfaceTool, a: Vector3, b: Vector3, w: float) -> bool:
	var d := b - a
	var L := d.length()
	if L < 1e-6:
		return false
	d /= L
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var u := d.cross(up).normalized() * w
	var v := d.cross(u).normalized() * w
	var c := [
		a - u - v, a + u - v, a + u + v, a - u + v,
		b - u - v, b + u - v, b + u + v, b - u + v,
	]
	for fi in [0, 1, 2, 0, 2, 3,  4, 6, 5, 4, 7, 6,  0, 4, 5, 0, 5, 1,
			1, 5, 6, 1, 6, 2,  2, 6, 7, 2, 7, 3,  3, 7, 4, 3, 4, 0]:
		st.add_vertex(c[fi])
	return true

func _marker_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

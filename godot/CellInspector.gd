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

var _panel: PanelContainer
var _label: RichTextLabel
var _mark_pad: MeshInstance3D
var _mark_pin: MeshInstance3D
var _font_size := FONT_SIZE_DEFAULT
var _last_report := ""

func setup(renderer: ZoneRenderer, cam: Camera3D) -> void:
	_renderer = renderer
	_cam = cam
	_build_ui()
	_build_marker()

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
	if _cam == null:
		return null
	var mp := get_viewport().get_mouse_position()
	var from := _cam.project_ray_origin(mp)
	var dir := _cam.project_ray_normal(mp)
	if absf(dir.y) < 1e-6:
		return null
	var t := -from.y / dir.y
	if t <= 0.0:
		return null
	return from + dir * t

func inspect_at_mouse() -> void:
	var hit = _ground_hit()
	if hit == null:
		return
	var cx := roundi(hit.x)
	var cy := roundi(hit.z)
	var report := build_report(cx, cy, hit)
	_show(report, cx, cy)
	DisplayServer.clipboard_set(report)
	_write(report)

# --- the report -------------------------------------------------------------

func build_report(cx: int, cy: int, hit: Vector3) -> String:
	var L: Array[String] = []
	var zone: Dictionary = _snap.get("zone", {})
	var player: Dictionary = _snap.get("player", {})

	L.append("=== Raves of Qud — cell %d,%d ===" % [cx, cy])
	L.append("zone %s  %sx%s   player (%s,%s)   picked at world (%.2f, %.2f)" % [
		zone.get("id", "?"), zone.get("width", "?"), zone.get("height", "?"),
		player.get("x", "?"), player.get("y", "?"), hit.x, hit.z])

	if not _by_cell.has(Vector2i(cx, cy)):
		L.append("")
		L.append("EMPTY — no objects here (Qud only sends non-empty cells).")
		return "\n".join(L)

	var cell: Dictionary = _by_cell[Vector2i(cx, cy)]
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
		L.append(" [%d] layer=%s  glyph=%s" % [i, o.get("layer", "?"), _q(String(o.get("glyph", "")))])
		L.append("     tile     %s" % (_q(tile) if tile != "" else "(none)"))
		L.append("     png      %s" % _png_line(tile))
		L.append("     colour   color=%s tilecolor=%s detail=%s" % [
			_q(String(o.get("color", ""))), _q(String(o.get("tilecolor", ""))), _q(String(o.get("detail", "")))])
		L.append("     flags    wall=%d occluding=%d solid=%d bridge=%d sinks=%d" % [
			int(bool(o.get("wall", false))), int(bool(o.get("occluding", false))),
			int(bool(o.get("solid", false))), int(bool(o.get("bridge", false))),
			int(bool(o.get("sinks", false)))])
		if acts.has(i):
			for p in acts[i]:
				L.append("     RENDERED %s  y=%.3f" % [p["kind"], p["y"]])
		else:
			L.append("     RENDERED (nothing — object was dropped)")
	return "\n".join(L)

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
	_mark_pad.position = Vector3(cx, 0.30, cy)
	_mark_pin.position = Vector3(cx, 1.60, cy)
	_mark_pad.visible = true
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

func hide_panel() -> void:
	_panel.visible = false
	_mark_pad.visible = false
	_mark_pin.visible = false

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
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "SF Mono", "Monaco", "Courier New", "monospace"])
	_label.add_theme_font_override("normal_font", mono)
	_panel.add_child(_label)

func _build_marker() -> void:
	var pad := BoxMesh.new()
	pad.size = Vector3(1.0, 0.05, 1.0)
	_mark_pad = MeshInstance3D.new()
	_mark_pad.mesh = pad
	_mark_pad.material_override = _marker_material(Color(1.0, 0.95, 0.3, 0.45))
	_mark_pad.visible = false
	add_child(_mark_pad)

	# a pin so the selection stays findable behind walls / at a shallow pitch
	var pin := BoxMesh.new()
	pin.size = Vector3(0.07, 2.6, 0.07)
	_mark_pin = MeshInstance3D.new()
	_mark_pin.mesh = pin
	_mark_pin.material_override = _marker_material(Color(1.0, 0.95, 0.3, 0.9))
	_mark_pin.visible = false
	add_child(_mark_pin)

func _marker_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

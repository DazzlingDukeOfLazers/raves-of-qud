extends Node
class_name TileReport

## Lower-right panel for reporting how a tile SHOULD render.
##
## Some things can't be derived from Qud's data at all. A water wheel faces north
## and south, but its tile is `sw_waterwheel_1` — no `_ns` suffix, no blueprint
## flag, nothing to infer from. Someone has to say so. This is where they say it.
##
## Submitting writes one file per tile under
##   ~/Library/Application Support/RavesOfQud/reports/
## containing the full inspector report plus the verdict, so a collaborator can
## read the directory and see every outstanding complaint with its evidence
## already attached.

## Verdicts phrased as renderer outcomes, so a report maps onto something concrete.
const VERDICTS := [
	"— pick one —",
	"should be a WALL (solid 3D block)",
	"should be an ORIENTED PANEL running N–S",
	"should be an ORIENTED PANEL running E–W",
	"should be an UPRIGHT BILLBOARD sprite",
	"should be FLAT on the floor",
	"should be a WALKABLE DECK (bridge-like)",
	"should NOT be drawn at all",
	"wrong COLOUR",
	"wrong HEIGHT / scale",
	"wrong POSITION / offset",
	"drawn TWICE / duplicated",
	"other — see notes",
]

var _renderer: ZoneRenderer
var _panel: PanelContainer
var _target: Label
var _verdict: OptionButton
var _subject: OptionButton      # WHICH object in the tile the report is about
var _notes: TextEdit
var _status: Label

const FONT := 19          # matches the inspector's readable default
const PANEL_W := 520
const PANEL_H := 430

var _font := FONT
var _title: Label
var _send: Button

var _objects: Array = []

var _cx := -1
var _cy := -1
var _zone := ""
var _tile := ""
var _report := ""

func setup(renderer: ZoneRenderer) -> void:
	_renderer = renderer
	_build()

## Point the form at whatever was just inspected.
##
## `objects` arrives TOPMOST FIRST. A tile routinely holds several things — a
## water wheel standing in a puddle — so the subject is chosen explicitly rather
## than guessed. Defaulting to the top object is right far more often than
## defaulting to the last one in the array, which is what filed a verdict about a
## water wheel against the water underneath it.
func set_target(cx: int, cy: int, zone: String, objects: Array, report: String) -> void:
	_cx = cx
	_cy = cy
	_zone = zone
	_report = report
	_objects = objects

	_subject.clear()
	for o in objects:
		var nm := String(o.get("display", ""))
		if nm == "":
			nm = String(o.get("name", "?"))
		_subject.add_item("L%s  %s" % [str(o.get("layer", "?")), nm])
	if objects.is_empty():
		_subject.add_item("(nothing here)")
	_subject.selected = 0
	_sync_subject()

	_target.text = "tile (%d, %d)" % [cx, cy]
	_status.text = ""
	_panel.visible = true

func _sync_subject() -> void:
	_tile = ""
	if _subject.selected >= 0 and _subject.selected < _objects.size():
		_tile = String(_objects[_subject.selected].get("tile", ""))
	_status.text = "" if _tile == "" else _tile.replace("\\", "/").get_file()

func _submit() -> void:
	if _cx < 0:
		_status.text = "inspect a tile first"
		return
	if _verdict.selected <= 0 and _notes.text.strip_edges() == "":
		_status.text = "pick a verdict or write a note"
		return
	var dir := _reports_dir()
	if dir == "":
		_status.text = "no tiles dir yet — take a turn in Qud"
		return
	DirAccess.make_dir_recursive_absolute(dir)

	var verdict := _verdict.get_item_text(_verdict.selected) if _verdict.selected > 0 else "(none)"
	var body := PackedStringArray()
	body.append("# Tile report — (%d, %d)" % [_cx, _cy])
	body.append("")
	body.append("- **zone**: %s" % _zone)
	body.append("- **tile**: `%s`" % _tile)
	body.append("- **verdict**: %s" % verdict)
	body.append("- **filed**: %s" % Time.get_datetime_string_from_system())
	body.append("")
	body.append("## Notes")
	body.append(_notes.text.strip_edges() if _notes.text.strip_edges() != "" else "_(none)_")
	body.append("")
	body.append("## Inspector report at time of filing")
	body.append("```")
	body.append(_report)
	body.append("```")

	var path := dir.path_join(_filename())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status.text = "could not write %s" % path
		return
	f.store_string("\n".join(body) + "\n")
	f.close()
	_status.text = "filed -> reports/%s" % _filename()
	_notes.text = ""
	_verdict.selected = 0

## One file per tile per verdict, so re-filing the same complaint overwrites
## rather than piling up, but two different complaints about one tile coexist.
func _filename() -> String:
	var zone := _zone.replace(".", "-")
	var slug := "none" if _tile == "" else _tile.replace("\\", "/").get_file().get_basename()
	var v := "note" if _verdict.selected <= 0 else str(_verdict.selected)
	return "%s_%02d-%02d_%s_v%s.md" % [zone, _cx, _cy, slug, v]

func _reports_dir() -> String:
	if _renderer == null:
		return ""
	var base := _renderer.tiles_dir().get_base_dir()
	return "" if base == "" else base.path_join("reports")

func _build() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.offset_left = -(PANEL_W + 14)
	_panel.offset_top = -(PANEL_H + 14)
	_panel.offset_right = -14
	_panel.offset_bottom = -14
	_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.04, 0.94)
	style.border_color = Color(0.45, 0.85, 0.55, 0.9)
	style.set_border_width_all(1)
	style.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)

	_title = Label.new()
	_title.text = "Report this tile"
	_title.add_theme_color_override("font_color", Color(0.65, 0.95, 0.7))
	box.add_child(_title)

	_target = Label.new()
	_target.add_theme_color_override("font_color", Color(0.8, 0.9, 0.8))
	box.add_child(_target)

	_subject = OptionButton.new()
	_subject.item_selected.connect(func(_i): _sync_subject())
	box.add_child(_subject)

	_verdict = OptionButton.new()
	for v in VERDICTS:
		_verdict.add_item(v)
	_verdict.selected = 0
	box.add_child(_verdict)

	_notes = TextEdit.new()
	_notes.placeholder_text = "what's wrong, in your words…"
	_notes.custom_minimum_size = Vector2(0, 120)
	box.add_child(_notes)

	_send = Button.new()
	_send.text = "Submit report"
	_send.pressed.connect(_submit)
	box.add_child(_send)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.95, 0.85, 0.5))
	box.add_child(_status)

	_apply_font()

## Same '-' / '=' keys as the inspector, so both panels scale together rather
## than one being legible and the other not.
func nudge_font(delta: int) -> void:
	_font = clampi(_font + delta, 10, 40)
	_apply_font()

func _apply_font() -> void:
	for c in [_title, _target, _status]:
		c.add_theme_font_size_override("font_size", _font)
	for ob in [_verdict, _subject]:
		ob.add_theme_font_size_override("font_size", _font)
		# the dropdown is a separate PopupMenu and does not inherit the button's size
		var pop: PopupMenu = ob.get_popup()
		if pop != null:
			pop.add_theme_font_size_override("font_size", _font)
	_notes.add_theme_font_size_override("font_size", _font)
	_send.add_theme_font_size_override("font_size", _font)
	_notes.custom_minimum_size = Vector2(0, _font * 6)

func hide_panel() -> void:
	_panel.visible = false

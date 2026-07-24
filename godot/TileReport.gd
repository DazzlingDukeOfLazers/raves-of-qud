extends Node
class_name TileReport

## Lower-right panel for reporting how a tile SHOULD render.
##
## Some things can't be derived from Qud's data at all. A water wheel faces north
## and south, but its tile is `sw_waterwheel_1` — no `_ns` suffix, no blueprint
## flag, nothing to infer from. Someone has to say so. This is where they say it.
##
## Submitting routes by verdict type, because the two kinds have opposite lifecycles:
##
##   STANDING RULES (shape, fill) are CONFIG. They upsert into ONE file,
##     ~/Library/Application Support/RavesOfQud/overrides.json, keyed by tile family.
##     The renderer reads it live. Entries persist until changed or cleared.
##
##   ONE-OFF NOTES (colour, position, free text) are TICKETS. Each writes a dated
##     .md under reports/ with the full inspector capture attached. Delete when done.
##
## Splitting them fixes the trap where deleting a "resolved" ticket silently
## reverted the render — because the ticket WAS the override. Config and tickets
## now live in different places and can be cleaned up independently. "Clear rules"
## removes this tile's config; deleting a note leaves the render untouched.

## Verdicts phrased as renderer outcomes, so a report maps onto something concrete.
const VERDICTS := [
	"— pick one —",
	"should be a WALL (solid 3D block)",
	"ORIENTED PANEL running N–S (faces E/W)",
	"ORIENTED PANEL running E–W (faces N/S)",
	"should be an UPRIGHT BILLBOARD sprite",
	"should be FLAT on the floor",
	"should be a WALKABLE DECK (bridge-like)",
	"should NOT be drawn at all",
	"FILL: fill the holes with BACKGROUND",
	"FILL: only ENCLOSED holes (conservative)",
	"FILL: make TRANSPARENT (see through)",
	"FILL: solid OPAQUE block",
	"FILL: wrong — see notes",
	"POS: FLOAT centered in the tile",
	"POS: seat on the GROUND (default)",
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

var _font := FONT
var _title: Label
var _send: Button
var _cancel: Button
var _menu: MenuButton

## Emitted when the form is dismissed (Cancel), so the caller can also drop the
## inspector panel and the 3D selection marker.
signal dismissed

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

## Route by verdict type. A shape or fill verdict is a STANDING RULE and gets
## merged into overrides.json; anything else is a one-off note under reports/.
func _submit() -> void:
	if _cx < 0:
		_status.text = "inspect a tile first"
		return
	var verdict := _verdict.get_item_text(_verdict.selected) if _verdict.selected > 0 else ""
	var slot := _rule_slot(verdict)
	if slot != "":
		_upsert_override(slot, verdict)
	else:
		_write_note(verdict)

## Which overrides slot a verdict belongs in: "shape", "fill", or "" for a note.
func _rule_slot(verdict: String) -> String:
	var v := verdict.to_lower()
	if v.contains("pos:"):
		return "position"
	if v.contains("fill"):
		return "fill"
	for k in ["wall", "panel", "n–s", "e–w", "billboard", "flat", "not be drawn"]:
		if v.contains(k):
			return "shape"
	return ""

# --- standing rules: overrides.json -----------------------------------------

## Merge one rule into overrides.json under this tile's family, preserving the
## other slot, every other tile, and any hand edits (read-modify-write).
func _upsert_override(slot: String, verdict: String) -> void:
	if _tile == "":
		_status.text = "no tile to attach the rule to"
		return
	var path := _overrides_path()
	if path == "":
		_status.text = "no tiles dir yet — take a turn in Qud"
		return
	var data := _read_overrides(path)
	var fam := _renderer.tile_family(_tile)
	var tiles: Dictionary = data.get("tiles", {})
	var entry: Dictionary = tiles.get(fam, {})
	entry[slot] = verdict
	tiles[fam] = entry
	data["tiles"] = tiles
	_write_overrides(path, data)
	_status.text = "rule set: %s.%s (live next turn)" % [fam, slot]
	_verdict.selected = 0

## Drop THIS tile's standing rules — the undo for a bad verdict.
func _clear_override() -> void:
	if _tile == "":
		return
	var path := _overrides_path()
	if path == "":
		return
	var data := _read_overrides(path)
	var tiles: Dictionary = data.get("tiles", {})
	var fam := _renderer.tile_family(_tile)
	if tiles.has(fam):
		tiles.erase(fam)
		data["tiles"] = tiles
		_write_overrides(path, data)
		_status.text = "cleared rules for %s" % fam
	else:
		_status.text = "no rules on %s" % fam

func _overrides_path() -> String:
	if _renderer == null:
		return ""
	var base := _renderer.tiles_dir().get_base_dir()
	return "" if base == "" else base.path_join("overrides.json")

func _read_overrides(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"version": 1, "tiles": {}}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else {"version": 1, "tiles": {}}

func _write_overrides(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()

# --- one-off notes: reports/*.md --------------------------------------------

func _write_note(verdict: String) -> void:
	if verdict == "" and _notes.text.strip_edges() == "":
		_status.text = "pick a verdict or write a note"
		return
	var dir := _reports_dir()
	if dir == "":
		_status.text = "no tiles dir yet — take a turn in Qud"
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var body := PackedStringArray()
	body.append("# Tile note — (%d, %d)" % [_cx, _cy])
	body.append("")
	body.append("- **zone**: %s" % _zone)
	body.append("- **tile**: `%s`" % _tile)
	body.append("- **verdict**: %s" % (verdict if verdict != "" else "(note only)"))
	body.append("- **filed**: %s" % Time.get_datetime_string_from_system())
	body.append("")
	body.append("## Notes")
	body.append(_notes.text.strip_edges() if _notes.text.strip_edges() != "" else "_(none)_")
	body.append("")
	body.append("## Inspector report at time of filing")
	body.append("```")
	body.append(_report)
	body.append("```")
	var path := dir.path_join(_note_filename())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status.text = "could not write %s" % path
		return
	f.store_string("\n".join(body) + "\n")
	f.close()
	_status.text = "note filed -> reports/%s" % _note_filename()
	_notes.text = ""
	_verdict.selected = 0

func _note_filename() -> String:
	var zone := _zone.replace(".", "-")
	var slug := "none" if _tile == "" else _tile.replace("\\", "/").get_file().get_basename()
	return "%s_%02d-%02d_%s.md" % [zone, _cx, _cy, slug]

func _reports_dir() -> String:
	if _renderer == null:
		return ""
	var base := _renderer.tiles_dir().get_base_dir()
	return "" if base == "" else base.path_join("reports")

func _build() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_panel = PanelContainer.new()
	# Pin the BOTTOM-RIGHT corner and grow up/left to fit the content. The panel
	# used to be a fixed 520x430 box, so when the fonts and the extra controls made
	# the content taller than 430 it overflowed off the bottom — taking the Submit
	# button with it. Auto-height from a pinned bottom keeps the button on screen.
	_panel.anchor_left = 1.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_right = -14
	_panel.offset_bottom = -14
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.custom_minimum_size = Vector2(PANEL_W, 0)   # fixed width, height from content
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

	# header: title on the left, hamburger menu on the right
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	box.add_child(header)

	_title = Label.new()
	_title.text = "Report this tile"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_color_override("font_color", Color(0.65, 0.95, 0.7))
	header.add_child(_title)

	# Destructive/rare actions live in the hamburger, one deliberate click away —
	# NOT beside Submit, where "Clear rules" was easy to hit and wipes a tile's
	# standing config with no undo.
	_menu = MenuButton.new()
	_menu.text = "☰"
	_menu.flat = false
	var pop := _menu.get_popup()
	pop.add_item("Clear rules for this tile", 0)
	pop.add_item("Copy report to clipboard", 1)
	pop.id_pressed.connect(_on_menu)
	header.add_child(_menu)

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

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)

	_send = Button.new()
	_send.text = "Submit"
	_send.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_send.pressed.connect(_submit)
	row.add_child(_send)

	_cancel = Button.new()
	_cancel.text = "Cancel"
	_cancel.pressed.connect(_on_cancel)
	row.add_child(_cancel)

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
	_cancel.add_theme_font_size_override("font_size", _font)
	_menu.add_theme_font_size_override("font_size", _font)
	var mpop: PopupMenu = _menu.get_popup()
	if mpop != null:
		mpop.add_theme_font_size_override("font_size", _font)
	_notes.custom_minimum_size = Vector2(0, mini(_font * 5, 130))

## Dismiss the form without filing. Also tells the caller to clear the selection
## (marker + inspector panel), since "cancel" means "never mind this tile".
func _on_cancel() -> void:
	_notes.text = ""
	_verdict.selected = 0
	hide_panel()
	dismissed.emit()

func _on_menu(id: int) -> void:
	match id:
		0: _clear_override()
		1:
			if _report != "":
				DisplayServer.clipboard_set(_report)
				_status.text = "report copied to clipboard"

func hide_panel() -> void:
	_panel.visible = false

extends CanvasLayer
class_name CharacterCreator

## "Become anything" menu: browse the blueprint catalog the mod dumps to
## become_catalog.json and turn the player INTO the picked blueprint — creature,
## item, weapon, food, implant, or furniture. Yes, you can become an immobile
## dresser; that's the point. Toggle with B (see Main._unhandled_input).
##
## Wiring: Main sets `client` and calls `toggle(base_dir)` where base_dir is the
## RavesOfQud support dir (renderer.tiles_dir().get_base_dir()). We ask the mod to
## (re)write the catalog over the bridge, then read the JSON file it drops there.

const CATEGORIES := ["creatures", "weapons", "food", "items", "implants", "furniture"]

var client: BridgeClient

var _panel: PanelContainer
var _cat_btn: OptionButton
var _filter: LineEdit
var _list: ItemList
var _status: Label
var _base_dir := ""
var _catalog := {}          # category -> Array[String] of blueprint ids
var _reload_accum := -1.0   # >=0 while a refresh is pending; counts up to RELOAD_DELAY
const RELOAD_DELAY := 0.6   # let the mod write become_catalog.json before we read it

func _ready() -> void:
	layer = 3
	_build_ui()
	visible = false

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(360, 460)
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	var title := Label.new()
	title.text = "Become anything  (B to close)"
	vb.add_child(title)

	_cat_btn = OptionButton.new()
	_cat_btn.focus_mode = Control.FOCUS_NONE
	for c in CATEGORIES:
		_cat_btn.add_item(String(c))
	_cat_btn.item_selected.connect(func(_i): _repopulate())
	vb.add_child(_cat_btn)

	_filter = LineEdit.new()
	_filter.placeholder_text = "filter…"
	_filter.text_changed.connect(func(_t): _repopulate())
	vb.add_child(_filter)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 320)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(_on_item_activated)
	vb.add_child(_list)

	var row := HBoxContainer.new()
	vb.add_child(row)
	var become_btn := Button.new()
	become_btn.text = "Become"
	become_btn.focus_mode = Control.FOCUS_NONE
	become_btn.pressed.connect(_become_selected)
	row.add_child(become_btn)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh catalog"
	refresh_btn.focus_mode = Control.FOCUS_NONE
	refresh_btn.pressed.connect(_request_catalog)
	row.add_child(refresh_btn)

	_status = Label.new()
	_status.text = ""
	vb.add_child(_status)

func toggle(base_dir: String) -> void:
	_base_dir = base_dir
	visible = not visible
	if visible:
		if _catalog.is_empty():
			if not _load_catalog_file():
				_request_catalog()   # no file yet — ask the mod to write one
		_repopulate()
		_filter.grab_focus()

func _request_catalog() -> void:
	if client == null:
		_status.text = "no bridge connection"
		return
	client.send_command("catalog", {})
	_status.text = "requested catalog…"
	_reload_accum = 0.0   # arm the deferred file read in _process

func _process(dt: float) -> void:
	if _reload_accum < 0.0:
		return
	_reload_accum += dt
	if _reload_accum >= RELOAD_DELAY:
		_reload_accum = -1.0
		if _load_catalog_file():
			_repopulate()
			_status.text = "catalog loaded"
		else:
			_status.text = "catalog not found at %s" % _catalog_path()

func _catalog_path() -> String:
	if _base_dir == "":
		return ""
	return _base_dir.path_join("become_catalog.json")

func _load_catalog_file() -> bool:
	var path := _catalog_path()
	if path == "" or not FileAccess.file_exists(path):
		return false
	var txt := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY:
		return false
	_catalog = data
	return true

func _repopulate() -> void:
	_list.clear()
	var cat_idx := _cat_btn.selected if _cat_btn.selected >= 0 else 0
	var cat := String(CATEGORIES[cat_idx])
	var names: Variant = _catalog.get(cat, [])
	if typeof(names) != TYPE_ARRAY:
		return
	var needle := _filter.text.to_lower()
	var shown := 0
	for n in names:
		var name_str := String(n)
		if needle != "" and not name_str.to_lower().contains(needle):
			continue
		_list.add_item(name_str)
		shown += 1
	_status.text = "%d / %d %s" % [shown, (names as Array).size(), cat]

func _on_item_activated(_index: int) -> void:
	_become_selected()

func _become_selected() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		_status.text = "pick a blueprint first"
		return
	var bp := _list.get_item_text(sel[0])
	if client == null:
		_status.text = "no bridge connection"
		return
	client.send_command("become", {"bp": bp})
	_status.text = "became %s — move/wait to refresh" % bp
	visible = false

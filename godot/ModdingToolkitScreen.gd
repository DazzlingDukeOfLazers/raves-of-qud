extends Control

## THE MODDING TOOLKIT SCREEN — a 1:1 mimic of Caves of Qud's "Modding Toolkit" menu
## (title screen › secondary links › Modding Toolkit).
##
## Qud draws a compact console-style box centred on a heavily dimmed background: a small
## plant ornament over the top edge, a "┤ Modding Toolkit ├" gold title, nine rows
## (Mod Manager … Waveform Collapse Map Generator) — the selected row gets a teal
## highlight bar and a gold ">" caret — and a "┤ [Esc] Back ├" footer set into the bottom
## border. Measured off a 3840x2160 Lumpy capture of Qud 1.0.5 (2026-08-06, session
## scratchpad qud_mt2.png): box ~710x708 px at 4K (355x354 at 1080p), slightly above
## window centre.
##
## Items are COSMETIC for now (the mimic phase, like Records was) — Esc/Back closes.
## Opened as an overlay by MainMenu; `closed` fires on Esc. UiState scene:
## "modding_toolkit" (set by MainMenu._open_overlay via to_snake_case).

signal closed

## Ask MainMenu to swap this overlay for a tool screen ("mod_manager" today;
## deep tools as they're built). Emitted instead of opening screens directly so
## MainMenu keeps sole ownership of the overlay slot + UiState scene reporting.
signal open_tool(tool_id: String)

## highvisor scene name (read by MainMenu._open_overlay; matches the gametree's
## title>modding_toolkit raves detect).
var ui_scene := "modding_toolkit"

# palette — sampled off the reference capture
const SCRIM := Color(0.01, 0.02, 0.02, 0.90)     # near-black dim over the art behind
const PANEL := Color8(0x0E, 0x3F, 0x3A)          # box interior — saturated dark teal
const BORDER := Color8(0x5B, 0x8A, 0x84)         # thin light-teal frame lines
const TITLE_GOLD := Color8(0xE8, 0xD4, 0x4D)     # "Modding Toolkit" + selected caret
const ITEM := Color8(0x7F, 0xC0, 0xBA)           # unselected item text — light cyan
const ITEM_SEL := Color8(0xE9, 0xF2, 0xF0)       # selected item text — near-white
const BAR := Color8(0x1D, 0x5A, 0x52)            # selected-row highlight bar
const HINT_DIM := Color8(0x8F, 0xA6, 0x9E)       # "Back" footer text

## Qud's item list, verbatim (Qud.UI.ModToolkit), with each item's Raves action:
## "tool:<id>" hands off to MainMenu (open_tool), "url:"/"dir:" shell-opens like
## Qud does, "" stays cosmetic until its screen exists.
const ITEMS := [
	{"text": "Mod Manager", "act": "tool:mod_manager"},
	{"text": "Workshop Uploader", "act": ""},
	{"text": "Map Editor", "act": ""},
	{"text": "Mod Wiki Website", "act": "url:https://wiki.cavesofqud.com/wiki/Modding:Overview"},
	{"text": "Blueprint Browser", "act": ""},
	{"text": "Open Save Folder", "act": "dir:qud_data"},
	{"text": "Write Mods.csproj File", "act": ""},
	{"text": "Histographicnomicon", "act": ""},
	{"text": "Waveform Collapse Map Generator", "act": ""},
]

## Qud's toolkit menu is LEGACY-CONSOLE styled — its glyphs are the console mono
## (Source Code Pro), not ElliotSans. Sizes measured off the 1920x1080 reference
## capture (~29px row pitch).
const FONT_REG := "res://fonts/SourceCodePro-Regular.ttf"
const FONT_SEMI := "res://fonts/SourceCodePro-Semibold.ttf"
## 18px: Qud's longest row ("Waveform Collapse Map Generator", 31 glyphs) spans
## ~333px in the 1080p reference → ~10.7px/glyph → SCP (0.6em advance) at 18.
const ITEM_PX := 18
const TITLE_PX := 21

## Box geometry, fractions of window HEIGHT (Qud's canvas scaler) — measured off the capture:
## 708px tall on 2160 ⇒ 0.328; aspect 710/708 ⇒ ~1.0; centre-line sits ~0.49 of the window.
const BOX_H_FRAC := 0.328
const BOX_ASPECT := 1.003
const BOX_CY := 0.49

var _sel := 0
var _rows: Array = []      # [{bar, caret, lbl}]
var _box: Control

func _ready() -> void:
	name = "ModdingToolkitScreen"
	_fit_to_viewport()   # runtime overlay: the parent doesn't propagate size (ModsScreen gotcha)
	theme = UiFont.make_theme(get_viewport())
	# Qud draws menu text on NO background — clear the Label panel styleboxes (the same
	# de-banding MainMenu applies in 1:1 mode) so rows read as plain text over the box.
	var empty := StyleBoxEmpty.new()
	for tt in ["Label", "Caption", "Title", "Big"]:
		theme.set_stylebox("normal", tt, empty)
	get_viewport().size_changed.connect(_relayout)

	var scrim := ColorRect.new()
	scrim.color = SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP   # modal: swallow clicks to the menu behind
	add_child(scrim)

	_box = Control.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)
	_build_box()
	_relayout()
	_apply_selection()

## Fill the whole viewport explicitly — as an added-at-runtime overlay we can't rely on the
## parent propagating its size (same rule as ModsScreen), so size to the viewport on resize.
func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

func _relayout() -> void:
	_fit_to_viewport()
	if _box == null:
		return
	UiFont.refresh_theme(theme, get_viewport())
	var vh := get_viewport().get_visible_rect().size.y
	var bh := vh * BOX_H_FRAC
	var bw := bh * BOX_ASPECT
	_box.anchor_left = 0.5
	_box.anchor_right = 0.5
	_box.anchor_top = BOX_CY
	_box.anchor_bottom = BOX_CY
	_box.offset_left = -bw * 0.5
	_box.offset_right = bw * 0.5
	_box.offset_top = -bh * 0.5
	_box.offset_bottom = bh * 0.5

## The console-style box: teal panel, thin border, gold title row, the item rows, and the
## footer set into the bottom edge. All children are fraction-anchored to the box.
func _build_box() -> void:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(2)
	sb.border_color = BORDER
	sb.set_corner_radius_all(0)
	panel.add_theme_stylebox_override("panel", sb)
	_box.add_child(panel)

	# title: "┤ Modding Toolkit ├" — gold, centred near the top
	var title := Label.new()
	title.text = "┤ Modding Toolkit ├"
	title.add_theme_font_override("font", load(FONT_SEMI))
	title.add_theme_font_size_override("font_size", TITLE_PX)
	title.add_theme_color_override("font_color", TITLE_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.045
	title.anchor_bottom = 0.135
	for k in ["left", "top", "right", "bottom"]:
		title.set("offset_" + k, 0.0)
	_box.add_child(title)

	# the item rows — a VBox spanning the box interior below the title
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 0)
	v.anchor_left = 0.03
	v.anchor_right = 0.97
	v.anchor_top = 0.155
	v.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		v.set("offset_" + k, 0.0)
	for i in range(ITEMS.size()):
		v.add_child(_build_row(i))
	_box.add_child(v)

	# footer: "┤ [Esc] Back ├" sitting ON the bottom border line, centred
	var foot := RichTextLabel.new()
	foot.bbcode_enabled = true
	foot.fit_content = true
	foot.scroll_active = false
	foot.autowrap_mode = TextServer.AUTOWRAP_OFF
	foot.add_theme_font_override("normal_font", load(FONT_REG))
	foot.add_theme_font_size_override("normal_font_size", ITEM_PX - 2)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gold := "#%s" % TITLE_GOLD.to_html(false)
	var dim := "#%s" % HINT_DIM.to_html(false)
	foot.text = "[center][color=%s]┤ [/color][color=%s][lb]Esc[rb][/color][color=%s] Back ├[/color][/center]" % [dim, gold, dim]
	foot.anchor_left = 0.0
	foot.anchor_right = 1.0
	foot.anchor_top = 0.955
	foot.anchor_bottom = 1.045
	for k in ["left", "top", "right", "bottom"]:
		foot.set("offset_" + k, 0.0)
	_box.add_child(foot)

## One item row: [highlight bar] under [gold caret][label]. The caret keeps its slot in every
## row (transparent when unselected) so text never shifts as the selection moves — the same
## no-reflow trick as the quit dialog's Yes/No cells.
func _build_row(idx: int) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, 1)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	var bar := ColorRect.new()
	bar.color = Color(0, 0, 0, 0)
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var caret := Label.new()
	caret.text = "> "
	caret.add_theme_font_override("font", load(FONT_REG))
	caret.add_theme_font_size_override("font_size", ITEM_PX)
	caret.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	caret.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(caret)
	var lbl := Label.new()
	lbl.text = ITEMS[idx]["text"]
	lbl.add_theme_font_override("font", load(FONT_REG))
	lbl.add_theme_font_size_override("font_size", ITEM_PX)
	lbl.add_theme_color_override("font_color", ITEM)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(lbl)
	row.add_child(h)
	row.mouse_entered.connect(func(): _select(idx))
	row.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select(idx)
			_activate())
	_rows.append({"bar": bar, "caret": caret, "lbl": lbl})
	return row

func _select(idx: int) -> void:
	if idx == _sel or idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	for i in range(_rows.size()):
		var on: bool = (i == _sel)
		_rows[i]["bar"].color = BAR if on else Color(0, 0, 0, 0)
		_rows[i]["caret"].add_theme_color_override("font_color", TITLE_GOLD if on else Color(0, 0, 0, 0))
		_rows[i]["lbl"].add_theme_color_override("font_color", ITEM_SEL if on else ITEM)

func _activate() -> void:
	var act := str(ITEMS[_sel]["act"])
	if act == "":
		return   # deep tool without a Raves screen yet — cosmetic, like Qud items we haven't built
	if act.begins_with("tool:"):
		open_tool.emit(act.trim_prefix("tool:"))   # MainMenu swaps the overlay
	elif act.begins_with("url:"):
		OS.shell_open(act.trim_prefix("url:"))     # external, matching Qud's own behaviour
	elif act == "dir:qud_data":
		OS.shell_open(_qud_data_dir())

## Caves of Qud's data folder — the same folder Qud's "Open Save Folder" opens.
func _qud_data_dir() -> String:
	if OS.get_name() == "Windows":
		return OS.get_environment("USERPROFILE").path_join(
			"AppData/LocalLow/Freehold Games/CavesOfQud")
	return OS.get_environment("HOME").path_join(
		"Library/Application Support/com.FreeholdGames.CavesOfQud")

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_down"):
		_select((_sel + 1) % ITEMS.size())
		accept_event()
	elif e.is_action_pressed("ui_up"):
		_select((_sel - 1 + ITEMS.size()) % ITEMS.size())
		accept_event()
	elif e.is_action_pressed("ui_accept"):
		_activate()
		accept_event()
	elif e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()

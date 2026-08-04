extends Control

## THE RECORDS SCREEN — a 1:1-styled mimic of Caves of Qud's "Records" (High Scores).
##
## Qud's title-menu "Records" (command "Pick:High Scores") shows the scoreboard: a score-sorted
## list of past-character game summaries (XRL.Core.Scoreboard2 -> HighScores.json). The bridge mod
## (RecordsExporter) copies the player's OWN HighScores.json to records.json; this screen reads it
## and renders, Qud-style: a woven gold frame over the cave-art, a titled header, a LEFT list of
## past runs (score, name, level, turns, mode) and a RIGHT panel with the full game summary (the
## `Details` text, with Qud {{colour|...}} markup rendered), plus a Back footer.
##
## Schema (Qud's own, copied verbatim by RecordsExporter):
##   { "Scores": [ { "Score":int, "Details":str(markup), "Turns":int, "GameId":str,
##                   "GameMode":str, "Name":str, "Level":int, "Version":int }, ... ] }
##
## Opened as an overlay by MainMenu (over the menu box); `closed` fires when Back is chosen.

signal closed

# palette — measured off Qud's screens (shared with ModsScreen)
const FRAME := Color8(0xB6, 0xA1, 0x63)          # woven gold border
const PANEL := Color(0.055, 0.078, 0.078, 0.96)  # dark weave interior
const SCRIM := Color(0.02, 0.03, 0.03, 0.55)     # dims the menu/bg behind
const TITLE := Color8(0xF0, 0xEA, 0xD8)          # character name
const LABEL := Color8(0x6E, 0xB5, 0xC9)          # "Level:" / "Turns:" / "Mode:"
const VALUE := Color8(0xC9, 0xC2, 0xA8)          # field values
const SCORE := Color8(0xC8, 0xA9, 0x4E)          # the big score number
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # header title, keycaps
const DIM := Color(0.89, 0.85, 0.72, 0.5)

# Qud's 16-colour palette for rendering the summary's {{code|text}} markup (baked so the summary
# reads in-colour at the title menu, where there's no live snapshot palette). Same values as
# ZoneRenderer.COLORS; converted to the hex map QudText.to_bbcode wants in _ready.
const QUD_COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),
}

const SIDE_W_FRAC := 0.016    # border thickness as a fraction of the panel
const BAR_H_FRAC := 0.022

var _records: Array = []
var _sel := 0
var _rows: Array = []          # [{panel, rec}]
var _list: VBoxContainer       # the records-list column (rebuilt on refresh)
var _summary: RichTextLabel    # the right-hand full game-summary
var _palette := {}             # code -> hex, for QudText.to_bbcode
# Auto-refresh-on-open: when the bridge connects, ask Qud to re-export the records and reload them.
var _peer := StreamPeerTCP.new()
var _refreshed := false
var _records_mtime := 0
var _reload_deadline := 0

func _ready() -> void:
	name = "RecordsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	for code in QUD_COLORS:
		_palette[code] = "#" + Color(QUD_COLORS[code]).to_html(false)
	_records = _load_records()

	if Settings.one_to_one():
		_build_1to1()
	else:
		var scrim := ColorRect.new()
		scrim.color = SCRIM
		scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		scrim.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks to the menu behind
		add_child(scrim)

		var frame := Control.new()          # the window panel, inset from the screen edges
		frame.anchor_left = 0.035
		frame.anchor_right = 0.965
		frame.anchor_top = 0.05
		frame.anchor_bottom = 0.95
		for k in ["left", "top", "right", "bottom"]:
			frame.set("offset_" + k, 0.0)
		add_child(frame)
		_build_frame(frame)
		_build_header(frame)
		_build_body(frame)
		_build_footer(frame)
		_apply_selection()
		_add_back()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())   # for the live re-export on open

## Auto-refresh on open: once the bridge is up, ask Qud to re-export its records, then reload
## records.json when it's rewritten so the screen shows the LIVE scoreboard (not the last export).
func _process(_dt: float) -> void:
	_peer.poll()
	var connected := _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if connected and not _refreshed:
		_refreshed = true
		_records_mtime = _records_json_mtime()
		_send_bridge({"type": "command", "name": "export"})
		_reload_deadline = Time.get_ticks_msec() + 1200   # fallback if the mtime second doesn't tick
	elif _refreshed and _reload_deadline > 0:
		if _records_json_mtime() > _records_mtime or Time.get_ticks_msec() >= _reload_deadline:
			_reload_deadline = 0
			_reload_records()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

## records.json modified time (seconds); 0 if absent. Detects Qud rewriting it after our `export`.
func _records_json_mtime() -> int:
	var path := InputModel.support_dir().path_join("records.json")
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0

## Frame + send one bridge message ([4-byte BE len][JSON]). No-op unless Qud is connected.
func _send_bridge(msg: Dictionary) -> void:
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## Reload the records from disk and rebuild the left column, preserving the selection if possible.
func _reload_records() -> void:
	_records = _load_records()
	if Settings.one_to_one():
		if _list_1to1 == null:
			return
		_populate_1to1()
	else:
		if _list == null:
			return
		_populate_records()
	_sel = clampi(_sel, 0, maxi(0, _records.size() - 1))
	_apply_selection()

## A clickable "‹ Back" at a fixed bottom-left spot (Esc also works) — the mouse route back to
## the menu, and a stable target for the regression suite's reset step.
func _add_back() -> void:
	var b := Button.new()
	b.text = "‹ Back"
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_color_override("font_color", GOLD)
	b.add_theme_color_override("font_hover_color", TITLE)
	b.anchor_left = 0.02
	b.anchor_right = 0.14
	b.anchor_top = 0.93
	b.anchor_bottom = 0.985
	for k in ["left", "top", "right", "bottom"]:
		b.set("offset_" + k, 0.0)
	b.pressed.connect(func(): closed.emit())
	add_child(b)

## Fill the whole viewport explicitly — as an added-at-runtime overlay we can't rely on the
## parent propagating its size, so we anchor top-left and size to the viewport (and on resize).
func _fit_to_viewport() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

# ── data ───────────────────────────────────────────────────────────────────────

func _load_records() -> Array:
	var path := InputModel.support_dir().path_join("records.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary and data.has("Scores") and data["Scores"] is Array):
		return []
	var scores: Array = (data["Scores"] as Array).duplicate()
	# Qud's Records is score-sorted, highest first; the on-disk order isn't guaranteed, so sort here.
	scores.sort_custom(func(a, b): return int(a.get("Score", 0)) > int(b.get("Score", 0)))
	return scores

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

# ── frame (reuse Qud's woven gold border + weave panel) ──────────────────────────

func _build_frame(frame: Control) -> void:
	var bg_tex := _chrome("panelBgTile.png")
	if bg_tex != null:
		var bg := _edge(bg_tex, TextureRect.STRETCH_TILE, 0.0, 0.0, 1.0, 1.0)
		bg.modulate = Color(1, 1, 1, 0.98)
		frame.add_child(bg)
	else:
		var flat := ColorRect.new()
		flat.color = PANEL
		flat.set_anchors_preset(Control.PRESET_FULL_RECT)
		flat.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(flat)
	var side := _chrome("borderSide.png")
	var bar := _chrome("borderBot.png")
	if side != null:
		frame.add_child(_edge(side, TextureRect.STRETCH_SCALE, 0.0, 0.0, SIDE_W_FRAC, 1.0))
		var r := _edge(side, TextureRect.STRETCH_SCALE, 1.0 - SIDE_W_FRAC, 0.0, 1.0, 1.0)
		r.flip_h = true
		frame.add_child(r)
	if bar != null:
		var top := _edge(bar, TextureRect.STRETCH_SCALE, 0.0, 0.0, 1.0, BAR_H_FRAC)
		top.flip_v = true
		frame.add_child(top)
		frame.add_child(_edge(bar, TextureRect.STRETCH_SCALE, 0.0, 1.0 - BAR_H_FRAC, 1.0, 1.0))
	if side == null and bar == null:   # no extracted sprites — flat gold outline
		var ol := Panel.new()
		ol.set_anchors_preset(Control.PRESET_FULL_RECT)
		ol.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.set_border_width_all(2)
		sb.border_color = FRAME
		ol.add_theme_stylebox_override("panel", sb)
		frame.add_child(ol)

func _edge(tex: Texture2D, mode: int, al: float, at: float, ar: float, ab: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = mode
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.anchor_left = al
	r.anchor_top = at
	r.anchor_right = ar
	r.anchor_bottom = ab
	for k in ["left", "top", "right", "bottom"]:
		r.set("offset_" + k, 0.0)
	return r

# ── header / body / footer ───────────────────────────────────────────────────────

func _build_header(frame: Control) -> void:
	var l := Label.new()
	l.text = "◈  Records  ◈"
	l.theme_type_variation = "Title"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", GOLD)
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.02
	l.anchor_bottom = 0.09
	for k in ["left", "top", "right", "bottom"]:
		l.set("offset_" + k, 0.0)
	frame.add_child(l)

func _build_body(frame: Control) -> void:
	# LEFT: scrollable score list
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0.03
	scroll.anchor_right = 0.46
	scroll.anchor_top = 0.11
	scroll.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		scroll.set("offset_" + k, 0.0)
	frame.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	_populate_records()

	# RIGHT: the full game summary for the selected run
	var pb := StyleBoxFlat.new()
	pb.bg_color = Color(0, 0, 0, 0.35)
	pb.set_border_width_all(1)
	pb.border_color = FRAME
	pb.set_content_margin_all(14)
	var pw := PanelContainer.new()
	pw.add_theme_stylebox_override("panel", pb)
	pw.anchor_left = 0.48
	pw.anchor_right = 0.97
	pw.anchor_top = 0.11
	pw.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		pw.set("offset_" + k, 0.0)
	frame.add_child(pw)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pw.add_child(sc)
	_summary = RichTextLabel.new()
	_summary.bbcode_enabled = true
	_summary.fit_content = true
	_summary.scroll_active = false
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.add_theme_color_override("default_color", VALUE)
	sc.add_child(_summary)

## Fill _list with a row per record (or an empty note). Split out of _build_body so a live refresh
## after the bridge re-export can clear + rebuild the column without rebuilding the whole window.
func _populate_records() -> void:
	_rows.clear()
	for c in _list.get_children():
		c.queue_free()
	if _records.is_empty():
		var empty := _text("No records yet. Finish a game in Caves of Qud (with Raves connected) to populate the scoreboard.", VALUE, "body")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
	for i in range(_records.size()):
		var row := _record_row(_records[i], i)
		_list.add_child(row)
		_rows.append({"panel": row, "rec": _records[i]})

func _record_row(rec: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 8)
	panel.add_child(pad)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	pad.add_child(v)

	# rank + score (prominent) + character name
	var name_str := str(rec.get("Name", "—"))
	var head := _rich("[color=#%s]%d.[/color]  [color=#%s]%s[/color]   [color=#%s]%s[/color]" % [
		DIM.to_html(false), idx + 1,
		SCORE.to_html(false), _commas(int(rec.get("Score", 0))),
		TITLE.to_html(false), _esc(name_str)], "title")
	v.add_child(head)
	# level / turns / mode
	var meta := _rich("[color=#%s]Level[/color] [color=#%s]%d[/color]    [color=#%s]Turns[/color] [color=#%s]%s[/color]    [color=#%s]%s[/color]" % [
		LABEL.to_html(false), VALUE.to_html(false), int(rec.get("Level", 0)),
		LABEL.to_html(false), VALUE.to_html(false), _commas(int(rec.get("Turns", 0))),
		LABEL.to_html(false), _esc(str(rec.get("GameMode", "—")))], "caption")
	v.add_child(meta)

	_style_row(panel, false)
	return panel

func _build_footer(frame: Control) -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = "[center][color=#%s][lb]Esc[rb][/color][color=#%s] Back      [/color][color=#%s]↑↓[/color][color=#%s] navigate[/color][/center]" % [
		GOLD.to_html(false), DIM.to_html(false), GOLD.to_html(false), DIM.to_html(false)]
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 0.92
	l.anchor_bottom = 0.98
	for k in ["left", "top", "right", "bottom"]:
		l.set("offset_" + k, 0.0)
	frame.add_child(l)

# ── selection + input ────────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _apply_selection() -> void:
	if Settings.one_to_one():
		for i in range(_rows.size()):
			_style_entry_1to1(_rows[i]["panel"], i == _sel)
		return
	for i in range(_rows.size()):
		_style_row(_rows[i]["panel"], i == _sel)
	if _summary == null:
		return
	if _sel >= 0 and _sel < _records.size():
		var details := str(_records[_sel].get("Details", ""))
		_summary.text = QudText.to_bbcode(details, _palette)
	else:
		_summary.text = ""

func _style_row(panel: PanelContainer, on: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.90, 0.86, 0.72, 0.10) if on else Color(1, 1, 1, 0.02)
	sb.set_corner_radius_all(2)
	sb.border_width_left = 3 if on else 0
	sb.border_color = GOLD
	panel.add_theme_stylebox_override("panel", sb)

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()
	elif e.is_action_pressed("ui_down"):
		_select(mini(_sel + 1, _rows.size() - 1)); accept_event()
	elif e.is_action_pressed("ui_up"):
		_select(maxi(_sel - 1, 0)); accept_event()

# ── small helpers ──────────────────────────────────────────────────────────────

# ── 1:1 build — Qud's ENDED RUNS screen, reproduced from measurement ────────────
# Bare flat background (no gilded panel): a dotted rail divider with end caps, the
# right-aligned rail list, the entry stack with a persistent dither-highlighted
# selection (+ > cursor + per-entry delete label), dotted separators, a 10px
# scroll track, the left [Esc] Back chevron, and the bottom hint.

## Raves' 2D canvas renders mid-tones ~x0.885 darker than specified (a pipeline
## gamma the 3D playfield never hit because its colours were tuned empirically).
## _q() pre-compensates so the CAPTURED pixels land on Qud's measured values.
static func _q(r8: int, g8: int, b8: int) -> Color:
	# channels <= 20 render ~faithfully already (the pipeline's curve flattens near
	# black); scaling them overshoots, so only compensate above that
	var f := func(v: int) -> int: return v if v <= 20 else mini(255, int(round(v * 1.13)))
	return Color8(f.call(r8), f.call(g8), f.call(b8))

var R_BG := _q(6, 44, 42)
var R_LINE := _q(58, 89, 101)
var R_TRACK := _q(29, 41, 46)
var R_GOLD := _q(200, 184, 57)
var R_CYAN_SEL := _q(108, 183, 200)
var R_CYAN := _q(56, 154, 176)
var R_BODY_SEL := _q(168, 194, 187)
var R_BODY_DIM := _q(21, 73, 72)
var R_CURSOR := _q(197, 207, 207)
const R_ENTRY_PITCH := 126
const R_ENTRY_H := 104
const RAIL_ITEMS := ["Ended Runs", "Daily (global)", "Daily (friends)", "Achievements"]

var _list_1to1: VBoxContainer
var _scrollbar_1to1: Control
var _scroll_1to1: ScrollContainer

func _build_1to1() -> void:
	var bg := ColorRect.new()
	bg.color = R_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# dotted rail divider (x331, y25..1054, 5-on/1-off) with square end caps
	var div := Control.new()
	div.set_anchors_preset(Control.PRESET_FULL_RECT)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	div.draw.connect(func():
		var y := 25.0
		while y < 1054.0:
			div.draw_rect(Rect2(331, y, 1, minf(5, 1054 - y)), R_LINE)
			y += 6.0
		for cy in [25.0, 1049.0]:
			div.draw_rect(Rect2(328, cy, 7, 6), _q(53, 90, 98)))
	add_child(div)

	# title
	var title := Label.new()
	title.text = "ENDED RUNS"
	title.add_theme_color_override("font_color", R_GOLD)
	var fv := FontVariation.new()
	fv.base_font = get_theme_font("font", "Label")
	fv.spacing_glyph = 3
	title.add_theme_font_override("font", fv)
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(347, 96)
	add_child(title)

	# rail (right-aligned, with small square markers right of each item)
	for i in range(RAIL_ITEMS.size()):
		var l := Label.new()
		l.text = RAIL_ITEMS[i]
		l.add_theme_color_override("font_color", R_CYAN_SEL)
		l.add_theme_font_size_override("font_size", 16)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.position = Vector2(60, 191 + i * 30)
		l.size = Vector2(236, 22)
		add_child(l)
		var dot := ColorRect.new()
		dot.color = R_LINE
		dot.position = Vector2(302, 198 + i * 30)
		dot.size = Vector2(5, 5)
		add_child(dot)

	# entry stack in a scroller
	_scroll_1to1 = ScrollContainer.new()
	_scroll_1to1.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_1to1.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll_1to1.position = Vector2(340, 144)
	_scroll_1to1.size = Vector2(1270, 861)
	add_child(_scroll_1to1)
	_list_1to1 = VBoxContainer.new()
	_list_1to1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_1to1.add_theme_constant_override("separation", 0)
	_scroll_1to1.add_child(_list_1to1)
	_populate_1to1()

	# scroll track (10px, x1616..1626, y135..1010) synced to the scroller
	_scrollbar_1to1 = Control.new()
	_scrollbar_1to1.position = Vector2(1616, 135)
	_scrollbar_1to1.size = Vector2(10, 875)
	_scrollbar_1to1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrollbar_1to1.draw.connect(func():
		var sb := _scrollbar_1to1
		sb.draw_rect(Rect2(0, 0, 10, sb.size.y), R_TRACK)
		var vsb := _scroll_1to1.get_v_scroll_bar()
		var content := maxf(1.0, float(vsb.max_value))
		var vis := float(vsb.page) if vsb.page > 0 else _scroll_1to1.size.y
		var frac := clampf(vis / content, 0.05, 1.0)
		var pos := 0.0
		if content > vis:
			pos = float(vsb.value) / (content - vis)
		var th := sb.size.y * frac
		sb.draw_rect(Rect2(0, (sb.size.y - th) * pos, 10, th), R_LINE))
	add_child(_scrollbar_1to1)
	_scroll_1to1.get_v_scroll_bar().value_changed.connect(func(_v): _scrollbar_1to1.queue_redraw())

	# [Esc] Back chevron, left mid-screen (clickable)
	var back := Control.new()
	back.position = Vector2(30, 520)
	back.size = Vector2(110, 75)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	back.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: closed.emit())
	back.draw.connect(func():
		back.draw_line(Vector2(48, 12), Vector2(36, 24), _q(120, 140, 138), 3.0)
		back.draw_line(Vector2(36, 24), Vector2(48, 36), _q(120, 140, 138), 3.0))
	add_child(back)
	var bl := RichTextLabel.new()
	bl.bbcode_enabled = true
	bl.fit_content = true
	bl.scroll_active = false
	bl.autowrap_mode = TextServer.AUTOWRAP_OFF
	bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl.add_theme_font_size_override("normal_font_size", 16)
	bl.text = "[color=#%s][lb]Esc[rb][/color][color=#%s] Back[/color]" % [
		R_GOLD.to_html(false), R_BODY_SEL.to_html(false)]
	bl.position = Vector2(4, 48)
	back.add_child(bl)

	# bottom hint: [icon] navigate  [Space] select
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.scroll_active = false
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override("normal_font_size", 16)
	var wht := "#FFFFFF"
	var dimc := "#%s" % R_BODY_SEL.to_html(false)
	var goldc := "#%s" % R_GOLD.to_html(false)
	hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	hint.append_text("[color=%s][lb][/color]" % wht)
	hint.add_image(_records_nav_icon(15), 22, 15)
	hint.append_text("[color=%s][rb][/color]" % wht)
	hint.append_text("[color=%s] navigate  [/color]" % dimc)
	hint.append_text("[color=%s][lb][/color][color=%s]Space[/color][color=%s][rb][/color]" % [wht, goldc, wht])
	hint.append_text("[color=%s] select[/color]" % dimc)
	hint.pop()
	hint.position = Vector2(370, 1010)
	add_child(hint)

	# Qud renders this screen INTERLACED: odd rows at ~50% (measured bg pairs
	# (6,44,42)/(2,22,22)) — a console-style scanline filter Mods doesn't have.
	var scan := ColorRect.new()
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
void fragment() {
	float row = floor(FRAGCOORD.y);
	COLOR = vec4(0.0, 0.0, 0.0, mod(row, 2.0) >= 1.0 ? 0.5 : 0.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	scan.material = mat
	add_child(scan)

func _records_nav_icon(ih: int) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))
	var k := int((ih - g) / 2.0)
	if k < 2:
		k = 2
	var w := 3 * k + 2 * g
	var h := 2 * k + g
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g
	img.fill_rect(Rect2i(mid, 0, k, k), R_GOLD)
	img.fill_rect(Rect2i(0, k + g, k, k), R_GOLD)
	img.fill_rect(Rect2i(mid, k + g, k, k), R_GOLD)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), R_GOLD)
	return ImageTexture.create_from_image(img)

func _populate_1to1() -> void:
	_rows.clear()
	for c in _list_1to1.get_children():
		c.queue_free()
	if _records.is_empty():
		var empty := Label.new()
		empty.text = "No ended runs yet."
		empty.add_theme_color_override("font_color", R_CYAN)
		_list_1to1.add_child(empty)
		return
	for i in range(_records.size()):
		var cell := _entry_1to1(_records[i], i, i < _records.size() - 1)
		_list_1to1.add_child(cell)
		_rows.append({"panel": cell, "rec": _records[i]})
	_apply_selection()

## The 4 body lines Qud shows per entry, pulled from the Details text:
## ended-on date, cause of death (or "You quit."), points, turns survived.
func _entry_lines(rec: Dictionary) -> Array:
	var det := QudText.strip(str(rec.get("Details", "")))
	var date := ""
	var cause := ""
	var scored := ""
	var survived := ""
	for raw in det.split("\n"):
		var t := str(raw).strip_edges()
		if t == "":
			continue
		if t.begins_with("This game ended"):
			date = t
		elif t.begins_with("You scored"):
			scored = t
		elif t.begins_with("You survived"):
			survived = t
		elif date != "" and cause == "" and not t.begins_with("You were level"):
			cause = t
	return [date, cause, scored, survived]

func _entry_1to1(rec: Dictionary, idx: int, separator: bool) -> Control:
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(0, R_ENTRY_PITCH)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.mouse_entered.connect(func(): _select(idx))
	cell.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))

	# persistent selection dither (Qud family tile), > cursor, delete — toggled in _style
	var hl := TextureRect.new()
	hl.name = "hl"
	var htex: Texture2D = _chrome("modsHoverTile.png")
	if htex != null:
		hl.texture = htex
		hl.stretch_mode = TextureRect.STRETCH_TILE
	hl.position = Vector2(16, 0)
	hl.size = Vector2(734, R_ENTRY_H)
	hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hl.visible = false
	cell.add_child(hl)
	var cur := Label.new()
	cur.name = "cur"
	cur.text = ">"
	cur.add_theme_color_override("font_color", R_CURSOR)
	cur.add_theme_font_size_override("font_size", 16)
	cur.position = Vector2(0, 50)
	cur.visible = false
	cell.add_child(cur)
	var del := Label.new()
	del.name = "del"
	del.text = "delete"
	del.add_theme_color_override("font_color", R_BODY_SEL)
	del.add_theme_font_size_override("font_size", 16)
	del.position = Vector2(690, 86)
	del.visible = false
	cell.add_child(del)

	var head := Label.new()
	head.name = "head"
	head.text = "%s :: Level %d :: %s" % [str(rec.get("Name", "?")),
		int(rec.get("Level", 0)), str(rec.get("GameMode", "?"))]
	head.add_theme_font_size_override("font_size", 16)
	head.position = Vector2(16, 4)
	cell.add_child(head)
	var lines := _entry_lines(rec)
	for j in range(lines.size()):
		var bl2 := Label.new()
		bl2.name = "body%d" % j
		bl2.text = str(lines[j])
		bl2.add_theme_font_size_override("font_size", 16)
		bl2.position = Vector2(16, [26, 47, 67, 88][j])
		cell.add_child(bl2)

	if separator:
		cell.draw.connect(func():
			var x := 16.0
			var xe := 750.0
			while x < xe:
				cell.draw_rect(Rect2(x, 114, minf(2, xe - x), 1), R_LINE)
				x += 5
				if x < xe:
					cell.draw_rect(Rect2(x, 114, minf(3, xe - x), 1), R_LINE)
				x += 6)
	_style_entry_1to1(cell, false)
	return cell

func _style_entry_1to1(cell: Control, on: bool) -> void:
	for nm in ["hl", "cur", "del"]:
		var n := cell.get_node_or_null(nm)
		if n != null:
			n.visible = on
	var head := cell.get_node_or_null("head")
	if head != null:
		head.add_theme_color_override("font_color", R_CYAN_SEL if on else R_CYAN)
	for j in range(4):
		var b := cell.get_node_or_null("body%d" % j)
		if b != null:
			b.add_theme_color_override("font_color", R_BODY_SEL if on else R_BODY_DIM)

func _text(txt: String, col: Color, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.add_theme_color_override("font_color", col)
	return l

func _rich(bb: String, role := "body") -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if role != "body":
		l.theme_type_variation = role.capitalize()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = bb
	return l

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")

## 12345 -> "12,345" (thousands separators for score/turns).
func _commas(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out

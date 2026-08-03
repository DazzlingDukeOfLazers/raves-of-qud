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

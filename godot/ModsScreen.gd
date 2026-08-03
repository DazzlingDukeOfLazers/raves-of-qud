extends Control

## THE MODS SCREEN — a 1:1-styled mimic of Caves of Qud's "Installed Mod Configuration".
##
## A full-screen Qud-style window (woven gold border + dark weave panel, reusing the frame
## sprites the mod extracted to title/chrome/) over the cave-art background: a titled header,
## a LEFT list of the player's installed mods (icon, title, author, version / size / tags,
## location, ENABLED badge) and a RIGHT preview panel, with a Back footer. The mod data is
## the player's OWN install — Qud's ModManager list, exported to mods.json by the bridge mod
## (ModsExporter), never redistributed. Read-only for now (view, not enable/disable).
##
## Opened as an overlay by MainMenu (over the menu box); `closed` fires when Back is chosen.

signal closed

# palette — measured off Qud's Mods screen
const FRAME := Color8(0xB6, 0xA1, 0x63)          # woven gold border
const PANEL := Color(0.055, 0.078, 0.078, 0.96)  # dark weave interior
const SCRIM := Color(0.02, 0.03, 0.03, 0.55)     # dims the menu/bg behind
const TITLE := Color8(0xF0, 0xEA, 0xD8)          # mod title
const AUTHOR := Color8(0x7E, 0xC8, 0xC0)         # "by <author>"
const LABEL := Color8(0x6E, 0xB5, 0xC9)          # "Version:" / "Size:" / "Tags:" / "Location:"
const VALUE := Color8(0xC9, 0xC2, 0xA8)          # field values
const GREEN := Color8(0x5F, 0xC8, 0x5A)          # ENABLED
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # header title, keycaps
const DIM := Color(0.89, 0.85, 0.72, 0.5)

const SIDE_W_FRAC := 0.016    # border thickness as a fraction of the panel
const BAR_H_FRAC := 0.022

# ── 1:1 constants — every number MEASURED off Qud's Mods screen @1920×1080 ──────
const Q_PANEL := Rect2(90, 48, 1742, 962)     # outer dither-band edge
const Q_BAND_H := 12                          # top/bottom dither band px
const Q_BAND_V := 10                          # left/right dither band px
const Q_LINE := Color8(65, 106, 115)          # inner structural lines
const Q_INNER_L := 19                         # inner frame x, panel-relative (real 109)
const Q_INNER_R := 1719                       # inner frame right (real 1809)
const Q_TOPLINE_Y := 16                       # inner top 2px line (real 64)
const Q_HEADLINE_Y := 43                      # ┤ Mods ├ 2px line (real 91)
const Q_BOTLINE_Y := 935                      # command-bar 1px line (real 983)
const Q_DIVIDER_X := 1399                     # list/pane divider (real 1489)
const Q_BG := Color8(6, 37, 37)               # flat panel interior
const Q_DITHER_BASE := Color8(0x35, 0x55, 0x5C)   # border-band dither
const Q_DITHER_DOT := Color8(0x1A, 0x28, 0x2A)
const Q_SEL_BASE := Color8(0x1A, 0x3F, 0x42)      # selection / chip dither
const Q_SEL_DOT := Color8(0x0F, 0x1F, 0x20)
const Q_GOLD := Color8(200, 184, 57)          # 'W' — header, authors, keycaps
const Q_WHITE := Color8(255, 255, 255)        # row titles
const Q_KEY_BLUE := Color8(0, 159, 255)       # 'B' — ▪ bullets + field keys
const Q_VALUE := Color8(90, 156, 174)         # field values
const Q_DESC := Color8(56, 154, 176)          # pane description
const Q_GREEN := Color8(0, 187, 29)           # ENABLED
const Q_TAN := Color8(177, 142, 88)           # 'w' — # SCRIPTING
const Q_LABEL_GREY := Color8(177, 177, 177)   # command-bar labels
const Q_THUMB_GREEN := Color8(30, 140, 50)    # thumb frame + corner ticks
const Q_ROW_PITCH := 112                      # row top -> next row top
const Q_ROW_H := 113   # full cell (Qud hover rect 113..225); separator rides the boundary

var _mods: Array = []
var _sel := 0
var _rows: Array = []          # [{panel, mod}]
var _list: VBoxContainer       # the mod-list column (rebuilt on refresh)
var _preview: TextureRect
var _preview_name: Label
# Auto-refresh-on-open: when the bridge connects, ask Qud to re-export the mod list and reload it.
var _peer := StreamPeerTCP.new()
var _refreshed := false
var _mods_mtime := 0
var _reload_deadline := 0

func _ready() -> void:
	name = "ModsScreen"
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = UiFont.make_theme(get_viewport())
	_mods = _load_mods()

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

## Auto-refresh on open: once the bridge is up, ask Qud to re-export its mod list, then reload
## mods.json when it's rewritten so the screen shows the LIVE install (not the last export on disk).
func _process(_dt: float) -> void:
	_peer.poll()
	var connected := _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	if connected and not _refreshed:
		_refreshed = true
		_mods_mtime = _mods_json_mtime()
		_send_bridge({"type": "command", "name": "export"})
		_reload_deadline = Time.get_ticks_msec() + 1200   # fallback if the mtime second doesn't tick
	elif _refreshed and _reload_deadline > 0:
		if _mods_json_mtime() > _mods_mtime or Time.get_ticks_msec() >= _reload_deadline:
			_reload_deadline = 0
			_reload_mods()

func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()

## mods.json modified time (seconds); 0 if absent. Detects Qud rewriting it after our `export`.
func _mods_json_mtime() -> int:
	var path := InputModel.support_dir().path_join("mods.json")
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

## Reload the mod list from disk and rebuild the left column, preserving the selection if possible.
func _reload_mods() -> void:
	_mods = _load_mods()
	if Settings.one_to_one():
		if _list_1to1 == null:
			return
		_populate_1to1()
	else:
		if _list == null:
			return
		_populate_list()
	# preserve the fresh-open NO-selection state (-1) across the auto-refresh reload
	_sel = clampi(_sel, -1, maxi(-1, _mods.size() - 1))
	_apply_selection()

## A clickable "‹ Back" at a fixed bottom-left spot (Esc also works) — the mouse route back
## to the menu, and a stable target for the regression suite's reset step.
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

func _load_mods() -> Array:
	var path := InputModel.support_dir().path_join("mods.json")
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.has("mods") and data["mods"] is Array:
		return data["mods"]
	return []

func _chrome(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _png(path: String) -> Texture2D:
	if path == "" or not FileAccess.file_exists(path):
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
	l.text = "◈  Mods  ◈"
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
	# LEFT: scrollable mod list
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0.03
	scroll.anchor_right = 0.70
	scroll.anchor_top = 0.11
	scroll.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		scroll.set("offset_" + k, 0.0)
	frame.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)
	_populate_list()

	# RIGHT: preview panel for the selected mod
	var right := VBoxContainer.new()
	right.anchor_left = 0.72
	right.anchor_right = 0.97
	right.anchor_top = 0.11
	right.anchor_bottom = 0.90
	for k in ["left", "top", "right", "bottom"]:
		right.set("offset_" + k, 0.0)
	right.add_theme_constant_override("separation", 10)
	frame.add_child(right)
	_preview = TextureRect.new()
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.custom_minimum_size = Vector2(0, 220)
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pb := StyleBoxFlat.new()
	pb.bg_color = Color(0, 0, 0, 0.4)
	pb.set_border_width_all(1)
	pb.border_color = FRAME
	var pw := PanelContainer.new()
	pw.add_theme_stylebox_override("panel", pb)
	pw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw.add_child(_preview)
	right.add_child(pw)
	_preview_name = _text("", TITLE, "caption")
	_preview_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_preview_name)

## Fill _list with a row per mod (or an empty note). Split out of _build_body so a live refresh
## after the bridge re-export can clear + rebuild the column without rebuilding the whole window.
func _populate_list() -> void:
	_rows.clear()
	for c in _list.get_children():
		c.queue_free()
	if _mods.is_empty():
		var empty := _text("No mods found. Play Caves of Qud once with Raves connected to populate this list.", VALUE, "body")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
	for i in range(_mods.size()):
		var row := _mod_row(_mods[i], i)
		_list.add_child(row)
		_rows.append({"panel": row, "mod": _mods[i]})

func _mod_row(mod: Dictionary, idx: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(func(): _select(idx))
	panel.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	var pad := MarginContainer.new()
	for k in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + k, 8)
	panel.add_child(pad)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	pad.add_child(hb)

	# icon
	var icon := TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE   # scale to OUR size, not the texture's
	icon.custom_minimum_size = Vector2(72, 72)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var itex := _png(str(mod.get("preview", "")))
	if itex != null:
		icon.texture = itex
	else:
		var ib := StyleBoxFlat.new()
		ib.bg_color = Color(0, 0, 0, 0.35)
		ib.set_border_width_all(1)
		ib.border_color = FRAME
		var iw := PanelContainer.new()
		iw.add_theme_stylebox_override("panel", ib)
		iw.custom_minimum_size = Vector2(72, 72)
		hb.add_child(iw)
	if itex != null:
		hb.add_child(icon)

	# text block
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 2)
	hb.add_child(v)
	# title + author
	var head := _rich("[color=#%s]%s[/color]  [color=#%s]by %s[/color]" % [
		TITLE.to_html(false), _esc(str(mod.get("title", mod.get("id", "?")))),
		AUTHOR.to_html(false), _esc(str(mod.get("author", "unknown")))], "title")
	v.add_child(head)
	# version / size / tags
	var tags: Array = mod.get("tags", [])
	var meta := _rich("[color=#%s]Version:[/color] [color=#%s]%s[/color]    [color=#%s]Size:[/color] [color=#%s]%s[/color]    [color=#%s]Tags:[/color] [color=#%s]%s[/color]" % [
		LABEL.to_html(false), VALUE.to_html(false), _esc(str(mod.get("version", "—"))),
		LABEL.to_html(false), VALUE.to_html(false), _esc(str(mod.get("size", "—"))),
		LABEL.to_html(false), VALUE.to_html(false), _esc(", ".join(tags) if tags is Array else "—")], "caption")
	v.add_child(meta)
	# location
	var loc := _rich("[color=#%s]Location:[/color] [color=#%s]%s[/color]" % [
		LABEL.to_html(false), VALUE.to_html(false), _esc(_shorten(str(mod.get("path", ""))))], "caption")
	v.add_child(loc)
	# enabled badge
	var enabled: bool = bool(mod.get("enabled", true))
	var badge := _text("ENABLED" if enabled else "DISABLED", GREEN if enabled else DIM, "caption")
	v.add_child(badge)

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
			_style_row_1to1(_rows[i]["panel"], i == _sel)
		_apply_selection_1to1()
		return
	for i in range(_rows.size()):
		_style_row(_rows[i]["panel"], i == _sel)
	if _sel >= 0 and _sel < _mods.size():
		var mod: Dictionary = _mods[_sel]
		var tex := _png(str(mod.get("preview", "")))
		if _preview != null:
			_preview.texture = tex
		if _preview_name != null:
			_preview_name.text = str(mod.get("title", mod.get("id", "")))

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
		_select(mini(_sel + 1, _rows.size() - 1)); accept_event()   # from -1 (fresh open) -> row 0
	elif e.is_action_pressed("ui_up"):
		_select(maxi(_sel - 1, 0)); accept_event()

# ── 1:1 build — Qud's Installed Mod Configuration, reproduced px-for-px ─────────
# The panel floats over the title screen with NO scrim (Qud dims nothing); the
# title's own hint bar + version stay visible below the panel, exactly like Qud.

var _panel_1to1: Control
var _list_1to1: VBoxContainer
var _pane_1to1: VBoxContainer

func _build_1to1() -> void:
	var vp := get_viewport_rect().size
	var sx := vp.x / 1920.0
	var sy := vp.y / 1080.0
	_sel = -1   # Qud opens with NO selection: chipped badges, empty preview box
	var p := Control.new()
	p.position = Vector2(Q_PANEL.position.x * sx, Q_PANEL.position.y * sy)
	p.size = Vector2(Q_PANEL.size.x * sx, Q_PANEL.size.y * sy)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(p)
	_panel_1to1 = p
	var w := p.size.x
	var h := p.size.y

	# flat interior
	var bg := ColorRect.new()
	bg.color = Q_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(bg)

	# dither border bands — Qud's pattern is a 7×7 periodic dither; each band's tile is
	# extracted PHASE-ANCHORED from its own origin in the reference capture, so tiling
	# from the band's top-left reproduces Qud's pixels exactly. Fallback: generated dither.
	var fallback := _dither_tex(Q_DITHER_BASE, Q_DITHER_DOT, 7)
	for spec in [["modsBandTop.png", Rect2(0, 0, w, Q_BAND_H)],
			["modsBandBottom.png", Rect2(0, h - Q_BAND_H, w, Q_BAND_H)],
			["modsBandLeft.png", Rect2(0, 0, Q_BAND_V, h)],
			["modsBandRight.png", Rect2(w - Q_BAND_V, 0, Q_BAND_V, h)]]:
		var tex: Texture2D = _chrome(spec[0])
		p.add_child(_tile_rect(tex if tex != null else fallback, spec[1]))

	# The container GRID, exactly Qud's: the horizontal lines span the FULL inner
	# width (5..1739) while the verticals (19 / 1399 / 1719) run only from the
	# header line down to the command-bar line and stop FREE (no bottom
	# throughline) — so the header strip is ONE cell spanning everything, and the
	# content row is four columns: [thin][list][pane][thin].
	# Top line: 4 measured segments — the small gaps are Qud's line ornaments
	# flanking the pictograph (its stem crossing is covered by the sprite).
	for seg in [[8, 796], [803, 870], [875, 936], [943, 1735]]:
		_hline(p, seg[0], seg[1], Q_TOPLINE_Y, 2)
	_vline(p, Q_INNER_L, Q_HEADLINE_Y, Q_BOTLINE_Y + 1, 1)
	_vline(p, Q_INNER_R, Q_HEADLINE_Y, Q_BOTLINE_Y + 1, 1)
	_vline(p, Q_DIVIDER_X, Q_HEADLINE_Y, Q_BOTLINE_Y, 1)

	# ┤ Mods ├ header line: full inner width with the measured title gap (830..909)
	_hline(p, 8, 830, Q_HEADLINE_Y, 2)
	_hline(p, 909, 1735, Q_HEADLINE_Y, 2)
	for bx in [830.0, 907.0]:   # the tall │ brackets at the gap edges
		_vline(p, bx, Q_HEADLINE_Y - 8, Q_HEADLINE_Y + 10, 2)
	var title := Label.new()
	title.text = "Mods"
	title.add_theme_color_override("font_color", Q_GOLD)
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(830, Q_HEADLINE_Y - 12)
	title.size = Vector2(79, 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(title)

	# pictograph riding the top band (crown overhangs the panel into the art above)
	var pict := _chrome("modsPictograph.png")
	if pict != null:
		var pr := TextureRect.new()
		pr.texture = pict
		pr.position = Vector2(840, -32)   # real (930,16) vs panel (90,48)
		pr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(pr)

	# LEFT: the mod list
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.position = Vector2(Q_INNER_L + 3, 65)
	scroll.size = Vector2(Q_DIVIDER_X - Q_INNER_L - 6, Q_BOTLINE_Y - 82)
	p.add_child(scroll)
	_list_1to1 = VBoxContainer.new()
	_list_1to1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_1to1.add_theme_constant_override("separation", 0)   # cells are full-pitch; boundary carries the dotted line
	scroll.add_child(_list_1to1)
	_populate_1to1()

	# RIGHT: preview pane
	_pane_1to1 = VBoxContainer.new()
	_pane_1to1.position = Vector2(Q_DIVIDER_X + 16, 86)
	_pane_1to1.size = Vector2(Q_INNER_R - Q_DIVIDER_X - 32, Q_BOTLINE_Y - 90)
	_pane_1to1.add_theme_constant_override("separation", 6)
	p.add_child(_pane_1to1)
	_apply_selection_1to1()

	# bottom command bar: a 1px line with a PACKED chip group over its middle —
	# Qud has no line between chips (the group is contiguous, ~4px gaps) and no
	# corner ticks; small │ terminals flank the group where the line ends.
	_hline(p, Q_INNER_L, Q_INNER_R, Q_BOTLINE_Y, 1)
	var bar := CenterContainer.new()
	bar.position = Vector2(Q_INNER_L, Q_BOTLINE_Y - 15)   # group centres on the panel, like Qud
	bar.size = Vector2(Q_INNER_R - Q_INNER_L, 30)
	p.add_child(bar)
	var grp := PanelContainer.new()   # flat panel-bg behind the whole group: the 1px
	var gsb := StyleBoxFlat.new()     # line must NOT show between the ticks and chips
	gsb.bg_color = Q_BG
	grp.add_theme_stylebox_override("panel", gsb)
	bar.add_child(grp)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
	grp.add_child(chips)
	chips.add_child(_bar_tick())
	var first := true
	for pair in [["Esc", "Back"], ["space", "Disable mod"], ["v", "Disable all"],
			["r", "Save and Reload"], ["u", "Undo"]]:
		var parts := [["[%s]" % pair[0], Q_GOLD], [" %s" % pair[1], Q_LABEL_GREY]]
		if first:
			parts.push_front(["> ", Q_LABEL_GREY])   # Qud's bar cursor sits on the first item
			first = false
		chips.add_child(_chip_1to1_parts(parts))
	chips.add_child(_bar_tick())

func _populate_1to1() -> void:
	_rows.clear()
	for c in _list_1to1.get_children():
		c.queue_free()
	if _mods.is_empty():
		var empty := _text("No mods found.", Q_VALUE, "body")
		_list_1to1.add_child(empty)
	for i in range(_mods.size()):
		var row := _mod_row_1to1(_mods[i], i, i < _mods.size() - 1)
		_list_1to1.add_child(row)
		_rows.append({"panel": row, "mod": _mods[i]})

func _mod_row_1to1(mod: Dictionary, idx: int, separator: bool = false) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, Q_ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _select(idx))
	# Qud's list SELECTS on mouse-over, and the full-cell dither highlight PERSISTS
	# until another row is selected (measured live via hv mouse: the highlight stays
	# with the cursor parked far away). The highlight is the selection marker; the
	# selected row also un-chips its badges + fills the pane.
	row.mouse_entered.connect(func(): _select(idx))
	var selhl := TextureRect.new()
	selhl.name = "selhl"
	var htex: Texture2D = _chrome("modsHoverTile.png")
	if htex == null:
		htex = _dither_tex(Color8(26, 63, 66), Color8(15, 31, 32), 17)
	selhl.texture = htex
	selhl.stretch_mode = TextureRect.STRETCH_TILE
	selhl.position = Vector2(8, 0)
	selhl.size = Vector2(1364, Q_ROW_H)
	selhl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selhl.visible = false
	row.add_child(selhl)
	if separator:
		# Qud's dotted divider between list items (measured: 2on-3off-3on-3off,
		# colour (58,89,101), at row_top+101, spanning x 8..width-7)
		row.draw.connect(func():
			var col := Color8(58, 89, 101)
			var x := 8.0
			var xe := row.size.x - 7.0
			var y := 112.0
			while x < xe:
				row.draw_rect(Rect2(x, y, minf(2, xe - x), 1), col)
				x += 5
				if x < xe:
					row.draw_rect(Rect2(x, y, minf(3, xe - x), 1), col)
				x += 6)

	# thumbnail: 64px art in Qud's frame SPRITE (5-dot corners + imperfect border,
	# extracted with alpha from the reference — procedural drawing can't match the jank)
	var tframe := Control.new()
	tframe.name = "thumbframe"
	tframe.position = Vector2(28, 15)   # sprite lands at real (140, cell_top+15) like Qud
	tframe.size = Vector2(79, 79)
	tframe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fspr := _chrome("modsThumbFrame.png")
	if fspr != null:
		var fr := TextureRect.new()
		fr.texture = fspr
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tframe.add_child(fr)
	else:
		tframe.draw.connect(func():
			tframe.draw_rect(Rect2(7, 7, 66, 66), Q_THUMB_GREEN, false, 1.0)
			for corner in [Vector2(0, 0), Vector2(75, 0), Vector2(0, 75), Vector2(75, 75)]:
				tframe.draw_rect(Rect2(corner + Vector2(1, 1), Vector2(2, 2)), Q_THUMB_GREEN))
	row.add_child(tframe)
	var icon := TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.position = Vector2(8, 8)
	icon.size = Vector2(64, 64)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var itex := _png(str(mod.get("preview", "")))
	if itex == null:
		itex = _fallback_logo()
	icon.texture = itex
	tframe.add_child(icon)
	tframe.move_child(icon, 0)   # art UNDER the frame sprite so the border overdraws edges

	# text column
	var v := VBoxContainer.new()
	v.position = Vector2(116, 13)
	v.size = Vector2(Q_DIVIDER_X - Q_INNER_L - 132, Q_ROW_H - 8)
	v.add_theme_constant_override("separation", 1)
	row.add_child(v)

	var author_bb: String = QudText.to_bbcode(str(mod.get("author", "")), _qud_palette())
	var head := _rich("", "body")
	head.add_theme_font_size_override("normal_font_size", 17)
	head.append_text("[color=#FFFFFF]%s[/color]  " % _esc(str(mod.get("title", mod.get("id", "?")))))
	head.add_image(_glyph_tex(), 12, 12)
	head.append_text("  [color=#FFFFFF]by [/color][color=#FFFFFF]%s[/color]" % author_bb)
	v.add_child(head)

	var meta := _rich(_kv("Version", _null_dash(mod.get("version"))) + "  "
		+ _kv("Size", _null_dash(mod.get("size"))) + "  "
		+ _kv("Tags", ", ".join(mod.get("tags", []))), "body")
	meta.add_theme_font_size_override("normal_font_size", 16)
	v.add_child(meta)

	var loc := _rich(_kv("Location", _qud_elide(str(mod.get("path", "")))), "body")
	loc.add_theme_font_size_override("normal_font_size", 16)
	loc.clip_contents = true
	v.add_child(loc)

	var badges := HBoxContainer.new()
	badges.name = "badges"
	badges.add_theme_constant_override("separation", 14)
	var enabled: bool = bool(mod.get("enabled", true))
	badges.add_child(_chip_1to1_parts([[
		"ENABLED" if enabled else "DISABLED",
		Q_GREEN if enabled else Color8(120, 120, 120)]], true, true))
	if bool(mod.get("scripting", false)):
		badges.add_child(_chip_1to1_parts([["# SCRIPTING", Q_TAN]], true, true))
	v.add_child(badges)
	row.set_meta("badges", badges)

	_style_row_1to1(row, false)
	return row

## Selection in Qud's list: the selected row's badges render PLAIN (no chip dither);
## unselected rows keep the chip. That plus the pane is the whole selection signal.
func _style_row_1to1(row: Control, on: bool) -> void:
	var selhl := row.get_node_or_null("selhl")
	if selhl != null:
		selhl.visible = on
	var badges: HBoxContainer = row.get_meta("badges") if row.has_meta("badges") else null
	if badges == null:
		return
	for chip in badges.get_children():
		if chip is PanelContainer:
			if on:
				chip.add_theme_stylebox_override("panel", _chip_flat_sb(true))
			else:
				chip.add_theme_stylebox_override("panel", _chip_dither_sb(true))

func _apply_selection_1to1() -> void:
	if _pane_1to1 == null:
		return
	for c in _pane_1to1.get_children():
		c.queue_free()

	# preview box: BLACK 128px square in Qud's frame SPRITE (imperfect border + 5-dot
	# corners) — shown even with no selection (Qud's fresh-open state: empty box + the
	# four-squares glyph, nothing else). Sprite placed at Qud's absolute spot.
	var wrapper := Control.new()
	wrapper.custom_minimum_size = Vector2(0, 150)
	var pframe := Control.new()
	pframe.position = Vector2(65, 7)   # sprite at real (1570, 141) vs pane origin (1505, 134)
	pframe.size = Vector2(143, 143)
	var blackbg := ColorRect.new()
	blackbg.color = Color.BLACK
	blackbg.position = Vector2(9, 9)
	blackbg.size = Vector2(127, 127)
	pframe.add_child(blackbg)
	var has_sel := _sel >= 0 and _sel < _mods.size()
	if has_sel:
		var img := TextureRect.new()
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.position = Vector2(9, 9)
		img.size = Vector2(127, 127)
		var tex := _png(str(_mods[_sel].get("preview", "")))
		if tex == null:
			tex = _fallback_logo()
		img.texture = tex
		pframe.add_child(img)
	var pspr := _chrome("modsPaneFrame.png")
	if pspr != null:
		var fr := TextureRect.new()
		fr.texture = pspr
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pframe.add_child(fr)   # frame OVER the art, like Qud
	else:
		pframe.draw.connect(func():
			pframe.draw_rect(Rect2(8, 8, 129, 129), Color8(59, 126, 72), false, 1.0)
			for corner in [Vector2(0, 0), Vector2(137, 0), Vector2(0, 137), Vector2(137, 137)]:
				pframe.draw_rect(Rect2(corner + Vector2(2, 2), Vector2(2, 2)), Color8(59, 126, 72)))
	wrapper.add_child(pframe)
	_pane_1to1.add_child(wrapper)
	_pane_1to1.add_child(_spacer(24))
	if not has_sel:
		_pane_1to1.add_child(_glyph_line())
		return
	var mod: Dictionary = _mods[_sel]

	var name_l := _rich("[center][color=#%s]%s[/color][/center]" % [
		Q_GOLD.to_html(false), _esc(str(mod.get("title", mod.get("id", ""))))], "body")
	name_l.add_theme_font_size_override("normal_font_size", 18)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pane_1to1.add_child(name_l)

	_pane_1to1.add_child(_glyph_line())

	var by_l := _rich("[center][color=#%s]by %s[/color][/center]" % [
		Q_GOLD.to_html(false), _esc(QudText.strip(str(mod.get("author", ""))))], "body")
	by_l.add_theme_font_size_override("normal_font_size", 18)
	by_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pane_1to1.add_child(by_l)
	_pane_1to1.add_child(_spacer(10))

	var desc := _rich("[color=#%s]%s[/color]" % [
		Q_DESC.to_html(false), _esc(str(mod.get("description", "")))], "body")
	desc.add_theme_font_size_override("normal_font_size", 16)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pane_1to1.add_child(desc)

# ── 1:1 helper widgets ─────────────────────────────────────────────────────────

func _hline(parent: Control, x0: float, x1: float, y: float, th: float) -> void:
	var r := ColorRect.new()
	r.color = Q_LINE
	r.position = Vector2(x0, y)
	r.size = Vector2(x1 - x0, th)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)

func _vline(parent: Control, x: float, y0: float, y1: float, th: float) -> void:
	var r := ColorRect.new()
	r.color = Q_LINE
	r.position = Vector2(x, y0)
	r.size = Vector2(th, y1 - y0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(r)

func _tile_rect(tex: Texture2D, rect: Rect2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = TextureRect.STRETCH_TILE
	r.position = rect.position
	r.size = rect.size
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

## Random ~25% dot dither — the texture Qud uses for border bands, row selection
## and badge chips (two palettes of the same weave; see the measured constants).
static var _dither_cache := {}
static func _dither_tex(base: Color, dot: Color, seed_v: int) -> ImageTexture:
	var key := str(base) + str(dot) + str(seed_v)
	if _dither_cache.has(key):
		return _dither_cache[key]
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for y in range(64):
		for x in range(64):
			img.set_pixel(x, y, dot if rng.randf() < 0.25 else base)
	var tex := ImageTexture.create_from_image(img)
	_dither_cache[key] = tex
	return tex

## The ⠿-ish four-squares glyph Qud puts after mod names — WHITE in the list rows,
## GOLD-OLIVE in the preview pane (measured (139,145,61)).
static var _glyph_tex_cache := {}
static func _glyph_tex(col: Color = Color8(255, 255, 255)) -> ImageTexture:
	var key := str(col)
	if _glyph_tex_cache.has(key):
		return _glyph_tex_cache[key]
	var img := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for gx in [0, 7]:
		for gy in [0, 7]:
			for x in range(5):
				for y in range(5):
					img.set_pixel(gx + x, gy + y, col)
	var tex := ImageTexture.create_from_image(img)
	_glyph_tex_cache[key] = tex
	return tex

## A command-bar / badge chip: Qud's chip is a bare rect of the 7×7 dither (no border).
## `parts` is [[text, Color], ...] — Labels report proper minimum sizes (RichTextLabel
## doesn't, which collapses PanelContainers). `dithered` false = plain (selected-row look).
func _chip_1to1_parts(parts: Array, dithered: bool = true, compact: bool = false) -> Control:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", _chip_dither_sb(compact) if dithered else _chip_flat_sb(compact))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 0)
	for part in parts:
		var l := Label.new()
		l.text = str(part[0])
		l.add_theme_color_override("font_color", part[1])
		l.add_theme_font_size_override("font_size", 16)
		hb.add_child(l)
	chip.add_child(hb)
	return chip

func _chip_dither_sb(compact: bool = false) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	# The chip weave IS the window-border pattern, darker: border #35555C/#1A282A ->
	# chip (12,60,63)/(6,29,31). modsChipTile.png is the band tile remapped to that
	# palette; the fallback derives it from the band tile at runtime the same way.
	var tex: Texture2D = _chrome("modsChipTile.png")
	if tex == null:
		var bandtex: Texture2D = _chrome("modsBandTop.png")
		if bandtex != null:
			var img := bandtex.get_image()
			img.convert(Image.FORMAT_RGB8)
			var base := Color8(0x35, 0x55, 0x5C)
			for y in range(img.get_height()):
				for x in range(img.get_width()):
					var c := img.get_pixel(x, y)
					var near_base: bool = absf(c.r - base.r) + absf(c.g - base.g) + absf(c.b - base.b) < 0.15
					img.set_pixel(x, y, Color8(12, 60, 63) if near_base else Color8(6, 29, 31))
			tex = ImageTexture.create_from_image(img)
	sb.texture = tex if tex != null else _dither_tex(Color8(12, 60, 63), Color8(6, 29, 31), 13)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.content_margin_left = 7 if compact else 14
	sb.content_margin_right = 7 if compact else 14
	sb.content_margin_top = 3 if compact else 2
	sb.content_margin_bottom = 3 if compact else 2
	return sb

func _chip_flat_sb(compact: bool = false) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 7 if compact else 14
	sb.content_margin_right = 7 if compact else 14
	sb.content_margin_top = 3 if compact else 2
	sb.content_margin_bottom = 3 if compact else 2
	return sb

## The small │ terminal where the command-bar line meets the chip group.
func _bar_tick() -> Control:
	var t := Control.new()
	t.custom_minimum_size = Vector2(2, 30)
	var r := ColorRect.new()
	r.color = Q_LINE
	r.position = Vector2(0, 9)
	r.size = Vector2(2, 12)
	t.add_child(r)
	return t

func _kv(key: String, val: String) -> String:
	return "[color=#%s]▪ %s:[/color] [color=#%s]%s[/color]" % [
		Q_KEY_BLUE.to_html(false), key, Q_VALUE.to_html(false), _esc(val)]

func _null_dash(v) -> String:
	return "—" if v == null or str(v) == "" else str(v)

## Qud's path elision: strip "~/Library/Application Support/", then keep only the
## part of the FIRST segment after its last dot ("com.FreeholdGames.CavesOfQud" ->
## "CavesOfQud"; "Steam" has no dot -> dropped entirely). Prefix "<...>".
func _qud_elide(p: String) -> String:
	var home := OS.get_environment("HOME")
	var pref := home + "/Library/Application Support/"
	if home != "" and p.begins_with(pref):
		var rest := p.substr(pref.length())
		var slash := rest.find("/")
		var first := rest.substr(0, slash) if slash >= 0 else rest
		var tail := rest.substr(slash) if slash >= 0 else ""
		var dot := first.rfind(".")
		if dot >= 0:
			return "<...>/" + first.substr(dot + 1) + tail
		return "<...>" + tail
	if p.length() > 90:
		return "<...>" + p.substr(p.length() - 89)
	return p

func _fallback_logo() -> Texture2D:
	# Qud's no-preview thumb is its stacked square logo — extracted from the reference
	# capture into chrome/. The wide title logo is the wrong art for this slot.
	var t := _chrome("modsThumbFallback.png")
	if t != null:
		return t
	var path := InputModel.support_dir().path_join("title").path_join("logo.png")
	return _png(path)

func _qud_palette() -> Dictionary:
	var out := {}
	for code in QudPalette.COLORS:
		out[code] = QudPalette.COLORS[code].to_html(false)
	return out

## The pane's gold four-squares glyph, centred on the IMAGE BOX axis (x=130 pane-local
## ≈ real 1641), not the pane's own centre — Qud aligns it to the preview box.
func _glyph_line() -> Control:
	var line := Control.new()
	line.custom_minimum_size = Vector2(0, 12)
	var gi := TextureRect.new()
	gi.texture = _glyph_tex(Color8(139, 145, 61))
	gi.position = Vector2(130, 0)
	line.add_child(gi)
	return line

func _spacer(hpx: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, hpx)
	return s

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

func _shorten(p: String) -> String:
	var home := OS.get_environment("HOME")
	if home != "" and p.begins_with(home):
		p = "~" + p.substr(home.length())
	if p.length() > 64:
		p = "…" + p.substr(p.length() - 63)
	return p

extends Control

## ATTRIBUTES & POWERS — the status screens' character-sheet tab, 1:1.
##
## Renders character.json (mod CharacterExporter): the char header (portrait, name,
## genotype+subtype, level/HP/XP/weight line), three left-column sections of dotted
## stat boxes (MAIN / SECONDARY / RESISTANCES) with green/red [±mod] readouts, and
## the right column's MUTATIONS list + detail pane (title, [type], RANK n/max,
## description, This rank / Next rank level text). Hover selects: a mutation updates
## the detail pane; a stat box shows its Qud help text below the boxes (the default
## selection mirrors the reference capture: the HR box).
##
## All geometry/colours measured off reports/2026-08-04-status-screens/attributes_qud.png.

var C_NAME := QudChrome.q8(105, 124, 135)
var C_SUBTITLE := QudChrome.q8(117, 96, 57)
var C_LABEL := QudChrome.q8(70, 125, 157)       # header/info labels (blue)
var C_HEADER := QudChrome.q8(59, 120, 154)      # section header text
var C_PALE := QudChrome.q8(168, 194, 187)       # body text / values
var C_POINTS := QudChrome.q8(158, 184, 179)
var C_BOX_LABEL := QudChrome.q8(72, 105, 118)
var C_VALUE := QudChrome.q8(108, 183, 200)      # stat values (cyan)
var C_GREEN := QudChrome.q8(0, 188, 29)
var C_RED := QudChrome.q8(208, 58, 0)
var C_MUT_TITLE := QudChrome.q8(0, 139, 255)
var C_MUT_TYPE := QudChrome.q8(56, 154, 176)
var C_RULE := QudChrome.q8(60, 84, 92)
var C_LINE := QudChrome.q8(68, 99, 111)        # spine / divider lines / header rules (Qud: #4d6e7a)
var C_FRAME := QudChrome.q8(55, 84, 98)        # stat-box frame + corner loops
var C_BAND := QudChrome.q8(30, 57, 72)         # the divider's solid centre band
var C_GOLD := QudChrome.q8(195, 180, 56)

const BOX_W := 70
const BOX_H := 70
const BOX_PITCH := 102
const BOX_X0 := 206

var _data := {}
var _palette := {}
var _portrait: Texture2D = null
var _sel_stat := "STR"       # Qud default: STR selected, its flavor text under the MAIN row
var _sel_mut := 0
var _boxes: Control
var _mut_list: Control
var _detail: Control
var _help_lbl: RichTextLabel
var _help_slots := {}        # section -> RichTextLabel (flavor text under that section's row)
var _detail_labels: Array = []
const SECTION_OF := {"STR": "main", "AGI": "main", "TOU": "main", "INT": "main", "WIL": "main", "EGO": "main",
	"QN": "sec", "MS": "sec", "AV": "sec", "DV": "sec", "MA": "sec",
	"AR": "res", "ER": "res", "CR": "res", "HR": "res"}

func has_portrait() -> bool:
	return _portrait != null

func setup(data: Dictionary, palette: Dictionary, portrait: Texture2D) -> void:
	_data = data
	_palette = palette
	_portrait = portrait
	for c in get_children():
		c.queue_free()
	_build()

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ── char header ─────────────────────────────────────────────────────────────
	if _portrait != null:
		var pr := TextureRect.new()
		pr.texture = _portrait
		pr.position = Vector2(162, 172)
		pr.size = Vector2(24, 36)   # Qud: the 16x24 tile at 1.5x (measured off content)
		pr.flip_h = true   # Qud's sheet portrait faces left (the sprite-facing rule)
		pr.stretch_mode = TextureRect.STRETCH_SCALE
		pr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pr)
	_label(str(_data.get("name", "?")), Vector2(199, 172), C_NAME, 16)
	_label(str(_data.get("title", "")), Vector2(199, 191), C_SUBTITLE, 14)
	var info := _rich(Vector2(199, 207), 14)
	var lb := "#" + C_LABEL.to_html(false)
	var pv := "#FFFFFF"   # Qud renders the numbers white
	info.text = ("[color=%s]Level:[/color] [color=%s]%d[/color] [color=%s]»[/color] " +
		"[color=%s]HP:[/color] [color=%s]%d/%d[/color] [color=%s]»[/color] " +
		"[color=%s]XP:[/color] [color=%s]%d/%d[/color] [color=%s]»[/color] " +
		"[color=%s]Weight:[/color] [color=%s]%d#[/color]") % [
		lb, pv, int(_data.get("level", 0)), lb,
		lb, pv, int(_data.get("hp", 0)), int(_data.get("hpMax", 0)), lb,
		lb, pv, int(_data.get("xp", 0)), int(_data.get("xpNext", 0)), lb,
		lb, pv, int(_data.get("weight", 0))]
	add_child(info)

	# ── left column: three box sections ────────────────────────────────────────
	_boxes = Control.new()
	_boxes.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boxes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boxes.draw.connect(_draw_left)
	add_child(_boxes)

	var stats: Dictionary = _data.get("stats", {})
	_section_header(Vector2(215, 230), "MAIN ATTRIBUTES", 815,
		"Attribute Points:", int(_data.get("ap", 0)), 456)
	var mains := ["STR", "AGI", "TOU", "INT", "WIL", "EGO"]
	for i in mains.size():
		_stat_box(mains[i], stats.get(mains[i], {}), Vector2(BOX_X0 + i * BOX_PITCH, 255), true)
	_section_header(Vector2(215, 423), "SECONDARY ATTRIBUTES", 815, "", 0, 0)
	var secs := ["QN", "MS", "AV", "DV", "MA"]
	for i in secs.size():
		_stat_box(secs[i], stats.get(secs[i], {}), Vector2(BOX_X0 + i * BOX_PITCH, 447), false)
	_section_header(Vector2(215, 615), "RESISTANCES", 815, "", 0, 0)
	var rs := ["AR", "ER", "CR", "HR"]
	for i in rs.size():
		_stat_box(rs[i], stats.get(rs[i], {}), Vector2(BOX_X0 + i * BOX_PITCH, 645), false)

	# per-section flavor slots (Qud shows the hovered stat's help under ITS section's
	# row; one selection across all three groups; default STR)
	for slot in [["main", 339.0], ["sec", 531.0], ["res", 729.0]]:
		var hl := _rich(Vector2(206, slot[1]), 16)
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hl.size = Vector2(600, 84)
		hl.fit_content = false
		hl.add_theme_color_override("default_color", C_PALE)
		add_child(hl)
		_help_slots[slot[0]] = hl
	_apply_stat_sel()

	# ── right column: mutations ────────────────────────────────────────────────
	_section_header(Vector2(878, 230), "MUTATIONS", 1750,
		"Mutation Points:", int(_data.get("mp", 0)), 1000)
	_mut_list = Control.new()
	_mut_list.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mut_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_mut_list)
	var muts: Array = _data.get("mutations", [])
	for i in muts.size():
		var m: Dictionary = muts[i]
		# name + " (n)" when Qud's ShouldShowLevel says so (CanLevel; defects/fixed stay bare)
		var nm := str(m.get("display", m.get("name", "?")))
		var row := _rich(Vector2(872, 280 + i * 36), 16)
		row.size = Vector2(420, 22)   # list column only — a 700px row covered the detail pane,
		row.add_theme_color_override("default_color", C_PALE)   # eating its wheel + hover
		var body := QudText.to_bbcode(nm, _palette)
		if bool(m.get("showLevel", false)):
			# Qud renders the (n) in cyan, not the name colour
			body += " [color=#%s](%d)[/color]" % [C_MUT_TYPE.to_html(false), int(m.get("uiLevel", 0))]
		row.text = body
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		row.mouse_entered.connect(func(): _select_mut(idx))
		add_child(row)
	_detail = Control.new()
	_detail.set_anchors_preset(Control.PRESET_FULL_RECT)
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_detail)
	_select_mut(0)

func _draw_left() -> void:
	# centre divider (measured): solid 1px lines at x816/x834 flanking a 6px solid
	# navy band at x823..828 — the border-band family, flat at 1x
	_boxes.draw_rect(Rect2(816, 170, 1, 765), C_LINE)
	_boxes.draw_rect(Rect2(823, 170, 6, 765), C_BAND)
	_boxes.draw_rect(Rect2(834, 170, 1, 765), C_LINE)
	# the left spine: below the portrait, down the whole column; header rules tie into it
	_boxes.draw_rect(Rect2(173, 218, 1, 717), C_LINE)
	# mutations list/detail divider (still dotted in Qud)
	var y2 := 252.0
	while y2 < 935.0:
		_boxes.draw_rect(Rect2(1310, y2, 1, 3), C_RULE)
		y2 += 6.0

func _section_header(pos: Vector2, title: String, rule_end: float, extra: String, extra_val: int, extra_x: float) -> void:
	var hdr := Control.new()
	hdr.position = pos
	hdr.size = Vector2(rule_end - pos.x, 20)
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := get_theme_font("font", "Label")
	var tw := f.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	hdr.draw.connect(func():
		# spine ──┤ TITLE ├── rule running to a few px shy of the centre divider
		var x0 := 173.0 - hdr.position.x    # start at the left spine (mutations: the divider)
		if hdr.position.x > 830.0:
			x0 = 840.0 - hdr.position.x
		hdr.draw_rect(Rect2(x0, 9, 8 - x0 + 8, 1), C_LINE)
		hdr.draw_rect(Rect2(8, 4, 1, 11), C_LINE)
		hdr.draw_string(f, Vector2(14, 16), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_HEADER)
		var rx := 14.0 + tw + 6.0
		hdr.draw_rect(Rect2(rx, 4, 1, 11), C_LINE)
		var ex := (extra_x - hdr.position.x) if extra != "" else 0.0
		if extra != "":
			hdr.draw_rect(Rect2(rx + 1, 9, ex - rx - 8, 1), C_LINE)
			var etw := f.get_string_size(extra, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			hdr.draw_string(f, Vector2(ex, 16), extra, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_POINTS)
			hdr.draw_string(f, Vector2(ex + etw + 8, 16), str(extra_val),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GOLD if extra_val > 0 else C_BOX_LABEL)
			hdr.draw_rect(Rect2(ex + etw + 28, 9, hdr.size.x - (ex + etw + 28), 1), C_LINE)
		else:
			hdr.draw_rect(Rect2(rx + 1, 9, hdr.size.x - rx - 1, 1), C_LINE))
	add_child(hdr)

## Palette colour for a Qud colour code, with the console-table fallback.
func _code_col(code: String, fallback: Color) -> Color:
	if _palette.has(code):
		return Color(String(_palette[code]))
	var tbl: Dictionary = _tiles_colors()
	return tbl.get(code, fallback)

static func _tiles_colors() -> Dictionary:
	return load("res://QudTiles.gd").COLORS

func _stat_box(id: String, sd: Dictionary, pos: Vector2, with_mod: bool) -> void:
	var value := int(sd.get("v", 0))
	var box := Control.new()
	box.position = pos
	box.size = Vector2(BOX_W, BOX_H)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.mouse_entered.connect(func(): _select_stat(id))
	box.set_meta("stat", id)
	var f := get_theme_font("font", "Label")
	box.draw.connect(func():
		# Qud's frame: solid 2px border with an interlocking 7x7 corner loop at the
		# upper-left and (mirrored) lower-right — transcribed pixel-for-pixel
		var W := float(BOX_W)
		var H := float(BOX_H)
		# UL loop: hollow 7x7 ring, 2px stub, 7px bar, then the borders take over
		box.draw_rect(Rect2(0, 0, 7, 2), C_FRAME)
		box.draw_rect(Rect2(0, 5, 7, 2), C_FRAME)
		box.draw_rect(Rect2(0, 2, 2, 3), C_FRAME)
		box.draw_rect(Rect2(5, 2, 2, 3), C_FRAME)
		box.draw_rect(Rect2(5, 7, 2, 2), C_FRAME)
		box.draw_rect(Rect2(0, 9, 7, 2), C_FRAME)
		box.draw_rect(Rect2(0, 11, 2, H - 11), C_FRAME)          # left border
		box.draw_rect(Rect2(9, 0, W - 9, 2), C_FRAME)            # top border
		# LR loop (180-degree mirror)
		box.draw_rect(Rect2(W - 7, H - 2, 7, 2), C_FRAME)
		box.draw_rect(Rect2(W - 7, H - 7, 7, 2), C_FRAME)
		box.draw_rect(Rect2(W - 2, H - 5, 2, 3), C_FRAME)
		box.draw_rect(Rect2(W - 7, H - 5, 2, 3), C_FRAME)
		box.draw_rect(Rect2(W - 7, H - 9, 2, 2), C_FRAME)
		box.draw_rect(Rect2(W - 7, H - 11, 7, 2), C_FRAME)
		box.draw_rect(Rect2(W - 2, 0, 2, H - 11), C_FRAME)       # right border
		box.draw_rect(Rect2(0, H - 2, W - 9, 2), C_FRAME)        # bottom border
		var lw := f.get_string_size(id, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		box.draw_string(f, Vector2((BOX_W - lw) * 0.5, 22), id, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_BOX_LABEL)
		var vs := str(value)
		var vw := f.get_string_size(vs, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		# Qud's own colour code (C/G/r), computed mod-side from Statistic Value vs Base
		var vcol := _code_col(str(sd.get("c", "C")), C_VALUE)
		box.draw_string(f, Vector2((BOX_W - vw) * 0.5, 45), vs, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, vcol)
		if with_mod:
			# Qud: Modifier > -1 -> {{G|[+n]}}, else {{R|[n]}} (Statistic.Modifier, exported)
			var mod := int(sd.get("m", 0))
			var ms := "[%s%d]" % ["+" if mod > -1 else "", mod]
			var mw := f.get_string_size(ms, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			box.draw_string(f, Vector2((BOX_W - mw) * 0.5, 63), ms,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				_code_col("G", C_GREEN) if mod > -1 else _code_col("R", C_RED))
		if _sel_stat == id:
			box.draw_string(f, Vector2(-11, 36), ">", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_GOLD))
	add_child(box)

func _select_stat(id: String) -> void:
	if _sel_stat == id:
		return
	_sel_stat = id
	_apply_stat_sel()
	for c in get_children():
		if c is Control and c.has_meta("stat"):
			c.queue_redraw()

func _apply_stat_sel() -> void:
	if _help_slots.is_empty():
		return
	var help: Dictionary = _data.get("help", {})
	var sect: String = SECTION_OF.get(_sel_stat, "")
	for k in _help_slots:
		_help_slots[k].text = QudText.to_bbcode(str(help.get(_sel_stat, "")), _palette) if k == sect else ""

func _select_mut(idx: int) -> void:
	var muts: Array = _data.get("mutations", [])
	if idx < 0 or idx >= muts.size():
		return
	_sel_mut = idx
	for l in _detail_labels:
		if is_instance_valid(l):
			l.queue_free()
	_detail_labels.clear()
	var m: Dictionary = muts[idx]
	var cx := 1539.0   # detail column centre
	# the mutation's icon, 16x24 at 3.5x above the title. Qud rules a line straight
	# through its middle — deliberately OMITTED here (Daniel's call).
	var mtile := str(m.get("iconTile", ""))
	if mtile != "":
		var it := TextureRect.new()
		var tiles: RefCounted = load("res://QudTiles.gd").new()
		tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
		if not _palette.is_empty():
			tiles.palette = _palette
		it.texture = tiles.texture(mtile,
			tiles.color_of(str(m.get("iconColor", "")), Color.WHITE),
			tiles.color_of(str(m.get("iconDetail", "")), Color.WHITE))
		it.position = Vector2(1496, 187)
		it.size = Vector2(64, 96)   # Qud: the 16x24 tile at 4x, centred on x1528 (measured)
		it.stretch_mode = TextureRect.STRETCH_SCALE
		it.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		it.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(it)
		_detail_labels.append(it)
	var title := _center_label(str(m.get("name", "?")), cx, 278, C_MUT_TITLE, 22)
	var mtype := _center_label("[%s Mutation]" % str(m.get("type", "?")), cx, 304, C_MUT_TYPE, 16)
	var rank := _center_label("RANK %d/%d" % [int(m.get("level", 0)), int(m.get("maxLevel", 10))],
		cx, 326, C_GREEN, 16)
	# body (description + rank text) lives in a scrollbar-less scroller — long
	# mutations (Electrical Generation etc.) overflow the column otherwise
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.position = Vector2(1328, 372)
	scroll.size = Vector2(354, 556)
	add_child(scroll)
	var body_box := VBoxContainer.new()
	body_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_box.add_theme_constant_override("separation", 0)
	scroll.add_child(body_box)
	_detail_labels.append(scroll)
	var desc := _rich(Vector2.ZERO, 16)
	body_box.add_child(desc)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.fit_content = true
	desc.add_theme_color_override("default_color", C_PALE)
	desc.text = QudText.to_bbcode(str(m.get("desc", "")), _palette) + "\n"
	var this_rank := _rich(Vector2.ZERO, 16)
	body_box.add_child(this_rank)
	this_rank.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	this_rank.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	this_rank.fit_content = true
	this_rank.add_theme_color_override("default_color", C_PALE)
	var g := "#" + C_GREEN.to_html(false)
	var body := "[color=%s]This rank:[/color]\n%s" % [g, QudText.to_bbcode(str(m.get("levelText", "")), _palette)]
	if m.has("nextText"):
		body += "\n\n[color=%s]Next rank:[/color]\n%s" % [g, QudText.to_bbcode(str(m.get("nextText", "")), _palette)]
	this_rank.text = body
	for l in [title, mtype, rank]:
		_detail_labels.append(l)

func _center_label(txt: String, cx: float, y: float, col: Color, size_px: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size_px)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(cx - 211, y)
	l.size = Vector2(422, 24)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

func _label(txt: String, pos: Vector2, col: Color, size_px: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.position = pos
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size_px)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

func _rich(pos: Vector2, size_px: int) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.position = pos
	r.size = Vector2(700, 22)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", size_px)
	return r

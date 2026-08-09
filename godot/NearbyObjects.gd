extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column.
##
## TWO RENDERS, one per mode:
##
## USER (QoL): computed CLIENT-SIDE from the snapshot's cells + player position — objects within
##   RADIUS, deduped by (stripped) display name, showing the NEAREST one's arrow, its recoloured
##   TILE image, and a ×count. Sorted nearest. This is the variant Daniel likes; leave it alone.
##
## 1:1: Qud's own rows, shipped by the mod from XRL.UI.ObjectFinder (snapshot key "nearby") and
##   drawn to Qud.UI.ObjectFinderLine's layout — see the geometry block below. The content CANNOT
##   be derived here: Qud's accept test is a seven-rule classifier chain over objects that already
##   passed ShouldShowInNearbyItemsList(), which for a solid cell defers to CanInteractInCellWithSolid.
##   That is why Qud lists two takeable items where this panel's own scan listed a wall and a path.
##
## NOTE: the whole-zone scan (RADIUS = zone size) is the basis for the future Points of Interest menu.

signal left_edge_drag(dx: float)   # 1:1: the ||| grab-bar resizes the side column (as the log does)

const MAX_ROWS := 25
const RADIUS := 1   # king-move radius; 1 = the 3x3 (9 tiles) around the player

# ── 1:1 geometry, measured off Qud at 1920x1080 (sidebar panel-relative, content origin = the
# panel's left content edge, i.e. past the 20px ||| margin). Row pitch and the columns come from a
# pixel profile of a live two-row list; every number here is a measurement, not a guess:
#   row pitch 26 · tile ink x+11 (16x24 box) · arrow x+32 · name x+48 · text baseline +16
#   title ink starts x+6, its baseline 10px above the first row's top
const ROW_H_1TO1 := 26.0
const TILE_X_1TO1 := 11.0
const TILE_W_1TO1 := 16.0
const TILE_H_1TO1 := 24.0
const ARROW_X_1TO1 := 32.0
const NAME_X_1TO1 := 47.0
const BASELINE_1TO1 := 17.0
## Vertical layout, measured against Qud at 1080 (heading ink top 96, first tile ink top 124) and
## expressed against this panel's own origin (93, read off the live layout). The heading is DRAWN
## in 1:1 rather than laid out as a Label because a PanelContainer CLAMPS content_margin_top at 0
## — it needed to sit above that floor, and a negative margin silently did nothing.
const TITLE_BASE_1TO1 := 14.0     # heading baseline: ink top 96 = 93 + 14 - 11 (cap height)
const ROW0_TOP_1TO1 := 25.0       # first row box top: tile ink 124 = 93 + 25 + 6 (sprite inset)
const TITLE_X_1TO1 := 6.0
const RIGHT_PAD_1TO1 := 10.0                      # the weight column stops short of the content edge
## Gap the name keeps from the weight column. Measured, not chosen: Qud's "lead slug →4 ♥1d2" ends
## at 1851.6 with the weight starting 1855.6. A full space here (the first guess) ellipsized a name
## Qud renders whole.
const NAME_GAP_1TO1 := 4.0
const LOG_FONT_FRAC_1TO1 := 0.76                  # same 0.76x body the message log measured at
const TITLE_COLOR_1TO1 := Color8(59, 89, 107)     # Qud's dim grey-teal panel heading (as the log's)
const SEP_MARGIN_1TO1 := 20                       # left content inset so text clears the ||| bar
var SEP_OUTER := QudChrome.q8(68, 99, 112)
var SEP_CENTER := QudChrome.q8(30, 57, 72)
## Qud's body text for these rows (arrow + an unmarked-up name), measured off the live panel's
## glyph cores. q8 because that measurement is what Qud SHOWS — the canvas curve has to be
## compensated for, or Raves draws it a few points off.
var TEXT_1TO1 := QudChrome.q8(167, 192, 186)

var _rt: RichTextLabel
var _tiles: RefCounted   # shared tile recolouring + colour resolution (QudTiles), set in _ready
var _palette := {}       # for rendering coloured names via QudText
var _full := false       # perceived icon (default) vs real — driven by MainFrame's top-menu toggle
var _last_data := {}     # last snapshot, so a mode toggle re-renders without waiting for a new one
var _title: Label
var _vbox: VBoxContainer
var _list: Control       # 1:1: the owner-drawn row list (the QoL path uses _rt instead)
var _qud_rows: Array = []   # 1:1 rows: {tex, arrow, name, right}
var _font: Font
var _dragging := false
var _grab: Control        # the ||| bar's own hit strip, so only IT shows a resize cursor

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	_font = UiFont.make_theme(get_viewport()).default_font
	_build_grab_strip()
	_apply_panel_box()

	_vbox = VBoxContainer.new()
	var v := _vbox
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	_title = Label.new()
	_title.text = "Nearby objects"
	_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(_title)
	# 1:1 list: one owner-drawn surface. A RichTextLabel cannot do this layout — the name has to
	# ELLIPSIZE against a right-aligned weight column, which is a per-row measurement, not a wrap.
	_list = Control.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.visible = false
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.draw.connect(_draw_rows)
	v.add_child(_list)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true             # names are rendered in their Qud colours
	_rt.scroll_active = true
	_rt.selection_enabled = false   # a selectable RTL grabs focus on click and the arrows stop
	_rt.focus_mode = Control.FOCUS_NONE   # reaching the player (the command-bar rule)
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs cells + player + tilesDir + palette).
func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_tiles.palette = _palette
	# 1:1 renders QUD'S rows (mod key "nearby"), never this file's scan. `has()`, not emptiness:
	# an empty list is a real answer (nothing nearby / the overlay is off), and falling back to the
	# QoL scan on it would put walls and ground cover in a list Qud is deliberately showing empty.
	# Only a mod too old to ship the key falls through to the client-side scan.
	if _one_to_one and data.has("nearby"):
		_build_qud_rows(data["nearby"])
		return
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return

	var found := {}   # display name -> {arrow, glyph, tile, main, detail, dist, count}
	for cell in data.get("cells", []):
		var dx := int(cell.get("x", 0)) - px
		var dy := int(cell.get("y", 0)) - py
		var dist: int = maxi(absi(dx), absi(dy))
		if dist > RADIUS:
			continue
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue
			if dist == 0 and bool(obj.get("creature", false)):
				continue                   # the player, on their own cell
			var raw := String(obj.get("display", ""))
			var nm := QudText.strip(raw)      # stripped = stable dedup key
			if nm == "":
				nm = String(obj.get("name", ""))
				raw = nm
			if nm == "" or nm == "[painted ground]":
				continue
			if found.has(nm):
				found[nm]["count"] += 1
				if dist < found[nm]["dist"]:
					found[nm]["dist"] = dist
					found[nm]["arrow"] = _arrow(dx, dy)
			else:
				found[nm] = {
					"arrow": _arrow(dx, dy), "raw": raw, "obj": obj,
					"dist": dist, "count": 1,
				}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])

	var img_h := UiFont.px(get_viewport(), "body") * 2   # match the message log's inline icon size
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	_rt.clear()
	for i in mini(names.size(), MAX_ROWS):
		var e: Dictionary = found[names[i]]
		var o: Dictionary = e["obj"]
		_rt.append_text(String(e["arrow"]) + " ")
		# Perceived icon by default (unidentified -> "unknown" tile via tileP); real tile in full mode.
		var tex: Texture2D = _tiles.texture_for(o, _full)
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(_tiles.glyph_for(o, _full).replace("[", "[lb]"))   # fallback glyph
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		_rt.append_text(" " + QudText.to_bbcode(String(e["raw"]), _palette) + suffix + "\n")

## Driven by MainFrame's global top-menu toggle: perceived icons (default) vs the real ones.
func set_full_info(full: bool) -> void:
	_full = full
	if not _last_data.is_empty():
		set_snapshot(_last_data)

## 1:1 (parity) mode: render the Qud-faithful nearby-objects list instead of the QoL variant.
var _one_to_one := false
func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	# 1:1: let the list size to its rows (Qud's Nearby objects is content-height, with the Message log
	# below taking the rest). fit_content grows the label to its text; scroll off so it doesn't cap.
	# User: the QoL panel scrolls inside its expanded share of the column.
	if _rt != null:
		_rt.fit_content = on
		_rt.scroll_active = not on
		_rt.visible = not on
	if _list != null:
		_list.visible = on
	if _title != null:
		_title.visible = not on     # 1:1 draws the heading itself, at Qud's own offset
	_apply_panel_box()
	_apply_title_style()
	queue_redraw()
	if not _last_data.is_empty():
		set_snapshot(_last_data)

# ── 1:1 render ────────────────────────────────────────────────────────────────────────────────

## The panel box: user mode keeps the framed QoL box; 1:1 drops the border (Qud draws none) and
## insets the content so the ||| grab-bar sits in the left margin — the message log's treatment,
## shared so the two stacked panels present one continuous sidebar edge.
func _apply_panel_box() -> void:
	var sb := StyleBoxFlat.new()
	# q8: Qud's colour is the TARGET and the canvas curve sags it — state the target, compensate.
	sb.bg_color = QudChrome.q8(17, 33, 38) if _one_to_one else QudPalette.CHROME
	sb.content_margin_left = SEP_MARGIN_1TO1 if _one_to_one else 6
	sb.content_margin_right = 6
	sb.content_margin_top = 0 if _one_to_one else 4
	sb.content_margin_bottom = 4
	if not _one_to_one:
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.12)
		sb.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", sb)
	if _grab != null:
		_grab.visible = _one_to_one
		_grab.offset_right = float(SEP_MARGIN_1TO1)

func _apply_title_style() -> void:
	if _title == null:
		return
	if _one_to_one:
		_title.add_theme_font_size_override("font_size",
			int(round(UiFont.px(get_viewport(), "body") * LOG_FONT_FRAC_1TO1)))
		_title.add_theme_color_override("font_color", TITLE_COLOR_1TO1)
	else:
		_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
		_title.remove_theme_color_override("font_color")

## 1:1 only: Qud's "|||" grab-bar down the panel's left edge, continuing the log's below.
func _draw() -> void:
	if not _one_to_one:
		return
	# Qud's bar is NOT three 1px lines: the centre is TWO pixels (1627-1628 at 1080) and the right
	# outer sits at +11, not +10. Measured off both panels in a synced capture.
	var h := size.y
	draw_rect(Rect2(2, 0, 1, h), SEP_OUTER)
	draw_rect(Rect2(6, 0, 2, h), SEP_CENTER)
	draw_rect(Rect2(11, 0, 1, h), SEP_OUTER)

## The ||| margin drags the sidebar edge, exactly as the log's does — the bar is one continuous
## handle down the column, so half of it being inert would be a worse lie than not drawing it.
## The ||| bar is the ONLY part of this panel that resizes anything, so it is the only part that
## may say so. `mouse_default_cursor_shape` is per-CONTROL, and setting it on the panel put the
## horizontal-resize cursor over the whole thing -- reported as "the resize icon dominates", and
## it is a cursor promising a drag that the other 95% of the panel does not do. A child strip the
## width of the bar carries the cursor instead; MOUSE_FILTER_PASS so events still reach
## `_gui_input` below, which is what actually does the dragging.
func _build_grab_strip() -> void:
	if _grab != null:
		return                  # idempotent: a mode toggle must not stack a second strip
	_grab = Control.new()
	_grab.name = "GrabBar"
	_grab.mouse_filter = Control.MOUSE_FILTER_PASS
	_grab.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_grab.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_grab.offset_left = 0
	_grab.offset_right = float(SEP_MARGIN_1TO1)
	add_child(_grab)

func _gui_input(e: InputEvent) -> void:
	if not _one_to_one:
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and e.position.x < float(SEP_MARGIN_1TO1):
			_dragging = true
			accept_event()
		elif not e.pressed:
			_dragging = false
	elif e is InputEventMouseMotion and _dragging:
		left_edge_drag.emit(e.relative.x)
		accept_event()

## Build the 1:1 rows from the mod's "nearby" array (Qud's ObjectFinder output, already filtered
## and sorted — order is Qud's, so it is preserved verbatim).
func _build_qud_rows(rows: Variant) -> void:
	_qud_rows.clear()
	if rows is Array:
		for r in rows:
			if not (r is Dictionary):
				continue
			var o: Dictionary = r
			var right := ""
			# RightText exists ONLY for takeable objects (ObjectFinderLine.setData hides the whole
			# element otherwise) — so a missing "weight" key means no column, not a zero.
			# Rendered through Qud's own {{K|…}} markup so the dim comes from the shipped palette.
			# NO space before "lbs." — Qud's string is `Weight + "lbs."`, and a live capture of a
			# 0-weight row reads "0lbs." flush. (An earlier reading of a wider row as "50 lbs."
			# was the gap in front of the RIGHT-ALIGNED column, not a space inside it.)
			if o.has("weight"):
				right = "{{K|%dlbs.}}" % int(o["weight"])
			_qud_rows.append({
				"tex": _tiles.texture_for(o, _full),
				"arrow": String(o.get("arrow", "")),
				"name": String(o.get("name", "")),
				"right": right,
			})
	# content height drives the panel: Qud's list is exactly its heading plus its rows
	if _list != null:
		_list.custom_minimum_size = Vector2(0, ROW0_TOP_1TO1 + _qud_rows.size() * ROW_H_1TO1)
		_list.queue_redraw()

func _draw_rows() -> void:
	if _font == null or _list == null:
		return
	var px := int(round(UiFont.px(get_viewport(), "body") * LOG_FONT_FRAC_1TO1))
	# the heading rides on this surface too — see TITLE_BASE_1TO1
	_list.draw_string(_font, Vector2(TITLE_X_1TO1, TITLE_BASE_1TO1), "Nearby objects",
		HORIZONTAL_ALIGNMENT_LEFT, -1, px, TITLE_COLOR_1TO1)
	var right_edge := _list.size.x - RIGHT_PAD_1TO1
	for i in _qud_rows.size():
		var r: Dictionary = _qud_rows[i]
		var top := ROW0_TOP_1TO1 + i * ROW_H_1TO1
		var base := top + BASELINE_1TO1
		var tex: Texture2D = r["tex"]
		if tex != null:
			_list.draw_texture_rect(tex,
				Rect2(TILE_X_1TO1, top, TILE_W_1TO1, TILE_H_1TO1), false)
		if String(r["arrow"]) != "":
			_list.draw_string(_font, Vector2(ARROW_X_1TO1, base), String(r["arrow"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, px, TEXT_1TO1)
		# the weight column is right-aligned to the content edge; the name gets what is left and
		# ellipsizes into it — that is why both rows' "lbs." end on the same pixel in Qud
		var adv := _cell_adv(px)
		var limit := right_edge
		var right_txt := String(r["right"])
		if right_txt != "":
			var w := QudText.strip(right_txt).length() * adv
			_draw_runs(right_txt, right_edge - w, base, px, 9999)
			limit = right_edge - w - NAME_GAP_1TO1
		_draw_runs(String(r["name"]), NAME_X_1TO1, base, px, limit)

## One monospace cell width. Measured over 10 glyphs and divided: a single get_string_size("0")
## rounds to whole pixels, and Qud's advance is 9.6 at this size — rounding it to 10 drifted a
## 17-character row 3px right by its end, which ellipsized a name Qud draws whole.
func _cell_adv(px: int) -> float:
	return _font.get_string_size("0000000000", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x / 10.0

## Draw Qud markup as coloured runs on the MONOSPACE CELL GRID, ellipsizing at `limit`.
##
## Every glyph sits at `x + column * advance` — the model Qud lays these rows out with — rather
## than at an accumulated sum of per-run measured widths. Those two agree for a single run and
## diverge once a name carries markup ("lead slug {{c|→4}} {{r|♥}}1d2" is five runs), because each
## run's measured width rounds independently. Truncation happens INSIDE a run so a multi-colour
## name clips the way Qud's does: one "…" at the cut, nothing after it.
func _draw_runs(s: String, x: float, base: float, px: int, limit: float) -> void:
	var adv := _cell_adv(px)
	var max_cols := int(floor((limit - x) / adv))
	var col := 0
	for run in QudText.runs(s, _palette, TEXT_1TO1):
		var txt: String = run[0]
		if txt == "":
			continue
		if col + txt.length() <= max_cols:
			_list.draw_string(_font, Vector2(x + col * adv, base), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1])
			col += txt.length()
			continue
		# does not fit: keep what does, minus one cell for the ellipsis, then stop
		var keep: int = maxi(0, max_cols - col - 1)
		_list.draw_string(_font, Vector2(x + col * adv, base), txt.substr(0, keep) + "…",
			HORIZONTAL_ALIGNMENT_LEFT, -1, px, run[1])
		return

## Compass ARROW from a cell offset (y increases SOUTH). Within RADIUS 1 this is exactly the 8
## neighbours plus the centre.
func _arrow(dx: int, dy: int) -> String:
	if dx == 0 and dy == 0:
		return "·"
	if dx == 0:
		return "↑" if dy < 0 else "↓"
	if dy == 0:
		return "→" if dx > 0 else "←"
	if dx > 0:
		return "↗" if dy < 0 else "↘"
	return "↖" if dy < 0 else "↙"

extends Control

## THE LOAD GAME PICKER — a 1:1 mimic of Caves of Qud's Continue screen
## (ModernSaveManagement), reproduced from measurement (reports/2026-08-03-menu-parity/
## picker_qud.png). Reads the saves straight off disk: every
## Synced/Saves/<GUID>/Primary.json under Qud's support dir, newest first (Qud's order).
##
## Per entry: the character tile (recoloured FColor/DColor via QudTiles, flat dim
## silhouette when unselected), a dotted icon frame (gold when selected), the
## name/level/mode header (gold when selected, cyan otherwise), Location/Last saved
## lines, and the Total size {ID} line which stays dim even on the selected row —
## measured: it nearly vanishes into the selection dither. Hover-select persists
## (Qud's list convention); Esc/[Esc] Back closes. Selecting a save is DISPLAY-ONLY
## for now (parity phase; loading drives Qud later).
##
## Opened by MainMenu's Continue in 1:1 mode only; `closed` fires on Back.

signal closed
signal load_requested(id: String)     # the chosen save's Primary.json ID — MainMenu drives the load
signal delete_requested(id: String)   # confirmed delete — MainMenu sends deletesave to the mod

# palette — measured off the Qud capture, pre-compensated via QudChrome (the 2D canvas
# darkens mid-tones ~x0.885; see QudChrome.gd)
var P_BG := QudChrome.q8(6, 44, 42)
var P_LINE := QudChrome.q8(58, 89, 101)          # dividers, separators
var P_LINE_DIM := QudChrome.q8(47, 72, 82)       # the secondary left rail line
var P_GOLD := QudChrome.q8(200, 184, 57)         # title, selected header, selected frame
var P_CYAN := QudChrome.q8(56, 154, 176)         # unselected entry header
var P_CYAN_SEL := QudChrome.q8(108, 183, 200)    # selected row's "Location:" label
var P_BODY_SEL := QudChrome.q8(168, 194, 187)    # selected row's body values, delete
var P_BODY_DIM := QudChrome.q8(21, 73, 72)       # unselected body, icon silhouette, total-size
var P_CURSOR := QudChrome.q8(197, 207, 207)      # the > cursor

# geometry — measured at 1920x1080 (Qud's fractional row pitch: 125.667)
const ROW_PITCH := 125.667
const ROW0_TOP := 127.0
const ROW_H := 115          # selection dither height
const CELL_X := 594
const CELL_W := 756

var _saves: Array = []       # [{dir, name, level, mode, loc, time, turn, saved, mb, id, icon, fcolor, dcolor}]
var _rows: Array = []        # cell Controls, index-aligned with _saves
var _sel := 0
var _tiles: RefCounted = null

# delete flow — Qud's HandleDelete mirrored: {{R|Delete X}} confirm → deletesave over
# the bridge (MainMenu relays) → poll the save dir off disk → "Game Deleted!" → re-list
var _popup: PopupOverlay = null
var _popup_seq := 0
var _popup_mode := ""        # "confirm" | "deleted"
var _popup_target := {}
var _palette := {}           # colour-code → hex for QudText markup in the popups
var _del_dir := ""           # save dir we're waiting to see vanish
var _del_deadline := 0

func _ready() -> void:
	name = "LoadGameScreen"
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(func(): size = get_viewport_rect().size)
	theme = UiFont.make_theme(get_viewport())
	_tiles = load("res://QudTiles.gd").new()
	_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
	for code in _tiles.COLORS:
		_palette[code] = "#" + Color(_tiles.COLORS[code]).to_html(false)
	set_process(false)   # only runs while polling a pending delete
	_saves = _load_saves()
	_build()

# ── data ───────────────────────────────────────────────────────────────────────

## Qud's save root, per-OS. Each save is a GUID dir holding Primary.json.
static func _saves_root() -> String:
	return InputModel.qud_saves_dir()

func _load_saves() -> Array:
	var out: Array = []
	var root := _saves_root()
	var d := DirAccess.open(root)
	if d == null:
		return out
	for sub in d.get_directories():
		var pj := root.path_join(sub).path_join("Primary.json")
		if not FileAccess.file_exists(pj):
			continue
		var f := FileAccess.open(pj, FileAccess.READ)
		if f == null:
			continue
		var data: Variant = JSON.parse_string(f.get_as_text())
		if not (data is Dictionary):
			continue
		var dirpath := root.path_join(sub)
		out.append({
			"dir": dirpath,
			"name": str(data.get("Name", "?")),
			"level": int(data.get("Level", 0)),
			"mode": str(data.get("GameMode", "?")),
			"loc": str(data.get("Location", "?")),
			"time": str(data.get("InGameTime", "")),
			"turn": int(data.get("Turn", 0)),
			"saved": str(data.get("SaveTime", "")),
			"mb": _dir_mb(dirpath),
			"id": str(data.get("ID", sub)),
			"icon": str(data.get("CharIcon", "")),
			"fcolor": int(data.get("FColor", 89)),
			"dcolor": int(data.get("DColor", 89)),
			"mtime": FileAccess.get_modified_time(pj),
		})
	# Qud lists newest save first (measured against the live picker)
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]))
	return out

## Whole-save-dir size in Qud's units ("1mb"): bytes/1024^2, round half up (like mods).
static func _dir_mb(path: String) -> int:
	var total := 0
	var d := DirAccess.open(path)
	if d == null:
		return 0
	for fn in d.get_files():
		var f := FileAccess.open(path.path_join(fn), FileAccess.READ)
		if f != null:
			total += f.get_length()
	for sub in d.get_directories():
		total += _dir_mb_bytes(path.path_join(sub))
	return int((total + 524288) / 1048576)

static func _dir_mb_bytes(path: String) -> int:
	var total := 0
	var d := DirAccess.open(path)
	if d == null:
		return 0
	for fn in d.get_files():
		var f := FileAccess.open(path.path_join(fn), FileAccess.READ)
		if f != null:
			total += f.get_length()
	for sub in d.get_directories():
		total += _dir_mb_bytes(path.path_join(sub))
	return total

# ── build ──────────────────────────────────────────────────────────────────────

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = P_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# chrome: the main dotted divider (x587, 3-on/3-off, square end caps), the dim
	# secondary rail line (x562) and its two dotted tick marks
	var chrome := Control.new()
	chrome.set_anchors_preset(Control.PRESET_FULL_RECT)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chrome.draw.connect(func():
		var y := 36.0
		while y < 1044.0:
			chrome.draw_rect(Rect2(587, y, 1, minf(3, 1044 - y)), P_LINE)
			y += 6.0
		for cy in [25.0, 1045.0]:
			chrome.draw_rect(Rect2(583, cy, 9, 10), P_LINE)
		# phase measured: dashes sit at y%6 in {1,2,3}, clipped to the 153..996 extent
		y = 151.0
		while y < 997.0:
			var y0 := maxf(y, 153.0)
			if y + 3.0 > y0:
				chrome.draw_rect(Rect2(562, y0, 1, minf(y + 3.0, 997.0) - y0), P_LINE_DIM)
			y += 6.0
		for ty in [160.0, 986.0]:
			for seg in [[564, 2], [568, 3], [574, 2], [578, 3], [585, 2]]:
				chrome.draw_rect(Rect2(seg[0], ty, seg[1], 1), P_LINE_DIM)
		# dotted separators above each entry after the first (3-on/3-off/2-on/3-off)
		for i in range(1, _saves.size()):
			var sy := roundf(ROW0_TOP - 0.5 + i * ROW_PITCH)
			var x := 594.0
			while x < 1344.0:
				chrome.draw_rect(Rect2(x, sy, minf(3, 1344 - x), 1), P_LINE)
				x += 6
				if x < 1344.0:
					chrome.draw_rect(Rect2(x, sy, minf(2, 1344 - x), 1), P_LINE)
				x += 5)
	add_child(chrome)

	# title
	var title := Label.new()
	title.text = "LOAD GAME"
	title.add_theme_color_override("font_color", P_GOLD)
	var fv := FontVariation.new()
	fv.base_font = get_theme_font("font", "Label")
	fv.spacing_glyph = 3
	title.add_theme_font_override("font", fv)
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(602, 100)
	add_child(title)

	# entries (absolutely positioned — Qud's pitch is fractional, a VBox would drift)
	_rows.clear()
	if _saves.is_empty():
		var empty := Label.new()
		empty.text = "No saved games."
		empty.add_theme_color_override("font_color", P_CYAN)
		empty.add_theme_font_size_override("font_size", 16)
		empty.position = Vector2(704, 142)
		add_child(empty)
	for i in range(_saves.size()):
		var cell := _entry(_saves[i], i)
		cell.position = Vector2(CELL_X, roundf(ROW0_TOP + i * ROW_PITCH))
		add_child(cell)
		_rows.append(cell)
	_apply_selection()

	# [Esc] Back chevron (same spot as Records — Qud shares it across these screens)
	var back := Control.new()
	back.position = Vector2(30, 520)
	back.size = Vector2(110, 75)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	back.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: closed.emit())
	back.draw.connect(func():
		back.draw_line(Vector2(48, 12), Vector2(36, 24), QudChrome.q8(120, 140, 138), 3.0)
		back.draw_line(Vector2(36, 24), Vector2(48, 36), QudChrome.q8(120, 140, 138), 3.0))
	add_child(back)
	var bl := RichTextLabel.new()
	bl.bbcode_enabled = true
	bl.fit_content = true
	bl.scroll_active = false
	bl.autowrap_mode = TextServer.AUTOWRAP_OFF
	bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bl.add_theme_font_size_override("normal_font_size", 16)
	bl.text = "[color=#%s][lb]Esc[rb][/color][color=#%s] Back[/color]" % [
		P_GOLD.to_html(false), P_BODY_SEL.to_html(false)]
	bl.position = Vector2(4, 48)
	back.add_child(bl)

	# bottom hint: [icon] navigate  [Space] select  [Delete] delete
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.scroll_active = false
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override("normal_font_size", 16)
	var wht := "#FFFFFF"
	var dimc := "#%s" % P_BODY_SEL.to_html(false)
	var goldc := "#%s" % P_GOLD.to_html(false)
	hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	hint.append_text("[color=%s][lb][/color]" % wht)
	hint.add_image(_nav_icon(15), 22, 15)
	hint.append_text("[color=%s][rb][/color]" % wht)
	hint.append_text("[color=%s] navigate  [/color]" % dimc)
	hint.append_text("[color=%s][lb][/color][color=%s]Space[/color][color=%s][rb][/color]" % [wht, goldc, wht])
	hint.append_text("[color=%s] select  [/color]" % dimc)
	hint.append_text("[color=%s][lb][/color][color=%s]Delete[/color][color=%s][rb][/color]" % [wht, goldc, wht])
	hint.append_text("[color=%s] delete[/color]" % dimc)
	hint.pop()
	hint.position = Vector2(622, 1006)
	add_child(hint)

	# the same luminance-weighted interlace as Records/Options (measured bg pairs
	# (6,44,42)/(2,22,22); a flat 50% cut shreds glyphs)
	var scan := ColorRect.new()
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture;
void fragment() {
	vec4 c = texture(screen_tex, SCREEN_UV);
	float row = floor(FRAGCOORD.y);
	if (mod(row, 2.0) >= 1.0) {
		float lum = max(c.r, max(c.g, c.b)) * 255.0;
		float f = mix(0.5, 1.0, smoothstep(30.0, 180.0, lum));
		COLOR = vec4(c.rgb * f, 1.0);
	} else {
		COLOR = vec4(c.rgb, 1.0);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	scan.material = mat
	add_child(scan)

func _nav_icon(ih: int) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))
	var k := int((ih - g) / 2.0)
	if k < 2:
		k = 2
	var w := 3 * k + 2 * g
	var h := 2 * k + g
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g
	img.fill_rect(Rect2i(mid, 0, k, k), P_GOLD)
	img.fill_rect(Rect2i(0, k + g, k, k), P_GOLD)
	img.fill_rect(Rect2i(mid, k + g, k, k), P_GOLD)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), P_GOLD)
	return ImageTexture.create_from_image(img)

# ── entries ────────────────────────────────────────────────────────────────────

# The selection dither, measured off Qud's picker (light (20,70,72) / dark (14,50,51),
# 7x7 period, anchored to absolute screen coords). Rows are the y%7 phases, cols x%7.
const DITHER_ROWS := ["BABAABA", "AAAAAAB", "BAABABA", "ABAABAA", "AABAABA", "BAABAAA", "ABAABAA"]
var _dither_cache := {}

## A 7x7 dither tile phase-shifted so that a TextureRect at ABSOLUTE (ax, ay) lines its
## pattern up with Qud's screen-anchored weave.
func _dither_tex(ax: int, ay: int) -> ImageTexture:
	var key := "%d_%d" % [ax % 7, ay % 7]
	if _dither_cache.has(key):
		return _dither_cache[key]
	var la := QudChrome.q8(20, 70, 72)
	var da := QudChrome.q8(14, 50, 51)
	var img := Image.create(7, 7, false, Image.FORMAT_RGBA8)
	for y in range(7):
		var row: String = DITHER_ROWS[(y + ay) % 7]
		for x in range(7):
			img.set_pixel(x, y, la if row[(x + ax) % 7] == "A" else da)
	var tex := ImageTexture.create_from_image(img)
	_dither_cache[key] = tex
	return tex

func _entry(sv: Dictionary, idx: int) -> Control:
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(CELL_W, ROW_H)
	cell.size = Vector2(CELL_W, ROW_H)
	cell.mouse_filter = Control.MOUSE_FILTER_STOP
	cell.mouse_entered.connect(func(): _select(idx))
	# hover already selected the row, so a left-click = activate (Qud's picker rule)
	cell.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_select(idx)
			if e.button_index == MOUSE_BUTTON_LEFT:
				_activate(idx))

	# persistent selection dither — the measured 7x7 weave, anchored to SCREEN phase
	# (Qud's dither is screen-continuous; the mods hover tile is a different colourway)
	var hl := TextureRect.new()
	hl.name = "hl"
	hl.texture = _dither_tex(int(CELL_X + 18), int(roundf(ROW0_TOP + idx * ROW_PITCH)))
	hl.stretch_mode = TextureRect.STRETCH_TILE
	hl.position = Vector2(18, 0)
	hl.size = Vector2(735, ROW_H)
	hl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hl.visible = false
	cell.add_child(hl)

	var cur := Label.new()
	cur.name = "cur"
	cur.text = ">"
	cur.add_theme_color_override("font_color", P_CURSOR)
	cur.add_theme_font_size_override("font_size", 16)
	cur.position = Vector2(0, 53)
	cur.visible = false
	cell.add_child(cur)

	# dotted icon frame (drawn; dim normally, gold when selected). The SELECTED frame is
	# taller with dot-triplet top corners; unselected starts 9px lower with single dots
	# — both transcribed off the capture.
	var frame := Control.new()
	frame.name = "frame"
	frame.position = Vector2(21, 14)
	frame.size = Vector2(74, 100)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_meta("on", false)
	frame.draw.connect(func():
		var on: bool = bool(frame.get_meta("on"))
		var col: Color = P_GOLD if on else P_BODY_DIM
		# vertical dash cadence transcribed row-by-row off the capture (Qud scales a
		# unit dot pattern non-integrally, so the dashes run 3-5px — not a clean 3/3)
		var dash := [[0, 3], [5, 2], [9, 2], [15, 3], [21, 4], [29, 3], [35, 4], [42, 4],
			[49, 4], [56, 3], [62, 5], [70, 3], [76, 5], [84, 2], [88, 3], [93, 2], [97, 3]]
		var ytop := 0 if on else 9
		for fx in [0.0, 73.0]:
			for seg in dash:
				if seg[0] + seg[1] <= ytop:
					continue
				var y0 := maxi(int(seg[0]), ytop)
				frame.draw_rect(Rect2(fx, y0, 1, seg[0] + seg[1] - y0), col)
		# corner clusters: stacked 2x2 dots inset at x5/x66 + inboard runs; the top
		# cluster (dots at y0 + the inboard row) only appears on the selected frame
		for cx in [5, 66]:
			if on:
				frame.draw_rect(Rect2(cx, 0, 2, 3), col)
				frame.draw_rect(Rect2(cx, 5, 2, 2), col)
			frame.draw_rect(Rect2(cx, 9, 2, 2), col)
			frame.draw_rect(Rect2(cx, 85, 2, 2), col)
			frame.draw_rect(Rect2(cx, 89, 2, 2), col)
			frame.draw_rect(Rect2(cx, 93, 2, 2), col)
		for ix in [9, 13, 58, 62]:
			if on:
				frame.draw_rect(Rect2(ix, 0, 2, 3), col)
			frame.draw_rect(Rect2(ix, 93, 2, 2), col))
	cell.add_child(frame)

	# the character tile: 16x24 recoloured FColor/DColor, x3.5 nearest, H-FLIPPED (Qud's
	# picker draws creatures facing left — the sprite-facing gotcha) — selected shows
	# full colour, unselected a flat dim silhouette (measured: one colour, no shading)
	var icon := TextureRect.new()
	icon.name = "icon"
	# Qud scales the 16x24 tile x3.646 (58.3x87.5, measured) — NOT a clean x3.5; the
	# non-integer scale + NEAREST gives the same duplicated-row texture Qud shows
	icon.position = Vector2(28, 18.4)
	icon.size = Vector2(58.3, 87.5)
	icon.flip_h = true
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fc: Color = QudChrome.q(_tiles.color_of(String.chr(int(sv["fcolor"])), Color.WHITE))
	var dc: Color = QudChrome.q(_tiles.color_of(String.chr(int(sv["dcolor"])), Color.WHITE))
	icon.set_meta("tex_on", _tiles.texture(str(sv["icon"]), fc, dc))
	icon.set_meta("tex_off", _tiles.texture(str(sv["icon"]), P_BODY_DIM, P_BODY_DIM))
	cell.add_child(icon)

	var head := Label.new()
	head.name = "head"
	head.text = "%s :: Level %d  [%s]" % [str(sv["name"]), int(sv["level"]), str(sv["mode"])]
	head.add_theme_font_size_override("font_size", 16)
	head.position = Vector2(108, 10)
	cell.add_child(head)

	# Location: <loc>, <time> turn <turn> — the "Location:" label brightens cyan on the
	# selected row while its values go pale; unselected rows are uniformly dim
	var loc := RichTextLabel.new()
	loc.name = "loc"
	loc.bbcode_enabled = true
	loc.fit_content = true
	loc.scroll_active = false
	loc.autowrap_mode = TextServer.AUTOWRAP_OFF
	loc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loc.add_theme_font_size_override("normal_font_size", 16)
	loc.position = Vector2(108, 30)
	loc.set_meta("loc_text", "%s, %s turn %d" % [str(sv["loc"]), str(sv["time"]), int(sv["turn"])])
	cell.add_child(loc)

	var saved := RichTextLabel.new()
	saved.name = "saved"
	saved.bbcode_enabled = true
	saved.fit_content = true
	saved.scroll_active = false
	saved.autowrap_mode = TextServer.AUTOWRAP_OFF
	saved.mouse_filter = Control.MOUSE_FILTER_IGNORE
	saved.add_theme_font_size_override("normal_font_size", 16)
	saved.position = Vector2(109, 51)
	saved.set_meta("saved_text", str(sv["saved"]))
	cell.add_child(saved)

	# total size stays DIM even when selected (measured — it sinks into the dither)
	var tot := Label.new()
	tot.text = "Total size: %dmb {%s}" % [int(sv["mb"]), str(sv["id"])]
	tot.add_theme_color_override("font_color", P_BODY_DIM)
	tot.add_theme_font_size_override("font_size", 16)
	tot.position = Vector2(110, 70)
	cell.add_child(tot)

	var del := Label.new()
	del.name = "del"
	del.text = "delete"
	del.add_theme_color_override("font_color", P_BODY_SEL)
	del.add_theme_font_size_override("font_size", 16)
	del.position = Vector2(110, 91)
	del.visible = false
	del.mouse_filter = Control.MOUSE_FILTER_STOP   # clickable (only visible when selected)
	del.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_confirm_delete(idx)
			del.accept_event())
	cell.add_child(del)

	_style(cell, false)
	return cell

func _style(cell: Control, on: bool) -> void:
	for nm in ["hl", "cur", "del"]:
		var n := cell.get_node_or_null(nm)
		if n != null:
			n.visible = on
	var head := cell.get_node_or_null("head")
	if head != null:
		head.add_theme_color_override("font_color", P_GOLD if on else P_CYAN)
	var frame := cell.get_node_or_null("frame")
	if frame != null:
		frame.set_meta("on", on)
		frame.queue_redraw()
	var icon: TextureRect = cell.get_node_or_null("icon")
	if icon != null:
		icon.texture = icon.get_meta("tex_on") if on else icon.get_meta("tex_off")
	var loc: RichTextLabel = cell.get_node_or_null("loc")
	if loc != null:
		loc.text = "[color=#%s]Location:[/color] [color=#%s]%s[/color]" % [
			(P_CYAN_SEL if on else P_BODY_DIM).to_html(false),
			(P_BODY_SEL if on else P_BODY_DIM).to_html(false),
			str(loc.get_meta("loc_text")).replace("[", "[lb]")]
	var saved: RichTextLabel = cell.get_node_or_null("saved")
	if saved != null:
		saved.text = "[color=#%s]Last saved:[/color] [color=#%s]%s[/color]" % [
			(P_CYAN_SEL if on else P_BODY_DIM).to_html(false),
			(P_BODY_SEL if on else P_BODY_DIM).to_html(false),
			str(saved.get_meta("saved_text")).replace("[", "[lb]")]

# ── selection + input ──────────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

## Chosen (click / Space): hand the save ID up — MainMenu sends the bridge command
## and enters the viewer once the game goes live.
func _activate(idx: int) -> void:
	if idx < 0 or idx >= _saves.size():
		return
	load_requested.emit(str(_saves[idx]["id"]))

# ── delete flow (mirrors Qud's SaveManagement.HandleDelete) ────────────────────

func _ensure_popup() -> void:
	if _popup != null:
		return
	_popup = PopupOverlay.new()
	add_child(_popup)
	_popup.answered.connect(_on_popup_answered)

## Qud's exact popup shapes: AcceptCancelButton for the confirm, AcceptButton after.
func _show_qud_popup(title: String, message: String, cancelable: bool) -> void:
	_ensure_popup()
	_popup_seq += 1
	var btns := [{"text": "{{y|Accept}}", "command": "keep", "hotkey": "Accept"}]
	if cancelable:
		btns.append({"text": "{{y|Cancel}}", "command": "Cancel", "hotkey": "Cancel"})
	_popup.show_popup({"id": _popup_seq, "title": title, "message": message,
		"buttons": btns}, _palette)

func _confirm_delete(idx: int) -> void:
	if idx < 0 or idx >= _saves.size() or _del_dir != "":
		return
	_select(idx)
	_popup_mode = "confirm"
	_popup_target = _saves[idx]
	var nm := str(_popup_target["name"])
	_show_qud_popup("{{R|Delete %s}}" % nm,
		"Are you sure you want to delete the save game for %s?" % nm, true)

func _on_popup_answered(payload: Dictionary) -> void:
	var mode := _popup_mode
	_popup_mode = ""
	if mode == "confirm":
		if str(payload.get("btn", "")) == "Cancel":
			return
		delete_requested.emit(str(_popup_target["id"]))
		_del_dir = str(_popup_target["dir"])
		_del_deadline = Time.get_ticks_msec() + 8000
		set_process(true)   # poll the dir off disk
	elif mode == "deleted":
		_reload()

## Poll for the mod's delete landing on disk; then Qud's "Game Deleted!" popup.
func _process(_dt: float) -> void:
	if _del_dir == "":
		set_process(false)
		return
	var gone := not FileAccess.file_exists(_del_dir.path_join("Primary.json"))
	if not gone and Time.get_ticks_msec() < _del_deadline:
		return
	_del_dir = ""
	set_process(false)
	if gone:
		_popup_mode = "deleted"
		_show_qud_popup("", "Game Deleted!", false)
	else:
		_reload()   # delete never landed — just resync the list quietly

## Re-read the saves and rebuild the whole screen (it's static and cheap). Qud
## Exits the picker when the last save is gone — mirror with `closed`.
func _reload() -> void:
	_saves = _load_saves()
	if _saves.is_empty():
		closed.emit()
		return
	_sel = clampi(_sel, 0, _saves.size() - 1)
	_popup = null   # child — freed with the rest; recreated lazily
	for c in get_children():
		c.queue_free()
	_rows.clear()
	_build()

func _apply_selection() -> void:
	for i in range(_rows.size()):
		_style(_rows[i], i == _sel)

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		closed.emit()
		accept_event()
	elif e.is_action_pressed("ui_accept"):
		_activate(_sel); accept_event()
	elif e is InputEventKey and e.pressed and (e.keycode == KEY_DELETE or e.keycode == KEY_BACKSPACE):
		# the Mac "delete" key is BACKSPACE; forward-delete is KEY_DELETE — honour both
		_confirm_delete(_sel); accept_event()
	elif e.is_action_pressed("ui_down"):
		_select(mini(_sel + 1, _rows.size() - 1)); accept_event()
	elif e.is_action_pressed("ui_up"):
		_select(maxi(_sel - 1, 0)); accept_event()

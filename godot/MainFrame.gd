extends Control

## MAIN GAMEPLAY FRAMING — the chrome around the whole gameplay view.
##
## This is ROUGH framing only: real Control chrome (status bar, vitals, menus, command bar) with
## PLACEHOLDER data, plus labelled placeholder CELLS for the sub-views that each get their own Godot
## scene later (the Holodeck, minimap, nearby-objects, message log, …). The layout is five stacked
## rows; row 3 (the Holodeck + side panels) expands to take the free space, split by a draggable
## "grabby" separator.
##
## Built in GDScript (like Main.gd / OnboardingControl) so the .tscn stays a single node. Fonts come
## from the one source of truth, UiFont — the root theme propagates to every child Control here (no
## CanvasLayer in between, so it just inherits). Press F12 to drop a screenshot next to the others.
##
## NOT wired to Qud yet — it runs standalone so the layout can be iterated fast. Placeholder values
## are illustrative; the real bindings arrive with each view.

# Chrome colours from Caves of Qud's canonical palette (see QudPalette.gd / wiki Visual Style). Inlined
# as literal Colors so they stay compile-time consts; codes noted in comments.
const COL_HUNGER := Color("e99f10")           # O — hunger / food-orange
const COL_THIRST := Color("0096ff")           # B — thirst / water-blue (water is also currency)
const COL_HP := Color("00c420")               # G — HP bar green
const COL_EXP := Color("40a4b9")              # c — LVL/EXP bar (dark cyan)
# 1:1 mode — Qud's own muted vitals (sampled from Qud): white HP text, grey LVL text, dark-green bar.
# User mode keeps the bright COL_HP / COL_EXP above.
const COL_HP_1TO1 := Color(1, 1, 1)           # Qud: HP text white
const COL_EXP_1TO1 := Color8(146, 169, 164)   # Qud: LVL/EXP text light grey
const COL_HP_BAR_1TO1 := Color8(25, 89, 34)   # Qud: HP bar dark green (#195922)
const COL_EXP_BAR_1TO1 := Color8(47, 80, 86)  # Qud: LVL/EXP bar muted teal (sampled with xp on the bar)
# Qud colours the HP text by health % (GameObject.GetHPColor): >=100 white, 66-99 green, 33-65 gold,
# 15-32 red, <15 dark red. RGB from Qud's palette (red sampled from a live low-HP capture).
const COL_HP_GREEN := Color8(0, 193, 46)      # &G green (66-99%)
const COL_HP_GOLD := Color8(214, 154, 20)     # &W gold (33-65%)
const COL_HP_RED := Color8(209, 58, 0)        # &R red (15-32%; sampled)
const COL_HP_DARKRED := Color8(140, 32, 8)    # &r dark red (<15%)
const COL_STAT_TEAL := Color("2b6382")        # AV/DV/MA — Qud tints these teal-blue (QN/MS stay neutral)
const COL_DIM := Color(0.69, 0.79, 0.76, 0.45)   # y (grey), dimmed — hints/captions
const COL_BORDER := Color(0.69, 0.79, 0.76, 0.16) # y (grey), faint — panel edges
# The character name is NOT the teal `y` default — Qud renders it a desaturated NEUTRAL grey
# (measured off the top bar: R≈G≈B, glyph core ~161, peak ~180 → ≈ #b0b0b0), a touch smaller than
# body (x-height 9px vs 11px → the caption role, 0.85×body). See reports/1to1-topbar-name-separator.md.
const COL_NAME := Color("b0b0b0")             # character name — neutral grey (not teal y)
# Qud draws its UI CHROME on a near-black neutral (measured: top-bar modal bg (11,14,15)), which is
# darker and greyer than ANY tile-palette colour — the 18-colour palette is for the game WORLD, not the
# chrome. So the world/clear stays palette k (the play area samples to k), but the panels use that
# near-black. (Earlier k-for-panels read too green; K #155352 read as a bright teal box.)
const COL_PANEL := Color("0c0f10")            # UI near-black chrome fill (Qud's bars ≈ 11,14,15)
const COL_BG := Color("0f3b3a")               # k — world/clear background ("Qud viridian")

var _holo: Node             # the Main.tscn instance rendering full-window into the ROOT viewport (null until Connect)
var _holo_host: Control     # the row-3 left column (control bar + the transparent hole)
var _holo_hole: Control     # the transparent row-3 area the full-window 3D shows through
var _holo_hint: Label       # centred hint in the hole (hidden once the viewport is on)
var _connect_btn: Button    # stage 1: bridge + data, no 3D
var _render_btn: Button     # stage 2: turn the 3D on

# Live status-bar labels, updated from each snapshot's `stats` block.
var _portrait: TextureRect  # the player's own tile, top-left (Qud's character icon)
var _tiles: RefCounted      # QudTiles, for resolving the portrait (and any future bar icons)
var _l_name: Label
var _l_temp: Label
var _l_weight: Label
var _l_water: Label
var _l_qn: Label
var _l_ms: Label
var _l_av: Label
var _l_dv: Label
var _l_ma: Label
var _l_biome: Label
var _l_hunger: Label
var _l_thirst: Label
var _daynight: Label           # day/night glyph — fallback until the clock sprites are extracted
var _clock: TextureRect        # Qud's day/night sky disc (PlayerStatusBar.QudTimeImages, by time-of-day)
var _clock_tex: Array = []     # loaded clock_0..N textures
# Top-row groups — a center-on-% layout (positions read off Qud): each group is placed independently in
# _relayout_topbar so content-width changes (food status, gold digits) grow it around its centre instead
# of shoving neighbours. Left/right clusters are edge-anchored; T-group & stats centre on their %s.
var _topbar: Control
var _grp_left: HBoxContainer    # avatar + name (left edge)
var _grp_t: HBoxContainer       # T:temp :: food water :: weight $   (centre 30%)
var _grp_stats: HBoxContainer   # QN :: MS :: AV :: DV :: MA          (centre 65%)
var _grp_right: HBoxContainer   # sky disc :: zone (right edge)
var _sep1: Control
var _sep2: Control
var _sep3: Control
# T-group & stats are NOT at fixed % of the bar — _relayout_topbar splits the slack into 3 equal gaps
# (measured: Qud tracks the right cluster, not the window width). See _relayout_topbar.
const TOPBAR_SEP := 10           # within-group spacing (Qud's :: gaps are looser than our default 6)
const TOPBAR_TRACKING := 1       # extra glyph spacing — Qud's top bar tracks looser than Source Code Pro
const STAT_PITCH := 86           # Qud centres each stat on a uniform ~86px grid (not natural text width)
const VITALS_BOX_H := 18         # Qud's HP/EXP bar box height — the bar fills the whole row, text on top
const VITALS_USER_INSET := 170   # user mode: inset the bar behind the label so green text stays readable
const COL_VITALS_TRACK := Color8(19, 23, 26)   # Qud's empty-bar track (dark)
var _l_hp: RichTextLabel   # HP line — RichText so only the current-HP number is health-tinted (like Qud)
var _bar_hp: ProgressBar
var _l_exp: Label
var _bar_exp: ProgressBar
var _msglog: Control        # the Message log view (MessageLog.gd)
var _nearby: Control        # the Nearby objects view (NearbyObjects.gd)
var _minimap: Control       # the Minimap view (MinimapView.gd)
var _effects: Control       # the Active effects view (ActiveEffects.gd)
var _target: Control        # the Target view (TargetView.gd)
var _context: Control       # the Context menu view (ContextMenu.gd)
var _command: Control       # the Command bar view (CommandBar.gd, row 5)
var _info_btn: Button       # top-menu Perceived/Full toggle
var _full_info := bool(Settings.get_value("full_info", false))  # perceived (false) vs full; Options default
var _panels: Array = []     # every sub-view; each has set_snapshot(data) (some also set_full_info)

# --- 1:1 (parity) layout handles ----------------------------------------------
# In 1:1 mode the chrome is reshaped to match Qud: a wider side column, the verbose top menu collapses
# to Qud's compact icon cluster, and the dev (Connect / viewport) strip is hidden. User mode is untouched.
var _menu_verbose: HBoxContainer   # user-mode top menu (verbose text buttons)
var _menu_compact: HBoxContainer   # 1:1 top menu (Qud's compact icon cluster)
var _row_split: HSplitContainer    # row-3 split (holo | side); sidebar width set per mode
var _side: VBoxContainer           # the row-3 side column (panels)
# 1:1 only: Qud draws one continuous background behind the top strip (rows 1+2) and one behind the bottom
# strip (rows 4+5) — no playfield showing through the inter-element gaps. We back the chrome with two
# opaque rects sized to the strips above/below the play hole (row 3).
var _top_bg: ColorRect
var _bottom_bg: ColorRect
const ROW_BG_1TO1 := Color8(19, 23, 26)   # Qud's continuous chrome-strip background
var _dev_bar: Control              # holodeck cell's Connect/Turn-on-viewport strip (hidden in 1:1)
const SIDEBAR_FRAC_1TO1 := 0.153   # Qud's MINIMUM message-log width ≈ 15.3% (293px at 1920 — matches a Qud
                                   # log dragged to its minimum, which maximises the playfield)
const SIDEBAR_W_USER := 320.0      # user-mode side-column min width (the original value)

var _crt_layer: CanvasLayer        # CRT scanline+vignette overlay above everything (Settings "crt")

# Mod-version handshake. The mod sends `protocol` (mod/Protocol.cs Version) each snapshot; the client
# requires at least MIN and understands up to CLIENT. Mismatch -> a message-log status line, so a stale
# mod (deployed but Qud not restarted) is visible instead of silently shipping old behaviour.
const MIN_MOD_PROTOCOL := 3   # oldest mod wire version this client can rely on (needs `liquid` + `onFire`)
const CLIENT_PROTOCOL := 3    # newest wire version this client was built to understand
var _mod_status := 0          # 0 unknown, 1 current, 2 mod-too-old, 3 client-too-old — update log only on change

func _ready() -> void:
	name = "MainFrame"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())   # one source of truth; children inherit
	_tiles = load("res://QudTiles.gd").new()    # for the status-bar character portrait
	get_viewport().size_changed.connect(_on_resize)

	# No full-window background rect: the Holodeck now renders 3D into THIS (root) viewport, full-window,
	# with the chrome floating on top. A hole in row 3 lets that 3D show through — a covering ColorRect
	# would hide it. The clear colour stands in for the panel bg in the thin gaps between strips and
	# before the Holodeck connects.
	RenderingServer.set_default_clear_color(COL_BG)

	# 1:1 continuous chrome-strip backgrounds — added FIRST so they sit behind the rows (and over the
	# full-window playfield), filling the gaps the playfield used to show through. Positioned in _layout_row_bgs.
	_top_bg = _make_row_bg()
	_bottom_bg = _make_row_bg()

	var rows := VBoxContainer.new()
	rows.set_anchors_preset(Control.PRESET_FULL_RECT)
	rows.add_theme_constant_override("separation", 4)
	add_child(rows)

	rows.add_child(_row_status())        # 1: top status strip
	rows.add_child(_row_vitals_menu())   # 2: HP/EXP  |  top menu
	rows.add_child(_row_main())          # 3: Holodeck | side panels  (expands)
	rows.add_child(_row_context())       # 4: effects | target | context menu
	rows.add_child(_row_command())       # 5: command bar (abilities)

	# The registry of sub-views (created inside the row builders above). _apply_stats feeds them all.
	_panels = [_minimap, _nearby, _msglog, _effects, _target, _context, _command].filter(
		func(p): return p != null)
	_apply_full_info()                   # init the toggle label + push the default (perceived) to views
	_add_crt_overlay()                   # Qud's CRT terminal look, on top of the chrome + 3D

	# Resume (Continue / New Game with the bridge up): MainMenu set this so we AUTO-CONNECT the data
	# stage now, rather than stranding the player at the empty "▶ Connect (data)" prompt. Data-only —
	# the 3D viewport stays a manual opt-in ("▶ Turn on viewport"). Deferred so every row/button the
	# connect path touches is fully built first; the flag is one-shot (cleared here).
	if get_tree().has_meta("holo_auto_connect") and bool(get_tree().get_meta("holo_auto_connect")):
		get_tree().remove_meta("holo_auto_connect")
		_connect_holodeck.call_deferred()

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())
	pass  # CRT logical_h is pushed in _process
	# The 1:1 sidebar is a fraction of the window, and the camera inset derives from it — re-apply both.
	if Settings.one_to_one():
		_apply_layout_mode(true)
	else:
		_apply_vitals_mode(false)   # user mode: inset the vitals bar + keep bright colours (overlay defaults to 1:1)
	_layout_row_bgs.call_deferred()

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F12:
		_shot()

# ── helpers ────────────────────────────────────────────────────────────────

## Qud's day/night clock index (from PlayerStatusBar): a JoppaWorld day maps to 7 day + 3 night sprites.
func _clock_index(t: Dictionary) -> int:
	if _clock_tex.is_empty():
		return -1
	var spd: float = maxf(1.0, float(t.get("segmentsPerDay", 12000)))
	var seg: float = float(t.get("segment", spd * 0.5))
	var day_seg := seg / spd * 12000.0            # normalise to Qud's 12000-segment day
	var num2 := int(day_seg / 10.0)
	num2 = (num2 + 875) % 1200
	var idx: int
	if num2 < 675:
		idx = int(num2 * 7 / 675.0)               # day: 0..6
	else:
		idx = 7 + int((num2 - 675) * 3 / 525.0)   # night: 7..9
	return clampi(idx, 0, _clock_tex.size() - 1)

## Load the clock sprites once the mod has exported them (clock_0..N in the title dir); polled per snapshot.
func _ensure_clocks() -> void:
	if not _clock_tex.is_empty():
		return
	var arr: Array = []
	var i := 0
	while true:
		var tex := _load_clock_tex(i)
		if tex == null:
			break
		arr.append(tex)
		i += 1
	if not arr.is_empty():
		_clock_tex = arr

## Load a nav-bar icon (nav_<key>.png in the title dir), extracted from Qud's ActiveButtons.
func _load_nav_icon(key: String) -> Texture2D:
	return _load_title_png("nav_%s.png" % key)

func _load_title_png(fname: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join(fname)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)

func _load_clock_tex(i: int) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join("clock_%d.png" % i)
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Every Label in the subtree (for a uniform per-strip font size).
func _labels_under(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Label:
			out.append(c)
		out.append_array(_labels_under(c))
	return out

func _text(s: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = s
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	if role != "body":
		l.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), role))
	return l

func _sep() -> VSeparator:
	return VSeparator.new()

## A bordered panel — used for the chrome strips and as the frame around placeholder cells.
func _panel_style(bg := COL_PANEL) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(1)
	sb.border_color = COL_BORDER
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb

func _strip() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	return p

## A labelled placeholder for a sub-view that gets its own Godot scene later.
func _cell(title: String, min_size := Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(QudPalette.CHROME))
	if min_size != Vector2.ZERO:
		p.custom_minimum_size = min_size
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(v)
	var t := _text(title)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var hint := _text("(view)", COL_DIM, "caption")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)
	return p

## A little square placeholder for an icon (player portrait, ability icon, …).
func _icon(px_size: float, col := Color(0.30, 0.34, 0.42)) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(px_size, px_size)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(3)
	p.add_theme_stylebox_override("panel", sb)
	return p

func _menu_btn(txt: String) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	return b

func _bar(value: float, maxv: float, col: Color) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.min_value = 0.0
	pb.max_value = maxv
	pb.value = value
	pb.show_percentage = false
	pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bgs := StyleBoxFlat.new()
	bgs.bg_color = COL_VITALS_TRACK          # Qud's dark track; sharp corners (Qud bars aren't rounded)
	var fills := StyleBoxFlat.new()
	fills.bg_color = col
	pb.add_theme_stylebox_override("background", bgs)
	pb.add_theme_stylebox_override("fill", fills)
	return pb

## One vitals row (HP or LVL/EXP): the bar fills the box, the label + numbers drawn ON TOP (Qud's
## layout). 1:1 → bar spans the full box; user → bar inset behind the label (_apply_vitals_mode sets it).
func _vitals_row(lbl: Control, pb: ProgressBar) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, VITALS_BOX_H)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pb.set_anchors_preset(Control.PRESET_FULL_RECT)
	pb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pb)
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.offset_left = 19                       # inset the text to ~x21, aligning with the avatar column (Qud)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if lbl is Label:
		(lbl as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		(lbl as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	elif lbl is RichTextLabel:
		lbl.offset_top = 2.0                   # RichText has no vertical_alignment — nudge to centre in the box
	row.add_child(lbl)                         # added after the bar → renders on top
	return row

## The HP line: a RichTextLabel so only the current-HP number is colour-coded by health (Qud's GetHPColor);
## the "HP:" prefix and "/ max" stay white. vcentred in the box via a small top offset (RichText has no
## vertical_alignment). Font matches the other vitals text (theme mono + the 0.85×body size).
func _hp_rich(font_size: int) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = false
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.clip_contents = false
	rt.add_theme_font_size_override("normal_font_size", font_size)
	rt.text = "HP: —"
	return rt

# Qud's within-group divider — a compact 2×2 block of dim squares (not text colons).
func _dots(cell_w := 0) -> Control:
	var d := Control.new()
	var sq := 2
	var gap := 2
	var side := sq * 2 + gap
	var w := maxi(side, cell_w)                 # a wider cell floats the :: in a bigger gap (Qud's T-group)
	var ox := (w - side) / 2                     # centre the dot block in the cell
	d.custom_minimum_size = Vector2(w, side)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for iy in range(2):
		for ix in range(2):
			var dot := ColorRect.new()
			dot.color = COL_DIM
			dot.position = Vector2(ox + ix * (sq + gap), iy * (sq + gap))
			dot.size = Vector2(sq, sq)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			d.add_child(dot)
	return d

## One stat on Qud's uniform grid: the label IS the fixed-pitch cell (centred text, natural height so the
## group sizes right), with the :: separator straddling the label's left edge (the gap to the previous
## stat), where Qud draws it. first ⇒ no ::.
func _stat_cell(lbl: Label, first: bool) -> Label:
	lbl.custom_minimum_size.x = STAT_PITCH
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not first:
		var d := _dots()
		d.anchor_top = 0.5;  d.anchor_bottom = 0.5   # vertically centre the :: in the label …
		d.offset_top = -3.0; d.offset_bottom = 3.0
		d.offset_left = -3.0; d.offset_right = 3.0    # … straddling x = 0 (the label's left edge / gap)
		lbl.add_child(d)
	return lbl

# An expanding horizontal rule that FILLS the gap between groups, so the bar spreads its groups edge to
# edge like Qud (name far-left, zone far-right). Qud caps each rule with a DOUBLE vertical bar (║) where
# it meets a group, so: ║────────║.
func _rule(frac := 0.0) -> Control:
	var row := HBoxContainer.new()
	if frac > 0.0:   # fixed width (Qud left-packs name+T-group, so those gaps are fixed, not shared)
		row.custom_minimum_size = Vector2(get_viewport_rect().size.x * frac, 0)
		row.size_flags_horizontal = Control.SIZE_FILL
	else:
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(30, 0)
	row.add_theme_constant_override("separation", 3)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_rule_cap())
	var line := ColorRect.new()
	line.color = COL_BORDER
	line.custom_minimum_size = Vector2(8, 2)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	row.add_child(_rule_cap())
	return row

# The double vertical bar (║) Qud draws where a rule meets a group.
func _rule_cap() -> Control:
	var cap := Control.new()
	var ch := int(round(UiFont.px(get_viewport(), "body") * 0.6))
	cap.custom_minimum_size = Vector2(4, ch)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for bx in [0, 3]:
		var bar := ColorRect.new()
		bar.color = COL_BORDER
		bar.anchor_top = 0.0
		bar.anchor_bottom = 1.0
		bar.offset_left = bx
		bar.offset_right = bx + 1
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.add_child(bar)
	return cap

## A free-positioned separator for the center-on-% top row: a horizontal line spanning the Control's
## width with Qud's double vertical-bar (║) cap at each end. _place_sep sets its width to the live gap.
func _sep_rule() -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ch := int(round(UiFont.px(get_viewport(), "body") * 0.6))
	c.custom_minimum_size = Vector2(24, ch)
	var line := ColorRect.new()
	line.color = COL_BORDER
	line.anchor_left = 0.0; line.anchor_right = 1.0
	line.anchor_top = 0.5; line.anchor_bottom = 0.5
	line.offset_left = 5; line.offset_right = -5
	line.offset_top = -1; line.offset_bottom = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(line)
	for spec in [[0, false], [3, false], [0, true], [3, true]]:
		var bar := ColorRect.new()
		bar.color = COL_BORDER
		bar.anchor_top = 0.5; bar.anchor_bottom = 0.5
		bar.offset_top = -ch * 0.5; bar.offset_bottom = ch * 0.5
		var off: int = spec[0]
		if spec[1]:
			bar.anchor_left = 1.0; bar.anchor_right = 1.0
			bar.offset_left = -(off + 1); bar.offset_right = -off
		else:
			bar.anchor_left = 0.0; bar.anchor_right = 0.0
			bar.offset_left = off; bar.offset_right = off + 1
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(bar)
	return c

# Colour for a food/water status word, following Qud (good = green, worsening = gold → orange → red).
const _STATUS_GOOD := ["sated", "overfed", "full", "quenched", "tumescent", "slaked", "watered"]
const _STATUS_WARN := ["hungry", "peckish", "thirsty"]
const _STATUS_BAD := ["famished", "parched"]
const _STATUS_CRIT := ["starving", "dehydrated"]
func _status_color(word: String) -> Color:
	var w := word.to_lower().strip_edges()
	if _STATUS_GOOD.has(w): return Color("00c420")   # G — green
	if _STATUS_WARN.has(w): return Color("cfc041")   # W — gold
	if _STATUS_BAD.has(w): return Color("e99f10")    # O — orange
	if _STATUS_CRIT.has(w): return Color("d74200")   # R — red
	return QudPalette.TEXT                            # neutral / unknown

func _set_status_label(label: Label, word: String) -> void:
	label.text = word
	label.add_theme_color_override("font_color", _status_color(word))

# ── row 1: status strip ──────────────────────────────────────────────────────
# Qud's top bar spreads its groups across the whole width with horizontal rules between them and "::"
# dividers within: [icon name] ══ T:temp :: food water :: weight $ ══ QN::MS::AV::DV::MA ══ [zone].

func _row_status() -> Control:
	var strip := _strip()
	# Trim the space below the bar: Qud's row 2 starts ~4px higher. The bar (and its vcentred avatar/text)
	# stays put; only the strip's bottom shrinks, lifting row 2 to Qud's y.
	var sstyle: StyleBoxFlat = _panel_style()
	sstyle.content_margin_bottom = 1
	strip.add_theme_stylebox_override("panel", sstyle)
	var bpx := UiFont.px(get_viewport(), "body")
	var isz := int(bpx * 1.7)                          # avatar scale, matched to Qud
	var bar := Control.new()                            # free-positioning host; groups placed by _relayout_topbar
	bar.custom_minimum_size = Vector2(0, isz)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(bar)
	_topbar = bar

	# ── left cluster: avatar + name (left edge) ──
	# Qud leaves ~20px between the avatar and the name; the default 10px group gap left the name ~6px
	# left of Qud. Widen just this group's separation (the avatar itself stays aligned at Qud's x).
	_grp_left = _grp()
	_grp_left.add_theme_constant_override("separation", 16)
	_portrait = TextureRect.new()                      # player tile, filled from each snapshot's `player`
	_portrait.custom_minimum_size = Vector2(round(isz * 16.0 / 24.0), isz)
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var pm := MarginContainer.new()
	pm.add_theme_constant_override("margin_left", int(round(bpx * 0.62)))
	pm.add_child(_portrait)
	_grp_left.add_child(pm)
	_l_name = _text("—", COL_NAME, "caption")
	_l_name.clip_text = false
	_grp_left.add_child(_l_name)
	bar.add_child(_grp_left)

	# ── T-group (centre 30%): T:temp :: food water :: weight $ ──
	# Qud's :: gaps here are ~44px (much looser than its word spaces); our default 6px dots left them
	# ~30px, so the group ran 20px narrow. Widen just these two :: to Qud's gap (word spaces stay tight).
	_grp_t = _grp()
	_l_temp = _text("—"); _grp_t.add_child(_l_temp)
	_grp_t.add_child(_dots(17))
	_l_hunger = _text("—", COL_HUNGER); _grp_t.add_child(_l_hunger)   # food status (colour per-state)
	_l_thirst = _text("—", COL_THIRST); _grp_t.add_child(_l_thirst)   # water status (colour per-state)
	_grp_t.add_child(_dots(17))
	_l_weight = _text("—"); _grp_t.add_child(_l_weight)               # carry weight cur/max
	_l_water = _text("—", COL_THIRST); _grp_t.add_child(_l_water)      # fresh water in drams (= currency)
	bar.add_child(_grp_t)

	# ── stats (centre 65%): QN :: MS :: AV :: DV :: MA ──
	# Qud lays these on a uniform ~86px grid (each stat CENTRED in its cell), so narrow stats (AV/DV/MA)
	# don't bunch up like natural HBox flow. Each stat is a fixed-width centred cell; the :: sits at the
	# cell boundary (the gap), where Qud draws it. Separation 0 → pitch == cell width.
	_grp_stats = _grp()
	_grp_stats.add_theme_constant_override("separation", 0)
	_l_qn = _text("QN: —"); _grp_stats.add_child(_stat_cell(_l_qn, true))
	_l_ms = _text("MS: —"); _grp_stats.add_child(_stat_cell(_l_ms, false))
	_l_av = _text("AV: —", COL_STAT_TEAL); _grp_stats.add_child(_stat_cell(_l_av, false))   # teal, as in Qud
	_l_dv = _text("DV: —", COL_STAT_TEAL); _grp_stats.add_child(_stat_cell(_l_dv, false))
	_l_ma = _text("MA: —", COL_STAT_TEAL); _grp_stats.add_child(_stat_cell(_l_ma, false))
	bar.add_child(_grp_stats)

	# ── right cluster: sky disc :: zone (right edge) ──
	_grp_right = _grp()
	# Qud sets the disc and the zone name ~42px apart; the default 10px group separation packed them too
	# tight (26px), which shoved the narrower disc rightward. 18px → the ~42px gap Qud shows.
	_grp_right.add_theme_constant_override("separation", 18)
	_clock = TextureRect.new()                          # Qud's day/night sky disc (real sprite)
	_clock.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_clock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_clock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var cw := int(round(bpx * 2.3))                     # disc renders ~48px wide, Qud's native sprite size
	_clock.custom_minimum_size = Vector2(cw, int(round(cw * 0.5)))   # the disc sprite is 2:1 (48x24)
	_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_clock.visible = false
	_grp_right.add_child(_clock)
	_daynight = _text("☾")                              # glyph fallback until the sprites land
	_grp_right.add_child(_daynight)
	_grp_right.add_child(_dots())                        # :: between the sky disc and the zone name
	_l_biome = _text("—"); _grp_right.add_child(_l_biome)   # zone / biome name
	bar.add_child(_grp_right)

	# Separators fill the gaps between adjacent groups (sized to the live gap in _relayout_topbar).
	_sep1 = _sep_rule(); bar.add_child(_sep1)
	_sep2 = _sep_rule(); bar.add_child(_sep2)
	_sep3 = _sep_rule(); bar.add_child(_sep3)

	# Qud's top bar is smaller than body — one uniform size for every glyph — and tracks looser than
	# Source Code Pro's default, so apply a FontVariation with extra glyph spacing to match its width.
	var tp := int(round(bpx * 0.72))
	var topfont := FontVariation.new()
	topfont.base_font = load("res://fonts/SourceCodePro-Regular.ttf")
	topfont.spacing_glyph = TOPBAR_TRACKING
	for lbl in _labels_under(bar):
		lbl.add_theme_font_override("font", topfont)
		lbl.add_theme_font_size_override("font_size", tp)

	bar.resized.connect(_relayout_topbar)
	_relayout_topbar.call_deferred()
	return strip

## A within-group HBox (tight, Qud-like spacing). Sized to content; positioned by _relayout_topbar.
func _grp() -> HBoxContainer:
	var g := HBoxContainer.new()
	g.add_theme_constant_override("separation", TOPBAR_SEP)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return g

## Place the four top-row groups: [left][gap][T][gap][stats][gap][right] with the THREE gaps EQUAL —
## the slack split three ways. Left edge-anchored, right cluster right-anchored (~8px inset). Derived by
## measuring Qud across zone lengths (Joppa/Rustwell/desert): T lands at 0.328×Rl every time and the gaps
## come out equal. Uses the LIVE group widths, so a longer zone / status word / stat digits just shrinks
## the gaps evenly instead of colliding (the old fixed w×0.30 / w×0.66 ignored the right cluster and broke
## when the zone name grew). Re-run on resize and each snapshot.
func _relayout_topbar() -> void:
	if _topbar == null or _grp_right == null:
		return
	var w := _topbar.size.x
	var hh := _topbar.size.y
	if w <= 1.0:
		return
	for g in [_grp_left, _grp_t, _grp_stats, _grp_right]:
		g.size = g.get_combined_minimum_size()
		g.position.y = (hh - g.size.y) * 0.5
	_grp_left.position.x = 0.0
	# Right cluster ends ~8px inside the bar's right edge, so its zone name lines up with Qud's.
	_grp_right.position.x = w - _grp_right.size.x - 8.0
	# Split the leftover space between left and right into three equal gaps around T and stats.
	var gap := (_grp_right.position.x - _grp_left.size.x - _grp_t.size.x - _grp_stats.size.x) / 3.0
	_grp_t.position.x = _grp_left.size.x + gap
	_grp_stats.position.x = _grp_t.position.x + _grp_t.size.x + gap
	# Qud's name↔T-group separator is the same fixed-width box (||—————||) as the other two, centred in
	# the gap — not a line stretched to fill it (which ran ~284px vs Qud's ~260).
	_place_sep(_sep1, _grp_left, _grp_t, 8.0, 261.0, true)
	# Qud's water$↔QN separator is the same fixed-width box (||—————||) as the one below, floating
	# ~centred in the gap between the T-group and the stats (Qud caps at 778/1036, ~258px). Centre a
	# fixed-width box in the gap rather than stretching it (which ran 20px wide).
	_place_sep(_sep2, _grp_t, _grp_stats, 8.0, 261.0, true)
	# Qud's stats↔disc separator is a fixed-width box (||—————||), not a line glued to the stats. Its
	# right || is 16px left of the disc (aligned above); its left || is ~261px further left, at Qud's x
	# (~1490). Anchor it to the aligned right end at Qud's box width so the left || matches Qud regardless
	# of the stats group's width/position (which still sits ~20px left of Qud — a later leftward pass).
	_place_sep(_sep3, _grp_stats, _grp_right, 16.0, 261.0)

func _place_sep(sep: Control, lg: Control, rg: Control, rpad := 8.0, fixed_w := 0.0, centered := false) -> void:
	var lend := lg.position.x + lg.size.x
	var x0: float
	var x1: float
	if fixed_w > 0.0 and centered:
		var fw := minf(fixed_w, maxf(4.0, (rg.position.x - lend) - 12.0))   # shrink to fit a tight gap
		var mid := (lend + rg.position.x) * 0.5
		x0 = mid - fw * 0.5
		x1 = mid + fw * 0.5
	elif fixed_w > 0.0:
		x1 = rg.position.x - rpad                                            # anchored to the right end
		x0 = x1 - minf(fixed_w, maxf(4.0, (x1 - lend) - 6.0))
	else:
		x0 = lend + 8.0                                                      # stretch to fill the gap
		x1 = rg.position.x - rpad
	sep.size = Vector2(maxf(2.0, x1 - x0), sep.get_combined_minimum_size().y)
	sep.position = Vector2(x0, (_topbar.size.y - sep.size.y) * 0.5)

# ── row 2: vitals (HP / LVL-EXP)  |  top menu ────────────────────────────────

func _row_vitals_menu() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)   # tight vitals↔nav gap so the vitals box reaches Qud's edge

	# col 1 — two stacked vitals rows. Qud draws the HP/EXP bar as the FULL box (from the left edge,
	# length = the value) with the label + numbers ON TOP of it — not a label beside a separate bar.
	# Each row is the bar full-rect with the label overlaid; in 1:1 the bar fills the whole box, in user
	# mode it's inset behind the label (so the green text stays readable). No panel — the bar is the bg.
	var vitals := VBoxContainer.new()
	vitals.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vitals.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vitals.add_theme_constant_override("separation", 3)
	vitals.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Qud's vitals text is ~15% smaller than our default body — sized to match (cap ~11px vs Qud's 11).
	var vfs := int(round(UiFont.px(get_viewport(), "body") * 0.85))
	_l_hp = _hp_rich(vfs)
	_bar_hp = _bar(0, 1, COL_HP)
	vitals.add_child(_vitals_row(_l_hp, _bar_hp))

	_l_exp = _text("LVL: —   EXP: —", COL_EXP)
	_l_exp.add_theme_font_size_override("font_size", vfs)
	_bar_exp = _bar(0, 1, COL_EXP)
	vitals.add_child(_vitals_row(_l_exp, _bar_exp))
	h.add_child(vitals)

	# col 2 — top menu, a compact cluster hugging the right (Qud's top-right icon menu). Two variants
	# live here; _apply_menu_mode shows one. VERBOSE (user): labelled buttons. COMPACT (1:1): Qud's
	# six icons only, for parity. Both are cosmetic placeholders except the Perceived/Full toggle.
	var menu := _strip()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_END
	# Qud's nav icons hug the window's right edge; trim this strip's right inset so the cluster sits
	# flush like Qud's (the default 8px panel margin left it ~7px shy of Qud's last icon).
	var mstyle: StyleBoxFlat = _panel_style()
	mstyle.content_margin_right = 1
	mstyle.content_margin_left = 1   # trim the left inset too so the vitals box reaches Qud's right edge
	menu.add_theme_stylebox_override("panel", mstyle)

	_menu_verbose = HBoxContainer.new()
	_menu_verbose.add_theme_constant_override("separation", 4)
	menu.add_child(_menu_verbose)
	_menu_verbose.add_child(_menu_btn("≡"))
	# Global Perceived/Full toggle (debug): drives Target, Context menu, Nearby objects (and the log,
	# once it has icons). Default = perceived — what the player actually sees.
	_info_btn = Button.new()
	_info_btn.focus_mode = Control.FOCUS_NONE
	_info_btn.pressed.connect(_toggle_full_info)
	_menu_verbose.add_child(_info_btn)
	for label in ["🔒 Lock", "🗺 Minimap", "Look", "Wait", "Character",
			"POI", "Auto-explore", "▼ Down", "▲ Up"]:
		_menu_verbose.add_child(_menu_btn(label))

	# Qud's compact top-right cluster: the 11 real nav icons (extracted from Qud's ActiveButtons), in
	# fixed slots at Qud's ~43px pitch (1.8×body), right-anchored. Python-modelled to Qud's centres.
	_menu_compact = HBoxContainer.new()
	_menu_compact.add_theme_constant_override("separation", 0)   # pitch = the slot width
	_menu_compact.visible = false
	menu.add_child(_menu_compact)
	var nbpx := UiFont.px(get_viewport(), "body")
	var slot := int(round(nbpx * 2.05))            # ~43px pitch (screen), matching Qud (calibrated)
	var ihh := int(round(nbpx * 1.6))
	var iscale := nbpx / 26.0                       # native icon px → render size (consistent, keeps aspect)
	for key in ["system", "wlock", "map", "find", "look", "rest", "char", "poi", "explore", "down", "up"]:
		var cell := Control.new()
		cell.custom_minimum_size = Vector2(slot, ihh)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex := _load_nav_icon(key)
		var ic := TextureRect.new()
		ic.texture = tex
		ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ic.stretch_mode = TextureRect.STRETCH_SCALE
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if tex != null:
			var ts: Vector2 = tex.get_size() * iscale   # same scale for every icon → native aspect preserved
			ic.anchor_left = 0.5; ic.anchor_top = 0.5
			ic.anchor_right = 0.5; ic.anchor_bottom = 0.5
			ic.offset_left = -ts.x * 0.5; ic.offset_top = -ts.y * 0.5
			ic.offset_right = ts.x * 0.5; ic.offset_bottom = ts.y * 0.5
		cell.add_child(ic)
		_menu_compact.add_child(cell)

	h.add_child(menu)
	return h

func _toggle_full_info() -> void:
	_full_info = not _full_info
	_apply_full_info()

## Push the current info mode to every view that honours it, and refresh the button label.
func _apply_full_info() -> void:
	if _info_btn != null:
		_info_btn.text = "👁 Full" if _full_info else "👁 Perceived"
		_info_btn.tooltip_text = "Info: %s — click for %s" % [
			"FULL (debug)" if _full_info else "perceived", "perceived" if _full_info else "full"]
	for p in _panels:
		if p.has_method("set_full_info"):
			p.set_full_info(_full_info)

# --- CRT overlay (Qud's terminal scanlines + vignette) ------------------------
## A full-window ColorRect on a top CanvasLayer, running the crt shader. It darkens everything behind
## it (chrome + the 3D), so it sits above both. Mouse-transparent so it never eats clicks. Visibility
## shows only if the fx_scanlines / fx_vignette settings are on (both off in the minimal 1:1 test).
func _add_crt_overlay() -> void:
	if _crt_layer != null:
		return
	_crt_layer = CanvasLayer.new()
	_crt_layer.layer = 100                       # above the chrome (layer 0) and the 3D
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Scanlines and vignette are independent 1:1-test effects; the overlay shows if either is on.
	var scan := bool(Settings.get_value("fx_scanlines", false))
	var vig := bool(Settings.get_value("fx_vignette", false))
	var sh: Shader = load("res://crt.gdshader")
	if sh != null:
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("scanline_lift", 0.042 if scan else 0.0)
		mat.set_shader_parameter("vignette_strength", 0.42 if vig else 0.0)
		rect.material = mat
	_crt_layer.add_child(rect)
	add_child(_crt_layer)
	_crt_layer.visible = scan or vig

# --- 1:1 (parity) mode: panel half + persistence ------------------------------
# The Holodeck owns the master switch + camera (hotkey / highvisor / preset flip it there and
# emit one_to_one_changed); here we swap the side panels to their Qud-faithful variant and
# persist the choice so the next launch (and presets) stick.
func _on_one_to_one_changed(on: bool) -> void:
	_set_panels_one_to_one(on)
	_apply_layout_mode(on)
	Settings.set_value("mode", "1to1" if on else "user")
	Settings.save()

func _set_panels_one_to_one(on: bool) -> void:
	for p in _panels:
		if p.has_method("set_one_to_one"):
			p.set_one_to_one(on)

## Reshape the chrome to match Qud (1:1) or restore the QoL layout (user). Three moves: widen the side
## column, swap the top menu to Qud's compact icons, and drop the dev strip. Idempotent + re-run on
## resize (the sidebar width is a fraction of the window). Safe before the Holodeck connects.
func _apply_layout_mode(on: bool) -> void:
	if _menu_verbose != null:
		_menu_verbose.visible = not on
	if _menu_compact != null:
		_menu_compact.visible = on
	if _dev_bar != null:
		# In 1:1 the strip is redundant (connect auto-runs, viewport auto-enables) — hide it once
		# connected so the play hole starts at the top like Qud. Before connect it stays up as a fallback.
		_dev_bar.visible = not (on and _holo != null)
	if _side != null and _row_split != null:
		if on:
			var w := float(get_viewport().get_visible_rect().size.x)
			# Qud's minimum log width (NOT clamped to the wider user-mode min) so the playfield is largest.
			_side.custom_minimum_size = Vector2(round(w * SIDEBAR_FRAC_1TO1), 0)
			_row_split.split_offset = 0   # deterministic: side = its min width, holo takes the rest
		else:
			_side.custom_minimum_size = Vector2(SIDEBAR_W_USER, 0)
			_row_split.split_offset = 900
	_apply_panel_sizing(on)
	_push_play_inset(on)
	_apply_vitals_mode(on)
	_layout_row_bgs.call_deferred()   # size the continuous chrome-strip backgrounds to the new play hole

## The whole ||| grab-bar (message-log left margin) drags the side column wider/narrower in 1:1. dx<0
## (dragged left) widens the log. Clamped between a readable min and half the window; the camera play
## inset follows so the zone re-fits the shrinking/growing hole. Transient (not persisted).
func _on_sidebar_drag(dx: float) -> void:
	if not Settings.one_to_one() or _side == null:
		return
	var w := float(get_viewport().get_visible_rect().size.x)
	_side.custom_minimum_size.x = clampf(_side.custom_minimum_size.x - dx, 120.0, w * 0.5)
	_push_play_inset(true)
	_layout_row_bgs.call_deferred()

func _make_row_bg() -> ColorRect:
	var c := ColorRect.new()
	c.color = ROW_BG_1TO1
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat clicks/arrows headed for the chrome or hole
	c.visible = false
	add_child(c)
	return c

## Position the two 1:1 chrome-strip backgrounds around the play hole (row 3 = _row_split): top strip =
## window top → hole top; bottom strip = hole bottom → window floor. Hidden in user mode. Deferred callers
## ensure the split has been laid out first.
func _layout_row_bgs() -> void:
	if _top_bg == null or _bottom_bg == null or _row_split == null:
		return
	var on := Settings.one_to_one()
	_top_bg.visible = on
	_bottom_bg.visible = on
	if not on:
		return
	var r := _row_split.get_rect()          # rows VBox is full-rect at (0,0), so this is in MainFrame coords
	_top_bg.position = Vector2.ZERO
	_top_bg.size = Vector2(size.x, maxf(0.0, r.position.y))
	var hole_bottom := r.position.y + r.size.y
	_bottom_bg.position = Vector2(0, hole_bottom)
	_bottom_bg.size = Vector2(size.x, maxf(0.0, size.y - hole_bottom))

## Row-2 vitals colour per mode: 1:1 = Qud's own muted white/grey text + dark-green bar; user = the
## bright green/cyan. (Format is gated in _apply_stats.) Build-time defaults are user mode, so this is
## only re-applied when 1:1 is active or on a mode flip.
func _apply_vitals_mode(on: bool) -> void:
	if _l_hp != null:
		# RichTextLabel base colour ("HP:" + "/ max"); the current number is tinted per-snapshot in _apply_stats.
		_l_hp.add_theme_color_override("default_color", COL_HP_1TO1 if on else COL_HP)
	if _l_exp != null:
		_l_exp.add_theme_color_override("font_color", COL_EXP_1TO1 if on else COL_EXP)
	_recolor_bar(_bar_hp, COL_HP_BAR_1TO1 if on else COL_HP)
	_recolor_bar(_bar_exp, COL_EXP_BAR_1TO1 if on else COL_EXP)
	# 1:1 → bar fills the whole box (behind the text); user → inset behind the label so green stays legible
	var inset := 0.0 if on else float(VITALS_USER_INSET)
	if _bar_hp != null:
		_bar_hp.offset_left = inset
	if _bar_exp != null:
		_bar_exp.offset_left = inset

func _recolor_bar(pb: ProgressBar, col: Color) -> void:
	if pb == null:
		return
	var fill := pb.get_theme_stylebox("fill")
	if fill is StyleBoxFlat:
		(fill as StyleBoxFlat).bg_color = col

## True when a Qud option (from the exported options.json mirror) is enabled ("Yes"). Lets 1:1 mode
## honour Qud's own sidebar toggles (Show minimap / Show nearby objects). Unreadable/absent → show.
func _qud_option_on(id: String) -> bool:
	var path := InputModel.support_dir().path_join("options.json")
	if path == "" or not FileAccess.file_exists(path):
		return true
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return true
	var d = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.get("categories") is Array:
		for cat in d["categories"]:
			if cat is Dictionary and cat.get("options") is Array:
				for o in cat["options"]:
					if o is Dictionary and o.get("id") == id:
						return str(o.get("value", "")) == "Yes"
	return true

## Qud's HP-text colour by health %, matching GameObject.GetHPColor().
func _hp_color(hp: int, hpmax: int) -> Color:
	var pct := 100 * hp / maxi(1, hpmax)
	if pct < 15:  return COL_HP_DARKRED
	if pct < 33:  return COL_HP_RED
	if pct < 66:  return COL_HP_GOLD
	if pct < 100: return COL_HP_GREEN
	return COL_HP_1TO1   # white at full

## Size the three side-column panels per mode. Qud stacks a SHORT minimap, a content-sized Nearby
## objects, and a Message log that fills ALL the remaining height. User (QoL) mode keeps the original
## split (taller minimap; nearby + log share the leftover space).
func _apply_panel_sizing(on: bool) -> void:
	if _minimap != null:
		# Qud's minimap is a short landscape strip; the QoL one reserved a tall box with dead space.
		_minimap.custom_minimum_size = Vector2(0, 150 if on else 220)
		# 1:1: honour Qud's "Show minimap" option — hidden when off. User mode always shows it.
		_minimap.visible = (not on) or _qud_option_on("OptionOverlayMinimap")
	if _nearby != null:
		# 1:1: size to content (no dead gap) — the panel itself fits its rows via set_one_to_one.
		# User: expand to share the leftover height with the log.
		_nearby.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if on else Control.SIZE_EXPAND_FILL
		# 1:1: honour Qud's "Show nearby objects list" option — hidden when off.
		_nearby.visible = (not on) or _qud_option_on("OptionOverlayNearbyObjects")
	if _msglog != null:
		_msglog.size_flags_vertical = Control.SIZE_EXPAND_FILL   # always the space-filler; dominant in 1:1
	# Row 4 (Active effects | Target | Context menu). Qud keeps this a thin single-line strip; the QoL
	# layout reserves taller boxes. 1:1 slims them (context a touch taller for the equipped-weapon sprite),
	# which also hands the freed height to the play hole above.
	if _effects != null:
		_effects.custom_minimum_size = Vector2(0, 58 if on else 90)
	if _target != null:
		_target.custom_minimum_size = Vector2(0, 58 if on else 90)
	if _context != null:
		_context.custom_minimum_size = Vector2(0, 66 if on else 104)

## Tell the Holodeck camera what fraction of the window the sidebar now covers, so the 1:1 zone-fit
## recentres the view in the visible play hole (left of the sidebar) instead of the full window.
func _push_play_inset(one_to_one: bool) -> void:
	if _holo == null or not _holo.has_method("set_ui_right_inset"):
		return
	var frac := 0.0
	if one_to_one:
		var w := float(get_viewport().get_visible_rect().size.x)
		if w > 0.0 and _side != null:
			frac = clampf(_side.custom_minimum_size.x / w, 0.0, 0.6)
	_holo.set_ui_right_inset(frac)
	_push_play_hole.call_deferred(one_to_one)   # deferred: read the hole rect AFTER the layout settles

## Push the play hole's real px rect (row 3's transparent area) to the camera — the 1:1 pixel model
## fits Qud's stage into this rect on BOTH axes (the fraction above is horizontal-only and keeps the
## legacy fallback alive). Rect2() clears it in user mode so the fallback paths take over.
func _push_play_hole(one_to_one: bool) -> void:
	if _holo == null or not _holo.has_method("set_play_hole_rect"):
		return
	if one_to_one and _holo_hole != null:
		_holo.set_play_hole_rect(_holo_hole.get_global_rect())
	else:
		_holo.set_play_hole_rect(Rect2())

# ── row 3: Holodeck  |grabby|  side panels  (expands to fill) ─────────────────

func _row_main() -> Control:
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 900   # give the Holodeck the lion's share; user can drag the separator
	_row_split = split

	var holo := _holodeck_cell()
	holo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(holo)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(SIDEBAR_W_USER, 0)
	side.add_theme_constant_override("separation", 4)
	_side = side
	_minimap = load("res://MinimapView.gd").new()    # the real Minimap view (its own file)
	_minimap.custom_minimum_size = Vector2(0, 220)
	_nearby = load("res://NearbyObjects.gd").new()   # the real Nearby objects view (its own file)
	_nearby.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_nearby.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msglog = load("res://MessageLog.gd").new()      # the real Message log view (its own file)
	_msglog.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_msglog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msglog.left_edge_drag.connect(_on_sidebar_drag)   # 1:1: the ||| grab-bar resizes the side column
	side.add_child(_minimap)
	side.add_child(_nearby)
	side.add_child(_msglog)
	split.add_child(side)
	return split

## The Holodeck cell: the existing 3D scene (Main.tscn), rendered FULL-WINDOW into the root viewport
## (its original, crash-free home — the SubViewport that was added only for embedding is gone). The
## chrome floats on top; this row-3 cell is a transparent HOLE the 3D shows through. Main creates its
## own camera / environment / bridge in _ready, so it just works. Mouse over the hole passes through to
## Main (inspector); keyboard reaches Main via _unhandled_input. Camera/movement (polled input) works
## regardless. Two explicit stages so the (now-unlikely) 3D crash can't take the data with it:
##   1. Connect (data) — instance Main with render_3d = FALSE. The bridge starts and the status bar +
##      panels fill with ZERO 3D build work (Main skips the whole build/render path). The empty 3D
##      world (just sky) shows in the hole. Proves the data layer independent of the 3D.
##   2. Turn on viewport — set Main.render_3d = true, which builds + renders the current zone into the
##      root viewport. No SubViewport, so no separate Metal render target to overrun.
func _holodeck_cell() -> Control:
	_holo_host = VBoxContainer.new()
	_holo_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holo_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holo_host.add_theme_constant_override("separation", 2)

	var bar := _strip()
	_dev_bar = bar            # hidden in 1:1 (Qud has no such strip); the play hole then starts at the top
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 6)
	bar.add_child(bh)
	_connect_btn = _menu_btn("▶ Connect (data)")
	_connect_btn.pressed.connect(_connect_holodeck)
	bh.add_child(_connect_btn)
	_render_btn = _menu_btn("▶ Turn on viewport")
	_render_btn.disabled = true
	_render_btn.pressed.connect(_enable_viewport)
	bh.add_child(_render_btn)
	var tail := Control.new()
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(tail)
	_holo_host.add_child(bar)

	# The HOLE — a transparent Control the full-window 3D shows through. No stylebox (so nothing is
	# drawn over the 3D), mouse IGNORE (so clicks fall through to Main's inspector).
	_holo_hole = Control.new()
	_holo_hole.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holo_hole.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holo_hole.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The 1:1 camera fits Qud's stage into this rect, so any late layout settle (chrome rows collapsing
	# on a mode switch, a sidebar drag, a window resize) must re-push it — the deferred push in
	# _push_play_inset alone can catch the rect mid-settle and leave the stage mis-fit by a few px.
	_holo_hole.item_rect_changed.connect(func() -> void: _push_play_hole(Settings.one_to_one()))
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_holo_hint = _text("HOLODECK — press  ▶ Connect (data),  then  ▶ Turn on viewport", COL_DIM)
	_holo_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_holo_hint)
	_holo_hole.add_child(center)
	_holo_host.add_child(_holo_hole)
	return _holo_host

## Stage 1 — data only. Instance Main into the ROOT viewport (full-window) with render_3d = false: the
## bridge runs and snapshots flow (status bar + panels) with no 3D build work. The chrome is already
## on top; the empty 3D world (sky) shows in the hole.
func _connect_holodeck() -> void:
	if _holo != null:
		return
	_connect_btn.disabled = true
	if _holo_hint != null:
		_holo_hint.text = "Data connected — press  ▶ Turn on viewport"
	_holo = load("res://Main.tscn").instantiate()
	_holo.embedded = true                       # hide Main's own HUD chrome; move its grade below the frame
	_holo.render_3d = false                     # DATA ONLY — no 3D build/render at all
	_holo.connect("snapshot", _apply_stats)     # feeds status bar + panels off the same stream
	_holo.connect("one_to_one_changed", _on_one_to_one_changed)  # camera flips → sync panels + persist
	add_child(_holo)                            # ROOT viewport → 3D renders full-window BEHIND the chrome
	_render_btn.disabled = false
	# Apply the saved 1:1 / user mode now that the Holodeck (camera owner) exists. When 1:1, this
	# emits one_to_one_changed → _on_one_to_one_changed pushes the 1:1 variant to the panels too.
	_holo.set_one_to_one(Settings.one_to_one())
	if Settings.one_to_one():
		_set_panels_one_to_one(true)            # ensure panels match on a 1:1 launch
		_apply_layout_mode(true)                # widen sidebar, compact menu, drop dev strip, recentre cam
		_enable_viewport.call_deferred()        # 1:1 is a parity view — bring the 3D up automatically

## Stage 2 — bring the 3D up: build + render the current zone into the root viewport. No SubViewport
## present-flip to race the Metal driver (that was the crash); this is the path standalone Main always
## used. The hole's hint is dropped so it doesn't float over the live view.
func _enable_viewport() -> void:
	if _holo == null:
		return
	_render_btn.disabled = true
	if _holo_hint != null:
		_holo_hint.visible = false
	_holo.set_render_3d(true)

## Update the status bar from one snapshot's `stats` block (and `time` for day/night). Missing
## fields fall back to "—" so a partial/older mod never shows stale numbers.
func _apply_stats(data: Dictionary) -> void:
	var s: Dictionary = data.get("stats", {})
	# Character icon — the player's own tile, like Qud's top-left avatar.
	if _portrait != null and _tiles != null:
		var pal: Dictionary = data.get("palette", {})
		if not pal.is_empty():
			_tiles.palette = pal
		_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
		var pobj: Dictionary = data.get("player", {})
		if not pobj.is_empty():
			# Qud's HUD avatar renders the player tile in WHITE — the object's ColorString `&y`
			# is the grey TEXT colour, not the graphical tile colour (Qud's TileColor is white and
			# the mod sends it empty for the player) — with the detail colour (red) painted on top.
			var tex: Texture2D = _tiles.texture(String(pobj.get("tile", "")), Color.WHITE, _tiles.detail_color(pobj))
			if tex != null:
				_portrait.texture = tex
			_portrait.flip_h = bool(pobj.get("hflip", false))   # match Qud's sprite facing
	if _l_name != null:
		_l_name.text = QudText.strip(String(s.get("name", "—")))
	if _l_temp != null:
		_l_temp.text = ("T:%d°" % int(s["temp"])) if s.has("temp") else "—"   # Qud shows "T:25°"
	if _l_weight != null:
		_l_weight.text = "%d/%d#" % [int(s.get("weight", 0)), int(s.get("weightMax", 0))]
	if _l_water != null:
		_l_water.text = "%d$" % int(s.get("water", 0))
	if _l_qn != null:
		_l_qn.text = "QN: %d" % int(s.get("qn", 0))
	if _l_ms != null:
		_l_ms.text = "MS: %d" % int(s.get("ms", 0))
	if _l_av != null:
		_l_av.text = "AV: %d" % int(s.get("av", 0))
	if _l_dv != null:
		_l_dv.text = "DV: %d" % int(s.get("dv", 0))
	if _l_ma != null:
		_l_ma.text = "MA: %d" % int(s.get("ma", 0))
	# row 2 — HP + LVL/EXP bars
	var hp := int(s.get("hp", 0))
	var hpmax := maxi(1, int(s.get("hpMax", 1)))
	if _l_hp != null:
		if Settings.one_to_one():
			# Qud's spacing, and colour ONLY the current-HP number by health % (rest white). BBCode.
			_l_hp.text = "HP: [color=#%s]%d[/color] / %d" % [_hp_color(hp, hpmax).to_html(false), hp, hpmax]
		else:
			_l_hp.text = "HP: %d/%d" % [hp, hpmax]
	if _bar_hp != null:
		_bar_hp.max_value = hpmax
		_bar_hp.value = hp
	if s.has("level"):
		var lvl := int(s.get("level", 0))
		var xp := int(s.get("xp", 0))
		var xp_floor := int(s.get("xpFloor", 0))
		var xp_next := maxi(xp_floor + 1, int(s.get("xpNext", xp_floor + 1)))
		if _l_exp != null:
			_l_exp.text = ("LVL: %d Exp: %d / %d" if Settings.one_to_one() else "LVL: %d   EXP: %d/%d") % [lvl, xp, xp_next]
		if _bar_exp != null:
			_bar_exp.min_value = xp_floor
			_bar_exp.max_value = xp_next
			_bar_exp.value = clampi(xp, xp_floor, xp_next)
	# Food/water status, coloured by state like Qud (good = green, worsening = gold/orange/red). The mod
	# strips the colour markup, so map the known status words here.
	if _l_hunger != null:
		_set_status_label(_l_hunger, String(s.get("hunger", "—")))
	if _l_thirst != null:
		_set_status_label(_l_thirst, String(s.get("thirst", "—")))
	if _l_biome != null:
		var terrain := QudText.strip(String(s.get("terrain", "")))
		# Qud's DisplayName usually already includes the stratum ("salt marsh, surface"); fall back to
		# our own "— · surface/cavern" from zone.z if it's empty.
		_l_biome.text = terrain if terrain != "" else ("— · %s" % _floor_name(data))
	if _daynight != null:
		var t: Dictionary = data.get("time", {})
		_ensure_clocks()
		var idx := _clock_index(t)
		if idx >= 0 and idx < _clock_tex.size() and _clock_tex[idx] != null:
			_clock.texture = _clock_tex[idx]
			_clock.visible = true
			_daynight.visible = false
		else:
			_clock.visible = false
			_daynight.visible = true
			var is_day: bool = bool(t.get("isDay", true))
			_daynight.text = "☀" if is_day else "☾"
			_daynight.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if is_day else Color(0.6, 0.7, 1.0))
	# Content widths just changed (status words, gold digits, zone name) — re-place the centred groups.
	_relayout_topbar.call_deferred()
	_check_mod_version(data)
	# Every sub-view shares one entry point, so feeding them is a loop (adding a panel = build the scene
	# + append it to _panels in _ready; no wiring change here).
	for p in _panels:
		p.set_snapshot(data)

## Compare the running mod's wire version to what this client needs, and pin a status line in the message
## log. A mod .cs change only takes effect after a Qud restart, so "deployed but not restarted" left the
## client running old behaviour with no signal — this makes it loud. Only touches the log when the verdict
## changes (a reconnect to a newer mod flips it to current). Absent `protocol` = a pre-handshake mod (v1).
func _check_mod_version(data: Dictionary) -> void:
	if _msglog == null:
		return
	var proto := int(data.get("protocol", 1))
	var status: int
	if proto < MIN_MOD_PROTOCOL:
		status = 2
	elif proto > CLIENT_PROTOCOL:
		status = 3
	else:
		status = 1
	if status == _mod_status:
		return
	_mod_status = status
	match status:
		1:
			_msglog.set_notice("[color=#6fcf6f]✓ Raves mod v%d — up to date[/color]" % proto)
		2:
			_msglog.set_notice("[color=#ff6a6a]⚠ Raves mod is out of date (v%d, need v%d) — restart Caves of Qud to load the latest mod[/color]" % [proto, MIN_MOD_PROTOCOL])
		3:
			_msglog.set_notice("[color=#ffd24a]⚠ Raves client is out of date (mod v%d, client v%d) — rebuild/re-export Raves[/color]" % [proto, CLIENT_PROTOCOL])

## Forward a Context-menu click to the Holodeck's bridge (Main owns the BridgeClient). No-op until the
## Holodeck is connected.
func _on_context_command(payload: Dictionary) -> void:
	if _holo == null:
		return
	match String(payload.get("type", "")):
		"command":
			_holo.request_command(String(payload.get("command", "")))
		"itemaction":
			_holo.request_item_action(String(payload.get("item", "")), String(payload.get("command", "")))

## A command-bar ability was clicked: activate it, and for a known direction ability, start the
## Holodeck's direction picker (the ability's icon becomes the cursor).
func _on_ability_command(payload: Dictionary) -> void:
	if _holo == null:
		return
	var cmd := String(payload.get("command", ""))
	if cmd == "":
		return
	_holo.request_command(cmd)
	if bool(payload.get("pick_dir", false)):
		var icon = payload.get("icon")
		if icon != null:
			_holo.start_direction_picker(icon)

## Stratum label from zone.z (surface = 10, deeper = cavern -N, negative = the overworld map).
func _floor_name(data: Dictionary) -> String:
	var z: int = int(data.get("zone", {}).get("z", 10))
	if z < 0:
		return "world map"
	if z > 10:
		return "cavern -%d" % (z - 10)
	return "surface"

# NOTE: no key forwarding here. Main renders into the ROOT viewport, so it receives keyboard via its
# own _unhandled_input directly (the chrome's menu buttons are focus-less, so they never swallow keys).
# One keypress -> one delivery -> one step. (The old SubViewport path needed care here to avoid the
# "double stepping" bug; full-window has no such duplication.)

# ── row 4: active effects | target | context menu ────────────────────────────

func _row_context() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	_effects = load("res://ActiveEffects.gd").new()   # the real Active effects view (its own file)
	_effects.custom_minimum_size = Vector2(0, 90)
	var eff: Control = _effects
	eff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target = load("res://TargetView.gd").new()       # the real Target view (its own file)
	_target.custom_minimum_size = Vector2(0, 90)
	var tgt: Control = _target
	tgt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_context = load("res://ContextMenu.gd").new()     # the real Context menu view (its own file)
	_context.custom_minimum_size = Vector2(0, 104)    # room for the larger, Qud-sized weapon sprite on one row
	_context.command_requested.connect(_on_context_command)   # fire/reload/[?] → the Holodeck's bridge
	var ctx: Control = _context
	ctx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(eff)
	h.add_child(tgt)
	h.add_child(ctx)
	return h

# ── row 5: command bar — the player's activated abilities (CommandBar.gd) ─────

func _row_command() -> Control:
	_command = load("res://CommandBar.gd").new()   # the real command bar (its own file)
	_command.command_requested.connect(_on_ability_command)   # ability click → activate (+ direction picker)
	return _command

# ── screenshot (F12) ─────────────────────────────────────────────────────────

func _shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := InputModel.support_dir().path_join("frame_shot.png")
	img.save_png(path)
	print("[frame] shot -> ", path)

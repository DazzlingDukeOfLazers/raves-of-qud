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
const COL_DIM := Color(0.69, 0.79, 0.76, 0.45)   # y (grey), dimmed — hints/captions
const COL_BORDER := Color(0.69, 0.79, 0.76, 0.16) # y (grey), faint — panel edges
const COL_PANEL := Color("155352")            # K — panels / strips
const COL_BG := Color("0f3b3a")               # k — screen background ("Qud viridian")

var _holo: Node             # the Main.tscn instance rendering full-window into the ROOT viewport (null until Connect)
var _holo_host: Control     # the row-3 left column (control bar + the transparent hole)
var _holo_hole: Control     # the transparent row-3 area the full-window 3D shows through
var _holo_hint: Label       # centred hint in the hole (hidden once the viewport is on)
var _connect_btn: Button    # stage 1: bridge + data, no 3D
var _render_btn: Button     # stage 2: turn the 3D on

# Live status-bar labels, updated from each snapshot's `stats` block.
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
var _daynight: Label
var _l_hp: Label
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
var _dev_bar: Control              # holodeck cell's Connect/Turn-on-viewport strip (hidden in 1:1)
const SIDEBAR_FRAC_1TO1 := 0.28    # Qud's right sidebar ≈ 28% of window width (measured at 1600×900)
const SIDEBAR_W_USER := 320.0      # user-mode side-column min width (the original value)

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
	get_viewport().size_changed.connect(_on_resize)

	# No full-window background rect: the Holodeck now renders 3D into THIS (root) viewport, full-window,
	# with the chrome floating on top. A hole in row 3 lets that 3D show through — a covering ColorRect
	# would hide it. The clear colour stands in for the panel bg in the thin gaps between strips and
	# before the Holodeck connects.
	RenderingServer.set_default_clear_color(COL_BG)

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

	# Resume (Continue / New Game with the bridge up): MainMenu set this so we AUTO-CONNECT the data
	# stage now, rather than stranding the player at the empty "▶ Connect (data)" prompt. Data-only —
	# the 3D viewport stays a manual opt-in ("▶ Turn on viewport"). Deferred so every row/button the
	# connect path touches is fully built first; the flag is one-shot (cleared here).
	if get_tree().has_meta("holo_auto_connect") and bool(get_tree().get_meta("holo_auto_connect")):
		get_tree().remove_meta("holo_auto_connect")
		_connect_holodeck.call_deferred()

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())
	# The 1:1 sidebar is a fraction of the window, and the camera inset derives from it — re-apply both.
	if Settings.one_to_one():
		_apply_layout_mode(true)

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F12:
		_shot()

# ── helpers ────────────────────────────────────────────────────────────────

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
	p.add_theme_stylebox_override("panel", _panel_style(Color(0.09, 0.10, 0.13)))
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
	pb.custom_minimum_size = Vector2(0, 14)
	var bgs := StyleBoxFlat.new()
	bgs.bg_color = Color(0, 0, 0, 0.35)
	bgs.set_corner_radius_all(3)
	var fills := StyleBoxFlat.new()
	fills.bg_color = col
	fills.set_corner_radius_all(3)
	pb.add_theme_stylebox_override("background", bgs)
	pb.add_theme_stylebox_override("fill", fills)
	return pb

# ── row 1: status strip ──────────────────────────────────────────────────────

func _row_status() -> Control:
	var strip := _strip()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	strip.add_child(h)

	h.add_child(_icon(UiFont.px(get_viewport(), "body")))   # player portrait (same tile as the Holodeck marker, later)
	_l_name = _text("—")
	_l_name.custom_minimum_size = Vector2(220, 0)           # reserve width so long names don't shove the strip
	_l_name.clip_text = true
	h.add_child(_l_name)

	_l_temp = _text("—")
	h.add_child(_l_temp)
	h.add_child(_sep())
	_l_hunger = _text("—", COL_HUNGER); h.add_child(_l_hunger)   # hunger (Stomach FoodStatus)
	_l_thirst = _text("—", COL_THIRST); h.add_child(_l_thirst)   # thirst (Stomach WaterStatus)
	h.add_child(_sep())
	_l_weight = _text("—")                                 # carry weight cur/max
	h.add_child(_l_weight)
	_l_water = _text("—", COL_THIRST)                      # fresh water in drams (= currency)
	h.add_child(_l_water)
	h.add_child(_sep())
	_l_qn = _text("QN: —"); h.add_child(_l_qn)             # quickness (100 nominal)
	h.add_child(_sep())
	_l_ms = _text("MS: —"); h.add_child(_l_ms)             # move speed (100 nominal)
	h.add_child(_sep())
	_l_av = _text("AV: —"); h.add_child(_l_av)             # attack value
	h.add_child(_sep())
	_l_dv = _text("DV: —"); h.add_child(_l_dv)             # defense value
	_l_ma = _text("MA: —"); h.add_child(_l_ma)             # mental armor
	h.add_child(_sep())

	_daynight = _text("☾")                                 # day/night — sun/moon glyph (placeholder for a real clock)
	_daynight.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	h.add_child(_daynight)
	h.add_child(_sep())

	_l_biome = _text("—")                                  # biome · floor
	h.add_child(_l_biome)
	var tail := Control.new()                              # push nothing; keep items left-packed
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(tail)
	return strip

# ── row 2: vitals (HP / LVL-EXP)  |  top menu ────────────────────────────────

func _row_vitals_menu() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)

	# col 1 — two stacked vitals rows, each a label + a coloured percent bar. Expands wide (like
	# Qud, where the HP/EXP bars span most of the width) while the menu shrinks to the right.
	var vitals := _strip()
	vitals.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vitals.add_child(vb)

	var hp := HBoxContainer.new()
	hp.add_theme_constant_override("separation", 8)
	_l_hp = _text("HP: —", COL_HP)
	_l_hp.custom_minimum_size = Vector2(160, 0)
	hp.add_child(_l_hp)
	_bar_hp = _bar(0, 1, COL_HP)
	hp.add_child(_bar_hp)
	vb.add_child(hp)

	var xp := HBoxContainer.new()
	xp.add_theme_constant_override("separation", 8)
	_l_exp = _text("LVL: —   EXP: —", COL_EXP)
	_l_exp.custom_minimum_size = Vector2(220, 0)
	xp.add_child(_l_exp)
	_bar_exp = _bar(0, 1, COL_EXP)
	xp.add_child(_bar_exp)
	vb.add_child(xp)
	h.add_child(vitals)

	# col 2 — top menu, a compact cluster hugging the right (Qud's top-right icon menu). Two variants
	# live here; _apply_menu_mode shows one. VERBOSE (user): labelled buttons. COMPACT (1:1): Qud's
	# six icons only, for parity. Both are cosmetic placeholders except the Perceived/Full toggle.
	var menu := _strip()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_END

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

	# Qud's compact top-right cluster: menu · lock · abilities · journal · look · wait. Hidden until 1:1.
	_menu_compact = HBoxContainer.new()
	_menu_compact.add_theme_constant_override("separation", 4)
	_menu_compact.visible = false
	menu.add_child(_menu_compact)
	for icon in ["≡", "🔒", "🅰", "📖", "🔍", "⏳"]:
		_menu_compact.add_child(_menu_btn(icon))

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
			_side.custom_minimum_size = Vector2(maxf(SIDEBAR_W_USER, round(w * SIDEBAR_FRAC_1TO1)), 0)
			_row_split.split_offset = 0   # deterministic: side = its min width, holo takes the rest
		else:
			_side.custom_minimum_size = Vector2(SIDEBAR_W_USER, 0)
			_row_split.split_offset = 900
	_apply_panel_sizing(on)
	_push_play_inset(on)

## Size the three side-column panels per mode. Qud stacks a SHORT minimap, a content-sized Nearby
## objects, and a Message log that fills ALL the remaining height. User (QoL) mode keeps the original
## split (taller minimap; nearby + log share the leftover space).
func _apply_panel_sizing(on: bool) -> void:
	if _minimap != null:
		# Qud's minimap is a short landscape strip; the QoL one reserved a tall box with dead space.
		_minimap.custom_minimum_size = Vector2(0, 150 if on else 220)
	if _nearby != null:
		# 1:1: size to content (no dead gap) — the panel itself fits its rows via set_one_to_one.
		# User: expand to share the leftover height with the log.
		_nearby.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if on else Control.SIZE_EXPAND_FILL
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
	if _l_name != null:
		_l_name.text = QudText.strip(String(s.get("name", "—")))
	if _l_temp != null:
		_l_temp.text = ("%d °C" % int(s["temp"])) if s.has("temp") else "—"
	if _l_weight != null:
		_l_weight.text = "%d/%d #" % [int(s.get("weight", 0)), int(s.get("weightMax", 0))]
	if _l_water != null:
		_l_water.text = "%d $" % int(s.get("water", 0))
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
			_l_exp.text = "LVL: %d   EXP: %d/%d" % [lvl, xp, xp_next]
		if _bar_exp != null:
			_bar_exp.min_value = xp_floor
			_bar_exp.max_value = xp_next
			_bar_exp.value = clampi(xp, xp_floor, xp_next)
	if _l_hunger != null:
		_l_hunger.text = String(s.get("hunger", "—"))
	if _l_thirst != null:
		_l_thirst.text = String(s.get("thirst", "—"))
	if _l_biome != null:
		var terrain := QudText.strip(String(s.get("terrain", "")))
		# Qud's DisplayName usually already includes the stratum ("salt marsh, surface"); fall back to
		# our own "— · surface/cavern" from zone.z if it's empty.
		_l_biome.text = terrain if terrain != "" else ("— · %s" % _floor_name(data))
	if _daynight != null:
		var is_day: bool = bool(data.get("time", {}).get("isDay", true))
		_daynight.text = "☀" if is_day else "☾"
		_daynight.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if is_day else Color(0.6, 0.7, 1.0))
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

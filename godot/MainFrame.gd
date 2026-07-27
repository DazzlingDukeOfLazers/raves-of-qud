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

# Placeholder status colours — tuned later against Qud's real palette.
const COL_HUNGER := Color(0.90, 0.55, 0.20)   # Famished — warm/hungry
const COL_THIRST := Color(0.35, 0.65, 1.00)   # Tumescent — water-blue (water is also currency)
const COL_HP := Color(0.25, 0.80, 0.32)       # HP bar — green
const COL_EXP := Color(0.46, 0.52, 0.64)      # LVL/EXP bar — bluish grey
const COL_DIM := Color(1, 1, 1, 0.45)
const COL_BORDER := Color(1, 1, 1, 0.12)
const COL_PANEL := Color(0.10, 0.11, 0.14)
const COL_BG := Color(0.055, 0.065, 0.085)

var _holo: Node             # the embedded Main.tscn instance (null until Connect)
var _holo_vp: SubViewport   # the SubViewport it renders into
var _holo_host: Control     # the row-3 left cell (control bar + viewport area)
var _connect_btn: Button    # stage 1: bridge + data, no 3D
var _render_btn: Button     # stage 2: turn the 3D viewport on

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

func _ready() -> void:
	name = "MainFrame"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())   # one source of truth; children inherit
	get_viewport().size_changed.connect(_on_resize)

	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var rows := VBoxContainer.new()
	rows.set_anchors_preset(Control.PRESET_FULL_RECT)
	rows.add_theme_constant_override("separation", 4)
	add_child(rows)

	rows.add_child(_row_status())        # 1: top status strip
	rows.add_child(_row_vitals_menu())   # 2: HP/EXP  |  top menu
	rows.add_child(_row_main())          # 3: Holodeck | side panels  (expands)
	rows.add_child(_row_context())       # 4: effects | target | context menu
	rows.add_child(_row_command())       # 5: command bar (abilities)

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())

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

	# col 2 — top menu, a compact cluster hugging the right (Qud's top-right icon menu)
	var menu := _strip()
	menu.size_flags_horizontal = Control.SIZE_SHRINK_END
	var mh := HBoxContainer.new()
	mh.add_theme_constant_override("separation", 4)
	menu.add_child(mh)
	for label in ["≡", "🔒 Lock", "🗺 Minimap", "Look", "Wait", "Character",
			"POI", "Auto-explore", "▼ Down", "▲ Up"]:
		mh.add_child(_menu_btn(label))
	h.add_child(menu)
	return h

# ── row 3: Holodeck  |grabby|  side panels  (expands to fill) ─────────────────

func _row_main() -> Control:
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 900   # give the Holodeck the lion's share; user can drag the separator

	var holo := _holodeck_cell()
	holo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(holo)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	side.add_theme_constant_override("separation", 4)
	var mini := _cell("Minimap", Vector2(0, 220))
	_nearby = load("res://NearbyObjects.gd").new()   # the real Nearby objects view (its own file)
	_nearby.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_nearby.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msglog = load("res://MessageLog.gd").new()      # the real Message log view (its own file)
	_msglog.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_msglog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(mini)
	side.add_child(_nearby)
	side.add_child(_msglog)
	split.add_child(side)
	return split

## The Holodeck cell: the existing 3D scene (Main.tscn) instanced inside a SubViewport, stretched to
## fill the cell. Main creates its own camera / World3D / bridge in _ready, so it just works in here.
## Mouse over the cell is forwarded by SubViewportContainer; keyboard is forwarded in
## _unhandled_key_input below. Camera/movement (polled Input.is_key_pressed) works regardless.
## Two explicit stages so the 3D crash can't take the data with it:
##   1. Connect (data) — instance Main with render_3d = FALSE and the SubViewport render off. The
##      bridge starts and the status bar + message log fill with ZERO 3D/Metal work (Main skips the
##      whole build/render path). If this is stable, the data layer is proven independent of the 3D.
##   2. Turn on viewport — set Main.render_3d = true (renders the current zone) and flip the
##      SubViewport to present. Any 3D crash is now isolated here, and the data view survives it.
func _holodeck_cell() -> Control:
	_holo_host = VBoxContainer.new()
	_holo_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_holo_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holo_host.add_theme_constant_override("separation", 2)

	var bar := _strip()
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

	var area := _cell("HOLODECK")
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holo_host.add_child(area)
	return _holo_host

## Stage 1 — data only. Main runs the bridge and emits snapshots (status bar + log) but does NO 3D
## work (render_3d = false), and the SubViewport isn't presenting.
func _connect_holodeck() -> void:
	if _holo != null:
		return
	_connect_btn.disabled = true
	if _holo_host.get_child_count() > 1:
		_holo_host.get_child(1).queue_free()
	var svc := SubViewportContainer.new()
	svc.stretch = true
	# Render the 3D at HALF the native-retina resolution (upscaled to fill). At full HiDPI the
	# SubViewport's Metal render target overran and crashed ONLY in the exported app — the dev editor,
	# at ~half res, renders it fine. This caps the 3D render to that safe resolution; the frame's 2D
	# chrome stays crisp. Bump stretch_shrink higher if it ever recurs.
	svc.stretch_shrink = 2
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	svc.add_child(sv)
	_holo = load("res://Main.tscn").instantiate()
	_holo.embedded = true
	_holo.render_3d = false                     # DATA ONLY — no 3D build/render at all
	_holo.connect("snapshot", _apply_stats)     # feeds status bar + message log
	sv.add_child(_holo)                          # _ready() → bridge connects
	_holo_vp = sv
	_holo_host.add_child(svc)
	_render_btn.disabled = false

## Stage 2 — bring the 3D up: render the current zone and start presenting.
func _enable_viewport() -> void:
	if _holo == null or _holo_vp == null:
		return
	_render_btn.disabled = true
	_holo.set_render_3d(true)                    # build the current zone now
	_holo_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

## Update the status bar from one snapshot's `stats` block (and `time` for day/night). Missing
## fields fall back to "—" so a partial/older mod never shows stale numbers.
func _apply_stats(data: Dictionary) -> void:
	var s: Dictionary = data.get("stats", {})
	if _l_name != null:
		_l_name.text = String(s.get("name", "—"))
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
		var terrain := String(s.get("terrain", ""))
		# Qud's DisplayName usually already includes the stratum ("salt marsh, surface"); fall back to
		# our own "— · surface/cavern" from zone.z if it's empty.
		_l_biome.text = terrain if terrain != "" else ("— · %s" % _floor_name(data))
	if _daynight != null:
		var is_day: bool = bool(data.get("time", {}).get("isDay", true))
		_daynight.text = "☀" if is_day else "☾"
		_daynight.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if is_day else Color(0.6, 0.7, 1.0))
	if _msglog != null:
		_msglog.set_messages(data.get("messages", []), int(data.get("msgCount", 0)), data.get("palette", {}))
	if _nearby != null:
		_nearby.set_snapshot(data)

## Stratum label from zone.z (surface = 10, deeper = cavern -N, negative = the overworld map).
func _floor_name(data: Dictionary) -> String:
	var z: int = int(data.get("zone", {}).get("z", 10))
	if z < 0:
		return "world map"
	if z > 10:
		return "cavern -%d" % (z - 10)
	return "surface"

# NOTE: no manual key forwarding here. SubViewportContainer already delivers input to its SubViewport,
# so pushing events in ALSO would double them (one keypress -> two moves = the "double stepping" bug).
# Let the container handle it.

# ── row 4: active effects | target | context menu ────────────────────────────

func _row_context() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var eff := _cell("Active effects", Vector2(0, 90))
	eff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tgt := _cell("Target", Vector2(0, 90))
	tgt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ctx := _cell("Context menu", Vector2(0, 90))   # multipurpose text menu (fire / no weapon / …)
	ctx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(eff)
	h.add_child(tgt)
	h.add_child(ctx)
	return h

# ── row 5: command bar — ability tabs + ability slots ────────────────────────

func _row_command() -> Control:
	var strip := _strip()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	strip.add_child(h)

	h.add_child(_menu_btn("⮂ Tabs"))   # toggle ability tabs
	h.add_child(_sep())
	# Abilities [0:N] — icon + name + [status] + <hotkey>, inline like Qud. Placeholders for now.
	var demo := [
		{"name": "Sprint", "key": "1", "status": "off"},
		{"name": "Make Camp", "key": "2", "status": ""},
		{"name": "Intimidate", "key": "3", "status": ""},
		{"name": "Regeneration", "key": "4", "status": "cooldown"},
		{"name": "Lase", "key": "5", "status": "4 charges"},
		{"name": "Ambient Light", "key": "6", "status": "on"},
	]
	for i in demo.size():
		h.add_child(_ability_slot(demo[i]))
	var tail := Control.new()
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(tail)
	return strip

func _ability_slot(a: Dictionary) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(Color(0.12, 0.13, 0.17)))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	p.add_child(h)
	h.add_child(_icon(UiFont.px(get_viewport(), "body")))
	h.add_child(_text(String(a.get("name", ""))))
	var st := String(a.get("status", ""))
	if st != "":
		h.add_child(_text("[%s]" % st, COL_DIM, "caption"))   # inline status, e.g. [off] / [cooldown]
	h.add_child(_text("<%s>" % String(a.get("key", "")), COL_DIM, "caption"))   # <hotkey>, Qud style
	return p

# ── screenshot (F12) ─────────────────────────────────────────────────────────

func _shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := InputModel.support_dir().path_join("frame_shot.png")
	img.save_png(path)
	print("[frame] shot -> ", path)

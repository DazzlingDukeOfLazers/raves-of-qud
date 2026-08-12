extends CanvasLayer

## THE STATUS SCREENS — Qud's 8-tab in-game menu (StatusScreensScreen), 1:1.
##
## One shared frame (V4 plan: docs/status-screens-plan.md): a per-channel multiply
## scrim dims the LIVE game behind (measured 0.41/0.575/0.567), an opaque tab-bar
## strip on (7,26,27) with icon+letterspaced-name tabs (active white, inactive dim
## slate), numpad-7/9 page keycaps with end-stop glyphs at the bar's ends, a bottom
## rule + search field + nav hint, and a content pane per tab. Tab icons are
## extracted per-install into title/chrome/statusIcon_<tab>_{on,off}.png.
##
## Panes port one at a time; MESSAGE LOG is built (session-accumulated raw lines —
## the side panel dedupes/collapses, this screen mirrors Qud's raw list). Unported
## tabs show an empty scrim pane. Created hidden at MainFrame build time so message
## accumulation runs from the first snapshot; F2 (placeholder opener) toggles it.
##
## A CanvasLayer (90 — under the CRT at 100): the scrim's hint_screen_texture only
## sees the 3D Holodeck from a layer above the base canvas (the CRT-shader lesson).

signal closed

const TABS := [
	{"id": "skills", "name": "SKILLS"},
	{"id": "attributes", "name": "ATTRIBUTES & POWERS"},
	{"id": "equipment", "name": "EQUIPMENT"},
	{"id": "tinkering", "name": "TINKERING"},
	{"id": "journal", "name": "JOURNAL"},
	{"id": "quests", "name": "QUESTS"},
	{"id": "reputation", "name": "REPUTATION"},
	{"id": "messagelog", "name": "MESSAGE LOG"},
]
# tab cell boundaries + bar band, measured at 1920x1080
const CELL_X := [205, 346, 636, 818, 1000, 1162, 1312, 1505, 1735]
const BAR_Y := 108.0
const BAR_H := 52.0
# the scrim's per-channel multiply (menu capture / in-game capture, measured)
const SCRIM := Color(0.41, 0.575, 0.567)

var S_BAR_BG := QudChrome.q8(7, 26, 27)
var S_ACTIVE := QudChrome.q8(218, 255, 218)
var S_INACTIVE := QudChrome.q8(65, 106, 115)
var S_KEYCAP := QudChrome.q8(68, 99, 111)
var S_KEYDIGIT := QudChrome.q8(30, 140, 60)
var S_DIM_TEXT := QudChrome.q8(81, 111, 127)     # log default text
var S_HINT := QudChrome.q8(167, 192, 186)
var S_GOLD := QudChrome.q8(195, 180, 56)         # the > cursor
## Qud's rule colour, on the glass. Every 1px rule element on these screens carries #4d6e7a (54 of
## them across the probes) and lands at (68,99,111) after the CRT pass -- the same value the
## attributes pane arrived at independently for its own spine (C_LINE). Ours targeted (60,84,92),
## which is a good 12 too dark on every rule the shared frame draws: the top rule, both verticals,
## the bottom rule and the corner stub.
var S_RULE := QudChrome.q8(68, 99, 111)

var _root: Control           # full-rect content root inside this layer
## Qud's vertical rules are PER TAB. They are not an outer frame at all: every one of them is an
## element inside a tab's own subtree (Screens/<Tab>/.../Vertical Border), so the position, the
## vertical extent AND whether a side is drawn at all change with the tab. Measured across all
## eight -- three tabs draw none, tinkering draws only a left, attributes' right sits at 1745 while
## journal's and quests' sit at 1748.
##
## Drawing one fixed pair (166 / 1753) put a full-height rule down the right of every tab. That pair
## is the EQUIPMENT tab's, which is where it was measured; it was right on one tab in eight.
##
## Values are pixel-measured off Qud, one capture per tab, with the tab confirmed first-party
## before each shot: [x, y_top, y_bottom]. Interior column dividers (attributes 816/834, journal
## 952, quests 1021) belong to the panes, not here.
## The top rule's centred gap, half-width, per tab -- and which tabs draw one at all. Measured the
## same way as TAB_VRULES: equipment 581..1338, journal 726..1193, tinkering 842..1077, every one
## centred on 959.5. The other five draw no top rule, and we were drawing the equipment tab's on all
## eight.
const TOP_CENTRE := 959.5
## EVERY GAP IN THE TOP RULE IS BRACKETED BY A TICK -- a 1px column, 14 tall, at y=190. Qud's
## CategoryBar carries them as `VBar` children either side of each spacer, and there are six on a
## tab that draws a rule: the left notch, the centred gap the carousel sits in, and the right notch.
## Reported as "carousel bar on the right-hand side has ---| |---", and it does.
##
## Measured off Qud's journal screen, column by column: the rule runs to 203, a tick occupies 204
## (rows 190..203), the gap is 205..212, a tick occupies 213, the rule resumes at 214. Same shape at
## 726 / 1193 around the carousel and at 1705 / 1714 at the right end. Raves drew the rule THROUGH
## those six columns, so the ticks read as a rule that simply stopped.
##
## This also retires the per-tab TOP_LEFT_END. The journal was recorded at 208 where the other two
## tabs were 204 -- one tab out of three disagreeing about a fixed notch should have been the tell.
## Qud's own probe puts its VBars at 204.5/213.5 on the journal too; the 208 was the rule and its
## tick read as one run.
const TOP_LEFT_END := 204.0
const TOP_RESUME := 213.0
const TICK_Y := 190.0
const TICK_H := 14.0
## THE EQUIPMENT GAP IS NOT A CONSTANT -- it is the filter strip's span plus a 9px margin either
## side, and the strip grows with the character's categories. 378.5 is what that formula yields for
## the 11-category reference fixture (739/2 + 9), which is why it looked like a measured constant
## for as long as we only ever measured that fixture. On a 17-category character Qud's rule ends at
## 407 and resumes at 1512 -- g = 552.5 = 1087/2 + 9 -- while Raves still drew 378.5 and struck
## through three cells on each side. Same defect as FILT_MAX_CELLS one file over: a number read off
## one save, mistaken for geometry. Journal and tinkering carry no strip, so theirs stay fixed.
## How often an open tab re-reads its export. Inherited from the one-shot follow-ups this
## replaced; fast enough that a re-file lands within a blink, and one mtime stat per tick.
const PANE_POLL_S := 1.2
const TOP_GAP_PAD := 9.0
const TAB_TOPGAP := {
	"equipment":  378.5,   # fallback only, for the frame drawn before the pane has data
	"journal":    233.5,
	"tinkering":  117.5,
}

## INTERIOR COLUMN DIVIDERS — the rule BETWEEN panes, with Qud's plant ornament sitting in a
## break at its middle and a small diamond knob capping every free end. An earlier note here
## said interior dividers "belong to the panes, not here"; they do not — they are frame chrome
## like the outer rules, and no pane was drawing them, so the equipment tab ran its item list
## straight up against the paper doll and tinkering had nothing between its three columns.
## Reported 2026-08-10: "add vertical separator line and artwork between paperdoll and inventory
## item list" / "add two vertical separators to match Qud".
##
## Every number is first-party, read off Qud's own RectTransforms (hv bridge uiprobe) rather
## than a screenshot: `VLine`/`Image` for the rule halves, `polat-center-divider-knob` (7x7) for
## the caps and `polat-vertical-divider-decoration` (40x122) for the ornament, both extracted
## from the player's install. `x` is the rule's column; the ornament is centred on it and the
## knob straddles it (x-3), which is why neither carries an x of its own.
const TAB_VDIV := {
	"equipment": [
		{"x": 825.0, "top": [236.0, 498.5], "orn": 516.5, "bot": [656.5, 919.0],
			"knobs": [229.0, 498.5, 649.5, 919.0]},
	],
	# Tinkering butts the ornament straight onto both rule halves — no 11px spacers and no
	# inner knobs, only the two outer caps. Same art, different assembly; do not "tidy" the
	# two tabs into one shape.
	"tinkering": [
		{"x": 801.0, "top": [242.0, 522.5], "orn": 522.5, "bot": [644.5, 925.0],
			"knobs": [242.0, 918.0]},
		{"x": 1341.0, "top": [242.0, 522.5], "orn": 522.5, "bot": [644.5, 925.0],
			"knobs": [242.0, 918.0]},
	],
}
const VDIV_ORN := Vector2(40, 122)
const VDIV_KNOB := Vector2(7, 7)

const TAB_VRULES := {
	"attributes": [[173.0, 180.0, 938.0], [1745.0, 236.0, 938.0]],
	"equipment":  [[166.0, 197.0, 938.0], [1753.0, 197.0, 938.0]],
	"journal":    [[1748.0, 197.0, 938.0]],
	"quests":     [[1748.0, 180.0, 938.0]],
	"tinkering":  [[166.0, 197.0, 938.0]],
	"messagelog": [],
	"reputation": [],
	"skills":     [],
}

var _tab := "messagelog"
var _hover_tab := -1
var _palette := {}
var _icons := {}             # "<id>_on"/"<id>_off" -> Texture2D
var _orn_tex: Texture2D = null    # polat-vertical-divider-decoration (40x122), TAB_VDIV
var _knob_tex: Texture2D = null   # polat-center-divider-knob (7x7), TAB_VDIV
var _bar: Control
var _pane_host: Control
var _frame: Control = null   # the screen chrome layer; repainted on tab change
var _log_scroll: ScrollContainer
var _log_box: VBoxContainer
var _search: LineEdit
var _hint: RichTextLabel     # bottom hint bar — content changes per tab, like Qud's
var _cursor: Label           # the gold > beside the newest log line
var _filter := ""

# raw session log (Qud's screen shows raw lines, repeats included)
var _all_lines: Array = []
var _msg_total := 0
var _seeded := false

# character sheet (Attributes & Powers): mod CharacterExporter -> character.json;
# we request a fresh export on open via our own bridge peer (Records pattern)
var _attr_pane: Control = null
var _skills_pane: Control = null
var _skills_mtime := 0
var _inv_pane: Control = null
var _quests_pane: Control = null
var _quests_mtime := 0
var _fact_pane: Control = null
var _fact_mtime := 0
var _jrn_pane: Control = null
var _jrn_mtime := 0
var _tnk_pane: Control = null
var _tnk_mtime := 0
var _inv_mtime := 0
var _char_mtime := 0
var _pane_pal_empty := true
var _portrait_tex: Texture2D = null   # live player tile — also the attributes tab's icon
var _peer := StreamPeerTCP.new()
var _tiles: RefCounted = null
var _last_player := {}
var _tiles_dir := ""

func _init() -> void:
	layer = 90                                   # above chrome+3D, under the CRT (100)
	name = "StatusScreens"
	visible = false

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP     # modal while shown
	_root.gui_input.connect(func(e: InputEvent):
		if _tab == "skills" and _skills_pane != null and _skills_pane.visible \
				and _skills_pane.has_method("handle_mouse"):
			_skills_pane.handle_mouse(e)
		elif _tab == "equipment" and _inv_pane != null and _inv_pane.visible \
				and _inv_pane.has_method("handle_mouse"):
			_inv_pane.handle_mouse(e)
		elif _tab == "reputation" and _fact_pane != null and _fact_pane.visible \
				and _fact_pane.has_method("handle_mouse"):
			_fact_pane.handle_mouse(e)
		elif _tab == "journal" and _jrn_pane != null and _jrn_pane.visible \
				and _jrn_pane.has_method("handle_mouse"):
			_jrn_pane.handle_mouse(e)
		# CONSUME IT. MOUSE_FILTER_STOP is not enough for the WHEEL: Godot propagates a
		# wheel event up the Control chain and marks it handled only when someone calls
		# accept_event() — so scrolling the skills list ALSO reached Main's
		# _unhandled_input and zoomed the playfield behind the modal (measured
		# 2026-08-10: tiles visibly larger, against 0.00 ambient diff). Buttons and
		# motion are consumed for the same reason a modal owns the whole screen even
		# where it does not paint.
		if e is InputEventMouseButton or e is InputEventMouseMotion:
			_root.accept_event())
	_root.theme = UiFont.make_theme(get_viewport())    # CanvasLayer theme-root trap
	add_child(_root)
	for t in TABS:
		for st in ["on", "off"]:
			var p := InputModel.support_dir().path_join("title").path_join("chrome").path_join(
				"statusIcon_%s_%s.png" % [t["id"], st])
			if FileAccess.file_exists(p):
				var img := Image.new()
				if img.load(p) == 0:
					_icons["%s_%s" % [t["id"], st]] = ImageTexture.create_from_image(QudChrome.brighten(img))
	# The interior dividers' art, extracted from the player's own install (see TAB_VDIV).
	# Absent until someone has run the export, and the rule halves still draw without them —
	# a missing ornament must not take the separator with it.
	_orn_tex = _load_tile_sprite("divider_orn.png")
	_knob_tex = _load_tile_sprite("divider_knob.png")
	_build()

## NO QudChrome.brighten HERE, AND THAT IS THE POINT. Pre-compensation is for a colour MEASURED
## OFF A QUD CAPTURE: that number is Qud's OUTPUT, so it is the target and has to be pushed
## through INV to survive Raves' canvas sag. An EXTRACTED SPRITE is the opposite — its texels are
## Qud's INPUT, and Qud's own canvas sags them by the same curve on the way to the screen. Drawing
## them raw reproduces Qud exactly; brightening them first cancels Qud's sag and leaves the art
## ~12% too light.
##
## Measured, all three channels, on the divider ornament (2026-08-10): texel (58,80,92) ->
## Qud draws (51,70,82), and QudChrome.INV[51]=58, INV[70]=80, INV[82]=92. The forward curve maps
## the raw texel onto Qud's screen value on the nose, three for three.
func _load_tile_sprite(fname: String) -> Texture2D:
	var p := InputModel.support_dir().path_join("tiles").path_join(fname)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != 0:
		return null
	return ImageTexture.create_from_image(img)

func _build() -> void:
	# the multiply scrim: a screen-texture shader (a plain MUL ColorRect can't dim the
	# 3D Holodeck under the canvas hole — same reason the CRT overlay uses a shader)
	var scrim := ColorRect.new()
	var sh := Shader.new()
	# NOT a multiply: Qud's scrim is an ~82%-opaque dark-teal ALPHA BLEND — fitted
	# out = k*in + b per channel on dark ground AND the bright Joppa water pools
	# (a multiply matched the darks but left brights 2x too bright)
	sh.code = """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture;
void fragment() {
	vec4 c = texture(screen_tex, SCREEN_UV);
	COLOR = vec4(c.rgb * vec3(0.190, 0.168, 0.170) + vec3(3.79, 21.27, 20.34) / 255.0, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	scrim.material = mat
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.set_meta("feedback_pass", true)   # full-window chrome — never the element feedback means
	_root.add_child(scrim)

	# opaque tab-bar strip + tabs + keycap clusters (one draw pass)
	_bar = Control.new()
	_bar.position = Vector2(0, BAR_Y)
	_bar.size = Vector2(1920, BAR_H)
	_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	# NEAREST for everything the bar draws — the live tab icon scales 1.5x, and the
	# default LINEAR filter smears it soft/dim next to the crisp NEAREST portrait
	_bar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bar.draw.connect(_draw_bar)
	_bar.gui_input.connect(_bar_input)
	_root.add_child(_bar)

	# content host (panes draw inside; the scrim already dimmed what's behind)
	_pane_host = Control.new()
	_pane_host.position = Vector2(0, BAR_Y + BAR_H)
	_pane_host.size = Vector2(1920, 940 - (BAR_Y + BAR_H))
	_pane_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_pane_host)
	_build_log_pane()

	# THE OUTER FRAME. Only the bottom rule existed; the top, left and right edges were
	# never drawn at all (measured: Qud lights 1018/712/711 px on them, Raves 189/2/40 --
	# and the 189 was the filter strip crossing that row, not a line). MEASURED off Qud:
	#   top    y197, in four segments -- 158-204, 213-581, 1338-1705, 1714-1760, the gaps
	#          at 205-212 and 1706-1713 being notches and the long one the filter strip
	#   left/right: PER TAB, see TAB_VRULES -- they are not part of this frame at all
	#   bottom y937, x158-1760       (the rule that was already here)
	# The verticals start ~30px below the top line: that gap is the corner ornament's,
	# and drawing through it would be worse than leaving it.
	var frame := Control.new()
	frame.position = Vector2.ZERO
	frame.size = Vector2(1920, 1080)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # see TAB_VDIV
	_frame = frame
	frame.draw.connect(func():
		# The top rule is per tab too, and it is a GAP, not a fixed set of segments: it runs
		# 158-204 / 213 .. (centre - g) and (centre + g) .. 1705 / 1714-1760, where the gap is
		# centred on 959.5 on every tab that has one and only its half-width g changes with the
		# tab's header block. Five tabs draw no top rule at all.
		var g: float = TAB_TOPGAP.get(_tab, -1.0)
		# ...except on equipment, where the carousel sets it — see TOP_GAP_PAD.
		if _tab == "equipment" and _inv_pane != null and _inv_pane.has_method("filter_span"):
			g = _inv_pane.filter_span() * 0.5 + TOP_GAP_PAD
		if g > 0.0:
			# The three gaps, as [first tick column, last tick column]. Everything else follows:
			# a rule segment fills each span BETWEEN gaps, and a tick stands on each gap edge.
			var gaps := [[TOP_LEFT_END, TOP_RESUME], [TOP_CENTRE - g, TOP_CENTRE + g],
				[1705.0, 1714.0]]
			var from := 158.0
			for gap in gaps:
				frame.draw_rect(Rect2(from, 197.0, gap[0] - from, 1.0), S_RULE)
				for tx in gap:
					frame.draw_rect(Rect2(tx, TICK_Y, 1.0, TICK_H), S_RULE)
				from = gap[1] + 1.0
			frame.draw_rect(Rect2(from, 197.0, 1762.0 - from, 1.0), S_RULE)
		# The verticals belong to the TAB, not the frame -- see TAB_VRULES.
		for r in TAB_VRULES.get(_tab, []):
			frame.draw_rect(Rect2(r[0], r[1], 1.0, r[2] - r[1] + 1.0), S_RULE)
		# ...and so do the INTERIOR ones, which carry art -- see TAB_VDIV.
		for d in TAB_VDIV.get(_tab, []):
			var dx: float = d["x"]
			for half in [d["top"], d["bot"]]:
				frame.draw_rect(Rect2(dx, half[0], 1.0, half[1] - half[0]), S_RULE)
			# FLOOR THE SPRITE ORIGINS. Qud's RectTransforms sit on half pixels (the ornament at
			# y=516.5, two of the four knobs at .5) and Unity lands them on the pixel grid; drawn
			# at the raw y, Godot blends each row across two and the ornament grew a faint copy of
			# every edge -- measured as extra lit runs at 568/572 where Qud has bare background.
			# NEAREST on top of that, so nothing resamples a sprite that is already 1:1.
			if _orn_tex != null:
				frame.draw_texture(_orn_tex,
					Vector2(floorf(dx - VDIV_ORN.x * 0.5), floorf(d["orn"])))
			if _knob_tex != null:
				for ky in d["knobs"]:
					frame.draw_texture(_knob_tex,
						Vector2(floorf(dx - (VDIV_KNOB.x - 1.0) * 0.5), floorf(ky)))
		# EQUIPMENT ONLY. The Ctrl+Tab cybernetics hint belongs to the paper doll; drawn
		# unconditionally it printed over the first row of every other tab's content.
		if _tab == "equipment":
			_draw_cyber_hint(frame))
	frame.set_meta("feedback_pass", true)
	_root.add_child(frame)

	# bottom rule + search + hint
	var bottom := Control.new()
	bottom.position = Vector2(0, 936)
	bottom.size = Vector2(1920, 60)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.draw.connect(func():
		bottom.draw_rect(Rect2(160, 1, 1600, 2), S_RULE)
		# magnifier
		bottom.draw_arc(Vector2(185, 24), 6, 0, TAU, 12, S_HINT, 1.5)
		bottom.draw_line(Vector2(190, 29), Vector2(196, 35), S_HINT, 1.5))
	bottom.set_meta("feedback_pass", true)
	_root.add_child(bottom)
	_search = LineEdit.new()
	_search.position = Vector2(205, 950)
	_search.size = Vector2(150, 24)
	_search.placeholder_text = "<search>"
	# FOCUS_CLICK, and released on every open: with the default focus mode this field
	# holds focus and eats the ACCEPT key, so Enter/Space never reach the pane. The
	# giveaway is that arrows still work -- a LineEdit passes up/down through and
	# swallows only what it uses. Same law as the Holodeck's FOCUS_NONE rule.
	_search.focus_mode = Control.FOCUS_CLICK
	_search.add_theme_font_size_override("font_size", 14)
	_search.add_theme_color_override("font_color", S_HINT)
	_search.add_theme_color_override("font_placeholder_color", S_INACTIVE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.25)
	sb.set_border_width_all(1)
	sb.border_color = S_RULE
	sb.content_margin_left = 6
	_search.add_theme_stylebox_override("normal", sb)
	_search.text_changed.connect(func(t):
		_filter = t.strip_edges().to_lower()
		_refresh_log())
	_root.add_child(_search)
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.fit_content = true
	_hint.scroll_active = false
	_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("normal_font_size", 16)
	# Qud centres the hint row on x~1067 (measured on both tabs); a CenterContainer
	# keeps it centred as per-tab content changes its width
	var hc := CenterContainer.new()
	hc.position = Vector2(367, 950)
	hc.size = Vector2(1400, 28)
	hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hc.add_child(_hint)
	_root.add_child(hc)
	_build_hints()

	# THE POLL THAT USED TO STOP. Every loader ended with a one-shot `create_timer(1.2)`
	# that re-armed itself -- but on the SUCCESS path only, below the `mt == _..._mtime`
	# early return. So the chain died the first time the file had not changed, which is
	# the normal case one tick after opening a tab, and from then on the pane showed
	# whatever it had read at open time until the tab was left and re-entered.
	#
	# Identifying an artifact is the sharp case (reported 2026-08-10): Qud re-files the
	# object out of Artifacts into its real category, the mod re-exports -- and Raves went
	# on drawing "Artifacts / odd trinket" against an inventory.json that already said
	# "Trade Goods / gyre iron". A REPEATING timer is re-armed by the engine rather than by
	# the code path that just decided there was nothing to do, so it cannot stop.
	var poll := Timer.new()
	poll.name = "PanePoll"
	poll.wait_time = PANE_POLL_S
	poll.autostart = true
	poll.timeout.connect(_poll_panes)
	add_child(poll)

## Re-read the ACTIVE tab's export. One file's mtime per tick -- cheap, and the only tab
## whose pane anyone can see. Deliberately does NOT _request_export(): that re-exports
## every screen in the game (blueprints, tiles, records) and belongs on a tab switch, not
## on a heartbeat. The mod already re-exports the inventory after anything Raves drives
## through it (Twiddle, Identify), so the fresh file is there to be found.
func _poll_panes() -> void:
	if not visible:
		return
	match _tab:
		"attributes": _load_character()
		"skills":     _load_skills()
		"equipment":  _load_inventory()
		"quests":     _load_quests()
		"reputation": _load_factions()
		"journal":    _load_journal()
		"tinkering":  _load_tinkering()


## Rebuild the bottom hint bar for the active tab (Qud's changes per screen).
func _build_hints() -> void:
	if _hint == null:
		return
	_hint.clear()
	var wht := "#FFFFFF"
	var dimc := "#%s" % S_HINT.to_html(false)
	var goldc := "#%s" % QudChrome.q8(200, 184, 57).to_html(false)
	_hint.push_paragraph(HORIZONTAL_ALIGNMENT_LEFT)
	_hint.append_text("[color=%s][lb][/color]" % wht)
	_hint.add_image(QudChrome.nav_icon(15), 22, 15)
	_hint.append_text("[color=%s][rb][/color]" % wht)
	_hint.append_text("[color=%s] navigation  [/color]" % dimc)
	var keys := [["Space", "Accept"]]
	if _tab == "attributes":
		keys.append(["E", "Show Effects"])
		keys.append(["M", "Buy Mutation"])
	for k in keys:
		_hint.append_text("[color=%s][lb][/color][color=%s]%s[/color][color=%s][rb][/color]" % [wht, goldc, k[0], wht])
		_hint.append_text("[color=%s] %s  [/color]" % [dimc, k[1]])
	_hint.pop()
# ── the tab bar ────────────────────────────────────────────────────────────────

func _draw_bar() -> void:
	_bar.draw_rect(Rect2(0, 0, 1920, BAR_H), S_BAR_BG)
	var f := _root.get_theme_font("font", "Label")
	for i in TABS.size():
		var t: Dictionary = TABS[i]
		var active: bool = (t["id"] == _tab)
		var cx0: int = CELL_X[i]
		var cw: int = CELL_X[i + 1] - cx0
		var icon: Texture2D = _icons.get("%s_%s" % [t["id"], "on" if active else "off"])
		var live: bool = (t["id"] == "attributes" and _portrait_tex != null)
		var tw := f.get_string_size(t["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		var iw := 0.0
		if live:
			iw = 24.0 + 10.0
		elif icon != null:
			iw = icon.get_width() + 10.0
		var x := cx0 + (cw - (iw + tw)) * 0.5
		if live:
			# Qud's Attributes tab icon IS the character sprite, same 24x36 as the
			# sheet portrait, facing left. Flip via TRANSFORM so the 1.5x NEAREST
			# duplicate-columns land like the portrait's flip_h (scale THEN mirror —
			# a pre-flipped image mirrors first and doubles the other side: derpy).
			_bar.draw_set_transform(Vector2(x + 24.0, 10.0), 0.0, Vector2(-1, 1))
			_bar.draw_texture_rect(_portrait_tex, Rect2(0, 0, 24, 36), false,
				Color.WHITE if active else Color(0.5, 0.62, 0.66))
			_bar.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		elif icon != null:
			_bar.draw_texture(icon, Vector2(x, (BAR_H - icon.get_height()) * 0.5 + 1))
		_bar.draw_string(f, Vector2(x + iw, 36), t["name"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, S_ACTIVE if active else S_INACTIVE)
		if _hover_tab == i and not active:
			_bar.draw_string(f, Vector2(x - 14, 36), ">", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, S_GOLD)
	# numpad 7/9 page keycaps with end-stop glyphs: "⊣ [7]" left, "[9] ⊢" right
	_draw_keycap(163, true)
	_draw_keycap(1722, false)

## Qud's "[Ctrl+Tab] show cybernetics" hint, hung off the frame's left edge.
##
## All MEASURED off the reference, by reading the region as a bitmap rather than
## eyeballing it: the ⊣ tick that joins it to the edge is a 24x1 at y227 plus a 1x16
## at x189; the keycap is a 20x15 outline at (207,220) with "Ctrl" inside; "+Tab]"
## follows in the same gold, and "show cybernetics" runs from x278 in the hint grey.
func _draw_cyber_hint(c: CanvasItem) -> void:
	var f: Font = _root.get_theme_default_font()
	if f == null:
		return
	if not Settings.one_to_one():
		# USER MODE: the LIVE "Toggle" binding(s) from the control-mapping export.
		# Qud's own caption renders only the primary slot, so a player who ADDS a
		# binding (F7) without replacing slot 1 reads a stale Ctrl+Tab forever
		# (flagged 2026-08-10). 1:1 below stays verbatim-Qud, stale caption and all.
		c.draw_rect(Rect2(166.0, 227.0, 24.0, 1.0), S_RULE)
		c.draw_rect(Rect2(189.0, 220.0, 1.0, 16.0), S_RULE)
		var labels := PackedStringArray()
		for b in load("res://StatusPaneInventory.gd").toggle_binds():
			var l := str(b.get("label", ""))
			if l != "" and not labels.has(l):
				labels.append(l)
		var cap2 := "[%s]" % " / ".join(labels)
		c.draw_string(f, Vector2(199.0, 233.0), cap2, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, S_GOLD)
		var w := f.get_string_size(cap2, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		c.draw_string(f, Vector2(199.0 + w + 9.0, 233.0), "show cybernetics",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, S_HINT)
		return
	c.draw_rect(Rect2(166.0, 227.0, 24.0, 1.0), S_RULE)     # ⊣ into the left edge
	c.draw_rect(Rect2(189.0, 220.0, 1.0, 16.0), S_RULE)
	# 14, not 16: MEASURED against Qud's own advances -- its "show" is 33px for four
	# glyphs where 16 gave us 37, and the error compounds along the line
	c.draw_string(f, Vector2(199.0, 233.0), "[", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, S_GOLD)
	# the keycap: outline only, the label inset
	c.draw_rect(Rect2(207.0, 220.0, 20.0, 15.0), S_GOLD, false, 1.0)
	# The keycap label is CONDENSED, not small: Qud fits 17x11 of ink in a 20-wide box,
	# where our font at the size that gives 11px of height wants ~26. Shrinking the size
	# instead (10 -> 7px tall) made it squat and ran the "l" into the border. Draw at a
	# height-correct size and SQUEEZE horizontally to Qud's measured 17.
	var cap := 16
	var capw := f.get_string_size("Ctrl", HORIZONTAL_ALIGNMENT_LEFT, -1, cap).x
	if capw > 0.0:
		c.draw_set_transform(Vector2(209.0, 232.0), 0.0, Vector2(17.0 / capw, 1.0))
		c.draw_string(f, Vector2.ZERO, "Ctrl", HORIZONTAL_ALIGNMENT_LEFT, -1, cap, S_GOLD)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	c.draw_string(f, Vector2(229.0, 233.0), "+Tab]", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, S_GOLD)
	c.draw_string(f, Vector2(278.0, 233.0), "show cybernetics",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, S_HINT)

func _draw_keycap(x: float, left: bool) -> void:
	var box_x := x + (18.0 if left else 0.0)
	_bar.draw_rect(Rect2(box_x, 11, 20, 30), S_KEYCAP)
	var f := _root.get_theme_font("font", "Label")
	_bar.draw_string(f, Vector2(box_x + 6, 33), "7" if left else "9",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, S_KEYDIGIT)
	var gy := 26.0
	if left:
		_bar.draw_rect(Rect2(x - 16, gy - 1, 14, 2), S_KEYCAP)   # ⊣
		_bar.draw_rect(Rect2(x - 3, 14, 2, 24), S_KEYCAP)
	else:
		_bar.draw_rect(Rect2(box_x + 21, 14, 2, 24), S_KEYCAP)   # ⊢
		_bar.draw_rect(Rect2(box_x + 23, gy - 1, 14, 2), S_KEYCAP)

func _bar_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := _tab_at(e.position.x)
		if h != _hover_tab:
			_hover_tab = h
			_bar.queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var i := _tab_at(e.position.x)
		if i >= 0:
			_set_tab(TABS[i]["id"])

## FEEDBACK PROVIDER for the tab bar (drawn in one pass — no per-tab nodes). "tab · Equipment"
## with the cell's own rect, using the same CELL_X math the click handler uses.
func feedback_element_at(p: Vector2) -> Dictionary:
	# The TAB branch is bar-gated; the pane delegation is NOT. The first cut gated the whole
	# function on the bar's rect, so every click outside the tab strip returned {} before the
	# delegation could run — the paper doll never had a chance.
	if _bar != null and _bar.is_visible_in_tree() and _bar.get_global_rect().has_point(p):
		var i := _tab_at(p.x)
		if i >= 0:
			var r := _bar.get_global_rect()
			return {"label": "tab · " + str(TABS[i]["name"]),
				"key": "tab." + str(TABS[i]["id"]),
				"rect": Rect2(CELL_X[i], r.position.y, CELL_X[i + 1] - CELL_X[i], r.size.y),
				"action": "switch to the " + str(TABS[i]["name"]) + " tab"}
	# DELEGATE to the visible pane: the panes are owner-drawn and late overlays keep them out of
	# the hit's ancestor chain, but THIS layer is always in it — so it forwards. Any pane that
	# implements the contract gets interior resolution for free.
	for pane in [_inv_pane, _attr_pane, _skills_pane, _quests_pane, _fact_pane, _jrn_pane, _tnk_pane]:
		if pane != null and pane.visible and pane.has_method("feedback_element_at"):
			return pane.feedback_element_at(p)
	return {}


func _tab_at(x: float) -> int:
	for i in TABS.size():
		if x >= CELL_X[i] and x < CELL_X[i + 1]:
			return i
	return -1

func _set_tab(id: String) -> void:
	_tab = id
	_bar.queue_redraw()
	if _frame != null:
		_frame.queue_redraw()   # the chrome draws tab-dependent bits (the cybernetics hint)
	_log_scroll.visible = (id == "messagelog")
	if _cursor != null:
		_cursor.visible = (id == "messagelog")
	if id == "messagelog":
		_refresh_log()
	if _attr_pane != null:
		_attr_pane.visible = (id == "attributes")
	if _skills_pane != null:
		_skills_pane.visible = (id == "skills")
	if _inv_pane != null:
		_inv_pane.visible = (id == "equipment")
	if _quests_pane != null:
		_quests_pane.visible = (id == "quests")
	if _fact_pane != null:
		_fact_pane.visible = (id == "reputation")
	if _jrn_pane != null:
		_jrn_pane.visible = (id == "journal")
	if _tnk_pane != null:
		_tnk_pane.visible = (id == "tinkering")
	if id == "attributes":
		_request_export()
		_load_character()
	if id == "skills":
		_request_export()
		_load_skills()
		_load_character()   # the skills header's Icon is the portrait character.json builds
		                    # -- without this it stayed null until the user VISITED attributes
	if id == "equipment":
		_request_export()
		_load_inventory()
	if id == "quests":
		_request_export()
		_load_quests()
	if id == "reputation":
		_request_export()
		_load_factions()
	if id == "journal":
		_request_export()
		_load_journal()
	if id == "tinkering":
		_request_export()
		_load_tinkering()
	_build_hints()
	if visible:
		UiState.set_scene("status_" + _tab)

## Send any bridge command from this screen's own peer (fire-and-forget).
func _send_bridge(msg: Dictionary) -> void:
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		return
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var frame := PackedByteArray()
	var n := payload.size()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## Ask the mod for a fresh data export (character.json etc.); fire-and-forget.
func _request_export() -> void:
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		return
	var payload := JSON.stringify({"type": "command", "name": "export"}).to_utf8_buffer()
	var frame := PackedByteArray()
	var n := payload.size()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## (Re)build the Attributes & Powers pane from character.json when it changes.
func _load_character() -> void:
	var path := InputModel.support_dir().path_join("character.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	# rebuild despite an unchanged file if the pane was built before the palette
	# arrived (an early open rendered every colour code white)
	var pane_missing_portrait: bool = _attr_pane != null and _attr_pane.has_method("has_portrait") \
		and not _attr_pane.has_portrait() and not _last_player.is_empty()
	if _attr_pane != null and mt == _char_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()) and not pane_missing_portrait:
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)   # strip a UTF-8 BOM — JSON.parse_string rejects it
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_char_mtime = mt
	if _attr_pane == null:
		_attr_pane = load("res://StatusPaneAttributes.gd").new()
		_attr_pane.name = "AttributesPane"
		_root.add_child(_attr_pane)
	# the player portrait: white tile + detail colour, like the frame's avatar
	# portrait straight from character.json (tile + detail code) — snapshots proved
	# an unreliable source (they only flow on turns/connect; a menu-opened pane raced)
	var tex: Texture2D = null
	var tile := String(data.get("tile", ""))
	if tile != "":
		_tiles.tiles_dir = InputModel.support_dir().path_join("tiles")
		if not _palette.is_empty():
			_tiles.palette = _palette
		tex = _tiles.texture(tile, Color.WHITE, _tiles.color_of(String(data.get("detail", "")), Color.WHITE))
	_portrait_tex = tex
	if _bar != null:
		_bar.queue_redraw()   # the attributes tab icon IS the live portrait
	if _skills_pane != null:
		_skills_pane.set_portrait(tex)   # the skills header's Icon is the same portrait
	_pane_pal_empty = _palette.is_empty()
	_attr_pane.setup(data, _palette, tex)
	_attr_pane.visible = (_tab == "attributes")

## (Re)build the Skills pane from skills.json when it changes (same guards as the
## character sheet: mtime, plus a rebuild once the palette lands).
func _load_skills(force := false) -> void:
	var path := InputModel.support_dir().path_join("skills.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _skills_pane != null and mt == _skills_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_skills_mtime = mt
	if _skills_pane == null:
		_skills_pane = load("res://StatusPaneSkills.gd").new()
		_skills_pane.name = "SkillsPane"
		_skills_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_skills_pane.reload_cb = func(): _load_skills(true)
		_root.add_child(_skills_pane)
	_pane_pal_empty = _palette.is_empty()
	_skills_pane.setup(data, _palette)
	_skills_pane.set_portrait(_portrait_tex)   # Qud's header Icon; null until character.json lands
	_skills_pane.visible = (_tab == "skills")





## (Re)build the Tinkering tab from tinkering.json.
func _load_tinkering(force := false) -> void:
	var path := InputModel.support_dir().path_join("tinkering.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _tnk_pane != null and mt == _tnk_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_tnk_mtime = mt
	if _tnk_pane == null:
		_tnk_pane = load("res://StatusPaneTinkering.gd").new()
		_tnk_pane.name = "TinkeringPane"
		_tnk_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_tnk_pane.reload_cb = func(): _load_tinkering(true)
		_root.add_child(_tnk_pane)
	_pane_pal_empty = _palette.is_empty()
	_tnk_pane.setup(data, _palette)
	_tnk_pane.visible = (_tab == "tinkering")

## (Re)build the Journal tab from journal.json.
func _load_journal(force := false) -> void:
	var path := InputModel.support_dir().path_join("journal.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _jrn_pane != null and mt == _jrn_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_jrn_mtime = mt
	if _jrn_pane == null:
		_jrn_pane = load("res://StatusPaneJournal.gd").new()
		_jrn_pane.name = "JournalPane"
		_jrn_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_jrn_pane.reload_cb = func(): _load_journal(true)
		_root.add_child(_jrn_pane)
	_pane_pal_empty = _palette.is_empty()
	_jrn_pane.setup(data, _palette)
	_jrn_pane.visible = (_tab == "journal")

## (Re)build the Reputation tab's faction list from factions.json.
func _load_factions(force := false) -> void:
	var path := InputModel.support_dir().path_join("factions.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _fact_pane != null and mt == _fact_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_fact_mtime = mt
	if _fact_pane == null:
		_fact_pane = load("res://StatusPaneFactions.gd").new()
		_fact_pane.name = "ReputationPane"
		_fact_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_fact_pane.reload_cb = func(): _load_factions(true)
		_root.add_child(_fact_pane)
	_pane_pal_empty = _palette.is_empty()
	_fact_pane.setup(data, _palette)
	_fact_pane.visible = (_tab == "reputation")

## (Re)build the Quests tab's list from quests.json.
func _load_quests(force := false) -> void:
	var path := InputModel.support_dir().path_join("quests.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _quests_pane != null and mt == _quests_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_quests_mtime = mt
	if _quests_pane == null:
		_quests_pane = load("res://StatusPaneQuests.gd").new()
		_quests_pane.name = "QuestsPane"
		_quests_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_quests_pane.reload_cb = func(): _load_quests(true)
		_root.add_child(_quests_pane)
	_pane_pal_empty = _palette.is_empty()
	_quests_pane.setup(data, _palette)
	_quests_pane.visible = (_tab == "quests")

## (Re)build the Equipment tab's inventory pane from inventory.json.
func _load_inventory(force := false) -> void:
	var path := InputModel.support_dir().path_join("inventory.json")
	if not FileAccess.file_exists(path):
		return
	var mt := FileAccess.get_modified_time(path)
	if not force and _inv_pane != null and mt == _inv_mtime \
			and not (_pane_pal_empty and not _palette.is_empty()):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_inv_mtime = mt
	if _inv_pane == null:
		_inv_pane = load("res://StatusPaneInventory.gd").new()
		_inv_pane.name = "EquipmentPane"
		_inv_pane.bridge_cb = func(msg: Dictionary): _send_bridge(msg)
		_inv_pane.reload_cb = func(): _load_inventory(true)
		_root.add_child(_inv_pane)
	_pane_pal_empty = _palette.is_empty()
	_inv_pane.setup(data, _palette)
	_inv_pane.visible = (_tab == "equipment")
	# The frame's top rule is sized from THIS pane's strip, so it is stale the moment the strip
	# changes width — a category emptying out or appearing moves both ends of the gap.
	if _frame != null:
		_frame.queue_redraw()

# ── open / close / input ───────────────────────────────────────────────────────

func open(tab := "") -> void:
	if tab != "":
		_tab = tab
	visible = true
	_hover_tab = -1
	if _search != null:
		_search.release_focus()
	_set_tab(_tab)

func close() -> void:
	visible = false
	UiState.set_scene("in_game")
	closed.emit()

## An item action finishes when the viewer ANSWERS the popup, which can be seconds
## after it opened -- so the pane reloads on popup CLOSE. Firing timers from the moment
## the menu opened (the first attempt) meant they had all expired before the choice was
## made, and the list still showed an item that had just been dropped.
func _refresh_after_popup() -> void:
	if not visible:
		return
	if _tab == "equipment":
		_load_inventory(true)
	elif _tab == "skills":
		_load_skills(true)

## TAB IS EATEN BY GODOT'S FOCUS TRAVERSAL (ui_focus_next) before _unhandled_input ever runs, so
## Qud's Ctrl+Tab mode toggle never reached the Tinkering pane. Same class as the Holodeck click
## trap already in gotchas.md: anything competing with built-in GUI handling belongs in _input.
func _input(e: InputEvent) -> void:
	# typing guard: this dispatch runs before the GUI pass, so a focused text field has
	# not consumed the key yet — see TypingGuard
	if TypingGuard.typing(get_viewport()):
		return
	if not visible or _tab != "tinkering":
		return
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_TAB \
			and (e.ctrl_pressed or e.meta_pressed):
		if _tnk_pane != null and _tnk_pane.has_method("handle_key") and _tnk_pane.handle_key(e):
			get_viewport().set_input_as_handled()

func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed and not e.echo:
		if _tab == "skills" and _skills_pane != null and _skills_pane.has_method("handle_key") \
				and _skills_pane.handle_key(e):
			get_viewport().set_input_as_handled()
			return
		if _tab == "equipment" and _inv_pane != null and _inv_pane.has_method("handle_key") \
				and _inv_pane.handle_key(e):
			get_viewport().set_input_as_handled()
			return
		if _tab == "journal" and _jrn_pane != null and _jrn_pane.has_method("handle_key") \
				and _jrn_pane.handle_key(e):
			get_viewport().set_input_as_handled()
			return
		if _tab == "tinkering" and _tnk_pane != null and _tnk_pane.has_method("handle_key") \
				and _tnk_pane.handle_key(e):
			get_viewport().set_input_as_handled()
			return
		match e.keycode:
			KEY_7, KEY_KP_7:
				_step_tab(-1); get_viewport().set_input_as_handled()
			KEY_9, KEY_KP_9:
				_step_tab(1); get_viewport().set_input_as_handled()
			# swallow the remaining digits so ability hotkeys can't fire underneath
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_8, \
			KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_8:
				get_viewport().set_input_as_handled()

func _step_tab(dir: int) -> void:
	var idx := 0
	for i in TABS.size():
		if TABS[i]["id"] == _tab:
			idx = i
	_set_tab(TABS[wrapi(idx + dir, 0, TABS.size())]["id"])

# ── MESSAGE LOG pane ───────────────────────────────────────────────────────────

func _build_log_pane() -> void:
	_log_scroll = ScrollContainer.new()
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_log_scroll.position = Vector2(192, 196 - (BAR_Y + BAR_H))
	_log_scroll.size = Vector2(1568, 936 - 196)
	_pane_host.add_child(_log_scroll)
	_log_box = VBoxContainer.new()
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_box.add_theme_constant_override("separation", 0)
	_log_scroll.add_child(_log_box)

## MainFrame feeds every snapshot (registered in _panels): accumulate the RAW line
## history via msgCount deltas — the side panel's collapsed entries are no use here.
func set_snapshot(data: Dictionary) -> void:
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		var first := _palette.is_empty()
		_palette = pal   # same shape MessageLog/QudText already consume
		if first:
			# Every pane built BEFORE the first palette rendered its markup in the
			# fallback WHITE, and stayed that way (feedback 2026-08-10: "Skill list
			# items need color formatting to match Qud"). The state is easy to hit:
			# a Raves connected while Qud sits parked on one of its own status
			# screens receives NO snapshot at all — the turn thread that publishes
			# them is parked — so there is no palette anywhere until Qud returns to
			# play, and the 1.2s reload chain that would have healed the pane only
			# re-arms while its tab check keeps passing. Push the recovery from the
			# palette's own arrival instead: flag every pane stale and rebuild the
			# one on screen.
			_pane_pal_empty = true
			if visible:
				_set_tab(_tab)
	var pobj: Dictionary = data.get("player", {})
	if not pobj.is_empty():
		_last_player = pobj
	_tiles_dir = String(data.get("tilesDir", _tiles_dir))
	var lines: Array = data.get("messages", [])
	var total := int(data.get("msgCount", 0))
	if not _seeded:
		_seeded = true
		for l in lines:
			_all_lines.append(str(l))
		_msg_total = total
	elif total > _msg_total:
		var n := mini(total - _msg_total, lines.size())
		for i in range(lines.size() - n, lines.size()):
			_all_lines.append(str(lines[i]))
		_msg_total = total
	else:
		return
	if visible and _tab == "messagelog":
		_refresh_log()

func _refresh_log() -> void:
	for c in _log_box.get_children():
		c.queue_free()
	var shown: Array = []
	for l in _all_lines:
		if _filter == "" or str(l).to_lower().find(_filter) >= 0:
			shown.append(l)
	for i in shown.size():
		var rl := RichTextLabel.new()
		rl.bbcode_enabled = true
		rl.fit_content = true
		rl.scroll_active = false
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rl.add_theme_font_size_override("normal_font_size", 16)
		rl.add_theme_color_override("default_color", S_DIM_TEXT)
		rl.custom_minimum_size = Vector2(0, 20)
		rl.text = QudText.to_bbcode(str(shown[i]), _palette)
		_log_box.add_child(rl)
	# bottom-anchor like Qud: newest visible, gold > cursor beside the newest line
	await get_tree().process_frame
	if _log_scroll == null:
		return
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)
	if _cursor == null:
		_cursor = Label.new()
		_cursor.text = ">"
		_cursor.add_theme_color_override("font_color", S_GOLD)
		_cursor.add_theme_font_size_override("font_size", 16)
		_pane_host.add_child(_cursor)
	var content_h := minf(_log_box.size.y, _log_scroll.size.y)
	_cursor.position = Vector2(178, _log_scroll.position.y + content_h - 20.0)
	_cursor.visible = shown.size() > 0

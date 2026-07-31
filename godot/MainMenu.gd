extends Control

## THE MAIN MENU — a 1:1 MIMIC of Caves of Qud's modern main menu.
##
## A deliberate, faithful RECONSTRUCTION of Qud's own title screen, measured against a
## real 1793x997 capture of it (build 2.0.211.59):
##   • the extracted cave-art background + "CAVES OF QUD" logo (the player's OWN install
##     art, exported by the mod — never redistributed; see TitleExporter.cs);
##   • a single CENTERED, gilded framed box holding the primary options (New Game /
##     Continue / Records / Options / Mods), centre-aligned;
##   • a BOTTOM-LEFT list of the secondary options (Redeem Code / Modding Toolkit /
##     Credits / Help);
##   • a bottom-centre hotkey hint and a bottom-right version corner.
## Item text + ordering are verbatim from the decompiled Qud.UI.MainMenu (LeftOptions =
## the box, RightOptions = the bottom-left list; "left/right" there are NAV names, not
## screen columns). Positions/colours below are MEASURED off the reference capture.
##
## Pixel-faithful "when possible" — what's approximated: the box's gilded frame and the
## hieroglyph HEADER strip are bespoke Qud art (a hatched gold border + glyph ornament);
## until they're extracted from the install like the bg/logo, they're approximated here
## with a gold-bordered dark panel + a header strip. Qud's menu type is a SANS baked into
## TMP atlases (no loose font ships), so options render in the app's Atkinson sans.
##
## The user's own custom launcher menu (Launch / Enter-viewer detect button, attribution
## corner, ORG_NAME) is preserved in `MainMenu.custom.gd.bak` for LATER restore. To keep
## this mimic usable, two of Qud's items map to Raves actions — New Game LAUNCHES the
## installed Qud, Continue ENTERS the viewer (and, like Qud disabling Continue without a
## save, lights up only while the mod bridge answers) — the rest are cosmetic for now.

# ── palette (measured off the reference capture) ─────────────────────────────────
const BG := Color8(0x0C, 0x1A, 0x16)              # dark teal — clear-colour fallback
const PANEL := Color(0.059, 0.082, 0.082, 0.90)   # #0F1515 box interior, semi-transparent
const FRAME := Color8(0xB6, 0xA1, 0x63)           # gilded frame border (tan-gold)
const HEADER_BG := Color(0.10, 0.13, 0.08, 0.92)  # header strip behind the (future) glyphs
const SEL := Color8(0xF6, 0xF6, 0xF6)             # selected option — near-white
const MUTED := Color8(0x5C, 0x66, 0x63)          # unselected / disabled / secondary — grey-green
const HINT := Color8(0x8F, 0xA6, 0x9E)           # hotkey hint text
const GOLD := Color8(0xC8, 0xA9, 0x4E)           # keycap accents in the hint

# Quit-confirm prompt (1:1). Qud's is a COMPACT panel over the box top, not a big modal —
# measured off a 1920x1080 capture: near-black teal fill, thin muted-teal border, a muted
# green question, and "> Yes  No" with a gold caret on the selection.
const Q_DLG_FILL := Color(0.024, 0.145, 0.145, 1.0)   # ~ rgb(6,37,37), opaque (fully hides the menu under it)
const Q_DLG_BORDER := Color8(0x46, 0x64, 0x60)        # thin muted-teal frame line
const Q_DLG_TEXT := Color8(0x6E, 0x8A, 0x86)          # question text ~ rgb(110,138,134)
const Q_DLG_LINE := Color8(0x40, 0x6A, 0x73)          # button-row rule + framing ticks ~ rgb(64,106,115)
const Q_DLG_CELL := Color8(0x11, 0x2D, 0x2E)          # faint Yes/No cell fill ~ rgb(17,45,46)

## The box is built from Qud's OWN extracted frame sprites (title/chrome/, via the mod)
## composed as Qud composes them (Frame/Border): a tiled dark panel, gold woven side +
## bottom borders, and the gilded hieroglyph header on top. These fractions are each
## piece's thickness relative to the box, from the dump (borderTop 350x69, borderSide
## 18-wide, borderBot 339x18 on a 339x292 border). Absent sprites -> the styled fallback.
const HEADER_H_FRAC := 0.185   # borderTop height / box height
const SIDE_W_FRAC := 0.052     # borderSide width / box width
const BOT_H_FRAC := 0.052      # borderBot height / box height
## Qud's header (borderTop 350w) OVERHANGS the box body (339w) by ~1.6% each side — the gilded
## header + hieroglyph row are wider than the box, an eave. Applied to the header edge below.
const HEADER_OVERHANG := 0.016  # fraction of box width the header extends BEYOND each side (matches Qud)

## The box holds a FIXED aspect and scales with window HEIGHT (centered), like Qud's canvas
## scaler — so it reads the same shape at any window aspect instead of stretching. Width =
## height * BOX_ASPECT; position/height come from the "menu" layout rect. Measured off a 1920x1080
## Qud capture: box body is 334w x 354h -> aspect 0.943 (the old 0.99 rendered it ~20px too wide).
const BOX_ASPECT := 0.943

## Qud's real menu items, verbatim from Qud.UI.MainMenu. LeftOptions = the centred box;
## RightOptions = the bottom-left list. `act` maps an item to a Raves action for this
## mimic phase; "" = cosmetic (no-op for now).
const BOX_ITEMS := [
	{"text": "New Game", "act": "new"},
	{"text": "Continue", "act": "continue"},
	{"text": "Records", "act": "records"},
	{"text": "Options", "act": "options"},
	{"text": "Mods", "act": "mods"},
]
const LINK_ITEMS := ["Redeem Code", "Modding Toolkit", "Credits", "Help"]

## Fallback if the cache file is missing. Normalized [x,y,w,h] window fractions, MEASURED
## off the reference capture. Tunable at runtime via title_layout.json (no rebuild).
const DEFAULT_LAYOUT := {
	"logo": [0.213, 0.119, 0.56, 0.134],
	"menu": [0.408, 0.393, 0.184, 0.332],
	"links": [0.033, 0.785, 0.22, 0.14],
	"hint": [0.20, 0.953, 0.60, 0.028],
	"version": [0.80, 0.892, 0.185, 0.052],
}

var _layout: Dictionary
var _hl: Texture2D             # buttonHighlight sprite behind the selected option (if extracted)
var _box: Control             # the centred option box (re-placed on resize to hold its aspect)
var _overlay: Control         # active sub-screen (Mods, …) over the menu, or null
var _rows: Array = []          # box options only: [{btn,cfg,enabled}]
var _sel := 0
var _peer := StreamPeerTCP.new()
var _retry := 0.0
var _qud_up := false
var _launching := false
var _game_live := false        # a snapshot has arrived = a game is actually live (not just a socket open)
var _continue_hint: Label      # "load a game in Qud" note, shown when Qud is up but no game is live
var _bg_rect: TextureRect      # the title background (nudgeable live via title_bg.json)
var _bg_nudge := {"dx": 0.0, "dy": 0.0, "scale": 1.0}   # live pan/zoom over the base cover
var _bg_nudge_mtime := -1.0
var _bg_poll_t := 0.0
var _quit_dialog: Control      # the "Are you sure you want to quit?" modal, or null
var _quit_sel := 0             # 0 = Yes, 1 = No
var _quit_opts: Array = []     # [{lbl, act}] for the dialog

func _ready() -> void:
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())
	if Settings.one_to_one():
		# 1:1: Qud's title labels sit on NO background — clear the Label panel (base + role
		# variations) so the bottom-left list (Redeem Code … Help) and the version render as
		# plain text like Qud. User mode keeps Raves' framed look.
		var empty := StyleBoxEmpty.new()
		for tt in ["Label", "Caption", "Title", "Big"]:
			theme.set_stylebox("normal", tt, empty)
	get_viewport().size_changed.connect(_on_resize)
	get_window().title = Brand.title()
	RenderingServer.set_default_clear_color(BG)

	_layout = _load_layout()
	_hl = _chrome("buttonHighlight.png")
	_build_background()   # Qud's title cave-art from the install (if the mod exported it)
	_build_logo()         # Qud's "CAVES OF QUD" wordmark (extracted), else a text fallback
	_build_menu()         # the centred, gilded option box
	_build_continue_hint()  # "load a game in Qud" note under the box (hidden until relevant)
	_build_links()        # the bottom-left secondary list
	_build_hint()
	_build_version()
	_build_quit_button()   # Qud's upper-left "X" → quit confirmation

	_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())  # start detecting Qud
	_refresh_enabled()

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())
	if _box != null:
		_place_box(_box)   # keep the box's aspect across any window shape
	_apply_bg_nudge()      # the pan/zoom is window-relative, so re-apply on resize

# ── layout cache ──────────────────────────────────────────────────────────────

func _load_layout() -> Dictionary:
	var out: Dictionary = DEFAULT_LAYOUT.duplicate(true)
	var path := InputModel.support_dir().path_join("title_layout.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.has("elements") and data["elements"] is Dictionary:
				for k in data["elements"]:
					out[k] = data["elements"][k]
	return out

func _place(c: Control, key: String) -> void:
	var r: Array = _layout.get(key, DEFAULT_LAYOUT.get(key, [0, 0, 1, 1]))
	c.anchor_left = r[0]
	c.anchor_top = r[1]
	c.anchor_right = r[0] + r[2]
	c.anchor_bottom = r[1] + r[3]
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0

# ── extracted art ───────────────────────────────────────────────────────────────

## Qud's title BACKGROUND (cave art) exported by the mod, rendered from the player's own
## install (never bundled). Behind everything. Absent until the mod has run in-game once.
func _build_background() -> void:
	var tex := _load_title_png("background.png")
	if tex == null:
		return
	var rect := TextureRect.new()
	rect.texture = tex
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	# EXPAND_IGNORE_SIZE so the rect isn't forced to the texture's NATIVE size — _apply_bg_nudge
	# sizes it to the base COVER × (sx, sy) and STRETCH_SCALE fills it, so independent x/y scaling
	# genuinely stretches the art to match Qud. (Without IGNORE_SIZE the TextureRect took the
	# 2048x1897 native size and ignored its rect — the same gotcha the option-box frame hit.)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	move_child(rect, 0)   # first child = behind everything
	_bg_rect = rect
	_load_bg_nudge(true)   # apply any saved pan/zoom (from the cockpit nudge tool)

# ── background nudge (live pan/zoom, tuned from the highvisor cockpit) ─────────────
# The base cover fills the window; `scale` zooms IN from there (>=1, so it stays covered)
# and dx/dy pan. Values live in title_bg.json in the support dir — the cockpit's nudge tool
# writes it and MainMenu polls it, so tweaks apply with NO rebuild. Once dialed in, bake the
# final numbers into the `_bg_nudge` default above so they persist without the runtime file.
func _bg_nudge_path() -> String:
	return InputModel.support_dir().path_join("title_bg.json")

func _apply_bg_nudge() -> void:
	if _bg_rect == null or _bg_rect.texture == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var ts := _bg_rect.texture.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0:
		return
	# Base = COVER (art fills the window, aspect preserved). sx/sy scale each axis INDEPENDENTLY
	# from there: >1 stretches/zooms that axis, <1 shrinks it and shows a clear-colour border on
	# that axis; dx/dy pan. Backward-compat: a lone "scale" applies to both axes. The rect is sized
	# to cover×(sx,sy) and STRETCH_SCALE fills it, so a non-square rect genuinely stretches the art.
	var cover: float = maxf(vp.x / ts.x, vp.y / ts.y)
	var uni: float = float(_bg_nudge.get("scale", 1.0))
	var sx: float = maxf(0.05, float(_bg_nudge.get("sx", uni)))
	var sy: float = maxf(0.05, float(_bg_nudge.get("sy", uni)))
	var dx: float = float(_bg_nudge.get("dx", 0.0))
	var dy: float = float(_bg_nudge.get("dy", 0.0))
	var rw: float = ts.x * cover * sx
	var rh: float = ts.y * cover * sy
	_bg_rect.anchor_left = 0.5; _bg_rect.anchor_right = 0.5
	_bg_rect.anchor_top = 0.5; _bg_rect.anchor_bottom = 0.5
	_bg_rect.offset_left = -rw * 0.5 + dx
	_bg_rect.offset_right = rw * 0.5 + dx
	_bg_rect.offset_top = -rh * 0.5 + dy
	_bg_rect.offset_bottom = rh * 0.5 + dy

func _load_bg_nudge(force := false) -> void:
	var p := _bg_nudge_path()
	if not FileAccess.file_exists(p):
		if force:
			_apply_bg_nudge()   # seed dir empty → identity cover
		return
	var m := float(FileAccess.get_modified_time(p))
	if not force and m == _bg_nudge_mtime:
		return
	_bg_nudge_mtime = m
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		_bg_nudge = d
	_apply_bg_nudge()

func _build_logo() -> void:
	var tex := _load_title_png("logo.png")
	if tex != null:
		var r := TextureRect.new()
		r.texture = tex
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(r)
		_place(r, "logo")
		return
	# fallback: wordmark as text (mod hasn't exported logo.png yet)
	var l := _label("CAVES OF QUD", SEL, "big")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(l)
	_place(l, "logo")

func _load_title_png(file: String) -> Texture2D:
	var path := InputModel.support_dir().path_join("title").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != 0:   # 0 == OK
		return null
	return ImageTexture.create_from_image(img)

# ── the centred option box ───────────────────────────────────────────────────────

func _build_menu() -> void:
	var box := Control.new()
	box.name = "MenuBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not _build_chrome_frame(box):
		_build_approx_frame(box)   # no extracted sprites yet — styled fallback

	# The options, inset within the frame (below the header, between the side borders), CENTER-
	# aligned so the block sits at the rect's vertical midpoint. Pitch is tuned to Qud: measured off
	# a 1920x1080 capture, Qud's rows sit ~46px apart (Raves was ~50px with separation 6 — a block
	# ~20px too tall). separation 2 -> ~46px pitch. The rect midpoint is biased ~0.006 above the box
	# centre-of-body so the block lands on Qud's block-centre (~0.566 of the box), not the geometric
	# middle (the header eats the top, so Qud centres the items a touch low).
	var opts := VBoxContainer.new()
	opts.alignment = BoxContainer.ALIGNMENT_CENTER
	opts.add_theme_constant_override("separation", 2)
	opts.anchor_left = 0.09
	opts.anchor_right = 0.91
	opts.anchor_top = HEADER_H_FRAC + 0.0345
	opts.anchor_bottom = 1.0 - (BOT_H_FRAC + 0.0355)
	for k in ["left", "top", "right", "bottom"]:
		opts.set("offset_" + k, 0.0)
	for cfg in BOX_ITEMS:
		var b := _option_button(cfg)
		opts.add_child(b)
		_rows.append({"btn": b, "cfg": cfg, "enabled": true})
	box.add_child(opts)

	_box = box
	add_child(box)
	_place_box(box)

## Place the box centred on the "menu" rect's centre, sized by window HEIGHT at a fixed
## aspect (Qud's canvas-scaler behaviour) so it never stretches. Re-run on resize.
func _place_box(c: Control) -> void:
	var r: Array = _layout.get("menu", DEFAULT_LAYOUT["menu"])
	var vh := get_viewport().get_visible_rect().size.y
	var cx: float = r[0] + r[2] * 0.5
	var cy: float = r[1] + r[3] * 0.5
	var bh: float = r[3] * vh
	var bw: float = bh * BOX_ASPECT
	c.anchor_left = cx
	c.anchor_right = cx
	c.anchor_top = cy
	c.anchor_bottom = cy
	c.offset_left = -bw * 0.5
	c.offset_right = bw * 0.5
	c.offset_top = -bh * 0.5
	c.offset_bottom = bh * 0.5

## A small note just under the option box, shown only when Qud is up but no game is live (see
## _update_continue_hint). Pure fractional anchors, so it tracks the box across window resizes.
func _build_continue_hint() -> void:
	if Settings.one_to_one():
		return   # Qud shows no such hint — it just greys Continue (mirrored via _refresh_enabled)
	_continue_hint = _label("Load a game in Caves of Qud to continue", MUTED, "caption")
	_continue_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_continue_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_continue_hint.visible = false
	add_child(_continue_hint)
	var r: Array = _layout.get("menu", DEFAULT_LAYOUT["menu"])
	var below: float = r[1] + r[3] + 0.012   # just under the box bottom
	_continue_hint.anchor_left = 0.14
	_continue_hint.anchor_right = 0.86
	_continue_hint.anchor_top = below
	_continue_hint.anchor_bottom = below + 0.06
	for k in ["left", "top", "right", "bottom"]:
		_continue_hint.set("offset_" + k, 0.0)

## Reconstruct Qud's box from its OWN extracted frame sprites (title/chrome/), composed
## the way Qud composes Frame/Border: tiled dark panel, woven gold side + bottom borders,
## and the gilded hieroglyph header on top. Returns false if the sprites aren't present.
func _build_chrome_frame(box: Control) -> bool:
	var top := _chrome("borderTop.png")
	if top == null:
		return false
	var bg := _chrome("panelBgTile.png")
	if bg != null:   # dark weave panel — spans the FULL box, UNDER every border, native-scale tiled.
		# Qud runs the weave under the frame: the border sprites carry a transparent INNER margin
		# (borderSide is 23px wide but only its outer ~18px are opaque), so if the panel stopped at
		# the border band the cave-art background showed through that margin as a see-through seam.
		# A full-box opaque weave underlaps the borders, so their inner margins reveal weave, not bg.
		var r := _edge(bg, TextureRect.STRETCH_TILE, 0.0, 0.0, 1.0, 1.0)
		box.add_child(r)
	var side := _chrome("borderSide.png")
	if side != null:   # left + right woven borders (right mirrored)
		box.add_child(_edge(side, TextureRect.STRETCH_SCALE, 0.0, HEADER_H_FRAC * 0.6,
			SIDE_W_FRAC, 1.0 - BOT_H_FRAC * 0.4))
		var rt := _edge(side, TextureRect.STRETCH_SCALE, 1.0 - SIDE_W_FRAC, HEADER_H_FRAC * 0.6,
			1.0, 1.0 - BOT_H_FRAC * 0.4)
		rt.flip_h = true
		box.add_child(rt)
	var bot := _chrome("borderBot.png")
	if bot != null:   # bottom woven border
		box.add_child(_edge(bot, TextureRect.STRETCH_SCALE, 0.0, 1.0 - BOT_H_FRAC, 1.0, 1.0))
	# the gilded hieroglyph header last, on top (its ends carry the top corners). It OVERHANGS the
	# box body left+right (an eave), like Qud's wider borderTop.
	box.add_child(_edge(top, TextureRect.STRETCH_SCALE, -HEADER_OVERHANG, 0.0, 1.0 + HEADER_OVERHANG, HEADER_H_FRAC))
	return true

## A TextureRect anchored to a fractional sub-rect of its parent (the box), mouse-transparent.
func _edge(tex: Texture2D, mode: int, al: float, at: float, ar: float, ab: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.stretch_mode = mode
	# CRITICAL: without this a TextureRect sizes itself to the TEXTURE's native size and ignores
	# its anchors — the tall borderSide (23x431) then hung 100+px BELOW the box as "legs", the dark
	# panel tile fell short, and the header rendered at native width. IGNORE_SIZE makes it fill the
	# anchored sub-rect (so stretch_mode actually applies).
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.anchor_left = al
	r.anchor_top = at
	r.anchor_right = ar
	r.anchor_bottom = ab
	for k in ["left", "top", "right", "bottom"]:
		r.set("offset_" + k, 0.0)
	return r

## Styled fallback when Qud's frame sprites haven't been extracted yet: a gold-bordered
## dark panel with a header strip — the previous approximation.
func _build_approx_frame(box: Control) -> void:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(3)
	sb.border_color = FRAME
	sb.set_corner_radius_all(1)
	panel.add_theme_stylebox_override("panel", sb)
	box.add_child(panel)
	var header := Panel.new()
	header.anchor_left = 0.0; header.anchor_right = 1.0
	header.anchor_top = 0.0; header.anchor_bottom = HEADER_H_FRAC
	for k in ["left", "top", "right", "bottom"]:
		header.set("offset_" + k, 0.0)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = HEADER_BG
	hsb.border_width_bottom = 2
	hsb.border_color = FRAME
	header.add_theme_stylebox_override("panel", hsb)
	box.add_child(header)

func _chrome(file: String) -> Texture2D:
	return _load_title_png("chrome".path_join(file))

## One box option: focus-less, centre-aligned, transparent chrome. Selected = white,
## everything else = muted grey-green (Qud shows the selection by brightness, no bar).
func _option_button(cfg: Dictionary) -> Button:
	var b := Button.new()
	b.text = cfg.get("text", "")
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.theme_type_variation = "Big"
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, _transparent())
	var idx := _rows.size()
	b.mouse_entered.connect(func(): _select(idx))
	b.pressed.connect(func(): _activate(idx))
	return b

func _transparent() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

## The selected option's background: Qud's extracted buttonHighlight sprite if we have it,
## else a faint flat bar. Kept subtle — selection reads mostly through the white text.
func _highlight_box() -> StyleBox:
	if _hl != null:
		var st := StyleBoxTexture.new()
		st.texture = _hl
		st.modulate_color = Color(1, 1, 1, 0.62)   # soften — Qud's highlight is subtle
		st.content_margin_top = 2
		st.content_margin_bottom = 2
		return st
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.90, 0.86, 0.72, 0.10)
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

# ── the bottom-left secondary list ───────────────────────────────────────────────

func _build_links() -> void:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 6)
	for txt in LINK_ITEMS:
		var l := _label(txt, MUTED, "title")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		v.add_child(l)
	add_child(v)
	_place(v, "links")

# ── selection / enabled state ─────────────────────────────────────────────────────

func _select(idx: int) -> void:
	if idx == _sel or idx < 0 or idx >= _rows.size():
		return
	_sel = idx
	_apply_selection()

func _step(dir: int) -> void:
	var n := _rows.size()
	if n == 0:
		return
	var i := _sel
	for _k in range(n):
		i = (i + dir + n) % n
		if _rows[i]["enabled"]:
			_select(i)
			return

func _apply_selection() -> void:
	for i in range(_rows.size()):
		var b: Button = _rows[i]["btn"]
		var on: bool = (i == _sel) and _rows[i]["enabled"]
		var col: Color = SEL if on else MUTED
		for role in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
			b.add_theme_color_override(role, col)
		# Qud shows selection with its buttonHighlight sprite behind the option (if extracted)
		b.add_theme_stylebox_override("normal", _highlight_box() if on else _transparent())

## Qud disables Continue until there's a save; we mirror that against the live bridge —
## Continue lights up (becomes selectable) only while a modded Qud is running.
func _refresh_enabled() -> void:
	for row in _rows:
		var act: String = row["cfg"].get("act", "")
		var enabled := true
		if act == "continue":
			enabled = _game_live   # a LIVE game, not merely an open bridge socket
		row["enabled"] = enabled
		row["btn"].disabled = not enabled
	if _sel < _rows.size() and not _rows[_sel]["enabled"]:
		_step(1)
	_apply_selection()
	_update_continue_hint()

## Show "load a game in Qud" only when the bridge is up but no game is live — otherwise a greyed
## Continue looks broken. Hidden when Qud's down (nothing to say) or a game IS live (Continue works).
func _update_continue_hint() -> void:
	if _continue_hint != null:
		_continue_hint.visible = _qud_up and not _game_live

# ── hint bar + version corner ─────────────────────────────────────────────────────

func _build_hint() -> void:
	# Qud's hint: "navigate  [Space] select  [Esc] quit". Keycaps in gold via bbcode.
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gold := "#%s" % GOLD.to_html(false)
	var dim := "#%s" % HINT.to_html(false)
	var tail := "[color=%s] navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color]" % [dim, gold, dim, gold, dim]
	if Settings.one_to_one():
		# Qud shows an ARROW-KEYS icon (a gold d-pad cluster), not the literal "↑↓". Draw it and
		# inline it at the head of the centred hint.
		var ih := int(round(UiFont.px(get_viewport(), "caption") * 1.15))
		var icon := _nav_icon_texture(ih, GOLD)
		l.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
		l.add_image(icon, icon.get_width(), icon.get_height())
		l.append_text(tail)
		l.pop()
	else:
		l.text = "[center][color=%s]↑↓ navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color][/center]" % [dim, gold, dim, gold, dim]
	add_child(l)
	_place(l, "hint")

## A small arrow-keys icon (Qud's gold d-pad cluster) drawn procedurally: four keys in the
## inverted-T layout — up on top; left / down / right below — used in the 1:1 hint in place of "↑↓".
func _nav_icon_texture(ih: int, color: Color) -> ImageTexture:
	var g := maxi(1, int(round(ih * 0.10)))
	var k := int((ih - g) / 2)          # key size (two rows tall)
	if k < 2:
		k = 2
	var w := 3 * k + 2 * g
	var h := 2 * k + g
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := k + g                     # x of the centre column
	img.fill_rect(Rect2i(mid, 0, k, k), color)          # up (top centre)
	img.fill_rect(Rect2i(0, k + g, k, k), color)        # left
	img.fill_rect(Rect2i(mid, k + g, k, k), color)      # down (centre)
	img.fill_rect(Rect2i(2 * mid, k + g, k, k), color)  # right
	return ImageTexture.create_from_image(img)

func _build_version() -> void:
	if Settings.one_to_one():
		_build_version_qud()
		return
	var l := _label("%s\nbuild %s" % [Brand.GAME_NAME, Brand.LICENSE], MUTED, "caption")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(l)
	_place(l, "version")

## 1:1: Qud's own version corner — its release + build, right-aligned, in a READABLE colour.
## Qud draws the build line very dark (illegible); we lift it. A RichTextLabel so the two lines
## can differ in brightness AND so it carries none of the Label background panel.
func _build_version_qud() -> void:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.theme_type_variation = "Caption"
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ver := "#%s" % SEL.to_html(false)     # release: near-white, like Qud
	var bld := "#%s" % HINT.to_html(false)    # build: readable teal-grey (Qud's is too dark)
	l.text = "[right][color=%s]%s[/color]\n[color=%s]build %s[/color][/right]" % [
		ver, Brand.QUD_VERSION, bld, Brand.QUD_BUILD]
	add_child(l)
	_place(l, "version")

# ── quit button + confirmation ─────────────────────────────────────────────────────

## Qud's upper-left "X" — its Cancel sprite at ~50% alpha (brightens on hover); click (or Esc)
## opens the "Are you sure you want to quit?" confirmation. Positioned in the top-left corner.
func _build_quit_button() -> void:
	var hit := Control.new()
	hit.name = "QuitX"
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.position = Vector2(22, 22)
	hit.custom_minimum_size = Vector2(56, 56)
	hit.size = Vector2(56, 56)
	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.modulate = Color(1, 1, 1, 0.5)   # Qud draws it at 50% alpha
	var tex := _chrome("Cancel.png")
	if tex != null:
		icon.texture = tex
	else:
		var l := _label("✕", SEL, "title")   # fallback glyph if the sprite isn't extracted
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hit.add_child(l)
	hit.add_child(icon)
	hit.mouse_entered.connect(func(): icon.modulate = Color(1, 1, 1, 1.0))
	hit.mouse_exited.connect(func(): icon.modulate = Color(1, 1, 1, 0.5))
	hit.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_confirm_quit())
	add_child(hit)

func _confirm_quit() -> void:
	if _quit_dialog != null:
		return
	_quit_sel = 0
	_quit_opts = []
	if Settings.one_to_one():
		_confirm_quit_1to1()   # Qud's compact over-the-box prompt
		return
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()   # darken the menu behind the modal
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)
	# centred gold-bordered panel with the question + Yes / No
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _dialog_style())
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	var q := _label("Are you sure you want to quit?", SEL, "title")
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(q)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 40)
	for cfg in [{"lbl": "Yes", "act": "yes"}, {"lbl": "No", "act": "no"}]:
		var opt := _label(cfg["lbl"], MUTED, "big")
		var idx := _quit_opts.size()
		opt.mouse_filter = Control.MOUSE_FILTER_STOP
		opt.mouse_entered.connect(func(): _quit_select(idx))
		opt.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_quit_select(idx); _quit_activate())
		row.add_child(opt)
		_quit_opts.append({"lbl": opt, "act": cfg["act"]})
	v.add_child(row)
	panel.add_child(v)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.pivot_offset = Vector2.ZERO
	layer.add_child(panel)
	# centre the panel (deferred so its min size is known)
	panel.call_deferred("set_anchors_preset", Control.PRESET_CENTER)
	_quit_dialog = layer
	add_child(layer)
	_apply_quit_sel()

## Qud's 1:1 quit prompt: a COMPACT panel overlaying the top of the option box (under the
## header, over where New Game/Continue sit), NOT a big centred modal. Muted question, a thin
## divider, then "> Yes   No" with a gold caret on the selection. Positioned on the box's rect
## so it tracks the box. Keyboard (arrows / Space / Esc) is handled in _unhandled_input.
func _confirm_quit_1to1() -> void:
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP   # modal: clicks outside the panel do nothing
	var br: Rect2 = _box.get_rect() if _box != null else get_viewport().get_visible_rect()
	# the panel: box-interior width, ~1/5 the box tall, just below the header
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Q_DLG_FILL
	sb.set_border_width_all(1)
	sb.border_color = Q_DLG_BORDER
	sb.set_corner_radius_all(0)
	panel.add_theme_stylebox_override("panel", sb)
	var pw: float = br.size.x * 0.98
	var ph: float = br.size.y * 0.20
	panel.position = Vector2(br.position.x + (br.size.x - pw) * 0.5,
		br.position.y + br.size.y * HEADER_H_FRAC)
	panel.size = Vector2(pw, ph)
	layer.add_child(panel)
	# Qud's dialog font is smaller than the menu items and its narrow font fits the question on one
	# line; Raves' Atkinson is wider, so size the text off the box height to fit one line with margins.
	var fs: int = int(round(br.size.y * 0.043))
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 5)
	v.offset_left = 7; v.offset_right = -7; v.offset_top = 5; v.offset_bottom = -5
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var q := _label("Are you sure you want to quit?", Q_DLG_TEXT, "caption")
	q.add_theme_font_size_override("font_size", fs)
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	q.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(q)
	# Button row (Qud's style): a horizontal rule that STOPS at vertical ticks framing the Yes/No
	# group, each option sitting in a faint cell. Expanding rule segments on both sides auto-centre
	# the group; the caret keeps its slot in BOTH cells (transparent when unselected) so nothing
	# shifts as the selection moves.
	var lt: int = maxi(1, int(round(br.size.y * 0.004)))    # rule / tick thickness
	var tick_h: int = maxi(6, int(round(br.size.y * 0.04)))  # framing-tick height
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_dlg_rule(lt))            # left rule (expands)
	row.add_child(_dlg_tick(lt, tick_h))    # left framing tick
	var cfgs := [{"lbl": "Yes", "act": "yes"}, {"lbl": "No", "act": "no"}]
	for i in range(cfgs.size()):
		if i > 0:
			var gap := Control.new()   # small gap between the Yes and No cells
			gap.custom_minimum_size = Vector2(6, 0)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(gap)
		var cell := PanelContainer.new()   # faint cell holding [gold caret] + [label]
		var csb := StyleBoxFlat.new()
		csb.bg_color = Q_DLG_CELL
		csb.content_margin_left = 8; csb.content_margin_right = 8
		csb.content_margin_top = 2; csb.content_margin_bottom = 2
		cell.add_theme_stylebox_override("panel", csb)
		cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cell.mouse_filter = Control.MOUSE_FILTER_STOP
		var inner := HBoxContainer.new()
		inner.add_theme_constant_override("separation", 4)
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var caret := _label(">", GOLD, "caption")   # holds its slot always; coloured in _apply_quit_sel
		caret.add_theme_font_size_override("font_size", fs)
		caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var opt := _label(cfgs[i]["lbl"], MUTED, "caption")
		opt.add_theme_font_size_override("font_size", fs)
		opt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(caret); inner.add_child(opt)
		cell.add_child(inner)
		var idx := _quit_opts.size()
		cell.mouse_entered.connect(func(): _quit_select(idx))
		cell.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_quit_select(idx); _quit_activate())
		row.add_child(cell)
		_quit_opts.append({"lbl": opt, "caret": caret, "act": cfgs[i]["act"]})
	row.add_child(_dlg_tick(lt, tick_h))    # right framing tick
	row.add_child(_dlg_rule(lt))            # right rule (expands)
	v.add_child(row)
	panel.add_child(v)
	_quit_dialog = layer
	add_child(layer)
	_apply_quit_sel()

## A horizontal rule segment for the quit dialog's button row (expands to fill its side).
func _dlg_rule(thick: int) -> ColorRect:
	var r := ColorRect.new()
	r.color = Q_DLG_LINE
	r.custom_minimum_size = Vector2(0, thick)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

## A short vertical framing tick that bookends the Yes/No group (the rule stops at these).
func _dlg_tick(thick: int, h: int) -> ColorRect:
	var t := ColorRect.new()
	t.color = Q_DLG_LINE
	t.custom_minimum_size = Vector2(thick, h)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t

func _dialog_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_border_width_all(3)
	sb.border_color = FRAME
	sb.set_corner_radius_all(1)
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 28
	sb.content_margin_bottom = 28
	return sb

func _quit_select(i: int) -> void:
	if _quit_opts.is_empty():
		return
	_quit_sel = clampi(i, 0, _quit_opts.size() - 1)
	_apply_quit_sel()

func _apply_quit_sel() -> void:
	for i in range(_quit_opts.size()):
		var on: bool = (i == _quit_sel)
		var lbl: Label = _quit_opts[i]["lbl"]
		lbl.add_theme_color_override("font_color", SEL if on else MUTED)
		if _quit_opts[i].has("caret"):   # 1:1: gold caret on the selection; transparent (keeps slot) otherwise
			_quit_opts[i]["caret"].add_theme_color_override("font_color", GOLD if on else Color(0, 0, 0, 0))

func _quit_activate() -> void:
	if _quit_sel < _quit_opts.size() and _quit_opts[_quit_sel]["act"] == "yes":
		get_tree().quit()
	else:
		_close_quit()

func _close_quit() -> void:
	if _quit_dialog != null:
		_quit_dialog.queue_free()
		_quit_dialog = null
		_quit_opts = []

# ── input ─────────────────────────────────────────────────────────────────────────

func _unhandled_input(e: InputEvent) -> void:
	if _quit_dialog != null:
		if e.is_action_pressed("ui_left") or e.is_action_pressed("ui_up"):
			_quit_select(0); accept_event()
		elif e.is_action_pressed("ui_right") or e.is_action_pressed("ui_down"):
			_quit_select(1); accept_event()
		elif e.is_action_pressed("ui_accept"):
			_quit_activate(); accept_event()
		elif e.is_action_pressed("ui_cancel"):
			_close_quit(); accept_event()   # Esc in the dialog = No
		return
	if _overlay != null:
		return   # a sub-screen (Mods, …) owns input while it's open
	if e.is_action_pressed("ui_down"):
		_step(1); accept_event()
	elif e.is_action_pressed("ui_up"):
		_step(-1); accept_event()
	elif e.is_action_pressed("ui_accept"):
		_activate(_sel); accept_event()
	elif e.is_action_pressed("ui_cancel"):
		_confirm_quit(); accept_event()   # Esc → confirm, like Qud (was an immediate quit)

func _activate(idx: int) -> void:
	if idx < 0 or idx >= _rows.size():
		return
	var row: Dictionary = _rows[idx]
	if not row["enabled"]:
		return
	match String(row["cfg"].get("act", "")):
		"continue":
			_enter_viewer()
		"new":
			if not _qud_up and not _launching:
				_launching = true
				OS.shell_open(Brand.URL_STEAM_RUN)   # launch the installed copy
			elif _qud_up:
				_open_chargen()   # chargen flow — WIP: genotype → subtype (drives Qud on Embark later)
		"mods":
			_open_overlay("res://ModsScreen.gd")
		"options":
			_open_overlay("res://OptionsScreen.gd")
		"records":
			_open_overlay("res://RecordsScreen.gd")
		_:
			pass  # cosmetic Qud item — no-op during the mimic phase

## Menu sub-screens (Mods, later Options/Records) open as a full-screen overlay over the
## menu; their `closed` signal tears them down and hands input back to the menu.
func _open_overlay(script_path: String) -> void:
	if _overlay != null:
		return
	var scr: Variant = load(script_path)
	if scr == null:
		return
	_overlay = scr.new()
	add_child(_overlay)
	if _overlay.has_signal("closed"):
		_overlay.closed.connect(_close_overlay)

func _close_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null

# ── chargen flow (WIP) ────────────────────────────────────────────────────────────
# The interactive character creator as a chain of stage screens: Genotype → Subtype → …
# Each screen emits `chose(x)`; we record the pick and open the next stage. Embark (driving
# Qud's builder) comes once the stages are in. State lives here for now.
var _cg_mode := ""
var _cg_genotype := ""
var _cg_subtype := ""

## Qud's chargen opens on the GAME MODE step (Tutorial/Classic/Roleplay/Wander/Daily) before
## genotype; mirror that order — mode → genotype → subtype → embark.
func _open_chargen() -> void:
	if _overlay != null:
		return
	_cg_mode = ""
	_cg_genotype = ""
	_cg_subtype = ""
	var mode: Variant = load("res://GameModeScreen.gd").new()
	_overlay = mode
	add_child(mode)
	mode.closed.connect(_close_overlay)
	mode.chose.connect(_on_mode_chosen)

func _on_mode_chosen(mode_name: String) -> void:
	_cg_mode = mode_name
	_close_overlay()
	var geno: Variant = load("res://GenotypeScreen.gd").new()
	_overlay = geno
	add_child(geno)
	geno.closed.connect(_close_overlay)
	geno.chose.connect(_on_genotype_chosen)

func _on_genotype_chosen(genotype_name: String) -> void:
	_cg_genotype = genotype_name
	var cls := _genotype_subtype_class(genotype_name)   # "Castes" / "Callings"
	_close_overlay()
	var sub: Variant = load("res://SubtypeScreen.gd").new()
	sub.subtype_class = cls
	sub.genotype_name = genotype_name
	_overlay = sub
	add_child(sub)
	sub.closed.connect(_close_overlay)
	sub.chose.connect(_on_subtype_chosen)

func _on_subtype_chosen(subtype_name: String) -> void:
	_cg_subtype = subtype_name
	_close_overlay()
	# Vertical slice: genotype + subtype is enough to embark. (Attributes / Mutations /
	# Cybernetics / Summary stages will slot in BEFORE this step as they're built.)
	_embark()

## Send the assembled build to the mod, which skips Qud's chargen and boots straight into a
## running game (see mod/EmbarkDriver.cs), then switch Raves to the Holodeck to watch it.
func _embark() -> void:
	if _cg_genotype == "" or _cg_subtype == "":
		return
	if not _qud_up or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_warning("Raves: can't embark — bridge not connected")
		return
	_send_embark(_cg_genotype, _cg_subtype)
	_enter_viewer()   # data-first, same as Continue: MainFrame auto-connects once the game is live

func _send_embark(genotype: String, subtype: String) -> void:
	var msg := {"type": "command", "name": "embark", "genotype": genotype, "subtype": subtype}
	if _cg_mode != "":
		msg["mode"] = _cg_mode   # game mode (Classic/Roleplay/…); the driver may ignore it for now
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)

## The subtype family a genotype uses ("Castes"/"Callings"), from chargen.json's genotype entry.
func _genotype_subtype_class(genotype_name: String) -> String:
	var path := InputModel.support_dir().path_join("chargen.json")
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.get("genotypes", null) is Array:
		for g in data["genotypes"]:
			if g is Dictionary and str(g.get("name", "")) == genotype_name:
				return str(g.get("subtypes", ""))
	return ""

func _enter_viewer() -> void:
	if not _qud_up:
		return
	if _peer != null:
		_peer.disconnect_from_host()          # free the probe; MainFrame owns the bridge next
	# Resume: entering with the bridge up means "watch the running game", so tell MainFrame to
	# AUTO-CONNECT its data stage on load (stats/panels/minimap fill immediately) instead of
	# stranding the player at the empty "▶ Connect (data)" prompt. The 3D viewport stays a manual
	# opt-in ("▶ Turn on viewport") — its build has crash history, so we don't auto-fire it. The
	# SceneTree persists across change_scene, so a meta flag hands the intent to MainFrame._ready.
	get_tree().set_meta("holo_auto_connect", true)
	get_tree().change_scene_to_file("res://MainFrame.tscn")

# ── detect Qud (mod bridge) — drives Continue's enabled state ─────────────────────

func _process(dt: float) -> void:
	# poll the live bg-nudge file (~3x/sec) so the cockpit tool's tweaks apply without a rebuild
	_bg_poll_t += dt
	if _bg_poll_t >= 0.3:
		_bg_poll_t = 0.0
		_load_bg_nudge()
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_set_qud_up(true)
			# DRAIN + detect. The mod force-publishes a snapshot the instant we connect, but ONLY if
			# a game is actually live — so ANY bytes here mean "a game is running" (the mod sends
			# nothing else to a client). That's how we tell a live game apart from a bare socket open
			# at Qud's own main menu. We discard the bytes (detection only) but must read them, else
			# our receive buffer fills and the mod's writer to us stalls.
			var avail := _peer.get_available_bytes()
			if avail > 0:
				_peer.get_data(avail)
				_set_game_live(true)
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_set_qud_up(false)
			_set_game_live(false)   # socket dropped → re-detect on the next connect (mod republishes)
			_retry += dt
			if _retry >= 1.0:   # retry ~1/s until Qud is up
				_retry = 0.0
				_peer = StreamPeerTCP.new()
				_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		_:
			pass  # STATUS_CONNECTING

func _set_qud_up(up: bool) -> void:
	if up == _qud_up:
		return
	_qud_up = up
	if up:
		_launching = false
	_refresh_enabled()

func _set_game_live(live: bool) -> void:
	if live == _game_live:
		return
	_game_live = live
	_refresh_enabled()

# ── UI helpers ──────────────────────────────────────────────────────────────────

func _label(txt: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()   # "Big" / "Title" / "Caption"
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	return l

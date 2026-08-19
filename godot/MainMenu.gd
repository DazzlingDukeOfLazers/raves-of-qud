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
var SEL := QudChrome.q8(0xF6, 0xF6, 0xF6)         # selected option — near-white (gamma-comp)
var MUTED := QudChrome.q8(0x5C, 0x66, 0x63)      # unselected / disabled / secondary — grey-green
var HINT := QudChrome.q8(0x8F, 0xA6, 0x9E)       # hotkey hint text
var GOLD := QudChrome.q8(0xC8, 0xA9, 0x4E)       # keycap accents in the hint

# Quit-confirm prompt (1:1). Qud's is a COMPACT panel over the box top, not a big modal —
# measured off a 1920x1080 capture: near-black teal fill, thin muted-teal border, a muted
# green question, and "> Yes  No" with a gold caret on the selection.
var Q_DLG_FILL := QudChrome.q8(6, 37, 37)             # opaque dialog fill (gamma-comp)
var Q_DLG_BORDER := QudChrome.q8(0x46, 0x64, 0x60)    # thin muted-teal frame line
var Q_DLG_TEXT := QudChrome.q8(0x6E, 0x8A, 0x86)      # question text ~ rgb(110,138,134)
var Q_DLG_LINE := QudChrome.q8(0x40, 0x6A, 0x73)      # button-row rule + framing ticks
var Q_DLG_CELL := QudChrome.q8(0x11, 0x2D, 0x2E)      # faint Yes/No cell fill

## The box is built from Qud's OWN extracted frame sprites (title/chrome/, via the mod)
## composed as Qud composes them (Frame/Border): a tiled dark panel, gold woven side +
## bottom borders, and the gilded hieroglyph header on top. These fractions are each
## piece's thickness relative to the box, from the dump (borderTop 350x69, borderSide
## 18-wide, borderBot 339x18 on a 339x292 border). Absent sprites -> the styled fallback.
const HEADER_H_FRAC := 0.198   # borderTop height / box height (native 69px on the 349px box)
const SIDE_W_FRAC := 0.052     # borderSide width / box width
const BOT_H_FRAC := 0.052      # borderBot height / box height
## Qud's header (borderTop 350w) OVERHANGS the box body (339w) by ~1.6% each side — the gilded
## header + hieroglyph row are wider than the box, an eave. Applied to the header edge below.
const HEADER_OVERHANG := 0.024  # (350-334)/2/334 — native sprite width vs box body

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

## Dev convenience: when Qud is up but no game is live, auto-boot a background "Meta" pseudo-game
## (mod `metagame` → Marsh Taur pregen, Classic) so Continue lights up and the viewer has a real zone
## without hand-running chargen. The mod broadcasts snapshots to this open probe once it boots, which
## flips `_game_live`. Set AUTO_META = false to stop Raves spinning up a character in your Qud.
## OFF (2026-08-03): it re-sent every 150s, silently booting throwaway characters whenever both
## apps idled at their titles — sabotaged menu-parity driving and littered husk saves. Sync via
## named saves now (`hv loadsave`); Continue's "load a game in Qud" hint covers the empty case.
const AUTO_META := false
var _meta_sent := false
var _meta_wait := 0.0
var _status_poll_t := 0.0
var _continue_hint: Label      # "load a game in Qud" note, shown when Qud is up but no game is live
var _bg_rect: TextureRect      # the title background (nudgeable live via title_bg.json)
## Live pan/zoom over the base cover. The 1.010 is MEASURED, not taste: a plain cover fit put
## our backdrop ~1% small against Qud's. The tell was that the best per-window alignment offset
## ran +8 px on the far left and -8 px on the far right — symmetric about the centre, which is a
## SCALE mismatch rather than a pan — and that the error lived almost entirely on edges (flat
## areas mean|d| 4.9, edge areas 43.0). It is emphatically NOT a colour grade: the two backdrops'
## channel means already agreed within 1% (R 51.4/50.7, G 74.1/73.4, B 68.4/67.7).
## Fitted by searching this very file live (MainMenu polls it) against Qud: mean|d| 6.0 -> 1.3.
## An anisotropic fit (sx 1.01012, sy 1.00975) scored marginally better at 1.14, but a cover fit
## is aspect-preserving by construction so anisotropy has no mechanism — that 0.04% split is
## inside the search's quantisation, and baking it would be encoding noise.
var _bg_nudge := {"dx": 0.0, "dy": 0.0, "scale": 1.010}
var _bg_nudge_mtime := -1.0
var _bg_poll_t := 0.0
var _quit_dialog: Control      # the "Are you sure you want to quit?" modal, or null
var _quit_sel := 0             # 0 = Yes, 1 = No
var _quit_opts: Array = []     # [{lbl, act}] for the dialog

func _ready() -> void:
	name = "MainMenu"
	# Report the scene FIRST: this scene is also where the in-game lifecycle watch
	# lands when a game ends (MainFrame -> change_scene). Without this, UiState kept
	# the last in-game scene and its 2s heartbeat rewrote that STALE value forever —
	# `hv state` then reported e.g. status_skills while Raves sat on the title, and
	# driving landed clicks on the menu.
	UiState.set_scene("title")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())
	if Settings.qud_shape():
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

## Poll the mod's heartbeat file (StartupHook.StartHeartbeat writes it ~1/s) for the live state.
## Fresh file ⇒ Qud is up; content "live" ⇒ a game is actually running. Robust vs. the socket probe.
## Freshness = "the mtime CHANGED recently", never wall-clock minus mtime: on Windows
## FileAccess.get_modified_time returns LOCAL time while get_unix_time_from_system is UTC,
## so the subtraction reads hours stale and Continue never enabled on the PC.
var _bridge_mtime := 0.0
var _bridge_mtime_seen := 0.0   # OUR clock when we last saw the mtime move
func _poll_bridge_status() -> void:
	var path := InputModel.support_dir().path_join("bridge_status.txt")
	if not FileAccess.file_exists(path):
		_set_qud_up(false)
		_set_game_live(false)
		return
	var m := float(FileAccess.get_modified_time(path))
	var now := Time.get_unix_time_from_system()
	if m != _bridge_mtime:
		_bridge_mtime = m
		_bridge_mtime_seen = now
	if now - _bridge_mtime_seen > 3.0:   # heartbeat stopped moving → the mod isn't running
		_set_qud_up(false)
		_set_game_live(false)
		return
	_set_qud_up(true)
	var live := false
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		live = f.get_as_text().strip_edges() == "live"
	_set_game_live(live)

func _build_logo() -> void:
	var tex := _load_title_png("logo.png")
	if tex != null:
		var r := TextureRect.new()
		r.texture = tex
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# THE TextureRect gotcha, again: without this the wordmark rendered at NATIVE
		# texture size (8% oversized + off-centre), silently ignoring the layout rect
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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
	# NB: unlike the console-screen TILES, the title ART + chrome sprites render
	# FAITHFULLY through the canvas (measured — brightening them overshot ×1.13);
	# only flat draws and text colours need QudChrome compensation.
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
	# QUD-SHAPE-OK: title screen is a 1:1 parity target; the else is pre-clone QoL spacing
	opts.add_theme_constant_override("separation", 7 if Settings.qud_shape() else 2)   # ElliotSans pitch 46 like Qud
	opts.anchor_left = 0.09
	opts.anchor_right = 0.91
	opts.anchor_top = 0.2195   # decoupled from HEADER_H_FRAC: rows measured aligned to Qud
	opts.anchor_bottom = 1.0 - (BOT_H_FRAC + 0.0355)
	for k in ["left", "top", "right", "bottom"]:
		opts.set("offset_" + k, 0.0)
	for cfg in BOX_ITEMS:
		var b := _option_button(cfg)
		opts.add_child(b)
		var sub: Label = null
		if cfg.get("act", "") == "continue":
			# the save Continue will open, on its OWN line — spelled into the caption it
			# overflowed Qud's narrow box by half its width
			sub = Label.new()
			sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			sub.autowrap_mode = TextServer.AUTOWRAP_OFF
			sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			sub.clip_text = true
			sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
			sub.add_theme_font_size_override("font_size", 13)
			sub.visible = false
			opts.add_child(sub)
		_rows.append({"btn": b, "cfg": cfg, "enabled": true, "sub": sub})
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
	if Settings.qud_shape():
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
	if side != null:   # left + right woven borders, NATIVE scale — stretching shimmered
		# the alternating checker; TILE draws 1:1 from the sprite's top
		box.add_child(_edge(side, TextureRect.STRETCH_TILE, 0.0, HEADER_H_FRAC * 0.6,
			SIDE_W_FRAC, 1.0 - BOT_H_FRAC * 0.4))
		var rt := _edge(side, TextureRect.STRETCH_TILE, 1.0 - SIDE_W_FRAC, HEADER_H_FRAC * 0.6,
			1.0, 1.0 - BOT_H_FRAC * 0.4)
		rt.flip_h = true
		box.add_child(rt)
	var bot := _chrome("borderBot.png")
	if bot != null:   # bottom border in two mirrored halves — BOTH corners get the
		# sprite's native corner art (a single stretch mangled the right corner)
		box.add_child(_edge(bot, TextureRect.STRETCH_TILE, 0.0, 1.0 - BOT_H_FRAC, 0.5, 1.0))
		var rb := _edge(bot, TextureRect.STRETCH_TILE, 0.5, 1.0 - BOT_H_FRAC, 1.0, 1.0)
		rb.flip_h = true
		box.add_child(rb)
	# the gilded hieroglyph header last, on top (its ends carry the top corners). Drawn at
	# EXACTLY native size, centred — any scaling (even ~1%) plus NEAREST filtering drops
	# pixel columns periodically and breaks the checker band's rhythm (Qud's is uniform).
	var hdr := TextureRect.new()
	hdr.texture = top
	hdr.stretch_mode = TextureRect.STRETCH_KEEP
	hdr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hdr.anchor_left = 0.5
	hdr.anchor_right = 0.5
	hdr.anchor_top = 0.0
	hdr.anchor_bottom = 0.0
	hdr.offset_left = -top.get_width() / 2.0
	hdr.offset_right = top.get_width() / 2.0
	hdr.offset_top = 0.0
	hdr.offset_bottom = top.get_height()
	box.add_child(hdr)
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
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp checker/hieroglyphs, like Qud
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
	_apply_elliot(b, "Medium", 28)
	return b

## Qud's selection marker: thin bright ragged bars at the button's top + bottom
## edges, sized to the text (+24px). Uses the buttonHighlight sprite's edge strips
## when extracted (their raggedness IS Qud's), else plain bright rects.
func _make_hl_bars(b: Button) -> Control:
	var wrap := Control.new()
	wrap.name = "hlbars"
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := b.get_theme_font("font")
	var fs := b.get_theme_font_size("font_size")
	var tw := f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
	var w := tw + 80.0   # Qud's bars run well past the text (measured 144px on 64px 'Mods')
	for spec in [[0.0, 0.0, -1.0], [1.0, -3.0, 1.0]]:
		var bar: Control
		if _hl != null:
			var at := AtlasTexture.new()
			at.atlas = _hl
			var hh := int(_hl.get_height())
			at.region = Rect2(0, 0 if spec[2] < 0 else hh - 3, _hl.get_width(), 3)
			var tr := TextureRect.new()
			tr.texture = at
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.self_modulate = Color8(224, 216, 189)
			bar = tr
		else:
			var cr := ColorRect.new()
			cr.color = Color8(224, 216, 189, 230)
			bar = cr
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_left = 0.5
		bar.anchor_right = 0.5
		bar.anchor_top = spec[0]
		bar.anchor_bottom = spec[0]
		bar.offset_left = -w * 0.5
		bar.offset_right = w * 0.5
		bar.offset_top = spec[1]
		bar.offset_bottom = spec[1] + 3.0
		wrap.add_child(bar)
	return wrap

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
	# QUD-SHAPE-OK: title screen is a 1:1 parity target; the else is pre-clone QoL spacing
	v.add_theme_constant_override("separation", 14 if Settings.qud_shape() else 6)
	for txt in LINK_ITEMS:
		var l := _label(txt, MUTED, "title")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_apply_elliot(l, "Bold", 21)
		if txt == "Modding Toolkit":
			# live link (the rest stay cosmetic for now): hover brightens like Qud,
			# click opens the toolkit menu overlay
			l.mouse_filter = Control.MOUSE_FILTER_STOP
			l.mouse_entered.connect(func(): l.add_theme_color_override("font_color", SEL))
			l.mouse_exited.connect(func(): l.add_theme_color_override("font_color", MUTED))
			l.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					_open_overlay("res://ModdingToolkitScreen.gd"))
		v.add_child(l)
	add_child(v)
	_place(v, "links")
	if Settings.qud_shape():
		# MEASURED 2026-08-07 at 1920x1080: Qud's rows top at y 855/894/932/972, ours at
		# 895/934/975/1015 — a full row pitch (40 px) low, which is why this column's glyph
		# overlap against Qud was 0.0% even with the right face loaded: the rows could not
		# land on each other at all. The pitch (39-40) and the x start (65 vs 64) already
		# matched, so this is a pure vertical offset. A 28 px pad used to sit at the top of
		# this VBox modelling "Qud's list starts lower than the layout rect"; the diff
		# disproved that. Dropping it moved the column 54 px, not the 28 its height suggested
		# (the VBox is placed by its own content height), so +2 puts the first row back on
		# Qud's y 855. Re-measured after the change rather than assumed.
		v.offset_top += 2
		v.offset_bottom += 2

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
		# QUD-SHAPE-OK: title screen is a 1:1 parity target; the else is the pre-clone QoL layout
		if Settings.qud_shape():
			# Qud's selection = two THIN BRIGHT ragged bars hugging the item's top and
			# bottom edges, only slightly wider than the text (measured: ~2px tall,
			# text+24 wide, peak (224,216,189)) — not a full-width sprite wash.
			var bars := b.get_node_or_null("hlbars")
			if on and bars == null:
				b.add_child(_make_hl_bars(b))
			elif not on and bars != null:
				bars.queue_free()
			b.add_theme_stylebox_override("normal", _transparent())
		else:
			# user mode keeps the sprite wash behind the option
			b.add_theme_stylebox_override("normal", _highlight_box() if on else _transparent())

## Qud disables Continue until there's a save; we mirror that against the live bridge —
## Continue lights up (becomes selectable) only while a modded Qud is running.
func _refresh_enabled() -> void:
	for row in _rows:
		var act: String = row["cfg"].get("act", "")
		var enabled := true
		if act == "continue":
			# 1:1 Continue opens the save picker (reads Qud's saves off disk), so it
			# enables when Qud's would: saves exist. OR when a game is already LIVE on the
			# bridge — because _saves_exist() reads ANOTHER APP'S container
			# (~/Library/Application Support/com.FreeholdGames.CavesOfQud), and macOS can
			# refuse that: TCC grants are per code-signature, and this app is ad-hoc re-signed
			# on every build, so the permission silently lapses. When it does, DirAccess.open
			# returns null, Continue greys out, and the app sits at the title looking like a
			# BRIDGE failure when the bridge is fine. A live game is reason enough to continue.
			# QUD-SHAPE-OK: Continue enablement follows Qud in both modes (a save OR a live game)
			enabled = (_saves_exist() or _game_live) if Settings.qud_shape() else _game_live
		row["enabled"] = enabled
		row["btn"].disabled = not enabled
		if act == "continue" and row.get("sub") != null:
			var sl: Label = row["sub"]
			var txt := _continue_label(sl)
			sl.text = txt
			sl.visible = txt != ""
			sl.add_theme_color_override("font_color", MUTED)
	if _sel < _rows.size() and not _rows[_sel]["enabled"]:
		_step(1)
	_apply_selection()
	_update_continue_hint()

## The newest save's character name + level, for the Continue label (Daniel's feedback: "Show the
## save's character name and level here"). Newest-first by Primary.json mtime — the same order
## LoadGameScreen and Qud's own picker use, so the label always names the save Continue will open.
## {} when there is no readable save (same TCC caveat as _saves_exist: we may be unable to LOOK).
func _newest_save() -> Dictionary:
	var root := OS.get_environment("HOME").path_join(
		"Library/Application Support/com.FreeholdGames.CavesOfQud/Synced/Saves")
	var d := DirAccess.open(root)
	if d == null:
		return {}
	var best := {}
	var best_mtime := -1
	for sub in d.get_directories():
		var pj := root.path_join(sub).path_join("Primary.json")
		if not FileAccess.file_exists(pj):
			continue
		var mt := FileAccess.get_modified_time(pj)
		if mt <= best_mtime:
			continue
		var f := FileAccess.open(pj, FileAccess.READ)
		if f == null:
			continue
		var data: Variant = JSON.parse_string(f.get_as_text())
		if data is Dictionary:
			best_mtime = mt
			best = {"name": str(data.get("Name", "")), "level": int(data.get("Level", 0))}
	return best

## Continue's label. 1:1 keeps Qud's bare "Continue" -- Qud names no save there, and the title
## screen is on the parity scoreboard. User mode gets the save it will actually open.
## TRIM THE NAME, KEEP THE LEVEL. The label is one line in Qud's narrow box, and left to the Label's
## own OVERRUN_TRIM_ELLIPSIS the tail goes first -- which is the level, i.e. exactly the half the
## request named ("Show the save's character name AND level here"). Measured on the live save
## `true-kin-cybernetics-menu-chaos-monkey` at level 188: the button read
## "true-kin-cybernetics-menu-chaos-mo…" and the 188 was nowhere on screen.
##
## So the ellipsis is applied HERE, to the name only, against the label's real width and font. A
## short suffix always survives; a long name degrades. Before layout `size.x` is 0 and there is
## nothing to measure against -- return the whole string and let the Label's own overrun handle that
## frame, since the next refresh (this runs on every menu update) measures properly.
func _continue_label(sl: Label = null) -> String:
	if Settings.qud_shape():
		return ""            # Qud names no save here, and the title is on the parity scoreboard
	var sv := _newest_save()
	var nm := str(sv.get("name", ""))
	if nm == "":
		return ""
	var suffix := " · lvl %d" % int(sv.get("level", 0))
	if sl == null or sl.size.x <= 0.0:
		return nm + suffix
	var f := sl.get_theme_font("font")
	var fs := sl.get_theme_font_size("font_size")
	if f == null:
		return nm + suffix
	var room := sl.size.x - f.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if f.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= room:
		return nm + suffix
	while nm.length() > 1 and \
			f.get_string_size(nm + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
		nm = nm.substr(0, nm.length() - 1)
	return nm + "…" + suffix

static var _saves_warned := false

## Any Qud save on disk? (Gates 1:1 Continue, like Qud's own.) Cheap: one dir listing.
func _saves_exist() -> bool:
	var root := InputModel.qud_saves_dir()   # per-OS (a bare HOME read broke the PC)
	var d := DirAccess.open(root)
	if d == null:
		# Not "no saves" — we could not LOOK. Say so once; the caller falls back to _game_live.
		if not _saves_warned:
			_saves_warned = true
			push_warning("Raves: cannot read Qud's saves dir (%s) — permission? " % root
				+ "Continue will rely on a live bridge game instead.")
		return false
	for sub in d.get_directories():
		if FileAccess.file_exists(root.path_join(sub).path_join("Primary.json")):
			return true
	return false

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
	# QUD-SHAPE-OK: title screen is a 1:1 parity target; the else is the pre-clone QoL layout
	if Settings.qud_shape():
		# Qud: BOLD hint text; the arrow-keys icon and each keycap sit inside WHITE
		# [ ] brackets; the d-pad keys carry dark directional arrows.
		var ih := int(round(UiFont.px(get_viewport(), "caption") * 1.15))
		var icon := QudChrome.nav_icon(ih, GOLD)
		# Qud's hint bar stays MONO (Source Code Pro), bolder than regular — an
		# emboldened variation of the theme font, not ElliotSans
		var fv := FontVariation.new()
		fv.base_font = get_theme_font("normal_font", "RichTextLabel")
		fv.variation_embolden = 0.5
		l.add_theme_font_override("normal_font", fv)
		# 16, not 18: at 18 the words measured ~13% wider than Qud's (its "select" spans 56 px
		# to ours at 63, "quit" 36 to 42).
		l.add_theme_font_size_override("normal_font_size", 16)
		var wht := "#FFFFFF"
		l.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER)
		l.append_text("[color=%s][lb][/color]" % wht)
		l.add_image(icon, icon.get_width(), icon.get_height())
		l.append_text("[color=%s][rb][/color]" % wht)
		# TWO spaces between segments, not six. Measured: Qud's gap from "navigate" to
		# "[Space]" is 19 px and ours was 70 — six spaces at 18 px mono is ~65 px of it.
		l.append_text("[color=%s] navigate  [/color]" % dim)
		l.append_text("[color=%s][lb][/color][color=%s]Space[/color][color=%s][rb][/color]" % [wht, gold, wht])
		l.append_text("[color=%s] select  [/color]" % dim)
		l.append_text("[color=%s][lb][/color][color=%s]Esc[/color][color=%s][rb][/color]" % [wht, gold, wht])
		l.append_text("[color=%s] quit[/color]" % dim)
		l.pop()
	else:
		l.text = "[center][color=%s]↑↓ navigate      [/color][color=%s][lb]Space[rb][/color][color=%s] select      [/color][color=%s][lb]Esc[rb][/color][color=%s] quit[/color][/center]" % [dim, gold, dim, gold, dim]
	add_child(l)
	_place(l, "hint")
	if Settings.qud_shape():
		l.offset_top += 6      # measured: Qud's hint inks at y 1036, the seeded rect put ours at 1030
		l.offset_bottom += 6
func _build_version() -> void:
	if Settings.qud_shape():
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
	# NO "raves x.y.z · hv …" line here. Qud's corner is two lines — its release and its
	# build — and a third line is Raves branding that 1:1 mode has no business showing. It
	# also pushed the block up: the extra line is why our corner started ~34 px above Qud's.
	l.text = "[right][color=%s]%s[/color]\n[color=%s]build %s[/color][/right]" % [
		ver, Brand.QUD_VERSION, bld, Brand.QUD_BUILD]
	_apply_elliot(l, "Regular", 16)
	add_child(l)
	_place(l, "version")
	# MEASURED: Qud's two lines ink at y 1034..1044 and 1054..1064; the seeded rect put ours
	# at 995, so the corner drops 67 px from the rect rather than the 28 guessed before.
	l.offset_top += 69
	l.offset_bottom += 69

# ── quit button + confirmation ─────────────────────────────────────────────────────

## Qud's upper-left "X" — its Cancel sprite at ~50% alpha (brightens on hover); click (or Esc)
## opens the "Are you sure you want to quit?" confirmation. Positioned in the top-left corner.
func _build_quit_button() -> void:
	var hit := Control.new()
	hit.name = "QuitX"
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.position = Vector2(26, 26)
	hit.custom_minimum_size = Vector2(42, 42)   # Qud's X is smaller/thinner than 56px
	hit.size = Vector2(42, 42)
	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.modulate = Color(0.62, 0.62, 0.62, 0.55)   # Qud's X: darker + ~50% alpha
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
	if Settings.qud_shape():
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
	UiState.set_scene("quit_dialog")

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
	UiState.set_scene("quit_dialog")

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
	UiState.set_scene("title")

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
			# Qud's Continue opens the save picker (ModernSaveManagement); mirror it
			# in 1:1 mode — but only when no game is LIVE. Qud can't sit at its title
			# with a running game, so a live game means "attach to it" (also, the mod
			# refuses loadsave mid-game — the picker would dead-end). User mode keeps
			# the direct attach-to-running-game jump.
			# QUD-SHAPE-OK: title screen is a 1:1 parity target; the else is pre-clone QoL behaviour
			if Settings.qud_shape() and not _game_live:
				_open_overlay("res://LoadGameScreen.gd")
			else:
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
	if _overlay.has_signal("load_requested"):
		_overlay.load_requested.connect(_on_load_requested)
	if _overlay.has_signal("delete_requested"):
		_overlay.delete_requested.connect(func(id):
			_send_command({"type": "command", "name": "deletesave", "id": str(id)}))
	if _overlay.has_signal("open_tool"):
		_overlay.open_tool.connect(_on_open_tool)
	# highvisor state report: a screen may declare its scene name (`ui_scene`,
	# e.g. ModdingToolkitScreen -> "modding_toolkit"); otherwise the legacy
	# derivation from the file name (ModsScreen -> mods, LoadGameScreen ->
	# loadgame) — the names the Mac gametree already maps.
	var scn: Variant = _overlay.get("ui_scene")
	if scn == null or str(scn) == "":
		scn = script_path.get_file().get_basename().replace("Screen", "").to_lower()
	UiState.set_scene(str(scn))

## Modding Toolkit hand-off: swap the toolkit overlay for the requested tool's
## screen (Qud's Mod Manager opens the same Mods screen; its Esc exits to the
## TITLE, not back to the toolkit — measured, so a plain overlay swap matches).
func _on_open_tool(tool_id: String) -> void:
	_close_overlay()
	match tool_id:
		"mod_manager":
			_open_overlay("res://ModsScreen.gd")
		"map_editor":
			# refresh blueprints.json first so the palette shows the live install
			_send_command({"type": "command", "name": "export"})
			_open_overlay("res://MapEditorScreen.gd")
		"blueprint_browser":
			# ask Qud to refresh blueprints.json first (a modded install can change it);
			# the screen reads whatever is on disk and reports its own empty state.
			_send_command({"type": "command", "name": "export"})
			_open_overlay("res://BlueprintBrowserScreen.gd")
		_:
			pass   # deep tools (map editor, waveform, …) — future leaves

func _close_overlay() -> void:
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null
	UiState.set_scene("title")
	_refresh_enabled()   # e.g. Continue greys if the picker deleted the last save
	# NB selection persists across a screen round-trip in Qud (return from Mods ->
	# "Mods" still white) — measured; do NOT deselect here.

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
	UiState.set_scene("chargen_game_mode")

func _on_mode_chosen(mode_name: String) -> void:
	_cg_mode = mode_name
	_close_overlay()
	if mode_name == "Tutorial":
		_start_tutorial()   # pregen guided game — no genotype/subtype, boot straight in
		return
	# Qud's next step is CHARACTER TYPE (Presets/New/Random/Library/Last), not genotype —
	# skipping it was the "jumped straight to the mutant/truekin screen" feedback (2026-08-10).
	_open_chartype()

func _open_chartype(notice := "") -> void:
	var ct: Variant = load("res://ChartypeScreen.gd").new()
	ct.mode_name = _cg_mode
	if notice != "":
		# Reuse the guided-tutorial popup as an honest notice for the chartype flows Raves
		# has no slice for yet — better than a click that silently does nothing, and better
		# than faking a screen it cannot follow through on.
		ct.guide_title = "NOT YET IN RAVES"
		ct.guide_body = notice
	_overlay = ct
	add_child(ct)
	ct.closed.connect(_close_overlay)
	ct.chose.connect(_on_chartype_chosen)
	UiState.set_scene("chargen_chartype")

func _on_chartype_chosen(type_id: String) -> void:
	_close_overlay()
	if type_id != "New":
		# Presets / Random / Library / Last are real Qud flows whose Raves slices are not
		# built yet. Reopen the step with the notice up rather than silently doing nothing.
		var title := "Presets" if type_id == "Pregen" else type_id
		# plain text — the guide body renders verbatim (no {{}} markup pass, see
		# ChargenCardScreen._update_guide_body)
		_open_chartype("%s isn't wired into Raves' character creation yet — New is the path that works end to end. To use %s, start the game from Qud's own window." % [title, title])
		return
	var geno: Variant = load("res://GenotypeScreen.gd").new()
	geno.mode_name = _cg_mode   # breadcrumb trail: Qud shows the mode alongside the current screen
	geno.chartype_title = "New"   # ...and the chartype leg: "Wander | New | Choose Genotype"
	_overlay = geno
	add_child(geno)
	geno.closed.connect(_close_overlay)
	geno.chose.connect(_on_genotype_chosen)
	UiState.set_scene("chargen_genotype")

## Tutorial mode: walk the guided pre-game menus (Choose Genotype, onboarding to Mutated Human, with
## the Tutorial Guide popup) before booting. Reuses the shared card screen with the tutorial extras.
func _start_tutorial() -> void:
	# BEGIN Qud's tutorial chargen now (if the bridge is up) so the mod parks it at the genotype
	# window and captures its live tip into tutorial_tip.txt — which the guide popup reads. The body
	# starts empty and fills in when the real (Qud) text lands; nothing tutorial prose is bundled.
	var tip_path := InputModel.support_dir().path_join("tutorial_tip.txt")
	if FileAccess.file_exists(tip_path):
		DirAccess.remove_absolute(tip_path)   # drop any stale tip so we don't flash the previous one
	if _qud_up and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_send_command({"type": "command", "name": "tutorial"})   # begin + capture tip
	var geno: Variant = load("res://GenotypeScreen.gd").new()
	geno.crumbs = [
		{"label": "Tutorial", "current": false},
		{"label": "Choose Genotype", "current": true},
		{"label": "Pregens", "current": false},
	]
	geno.onboard_index = 0   # steer to Mutated Human, the tutorial's genotype
	geno.guide_tip_file = "tutorial_tip.txt"
	_overlay = geno
	add_child(geno)
	geno.closed.connect(_close_overlay)
	geno.chose.connect(_on_tutorial_genotype)

## After the guided genotype pick, COMMIT Qud's tutorial (the guided builder is parked at the genotype
## window; the mod boots the fixed Marsh Taur pregen) and watch it in the Holodeck.
func _on_tutorial_genotype(_genotype_name: String) -> void:
	_close_overlay()
	if not _qud_up or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_warning("Raves: can't start tutorial — bridge not connected")
		return
	_send_command({"type": "command", "name": "tutorial_go"})   # commit + boot
	_enter_viewer()

## Frame + send a bridge command over the detection peer (same wire format as _send_embark).
func _send_command(msg: Dictionary) -> void:
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

func _on_genotype_chosen(genotype_name: String) -> void:
	_cg_genotype = genotype_name
	var cls := _genotype_subtype_class(genotype_name)   # "Castes" / "Callings"
	_close_overlay()
	var sub: Variant = load("res://CasteScreen.gd").new()
	# SPLIT SCENE, one per branch. Both used to report "chargen_subtype", which meant the gametree
	# could not tell Choose Caste from Choose Calling: `hv goto raves caste` passed its verify even
	# if the click had missed and confirmed Mutated Human instead. Qud distinguishes them first-party
	# (QudSubtypeModuleCategoryWindow vs QudSubtypeModuleWindow); this is Raves catching up.
	UiState.set_scene("chargen_caste" if cls == "Castes" else "chargen_calling")
	sub.subtype_class = cls
	sub.genotype_name = genotype_name
	sub.mode_name = _cg_mode
	sub.chartype_title = "New"   # the leg of the trail the chartype screen added
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
	# Detect "Qud up" / "game live" from the mod's heartbeat file — robust, unlike sensing bytes on
	# the socket (the menu probe can't reliably drain the full snapshot stream just to detect a game).
	_status_poll_t += dt
	if _status_poll_t >= 0.4:
		_status_poll_t = 0.0
		_poll_bridge_status()

	# Keep the command socket alive (used only to SEND — e.g. the auto-boot command). Drain and discard
	# anything the mod broadcasts to us so its per-client writer never stalls.
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			var avail := _peer.get_available_bytes()
			if avail > 0:
				_peer.get_data(avail)
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			_retry += dt
			if _retry >= 1.0:
				_retry = 0.0
				_peer = StreamPeerTCP.new()
				_peer.connect_to_host(BridgeClient.host(), BridgeClient.port())
		_:
			pass  # STATUS_CONNECTING

	# Auto-boot the background "Meta" pseudo-game so Continue is usable without hand-running chargen.
	if AUTO_META and _qud_up and not _game_live and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_meta_wait += dt
		if not _meta_sent or _meta_wait >= 150.0:   # re-send after 150s covers a first send that landed
			_send_command({"type": "command", "name": "metagame"})   # before Qud had reached its menu
			_meta_sent = true
			_meta_wait = 0.0

func _set_qud_up(up: bool) -> void:
	if up == _qud_up:
		return
	_qud_up = up
	if up:
		_launching = false
	else:
		_meta_sent = false   # Qud dropped — re-arm auto-boot for the next session
		_meta_wait = 0.0
	_refresh_enabled()

# A picker load is in flight: the mod is loading the chosen save in Qud; the moment
# the heartbeat flips to live, enter the viewer (the same attach as user-mode Continue).
var _pending_load := false

## LoadGameScreen chose a save: ask the mod to load it (LoadSave.cs completes Qud's
## own picker completionSource), close the picker, and wait for the game to go live.
func _on_load_requested(id: String) -> void:
	_send_command({"type": "command", "name": "loadsave", "id": id})
	_pending_load = true
	_close_overlay()

func _set_game_live(live: bool) -> void:
	if live == _game_live:
		return
	_game_live = live
	_refresh_enabled()
	if live and _pending_load:
		_pending_load = false
		_enter_viewer()

# ── UI helpers ──────────────────────────────────────────────────────────────────

# ── ElliotSans — Qud's modern-UI proportional font, carved from the player's own
# install into title/chrome/ (never redistributed; falls back to the theme font).
# The title menu / links / hint / version are NOT Source Code Pro in Qud.
var _elliot_fonts := {}

func _elliot(weight: String) -> FontFile:
	if _elliot_fonts.has(weight):
		return _elliot_fonts[weight]
	var path := InputModel.support_dir().path_join("title").path_join("chrome").path_join("ElliotSans-%s.ttf" % weight)
	if not FileAccess.file_exists(path):
		return null
	var f := FontFile.new()
	if f.load_dynamic_font(path) != OK:
		return null
	_elliot_fonts[weight] = f
	return f

## Apply ElliotSans to a control in 1:1 mode (no-op otherwise / when not extracted).
func _apply_elliot(c: Control, weight: String, size: int) -> void:
	if not Settings.qud_shape():
		return
	var f := _elliot(weight)
	if f == null:
		return
	if c is RichTextLabel:
		c.add_theme_font_override("normal_font", f)
		c.add_theme_font_size_override("normal_font_size", size)
	else:
		c.add_theme_font_override("font", f)
		c.add_theme_font_size_override("font_size", size)

func _label(txt: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()   # "Big" / "Title" / "Caption"
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	return l

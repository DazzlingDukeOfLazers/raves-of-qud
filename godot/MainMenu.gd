extends Control

## THE MAIN MENU — the pre-game launcher shown at startup (the project's main_scene).
##
## Left column: the action menu (buy / find / run Caves of Qud, settings, credits,
## support, quit). Right column: a best-faith legal / attribution panel built from the
## Brand source of truth. The game name and every fixed fact come from the Brand
## autoload, so a rename only touches Brand.gd.
##
## Built in GDScript like MainFrame / OnboardingControl so the .tscn stays a single
## node and inherits the one-source-of-truth UiFont theme.
##
## SCOPE (first pass): the launch/detect actions are PLACEHOLDER stubs that report what
## they WOULD do in the status line — no process launch, no browser open yet. "Run Qud"
## is wired to proceed into the gameplay frame so the app isn't a dead end. Swapping a
## stub for the real action (OS.shell_open for links, Steam launch + readiness detect)
## is a one-line change per handler, marked TODO(launch).

const COL_BG := Color(0.055, 0.065, 0.085)
const COL_PANEL := Color(0.10, 0.11, 0.14)
const COL_SUB := Color(0.08, 0.09, 0.12)
const COL_BORDER := Color(1, 1, 1, 0.12)
const COL_DIM := Color(1, 1, 1, 0.55)
const COL_ACCENT := Color(0.55, 0.78, 0.62)   # sage — headings / title

var _status: Label

func _ready() -> void:
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiFont.make_theme(get_viewport())
	get_viewport().size_changed.connect(_on_resize)
	get_window().title = Brand.title()          # runtime title from the source of truth
	RenderingServer.set_default_clear_color(COL_BG)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	root.add_child(_header())

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 22)
	root.add_child(cols)

	var left := _menu_column()
	left.custom_minimum_size = Vector2(460, 0)
	cols.add_child(left)

	var right := _attribution_column()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	_status = _label("", COL_DIM, "caption")
	root.add_child(_status)

func _on_resize() -> void:
	UiFont.refresh_theme(theme, get_viewport())

# ── header ────────────────────────────────────────────────────────────────────

func _header() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var title := _label(Brand.GAME_NAME, COL_ACCENT, "big")
	v.add_child(title)
	v.add_child(_label(Brand.GAME_TAGLINE, COL_DIM, "caption"))
	return v

# ── left column: the action menu ──────────────────────────────────────────────

func _menu_column() -> Control:
	var panel := _framed(COL_PANEL)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(v)

	# Purchase — expandable to the three storefronts.
	v.add_child(_expander("Purchase a copy of %s" % Brand.BASE_GAME, [
		_action("Steam", func(): _open_link("Steam store", Brand.URL_STEAM)),
		_action("GOG", func(): _open_link("GOG store", Brand.URL_GOG)),
		_action("Elsewhere", func(): _open_link("official site", Brand.URL_ELSEWHERE)),
	]))

	v.add_child(_action("Find %s locally" % Brand.BASE_GAME,
		func(): _stub("Locate the installed copy of %s" % Brand.BASE_GAME)))
	v.add_child(_action("Run %s" % Brand.BASE_GAME, _run_qud))
	v.add_child(_action("Open settings", func(): _stub("Open settings")))
	v.add_child(_action("Credits", func(): _stub("Show credits")))

	# Support — expandable.
	v.add_child(_expander("Support", [
		_action("Feedback (available in-game)",
			func(): _stub("In-game feedback")),
		_action("Support the creators — buy another copy of %s" % Brand.BASE_GAME,
			func(): _open_link("Steam store", Brand.URL_STEAM)),
		_action("Donate to %s" % Brand.GAME_NAME,
			func(): _open_link("donation link", Brand.URL_DONATE)),
	]))

	v.add_child(_hsep())
	# The organization behind Raves of Qud — placeholder until the entity is named.
	var org := _label("Made by  %s" % Brand.ORG_NAME, COL_DIM, "caption")
	v.add_child(org)
	v.add_child(_hsep())

	v.add_child(_action("Quit", func(): get_tree().quit()))
	return panel

# ── right column: legal / attribution ─────────────────────────────────────────

func _attribution_column() -> Control:
	var panel := _framed(COL_PANEL)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)

	v.add_child(_label("Rights & licensing", COL_ACCENT, "title"))
	for section in Brand.attribution_sections():
		var block := VBoxContainer.new()
		block.add_theme_constant_override("separation", 2)
		var head := _label(String(section.get("head", "")), Color.WHITE, "body")
		head.add_theme_color_override("font_color", COL_ACCENT)
		block.add_child(head)
		var body := _label(String(section.get("body", "")), COL_DIM, "caption")
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block.add_child(body)
		v.add_child(block)

	var disclaimer := _label(
		"This summary is provided in good faith and is not legal advice.",
		COL_DIM, "caption")
	disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_hsep())
	v.add_child(disclaimer)
	return panel

# ── handlers ──────────────────────────────────────────────────────────────────

## Placeholder for "Run Qud": proceed into the gameplay frame so the app is navigable.
## TODO(launch): first launch the installed copy (Brand.URL_STEAM_RUN) and wait until
## the bridge is reachable, THEN switch to the frame.
func _run_qud() -> void:
	_stub("Run %s → entering viewer (placeholder)" % Brand.BASE_GAME)
	get_tree().change_scene_to_file("res://MainFrame.tscn")

## Placeholder for an outbound link. TODO(launch): OS.shell_open(url).
func _open_link(what: String, url: String) -> void:
	_stub("Open %s:  %s" % [what, url])

func _stub(what: String) -> void:
	if _status != null:
		_status.text = "· %s  (placeholder — not wired yet)" % what

# ── UI helpers ────────────────────────────────────────────────────────────────

func _label(txt: String, col := Color.WHITE, role := "body") -> Label:
	var l := Label.new()
	l.text = txt
	if role != "body":
		l.theme_type_variation = role.capitalize()   # "Big"/"Title"/"Caption"
	if col != Color.WHITE:
		l.add_theme_color_override("font_color", col)
	return l

func _action(txt: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b

## A top button that shows/hides an indented block of sub-actions.
func _expander(txt: String, children: Array) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	var sub := VBoxContainer.new()
	sub.add_theme_constant_override("separation", 4)
	sub.visible = false

	var head := Button.new()
	head.focus_mode = Control.FOCUS_NONE
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.text = "▸ " + txt
	head.pressed.connect(func():
		sub.visible = not sub.visible
		head.text = ("▾ " if sub.visible else "▸ ") + txt)
	v.add_child(head)

	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 22)
	indent.add_child(sub)
	for c in children:
		sub.add_child(c)
	v.add_child(indent)
	return v

func _framed(bg: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(1)
	sb.border_color = COL_BORDER
	sb.set_corner_radius_all(4)
	for side in ["left", "right", "top", "bottom"]:
		sb.set("content_margin_" + side, 14)
	p.add_theme_stylebox_override("panel", sb)
	return p

func _hsep() -> HSeparator:
	return HSeparator.new()

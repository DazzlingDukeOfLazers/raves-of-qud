class_name UiFont
extends RefCounted

## SINGLE SOURCE OF TRUTH for every UI font size in the project.
##
## Sizes scale with the window HEIGHT so the UI reads the same on any display, and never fall below
## MIN (nothing in the app is smaller than this). Everything routes through px(): the mode label,
## debug menu, reset button, the selection log (CellInspector), the tile-report form (TileReport),
## the onboarding wizard, and the font ruler. Change FRAC / MIN here and the whole app follows.
##
## Tuned with the in-app font ruler (press L): FRAC=0.0197 => ~36px "body" at a 1832-tall window;
## MIN=28 was the user's readable floor.

const FRAC := 0.0197        # body px = window_height * FRAC
const MIN := 28             # absolute floor px — no text anywhere is smaller

## Global multiplier on every UI size, set from the Options "Font scale" setting (Settings
## autoload applies it at startup). 1.0 = the tuned default. Re-stamp themes after changing it.
static var scale := 1.0

## Roles are multipliers of the body size, so the hierarchy scales together.
const ROLE := {
	"caption": 0.85,        # sub-labels, hints, captions
	"body": 1.0,            # default: labels, buttons, form fields, the selection log
	"title": 1.2,           # panel headings
	"big": 1.5,             # hero text
}

## The pixel size for a role at the given viewport's current height. Floored at MIN so even a
## caption in a short window stays readable. `bump` is a live nudge (the +/- keys) in px.
static func px(vp: Viewport, role := "body", bump := 0) -> int:
	var h := 900.0
	if vp != null:
		h = vp.get_visible_rect().size.y
	var mult := float(ROLE.get(role, 1.0))
	return maxi(int(MIN * scale), int(h * FRAC * mult * scale) + bump)

## THE automatic hook: a project-wide default Theme carrying the body size + the bundled Atkinson
## font. Assign it to the ROOT viewport (Main does this) and EVERY Control that doesn't explicitly
## override — CharacterCreator, and any UI written in the future — inherits the source-of-truth size
## and font for free. Explicit `add_theme_font_size_override` calls still win where a specific role
## is wanted. Also registers Label/Button type variations ("Title","Big","Caption") so new code can
## pick a role with `theme_type_variation = "Title"` instead of hardcoding a number.
static func make_theme(vp: Viewport) -> Theme:
	var t := Theme.new()
	var f := load("res://fonts/AtkinsonHyperlegible-Regular.ttf")
	if f != null:
		t.default_font = f
	refresh_theme(t, vp)
	return t

## Re-stamp a theme's sizes for the current window (call on resize). Keeps the default + every role
## variation in sync with px().
static func refresh_theme(t: Theme, vp: Viewport) -> void:
	if t == null:
		return
	t.default_font_size = px(vp, "body")
	for role in ROLE.keys():
		var vtype: String = String(role).capitalize()   # "Caption" / "Body" / "Title" / "Big"
		for base in ["Label", "Button", "CheckBox", "LineEdit", "TextEdit", "OptionButton"]:
			t.set_type_variation(vtype, base)
			t.set_font_size("font_size", vtype, px(vp, role))

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
	return maxi(MIN, int(h * FRAC * mult) + bump)

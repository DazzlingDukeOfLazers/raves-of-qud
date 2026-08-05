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
const MIN := 14             # absolute floor px — no text anywhere is smaller
                            # (was 28 when the window rendered at a 2x framebuffer; allow_hidpi is
                            #  now off so px == real px, and the floor halves to keep the same size)

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
## Qud's INPUT-GLYPH font, extracted from the game by the mod's GlyphExporter and loaded as a
## FALLBACK. Qud writes its keycap icons as Private Use Area codepoints (U+E80A navigate, U+E816
## Ctrl, U+E802 Shift, U+E809 LMB …) and draws them from its own TMP atlas; Source Code Pro has
## nothing at U+E8xx, so before this every one rendered as a tofu box — the picker's footer read
## "[?] navigate". As a fallback it needs no call-site changes: any mirrored string containing one
## of those codepoints just renders the real icon.
##
## Cached because make_theme runs per overlay and the .fnt parse is not free. Missing file (the mod
## has not run its export yet) is normal, not an error — QudText.GLYPHS still substitutes words.
static var _glyph_font: FontFile = null
static var _glyph_tried := false

static func qud_glyph_font() -> FontFile:
	if _glyph_tried:
		return _glyph_font
	_glyph_tried = true
	var path := InputModel.support_dir().path_join("glyphs").path_join("qud_glyphs.fnt")
	if not FileAccess.file_exists(path):
		return null
	var ff := FontFile.new()
	if ff.load_bitmap_font(path) != OK:
		push_warning("Raves: could not parse Qud's glyph font at %s" % path)
		return null
	# A bitmap font is rasterised at ONE size (Qud's atlas is ~201pt); without this it would draw at
	# that size next to 36px body text. Scaling keeps the icon proportional to the line it sits on.
	ff.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
	_glyph_font = ff
	return _glyph_font

## `base` with Qud's glyph font appended as a fallback. Returns a DUPLICATE: `fallbacks` is a
## property of the loaded resource, and load() hands back a shared instance — mutating it in place
## would push the fallback onto every other user of that .ttf, and re-appending on each make_theme
## call would grow the list without bound.
static func _with_qud_glyphs(base: Font) -> Font:
	var g := qud_glyph_font()
	if g == null or base == null:
		return base
	var dup: Font = base.duplicate()
	var fb := dup.fallbacks.duplicate()
	fb.append(g)
	dup.fallbacks = fb
	return dup

static func make_theme(vp: Viewport) -> Theme:
	var t := Theme.new()
	# Source Code Pro is Qud's UI font (wiki Visual Style). Fall back to Atkinson if it's ever missing.
	var f := load("res://fonts/SourceCodePro-Regular.ttf")
	if f == null:
		f = load("res://fonts/AtkinsonHyperlegible-Regular.ttf")
	if f != null:
		f = _with_qud_glyphs(f)
		t.default_font = f
		# Register the matching bold so RichTextLabel [b] (message log, nearby, command bar) renders in
		# Source Code Pro Bold rather than a synthesised/fallback bold. normal/mono stay the regular face.
		var fb: Font = load("res://fonts/SourceCodePro-Bold.ttf")
		if fb != null:
			fb = _with_qud_glyphs(fb)
			t.set_font("normal_font", "RichTextLabel", f)
			t.set_font("mono_font", "RichTextLabel", f)
			t.set_font("bold_font", "RichTextLabel", fb)
			t.set_font("bold_italics_font", "RichTextLabel", fb)
	# Qud's default UI text is the palette grey (y); emphasis stays white via explicit overrides.
	for base in ["Label", "Button", "CheckBox", "LineEdit", "TextEdit", "OptionButton"]:
		t.set_color("font_color", base, QudPalette.TEXT)
	t.set_color("default_color", "RichTextLabel", QudPalette.TEXT)   # RTL uses default_color, not font_color
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

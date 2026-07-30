class_name QudPalette
extends RefCounted

## Caves of Qud's canonical 18-colour palette, transcribed from the official wiki's Visual Style page
## (wiki.cavesofqud.com/wiki/Visual_Style). Keyed by Qud's one-letter colour code.
##
## This is the reference for UI CHROME parity (backgrounds, text, bars) so Raves matches Qud's look
## from one place. Tile RENDERING still uses the palette the mod sends each snapshot (same values) —
## this constant is for the Godot theme + frame colours, which never touch the wire.

const COLORS := {
	"r": Color("a64a2e"), "R": Color("d74200"),   # dark red / red
	"o": Color("f15f22"), "O": Color("e99f10"),   # dark orange / orange
	"w": Color("98875f"), "W": Color("cfc041"),   # brown / gold
	"g": Color("009403"), "G": Color("00c420"),   # dark green / green
	"b": Color("0048bd"), "B": Color("0096ff"),   # dark blue / azure
	"c": Color("40a4b9"), "C": Color("77bfcf"),   # dark cyan / cyan
	"m": Color("b154cf"), "M": Color("da5bd6"),   # dark magenta / magenta
	"k": Color("0f3b3a"), "K": Color("155352"),   # "Qud viridian" bg / dark grey
	"y": Color("b1c9c3"), "Y": Color("ffffff"),   # grey / white
}

# Named aliases for the common chrome roles (the code names in comments).
const BG := Color("0f3b3a")           # k — the screen background ("Qud viridian")
const PANEL := Color("155352")        # K — one step up, for panels / strips
const TEXT := Color("b1c9c3")         # y — default UI text (grey)
const TEXT_BRIGHT := Color("ffffff")  # Y — emphasis / headings
const HP := Color("00c420")           # G — HP bar green
const WATER := Color("0096ff")        # B — thirst / water-blue (water is currency)
const HUNGER := Color("e99f10")       # O — hunger / food-orange
const AMBER := Color("f15f22")        # o — cooldowns / warnings

## Look up a colour by its Qud code (e.g. "R"), falling back to white for an unknown code.
static func of(code: String, fallback := Color.WHITE) -> Color:
	return COLORS.get(code, fallback)

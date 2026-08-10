extends "res://ChargenCardScreen.gd"

## CHARACTER CREATION — CHARACTER TYPE (Qud's ":choose character type:"), the step BETWEEN game
## mode and genotype that Raves used to skip (feedback 2026-08-10: picking Wander jumped straight
## to Mutant/True Kin). Five cards off EmbarkModules.xml → QudChartypeModule via chargen.json:
## Presets / New / Random / Library / Last. `chose` emits the module ID ("Pregen", "New", …) —
## the string Qud's own selectType() takes — not the on-card title.
##
## Only {{W|New}} continues inside Raves for now (the genotype slice onward). The other four are
## real Qud flows whose Raves slices don't exist yet; MainMenu answers them with the guide-style
## notice rather than silently doing nothing or faking a screen.

## The game mode already chosen, for the breadcrumb trail. Qud's crumb here reads
## "Wander | Select Character Option" — the crumb LABEL differs from the window subtitle
## (captured live 2026-08-10, reports/qud_chartype).
var mode_name := ""

## Fallback types — verbatim from EmbarkModules.xml, used until chargen.json is slurped.
const TYPES := [
	{"name": "Pregen", "display": "Presets", "hotkey": "A", "tile": "UI/sw_preset.bmp",
		"desc": "Pick from several preset characters. Once you get comfortable, you can customize them."},
	{"name": "New", "display": "New", "hotkey": "B", "tile": "UI/sw_newchar.bmp",
		"desc": "Create a new character."},
	{"name": "Random", "display": "Random", "hotkey": "C", "tile": "UI/sw_random.bmp",
		"desc": "Roll a random character."},
	{"name": "Library", "display": "Library", "hotkey": "D", "tile": "Items/sw_bookshelf1.bmp",
		"desc": "Choose a character from your build library."},
	{"name": "Last", "display": "Last", "hotkey": "E", "tile": "UI/sw_lastchar.bmp",
		"desc": "Replay the last character you played."},
]

func _screen_node_name() -> String: return "ChartypeScreen"
func _subtitle() -> String: return ":choose character type:"
func _default_index() -> int: return 0   # Presets — Qud's default, captured live


func _breadcrumb_crumbs() -> Array:
	var out: Array = []
	if mode_name != "":
		out.append({"label": mode_name, "current": false,
			"tile": _chargen_tile("gameModes", mode_name)})
	out.append({"label": "Select Character Option", "current": true})
	return out


func _load_items() -> Array:
	var path := InputModel.support_dir().path_join("chargen.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.get("charTypes", null) is Array and not data["charTypes"].is_empty():
				return data["charTypes"]
	return TYPES.duplicate(true)


## Card icon two-tones, from the XML's own fg/detail codes: W = Qud's gold, w = its brown.
## (The gold is SEL_GOLD's #cfc041 — the same W every measured screen landed on.)
func _card_icon(tile: String, item_name: String) -> Dictionary:
	var pal := _type_palette(item_name)
	return {
		"colored": _recolor_tile(tile, pal[0], pal[1]),
		"neutral": _recolor_tile(tile, ICON_MAIN, ICON_DETAIL),
	}


func _type_palette(type_id: String) -> Array:
	var gold := Color8(0xCF, 0xC0, 0x41)   # Qud W (measured — ChargenCardScreen.SEL_GOLD)
	var brown := Color8(0x98, 0x87, 0x5F)  # Qud w
	match type_id:
		"Random", "Library":   # the XML flips these two: Foreground w, Detail W
			return [brown, gold]
		_:
			return [gold, brown]

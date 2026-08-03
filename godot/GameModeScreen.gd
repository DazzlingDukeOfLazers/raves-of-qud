extends "res://ChargenCardScreen.gd"

## CHARACTER CREATION — stage 0: GAME MODE (Qud's ":choose game mode:"). Thin subclass of the shared
## ChargenCardScreen card-row template; supplies the mode data + per-card two-tone colours.

## Fallback modes — names + descriptions verbatim from Qud's EmbarkModules.xml.
const MODES := [
	{"name": "Tutorial", "display": "Tutorial", "hotkey": "A", "desc": "Learn the basics of Caves of Qud."},
	{"name": "Classic", "display": "Classic", "hotkey": "B", "desc": "Permadeath: lose your character when you die."},
	{"name": "Roleplay", "display": "Roleplay", "hotkey": "C", "desc": "Checkpointing at settlements."},
	{"name": "Wander", "display": "Wander", "hotkey": "D", "desc": "{{c|ù}} Most creatures begin neutral to you.\n{{c|ù}} No XP for killing.\n{{c|ù}} More XP for discoveries and performing the water ritual.\n{{c|ù}} Checkpointing at settlements."},
	{"name": "Daily", "display": "Daily", "hotkey": "E", "desc": "{{c|ù}} One chance with a fixed character and world seed."},
]

func _screen_node_name() -> String: return "GameModeScreen"
func _breadcrumb_crumbs() -> Array: return [{"label": "Choose Game Mode", "current": true}]
func _subtitle() -> String: return ":choose game mode:"
func _default_index() -> int: return 1   # Classic, like Qud's default

func _load_items() -> Array:
	var path := InputModel.support_dir().path_join("chargen.json")
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary and data.get("gameModes", null) is Array and not data["gameModes"].is_empty():
				return data["gameModes"]
	return MODES.duplicate(true)

## Qud's card icons are near-black mask sprites recoloured two-tone (dark body → foreground, bright
## accents → detail). Selected shows the per-mode colours; unselected the neutral grey-teal.
func _card_icon(tile: String, item_name: String) -> Dictionary:
	var pal := _mode_palette(item_name)
	return {
		"colored": _recolor_tile(tile, pal[0], pal[1]),
		"neutral": _recolor_tile(tile, ICON_MAIN, ICON_DETAIL),
	}

func _mode_palette(mode_name: String) -> Array:
	match mode_name:
		"Tutorial": return [Color8(0x15, 0x49, 0x48), Color8(0xC8, 0xB0, 0x3C)]  # dark mortarboard, yellow tassel
		"Classic":  return [Color8(0xA8, 0xC2, 0xBB), Color8(0x15, 0x49, 0x48)]  # grey figure, dark detail
		"Roleplay": return [Color8(0x3A, 0x52, 0xB2), Color8(0x62, 0xC4, 0xCA)]  # cobalt figures, teal triangle
		"Wander":   return [Color8(0x48, 0x8E, 0x3A), Color8(0x62, 0xC4, 0xCA)]  # green river/road, teal castle
		"Daily":    return [Color8(0x8C, 0x7D, 0x50), Color8(0xC8, 0xB0, 0x3C)]  # tan glass, yellow face
		_:          return [ICON_MAIN, ICON_DETAIL]

class_name QudBinds
extends RefCounted

## Match key events against the player's CURRENT Qud keybindings (bindings.json,
## exported by the mod's BindingsExporter and refreshed on every rebind).
##
## This is the seam that makes Control Mapping edits WORK in Raves: Qud stores a
## remap fine (verified: "{" → Composite OneModifier leftBracket+shift on disk),
## but Raves' in-game keys were all hardcoded, so a custom bind died at our door.
## Main consults this map as the LAST fallback in _unhandled_input — Raves' own
## handlers keep precedence, anything else that matches a bound combo is sent to
## Qud's command executor over the bridge ({"command": <CmdID>}), which is exactly
## what the keypress would do inside Qud.
##
## Parsing: the export carries Qud's FORMATTED display strings ("Shift+[", "Num /",
## "Control+7", CP437 arrows). A bare digit is ambiguous (Qud renders numpad7 as
## "7"), so digits match BOTH the digit row and the numpad.

var _map := {}          # "keycode|ctrl|shift|alt" -> command id (first bind wins)
var _mtime := 0
var _path := ""

const _NAMED := {
	"space": [KEY_SPACE], "enter": [KEY_ENTER, KEY_KP_ENTER], "return": [KEY_ENTER],
	"tab": [KEY_TAB], "backspace": [KEY_BACKSPACE],
	"delete": [KEY_DELETE], "del": [KEY_DELETE], "insert": [KEY_INSERT], "ins": [KEY_INSERT],
	"home": [KEY_HOME], "end": [KEY_END],
	"pageup": [KEY_PAGEUP], "pgup": [KEY_PAGEUP], "pagedown": [KEY_PAGEDOWN], "pgdn": [KEY_PAGEDOWN],
	"↑": [KEY_UP], "↓": [KEY_DOWN], "←": [KEY_LEFT], "→": [KEY_RIGHT],
	"[": [KEY_BRACKETLEFT], "]": [KEY_BRACKETRIGHT], ";": [KEY_SEMICOLON], "'": [KEY_APOSTROPHE],
	",": [KEY_COMMA], ".": [KEY_PERIOD], "/": [KEY_SLASH], "\\": [KEY_BACKSLASH],
	"-": [KEY_MINUS, KEY_KP_SUBTRACT], "=": [KEY_EQUAL], "`": [KEY_QUOTELEFT],
	"+": [KEY_KP_ADD], "*": [KEY_KP_MULTIPLY],
}
const _NUMPAD := {
	"/": [KEY_KP_DIVIDE], "*": [KEY_KP_MULTIPLY], "+": [KEY_KP_ADD], "-": [KEY_KP_SUBTRACT],
	".": [KEY_KP_PERIOD], "enter": [KEY_KP_ENTER],
}

func setup(support_dir: String) -> void:
	_path = support_dir.path_join("bindings.json")

## Reload when the export changed (cheap stat; called per matched keypress path).
func _reload_if_changed() -> void:
	if _path == "" or not FileAccess.file_exists(_path):
		return
	var mt := FileAccess.get_modified_time(_path)
	if mt == _mtime:
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	if txt.length() > 0 and txt.unicode_at(0) == 0xFEFF:
		txt = txt.substr(1)
	var data: Variant = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	_mtime = mt
	_map.clear()
	for cat in data.get("categories", []):
		for c in cat.get("commands", []):
			var id := str(c.get("id", ""))
			if id == "":
				continue
			for slot in ["b1", "b2", "b3", "b4"]:
				for combo in _parse(str(c.get(slot, ""))):
					if not _map.has(combo):
						_map[combo] = id

## Formatted bind string -> list of matchable "keycode|c|s|a" combos ([] if unparsable).
func _parse(s: String) -> Array:
	if s == "":
		return []
	for code in [24, 25, 26, 27]:   # CP437 arrows (raw in the export)
		s = s.replace(String.chr(code), ["↑", "↓", "→", "←"][code - 24])
	var parts := s.split("+")
	var key := str(parts[parts.size() - 1])
	var mods := parts.slice(0, parts.size() - 1)
	if key == "" and mods.size() > 0 and str(mods[mods.size() - 1]) == "":
		key = "+"                    # the key itself is "+" ("Control++" splits to a trailing pair)
		mods = mods.slice(0, mods.size() - 1)
	var ctrl := false
	var shift := false
	var alt := false
	for m in mods:
		match str(m).strip_edges().to_lower():
			"control", "ctrl": ctrl = true
			"shift": shift = true
			"alt": alt = true
			_: return []             # unknown modifier — don't guess
	var numpad := false
	if key.begins_with("Num "):      # Qud renders numpad punctuation as "Num /" etc.
		numpad = true
		key = key.substr(4)
	var codes := _key_codes(key.strip_edges(), numpad)
	var out: Array = []
	for kc in codes:
		out.append("%d|%d%d%d" % [kc, int(ctrl), int(shift), int(alt)])
	return out

func _key_codes(key: String, numpad: bool) -> Array:
	var low := key.to_lower()
	if numpad and _NUMPAD.has(low):
		return _NUMPAD[low]
	if key.length() == 1:
		var ch := key.unicode_at(0)
		if ch >= 65 and ch <= 90:
			return [KEY_A + (ch - 65)]
		if ch >= 97 and ch <= 122:
			return [KEY_A + (ch - 97)]
		if ch >= 48 and ch <= 57:    # bare digit: Qud shows numpad digits as plain "7"
			return [KEY_0 + (ch - 48), KEY_KP_0 + (ch - 48)]
	if _NAMED.has(low):
		return _NAMED[low]
	if low.length() >= 2 and low[0] == "f" and low.substr(1).is_valid_int():
		var n := int(low.substr(1))
		if n >= 1 and n <= 12:
			return [KEY_F1 + n - 1]
	return []

## The bound Qud command for this key event, or "" when none matches.
func match_event(e: InputEventKey) -> String:
	_reload_if_changed()
	if _map.is_empty():
		return ""
	var combo := "%d|%d%d%d" % [e.keycode, int(e.ctrl_pressed or e.meta_pressed),
		int(e.shift_pressed), int(e.alt_pressed)]
	return str(_map.get(combo, ""))

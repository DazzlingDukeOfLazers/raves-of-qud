class_name QudText
extends RefCounted

## Qud colour markup helpers. Qud uses TWO formats, sometimes in one string:
##   {{code|text}}  — a span (can nest), the colour is the char before '|'
##   &X             — running FOREGROUND colour for following text until the next &X (stateful)
##   ^X             — running background (we ignore it)
## `palette` maps a single-char code -> hex string.

## Render markup as Godot BBCode ([color=#hex]…[/color]), escaping stray '[' so text can't be read as
## BBCode. Unknown codes fall back to white.
static func to_bbcode(s: String, palette: Dictionary) -> String:
	s = cp437(s)
	var out := ""
	var i := 0
	var n := s.length()
	var depth := 0        # open {{ }} spans
	var amp := false      # an &X colour is currently open
	while i < n:
		if i + 1 < n and s[i] == "{" and s[i + 1] == "{":
			var bar := s.find("|", i + 2)
			var close := s.find("}}", i + 2)
			if bar >= 0 and (close < 0 or bar < close):
				out += "[color=#%s]" % _hex(s.substr(i + 2, bar - (i + 2)), palette)
				depth += 1
				i = bar + 1
				continue
			i += 2
			continue
		if i + 1 < n and s[i] == "}" and s[i + 1] == "}":
			if depth > 0:
				out += "[/color]"
				depth -= 1
			i += 2
			continue
		# A DOUBLED sigil is Qud's escape for the literal character, not a colour code.
		# Popup.NewPopupMessageAsync does `.Replace("&&", "&").Replace("^^", "^")` on the
		# way in and re-doubles on the way out, so every mirrored string carrying a real
		# ampersand arrives doubled. Consuming it as a colour code ate BOTH characters and
		# rendered Qud's "Keyboard & Mouse" as "Keyboard  Mouse".
		if i + 1 < n and (s[i] == "&" or s[i] == "^") and s[i + 1] == s[i]:
			out += s[i]
			i += 2
			continue
		if s[i] == "&" and i + 1 < n:
			if amp:
				out += "[/color]"
			out += "[color=#%s]" % _hex(s.substr(i + 1, 1), palette)
			amp = true
			i += 2
			continue
		if s[i] == "^" and i + 1 < n:
			i += 2                       # background code — skip
			continue
		out += "[lb]" if s[i] == "[" else s[i]
		i += 1
	if amp:
		out += "[/color]"
	while depth > 0:
		out += "[/color]"
		depth -= 1
	return out

## Strip all markup to plain text.
static func strip(s: String) -> String:
	var out := ""
	var i := 0
	var n := s.length()
	while i < n:
		if i + 1 < n and s[i] == "{" and s[i + 1] == "{":
			var bar := s.find("|", i + 2)
			var close := s.find("}}", i + 2)
			if bar >= 0 and (close < 0 or bar < close):
				i = bar + 1
				continue
			i += 2
			continue
		if i + 1 < n and s[i] == "}" and s[i + 1] == "}":
			i += 2
			continue
		if i + 1 < n and (s[i] == "&" or s[i] == "^") and s[i + 1] == s[i]:
			out += s[i]            # doubled sigil = the literal character (see to_bbcode)
			i += 2
			continue
		if (s[i] == "&" or s[i] == "^") and i + 1 < n:
			i += 2
			continue
		out += s[i]
		i += 1
	return out

static func _hex(code: String, palette: Dictionary) -> String:
	var c := code.substr(0, 1) if code.length() > 0 else ""
	var h := String(palette.get(c, ""))
	return h.trim_prefix("#") if h != "" else "ffffff"


## Qud markup -> [[text, Color], …] runs, for CANVAS drawing (draw_string) where a
## RichTextLabel per row would be far too many nodes (the skills tree is ~140 rows).
## Same grammar as to_bbcode: {{code|…}} spans (nestable, inner wins) and &X codes.
## NB: written without lambdas on purpose — GDScript closures capture by VALUE, so a
## `flush` lambda appends the string as it was when the lambda was created (empty).
static func runs(s: String, palette: Dictionary, default_color := Color(1, 1, 1)) -> Array:
	s = cp437(s)
	var out: Array = []
	var stack: Array = []            # active {{ }} colours, innermost last
	var amp_col: Color = default_color
	var amp_on := false
	var cur := ""
	var cur_col := default_color
	var i := 0
	var n := s.length()
	while i < n:
		var is_open: bool = i + 1 < n and s[i] == "{" and s[i + 1] == "{"
		var is_close: bool = i + 1 < n and s[i] == "}" and s[i + 1] == "}"
		# doubled sigil = the literal character, not a colour code (see to_bbcode)
		if i + 1 < n and (s[i] == "&" or s[i] == "^") and s[i + 1] == s[i]:
			cur += s[i]
			i += 2
			continue
		var is_amp: bool = (s[i] == "&" or s[i] == "^") and i + 1 < n
		if is_open:
			var bar := s.find("|", i + 2)
			var close := s.find("}}", i + 2)
			if bar >= 0 and (close < 0 or bar < close):
				if cur != "":
					out.append([cur, cur_col])
					cur = ""
				stack.append(color_of_code(s.substr(i + 2, bar - (i + 2)), palette, default_color))
				cur_col = amp_col if amp_on else stack[stack.size() - 1]
				i = bar + 1
				continue
			i += 2
			continue
		if is_close:
			if cur != "":
				out.append([cur, cur_col])
				cur = ""
			if stack.size() > 0:
				stack.remove_at(stack.size() - 1)
			if amp_on:
				cur_col = amp_col
			elif stack.size() > 0:
				cur_col = stack[stack.size() - 1]
			else:
				cur_col = default_color
			i += 2
			continue
		if is_amp:
			if cur != "":
				out.append([cur, cur_col])
				cur = ""
			if s[i] == "&":
				amp_col = color_of_code(s.substr(i + 1, 1), palette, default_color)
				amp_on = true
				cur_col = amp_col
			i += 2
			continue
		cur += s[i]
		i += 1
	if cur != "":
		out.append([cur, cur_col])
	return out


## One Qud colour code -> Color (palette-resolved; `default_color` when unknown).
static func color_of_code(code: String, palette: Dictionary, default_color := Color(1, 1, 1)) -> Color:
	var c := code.substr(0, 1) if code.length() > 0 else ""
	var h := String(palette.get(c, ""))
	if h == "":
		return default_color
	return Color(h if h.begins_with("#") else "#" + h)


## Qud stores its badge glyphs as raw CP437 CONTROL bytes (AV = 0x04 diamond, DV =
## 0x09 circle, damage = 0x03 heart, …) — a modern font renders those as nothing, so
## "cloth robe ♦1 ○0" arrived as "cloth robe 1 0". Map them to the real characters.
const CP437 := {
	1: "☺", 2: "☻", 3: "♥", 4: "♦", 5: "♣", 6: "♠", 7: "•", 8: "◘",
	11: "♂", 12: "♀", 14: "♫", 15: "☼",
	# 9, 10 and 13 are DELIBERATELY ABSENT. CP437 has glyphs for them (○ ◙ ♪) but in a
	# string they are tab, LINE FEED and carriage return, and Qud lays them out as
	# whitespace -- its death popup draws "You died." / blank / "You were killed by an
	# ogre ape." on three lines. Mapping 10 to ◙ turned every one of those breaks into a
	# visible glyph on one long line ("You died.◙◙You were killed by..."), which is also
	# why the box measured one 60-character line wide. Qud can only reach the real glyphs
	# through a raw control byte, which would wreck its own layout the same way.
	16: "►", 17: "◄", 18: "↕", 19: "‼", 20: "¶", 21: "§", 22: "▬", 23: "↨",
	24: "↑", 25: "↓", 26: "→", 27: "←", 28: "∟", 29: "↔", 30: "▲", 31: "▼",
	# CP437's HIGH range reaches us as the same byte reinterpreted as Latin-1, so Qud's step
	# bullet (0xF9) arrives as "ù" and renders as a literal u-grave in Source Code Pro. The quest
	# log is full of them. Only the glyphs Qud actually uses as symbols are mapped — a blanket
	# high-range translation would mangle real accented text.
	0xF9: "∙",   # CP437 249 — bullet operator: quest step markers
	0xFA: "·",   # CP437 250 — middle dot
	0xFB: "√",   # CP437 251 — the tick on a COMPLETED quest step
}

## Qud's INPUT GLYPHS, which it emits as Private Use Area codepoints and draws from its own icon
## font (ControlManager.getCommandInputDescription, and the Ctrl/Alt/Shift/LMB/RMB replacements
## further down that file). Raves renders with Source Code Pro, which has nothing at U+E8xx, so
## every one of these came out as a tofu "?" — "[?] navigate" in the picker's footer bar.
##
## The substitutes are Qud's OWN words for the same keys: its non-glyph path (mapGlyphs:false)
## writes "Ctrl", "Alt", "Shift", "LMB", "RMB" and only swaps in the icons for the modern UI. The
## two navigation entries have no text form anywhere in Qud, so they get a plain description.
##
## 1:1 NOTE: this is a legibility fallback, not pixel parity. Matching Qud exactly means extracting
## its icon font and registering the U+E8xx range as a Godot fallback — worth doing, its own job.
const GLYPHS := {
	0xE80A: "Arrows",   # NavigationXYAxis, keyboard
	0xE90A: "Stick",    # NavigationXYAxis, gamepad
	0xE816: "Ctrl",
	0xE818: "Alt",
	0xE802: "Shift",
	0xE809: "LMB",
	0xE814: "RMB",
}

static func cp437(s: String) -> String:
	var out := s
	for code in CP437:
		if out.find(String.chr(code)) >= 0:
			out = out.replace(String.chr(code), CP437[code])
	# Only substitute when we DON'T have Qud's real glyph font. Once the mod has extracted it,
	# UiFont loads it as a fallback and the codepoints render as the actual keycap icons — rewriting
	# them to words here would consume them before the font ever got a chance.
	if UiFont.qud_glyph_font() == null:
		for g in GLYPHS:
			if out.find(String.chr(g)) >= 0:
				out = out.replace(String.chr(g), GLYPHS[g])
	return out

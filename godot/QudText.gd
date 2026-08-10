class_name QudText
extends RefCounted

## Qud colour markup helpers. Qud uses TWO formats, sometimes in one string:
##   {{code|text}}  — a span (can nest), the colour is the char before '|'
##   &X             — running FOREGROUND colour for following text until the next &X (stateful)
##   ^X             — running background (we ignore it)
## `palette` maps a single-char code -> hex string.
##
## ...AND THE SPAN'S CODE IS NOT ALWAYS ONE CHARACTER. It can be a SHADER NAME —
## {{rules|…}}, {{painted|…}}, {{rocket|…}} — and this file used to resolve those by taking
## the first character, so `rules` became `r` and every rules line in every item description
## came out dark red where Qud draws it light blue (reported 2026-08-10). Qud's own registry
## is exported to shaders.json; see `_shader_table` and `_expand_shaders`.

## Render markup as Godot BBCode ([color=#hex]…[/color]), escaping stray '[' so text can't be read as
## BBCode. Unknown codes fall back to white.
static func to_bbcode(s: String, palette: Dictionary) -> String:
	s = _expand_shaders(cp437(s))
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

## A span code -> hex. A one-character code is a palette lookup; anything longer is a SHADER
## NAME and must be resolved through the registry, never by its first letter -- that shortcut
## is what painted `{{rules|…}}` dark red. `_expand_shaders` has already split the positional
## kinds into per-character spans by the time this runs, so what arrives here is flat and
## colors[0] is the whole answer. A name nothing answers to falls back to white, which is what
## Qud's own renderer does with a shader it cannot find -- NOT to the first character.
static func _hex(code: String, palette: Dictionary) -> String:
	var c := code.substr(0, 1) if code.length() > 0 else ""
	if code.length() > 1:
		var sh := _shader(code)
		c = str(sh.get("colors", " ")).substr(0, 1) if not sh.is_empty() else ""
	var h := String(palette.get(c, ""))
	return h.trim_prefix("#") if h != "" else "ffffff"


## Qud markup -> [[text, Color], …] runs, for CANVAS drawing (draw_string) where a
## RichTextLabel per row would be far too many nodes (the skills tree is ~140 rows).
## Same grammar as to_bbcode: {{code|…}} spans (nestable, inner wins) and &X codes.
## NB: written without lambdas on purpose — GDScript closures capture by VALUE, so a
## `flush` lambda appends the string as it was when the lambda was created (empty).
static func runs(s: String, palette: Dictionary, default_color := Color(1, 1, 1)) -> Array:
	s = _expand_shaders(cp437(s))
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
## Same rule as `_hex`: one character is a palette code, more than one is a SHADER NAME and
## gets resolved through the registry rather than by its first letter.
static func color_of_code(code: String, palette: Dictionary, default_color := Color(1, 1, 1)) -> Color:
	var c := code.substr(0, 1) if code.length() > 0 else ""
	if code.length() > 1:
		var sh := _shader(code)
		c = str(sh.get("colors", " ")).substr(0, 1) if not sh.is_empty() else ""
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

# ══ NAMED SHADERS ═══════════════════════════════════════════════════════════════════════
# Qud's markup accepts a shader NAME where a colour code goes, and the shader decides the
# colour PER CHARACTER. Exported by ColorsExporter off ConsoleLib.Console.MarkupShaders'
# own registry (152 of them), so this tracks the game rather than a copy of Colors.xml:
#   solid        colors[0] throughout
#   sequence     colors[i % len]                — cycles per character
#   alternation  colors[i * len / n]            — n equal bands across the run
#   bordered     colors[1] on the first and last character, else colors[0]
# All four are pure functions of position: nothing here is time-varying, so Raves can be
# exact rather than approximate.
static var _shaders: Dictionary = {}
static var _shaders_tried := false

static func _shader_table() -> Dictionary:
	if not _shaders_tried:
		_shaders_tried = true
		var p := InputModel.support_dir().path_join("shaders.json")
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			if f != null:
				var d: Variant = JSON.parse_string(f.get_as_text())
				if d is Dictionary:
					_shaders = d
	return _shaders

## The shader for a span code, or {} when the code is a plain one-character colour (or a name
## nothing in the registry answers to).
static func _shader(code: String) -> Dictionary:
	if code.length() < 2:
		return {}
	var v: Variant = _shader_table().get(code, null)
	return v if v is Dictionary else {}

## The single-char colour code this shader paints character `i` of an `n`-character run with.
## Mirrors ConsoleLib.Console.MarkupShaders one branch at a time; `/` is integer division in
## GDScript exactly as in C#, so the alternation band arithmetic transfers verbatim.
static func _shade_code(sh: Dictionary, i: int, n: int) -> String:
	var cols := str(sh.get("colors", ""))
	if cols == "":
		return ""
	var ln := cols.length()
	match str(sh.get("kind", "solid")):
		"sequence":
			return cols[i % ln]
		"alternation":
			return cols[clampi(i * ln / maxi(n, 1), 0, ln - 1)]
		"bordered":
			return cols[1] if ln > 1 and (i == 0 or i == n - 1) else cols[0]
		_:
			return cols[0]

## Rewrite every POSITIONAL shader span into one single-char span per character, so the two
## parsers below need to know nothing about shaders — a `solid` name still resolves in `_hex`
## as one flat span, which is the common case and much cheaper than a span per letter.
##
## Left alone when the run contains markup of its own or any sigil we would have to re-escape
## ({ } | & ^): a shaded run is a leaf in practice, and guessing at a nested one would corrupt
## the string. Those fall through to the flat colors[0] treatment, which is wrong only in the
## same way it was before and never worse.
static func _expand_shaders(s: String) -> String:
	if s.find("{{") < 0 or _shader_table().is_empty():
		return s
	var out := ""
	var i := 0
	var n := s.length()
	while i < n:
		if i + 1 < n and s[i] == "{" and s[i + 1] == "{":
			var bar := s.find("|", i + 2)
			var close := s.find("}}", i + 2)
			if bar >= 0 and close > bar:
				var code := s.substr(i + 2, bar - (i + 2))
				var sh := _shader(code)
				var body := s.substr(bar + 1, close - (bar + 1))
				if not sh.is_empty() and str(sh.get("kind", "solid")) != "solid" \
						and body.length() > 0 and not _has_sigil(body):
					for k in body.length():
						var c := _shade_code(sh, k, body.length())
						out += ("{{%s|%s}}" % [c, body[k]]) if c != "" else body[k]
					i = close + 2
					continue
		out += s[i]
		i += 1
	return out

static func _has_sigil(s: String) -> bool:
	for ch in "{}|&^":
		if s.find(ch) >= 0:
			return true
	return false

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

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

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


## Qud markup -> [[text, Color], …] runs, for CANVAS drawing (draw_string) where a
## RichTextLabel per row would be far too many nodes (the skills tree is ~140 rows).
## Same grammar as to_bbcode: {{code|…}} spans (nestable, inner wins) and &X codes.
## NB: written without lambdas on purpose — GDScript closures capture by VALUE, so a
## `flush` lambda appends the string as it was when the lambda was created (empty).
static func runs(s: String, palette: Dictionary, default_color := Color(1, 1, 1)) -> Array:
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

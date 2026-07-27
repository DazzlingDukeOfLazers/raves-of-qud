extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column. Computed CLIENT-SIDE from the
## snapshot's cells + player position (no mod change needed — the data is already on the wire): every
## non-ground object in the zone, deduped by display name, showing the NEAREST one's direction and a
## count, sorted nearest-first. Refine the filter (what counts as "notable") from here as we tune it.

const MAX_ROWS := 25
const RADIUS := 1   # king-move radius; 1 = the 3x3 (9 tiles) around the player. NOTE: the whole-zone
                    # scan (RADIUS = zone size) is the basis for the future Points of Interest menu.

var _rt: RichTextLabel

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var title := Label.new()
	title.text = "Nearby objects"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	v.add_child(title)
	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = false
	_rt.scroll_active = true
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs `cells` + `player`).
func set_snapshot(data: Dictionary) -> void:
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return
	var found := {}   # display name -> {arrow, glyph, dist, count}
	for cell in data.get("cells", []):
		var dx := int(cell.get("x", 0)) - px
		var dy := int(cell.get("y", 0)) - py
		var dist: int = maxi(absi(dx), absi(dy))   # Chebyshev (king-move) distance
		if dist > RADIUS:
			continue
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue                   # skip painted ground
			if dist == 0 and bool(obj.get("creature", false)):
				continue                   # that's the player, on their own cell
			var nm := String(obj.get("display", ""))
			if nm == "":
				nm = String(obj.get("name", ""))
			if nm == "" or nm == "[painted ground]":
				continue
			if found.has(nm):
				found[nm]["count"] += 1
				if dist < found[nm]["dist"]:
					found[nm]["dist"] = dist
					found[nm]["arrow"] = _arrow(dx, dy)
			else:
				found[nm] = {"arrow": _arrow(dx, dy), "glyph": String(obj.get("glyph", "")), "dist": dist, "count": 1}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])
	var lines: Array[String] = []
	for i in mini(names.size(), MAX_ROWS):
		var nm: String = names[i]
		var e: Dictionary = found[nm]
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		lines.append("%s %s %s%s" % [e["arrow"], e["glyph"], nm, suffix])
	_rt.text = "\n".join(lines)

## Compass ARROW from a cell offset (y increases SOUTH). Within RADIUS 1 this is exactly the 8
## neighbours plus the centre.
func _arrow(dx: int, dy: int) -> String:
	if dx == 0 and dy == 0:
		return "·"                      # on your own tile
	if dx == 0:
		return "↑" if dy < 0 else "↓"
	if dy == 0:
		return "→" if dx > 0 else "←"
	if dx > 0:
		return "↗" if dy < 0 else "↘"
	return "↖" if dy < 0 else "↙"

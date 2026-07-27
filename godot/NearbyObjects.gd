extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column. Computed CLIENT-SIDE from the
## snapshot's cells + player position (no mod change needed — the data is already on the wire): every
## non-ground object in the zone, deduped by display name, showing the NEAREST one's direction and a
## count, sorted nearest-first. Refine the filter (what counts as "notable") from here as we tune it.

const MAX_ROWS := 25

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
	var found := {}   # display name -> {dir, dist, count}
	for cell in data.get("cells", []):
		var dx := int(cell.get("x", 0)) - px
		var dy := int(cell.get("y", 0)) - py
		if dx == 0 and dy == 0:
			continue                       # the player's own cell
		var dist: int = maxi(absi(dx), absi(dy))   # Chebyshev (king-move) distance
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue                   # skip painted ground
			var nm := String(obj.get("display", ""))
			if nm == "":
				nm = String(obj.get("name", ""))
			if nm == "" or nm == "[painted ground]":
				continue
			if found.has(nm):
				found[nm]["count"] += 1
				if dist < found[nm]["dist"]:
					found[nm]["dist"] = dist
					found[nm]["dir"] = _dir(dx, dy)
			else:
				found[nm] = {"dir": _dir(dx, dy), "dist": dist, "count": 1}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])
	var lines: Array[String] = []
	for i in mini(names.size(), MAX_ROWS):
		var nm: String = names[i]
		var e: Dictionary = found[nm]
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		lines.append("%-2s  %s%s" % [e["dir"], nm, suffix])
	_rt.text = "\n".join(lines)

## 8-way compass direction from a cell offset (y increases SOUTH, as in Qud/the snapshot).
func _dir(dx: int, dy: int) -> String:
	var ax := absi(dx)
	var ay := absi(dy)
	var h := "E" if dx > 0 else ("W" if dx < 0 else "")
	var vv := "S" if dy > 0 else ("N" if dy < 0 else "")
	if ax > ay * 2:
		return h
	if ay > ax * 2:
		return vv
	return vv + h   # diagonal, e.g. "NE"

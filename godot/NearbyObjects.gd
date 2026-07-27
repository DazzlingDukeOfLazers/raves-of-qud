extends PanelContainer

## Nearby objects view — its own scene in MainFrame's row-3 side column. Computed CLIENT-SIDE from the
## snapshot's cells + player position: objects within RADIUS, deduped by (stripped) display name,
## showing the NEAREST one's arrow direction, its recoloured TILE image, and a count. Sorted nearest.
##
## NOTE: the whole-zone scan (RADIUS = zone size) is the basis for the future Points of Interest menu.

const MAX_ROWS := 25
const RADIUS := 1   # king-move radius; 1 = the 3x3 (9 tiles) around the player

var _rt: RichTextLabel
var _tiles: RefCounted   # shared tile recolouring + colour resolution (QudTiles), set in _ready
var _palette := {}       # for rendering coloured names via QudText
var _full := false       # perceived icon (default) vs real — driven by MainFrame's top-menu toggle
var _last_data := {}     # last snapshot, so a mode toggle re-renders without waiting for a new one

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
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
	_rt.bbcode_enabled = true             # names are rendered in their Qud colours
	_rt.scroll_active = true
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot with the full data (needs cells + player + tilesDir + palette).
func set_snapshot(data: Dictionary) -> void:
	_last_data = data
	var pal: Dictionary = data.get("palette", {})
	if not pal.is_empty():
		_palette = pal
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_tiles.palette = _palette
	var p: Dictionary = data.get("player", {})
	var px := int(p.get("x", -1))
	var py := int(p.get("y", -1))
	if px < 0 or py < 0:
		return

	var found := {}   # display name -> {arrow, glyph, tile, main, detail, dist, count}
	for cell in data.get("cells", []):
		var dx := int(cell.get("x", 0)) - px
		var dy := int(cell.get("y", 0)) - py
		var dist: int = maxi(absi(dx), absi(dy))
		if dist > RADIUS:
			continue
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue
			if dist == 0 and bool(obj.get("creature", false)):
				continue                   # the player, on their own cell
			var raw := String(obj.get("display", ""))
			var nm := QudText.strip(raw)      # stripped = stable dedup key
			if nm == "":
				nm = String(obj.get("name", ""))
				raw = nm
			if nm == "" or nm == "[painted ground]":
				continue
			if found.has(nm):
				found[nm]["count"] += 1
				if dist < found[nm]["dist"]:
					found[nm]["dist"] = dist
					found[nm]["arrow"] = _arrow(dx, dy)
			else:
				found[nm] = {
					"arrow": _arrow(dx, dy), "raw": raw, "obj": obj,
					"dist": dist, "count": 1,
				}

	var names: Array = found.keys()
	names.sort_custom(func(a, b): return found[a]["dist"] < found[b]["dist"])

	var img_h := UiFont.px(get_viewport(), "body")
	var img_w := int(round(img_h * 16.0 / 24.0))   # Qud tiles are 16x24
	_rt.clear()
	for i in mini(names.size(), MAX_ROWS):
		var e: Dictionary = found[names[i]]
		var o: Dictionary = e["obj"]
		_rt.append_text(String(e["arrow"]) + " ")
		# Perceived icon by default (unidentified -> "unknown" tile via tileP); real tile in full mode.
		var tex: Texture2D = _tiles.texture_for(o, _full)
		if tex != null:
			_rt.add_image(tex, img_w, img_h)
		else:
			_rt.append_text(_tiles.glyph_for(o, _full).replace("[", "[lb]"))   # fallback glyph
		var suffix: String = ("  ×%d" % e["count"]) if e["count"] > 1 else ""
		_rt.append_text(" " + QudText.to_bbcode(String(e["raw"]), _palette) + suffix + "\n")

## Driven by MainFrame's global top-menu toggle: perceived icons (default) vs the real ones.
func set_full_info(full: bool) -> void:
	_full = full
	if not _last_data.is_empty():
		set_snapshot(_last_data)

## Compass ARROW from a cell offset (y increases SOUTH). Within RADIUS 1 this is exactly the 8
## neighbours plus the centre.
func _arrow(dx: int, dy: int) -> String:
	if dx == 0 and dy == 0:
		return "·"
	if dx == 0:
		return "↑" if dy < 0 else "↓"
	if dy == 0:
		return "→" if dx > 0 else "←"
	if dx > 0:
		return "↗" if dy < 0 else "↘"
	return "↖" if dy < 0 else "↙"

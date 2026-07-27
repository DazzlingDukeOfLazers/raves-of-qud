extends PanelContainer

## The Message log view — its own scene, hosted in MainFrame's row-3 side column. Fed each snapshot
## via set_messages(lines, total).
##
## VERBATIM (default): Qud's recent log lines as-is, newest at the bottom, auto-scrolled.
##
## FILTER: one line per UNIQUE message on screen. A repeat increments its "(xN)" count and drops the
## line to the bottom (most-recent). A line that stops appearing survives FILTER_GRACE quiet rounds,
## then its count is subtracted by 1 each round until it hits 0 and drops off — so repeated/important
## lines linger, one-offs fade. A "round" is a snapshot that carried NEW messages (≈ a turn); idle
## render ticks don't decay anything.

const MAX_LINES := 200
const FILTER_GRACE := 4   # quiet rounds a line survives before its count starts decaying

var _filter := false
var _last_msgs: Array = []       # last verbatim tail (for verbatim render + delta)
var _entries: Array = []         # filter state: [{text, count, quiet, seen}]
var _seen_total := -1            # total message count last processed (-1 = not yet initialised)
var _palette := {}   # Qud colour code -> hex, for rendering {{code|text}} markup
var _rt: RichTextLabel
var _toggle: Button
var _tiles: RefCounted           # shared tile recolouring for inline message icons (set in _ready)
var _name_index := {}            # lowercased object name -> object dict (current zone), for icon matching
var _landmark_index := {}        # lowercased landmark/biome name -> world-terrain dict, ACCUMULATED across travel
var _player_obj := {}            # the player's render, for the "you" pictograph
var _full := false               # perceived icons (default) vs real — driven by MainFrame's top-menu toggle

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

	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "Message log"
	title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_toggle = Button.new()
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_toggle_mode)
	head.add_child(_toggle)
	_refresh_toggle()

	_rt = RichTextLabel.new()
	_rt.bbcode_enabled = true            # we convert Qud {{colour|text}} markup to BBCode
	_rt.scroll_active = true
	_rt.scroll_following = true            # stay pinned to the newest line
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot: `lines` = the verbatim tail (with {{colour|text}} markup),
## `total` = Qud's total message count (to diff for NEW lines), `palette` = colour code -> hex.
func set_messages(lines: Array, total: int, palette: Dictionary, data := {}) -> void:
	_last_msgs = lines
	if not palette.is_empty():
		_palette = palette
	_tiles.palette = _palette
	_tiles.tiles_dir = String(data.get("tilesDir", _tiles.tiles_dir))
	_build_name_index(data)
	_player_obj = data.get("player", {})
	# Accumulate the current location's world-terrain (Salt marsh, Red Rock, …) — persists across travel,
	# so a log line naming a landmark we've visited can show its world tile.
	var wt: Dictionary = data.get("worldTerrain", {})
	if not wt.is_empty():
		var wn := QudText.strip(String(wt.get("name", ""))).to_lower().strip_edges()
		if wn != "":
			_landmark_index[wn] = wt
	_ingest(lines, total)   # keep filter state warm even in verbatim mode
	_rerender()

## Driven by MainFrame's global top-menu toggle: perceived icons (default) vs the real ones.
func set_full_info(full: bool) -> void:
	_full = full
	_rerender()

## Index the zone's objects by lowercased display name -> object dict, so a log line's text can be
## matched to a tile. First occurrence wins; ground is skipped.
func _build_name_index(data: Dictionary) -> void:
	if not data.has("cells"):
		return                          # this call carried no cells — keep the previous index
	_name_index.clear()
	for cell in data.get("cells", []):
		for obj in cell.get("objs", []):
			if bool(obj.get("ground", false)):
				continue
			var nm := QudText.strip(String(obj.get("display", ""))).to_lower().strip_edges()
			if nm == "" or nm == "[painted ground]":
				continue
			if not _name_index.has(nm):
				_name_index[nm] = obj

## Fold this snapshot's NEW messages into the filter state and age the rest.
func _ingest(lines: Array, total: int) -> void:
	if _seen_total < 0:
		_seen_total = total   # first snapshot: start fresh; don't replay the whole backlog
		return
	var new_n: int = clampi(total - _seen_total, 0, lines.size())
	_seen_total = total
	if new_n <= 0:
		return                # nothing new -> not a round -> no decay
	var fresh: Array = lines.slice(lines.size() - new_n)

	for e in _entries:
		e["seen"] = false
	for m in fresh:
		var s := String(m)
		var hit: Dictionary = {}
		for e in _entries:
			if e["text"] == s:
				hit = e
				break
		if hit.is_empty():
			_entries.append({"text": s, "count": 1, "quiet": 0, "seen": true})
		else:
			hit["count"] += 1
			hit["quiet"] = 0
			hit["seen"] = true
			_entries.erase(hit)     # drop to the bottom (most-recent)
			_entries.append(hit)

	# age lines that didn't appear this round; decay + drop after the grace period
	var survivors: Array = []
	for e in _entries:
		if e["seen"]:
			survivors.append(e)
			continue
		e["quiet"] += 1
		if e["quiet"] > FILTER_GRACE:
			e["count"] -= 1
		if e["count"] > 0:
			survivors.append(e)
	_entries = survivors

func _rerender() -> void:
	if _filter:
		_render_filter()
	else:
		_render_verbatim()

func _render_verbatim() -> void:
	var src: Array = _last_msgs
	if src.size() > MAX_LINES:
		src = src.slice(src.size() - MAX_LINES)
	_rt.clear()
	for m in src:
		_append_line(String(m))

func _render_filter() -> void:
	_rt.clear()
	for e in _entries:
		var c: int = e["count"]
		_append_line(String(e["text"]) + ("  (x%d)" % c if c > 1 else ""))

## Append one log line: if its text names a zone object, inline that object's icon first (perceived
## or real per the global toggle), then the coloured text.
func _append_line(markup: String) -> void:
	var obj := _icon_obj_for(markup)
	if not obj.is_empty():
		var tex: Texture2D = _tiles.texture_for(obj, _full)
		if tex != null:
			var img_h := UiFont.px(get_viewport(), "body") * 2   # doubled — a chunky inline pictograph
			_rt.add_image(tex, int(round(img_h * 16.0 / 24.0)), img_h)
			_rt.append_text(" ")
	_rt.append_text(QudText.to_bbcode(markup, _palette) + "\n")

## The icon for a log line: the LONGEST object/landmark name contained in the line's plain text (so
## "brinestalk wall" beats bare "wall", "Red Rock" beats nothing), else — if the line is about "you" —
## the player's own icon, else {}.
func _icon_obj_for(markup: String) -> Dictionary:
	var plain := QudText.strip(markup).to_lower()
	var best := ""
	var best_obj := {}
	for src in [_name_index, _landmark_index]:
		for nm in src:
			if nm.length() > best.length() and plain.contains(nm):
				best = nm
				best_obj = src[nm]
	if not best_obj.is_empty():
		return best_obj
	if not _player_obj.is_empty() and plain.contains("you"):
		return _player_obj    # self-referential line with no named object -> the "you" pictograph
	return {}

func _toggle_mode() -> void:
	_filter = not _filter
	_refresh_toggle()
	_rerender()

func _refresh_toggle() -> void:
	if _toggle != null:
		_toggle.text = "filter" if _filter else "verbatim"
		_toggle.tooltip_text = "Switch to %s mode" % ("verbatim" if _filter else "filter")

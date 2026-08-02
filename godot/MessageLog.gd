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

## 1:1 only: dragging the ||| grab-bar (the panel's left margin) resizes the sidebar. MainFrame connects
## this and adjusts the side-column width. dx = mouse motion in px (negative = dragged left = wider log).
signal left_edge_drag(dx: float)
var _dragging := false

var _filter := false
var _last_msgs: Array = []       # last verbatim tail (for verbatim render + delta)
var _since_load := -1            # count of msgs emitted since Qud loaded (1:1 log trims to this; -1 = all)
var _entries: Array = []         # filter state: [{text, count, quiet, seen}]
var _seen_total := -1            # total message count last processed (-1 = not yet initialised)
var _palette := {}   # Qud colour code -> hex, for rendering {{code|text}} markup
var _rt: RichTextLabel
var _title: Label                # "Message log" heading — sized "title" in user mode, "body" (= messages) in 1:1
var _toggle: Button
var _tiles: RefCounted           # shared tile recolouring for inline message icons (set in _ready)
var _name_index := {}            # lowercased object name -> object dict (current zone), for icon matching
var _landmark_index := {}        # lowercased landmark/biome name -> world-terrain dict, ACCUMULATED across travel
var _player_obj := {}            # the player's render, for the "you" pictograph
var _full := false               # perceived icons (default) vs real — driven by MainFrame's top-menu toggle
var _notice := ""                # sticky status line (BBCode) pinned at the BOTTOM — e.g. the mod-version check

func _ready() -> void:
	_tiles = load("res://QudTiles.gd").new()
	_apply_panel_box()   # user mode = framed QoL box; 1:1 = borderless + room for the ||| grab-bar

	resized.connect(queue_redraw)   # the ||| grab-bar spans the panel height — redraw when it changes

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)

	var head := HBoxContainer.new()
	v.add_child(head)
	_title = Label.new()
	_title.text = "Message log"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
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
	_apply_log_style()

## Uniform panel entry (MainFrame feeds every panel via set_snapshot).
func set_snapshot(data: Dictionary) -> void:
	set_messages(data.get("messages", []), int(data.get("msgCount", 0)), data.get("palette", {}), data)

## `lines` = the verbatim tail (with {{colour|text}} markup), `total` = Qud's total message count (to
## diff for NEW lines), `palette` = colour code -> hex.
func set_messages(lines: Array, total: int, palette: Dictionary, data := {}) -> void:
	_last_msgs = lines
	_since_load = int(data.get("msgSinceLoad", -1))   # -1 (old mod) = show all; else Qud's since-load window
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

## 1:1 (parity) mode: render the Qud-faithful log — verbatim colored text, NO inline pictographs and no
## verbatim/filter toggle (Qud has neither). Reverting restores the QoL icons + toggle.
var _one_to_one := false
var _saved_filter := false   # user's verbatim/filter choice, restored when leaving 1:1
## Qud draws its whole message log — the "Message log" heading AND the lines — at ~0.76x the body UI font
## (measured 16px vs 21px at 1080), the heading in a dim teal. Match both in 1:1; user mode keeps the
## larger "title" heading + body-size lines in the default colour.
const LOG_FONT_FRAC_1TO1 := 0.76
const TITLE_COLOR_1TO1 := Color8(59, 89, 107)     # Qud's dim grey-teal "Message log" heading
# Qud's grab-bar between the playfield and the log: three vertical lines "|||", the outer two a lighter
# teal, the centre a darker grey-teal (measured off Qud). Drawn in the panel's left margin in 1:1.
const SEP_OUTER := Color8(68, 99, 112)
const SEP_CENTER := Color8(30, 57, 72)
const SEP_MARGIN_1TO1 := 20                       # left content inset so text clears the ||| bar

## The panel background: user mode keeps the framed QoL box; 1:1 drops the border (Qud shows none) and
## insets the content so the ||| grab-bar (drawn in _draw) sits in the left margin.
func _apply_panel_box() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(17, 33, 38) if _one_to_one else QudPalette.CHROME   # Qud's dark blue-grey log bg
	sb.content_margin_left = SEP_MARGIN_1TO1 if _one_to_one else 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	if not _one_to_one:
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.12)
		sb.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", sb)
	# resize cursor over the ||| margin (the RichTextLabel child overrides it with the I-beam over text)
	mouse_default_cursor_shape = Control.CURSOR_HSIZE if _one_to_one else Control.CURSOR_ARROW

## Make the whole ||| grab-bar (the left content margin) a resize handle in 1:1. The RichTextLabel child
## keeps its I-beam over the text; only the uncovered margin gets this panel's HSIZE cursor + drag.
func _gui_input(e: InputEvent) -> void:
	if not _one_to_one:
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and e.position.x < float(SEP_MARGIN_1TO1):
			_dragging = true
			accept_event()
		elif not e.pressed:
			_dragging = false
	elif e is InputEventMouseMotion and _dragging:
		left_edge_drag.emit(e.relative.x)
		accept_event()

## 1:1 only: draw Qud's "|||" grab-bar down the panel's left edge (behind the inset content).
func _draw() -> void:
	if not _one_to_one:
		return
	var h := size.y
	# crisp 1px columns (draw_rect on integer x, not a half-pixel draw_line, so the teal isn't dimmed)
	draw_rect(Rect2(2, 0, 1, h), SEP_OUTER)
	draw_rect(Rect2(6, 0, 1, h), SEP_CENTER)
	draw_rect(Rect2(10, 0, 1, h), SEP_OUTER)

func _apply_log_style() -> void:
	var body := UiFont.px(get_viewport(), "body")
	if _one_to_one:
		var sz := int(round(body * LOG_FONT_FRAC_1TO1))
		if _title != null:
			_title.add_theme_font_size_override("font_size", sz)
			_title.add_theme_color_override("font_color", TITLE_COLOR_1TO1)
		if _rt != null:
			_rt.add_theme_font_size_override("normal_font_size", sz)
			_rt.add_theme_font_size_override("bold_font_size", sz)
	else:
		if _title != null:
			_title.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
			_title.remove_theme_color_override("font_color")
		if _rt != null:
			_rt.remove_theme_font_size_override("normal_font_size")
			_rt.remove_theme_font_size_override("bold_font_size")

func set_one_to_one(on: bool) -> void:
	if on == _one_to_one:
		return
	_one_to_one = on
	_apply_log_style()
	_apply_panel_box()
	queue_redraw()          # (re)draw or clear the ||| grab-bar for the new mode
	if _toggle != null:
		_toggle.visible = not on
	if on:
		_saved_filter = _filter
		_filter = false          # Qud shows the raw recent log, newest at the bottom
	else:
		_filter = _saved_filter  # restore the user's log mode
		_refresh_toggle()
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
		# First snapshot: SEED the filter from the visible backlog (deduped) so filter mode is useful
		# immediately, then track new messages from here. (Was starting empty, which read as "broken"
		# until enough new messages had trickled in.)
		_seed_from(lines)
		_seen_total = total
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

## Build the initial filter state from a backlog of lines: one entry per unique message, count = repeats,
## newest-last. Used to seed on connect so filter isn't empty.
func _seed_from(lines: Array) -> void:
	_entries.clear()
	for m in lines:
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
			_entries.erase(hit)
			_entries.append(hit)   # keep most-recent at the bottom

## A sticky status line pinned at the BOTTOM of the log (always visible under scroll_following) — used
## for the mod-version check. Pass "" to clear it. Idempotent, so callers can set it every snapshot.
func set_notice(markup: String) -> void:
	if markup == _notice:
		return
	_notice = markup
	_rerender()

func _rerender() -> void:
	if _filter:
		_render_filter()
	else:
		_render_verbatim()
	if _notice != "":
		# separated from the message flow and pinned last, so it doesn't scroll away like a game message
		_rt.append_text("\n" + _notice)

func _render_verbatim() -> void:
	var src: Array = _last_msgs
	# 1:1: Qud's sidebar is cleared on load and shows only messages emitted since — not the save's backlog.
	# Trim to the mod's since-load count so the history length matches. User mode keeps the full backlog.
	if _one_to_one and _since_load >= 0 and _since_load < src.size():
		src = src.slice(src.size() - _since_load)
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

## Qud's sidebar prefixes every log line with ":: " in a dim neutral grey (measured #818181), then the
## message in its own colour. Only in 1:1 mode — user mode keeps the clean, prefix-free QoL log.
const LOG_PREFIX_1TO1 := "[color=#818181]:: [/color]"

## Append one log line: if its text names a zone object, inline that object's icon first (perceived
## or real per the global toggle), then the coloured text.
func _append_line(markup: String) -> void:
	if not _one_to_one:   # QoL only: inline the object/landmark pictograph. Qud's log is plain text.
		var img_h := UiFont.px(get_viewport(), "body") * 2   # doubled — chunky inline pictographs
		var img_w := int(round(img_h * 16.0 / 24.0))
		for obj in _icons_for(markup):
			var tex: Texture2D = _tiles.texture_for(obj, _full)
			if tex != null:
				_rt.add_image(tex, img_w, img_h)
				_rt.append_text(" ")
	var prefix := LOG_PREFIX_1TO1 if _one_to_one else ""   # ":: " sidebar prefix, Qud-faithful (1:1 only)
	_rt.append_text(prefix + QudText.to_bbcode(markup, _palette) + "\n")

## The icons for a log line, in order: the player's own icon FIRST if the line says "you" (the subject),
## then the object/landmark whose (lowercased) name is the LONGEST one in the line ("brinestalk wall"
## beats bare "wall", "Red Rock" beats a stray "rock"). Either may be absent.
func _icons_for(markup: String) -> Array:
	var out: Array = []
	var plain := QudText.strip(markup).to_lower()
	if not _player_obj.is_empty() and plain.contains("you"):
		out.append(_player_obj)
	var best := ""
	var best_obj := {}
	for src in [_name_index, _landmark_index]:
		for nm in src:
			if nm.length() > best.length() and plain.contains(nm):
				best = nm
				best_obj = src[nm]
	if not best_obj.is_empty():
		out.append(best_obj)
	return out

func _toggle_mode() -> void:
	_filter = not _filter
	_refresh_toggle()
	_rerender()

func _refresh_toggle() -> void:
	if _toggle != null:
		_toggle.text = "filter" if _filter else "verbatim"
		_toggle.tooltip_text = "Switch to %s mode" % ("verbatim" if _filter else "filter")

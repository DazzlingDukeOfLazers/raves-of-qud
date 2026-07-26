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
var _rt: RichTextLabel
var _toggle: Button

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
	_rt.bbcode_enabled = false
	_rt.scroll_active = true
	_rt.scroll_following = true            # stay pinned to the newest line
	_rt.selection_enabled = true
	_rt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_rt)

## MainFrame calls this each snapshot: `lines` = the verbatim tail, `total` = Qud's total message
## count (so we can tell which tail lines are NEW since last snapshot).
func set_messages(lines: Array, total: int) -> void:
	_last_msgs = lines
	_ingest(lines, total)   # keep filter state warm even in verbatim mode
	_rerender()

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
	var out: Array[String] = []
	for m in src:
		out.append(String(m))
	_rt.text = "\n".join(out)

func _render_filter() -> void:
	var out: Array[String] = []
	for e in _entries:
		var c: int = e["count"]
		out.append(String(e["text"]) + ("  (x%d)" % c if c > 1 else ""))
	_rt.text = "\n".join(out)

func _toggle_mode() -> void:
	_filter = not _filter
	_refresh_toggle()
	_rerender()

func _refresh_toggle() -> void:
	if _toggle != null:
		_toggle.text = "filter" if _filter else "verbatim"
		_toggle.tooltip_text = "Switch to %s mode" % ("verbatim" if _filter else "filter")

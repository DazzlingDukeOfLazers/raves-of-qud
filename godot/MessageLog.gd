extends PanelContainer

## The Message log view — its own scene, hosted in MainFrame's row-3 side column. Fed the snapshot's
## `messages` (Qud's recent log lines) via set_messages().
##
## VERBATIM (default): shows the lines as-is, newest at the bottom, auto-scrolled.
## TERSE (header toggle — WORK IN PROGRESS): the full design is one line per UNIQUE message on screen;
## a repeat drops to the bottom and increments a "(xN)" counter; after X quiet rounds the counts decay
## and the line drops off. For now terse only collapses consecutive duplicates, and says so — we'll
## finish the real behaviour next.

const MAX_LINES := 200

var _terse := false
var _last_msgs: Array = []
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

	# header: title + verbatim/terse toggle
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

## Called by MainFrame each snapshot with the `messages` array (verbatim Qud lines).
func set_messages(msgs: Array) -> void:
	_last_msgs = msgs
	_rerender()

func _rerender() -> void:
	if _terse:
		_render_terse()
	else:
		_render_verbatim()

func _render_verbatim() -> void:
	var src: Array = _last_msgs
	if src.size() > MAX_LINES:
		src = src.slice(src.size() - MAX_LINES)
	var lines: Array[String] = []
	for m in src:
		lines.append(String(m))
	_rt.text = "\n".join(lines)

## WIP stub: collapse only CONSECUTIVE duplicates with a "(xN)" count, so terse reads differently from
## verbatim. The full spec (unique-per-screen, repeat-drops-to-bottom, decay-off) comes next.
func _render_terse() -> void:
	var out: Array[String] = []
	var prev := ""
	var count := 0
	for m in _last_msgs:
		var s := String(m)
		if s == prev:
			count += 1
		else:
			if prev != "":
				out.append(prev + ("  (x%d)" % count if count > 1 else ""))
			prev = s
			count = 1
	if prev != "":
		out.append(prev + ("  (x%d)" % count if count > 1 else ""))
	_rt.text = "\n".join(out) + "\n\n— terse mode is a work in progress —"

func _toggle_mode() -> void:
	_terse = not _terse
	_refresh_toggle()
	_rerender()

func _refresh_toggle() -> void:
	if _toggle != null:
		_toggle.text = "terse" if _terse else "verbatim"
		_toggle.tooltip_text = "Switch to %s mode" % ("verbatim" if _terse else "terse")

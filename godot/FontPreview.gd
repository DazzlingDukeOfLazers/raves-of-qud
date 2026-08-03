extends CanvasLayer
class_name FontPreview

## A quick font-size ruler: one line of Lorem Ipsum per size, labelled with its px, so you can eyeball
## which sizes read well and pick the app's MINIMUM and NORMAL sizes. Toggle it, read the numbers back,
## and those map to Main's MIN_FONT (absolute floor) and FONT_FRAC (size = viewport_height x FONT_FRAC).
## Uses the SAME font path as the app's main UI (default font, size-only override) so the preview is
## faithful. Most useful in the exported (crisp) build.

const LOREM := "Lorem ipsum dolor sit amet, consectetur adipiscing — Sultan 0123456789"
const SIZES := [10, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 44]

var _header: Label
var _built := false

func toggle(header_text: String) -> void:
	if not _built:
		_build()
		_built = true
	_header.text = header_text
	visible = not visible

func _build() -> void:
	layer = 4   # above the debug menu (2) and onboarding (3)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # modal: eat clicks
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.05, 0.98)
	sb.border_color = Color(0.45, 0.85, 0.55, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))  # chrome (sample lines below are literal px)
	_header.modulate = Color(0.65, 0.95, 0.7)
	vb.add_child(_header)

	var rule := HSeparator.new()
	vb.add_child(rule)

	for s in SIZES:
		var l := Label.new()
		l.text = "%2dpx   %s" % [s, LOREM]
		l.add_theme_font_size_override("font_size", s)
		l.modulate = Color(0.85, 0.92, 0.85)
		vb.add_child(l)

	var hint := Label.new()
	hint.text = "→ Tell me which px reads as the MINIMUM and which as the NORMAL size; I'll set MIN_FONT + FONT_FRAC. (toggle again to close)"
	hint.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "body"))   # chrome; sample lines stay literal
	hint.modulate = Color(0.95, 0.85, 0.5)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(900, 0)
	vb.add_child(hint)

	visible = false

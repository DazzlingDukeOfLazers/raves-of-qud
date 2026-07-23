extends Node3D
class_name ZoneRenderer

## Renders a zone snapshot as billboarded glyphs on a 3D grid.
## MVP uses Label3D (one per visible object) so it runs with ZERO Qud assets —
## swap to Sprite3D pointed at the player's own local tile PNGs later.

const CELL := 1.0        # world units per Qud cell
const LAYER_STEP := 0.02 # tiny Y offset so stacked objects don't z-fight

var _pool: Array[Label3D] = []
var _active: Array[Label3D] = []

func render_snapshot(data: Dictionary) -> void:
	# MVP: recycle all labels and repopulate. Diff-based updates are a v2 win.
	for lbl in _active:
		lbl.visible = false
		_pool.append(lbl)
	_active.clear()

	for cell in data.get("cells", []):
		var cx := int(cell.get("x", 0))
		var cy := int(cell.get("y", 0))
		var idx := 0
		for obj in cell.get("objs", []):
			var lbl := _take_label()
			lbl.text = String(obj.get("glyph", "?"))
			lbl.modulate = _qud_color(String(obj.get("color", "")))
			lbl.position = Vector3(cx * CELL, idx * LAYER_STEP, cy * CELL)
			lbl.visible = true
			_active.append(lbl)
			idx += 1

func _take_label() -> Label3D:
	if _pool.size() > 0:
		return _pool.pop_back()
	var lbl := Label3D.new()
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.pixel_size = 0.02
	lbl.font_size = 64
	lbl.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	add_child(lbl)
	return lbl

# Qud's 16-color palette. IMPORTANT non-obvious mapping (from Base/Colors.xml):
#   Y = white, y = gray, K = black; W = GOLD/yellow, w = BROWN; O/o = orange.
# Qud color strings look like "&Y" / "y"; we key off the trailing letter.
# RGB values approximate Qud's console palette — refine to exact hex later.
const COLORS := {
	"r": Color(0.60, 0.20, 0.15), "R": Color(1.00, 0.30, 0.30),  # dark red / red
	"g": Color(0.00, 0.50, 0.00), "G": Color(0.20, 0.90, 0.20),  # dark green / green
	"b": Color(0.00, 0.00, 0.60), "B": Color(0.25, 0.45, 1.00),  # dark blue / blue
	"c": Color(0.00, 0.55, 0.55), "C": Color(0.40, 1.00, 1.00),  # dark cyan / cyan
	"m": Color(0.55, 0.00, 0.55), "M": Color(1.00, 0.40, 1.00),  # dark magenta / magenta
	"w": Color(0.60, 0.40, 0.10), "W": Color(1.00, 0.82, 0.00),  # brown / gold
	"o": Color(0.70, 0.35, 0.00), "O": Color(1.00, 0.55, 0.00),  # dark orange / orange
	"y": Color(0.70, 0.70, 0.70), "Y": Color(1.00, 1.00, 1.00),  # gray / white
	"k": Color(0.10, 0.10, 0.10), "K": Color(0.10, 0.10, 0.10),  # black
}

func _qud_color(code: String) -> Color:
	var c := code.strip_edges()
	if c.is_empty():
		return Color.WHITE
	var ch := c.substr(c.length() - 1, 1)
	return COLORS.get(ch, Color.WHITE)

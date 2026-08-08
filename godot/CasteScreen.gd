extends "res://ChargenCardScreen.gd"

## CHARACTER CREATION — SUBTYPE, as Qud actually draws it: the same horizontal card carousel as
## Choose Game Mode and Choose Genotype, with a row of dash-ruled CATEGORY BANDS inserted above the
## cards when the subtype class is grouped.
##
## Replaces SubtypeScreen.gd, which answered this stage with a bordered panel — a scrim over the
## title art, a gold "◈ Choose Caste ◈" header, a scrolling left list of icon+name rows and a right
## detail pane. Its DATA was right (the same twelve castes, the same three arcologies, the same
## bullets straight out of GetChargenInfo) and none of its presentation was: Qud has no panel, no
## scrim, no list and no detail pane on this screen. Nothing here is new information about the game;
## it is the existing chargen.json feed poured into the existing card template.
##
## Serves BOTH branches. True Kin get "Castes" — twelve, in three arcologies, so the band row shows.
## Mutated Human get "Callings", a single ungrouped category, and `_category_bands` returns empty for
## it, which collapses this back to exactly the plain carousel the other two stages use.

## Set by the flow before _ready: "Castes" / "Callings", plus the genotype name for the breadcrumb.
var subtype_class := ""
var genotype_name := ""
## Optional breadcrumb override — [{label, current}], left→right. Empty = the default trail.
var crumbs: Array = []

const HOTKEYS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

var _class_cache := {}
## tile -> Qud detail colour code, filled by _load_items so _card_icon can look one up. Keyed by TILE
## rather than name because that is what _card_icon is handed, and tiles are unique per caste.
var _detail_by_tile := {}

func _screen_node_name() -> String: return "CasteScreen"

func _subtitle() -> String:
	# Qud's own subtitle for the class ("choose caste" / "choose calling"), never a guess: the mod
	# ships chargenTitle alongside the categories precisely so this line is the game's wording.
	var t := str(_class().get("chargenTitle", "")).strip_edges()
	return ":%s:" % (t.to_lower() if t != "" else "choose subtype")

func _breadcrumb_crumbs() -> Array:
	if not crumbs.is_empty():
		return crumbs
	var here := "Caste" if subtype_class == "Castes" else "Calling"
	var out: Array = []
	if genotype_name != "":
		out.append({"label": genotype_name, "current": false})
	out.append({"label": here, "current": true})
	return out

func _default_index() -> int: return 0

## The SELECTED caste is drawn in the creature's OWN detail colour, the resting ones in the flat
## two-tone. Corrects a note that had this backwards: stacking the captures shows Qud's selected
## Horticulturist plainly GREEN against Raves' grey, and it is not a brightness step.
##
## The colour does NOT come from the sprite. The exported tile is a black/white MASK -- loading it
## natively (tried, reverted) yields a black-and-white figure, which is the whole reason
## _recolor_tile exists. It comes from chargen.json, where every subtype carries a `detail` colour
## code alongside its tile: Horticulturist 'g', the Ibul castes 'c', the Yawningmoon ones 'r'. Per
## CASTE, not per arcology -- Ekuemekiyye alone runs g/Y/W/g -- so it has to be looked up per card.
##
## Only the detail channel moves. ICON_MAIN already measures (168,194,187) against the (177,201,195)
## Qud draws for the selected body, so the figure itself was never the problem.
func _card_icon(tile: String, item_name: String) -> Dictionary:
	var neutral := _recolor_tile(tile, ICON_MAIN, ICON_DETAIL)
	var code := str(_detail_by_tile.get(tile, ""))
	if code == "" or not QUD_COLORS.has(code):
		return {"colored": neutral, "neutral": neutral}
	return {"colored": _recolor_tile(tile, ICON_MAIN, QUD_COLORS[code]), "neutral": neutral}

# ── layout: the banded screen is NOT the plain one shifted ─────────────────────────
#
# ROW-PROFILED against a live 1920x1080 Qud capture of Choose Caste, not eyeballed: each value below
# comes from comparing bands of lit rows between the two screenshots, because "the title looks a bit
# low" is how a layout constant ends up carrying a guess. Qud's bands, for the record —
#   emblem 384-417 · "character creation" 423-440 · ":choose caste:" 449-459 · arcology row 482-498
#   card frames 507-615 (tiles 525-587) · names 621-654 · hotkeys 662-672 · bullets from 696
#
# Inserting the arcology row does not push the cards DOWN, it pulls the title block UP and leaves the
# cards where they were: title and subtitle move by ~0.05 of viewport height, the card row by ~0.013.
# That is why these are five separate hooks and not one offset — a uniform lift puts the title right
# and the cards 24px high, which reads as "close" and scores badly.

func _y_title() -> float: return 0.384 if _banded() else super._y_title()
func _y_subtitle() -> float: return 0.410 if _banded() else super._y_subtitle()
func _y_bands() -> float: return 0.4444
func _y_cards() -> float: return 0.470 if _banded() else super._y_cards()
func _y_desc() -> float: return 0.650 if _banded() else super._y_desc()

func _banded() -> bool:
	return _class().get("categories", []).size() > 1

## Twelve castes fit into roughly the span Qud gives five game modes, so the cards are narrower and
## the gaps tighter. Measured off the same capture: card boxes ~88px wide on a ~124px pitch, against
## the five-card screen's 94 on 121. Inherited unchanged, the twelve-card row ran 1660px wide against
## Qud's 1448 and pushed the outer castes under the page arrows.
## Castes pack twelve cards into the row, and there Qud marks the selection by recolouring the card's
## own dotted frame rather than dropping the big locator sprite over it. Callings are a short row and
## keep the locator.
func _sel_uses_card_frame() -> bool: return _banded()

func _card_w_frac() -> float: return 0.0499 if _banded() else super._card_w_frac()
## 0.013, not 0.0102: measured against Qud, whose caste cards sit on a 120px pitch at 1920x1080
## (card frames at x231, 351, 471, 591 …). Raves ran at 114 once the selection caret stopped
## reserving width in every card. NB Qud widens the pitch to ~139 across an ARCOLOGY BOUNDARY —
## that extra inter-band gap is not modelled here, so Raves' twelve cards still finish ~38px
## narrower than Qud's.
func _card_gap_frac() -> float: return 0.013 if _banded() else super._card_gap_frac()

## The arcology row occupies the space the unbanded screens give the selection frame: inherited, the
## frame reached up to y481 with band 1 sitting at y482, and swallowed that band's left rule whole.
func _sel_pad_top_frac() -> float: return 0.005 if _banded() else super._sel_pad_top_frac()

# ── data ───────────────────────────────────────────────────────────────────────────

## The chosen subtypeClass out of chargen.json. Cached per frame-ish rather than per call: _subtitle,
## every _y_* hook and _banded all ask for it, and _load_items is re-read on every icon-resolve poll.
func _class() -> Dictionary:
	if not _class_cache.is_empty():
		return _class_cache
	var path := InputModel.support_dir().path_join("chargen.json")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary and data.get("subtypeClasses", null) is Array):
		return {}
	var classes: Array = data["subtypeClasses"]
	for c in classes:
		if c is Dictionary and str(c.get("id", "")) == subtype_class:
			_class_cache = c
			return c
	if not classes.is_empty() and classes[0] is Dictionary:
		_class_cache = classes[0]
	return _class_cache

## Flatten category → subtypes into one card row, hotkeyed A.. in display order — which is exactly
## what Qud does: the letters run straight through the arcologies ([A]-[D] Ekuemekiyye, [E]-[H] Ibul,
## [I]-[L] Yawningmoon), they do not restart per group.
func _load_items() -> Array:
	var out: Array = []
	for cat in _class().get("categories", []):
		for st in cat.get("subtypes", []):
			var i := out.size()
			var lines := PackedStringArray()
			for x in st.get("info", []):
				lines.append(str(x))
			if lines.is_empty():
				for b in st.get("statBonuses", []):
					lines.append("· +%d %s" % [int(b.get("bonus", 0)), str(b.get("name", ""))])
			var tile := str(st.get("tile", ""))
			if tile != "":
				_detail_by_tile[tile] = str(st.get("detail", ""))
			out.append({
				"name": str(st.get("name", "?")),
				"display": str(st.get("display", st.get("name", "?"))),
				"hotkey": HOTKEYS[i] if i < HOTKEYS.length() else "",
				"tile": tile,
				"desc": "\n".join(lines),
			})
	return out

## One band per category, in the same order the cards were flattened, so start/count line up with the
## card indices without carrying a second ordering anywhere.
func _category_bands() -> Array:
	if not _banded():
		return []
	var out: Array = []
	var at := 0
	for cat in _class().get("categories", []):
		var n: int = (cat.get("subtypes", []) as Array).size()
		if n > 0:
			out.append({
				"display": str(cat.get("display", cat.get("name", ""))),
				"start": at,
				"count": n,
			})
		at += n
	return out

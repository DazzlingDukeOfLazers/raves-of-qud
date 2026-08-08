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

## Icons are left to the base two-tone recolour, as GenotypeScreen leaves them: Qud draws the caste
## sprites in the same neutral grey-teal as the mode and genotype icons and carries selection with
## brightness, which _apply_selection's ICON_SEL/ICON_DIM modulate already does.

# ── layout: the banded screen is NOT the plain one shifted ─────────────────────────
#
# Measured off a live 1920x1080 Qud capture of Choose Caste (reports/…/q3_caste.png). Inserting the
# arcology row does not push the cards DOWN, it pulls the title block UP and leaves the cards nearly
# where they were: title/subtitle move by ~0.035 of viewport height, the card row by ~0.013. That is
# why these are five separate hooks and not one offset — a uniform lift puts the title right and the
# cards 24px high, which reads as "close" and scores badly.

func _y_title() -> float: return 0.400 if _banded() else super._y_title()
func _y_subtitle() -> float: return 0.421 if _banded() else super._y_subtitle()
func _y_bands() -> float: return 0.449
func _y_cards() -> float: return 0.470 if _banded() else super._y_cards()
func _y_desc() -> float: return 0.650 if _banded() else super._y_desc()

func _banded() -> bool:
	return _class().get("categories", []).size() > 1

## Twelve castes fit into roughly the span Qud gives five game modes, so the cards are narrower and
## the gaps tighter. Measured off the same capture: card boxes ~88px wide on a ~124px pitch, against
## the five-card screen's 94 on 121. Inherited unchanged, the twelve-card row ran 1660px wide against
## Qud's 1448 and pushed the outer castes under the page arrows.
func _card_w_frac() -> float: return 0.0458 if _banded() else super._card_w_frac()
func _card_gap_frac() -> float: return 0.0094 if _banded() else super._card_gap_frac()

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
			out.append({
				"name": str(st.get("name", "?")),
				"display": str(st.get("display", st.get("name", "?"))),
				"hotkey": HOTKEYS[i] if i < HOTKEYS.length() else "",
				"tile": str(st.get("tile", "")),
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

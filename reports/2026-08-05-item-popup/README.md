# Parity baseline — item interaction popup, 2026-08-08

**Completes** the 2026-08-05 spec rather than superseding it. The spec's design was already right —
named regions with distinct kinds, and an `anchor` so the header leaves are scored relative to each
app's own popup top line instead of silently also scoring the popup's placement. What it lacked was
the baseline discipline: no `--stable` capture, no recorded pin, no scoreboard, and no statement of
which leaves are safe as controls. The captures are replaced; the spec is extended by one leaf.

## The pin — reproduce this exactly before re-scoring

| what | value |
|---|---|
| save | **`sync-raves-and-qud`** (row 1 of `hv saves`), Wander |
| zone | `JoppaWorld.11.22.1.1.10` — Joppa surface |
| loaded via | `python3 tools/capture/fixture.py reload sync-raves-and-qud` |
| **item** | **cloth robe** — `pack/Armor`, present deterministically in this fixture's 14 pack items |
| popup raised by | `python3 tools/capture/fixture.py twiddle robe` — resolves the item BY NAME and verifies the popup came up. Never by id (ids are not stable across a reload) and never by clicking whatever is under the cursor |
| mirrored | Qud raises it; Raves receives it over the popup bridge (`popup=menu`) |
| capture | Qud activated and given ~3s to repaint (it does not repaint unfocused), captured TWICE for `--stable`; then Raves activated and captured |

```bash
python3 tools/capture/fixture.py reload sync-raves-and-qud
hv goto raves in_game
python3 tools/capture/fixture.py twiddle robe
# activate + settle + capture each, then:
python3 tools/capture/parity.py score \
  reports/2026-08-05-item-popup/parity-item-popup.json \
  <qud.png> <raves.png> --stable <qud2.png> --json
```

## Reproducibility — checked, not assumed

The entire pin was re-driven from scratch (reload → re-attach Raves → re-raise the popup →
re-activate → re-capture) and re-scored. **All 7 leaves reproduced EXACTLY (+0.00)**, better than
the ±0.01 the Equipment baseline managed. An item popup raised by name off a reloaded fixture is
about as deterministic as this harness gets.

## Which leaves are safe as CONTROLS

`fixture_dependent` is recorded per leaf in the spec, because that distinction was already got
wrong once on the Equipment spec (`list_cat`/`list_item` were treated as chrome and are not).

- **Controls (fixture-independent): `popup_image_frame`, `popup_placement`** — the header block's
  border lines and the popup's own placement. Only these two are valid for validating a future
  retake.
- Everything else moves with the item: the name text, its colour and its box, and the tile's
  geometry and palette.

That is a thin control set — two of seven — which is precisely why the pin has to name the item.

## Verdict: the screen is in good shape, with two structural offsets

**At the floor, not worth chasing:**

| leaf | diff | why it is the floor |
|---|---|---|
| `popup_image_color` | **0.00** | the tile's two-tone is exact |
| `popup_image_geometry` | **0.25** | 42×54 ink in both apps, 1px apart in x |
| `popup_frame_text_color` | **2.26** | palette matches; this is an ink mean over antialiased small text |
| `popup_image_frame` | **2.50** | chrome lines, same band as Equipment's `doll_frame` (1.9–2.6) |

**Two genuine divergences, named rather than buried:**

1. **The whole popup sits 16px LOW in Raves.** Measured off the anchor rows directly: Qud's popup
   top line is at y320, Raves' at y336. `popup_placement` = 6.75. The spec recorded this on
   2026-08-05 as constant across a 5- and a 7-option menu; it is unchanged.
2. **The item-name line sits 1px LEFT in Raves.** `popup_frame_text_content` scores **15.40** and
   on its own says nothing useful — the glyphs and palette match (`ink_color` 2.26) and the line is
   simply translated. The new `popup_frame_text_geometry` (0.75) and the ink boxes
   (Qud x=4 w=152, Raves x=3 w=153) say it precisely.

Number 2 is the case for the spec format in miniature: a single masked mean-abs-diff folded a 1px
translation and a rasteriser difference into one number and so answered neither. 1px structural
offsets are exactly what this project chases (see the sidebar grab-bar note in `docs/gotchas.md`),
so both are worth fixing — but neither is a regression, and the content underneath is exact.

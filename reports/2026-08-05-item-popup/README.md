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
about as deterministic as this harness gets. Re-checked on 2026-08-08 after the box-model port:
two consecutive re-drives of the whole pin scored identically to two decimal places on all seven.

**One hazard the pin does not remove: the FIRST twiddle after a fixture reload sometimes raises a
SHORT option list** (the cloth robe's 8 options arriving as 2 or 6, with Qud still settling). It is
a different popup, so a run that captures it silently compares two different things — the header
leaves still score, because they are anchored to each app's own top line. Verify the option count
off Qud's live RectTransforms before capturing, and re-raise if it is wrong. Do **not** clear a
menu with `popup / action:button / btn:Cancel` to retry: the mod fabricates a Cancel item, Qud's
`OnActivateCommand` falls through to the HIGHLIGHTED row, and on the cloth robe that is
"equip (auto)" — a retry loop written that way quietly equips the fixture's item and then fails
forever. Reload the fixture instead; a reload cannot activate anything.

## Which leaves are safe as CONTROLS

`fixture_dependent` is recorded per leaf in the spec, because that distinction was already got
wrong once on the Equipment spec (`list_cat`/`list_item` were treated as chrome and are not).

- **Controls (fixture-independent): `popup_image_frame`, `popup_placement`** — the header block's
  border lines and the popup's own placement. Only these two are valid for validating a future
  retake.
- Everything else moves with the item: the name text, its colour and its box, and the tile's
  geometry and palette.

That is a thin control set — two of seven — which is precisely why the pin has to name the item.


## 2026-08-08 — Qud's popup BOX MODEL, ported whole

The two offsets recorded here on 2026-08-05 (the popup "16px low", the item name "1px left") are
closed. Neither was nudged: the model in the spec's `qud_model` block was applied whole, and both
fell out of it.

| leaf | was | now | |
|---|---|---|---|
| `popup_placement` | 6.75 | **0.00** | the popup's own top-line placement, absolute |
| `popup_frame_text_content` | 15.40 | **4.98** | the item-name line |
| `popup_frame_text_geometry` | 0.75 | **0.25** | same x, same y, same width; 1px of ink height left |
| `popup_image_geometry` | 0.25 | **0.00** | identical tile bbox |
| `popup_image_frame` | 2.50 | **2.28** | header chrome |
| `popup_frame_text_color` | 2.26 | 2.30 | +0.04, inside run-to-run noise |
| `popup_image_color` | 0.00 | 0.00 | |

### What changed

Qud centres `MenuControll` — spacing 10, pad L20 R20 T0 B5 — and hangs the visible chrome OFF that
box: the top rule 16 **above** it, the opaque fill from box_top−20 to box_bottom−2, the bottom rule
15.5 **inside** it. Raves centred the PANEL and drew its top rule 8px inside. So this was never a
margin to add; it changed which box is centred, and it is shared by every popup kind.

Inside the box, Qud's own structure now drives the sizes rather than a fitted height: the 138.12
context block, a Scroll View that is `Message + 2 + options area + 2 + inputbox` (26 per row,
spacing 2), and a 20px `MenuCrome` bar whose entries are `padL 2 + an 8px cursor cell + spacing 5 +
text + padR 20`.

### Verified across sizes AND kinds — six popups, four kinds, six widths

The spec is pinned to one item at fixed coordinates, so it cannot see a differently sized popup.
These were measured wherever they land, against Qud's own `MenuControll` from
`uiprobe target=PopupMessage`. **Exact** = the opaque fill, the top rule, the context divider and
the bottom rule all landed on Qud's pixel rows/columns with zero delta.

| popup | kind | Qud's box | |
|---|---|---|---|
| cloth robe, 8 options | menu + context | 278.21×407.12 @ 820.90,336.44 | exact |
| basic toolkit, 7 options | menu + context | 239.81×379.12 @ 840.09,350.44 | exact |
| data disk, 9 options | menu + context | 433.61×435.12 @ 743.20,322.44 | exact |
| wish prompt (`CmdWish`) | AskString input, 2 entries | 650.00×76.72 @ 635.00,501.64 | exact |
| quest notice | message, 1 entry | 462.81×57.12 @ 728.59,511.44 | exact |
| quit confirm (`CmdQuit`) | yes/no, 3 entries | 453.40×57.12 @ 733.30,511.44 | exact |

Three of those exist because **each term of the width rule wins on a different popup**, which one
capture could never have shown:

- the cloth robe is sized by its widest COMMAND (67 + 211.21 = 278.21)
- the data disk by its 41-character NAME (40 + 393.6 = 433.61) — its commands only ask for 199.81,
  so a client that sized on the list alone would draw that popup a little over half Qud's width
- the quit confirm by its COMMAND BAR (3 entries + 2 spacings + 2 line sprites at a 25px floor =
  453.40) — its message only asks for 383.40, and nothing but a multi-button confirm reaches it

### The one concession, stated rather than buried

Godot snaps every Control rect to a whole pixel, so the carrier `PanelContainer` cannot be 278.21
wide. Two consequences, both handled deliberately:

1. **A Container CEILS a fractional minimum** — a row asking for 228.2 is handed 229 — and the box
   came out 279, whose centred left edge is 820 where Qud's 278.21 rasterises from 821. The model's
   own widths are rounded to the NEAREST pixel instead, which reproduces Qud's pixel on all six.
2. **The chrome is drawn on the exact fractional box**, offset from the carrier by the sub-pixel
   difference. That is what puts the AskString's rules on Qud's rows despite a 76.72 box living in
   a 77px carrier. The offset is derived from SIZES only: a Control's `position` reads (0,0) from
   inside its own draw callback on the show frame, and since nothing dirties the panel afterwards
   that stale draw is the one left on screen.

### Where the 1px name shift actually came from

The prediction on record — that it was downstream of the 2px width difference and would resolve on
its own — is **confirmed**. Nothing in the name's own layout changed.

The cause was measurement, not placement: Godot's `get_string_size` returns a whole number where
Qud lays this text out at exactly 0.6em (9.6px at font 16), and summing the per-run pieces of a
coloured string rounds again — the widest option row measured 213 against Qud's 211.21. Measuring
and advancing on the font's own pitch puts the name's ink box at Qud's x, y and width; the residual
0.25 is one pixel of ink HEIGHT, which is the rasteriser and a documented floor.

### Controls, and what did not move

- `popup_image_frame` (fixture-independent) 2.50 → 2.28 — the header chrome did not regress.
- **Raves' header block still measures 151.0 against Qud's 151.0.** It was already Qud's model, and
  the port deliberately left its internals alone: the top rule moved to box_top−16 and every header
  offset is still quoted from that line, so the arithmetic is unchanged by construction.
- The Equipment spec was re-scored on the same build: **all 33 leaves within ±0.02** of
  `reports/2026-08-08-parity-baseline/scoreboard.json`. No shared layout rule reached it.

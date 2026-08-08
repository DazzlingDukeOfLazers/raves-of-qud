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

## 2026-08-08 — the offsets were investigated and NOT nudged

Asked to fix the two offsets, I decompiled Qud's control first, as the repo requires. The result
changed the problem, so the fix was deliberately **not** applied as a constant.

**Qud's model** (from the live RectTransforms via the mod's `uiprobe target=PopupMessage`, cross-
checked against the committed captures — the probe's `MenuControll h=407.12` matches the 407.5
measured between the chrome rules):

- the popup root is a 1920×1080 `VerticalLayoutGroup` with `align: MiddleCenter` — **Qud centres
  the popup; it does not place it at a fixed y**. `MenuControll` sits at y=336.44 with h=407.12,
  and 336.44 is exactly (1080−407.12)/2.
- the item name is `ContextItemText`, full content width (238.21 at x=840.9), so Qud centres the
  name on **x=960.0 — exactly screen centre**.

**The "16px low" is not a constant.** Measuring the three chrome rules in both apps
(Qud 320 / 471.5 / 728, Raves 336 / 487.5 / 735) decomposes it:

| part | Qud | Raves | |
|---|---|---|---|
| header block | 151.0 | 151.0 | **already exact** — Raves' header is Qud's model |
| command area | 256.5 | 247.5 | Raves **9px short**, and this part scales with option count |
| box centre | 524.2 | 535.8 | Raves **11.5px lower** — a different anchoring |
| width | 278.21 | ~280 | Raves 2px wider |

Adding 16 to the popup's y would zero the TOP rule on this one capture and leave the BOTTOM rule
7px out, because the observed 16 is the **sum** of a content-dependent height error and an
anchoring error that happen to add up on the cloth robe's 5-option menu. The 2026-08-05 note that
it was "constant across a 5- and a 7-option menu" is not evidence of a fixed offset — both parts
can be near-constant while their sum is a coincidence of those two sizes. That note is what made a
nudge look safe, and the decomposition is what shows it is not.

The **1px name offset** is very likely downstream of the 2px width difference (Qud centres the name
on exactly x=960.0; a 2px-wider box centred the same way rounds differently), so it should be
re-measured *after* the box model is right rather than nudged on its own.

**Not fixed, on purpose.** The remaining work is a box-model port — Qud's `MenuControll`
(spacing 10, pad L20 R20 T0 B5), `ContextContainer` (spacing 10, pad T10, MiddleCenter),
the 16px divider strip and the 224-tall Scroll View — applied WHOLE. The repo's own precedent is
explicit that this is the only way it works: the ability bar went 13.5 → 4.0 only when Qud's cell
model was applied whole, and every piecemeal copy scored *worse*. The model is recorded in the
spec's `qud_model` block so that port starts from Qud's numbers instead of from a delta.

**Scores are therefore unchanged** from the baseline above — nothing was altered, so nothing was
re-scored. The controls, the reproducibility and the verdict all still stand as committed.

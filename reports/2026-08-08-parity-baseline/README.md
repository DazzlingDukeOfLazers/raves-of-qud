# Parity baseline — Equipment tab, 2026-08-08

Retaken because the previous captures (`reports/2026-08-04-status-screens/`) were **unusable for
comparison**: nobody recorded the state they were taken in, and by 2026-08-07 the live fixture had
drifted away from them — the category filter strip held a different set of icons, a different
filter was selected, and Qud's strip sat one cell to the right. The spec addresses cells by fixed
coordinates, so those leaves were comparing different widgets and read as a 58–79 "regression"
that was nothing of the kind.

## The pin — reproduce this exactly before re-scoring

| what | value |
|---|---|
| save | **`sync-raves-and-qud`** (row 1 of `hv saves`), Wander |
| zone | `JoppaWorld.11.22.1.1.10` — Joppa surface |
| loaded via | `python3 tools/capture/fixture.py reload sync-raves-and-qud` (re-exports and BLOCKS until the export on disk is newer, so a stale read is not expressible) |
| screen | Equipment tab, both apps (`hv goto qud status_equipment`, `hv goto raves status_equipment`) |
| filter | **ALL** — the default selection on opening the tab, so it needs no arranging |
| capture | Qud activated and given ~3s to repaint (it does not repaint unfocused), captured TWICE for `--stable`; then Raves activated and captured |
| spec | `reports/2026-08-04-status-screens/parity-equipment.json` (unchanged) |

```bash
python3 tools/capture/fixture.py reload sync-raves-and-qud
hv goto raves in_game && hv goto qud status_equipment && hv goto raves status_equipment
# activate + capture each, then:
python3 tools/capture/parity.py score \
  reports/2026-08-04-status-screens/parity-equipment.json \
  <qud.png> <raves.png> --stable <qud2.png> --json
```

## Why this baseline is trustworthy

A retaken baseline can **hide** a real regression: re-baseline a leaf that genuinely got worse and
its delta goes to zero. So the retake was checked before being committed, against the leaves that
do NOT depend on which item or filter is selected — `doll_frame[0..4]`, `filter_frame[1..4]`,
`list_item`, `outer_frame`. Those are chrome; they should score the same whatever the fixture.
Scored against the OLD baseline they moved **-1.64 .. +0.91**, in line with the -0.30 .. -2.34
measured on the previous run and inside the ~0.7 run-to-run noise this spec is documented to have.
Nothing material moved, so the new numbers are a change of *fixture*, not of *rendering* — which is
also what the code says: nothing committed on 2026-08-07 touches a rendering path.

`filter_frame[0]` is deliberately NOT in that check: it is the ALL cell, and it is gold-selected
here, so it legitimately differs from a baseline where a different filter was selected.

## Reproducibility of the pin — checked, not assumed

The whole pin was re-driven from scratch (fixture reload → re-navigate both apps → re-activate and
re-capture) and re-scored against the scoreboard below. **All 33 leaves reproduced within ±0.01**
(range -0.01 .. +0.01, mean -0.001). So these numbers are a property of the pinned state, not of
one lucky capture, and `--stable` is fully removing the live-playfield noise it exists for.

## What the retake showed about the OLD baseline

The old (2026-08-04) captures turn out to have been taken **on this same `sync-raves-and-qud`
save** — that was simply never written down. Scored against them, the fixture-dependent leaves come
back nearly identical: `doll_image[0..4]` 5.75/12.70/0/2.76/0 vs 5.75/12.71/0/2.76/0, and
`filter_image` within 0.03 on four of five. The 58–79 "regression" seen on 2026-08-07 was entirely
an artefact of capturing on the `meta` save instead.

**One leaf genuinely moved and is named rather than absorbed: `list_cat` 3.91 → 6.48 (+2.57).**
It is not a rendering change — it is content. At that y the old capture had **blank space** (the
list sat at a different scroll position), so Qud and Raves trivially agreed; here the row holds a
populated category header, `c) [-] Data Disks |1 lbs.|`, where there is real text to disagree
about. Both apps render the same text in the new captures; the residual is glyph antialiasing,
which every composite leaf on text carries.

**Consequence worth carrying forward: `list_cat` and `list_item` are NOT fixture-independent.**
They depend on the list's contents and scroll position, so do not use them as chrome-style controls
when validating a future retake. The genuinely state-independent set is `doll_frame[0..4]`,
`filter_frame[1..4]` and `outer_frame`.

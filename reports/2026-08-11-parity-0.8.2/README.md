# Parity + regression run for 0.8.2 — 2026-08-11

Pin: `sync-raves-and-qud`, Wander, Joppa `JoppaWorld.11.22.1.1.10`, 1920x1080, 1:1 mode,
second Qud capture as `--stable`.

## SPOT — 10/10

All ten checks in `docs/testing.md` pass, scored **on exit code**, not on a phrase in the output.
That matters: a first pass grepping for `"0 checks failed"` reported `journal_carousel` and
`state_graph_render` as FAILURES when both had passed — they print their own success strings. A
check that cannot pass is the same class of bug as one that cannot fail.

## FULL 2 — 1:1 parity

### status_equipment vs the committed baseline (`reports/2026-08-08-parity-baseline`)

The control: nothing this release touched that screen.

| kind | baseline | now |
|---|---|---|
| image | 4.32 | **4.30** |
| frame | 2.14 | **2.10** |
| composite | 2.94 | **3.06** |

30 of 33 leaves within 0.5 of baseline. The three that moved are `filter_cell[0]`,
`filter_frame[0]`, `filter_cell[1]` (+0.9 to +1.6) — small frame leaves where the live playfield
behind the scrim dominates, which `docs/testing.md` already measures at ~0.7 between identical
builds.

**A first run of this scored SIX leaves regressed, up to +3.0, and it was my own doing.** Earlier in
the session I scrolled the wheel over the Holodeck as a control (to prove wheel delivery worked
before diagnosing the message log), which ZOOMED Raves' camera. In 1:1 the world behind the scrim
is supposed to match Qud's; zoomed, it does not, and Qud's filter strip sat over blue water where
Raves' sat over dry ground. Relaunching Raves reset the camera and the six became three.

**So: before scoring parity, restart Raves.** Any camera nudge during a session — a stray wheel
event over the playfield is enough — silently biases every leaf that shows world through a scrim.

### New baselines: skills and journal

Both changed this release and neither had a committed scoreboard.

| screen | composite | frame |
|---|---|---|
| status_skills | **1.94** (2 leaves) | 3.45 |
| status_journal | 14.20 (3 leaves) | 3.69 |

Journal's composite mean is carried by two leaves and neither is new:

- `worldmap` **12.56** — Qud renders the world map live; Raves blits the exported texture. Expected.
- `empty_state` **26.51** — the "No entries found." row. Drawn by `_draw_header_row`, NOT the header
  this release re-fonted, so it is pre-existing and unmeasured until now. Worth its own pass; the
  row sits ~8px off Qud's in the side-by-side captures.

## FULL 1, 3, 4

Exercised continuously through the session rather than as a single pass: `hv goto` + `hv assert`
across title / game_mode / chartype / genotype / caste / in_game / all status tabs on both apps
(FULL 3), popups raised, mirrored and answered including the item menu, the look message and the
AskString quit prompt, plus `statustab` and `invaction` (FULL 4), and the journal search field typed
into with the characters landing and no menu firing (FULL 1, one field).

**FULL 1 is one field, not seven** — and the session's revert (94dd987) is the reason to be precise
about what that proves. See `docs/testing.md`.

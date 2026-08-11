# Pre-0.8 test run — 2026-08-10

Ran the documented tiers in `docs/testing.md` before tagging for PC review.
**SPOT 11/11. FULL 2 and 4 pass. FULL 3 is 12/12 on the nodes that exist. FULL 1 partially
covered — the gap is named below.** Two graph gaps and one real UI defect found; the defect is
fixed, the graph gaps are open and are in **highvisor**, not in this repo.

## SPOT — 11/11

typing guard · modal input · popup overlay render · panel grab bar · journal carousel · nearby-row
hit test · popup report multi-source · state-graph render · Godot parse+`_ready` · Main.gd deep
check · mod API drift.

`Main.gd` reports `Identifier not found: UiState` → `Failed to load script`. That is the documented
autoload false positive; the real failure mode is `Could not parse global class`, and there were
**zero**. Checked, not assumed.

## FULL 2 — 1:1 parity sweep: PASS, no regression

Fixture pinned per `reports/2026-08-08-parity-baseline/README.md` (`sync-raves-and-qud`, Joppa,
Equipment tab, ALL filter, Qud captured twice for `--stable`).

**33 leaves, mean delta +0.028** against the committed scoreboard. Seven moved more than 0.7, all
of them `filter_*`.

A **control** run first: re-scoring the committed baseline *images* with today's scorer reproduced
the committed scoreboard on **0 of 33 leaves differing**. So the scorer and spec are stable and the
deltas are real capture differences, not tooling drift.

Then the deltas were decomposed by side — the step that actually settles it:

| capture pair | filter_cell[0] |
|---|---|
| base Qud vs base Raves | 1.12 |
| **now** Qud vs **now** Raves | 2.74 |
| base Qud vs **now** Raves (Raves-side only) | **1.12** |
| **now** Qud vs base Raves (Qud-side only) | **2.74** |

Raves' side is byte-equivalent to the baseline on these leaves; the movement is **entirely
Qud-side**. Cropping Qud's first five category cells then and now shows identical icons, order and
frames — what differs is the **live playfield bleeding through** behind the semi-transparent cells,
which is the noise source this spec's README already documents for the list leaves. Not a
regression.

### Real defect found: the ALL cell's label followed its frame

Selecting *All golds the cell's FRAME. Raves also golded the **word**, so the cell read as lit
twice over. Qud's own node carries a flat `color: #afc6c1ff` with no conditional (uiprobe on
`StatusScreensScreen`), and the capture agrees.

| | ALL glyph |
|---|---|
| Qud | (112,135,132) |
| Raves before | (199,182,55) — gold |
| Raves after | (115,141,136) |

**Coverage gap in the spec, worth knowing:** `filter_cell[0]` is at x=676, the first *category*
cell. The ALL cell sits at x=618 and **no leaf covers it** — which is why a wrong colour there
survived every previous sweep. The fix was found by eye while decomposing the deltas, not by the
score.

## FULL 3 — menu recipes: 12/12 on existing nodes, 2 graph gaps

`title / records / options / mods / in_game` reach and assert clean on **both** apps.

First pass reported 5 spurious Raves failures. That was **my harness, not the app**: `hv goto` was
followed immediately by `hv assert` with no settle, so the assert raced the transition. With 2.5s
between them all twelve pass. A test that fails for its own reasons is worse than no test.

Two nodes cannot be routed to **at all** — `no transition ENTERS`:

| node | inbound | outbound | note |
|---|---|---|---|
| `load_game` | none | — | pre-existing |
| `cyber_terminal` | none | 2 (both apps) | **added today**; I wired the exits and not the entrance |

**And `hv test`'s graph selftests all pass while this is true** — `plan`, `evaluate`, `state_read`,
`cli` are green. A node that is detectable and exitable but unreachable is exactly the half-wired
state a completeness check exists to catch, so this is a check that cannot fail. The durable fix is
in highvisor: make `selftest_plan` fail on any node carrying detect rules with no inbound
transition, with an explicit allowlist carrying reasons (the pattern `typing_guard_audit` already
uses). Not done — it is harness work, outside this repo, and it will fail on both nodes above
until they are wired, which is the point.

## FULL 4 — mod round-trip: PASS

- `statustab`: all eight tabs driven and confirmed — skills, attributes, equipment, tinkering,
  journal, quests, reputation, messagelog.
- nav commands: `CmdWait` and `CmdAutoexplore` each advanced Qud's turn timestamp.
- popups: raised in Qud, mirrored to Raves (`popup=menu`), **answered from Raves**, and Qud
  returned to `play`. Both halves.

## FULL 1 — typing guard, live: 2 of 7 fields

Typed `e j q x n 1 2` — all seven are live hotkeys (equipment, journal, quests, examine, notes, two
abilities).

| field | chars land | screen stays put |
|---|---|---|
| status-screen search | `ejqxn12` | yes |
| Options search | `ejqxn12` | yes |

**Not covered:** feedback note (needs Cmd+right-click on an element), Options host/port,
control-mapping, chargen name, tile report. Same shape of gap as the 2026-08-07 run. The SPOT audit
proves the guard is *present* on every dispatcher; this proves it is *reached* on two of them.

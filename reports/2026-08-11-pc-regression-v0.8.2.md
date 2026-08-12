# PC regression run for v0.8.2 — 2026-08-11 (floorputer, Win11)

Pinned: raves-of-qud at tag **v0.8.2** (`6e29659`, detached), highvisor at **`dec44c8`**
(`main` — the newest highvisor commit predating the tag, 2026-08-11 16:56). Both trees were
clean and fully pushed beforehand; the starting branches were raves `dd/pc-object-checker` and
highvisor `dd/pc-test-stations` (0-ahead / 141-behind `main`, i.e. already merged).

Environment: Godot 4.7.1 (winget), .NET 8.0.423, Qud 1.0.5 at
`C:\Program Files (x86)\Steam\steamapps\common\Caves of Qud`. The mod was redeployed from the
tag (46 files) before launch, and the running build read back over the wire as
`2026-08-06 zone stairs flags` — which is exactly what `mod/Protocol.cs` carries at v0.8.2. The
constant simply was not bumped for the release; this is the tag's mod, not a stale deploy.

**Result: SPOT 10/10 scorable checks PASS. Object Checker wire sweep 2483/2483 PASS, zero new
FAILs against the committed baselines.** FULL 2 was not runnable on this box — see below.

---

## FULL 2 could not be run here: this is not Lumpy

`docs/testing.md`'s PC parity baselines (skills 3.01/4.96/3.99, equipment 3.90/4.80/5.12,
reputation 6.27/2.81/5.28, tinkering 3.58/7.58) are pinned to the **`pc-parity`** golden and its
character `Lumpy-true-kin-dev-char`. Neither exists on floorputer: `saves.py goldens` lists only
`checker`, and no such character appears in `hv saves`. `fixtures/goldens.json` commits an
*index* entry for `pc-parity`, but goldens are per-platform binaries kept outside the repo, so
the index says nothing about which box actually holds one.

The pinned scoreboard therefore has no fixture to reproduce here and was **not run**. Quoting
those numbers as reproduced on this machine would have been fiction.

What floorputer *is* the rig for is the Object Checker (`docs/pc-test-rig.md`, golden `checker`,
char `Tygashwuraq`), whose Rung 1 names the wire sweep as the standing regression. That is what
ran.

---

## SPOT — 10/10 scorable checks pass

Scored on exit codes, per `docs/testing.md`.

| check | exit | verdict |
|---|---|---|
| typing_guard_audit | 0 | PASS |
| modal_input_audit | 0 | PASS |
| popup_overlay_render | 0 | PASS (41 ok) |
| panel_grab_bar | 0 | PASS (14 ok) |
| journal_carousel | 0 | PASS |
| nearby_rows | 0 | PASS (14 ok) |
| popup_report | 0 | PASS (10 ok) |
| state_graph_render | 0 | PASS (46 ok) — half-skipped, see below |
| Godot parse + `_ready` | 0 | PASS |
| mod API drift (`dotnet build`) | 0 | PASS — 0 errors / 20 warnings against Qud 1.0.5's real assemblies |
| `Main.gd --check-only` | **1** | not scorable on exit code, see below |

### A fresh checkout poisons SPOT until an editor rescan — and one check hangs forever

The first pass failed with `TypingGuard` / `FeedbackSubmitter` / `HighvisorClient` "not declared
in the current scope", every autoload failing to instantiate, and a cascading
`Cannot infer the type of "r"` in `StateGraphPanel.gd`. All of it was the stale
`.godot/global_script_class_cache.cfg` left behind by the previous branch — the case `CLAUDE.md`
already documents. `Godot --headless --editor --quit --path godot/` rebuilt the cache (21
classes) and every check went green.

Two things are worth fixing rather than remembering:

- **`state_graph_render` hung indefinitely** instead of failing. It is the only SPOT check
  invoked with `--script` and no `--quit-after`, so when its autoloads fail to instantiate the
  engine never quits. A suite runner without a per-check timeout stops dead there and never
  reaches the checks after it. Giving it a `--quit-after` would close this.
- **`popup_report` exited 0 having run 1 of its 10 checks**, dying on
  `Invalid access to property or key 'layer' on a base object of type 'Nil'`. A green exit code
  over a check that never ran is the same defect class `docs/testing.md` names in the other
  direction ("a check that cannot fail").

Also: the rescan **rewrites source files**. It re-indented two comment continuation lines in
`godot/Main.gd` from spaces to tabs, which shows up as a working-tree diff after running the
documented fix. Worth a line in `CLAUDE.md` next to the advice itself.

### `Main.gd --check-only` cannot be scored on its exit code

It exits 1, and its only error is `Identifier not found: UiState` at `Main.gd:373`. `UiState` is
an autoload (`project.godot`), so this is precisely the documented false-positive class
alongside `Settings` and `QudLauncher`. There is no `Could not parse global class X`, which is
the real signal.

This reconciles the 0.8.2 report's "SPOT 10/10" against an eleven-row table: ten checks can be
scored on exit code, and this one cannot. Either the doc should say so, or the check should
learn to exit 0 when the only errors are known autoload identifiers.

### `state_graph_render` only half-runs on the PC

It passes, and prints:

    real gametree.json — SKIPPED (no highvisor checkout at
    /Users/homefolder/personal-git/highvisor/highvisor/gametree.json)

The path is hardcoded to the Mac, so on this box the check only ever exercises its fixture and
never the real tree — while still exiting 0. The highvisor checkout is right there at
`C:\Users\danie\personal-git\highvisor`; the lookup belongs behind the plat seam.

---

## Object Checker wire sweep — 2483/2483 PASS, no regression

Rig boot per `docs/pc-test-rig.md` Rung 2: `saves.py restore checker` (Qud down) →
`hv launch qud_solo` → `hv loadsave Tygashwuraq` → `hv back` ×2 to clear the load popup →
`hv wish godmode`. `hv state` reported `In-Game scene=play via=scene` throughout.

Wire-only (no `--shots` / `--diff`). v0.8.2 has no `checker.py diff`, so the comparison is a
stand-in script diffing the fresh `reports/checker/<cat>.json` against the same files extracted
from the tag.

| category | n | new FAIL | healed | still FAIL | roster | warn drift |
|---|---|---|---|---|---|---|
| walls | 229 | 0 | 0 | 0 | ±0 | 76 |
| plants | 181 | 0 | 0 | 0 | ±0 | 104 |
| liquids | 79 | 0 | **2** | 0 | ±0 | 50 |
| furniture | 745 | 0 | 0 | 0 | ±0 | 285 |
| food | 276 | 0 | 0 | 0 | ±0 | 131 |
| implants | 77 | 0 | 0 | 0 | ±0 | 0 |
| creatures | 896 | 0 | 0 | 0 | ±0 | 376 |
| **total** | **2483** | **0** | **2** | **0** | **±0** | **1022** |

**2483/2483 wire PASS**, matching the certification figure in `pc-test-rig.md` §Rung 6 exactly.
The element roster is identical to the baseline in every category — no drift from the Qud 1.0.5
category-rule problem that hit `weapons`/`items`.

**The two "healed" liquids are harness recovery, not a fix.** `NeutronPool` and
`NeutronfluxPool` were baseline FAILs whose reason was `stage wedged the rig 3x — element
skipped`; they staged fine this time. Nothing in this release addressed them, and they should
be expected to flap again.

**The 1022 warn drifts are one family and are not a signal.** 1386 of the run's warns are
`wire tile != blueprint tile`, and the drift is that warn appearing and disappearing
symmetrically as the randomly-chosen tile variant changes per placement — `liquids_water_puddle_1..4`,
`items_sw_splat1..4`, `terrain_sw_tree_banana_1/3`, `wall_rock-00000000` and friends. This is
exactly why the check is a WARN and not a FAIL. The remaining warns are the known-skip families
(CherubimSpawner 20, multi-cell sprites 11, neutron flux 2), 6 `passed on retry (turn-flow
race)` markers, and a handful of odd-colour notes.

A `checker.py diff` should filter that family by default, or the drift will drown every future
comparison the way it nearly drowned this one.

### The zone-rot guard cannot complete on this box, and it takes the sweep with it

First attempt aborted at element 150 of walls:

    === rig reboot at 150/229 (zone-rot guard, every 150)
    reboot_rig: zoom/calibrate failed (calibrate: capture failed (is the Raves viewer open?)); full viewer recycle   ×3

`reboot_rig` does a viewer recycle plus `stage_zoom()` + `calibrate()` **unconditionally**, even
for a wire-only sweep that will never look at a pixel. Two consequences:

1. With no viewer running it fails outright, so **any category over 150 elements dies at the
   guard** — walls, plants, food, furniture and creatures, i.e. 2,327 of the 2,483 elements.
2. With the viewer running it still fails, because `reboot_rig` *relaunches* Raves, the fresh
   window takes the foreground, and Qud's self-capture needs focus. This is the trap
   `pc-test-rig.md` already documents — including that the error names the wrong app. The
   documented unblock (`MinimizeAll` then `hv activate CavesOfQud`) makes `calibrate` succeed by
   hand, but `reboot_rig` re-breaks it on its own next relaunch.

Worked around by running with `--reload-every 0` in slices of 140, re-arming between slices the
way Rung 2 does (`hv loadsave` → clear popup → `wish godmode`) — 21 slices, all exit 0, ~19
minutes for the full 2,483. The rot guard's intent is preserved (a golden reload every ≤140
stagings, versus its own 150) without the pixel machinery.

The durable fixes, in order of value: make `reboot_rig` skip zoom/calibrate when the sweep is
wire-only; and take `pc-test-rig.md`'s own suggestion of moving the Qud half of `shots_for()`
onto `hv shot CavesOfQud`, which has no focus dependency and would delete the whole failure
mode.

### One more trap, for whoever writes `checker.py diff`

**`checker.py` flushes its report periodically by merging into the previously committed one.**
Mid-sweep, `<cat>.json` therefore holds mostly baseline rows plus the few re-swept — including
the baseline's *pixel* scores, which a wire-only run never produces. Diffing it before the
process exits reads as a completed, clean run. It fooled me once in this session. Check the
process, not the file.

Relatedly, the baseline was swept **with** shots, so every baseline element carries a
`no capture pair — congruence skipped` warn that a wire-only run does not. Filtered as harness
noise rather than counted as drift.

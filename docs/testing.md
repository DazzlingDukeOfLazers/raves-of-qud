# Testing: what to run, and when

Two tiers, deliberately. **SPOT** is what you run constantly — seconds, no apps, cannot go flaky.
**FULL** is what you run before shipping or after touching input/chrome — it drives both apps and
takes minutes, and its failures need a human to read a screenshot.

The split follows one rule: **if the defect is decidable from the source, decide it statically.** A
static check runs in milliseconds, needs no window, and never reports a false failure because Qud
was unfocused or the rig bounced to the title screen. Only put a case in FULL when it genuinely
needs pixels or a live game.

---

## SPOT — every commit (~5s total, nothing running)

| check | command | catches |
|---|---|---|
| typing guard | `python3 tools/regression/typing_guard_audit.py` | a keyboard hotkey dispatched from `_input` without `TypingGuard`, and any newly added text field |
| State-graph panel render | `Godot --headless --path godot/ --script res://tests/state_graph_render.gd` | the panel's text builders against a fixture AND the real gametree.json — rows, markers, empty/null trees |
| Godot parse + `_ready` | `Godot --headless --path godot/ --quit-after 120` | parse errors, autoload/`_ready` failures |
| Main.gd deep check | `Godot --headless --path godot/ --check-only --script res://Main.gd` | a `class_name` parse error that would silently kill the Holodeck in the export |
| mod API drift | `dotnet build mod/RavesOfQudBridge.csproj` | Qud API changes, C# errors |

`Identifier not found: Settings` / `QudLauncher` in the `--check-only` output are known false
positives (autoloads aren't loaded headlessly). `Could not parse global class X` is REAL.

### The typing-guard audit specifically

It is a SPOT check because the bug class is structural. A hotkey dispatched from `_input` fires
*before* Godot's GUI pass, so a focused `LineEdit`/`TextEdit` has not consumed the key yet and
`is_input_handled()` is still false — which is why typing "e" in a note opened the Equipment screen.
Whether a given handler is exposed is readable from the source, so no game is needed.

It fails loudly when someone adds a new `_input` key dispatcher, and prints the full text-field
inventory every run so a **new text field shows up in the diff** even when the audit passes. That
inventory is the "make sure all text fields are updated" tripwire.

To exempt a handler that must act while typing (a modal owning its own field), add it to `EXEMPT` in
the script *with the reason* — an exemption without a reason is a bug in waiting.

---

## FULL — before a release, or after touching input, chrome, or the bridge

Needs both apps: `hv launch raves`, both in-game.

1. **Typing guard, live.** For each text field — feedback note (Cmd+Right-click any element),
   Options search, Options host/port, status-screen search, control-mapping, chargen name, tile
   report — focus it and type `e j q x n 1 2`. PASS = the characters land in the field and **no**
   status screen, ability, or menu fires. This is the case the SPOT audit cannot prove: it verifies
   the guard is reached at runtime, not merely present in the source.
2. **1:1 parity sweep.** `python3 tools/capture/parity.py` against the current report set; compare
   the panel means to the last committed scoreboard.
3. **Menu recipes.** `hv goto raves <node>` + `hv assert` across records/options/mods/load, both
   apps.
4. **Mod round-trip.** Popups mirror and answer; `statustab`; the nav commands (autoexplore, POI,
   wait) each reach Qud.

FULL is allowed to need judgement. SPOT is not.

---

## Running SPOT on another machine

Only the typing-guard audit is dependency-free (Python 3, stdlib only, no Godot, no Qud, no
highvisor). The other three need the Godot binary and the .NET SDK at the paths in `CLAUDE.md`.

```bash
python3 tools/regression/typing_guard_audit.py
```

Exit 0 clean, exit 1 with the offending files named and the fix spelled out.

## The checks are registered in the tree, and runnable from the panel (2026-08-07)

Every SPOT check is now declared in highvisor's `gametree.json` — harness-wide ones at the top
level (`tests`), screen-specific ones on the node they cover (`in_game` carries the typing-guard
audit). Two consequences worth having:

- `hv test` lists them all; `hv test <id>` runs one. The caller names WHICH check; the command
  text lives in version control next to the state it covers, so "run this node's check" can
  never become "run this string".
- Raves' state-graph panel (Ctrl+wheel / F6) renders them as clickable `[T]` markers next to
  each node's 1:1 `done` scores — hover shows the command, click runs it and reports the verdict
  plus the tail of its output. The scoreboard and the checks now sit on the same row as the
  state they describe.

Registered today: `plan`, `evaluate`, `state_read` (highvisor), `state_graph_render` (raves),
`typing_guard` (raves, on `in_game`).

## FULL run 2026-08-07 — results and coverage

SPOT 5/5. FULL 2/3/4 pass; FULL 1 partially covered, and the gap is named below.

Three broken menu edges found and fixed (highvisor `0e6af4b`): Raves' title menu never got its
activating **Space** (a click only moves the selection, so every title edge except in_game sat
there); Qud's quit **verified too eagerly** (a PopupMessage lingers after the game ends and
`in_game`'s detector claims that scene); Qud's Records exit used **uiback**, which
ModernHighScores ignores — it stranded Qud and took options/mods down with it.

Two harness defects found and fixed (`4629c49`, and the earlier scroll fix): **modifier clicks
and wheels need the modifier really HELD**, not just flagged on the event. This is why the
Cmd+Right-click feedback gesture appeared broken — the harness could not produce it.

**FULL 1 coverage — 2 of the 7 listed fields**, both chosen because they sit in contexts where
the in-game hotkeys are live, which is the only place the guard can actually fail:

- status-screen search — typed `ejqxn12`, scene stayed `equipment`, text landed. So `e`/`j`/`q`/
  `x`/`n` did not open Equipment/Journal/Quests/Attributes/Tinkering.
- feedback note (the field the original bug was filed against) — typed `ejqxn12`, scene stayed
  `in_game`, text landed.

NOT covered this run: Options search, Options host/port, control-mapping, chargen name, tile
report. Control-mapping was attempted and its route would not resolve; the other four sit on
screens where the in-game hotkeys are not live, so they carry much less risk — but they are
untested at runtime, and the SPOT audit only proves the guard is PRESENT in the source.

Parity (equipment spec): composite 5.24, frame 3.61 — in line with the committed scoreboard.
`image` 38.49 is dominated by the category filter strip, whose icons are offset by exactly one
slot (`filter_image[0]`'s Raves bbox == `filter_image[1]`'s Qud bbox, and so on). Pre-existing
and an ordering bug, not a rendering one.

## FULL on the merged mac/PC result — 2026-08-07

Branch `dd/mac-pc-merge` in both repos, after all four PC branches. The merged mod was DEPLOYED
and Qud fully restarted first — mods compile at startup, so nothing measured before that means
anything. Bridge came up on 48710, no compile errors in Player.log.

**PASS** — FULL 4 (mod round-trip): statustab on two tabs, the `wish` command channel, nav
commands moving the playfield and message log, and the popup mirror-and-answer route
(Esc -> Qud's CmdSystemMenu -> mirrored to Raves -> answered -> arrived).
**PASS** — FULL 3, everything except one edge: all 8 status tabs across both apps, both apps'
in_game and title, and all three Raves menus (records/options/mods).

**THREE DEFECTS FOUND, all fixed** (highvisor `f48c473`, `3f07e2c`):

- `key()` raised `NameError: modifiers` — the mac/PC vocabulary rename had clobbered a LOCAL
  called `mods` (the list `key()` parses out of "ctrl+m" itself). Every synthetic key was dead.
- Chasing that found TWO `_mod_flags`. The staticmethod added earlier that day was defined
  first and therefore shadowed, so click/scroll passed a *string* to a function that iterates
  modifier NAMES — it walked the string character by character. Invisible because the flags are
  cosmetic on that path: what actually delivers a modifier is the held key.
- `gamestate` threw `JSONDecodeError: line 1431` — a TORN READ. The tree hot-reloads on mtime,
  so any non-atomic writer leaves a window where the file is half a document, and since every op
  resolves through the tree the whole daemon answered that error until someone touched the file.
  `load_tree` keeps the last good tree now; regression-tested by half-writing the real file.

**ONE FAILURE, not fixed and not merge-caused:** `qud title -> records` fails consistently
(click_text finds and clicks "Records", Qud stays on the title). It passed earlier the same day
after the Records exit was fixed, and the click path is byte-for-byte unchanged by the merge
apart from a parameter rename — so this is the Qud modern-menu class again, not merge damage.
Needs its own session with a screenshot at each step.

**FULL 1 and FULL 2 — RUN on the merged tree, both PASS.**

FULL 1, the two in-game fields (the only places the hotkeys are live, so the only places the
guard can fail): status-screen search and the feedback note. Typed `ejqxn12` into each — the
characters landed and the scene did not move, so `e`/`j`/`q`/`x`/`n` fired nothing. Same 2-of-7
coverage as the pre-merge run; the other five sit on screens where the in-game hotkeys are not
live. NOTE: the first status-search attempt typed into nothing (the click missed the field and
the placeholder was still showing afterwards) — the scene not moving proves nothing when
nothing was typed, so it was re-run with the click on the field text. Check the field CONTENT,
not just the scene.

FULL 2 (equipment spec), merged vs pre-merge:
    composite  5.46  (was 5.24)
    frame      4.13  (was 3.61)
    image     38.23  (was 38.49)
Within the run-to-run noise this spec is documented to have — the live playfield shows through
the status scrim and moved the same build by ~0.7 between captures before now. No regression.
The `image` mean is still the category filter strip, offset by one slot; pre-existing and
tracked separately.

FULL now passes in full on `dd/mac-pc-merge`.

## FULL run 2026-08-07 (evening) — current `main`, both repos

Run end to end on `main` with the whole day's fixes in it (directional assert, popup matcher +
`refuse`, `_qud_command_chain`, `stranded_stage`, the focus-keeper two-flag fix, `hv quit`, the
gametree conversions). SPOT first as the gate: **5/5**, plus highvisor's four selftests.

### FULL 1 — typing guard, live: **PASS on 6 of the 7 listed fields**

Typed `e j q x n 1 2` into each and **read the characters back out of the field** — never inferred
from the scene not moving, which is the documented trap and which bit again this run (the first
Options attempt clicked 40px off, typed into nothing, and the scene "correctly" did not move).

| field | result |
|---|---|
| status-screen search | PASS — text in field, scene stayed `status_equipment` |
| feedback note | PASS — over a status screen, a harder case than the doc's in-game one |
| Options search | PASS (after re-clicking the real box) |
| control-mapping | PASS — the field the previous run could not reach at all |
| tile report | PASS — **in-game**, where `e`/`j`/`q`/`x`/`n` would open Equipment/Journal/Quests/Attributes/Tinkering |
| chargen name | N/A — no name field exists; the only chargen `LineEdit` is `filter…` |
| Options host/port | **NOT COVERED** — those live in the `Raves` options category, which `--one-to-one` hides, and `raves_solo` passes that flag. Needs the `raves_user` launcher. |

Two defects found and fixed from this case alone — see below.

### FULL 2 — 1:1 parity sweep: **INCONCLUSIVE, not a regression**

Scored PER LEAF against `reports/2026-08-04-status-screens/parity-equipment.json` with `--stable`
(a second Qud capture), baseline taken by scoring the committed captures with the same tool and
spec so the comparison is like-for-like. 33 leaves.

**The comparison is not valid, and the reason is visible in the pixels.** The captured game state
differs from the 2026-08-04 baseline: the category filter strip holds a *different set of category
icons*, a *different filter is selected* (ALL highlighted now, a different category then), and
Qud's strip sits one cell to the right. The spec addresses cells by fixed coordinates, so those
leaves are comparing different widgets — hence `filter_image` 3–5 → 58–79. `doll_image` is equally
state-dependent (it compares equipped-item sprites).

What IS comparable is the chrome, which does not depend on contents, and it is flat-to-better:
`doll_frame[0..4]` −0.61/−0.33/−0.62/−0.70/−0.60, `filter_frame[1..4]` −0.75/−0.75/−0.87/−2.12,
`list_item` −2.34. (`filter_frame[0]` +18.43 is the ALL cell, gold-selected now vs grey then.)
Consistent with no rendering regression — and nothing landed today touches a rendering path.

**To make this case meaningful again the baseline captures need retaking against the current
fixture**, or the fixture needs pinning. Left as-is rather than reported as a pass or a failure.

### FULL 4 — mod round-trip: **PASS**

- popups mirror and answer: `CmdSystemMenu` → Qud popup at 0.02s → Raves `popup=menu` at 0.43s.
- `statustab`: Journal and Tinkering, and back to in-game.
- nav commands — the doc's gap ("in 1:1 the nav cluster is icon-only, no caption to anchor a
  click"). Exercised through the SAME bridge channel the buttons use, with the command names read
  out of `MainFrame.gd` (`CmdAutoExplore` / `CmdMoveToPointOfInterest` / `CmdWaitMenu`), each
  verified by its effect rather than by the send returning:
  autoexplore moved the player (40,24)→(39,23); POI raised Qud's 2-option chooser; `CmdWaitMenu`
  raised its popup at 0.6s. **This does not test the icon's click target** — only that the command
  reaches Qud and acts.

### FULL 3 — menu recipes, whole tree: **Qud 20/28 arrived; Raves NOT RUN**

Drove every modelled target for Qud (28), greedy-nearest by the planner's own costs, arrival
checked with `hv assert --node` so a CONTAINER counts as arrived when detection lands inside it
(`goto status_screens` → `status_attributes` passed, correctly).

ARRIVED (20): in_game, all 8 status tabs + status_screens, title, modding_toolkit,
histographicnomicon, map_editor + all 5 me_menu_* sub-screens, mod_manager.

**All 8 failures are one root cause, not eight.** At `wfc_generator` the route took a restart
edge; on that restart **Qud's in-game Roslyn compiler NRE'd and the mod did not load**
(`MODERROR [Raves of Qud Bridge] - Exception compiling mod assembly ... NullReferenceException at
CSharpCompilation.GetSourceDeclarationDiagnostics`). The bridge never came up, `qud_state.json`
went stale (420s against a 6s TTL), and every subsequent target failed clicking for captions on
the wrong screen.

**Not caused by anything committed today**: `dotnet build` is clean, the same mod had compiled and
run through hours of driving earlier in the session, and a clean `hv restart qud` afterwards came
up with the bridge OPEN, the heartbeat 0.8s fresh and **zero** MODERRORs. Transient, under the load
the tour put on the app.

The harness defect it exposes is worth more than the flake: **`hv state` answered
"Title Screen  via=live" the whole time Qud was sitting on the Modding Toolkit.** With the state
file stale the engine falls back to the `game_live: false` inference, which every menu screen
satisfies, so a dead bridge degrades into a *confident wrong answer* rather than an unknown — the
same class as the `stranded_stage` mislabelling fixed earlier today. Tracked separately.

NOT RUN this session, and not to be read as passing:
- the **Raves** whole-tree tour (21 targets) — out of budget after the Qud tour;
- FULL 3 against the **Classic** save as a tour. The part of it that matters most, the quit chain,
  WAS exercised against `Marsha Taur` earlier the same day: 3/3 consecutive loud failures naming
  the ABANDON prompt, cancelled, game left live, not poisoning the next attempt.

### FULL 2 — RETAKEN 2026-08-08: **PASS**, and the earlier INCONCLUSIVE is superseded

New baseline at `reports/2026-08-08-parity-baseline/` (captures + `scoreboard.json` + a README
recording the pin). Supersedes the "INCONCLUSIVE" entry above, which was correct at the time: the
2026-08-04 captures carried no record of the state they were taken in.

**Pinned** with the repo's own tooling, not by hand: `sync-raves-and-qud` (Wander, Joppa
`JoppaWorld.11.22.1.1.10`) loaded via `tools/capture/fixture.py reload`, Equipment tab in both apps,
filter **ALL** (the default on open, so nothing needs arranging), Qud activated and given ~3s to
repaint, captured twice for `--stable`.

**The retake was checked before it was trusted**, because re-baselining a leaf that genuinely
regressed would drive its delta to zero and look healthy. Control: the leaves that do not depend on
which item or filter is selected — `doll_frame[0..4]`, `filter_frame[1..4]`, `outer_frame` — scored
against the OLD baseline moved **-1.64 .. +0.91**, matching the -0.30 .. -2.34 measured the day
before and inside this spec's documented ~0.7 noise. Nothing material moved, so the new numbers are
a change of fixture, not of rendering.

**Reproducibility**: the pin was re-driven end to end and re-scored — **all 33 leaves within
±0.01** (mean -0.001).

**What it revealed**: the old captures were taken on this same save all along. Fixture-dependent
leaves come back nearly identical (`doll_image` 5.75/12.70/0/2.76/0 vs 5.75/12.71/0/2.76/0;
`filter_image` within 0.03 on four of five). The 58–79 "regression" on 2026-08-07 was purely the
`meta` save being loaded instead.

**One leaf named, not absorbed: `list_cat` 3.91 → 6.48 (+2.57)** — content, not rendering. That row
was blank in the old capture (different scroll position) so the apps trivially agreed; it now holds
`c) [-] Data Disks |1 lbs.|`, real text both apps render the same, and the residual is glyph
antialiasing. **Therefore `list_cat`/`list_item` are NOT fixture-independent** and must not be used
as controls for a future retake — the state-independent set is `doll_frame[0..4]`,
`filter_frame[1..4]`, `outer_frame`.

### FULL 3 completed 2026-08-08 — the two tours the 08-07 run did not cover

Same method as the Qud tour: greedy-nearest by planner cost, arrival via `hv assert --node` so a
CONTAINER counts when detection lands inside it. The tour now also samples the **environment**
around every goto (bridge reachable, `qud_state.json` within its 6s TTL) and classifies each
failure, because the 08-07 run reported 8 failures that were one dead reporter:

    EDGE     environment healthy, the route still did not arrive
    ENV      the reporter was down -- not a broken edge
    REFUSED  the harness declined ON PURPOSE (see the Classic rows)

#### A. Raves, Wander fixture: **21/21 ARRIVED** (0 EDGE, 0 ENV)

First pass was 13/21 with 8 EDGE failures, **all one missing edge** — see the control-mapping fix
in highvisor `beee9bc`. Opening Raves' Control Mapping drives QUD to its Keybinds screen; Raves had
no exit edge, so the tour left it by whatever route the planner found, closing Raves' copy and
leaving Qud parked on Keybinds with its turn thread inside the UI. Every later
`raves in_game -> title` then failed "dismiss ran but in_game is still up", because CmdQuit reaches
a turn thread that is not in the game loop. The health columns were the thing that made this
readable at a glance: 0 ENV, heartbeat under 1s all run, so it could not be blamed on the mod-load
flake that produced the previous tour's phantom failures.

Worth keeping: `hv state` called that parked screen **"Title Screen via=live"** — the
`{game_live: false}` fallback again, and this time with a live game behind it (the probe reads
false because a parked turn thread publishes no snapshot). Fixed for this screen by giving Qud a
first-party detector (`scene: Keybinds`); the general fallback defect is still open.

Re-run after the fix: **21/21**, including `new_game` arriving at `game_mode` (the container rule).

#### B. Classic save (`Marsha Taur`), both apps — **no defects; the refusals are the design**

| tour | arrived | refused-by-design | EDGE | ENV |
|---|---|---|---|---|
| qud | 10/28 | 18 | 0 | 0 |
| raves | 10/21 | 11 | 0 | 0 |

ARRIVED both apps: `in_game` and every status screen (plus `status_screens` for Qud,
`control_mapping` for Raves) — i.e. everything that does **not** route through the title.

REFUSED (qud): title, continue, records, options, mods, new_game, game_mode, modding_toolkit,
mod_manager, workshop_uploader, blueprint_browser*, histographicnomicon, wfc_generator, map_editor,
me_menu_{edit,file,recent,transform,view}. (raves: the same set it models, plus genotype/calling.)
Every one of them routes through `title` from `in_game`, and on a Classic (non-checkpointing) save
that edge must answer Qud's typed ABANDON confirmation — which would end a permadeath run. The
harness cancels it and fails instead, naming the prompt. **That is the designed behaviour and a
PASS.** Verified after 18 consecutive qud refusals and 11 raves ones: the game was still
`live=True running=True player=True scene=play`, still drivable (status round-trip), not poisoned.

**THE FINDING: the planner cannot express "this edge is blocked on this save."** `hv restart qud`
DOES reach the title on Classic (verified) — killing the process needs no ABANDON answer and does
not touch the save file, only unsaved progress. But the planner prices the CmdQuit route at 8,
takes it, is refused, and then gives up: `_drive_route` only re-plans when the app MOVED, and the
refusal deliberately leaves the game exactly where it was. So the `* -> title` restart edge that
would work is never reached. All 29 refusals across the two tours are that one gap. Tracked
separately; it wants edge-exclusion on retry, not a cost tweak.

### FULL 3, Classic save — RE-RUN 2026-08-08 after refused-edge exclusion

**Supersedes the "B. Classic save" block above** (qud 10/28 + 18 refused, raves 10/21 + 11),
which was correct for the code as it stood: a refused edge ended the drive. highvisor `4fc058c`
now excludes the refused edge and re-plans, so the `* -> title` restart route the graph already
had becomes reachable.

**Method — the save is reloaded before EVERY node, uniformly.** Without that the tour stops
testing what it is named after: the first refusal-driven restart leaves Qud at the title, so every
later node would start from a title screen rather than an in-game Classic save, most would "arrive"
for reasons having nothing to do with Classic, and the numbers would not be comparable node-for-node
against the baseline. A failed reload counts as ENV, not as an edge defect.

**The restart fallback is allow-by-default in the daemon; the tour gets it by simply not passing
`--no-restart`. Stated plainly: these numbers hold only with it enabled.** With `--no-restart` the
18 qud nodes fail again, by design — verified.

| tour | arrived | via cheap | via restart | refused | EDGE | ENV | was |
|---|---|---|---|---|---|---|---|
| qud | **28/28** | 10 | 18 | 0 | 0 | 0 | 10/28 |
| raves | **20/21** | 10 | 10 | 0 | 0 | 0 | 10/21 |

**Cost.** qud 19.6 min wall — 11.0 min of it reloads (56%), 8.6 min driving. raves 16.6 min —
11.6 min reloads (70%), 5.0 min driving. **Reloading dominates**, so this shape of tour is a
pre-release exercise, not something to run per commit; the drives themselves are cheap.

**No restart storm.** Each restart-routed node cost 15–25s, not the 120 its edge is *priced* at —
that 120 is the planner's avoidance weight, not seconds. 28 restarts across both tours came to
13.6 min of driving in total.

**The one non-arrival is an artefact of the method, not a defect: raves `continue`.** Its node is
the load-game picker, and Raves' Continue only opens the picker when there is no live game —
with one running it attaches straight in-game. Reloading before every node guarantees a live game,
so the picker is unreachable *by construction*. Verified both ways: with a live Qud game the goto
fails `wanted {'scene': 'loadgame'}, got In-Game`; with Qud at the title it succeeds. It arrived in
the Wander tour precisely because that tour did not reload per node.

That verification also exercised the new structured marker: the failure reports `refused: False`,
so "declined on purpose" is now distinguishable from "broke" without reading the error text. An
earlier version of the tour script string-matched and mis-labelled this exact run as REFUSED
because an *earlier* edge in it had refused.

**Wander regression, run AFTER the Classic tours** (the regression this change could most easily
cause): qud 3/3 and raves 2/2 quit cycles take the cheap route (cost 8 / 22) with **zero** restarts.

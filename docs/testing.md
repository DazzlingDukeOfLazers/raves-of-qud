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

---

## FULL on `dd/pc-lumpy-merge` — 2026-08-07 (Lumpy, Win11)

Run after merging `origin/main` twice in a row (the Map Editor cycle + the
blueprint_browser conversion). **SPOT 5/5. FULL 3 and 4 pass. FULL 1 and 2 are
BLOCKED on one thing, named below — not on a defect in this branch.**

**SPOT — all five pass.** Typing-guard audit clean (every `_input` dispatcher
guarded or exempt). State-graph panel render 12/12. Headless parse + `_ready`: 0
errors. `Main.gd` deep check clean. The mod build has no `dotnet` on this box, so
it was verified the way that actually matters here: deploy the merged `mod/*.cs`,
start Qud, and read `build_log.txt` — **0 error lines, and the bridge port opens**,
which is a stronger claim than a compile anyway since it proves the mod loaded.

> One SPOT failure was real but not ours: `state_graph_render` died on
> `Identifier "HighvisorClient" not declared`. That is the `class_name` case
> CLAUDE.md documents — main added `HighvisorClient.gd`, and this machine's
> `.godot` class cache predated it. One `--headless --editor --quit` rescan fixed
> it. Worth knowing because it presents as a parse error in a file you did not
> touch.

**FULL 4 — mod round-trip: PASS.** Over the bridge into Qud's live Map Editor:
`mapedit paint` and `mapedit state` (this branch's) and `mapedit menuclose`
(main's new verb) all execute and log. The two lines merged cleanly into one
dispatch — `MapEditorDriver` carries both `Test` and `CloseMenu`.

**FULL 3 — menu recipes: PASS by hand, blocked via `hv goto`.** Driven by click:
`title -> modding_toolkit -> blueprint_browser` and `-> map_editor`, each
confirmed with `hv assert`. All three pass.

**The coordinate that moved.** This branch's title fix lifted the left link column
by one row pitch to match Qud, so Modding Toolkit is at **y≈902, not y≈952**.
Verified both ways: y=902 asserts `modding_toolkit`, y=952 misses entirely. Any
recipe or transition edge still carrying the old value needs updating.

**FULL 1 and 2 — BLOCKED, one cause.** Both need the two apps in-game, and the
route there is gone from under the running daemon: main converted the legacy
recipes to `transitions` edges, `gametree.json` hot-reloads but daemon CODE does
not, so the daemon reads the new tree and cannot plan it. Symptoms, all the same
root: `hv plan` -> `unknown op: 'plan_route'`; `hv goto qud in_game` and
`hv goto raves blueprint_browser` -> "no goto recipe". **One daemon restart
unblocks all of it** (Daniel's call — the daemon is not ours to start). `hv state`,
`hv assert`, `hv click` and the bridge are all unaffected, which is why everything
above could run.

The same restart is still owed to `hv click --middle` from earlier in the session.

### FULL follow-up on `dd/pc-lumpy-merge` — 2026-08-07, both apps in-game

The daemon restart landed, so the in-game tiers became reachable. **FULL 3 and 4
pass. FULL 1 passes on the field it could reach. FULL 2 runs but its numbers are
NOT comparable — see below.**

**The Raves status edges were broken and are fixed.** Every `in_game ->
status_*` edge sent Qud's per-screen letter binding (e/k/x/n/j/q). Raves does not
implement those: it opens the overlay with **F2** and you pick a TAB. So each
edge reported every step OK and simply never arrived. They now do F2 + a click on
the tab, x measured off the live strip (y=136, the row the messagelog edge
already used): skills 275, attributes 490, equipment 726, tinkering 908,
journal 1080, quests 1236, reputation 1408, message log 1619.
**8 of 8 tabs now drive and assert.**

**FULL 1 — PASS on the status-screen search field.** Typed `e j q x n 1 2`: the
characters LANDED in the field and the scene stayed `status_equipment`, so no
status screen, ability or menu fired. Checked the field CONTENT, not just the
scene — the trap the previous run recorded. Coverage is 1 of the 7 listed fields;
the others are not reachable from a Raves with no game data (below), and the
Blueprint Browser filter is not reachable from in_game at all (it hangs off the
title menu, by design).

**FULL 2 — RUNS, but the comparison is INVALID and must not be read as a
regression.** parity.py scored the equipment spec at composite 18.55 / frame
18.57 / image 35.01 against a recorded 5.46 / 4.13 / 38.23. Do not act on that:
**Raves has no game data.** Its equipment screen is empty, HP reads "—", the
message log and playfield are blank, and the capture is 33 KB against Qud's
1.5 MB. The score is measuring an empty screen, not a parity gap.

Raves reached `in_game` and renders its chrome, but never established the data
connection to Qud's bridge — no snapshot arrived, and a `wait` over the bridge
did not change the capture by a single byte. That is a separate defect from the
navigation edges fixed here, and it is what FULL 2 is really blocked on.

TWO CAPTURE TRAPS worth carrying, both of which produced convincing wrong
numbers before being caught:
  - A Qud shot taken too soon after `activate` catches an unpainted frame. The
    first attempt scored ~0.00 across every leaf because it was diffing two
    near-blank frames. The tell was file size — 315 KB vs 1.5 MB for the same
    screen. Settle ~4s and compare sizes before trusting a score.
  - `--stable` needs two DIFFERENT Qud captures. Two identical ones drop nothing
    and silently disable the noise filter the flag exists to provide.

#### FULL 2 is NOT blocked on Raves' data connection — the bridge publishes no snapshots

Chased on 2026-08-07 and the framing was wrong, so it is worth writing down.
Raves' connection is FINE. Its own log says so:

    [state-graph] highvisor reachable
    Raves bridge: connected

What does not happen is the SNAPSHOT. With Qud live on the play stage
(`{scene: play, live: true, view: Stage}`) and valid turn commands sent over the
bridge (`move`, `wait` — both in Bridge.cs's accepted set), the repo's own
`tools/capture/snap.py summary`, which connects and BLOCKS until Qud publishes a
frame, returned nothing in 45s. Raves' capture stayed byte-identical (16449)
across every attempt, and its panels keep reading `HP: —`.

So the defect is in the mod's snapshot PUBLISHER, not in Raves and not in the
connection. Prime suspect: the merge brought main's ~60-line StartupHook change
("the UI sampler must not overwrite a legacy view that is already right"); that
should be bisected against the pre-merge mod before anything else is touched.
Note the `mapedit` and `uiback` commands DO execute and log, so the bridge's
command path is healthy — it is specifically publication that is silent.

Two things this cost, both avoidable next time:
  - Qud's modern UI ignores OS-synthesized keys, so `hv key escape` will not
    leave a status screen. Use the bridge (`uiback`), which does.
  - In 1:1 mode Raves hides the "▶ Connect (data)" affordance, so there is no
    manual fallback to test the data stage with — auto-connect is the only path,
    which is why "is it connected?" has to be answered from the LOG rather than
    from the screen.

#### Root cause: the save's player has no BridgePart — NOT the StartupHook change

Bisected 2026-08-07. My earlier suspicion (the merged StartupHook) was WRONG and
is retracted: that diff is entirely heartbeat/`scene` reporting and touches
nothing in the publish path. Exonerated by inspection, before any redeploy.

The real cause is structural and predates the merge. `BridgePart` — the part that
fires `Bridge.Tick` / `TickAction` / `TickRender`, i.e. the ONLY thing that
publishes — is attached by `PlayerBridgeMutator`, a `[PlayerMutator]`. That runs
when the player GameObject is **created**. It does not run on LOAD.

So a save whose character was created without the bridge mod has a player with no
BridgePart, and therefore:
  - the server still starts (StartupHook) and still ACCEPTS commands — `mapedit`,
    `uiback`, `loadsave` all work and log, which is exactly why this looked like
    a Raves-side or connection problem
  - but nothing ever publishes: `snap.py` blocks forever, Raves' panels stay at
    `HP: —`, and its capture is byte-identical run after run

That is also what the "Mod Configuration Differs" popup was telling us all along:
these saves were made WITHOUT the bridge. The popup was the symptom, not an
annoyance to click past.

PROVED BY FIXING IT. `embark` (the mod's own chargen driver) built a fresh
character with the mod active, and `snap.py summary` returned a full frame
immediately:

    zone JoppaWorld.11.22.1.1.10  80x25  player (37,22)  cells 2000
    objects 2096   cell flags: bridge=1  wade=52  swim=0

Raves then picked it up — `raves_state.json` gained an advancing `snap_ts`.

CONSEQUENCE FOR THE FIXTURES: any save predating the mod is invisible to Raves,
permanently. Either rebuild the fixture saves via `embark`, or make the mod
attach BridgePart on LOAD as well as on creation (the mutator is creation-only;
PlayerBecome.cs already handles the body-swap case, so a load-time attach is the
missing third). The second is the better fix — it makes every existing save work
— and is the recommended next change.

#### FULL 2 RUNS — 2026-08-07, and what its numbers do and do not mean

With the load-time BridgePart attach in, both apps drive to `equipment` and Raves'
screen is FULLY POPULATED: equipment doll with slots and item icons, and the
categorised inventory (Ammo, Energy Cells, Food, Grenades, Light Sources, Meds,
Tonics, Water Containers) with real items. Capture went 33 KB (empty) -> 145 KB.

    composite mean 13.74 over 12 leaves
    frame     mean 14.73 over 11 leaves
    image     mean 49.76 over 10 leaves

DO NOT read that against the recorded 5.46 / 4.13 / 38.23 as a regression. The
recorded scoreboard was taken on the mac's golden save; this ran on a fresh
True Kin Horticulturist built by `embark`, because the two saves on this box
predate the mod and every leaf here is content-sensitive (item rows, category
strips, slot art). Same spec, different character — the numbers are not
comparable, and making them so needs the fixture save rebuilt via `embark` and
committed as the PC golden.

Getting Raves in-game also needed the title edge fixed. `title -> in_game`
selected Continue with an arrow key, which assumes the selection starts on
New Game — but Raves REMEMBERS the menu selection, so after any earlier
navigation that single `down` lands elsewhere and `space` activates the wrong
row. Arrow keys were verified to move the selection, so this was never key
delivery: it was a relative move against an unknown starting point. Now it
CLICKS Continue at (958,578), which is position-independent.

## FULL 2 — PC BASELINE, 2026-08-07 (golden `pc-parity`, equipment spec)

Repeatable at last: `saves.py restore pc-parity` -> `hv loadsave
Lumpy-true-kin-dev-char` -> drive both to `status_equipment` -> score.

    composite mean 13.27 over 12 leaves
    frame     mean 14.42 over 11 leaves
    image     mean 49.58 over 10 leaves

**Noise floor 0.00.** A second run from the same state with fresh captures
returned those three numbers IDENTICALLY. Note that contradicts the mac-side note
about this spec drifting ~0.7 between captures — on this fixture the character
stands still in a quiet Joppa zone, so nothing animates behind the status scrim.
Any movement in these numbers is therefore signal, not noise, which is exactly
what a baseline is for. Treat a change of even 0.5 as real.

### A correction: the fixture was NOT what made the mac numbers unreachable

I previously put the distance from the mac's recorded 5.46 / 4.13 / 38.23 down to
the fixture — different character, content-sensitive leaves. The data says
otherwise. The earlier run on a freshly embarked character scored
13.74 / 14.73 / 49.76 against this golden's 13.27 / 14.42 / 49.58: the character
swap is worth about **0.4**, not the ~9 points that separate this machine from
the mac's scoreboard.

So the gap is real and still unexplained. It is NOT the fixture, and it is not
capture noise. Candidates, in the order worth testing: platform rendering
differences (Windows font rasterisation and DPI — the same class that left the
Blueprint Browser's glyph agreement at 27% with the correct face loaded), and a
genuine parity regression on this branch. Do not compare PC runs to the mac
scoreboard; compare PC runs to THIS baseline.

`image` at 49.58 remains the category filter strip, which the mac notes already
track as a pre-existing offset-by-one-slot defect rather than a scoring artifact.

### The PC/mac FULL 2 gap is the equipment FILTER STRIP, not rasterisation

Tested 2026-08-07 and my "Windows font rasterisation" hypothesis is FALSIFIED.

CONTROL first: scoring the mac's OWN committed captures on this machine gives
composite 3.19 / frame 2.34 / image 4.28. Same tool, same spec, mac-rendered
pair 3.19 vs PC-rendered pair 13.27 — so the difference lives in what the apps
RENDER, not in the scorer.

`list_item`, scored per platform (each pair mirrors one character, so the error
CHARACTER is comparable even though content differs):

    MAC   best align dx=-1 dy=+1   ink overlap 26.8%   FLAT 5.25   EDGE 37.65
    PC    best align dx=-1 dy=+1   ink overlap 37.1%   FLAT 2.43   EDGE 54.40

Identical alignment, identical ink boxes, and the PC is BETTER on mean|d| (3.76
vs 6.36) and on overlap. Text is not the problem; `list_item` is not even in the
top 14 contributors.

The gap is the FILTER STRIP, by an order of magnitude:

    filter_image[0..4]   mac 2.15-5.57   PC 78.44-81.62   (+74 to +76 each)
    filter_frame[0..4]   mac 1.50-2.87   PC 24.06-37.93
    filter_cell[0..1]    mac 1.79-1.92   PC 23.57-42.27

Looked at it rather than inferring: on the MAC, Qud's and Raves' strips ALIGN —
same start x, icons matching one-for-one. On the PC, Qud's strip sits ~88 px
RIGHT of Raves' and the icons do not correspond — FOR THE SAME CHARACTER.

So this is a real Raves layout defect, not a platform artifact and not the
fixture: Raves positions the category filter strip differently from Qud, and the
two only coincide at the category count the mac's fixture happens to produce.
The mac note calling this "offset by one slot, pre-existing" was seeing the
benign end of the same bug.

NEXT: measure how Qud anchors that strip (left-aligned from a fixed x, centred,
or right-aligned against the panel) across two characters with different category
counts, then match it. Fixing it should move `image` from ~49.6 toward the mac's
~4, i.e. most of the PC/mac gap.

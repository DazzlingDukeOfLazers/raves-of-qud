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
| modal input | `python3 tools/regression/modal_input_audit.py` | mouse input leaking PAST an open modal — `MOUSE_FILTER_STOP` does not stop the WHEEL, so a modal that never calls `accept_event()` lets every tick reach `_unhandled_input` and zoom the playfield behind it |
| Popup overlay render | `Godot --headless --path godot/ --quit-after 400 res://tests/popup_overlay_render.tscn` | a runtime error in `PopupOverlay.show_popup` — which leaves the overlay invisible and reads from outside as "the popup never mirrored" |
| Panel grab-bar cursor | `Godot --headless --path godot/ --quit-after 400 res://tests/panel_grab_bar.tscn` | the ||| resize cursor spreading past the 20px bar it belongs to — reported from use as "I can't select nearby objects, the resize icon dominates" |
| Journal carousel hit test | `Godot --headless --path godot/ --quit-after 400 res://tests/journal_carousel.tscn` | a click selecting the WRONG sub-tab — the cells are owner-drawn, so a hit rect built on the 58px pitch instead of the 46px cell looks identical on screen and swallows the gaps |
| Nearby-row hit test | `Godot --headless --path godot/ --quit-after 400 res://tests/nearby_rows.tscn` | a click resolving to the WRONG row's object — off-by-one row arithmetic looks fine on screen and opens the wrong menu, which is worse than opening none |
| Popup report, multi-source | `Godot --headless --path godot/ --quit-after 400 res://tests/popup_report.tscn` | one overlay's popup report clobbering another's — three sources share the `popup` field, and closing a Qud modal used to wipe the feedback form's while the form was still up |
| State-graph panel render | `Godot --headless --path godot/ --script res://tests/state_graph_render.gd` | the panel's text builders against a fixture AND the real gametree.json — rows, markers, empty/null trees |
| Godot parse + `_ready` | `Godot --headless --path godot/ --quit-after 120` | parse errors, autoload/`_ready` failures — but ONLY in scripts that load at the main menu |
| qud_shape seam | `python3 tools/regression/qud_shape_audit.py` | a `Settings.clone_of_qud()` guarding a branch with an `else` (or an attempt to write the old ambiguous `qud_shape()` back) — that else is unreachable in BOTH modes (user mode renders as a 1:1 clone, so the bare gate is never false), which is how the message log's grouping, Nearby's larger icons and row 4's user-mode heights all became dead code that still read as features |
| parse ALL scripts | `python3 tools/regression/parse_all_audit.py` | a parse error in a Connect-only script (SkyGrade, ZoneRenderer, …) — the exported app ships it silently and the Holodeck dies with an empty playfield (2026-08-12: one double quote inside a shader-string comment) |
| darkness equivalence | `python3 tools/regression/darkness_equivalence.py` | a change to `_build_darkness` that moves a cell's darkness where it was not meant to go. Mirrors the TONE/VEIL rule AND the if-chain it replaced over the real 80x25 geometry, every cell state x light level, live zone plus all six neighbour offsets, and fails on any divergence outside the one sanctioned class. Exhaustive, ~1s, no apps — run it BEFORE a build, since the five bugs this pipeline produced were all invisible to a screenshot until the right time of day |
| burning detection | `python3 tools/regression/burning_detect_audit.py` | a change to `_is_burning` that puts fire on something merely tinted, or drops it from something alight. Qud ships no burning flag, so this reads the 60-frame `animSched` the mod sweeps out of the RenderEvent — cases are REAL wire captures (a burning player and, from the same snapshot, the dawnglider circling it, whose schedule swaps a status icon rather than flickering a background). Asleep floods `^c` the same shape, which is why both halves must be flame-coloured |
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
   - **A parity spec is pinned to one state at fixed coordinates, so it cannot see a differently
     sized widget.** After touching a shared layout (the popup box, a panel's chrome), also drive
     the widget at several SIZES and KINDS and compare the geometry wherever it lands — Qud's own
     `uiprobe` rect against the capture. The popup box model was checked that way across six
     popups and four kinds, and two of the three terms in its width rule are reached by exactly one
     of them (see `reports/2026-08-05-item-popup/README.md`). One capture would have hidden both.
3. **Menu recipes.** `hv goto raves <node>` + `hv assert` across records/options/mods/load, both
   apps.
4. **Zone-crossing fade.** `python3 tools/capture/zonewalk.py` — walks a FOUR-ZONE corner and
   asserts every adjacent zone wears the fade its id says it is owed from where the player now
   stands (edge neighbours fade along a side, diagonal ones only from their corner). Checks the
   builder's `[zonefade]` log against arithmetic on the zone ids, not pixels — neighbours are not
   on the wire at all, they live in the client's WorldStore. A corner is the case a there-and-back
   walk never reaches, which is why it goes around one. PROVEN TO FAIL: reinstating the bake-once
   guard makes it report 6 stale zones naming edge-vs-corner.
5. **Mod round-trip.** Popups mirror and answer; `statustab`; the nav commands (autoexplore, POI,
   wait) each reach Qud.

### Raising each popup KIND, deterministically

The popup box is shared by every kind, so a change to it has to be seen on more than the item menu.
All of these are non-destructive on the `sync-raves-and-qud` fixture and clear on the next reload:

| kind | how |
|---|---|
| option menu, N options | `tools/capture/fixture.py twiddle <item>` — cloth robe 8, basic toolkit 7, data disk 9 |
| menu sized by the NAME | twiddle `data disk` (a 41-character name, wider than any of its commands) |
| text input (AskString) | bridge `command` / `CmdWish` — the wish prompt |
| message | any notice; the fixture's quest grant raises one |
| yes/no confirm | bridge `command` / `CmdQuit` on a **Wander** save, then answer `Cancel`. Two prompts, and cancelling the first unwinds without quitting. Never on a Classic character — that chain ends in the ABANDON text prompt (see `docs/gotchas.md`) |
| **titled** option list | system menu (`CmdSystemMenu`) → answer option 2 (`[c] Control Mapping`) → `hv click CavesOfQud 675 117 --hover` on "Configuring Controller: …". That is `KeybindsScreen.SelectInputType()` → `Popup.PickOptionAsync("Select Controller", …)` — Qud's own code path, not scaffolding. **The click needs `--hover`; bare does nothing.** |

**The titled one is CLOSED as of 2026-08-08** — raised and mirrored on the first attempt, twice,
and re-captured. Measured figures in `reports/2026-08-05-item-popup/`. The earlier note here said it
"mirrors unreliably" and blamed `PopupBridge.Ensure()` arming only from `TickRender`; that arming
hole was real and is fixed, but it was not what stopped the mirror. **Raves' `PopupOverlay` was not
building at all** (a `RichTextLabel`/`Control` type mismatch aborted `_build()`), so no popup of any
kind displayed — see `docs/gotchas.md`.

**When a popup "does not appear", split the halves before theorising.** Tap the bridge for `popup`
frames (the mod's half) and `hv shot CavesOfQud` (Qud's half) BEFORE looking at Raves.
`fixture.py twiddle` and `hv state --popup` both verify through RAVES, so neither can tell you
anything about Qud — reading them as if they could cost a full session.

**Verify the option COUNT before capturing** — read `options` off the mirrored `popup` frame. The
item menu sometimes answers itself with its highlighted row (`equip (auto)` on the cloth robe) right
after raising, which moves the item between pack and body and makes the next raise offer a
genuinely different list (6 equipped, 8 in the pack). Measured 6/8 over eight cycles; the cause is
not identified. **Reload the fixture between raises rather than cancelling and retrying.**

FULL is allowed to need judgement. SPOT is not.

### Two ways these runs lie to you (both hit on 2026-08-11)

**RESTART RAVES BEFORE SCORING PARITY.** A status screen is drawn over the live playfield, so every
leaf that shows world through a scrim is only meaningful while Raves' camera matches Qud's. One
stray wheel event over the playfield during a session is enough to zoom it, and nothing in the
output says so — the 0.8.2 run scored SIX equipment leaves regressed by up to +3.0 until the app was
relaunched, after which three of them vanished and the kind-means came back flat. Qud's filter strip
was sitting over water where Raves' sat over dry ground.

**SCORE SPOT ON EXIT CODES, not on a phrase.** The suite's scripts do not share a success string:
`journal_carousel` prints `journal_carousel: OK` where the Godot scenes print `0 checks failed`. A
runner that greps for one of them reports the others as failures — which is the same defect as a
check that cannot fail, wearing the other face.

### What "FULL 1 passes" is allowed to mean

FULL 1 says "type into the field and check no menu fires". That outcome is ALSO what you get when
the keystroke never arrived, and when the key could never have reached the handler in the first
place. Both happened on 2026-08-11:

- a first run typed into the journal search and concluded the guard held; the field still showed its
  placeholder, so nothing had been delivered. `hv key --focus` delivers it. **Check the character
  LANDED before reading anything into the menu not moving.**
- a second run typed `e` and `7`, saw them land and no menu fire, and called ten new guards
  verified. A focused LineEdit eats letters and digits, so that result was identical before the
  change — see 94dd987. **A post-state alone cannot distinguish a fix from a no-op; the pre-state
  carries the information.**

The audit's scope is deliberate and documented in `tools/regression/typing_guard_audit.py`: the
unhandled pass only needs guarding where the key is one a text field does NOT eat (modifier combos,
function keys, dispatchers into Qud). Widening it to every screen is the "ten blanket guards" the
script's own comment warns against.

### Verifying the version stamp before a tag

`Brand.RAVES_VERSION` is what stamps `app_version` on every feedback report, so a release should
confirm it in the RUNNING build, not just in the source. Neither title mode shows it — 1:1 mirrors
Qud's own version corner by design, and user mode shows the same corner — but the **feedback form
says it out loud**, in the consent line it must show before anything leaves the machine:

```bash
hv click raves 960 577 --right --mod cmd     # Cmd+Right-click any element
# the form's consent line reads:
#   "Sends: your note, the element you picked, and Raves of Qud 0.8.2 on macOS."
```

Type a note starting `[deleteme]`, save, and the whole pipeline is exercised end to end: the outbox
drains to zero and the store gains NO row, because the server discards test reports at the door.
That is the only check that covers the client's marker, the submitter and the server's guard
together — a curl to `/v1/report` proves only the last of the three.

**`hv click` has `--right`, `--middle`, `--double`, `--hover` and `--mod` (cmd/meta/ctrl/alt/shift).**
Recorded because the 0.8.2 commit and tag claim this was a missing highvisor capability: it is not.
`--button right` is simply not the flag's name, and an argparse error was read as an absent feature
instead of a misremembered spelling. Check `hv <cmd> --help` before concluding a tool cannot do
something.

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

### FULL 2 now covers TWO screens — item popup added 2026-08-08

Baseline at `reports/2026-08-05-item-popup/` (spec + captures + `scoreboard.json` + README).
**Completes** the 2026-08-05 spec rather than superseding it: its design was already right (named
regions with distinct kinds, and an `anchor` so header leaves are scored relative to each app's own
popup top line instead of silently also scoring placement). What it lacked was the baseline
discipline — no `--stable` capture, no recorded pin, no scoreboard, no control set. Captures
replaced, spec extended by one leaf.

**Pinned**: `sync-raves-and-qud` (Wander, Joppa), **item = cloth robe** (`pack/Armor`, present
deterministically in the fixture's 14 pack items), popup raised by
`tools/capture/fixture.py twiddle robe` — BY NAME, never by id (ids do not survive a reload) and
never by clicking whatever is under the cursor. An item popup is far more state-dependent than a
tab, so naming the item is the whole pin.

**Reproducibility: all 7 leaves reproduced EXACTLY (+0.00)** on a full re-drive — better than the
±0.01 the Equipment baseline managed.

**Controls are thin and that is recorded in the spec**: `fixture_dependent` is now a per-leaf field,
and only `popup_image_frame` and `popup_placement` are fixture-independent. The other five move with
the item and would mask a regression if used to validate a retake. (Per-leaf because this was got
wrong once already — `list_cat`/`list_item` on the Equipment spec are not chrome.)

**Verdict: the screen is in good shape.** The tile is pixel-exact (`popup_image_color` 0.00,
`popup_image_geometry` 0.25), the palette matches (`popup_frame_text_color` 2.26) and the chrome is
in the same band as Equipment's `doll_frame` (`popup_image_frame` 2.50). Two structural offsets are
named rather than buried:

1. **the whole popup sits 16px LOW in Raves** (anchor rows y320 vs y336; `popup_placement` 6.75) —
   recorded on 2026-08-05 as constant across a 5- and a 7-option menu, and unchanged;
2. **the item-name line sits 1px LEFT in Raves** — `popup_frame_text_content` 15.40 says only "bad"
   on its own; the new `popup_frame_text_geometry` (0.75) plus the ink boxes (Qud x=4 w=152, Raves
   x=3 w=153) say what it actually is. The glyphs and palette match; the line is translated.

Number 2 is the spec format's argument in miniature: one masked mean folded a 1px translation and a
rasteriser difference into a single number and so answered neither question. Neither offset is a
regression.

**2026-08-08 follow-up — the offsets were decompiled, and deliberately NOT nudged.** Qud's popup
root is a 1920x1080 `VerticalLayoutGroup` with `align: MiddleCenter` (from `uiprobe
target=PopupMessage`): it CENTRES the popup rather than placing it, with `MenuControll` h=407.12 at
y=336.44 = (1080-407.12)/2 exactly. Measuring the three chrome rules in both apps decomposes the
"16px low" into parts that do not add up to a constant: the header block already matches EXACTLY
(151.0 both), the command area is 9px short in Raves **and scales with option count**, the box
centre sits 11.5px lower, and the box is 2px wider. Adding 16 would zero the top rule on the cloth
robe's 5-option menu and leave the bottom rule 7px out. The 2026-08-05 "constant across 5 and 7
options" note is what made a nudge look safe; it is a coincidence of those two sizes, not evidence
of a fixed offset. The fix is a whole box-model port (recorded in the spec's `qud_model` block),
per the ability-bar precedent where every piecemeal copy scored worse. Scores unchanged - nothing
was altered.

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

#### Not anchoring either: Raves emits MORE filter categories than Qud

Measured 2026-08-07 before changing anything, and the anchoring premise is wrong
too. Across all four captures (both apps x both fixtures) the strip's right end
sits at x=1741-1742 — Raves already anchors the way Qud does.

What differs is the CELL COUNT. On the PC golden, same character, same inventory:

    Qud    Q | ALL | 8 category cells | E
    Raves  Q | ALL | 11 category cells | E

Three extra cells push every cell left of them out of position, which is exactly
why the fixed-rect filter_image / filter_frame / filter_cell leaves compare an
icon against its neighbour and score 78-82 instead of 2-6. On the mac fixture the
counts happen to land close enough that the leaves still line up — that is the
"offset by one slot" the mac note recorded, i.e. the same defect seen at a
character where it nearly cancels.

So the fix is in what Raves puts IN the strip, not where it puts it: Raves is
categorising inventory more finely than Qud (or including categories Qud omits —
empty ones are the obvious suspect). The next step is to dump both category
lists for one character and diff the NAMES, which says immediately whether Raves
is splitting a category Qud merges or adding one Qud drops. Do that before
touching layout code — two anchoring hypotheses have already been wrong here.

## FULL 2 — PC BASELINE SUPERSEDED, 2026-08-07: 13.27 -> 0.04

The filter-strip fix closes it outright.

    composite  13.27 -> 0.04     (12 leaves)
    frame      14.42 -> 0.04     (11 leaves)
    image      49.58 -> 0.00     (10 leaves)

For reference the mac's own captures score 3.19 / 2.34 / 4.28 on this tool, so
the PC is now the better of the two — the residual there is the same filter-strip
defect at the count where it nearly cancels.

THE BUG. Qud CENTRES the category strip on the screen and sizes it to the
categories actually present. Raves had the reference measurements baked in as
constants — Q badge 590, ALL cell 618 — which are correct only for the eleven
categories the mac fixture happened to carry. Measured on two fixtures:

    mac (11 cats)  Q@590  E@1329  span 739  centre 959.5
    PC  ( 8 cats)  Q@677         span 565  centre 959.5    (3 fewer cells x 58)

so on the PC golden the whole strip sat 87 px left of Qud's, and every
fixed-rect filter_* leaf compared an icon against its NEIGHBOUR — 78-82 instead
of 2-6. `_filt_left(cells)` now derives the origin from the live count and
reproduces both fixtures exactly: 12 cells -> 590, 9 cells -> 677. Verified live,
Raves' strip moved 590 -> 677 and Qud's is at 677.

Three hypotheses were wrong before this one — the merged StartupHook, Windows
font rasterisation, and strip anchoring — and each died to a measurement before
any code changed. What finally worked was measuring the SAME quantity across two
fixtures and asking what stayed constant: the centre did, so the constant was
never 590.

## FULL 2 swept across all eight status tabs — 2026-08-07 (golden `pc-parity`)

Only `equipment` has a leaf spec, so the other seven were scored whole-screen.

    skills 92.87   attributes 93.43   equipment 93.37   tinkering 93.65
    journal 93.66  quests 93.68       reputation 93.02  messagelog 93.70

That band is 0.83 wide across eight different screens, which is the tell: it is
not eight per-screen problems, it is ONE shared difference. Note equipment reads
93.37 whole-screen while its LEAVES now score 0.04 — the residual is entirely
outside the spec'd regions, which is also why a whole-screen number was never the
right instrument for a single element.

LOCATED, and it is not located at all: bucketing the mismatch into 160x120 bands
gives every band exactly 1.4% of the error, on two unrelated tabs, with near
identical totals (83280 vs 83483). Uniform spread = global, not regional.

IT IS A TONAL OFFSET. Over 230k sampled pixels on `quests`, **not one matches**
(exact-equal 0.0%), and Qud is uniformly BRIGHTER:

    mean signed (qud - raves)   R +7.27   G +17.61   B +18.21
    mean |delta|                R  7.79   G  19.05   B  19.06
    most common G delta         +22 .. +30, tightly clustered

A constant positive offset weighted to G and B — i.e. Raves darkens the field
behind the status overlay more than Qud does, or applies a different scrim
colour. One fix should lift all eight tabs at once.

NEXT: this is the same shape as the toolkit backdrop veil, which was solved by
measuring the blend rather than guessing an alpha — sample a region Qud does NOT
draw over, solve for (alpha, colour) from two known backgrounds, and match. Do
NOT tune it by eye; the last four defects on this branch all yielded to a
measured invariant and none to a plausible guess.

### RETRACTION: there is no scrim offset — I scored against an unstable reference

The "one shared tonal offset across all eight tabs" conclusion above is WRONG.
Leaving it in place with this correction under it, because the mistake is more
instructive than the finding would have been.

What actually happens: **Qud draws its status screens over the LIVE playfield**,
which shows through the scrim and moves between frames. Two Qud captures of the
SAME screen, seconds apart, differ on **66.3% of pixels**. My whole-screen sweep
compared Raves against that without `--stable`, so Qud's animated world was
scored as a Raves error — and because the world fills the whole frame, the error
came out uniform (every band exactly 1.4%), which is precisely why it LOOKED
like a global tonal offset.

The transfer fit even said so and I misread it: Raves came out essentially
CONSTANT against Qud's varying value (R 7.0, G 30.0, B 29.0, slopes ~0). That is
not "Raves is darker by a constant" — it is Raves painting its own flat field
while Qud shows a moving world. The flat side was the stable one.

Corrected, masking pixels Qud does not hold still:

    equipment, whole screen, stable pixels only:  97.74%   (unmasked: 93.37%)

and its leaf score with `--stable` is 0.04. Both agree; the unmasked 93% never
measured Raves at all.

CONSEQUENCE FOR THE SWEEP ABOVE: those eight numbers are not a scoreboard. Any
whole-screen comparison of a Qud status screen MUST pass `--stable` (two Qud
captures) or restrict to leaf rects. The 0.83-wide band across eight screens was
not a shared defect — it was the same unstable background under all eight, which
is exactly what a shared cause looks like from the wrong instrument.

The `--stable` flag was written for this and its docstring says so. I had read it
earlier the same day and still walked into it.

### Leaf spec: skills (2026-08-07) — and why reputation is not here

`reports/2026-04-status-screens/parity-skills.json` added, measured off the
pc-parity golden. FIRST SCORE (with `--stable`, which this spec requires):

    outer_frame  15.09
    list_item    24.55
    list_next    27.33
    composite mean 25.94 (2 leaves)   frame mean 15.09 (1 leaf)

Real divergence, unlike the whole-screen 92.87 the sweep reported for this tab —
that number was measuring Qud's moving playfield. This one measures Raves.

The rects were taken FROM STABLE PIXELS ONLY: a naive row scan over a Qud status
screen finds the live world behind the scrim, not the UI. Every rect here was
derived from pixels that agree between two Qud captures seconds apart. Anyone
adding a spec for the remaining tabs must do the same or they will measure the
world and call it chrome.

REPUTATION IS BLOCKED, and not by anything in the spec format. `hv goto qud
status_reputation` reports success and Qud DOES NOT MOVE — its two captures came
back byte-identical to the skills ones, while `hv state` read
`qud=skills raves=reputation`. So Qud's tab navigation lands on skills for that
node. Writing a reputation spec from those captures would have described the
skills screen under a reputation filename, which is worse than having no spec.
Fix the qud status_reputation edge first; the spec is then ten minutes' work.

This is the same failure shape as the raves status edges and the Continue edge:
every step reports ok and the state does not move. Third instance on this branch
— worth a `verify` on each edge that asserts the DESTINATION, which the tree
supports and these edges do not all use.

### The qud status_reputation edge was never broken — the uiQueue had stalled

Retracting the blocker recorded above. `statustab Factions` resolved correctly
all along: `[raves] statustab -> Factions (6)` is in Player.log from the failing
run. What was wrong is that the heartbeat read `tab: SkillsAndPowers` with
**ui_age 236** — Qud's uiQueue had stopped draining, so the queued tab switch
never executed and Qud sat on whichever tab it was already showing.

That is the FIRST gotcha recorded on this branch, this morning, in the Map Editor
Test commit: a long-lived Qud can stop draining GameManager.uiQueue while still
serving the bridge, so mod-driven actions no-op silently and `ui_age` climbs
without bound. It cost a wrong "the edge is broken" conclusion twelve hours later
because I read the destination state and not `ui_age`.

After `hv restart qud`: ui_age 1, and `hv goto qud` PASSES for reputation, skills
and journal. **Check ui_age before diagnosing any mod-driven edge as broken** —
it is the difference between a stalled queue and a wrong recipe, and they look
identical from the destination.

### Leaf spec: reputation (2026-08-07)

`parity-reputation.json`, measured the same way as skills (stable pixels only,
score with --stable). First score on the pc-parity golden:

    outer_frame  15.87      list_item 24.95      list_next 30.61
    composite mean 27.78 (2 leaves)   frame mean 15.87 (1 leaf)

Alongside skills (15.09 / 24.55 / 27.33) that is the same shape at the same
magnitude, and both share the frame rect with equipment — whose frame scores
~0.04 now. So the frame geometry is right and something inside these two tabs
diverges consistently. Two tabs measuring alike is a lead, not two bugs.

### Rerun on a FRESH Qud: skills was an artifact, reputation is real

The skills spec was first scored against a Qud whose uiQueue had stalled, so its
capture was not the screen it claimed to be. Rerun after `hv restart qud` with
`ui_age` verified at 1 for both captures:

    skills      15.09 / 24.55 / 27.33   ->   3.01 / 4.95 / 4.00
    reputation  15.87 / 24.95 / 30.61   ->  15.56 / 24.23 / 29.62
                (frame / list_item / list_next)

**Skills is fine.** Its earlier score was measuring a stale frame. **Reputation
genuinely diverges** and reproduces across two independent runs on the golden.

RETRACTS the "two tabs measuring alike is one lead, not two bugs" note above.
They do not measure alike — one was a lie told by a stalled UI. The lead was an
artifact of the same stall that has now cost four wrong conclusions on this
branch, which is why `hv assert` reports `ui_age` at the top level as of
highvisor e7cae41.

STANDING RULE, learned the hard way and cheap to follow: record `ui_age` beside
any parity score. A capture from a stalled app is indistinguishable from a real
divergence once it is a number in a table, and the number outlives the session
that produced it.

Reputation is now the one open parity defect with a spec behind it: frame ~15.6
against equipment's ~0.04 on the SAME frame rect, so its panel chrome diverges
too, not just the rows.

### Reputation frame: narrowed to a geometry shift, NOT fixed

Measured on the golden with `ui_age` 1 and stable-pixel masking. Frame-band
mismatches (the rect minus its 16px inset interior), by edge:

    skills      1060   top 144   bottom  899   left   17   right 0
    reputation 12846   top 5497  bottom 5513   left 1836   right 0

Reputation is 12x skills on the SAME frame rect. The distribution is the useful
part: **the right edge is perfect (0) while top, bottom and left are all wrong.**
A colour or alpha difference would hit all four edges evenly. This is a shift or
a size difference that happens to leave the right edge coincident.

NOT FIXED, and deliberately not guessed at. My attempt to pin the exact frame
rules (long stable bright runs) was not reliable enough to trust — it found a
Raves h-rule at y=937 on both tabs with no Qud counterpart, and disagreeing
v-rules on skills (Qud 174/1744 vs Raves 1180) — which is more likely a weak
detector than a real asymmetry, and acting on it would be the fifth confident
wrong call on this branch today.

WHAT WOULD SETTLE IT, cheaply: crop the four frame edges of both apps on the
reputation tab and LOOK, the way the filter strip was settled. That took one
side-by-side crop and turned a wrong "anchoring" hypothesis into an exact
formula. The measurement above says where to crop — top, bottom and left, with
the right edge as the known-good control.

#### The crop settles it: reputation's CONTENT starts too high, the frame is innocent

Cropped the top frame band of both apps on the reputation tab (x140-1790,
y185-240) and looked. At the SAME screen y, Qud shows only the playfield through
the scrim; Raves is already drawing its list — "> — Antelopes … Reputation: 0"
with the description rows under it.

So `outer_frame` was never measuring a border. It was catching Raves' list text
intruding into a band Qud leaves empty. That is exactly why the edge breakdown
looked the way it did — top, bottom and left wrong with the right edge clean is
what CONTENT PLACEMENT looks like through a frame-shaped leaf, not what a
mis-drawn border looks like.

Same lesson as the filter strip, twice in one day: a leaf named `frame` scoring
badly does not mean the frame is wrong, it means something is wrong INSIDE that
leaf's rect. One crop answered what two rounds of clever pixel statistics could
not.

NEXT: measure Raves' first reputation row's y against Qud's and shift the pane's
content origin to match — the same shape of fix as the filter strip (derive the
origin, do not hard-code the reference). The list_item/list_next leaves at 24-30
are almost certainly the same offset seen through row-shaped rects, so one fix
should take all three leaves down together.

#### RETRACTED: the reputation "content origin" defect never existed — Qud was FROZEN

The whole reputation investigation above was scored against a Caves of Qud that
had stopped rendering. Proof, not inference: a screenshot taken fresh at 00:49
was **byte-identical** (same size, same md5 `fef1371116…`) to `N_reputation_q.png`
captured at 00:15. Thirty-four minutes, same frame, every pixel. The bridge
heartbeat cheerfully reported `scene: StatusScreensScreen, tab: Factions` the
whole time; the window was showing the plain playfield.

So "at the same y, Qud shows only the playfield through the scrim" was true and
completely misleading — Qud was not on the reputation screen at all. There was
no content-origin bug. The scores 15.56 / 24.23 / 29.62 measured Raves' correct
reputation pane against a stale playfield frame.

Two traps worth naming, because both made the bad data look good:

- **`--stable` cannot save you here.** It drops pixels the reference does not
  hold still between two captures. A frozen app holds EVERY pixel still, so the
  filter passed 99.9% of pixels through and reported the reference as rock
  solid. A stability check on a corpse reads as perfect stability.
- **`ui_age` is necessary but not sufficient.** The run recorded `ui_age 1` and
  was still wrong, because the value was sampled at a different moment than the
  capture. The reliable tell is cheaper and needs no bridge: **two successive
  captures of a live app always differ.** If `q.png` and `q2.png` are byte-equal,
  the app did not render and nothing measured against it means anything.

The stall recurs within ~10 minutes of a fresh start and **focusing does not
recover it** (measured: `ui_age` kept climbing 471→482 with the window focused).
Only a restart clears it. It has now caused five wrong conclusions in one day.

#### What the reputation pane actually got wrong (measured on a LIVE Qud)

Re-captured against a verified-live Qud (`ui_age 1`, two captures differing):
baseline **outer_frame 7.54 / list_item 6.31 / list_next 12.52** — real
divergence, about half what the frozen frame invented.

Cropping the Apes block side by side showed it immediately: Qud renders each
interest as its OWN paragraph, blank line between, faction name re-tinted at
each sentence start. Raves concatenated them into one run-on paragraph. Qud's
Apes block is 7 line slots, Raves' was 5, so every row below drifted upward
cumulatively — which is why `list_next` (further down the list) scored worse
than `list_item`.

`_wrapped` was destroying both halves of the data it was given:
`QudText.strip()` erased the `{{C|Apes}}` tint and `.replace("\n", " ")`
collapsed the paragraph breaks the exporter had faithfully carried across.

Then a UiProbe of the live `FactionsStatusScreen` settled the geometry exactly,
instead of fitting curves to noisy pixel bands:

    row heights   116.00   123.99   141.59   159.19
    minus 36 hdr   80.00    87.99   105.59   123.19
                =  floor    5*17.6   6*17.6    7*17.6

So **`det_h = max(80, lines * 17.6)`**, the 80 floor being the icon column. The
fixed 80 looked right for years because most factions sit under the floor.
Modelled in Python against all 18 probed rows first: 17/18 matched, and the one
holdout (Baetyls) has a first interest of *exactly* 60 characters — so Qud's
`blockWrap` breaks AT the limit, not past it. With `>=`, **18/18**.

Result, each step verified by re-scoring:

| leaf | frozen (void) | live baseline | + paragraphs & height | + newline fix |
|---|---|---|---|---|
| outer_frame | 15.56 | 7.54 | 6.90 | **6.42** |
| list_item | 24.23 | 6.31 | 3.75 | **2.92** |
| list_next | 29.62 | 12.52 | 12.71 | **5.14** |

The middle column is worth keeping: splitting on `"\n"` after `QudText.runs`
looked like a fix and scored like one on two leaves while making `list_next`
slightly worse. `runs()` maps through **cp437, where 0x0A is the printable glyph
◙** — the newlines were being DRAWN, not obeyed ("Oboroqoru's lair.◙◙Apes are
interested…"). Splitting before the cp437 conversion is what actually took
`list_next` from 12.71 to 5.14. The crop showed the ◙◙ instantly; the score
alone would have read as partial success.

NEXT: the dividers. Qud draws each column separator as a thin DASHED line —
2px wide at x=592/813, segments ~3px on / ~3px off, period ~6.1px — where Raves
fills the whole 7px `Border` rect solid. That is now the dominant term left in
`outer_frame`, and it is the one thing still visibly different in a side-by-side
crop of the top band.

#### Dividers: dashed, not solid

Implemented from measurement rather than the RectTransform: Qud's `Border` node
is 7 wide but the sprite inside paints a **2px dotted line down its centre** —
lit at x=592/593 and 813/814 against nominal 588.5/809.5, so centre +3.5. The
colour is a flat (77,106,115) at every sample over every background (opaque, no
blend), where Raves was filling all 7px with a darker (44,74,80). Dashes are
~3px on / ~3px off, period 6.105, anchored at the details box top.

Verified in the capture: Raves now lights exactly x=592/593 at (77,106,115),
and both apps' dash tops converge (368, 380, …).

`outer_frame` 6.42 -> 6.34. Small, as expected — the dividers are a thin
feature inside a 74,080px leaf — but it is a real 1:1 correction and the last
thing visibly different in a side-by-side crop of the top band.

Reputation now stands at **outer_frame 6.34 / list_item 2.92 / list_next 5.14**
(composite mean 4.03, from 9.41 on the live baseline). The remainder is
sub-pixel baseline rounding — Qud lands text lines at 346/364/382 where the
17.6 pitch puts Raves at 346/363.6/381.2 — plus glyph rasterisation. Both are
the same class of residual the equipment tab bottomed out at.

#### The guard: parity.py now refuses a frozen reference

`score --stable` exits 1 with `FROZEN REFERENCE` when the two Qud captures are
pixel-identical. A live Qud never renders two identical frames — the playfield
behind the scrim animates, and two captures normally differ on most pixels — so
identical means the app stopped rendering and the capture is a stale frame.

Verified both directions: it rejects the exact pair that produced the bogus
15.56/24.23/29.62 (exit 1), and still scores the live pair (exit 0).

This is the check that would have caught the whole thing in the first minute,
and it costs nothing. **`ui_age` is not a substitute** — that run recorded
`ui_age 1` and was still measuring a corpse, because the value was sampled at a
different moment than the capture. Compare the pixels you actually scored.

## Post-merge re-score — 2026-08-08 (Lumpy, merged `origin/main`)

Merged `origin/main` into `dd/pc-lumpy-merge` in both repos (raves `ed8810e`,
highvisor `4b6b2ce`). One conflict each, both trivial: `docs/testing.md` was a
pure append collision (kept both blocks), and the highvisor `gametree.json`
conflict was our bare `sleep: 1.5` against main's conditional `dismiss` on the
Raves title→in_game edge — took main's whole, since an idempotent conditional
beats hoping a delay covers it. Verified after resolving: JSON parses, 71
transitions, all 8 Lumpy `raves status_*` edges plus the toolkit subtree intact.
Mod redeployed (38 .cs) and Godot parse clean on the merged tree.

Reputation, re-scored on the golden with a verified-live Qud:

| leaf | pre-merge | post-merge |
|---|---|---|
| outer_frame | 6.34 | 6.37 |
| list_item | 2.92 | 2.93 |
| list_next | 5.14 | 5.14 |

Within capture noise (±0.03). **No regression from the merge.**

### The focus-keeper fix did NOT cure the stall

I expected `39c8134` to be the root cause — `bThreadFocus` gates
`GameManager.Update()`, which would explain a frozen view, an undrained uiQueue
and a Qud that focusing cannot revive. It is still the best mechanism on offer,
but the prediction was wrong: **Qud stalled again on the merged tree**, mid-run,
with the fix deployed and confirmed present in the deployed `Bridge.cs`.

Caught by the new `FROZEN REFERENCE` guard rather than by producing another
evening of confident nonsense, which is exactly what it is for. That is now two
saves in one session.

Worth checking next: the commit gates the keeper on **a connected client**, and
the daemon connects per-command and disconnects (`client connected` /
`client disconnected` pairs all through `Player.log`). If there is no persistent
client, the keeper may simply never engage on this box. That is a hypothesis
with an obvious test — hold a connection open and see whether the stall stops —
not a conclusion.

Also noted: after `hv restart raves` the window comes up 4267x2400 and an
`hv move` issued too early loses the race, so a capture silently comes back the
wrong size. `parity.py` fails loudly on the shape mismatch, which is fine, but
the placement should be verified rather than assumed — check `hv ls` reports
1920x1080 before capturing.

## The persistent-connection hypothesis: FALSIFIED — 2026-08-08

Added `clients` and `thread_focus` to the heartbeat so the focus keeper's two
inputs are observable, because "stalled" looked identical from outside whether
the keeper was idle, not running, or working fine. The keeper's gate is literally
`if (_server != null && _server.ClientCount > 0)`, so the hypothesis was that the
daemon's connect-per-command pattern left `ClientCount == 0` and the keeper never
engaged.

It does not. Measured across every provocation:

    clients = 1..4        thread_focus = true       (always)

**Raves is itself a persistent bridge client**, so the count is never 0 while the
pair is up. The keeper is engaged and holding `bThreadFocus` the whole time — and
the bad captures still happen. The gate is not the cause.

### What is actually happening

A Qud that is not rendering captures as the **playfield with no UI overlay**,
while the heartbeat correctly reports the status screen. The heartbeat was never
lying; the capture was. Measured with a tab-bar ink count (y 124–152, which every
status screen fills and the playfield leaves empty):

| capture | ui_age at shot | tab-bar ink | what the file shows |
|---|---|---|---|
| P1 | 3 | 576 | reputation screen |
| P2–P6 | 5–23 | 0 | playfield |
| FG / BG | 5 / 13 | 0 | playfield |
| FG2 | 1 | 576 | reputation screen |

**`ui_age` at the moment of capture is the predictor.** At 1 the capture is the
real screen; above ~3 it is a stale UI-less frame. Not the value logged before or
after the shot — the earlier runs sampled it at a different moment and read 1
while the shot itself was stale, which is exactly how this stayed hidden.

And the reason it drifts above 1: **`hv activate CavesOfQud` frequently does not
take.** Measured three attempts in a row where the foreground stayed elsewhere;
only the third brought `ui_age` to 1. So the earlier "focusing does not recover
it" (471→482) is at least as well explained by activate failing as by a hang. No
mod bug is needed to explain any of tonight.

### The procedure that follows

Before every Qud capture: activate, then **poll until `ui_age <= 2`**, retrying
the activate, and only then shoot. Do not trust a single activate, and do not
sample `ui_age` around the shot instead of at it.

The `FROZEN REFERENCE` guard is validated by this — the identical frames it
rejected were genuinely the stale playfield, not a legitimately static screen (I
suspected a false positive mid-investigation and was wrong; P2–P6 are playfield,
not reputation). It stays, but it is the backstop, not the check.

Unrelated but recurring: `hv restart raves` relaunches the Godot dev-run at
4267x2400 on this box. Use `hv layout pair` after a Raves restart rather than an
`hv move` on a fixed sleep, which races the window into existence.

### The poll is folded in: `parity.py capture`

The capture step was ad-hoc shell in every session, which is exactly why the
liveness mistake kept coming back — it was reinvented, or forgotten, each time.
It is now a command:

    parity.py capture <node> <prefix> [--no-goto]
    # drives both apps to the node and writes <prefix>_q.png, _q2.png, _r.png

Every shot goes through `hv shot --live`, which blocks until the app is actually
rendering and re-activates until it is. It also refuses to hand back a triple
whose windows are different sizes — not hypothetical, a Raves dev-run relaunches
at the display's default and silently produced a 2400-tall capture against a
1080-tall spec.

End-to-end on the golden, no hand-written bash: **6.37 / 2.93 / 5.15**, matching
the manual run. The first Qud shot needed **13 activate retries** before it
landed — that is the flakiness that cost the evening, now absorbed by the tool
instead of by whoever is watching.

Raves reports `--live skipped: state file has no ui_age`. Honest rather than
silent: `raves_state.json` carries no age field, so only Qud's liveness is
enforced today. Adding one to the Raves heartbeat would close that half.

### Raves reports `ui_age` too

`UiState` now carries `ui_age` alongside `scene`/`mode`/`pid`, so `hv shot --live`
gates on either app with one threshold. It counts seconds since the last
**presented frame**, not `_process` ticks: Godot keeps running the main loop while
a window is minimised or fully occluded, so a tick counter would read healthy for
exactly the case where the capture is stale. `Engine.get_frames_drawn()` only
advances when a frame actually reaches the screen.

Verified by stopping the rendering rather than by reading the code:

| state | ui_age |
|---|---|
| focused, rendering | 0 |
| minimised, +4s … +20s | 2 → 6 → 10 → 14 → 18 |
| restored | 0 |

And through the tool: a minimised Raves shot with `--live` reported
`ui_age 5`, re-activated twice, and captured at 0. It no longer prints
`--live skipped: state file has no ui_age`.

Both guards then earned their keep on the very next run. Restoring the minimised
window brought Raves back at 4267x2400, and `parity.py capture` refused the triple
with a size mismatch instead of handing over a 2400-tall capture to a 1080-tall
spec. `score` now fails the same way with a sentence rather than a numpy
boolean-index traceback from twenty frames deeper.

After `hv layout pair`, the full path — capture then score, no hand-written shell:

    outer_frame 6.28   list_item 2.81   list_next 5.28   (composite mean 4.04)

Same numbers as the manual runs within capture noise.

### The 2400-tall window, actually fixed

Two layers, and the second was the real one.

**The stage forgets.** `hv layout NAME` now records itself as the standing stage
and `hv restart` re-applies it once the app reports ready, so a relaunched window
comes back placed without anyone remembering to re-run the layout. Response
carries `relaid` so it is visible rather than magic.

**Raves was fighting the stage on a different clock.** That alone did not fix it:
the restart placed the window at 1920x1080 and it was 4267x2400 again by capture
time. `Main.gd` restores a saved `win` size from `raves_settings.json` when the
Holodeck loads — which happens when a status tab is opened, well AFTER placement.
The saved value was `[4267, 2400]`.

That late timing is why this read as "the restart raced the window" for most of
the evening. It was not a race at all; it was a second writer on a completely
different trigger.

The restore was already skipped in launch-qud mode, "because a saved size would
fight" QudLauncher's geometry. The same reasoning applies one layer out in 1:1
mode, where the stage owns geometry and Raves must match Qud's window exactly or
every leaf rect means a different thing in each app. Now gated on both.

The save side is gated too, and that matters for the human: in 1:1 mode the size
on screen is the STAGE's, so writing it back would quietly replace the size
chosen in user mode with whatever the last parity run used. The stored value is
carried through instead. Verified — `raves_settings.json` still reads
`[4267, 2400]` after a full parity run.

Measured end to end, restart through score with nothing done by hand:

    after restart:   1920x1080
    after Holodeck:  1920x1080      <- previously 4267x2400
    outer_frame 6.34   list_item 2.92   list_next 5.14

## FULL 2 across all eight status tabs — 2026-08-08 (golden `pc-parity`, merged tree)

Every capture liveness-gated (`ui_age` 1/1/0 on all eight), through
`parity.py capture`. First attempt failed six of eight, which was itself the
finding — see below.

| tab | whole-screen content_match | leaf scores |
|---|---|---|
| skills | 97.24 | outer_frame 3.08 · list_item 5.97 · list_next 3.86 |
| attributes | 98.33 | *(no leaf spec)* |
| equipment | 98.35 | outer_frame 3.66 · list_cat 4.64 · list_item 5.69 |
| tinkering | 98.81 | *(no leaf spec)* |
| journal | 96.88 | *(no leaf spec)* |
| quests | 97.02 | *(no leaf spec)* |
| reputation | 96.73 | outer_frame 9.28 · list_item 4.13 · list_next 9.25 |
| messagelog | 98.64 | *(no leaf spec)* |

### Six of eight failed first, and it was the bridge activate

Every failure read `wanted status_X, got <the PREVIOUS tab>`. The `statustab`
frames were landing in an undrained uiQueue and applying one step late, when the
next capture's activate happened to work. Silent by construction: a TCP write to
the mod cannot fail because the queue is parked, so the step reported ok and
simply never happened.

`_qud_bridge` was checking "is Qud frontmost" and, if not, activating and
sleeping a flat 2s. Both halves wrong in the same direction — the activate often
does not take, and frontmost is not the condition that matters, since a Qud that
IS frontmost but has stopped rendering drains nothing and paid no settle at all.
Replaced with the same `ui_age` settle the captures use. Three consecutive tab
hops then landed, and the re-run went eight for eight.

### Reputation moved 5.14 -> 9.25 with no code change, and it is not noise

Raves' captures across the two runs differ by 0.1%; Qud's by 6.2%. Stacking the
two Qud frames shows the same content at a **different scroll offset** (~28px).
A row-shaped leaf is exquisitely sensitive to that, which is the whole story.

So I widened the `--stable` window, on the theory that it masks only what moves
inside its 2.5s pair. That theory is wrong and the measurement says so: at 12s it
masked 1,046 px against 1,008 before, while 129,370 px actually vary between
runs. No stability window can mask a scroll. `--stable-gap` survives as an
option for a screen that genuinely animates; the default is back to 0 rather
than pay 12s a capture for nothing.

The real consequence: **leaf scores on a scrolling list are only comparable when
the list's scroll is pinned.** Within one run they are now exactly reproducible
(two consecutive runs returned identical 9.28 / 4.13 / 9.25). Across runs they
are not, unless the tab is entered the same way. Reputation's earlier 6.34 /
2.92 / 5.14 and today's 9.28 / 4.13 / 9.25 are both honest measurements of
differently-scrolled screens, and neither is a regression.

NEXT, and it blocks trustworthy list scoring: pin the scroll before capturing —
either drive the list Home as part of the status_* edges, or make the spec
anchor its row leaves to a landmark the way the item-popup spec already anchors
to its own top line. The anchor machinery exists (`anchor_row`); the status
specs just do not use it.

### The scroll is pinned, and the FULL 2 leaf numbers above are SUPERSEDED

Pinned by rebuilding the screen rather than by scrolling it: `parity.py capture`
now drives both apps out to `in_game` and back in before capturing any `status_*`
node, so each list comes up at the top. `--no-fresh` opts out.

Proof is the route test, not the mechanism: reputation captured directly, and
captured after visiting quests, journal and skills, now score **identically** —
6.27 / 2.81 / 5.28 both times, with Qud's two frames differing by 0.05% against
6.2% before.

Re-scored with the pin, superseding the unpinned rows in the table above:

| tab | content_match | leaf scores |
|---|---|---|
| skills | 97.98 | outer_frame 3.01 · list_item 4.96 · list_next 3.99 |
| equipment | 98.43 | outer_frame 3.61 · list_cat 4.09 · list_item 5.16 |
| reputation | 98.28 | outer_frame 6.27 · list_item 2.81 · list_next 5.28 |

Every one improved, because an unpinned capture could only ever add divergence.
Reputation's earlier 9.28 / 4.13 / 9.25 was a scrolled screen and is void;
6.27 / 2.81 / 5.28 agrees with the 6.34 / 2.92 / 5.14 measured directly after
the paragraph fix, which is the corroboration that matters — two runs days apart
in approach, same answer, once the fixture state is actually the same.

Reputation's content_match also moved 96.73 -> 98.28, the largest jump of the
three, which is what you would expect from the tab whose list was scrolled.

The five tabs without leaf specs (attributes, tinkering, journal, quests,
messagelog) still rest on whole-screen congruence alone, and those figures were
taken unpinned. They are less exposed — no leaf rect to slip against — but not
immune, and worth retaking whenever specs get written for them.

## Leaf specs for the remaining five status tabs — 2026-08-08

`parity-attributes/tinkering/journal/quests/messagelog.json`. Every rect measured
off a pinned Qud capture (card borders, text bands, the world-map panel found as
the large near-black region), not eyeballed from a downscaled sheet.

**Three of the five are EMPTY on the pc-parity golden** and the specs say so in
their own `note`: tinkering has no schematics, journal's Locations sub-tab no
entries, quests no active quests. So those specs measure chrome and empty-state
text, and the LIST rendering of three tabs remains completely uncovered. A
fixture with schematics, journal entries and an active quest is what would
actually close that, and it is worth more than any number below.

| tab | frame | content leaves |
|---|---|---|
| attributes | 3.55 | attr_card[0..5] 6.67–7.99 · attr_desc 23.94 · sec_header 21.26 |
| tinkering | 3.62 | filter_chip 14.93 · tab_hint 24.63 · empty_state 13.51 |
| journal | 5.93 | cat_strip 19.45 · worldmap 19.73 · empty_state 28.66 |
| quests | 4.41 | worldmap 19.23 · empty_state 21.25 |
| messagelog | 3.77 | log_head 22.11 · log_line 20.37 · log_para 11.86 |

The frames all land at 3.5–5.9, in line with the three established tabs, so the
pane chrome is consistently right. The content leaves at 12–29 are much worse
than skills/equipment/reputation's 2.8–6.3, and that gap is the finding: these
five tabs have had no leaf-level attention.

### Cropping the leaves paid for itself immediately

Two things a score alone would not have told me:

**A leaf was misnamed, not miscomputed.** tinkering's `empty_state` rect actually
framed `[Ctrl+Tab] switch to modifications`. The rect was right, the name was
wrong — renamed `tab_hint`, and the real empty-state line added as its own leaf
(13.51). A spec whose names lie about what they cover is worse than no spec.

**And it found a genuine bug.** Qud draws that hint with a boxed **Ctrl key
glyph**; Raves omits it and renders `[+Tab]`. That is the same class as the
ElliotSans and glyph-strip work — a missing first-party glyph, not a layout
error — and it is worth fixing on its own.

`messagelog log_head` scores 22.11 on text that reads identically in both apps,
so the remaining content divergence is dominated by ~1px baseline offsets on thin
glyphs, the same residual the equipment tab bottomed out at. Do not read 20-ish
here as "badly broken"; read it as "unexamined".

### The Ctrl keycap glyph — fixed, and it was never there

`StatusPaneTinkering` drew the mode hint from the literal

    "[{{W|+Tab}}] switch to %s"

directly beneath a comment reading "Qud's own hint string, with the Ctrl keycap
glyph it emits (U+E816)". The comment described an intention that the string
beside it never carried, so Raves rendered `[+Tab]` against Qud's `[Ctrl+Tab]`
for as long as the screen has existed.

Worth naming as a review hazard: the comment is *more* convincing than the code
at a glance, and a Private Use Area codepoint is invisible in source either way,
so nothing about reading that line suggests a bug. A parity leaf found it in one
crop.

Fixed by building the codepoint rather than typing it — `String.chr(CTRL_GLYPH)`
with `CTRL_GLYPH := 0xE816`, matching `QudText.GLYPHS`. The extracted atlas
already carried it (a 195x133 cell), so nothing needed re-exporting. Verified by
crop: the boxed keycap now renders.

`tab_hint` moved only 24.63 -> 23.49, and that is the expected size of the win,
not a disappointment — the glyph is ~200px of a 5,800px leaf. Reading the score
alone would have suggested the fix barely worked; the crop shows it worked
exactly.

NEXT on this tab, found by the same crop and measured rather than eyeballed:
**Qud draws a horizontal rule that Raves omits entirely.** 2px tall at y230-231,
spanning x158-1760 (1603px), colour (56,79,90) — the section separator that runs
behind and past the hint text. Absent in Raves at those rows (1150 lit px vs 0
across x600-1750). That, not the glyph, is the dominant remaining term in
`tab_hint`.

### The missing rule — fixed, pixel-exact

Qud draws a section rule under the tinkering mode hint that Raves omitted
entirely. Measured off the capture rather than guessed: 2px tall at y230,
spanning the full pane width x158..1760 (1603px), flat (56,79,90).

The part worth getting right was the ORDER. Sampling the rule's own colour showed
it continuous from 158 to 1760 with gaps only where glyphs sit, so it runs UNDER
the text and the text punches through — one rect drawn before the hint, not two
segments flanking it. Drawing it after would have struck the text out.

Verified numerically, not by eye alone: both apps now light exactly 1150 px at
y230 and y231 across x600-1750, at an identical (56,79,90).

    tab_hint   23.49 -> 20.17      composite mean 17.69 -> 16.20

**Still open on this leaf, and now the dominant term:** the Ctrl keycap
RASTERISES differently. Same 40px advance and near-identical box (qud h=14, raves
h=13), but Qud lights 225 ink px against Raves' 146 — Qud's keycap reads "Ctrl",
Raves' is a denser, muddier mark. That is the 201pt bitmap atlas being downscaled
to a 14px line: `fixed_size_scale_mode` scales it, it does not re-render it. Qud
draws the same asset crisply at target size. Fixing it properly means rendering
the glyph from a higher-resolution source or an SDF, which is its own job and
the same shape as the ElliotSans extraction.

### The keycap rasterisation: NOT fixed, and why I stopped

Reverted to `2024058`. Three attempts, all measured, none kept.

First, a correction to my own earlier measurement: the "keycap ink box" I quoted
used a 40px-wide window that BOTH apps filled, so `w=40` in each read as
agreement. Isolating the cap properly (columns 199-222, excluding the two rule
rows) gives:

    qud    20x12, 116 ink px
    raves  19x8,   38 ink px

Nearly the right width, two thirds the height. So it is not a sampling artefact
as I first reported — the glyph is drawn at the wrong SIZE.

| attempt | keycap | tab_hint |
|---|---|---|
| committed: cap at the 14px line, natural advance | 19x8, ink 38 | **20.16** |
| `generate_mipmaps`, set before AND after load | unchanged, ink 38 | 20.16 |
| cap at 18px, natural advance | 18x10, ink 83 | 21.07 |
| cap at 18px, advance pinned to 22.5 | 18x10, ink 83 | 21.76 |

`generate_mipmaps` does nothing for a bitmap font on either side of
`load_bitmap_font` — zero change in ink count. That hypothesis is dead, not
merely unproven.

Drawing the cap at 18px genuinely improves it (ink 38 -> 83 against Qud's 116,
height 8 -> 10 against 12) but widens the advance, pushing "+Tab] switch to…"
off Qud's x. That costs the leaf more than the better cap gains.

**Where it actually stalled: the instrument, not the renderer.** To place the
following text I measured the first column right of the cap carrying ink, and it
came out NON-MONOTONIC in the one parameter I control:

    advance 14.0 -> '+' ink at x227
    advance 18.0 -> '+' ink at x223
    advance 22.5 -> '+' ink at x227

A larger advance cannot move text left. The detector (threshold 70, >=2 lit rows
in a column) is picking the cap's right edge in some frames and the '+' in
others, so any constant fitted against it is fitted to noise. Tuning through it
would have produced a number that scored well by accident.

NEXT: build the pen position from a RELIABLE landmark before touching the draw
code again — the '+' stroke is a poor target next to a boxed glyph. Better: find
the "switch" word's left edge (a long, unambiguous ink run well clear of the
cap), solve the pen offset from that, and only then set the cap size and advance
independently. The cap size is already known good at 18px; it is purely the
placement of what follows that is unsolved.

### Keycap placement: FIXED (tab_hint 20.16 -> 7.58)

The blocker last round was the instrument. Naming a landmark ("the '+' stroke")
put the detector next to a boxed glyph and it caught the cap's right edge in some
frames, which read as a shift moving NON-MONOTONICALLY with the advance.

Replaced it with something that names nothing: cross-correlate the COLUMN INK
PROFILE of the whole trailing run (x236-560, rule rows dropped) and take the best
fit. It is self-validating — the reported shift must move 1:1 with the advance —
and it does:

    advance 14.0 -> raves -6px      advance 18.0 -> -2px      advance 22.5 -> +3px

Both clean fits put zero at **advance 20.0**, and that it equals Qud's measured
cap span (x201..220) is the corroboration: the advance IS the cap's width.

With placement pinned independently, the cap size became a clean single variable:
18 gives 18x10/83 ink, 20 gives 20x11/103, against Qud's 20x12/116. Kept 20.

    tab_hint   20.16 -> 7.87 (advance fixed) -> 7.58 (cap at 20)
    composite mean   16.20 -> 11.99
    trailing text    +0 px from Qud

Verified by crop as well as by score: the keycap reads "Ctrl" and the line aligns.

The lesson is the one that keeps recurring here, in its sharpest form yet: a
measurement that disagrees with itself is worth more attention than the thing it
was measuring. Three tuning attempts failed against the bad detector; one attempt
succeeded against the good one.

## Merge + regression — 2026-08-08 (main into `dd/pc-lumpy-merge`, both repos)

raves `1aa2297`, highvisor `93ee351`. One conflict each.

highvisor's was SEMANTIC, not textual: main deleted the `{game_live: false}`
fallback on the `title` node, because absence of bytes on a 0.35s probe is not
evidence of the title screen — it measured "Title Screen via=live" for 7 minutes
while Qud sat on the Modding Toolkit. That is the same failure family this branch
chased all session, from the other end: main removes the bad inference, we verify
the pixels (`hv shot --live`). Took main's note wholesale, appended ours beneath.
`selftest_plan` and `selftest_evaluate` both pass — the two that guard exactly the
logic main changed.

raves' was the usual `docs/testing.md` append collision; kept both.

Regression after redeploying the mod, reloading the daemon and restarting both
apps. `hv state` reports both apps `via=scene`, not `via=live` — main's change
working as intended.

| tab | expected | measured |
|---|---|---|
| skills | 3.01 / 4.96 / 3.99 | 3.01 / 4.97 / 4.00 |
| reputation | 6.27 / 2.81 / 5.28 | 6.28 / 2.81 / 5.27 |
| tinkering | frame 3.58, tab_hint 7.58 | 3.58 / 7.58 (exact) |
| equipment | 3.61 / 4.09 / 5.16 | 3.90 / 4.79 / 5.12 |

The pinned tabs reproduce to ±0.01, which is the scroll pin doing its job.

TWO CORRECTIONS TO MY OWN REPORTING, both found by this pass:

**The equipment spec has NINE leaves, not three.** doll_image/doll_frame/doll_cell
and filter_image/filter_frame/filter_cell were always there; every equipment
figure quoted earlier came through a `grep -E "^outer_frame|^list_"` that silently
dropped them. The spec did not change in the merge — my reporting was narrow. The
filter grid scores 1.64–7.27 and the doll leaves were never shown at all.

**Equipment drifted more than the others** (outer_frame 3.61 -> 3.90, list_cat
4.09 -> 4.79) where skills and reputation reproduced exactly. Not yet explained.
Equipment is the tab with the paper-doll and the filter strip, so it has live
content the pinned list tabs do not; worth a look before treating its numbers as
a baseline the way the other three now are.

## Equipment baselined, and the empty tabs opened up — 2026-08-08

### Equipment reproduces exactly; the "drift" was cross-session

Two back-to-back captures score identically — outer_frame 3.90, list_cat 4.80/4.79,
list_item 5.12, and every doll_/filter_ leaf to ±0.01. Qud's own two frames differ
by 0.05%, the same floor the pinned list tabs sit at.

So equipment is NOT unstable and IS baselined at those figures. The 3.61 -> 3.90
step I flagged was between sessions, not between runs — the same class as
reputation's scroll offset, and a reminder that a cross-session comparison is only
meaningful when the fixture state is identical. Within a session all four tabs are
now reproducible.

Also recorded: the doll leaves were never in any figure I reported. They are the
worst on this screen — doll_image 13.13-30.51 against list leaves at ~5 — and had
been hidden by a grep the whole time.

### The quests tab has list content for the first time

Started "What's Eating the Watervine?" through the mod's `startquest` bridge
command. Both apps now render a real quest list, so this tab's list rendering has
been measured for the first time:

    outer_frame 4.10 · worldmap 11.37 · quest_title 18.98
    quest_name 12.59 · quest_step 17.82 · quest_step2 18.36

The `empty_state` leaf is gone from the spec; it was measuring the absence of the
thing worth measuring.

**A real defect fell out immediately: the rows drift progressively.** Qud's rows
band at y278-289 / 298-312 / 338-349 / 359-369; Raves' at 279-289 / 300-313 /
342-352 / 363-376. One pixel low at the first row, four by the fourth — a row
pitch slightly too large, accumulating down the list. That is the same shape as
the reputation paragraph bug and should yield to the same treatment: derive the
pitch from Qud rather than carry a constant. `quest_step2` is positioned
deliberately to catch it.

Journal moved too but is not yet fixed: Qud shows three left-column bands to
Raves' two, and Qud's header runs x190-906 against Raves' x190-589.

### IMPORTANT: the quest is not durable, and must not be saved over the golden

It lives in the RUNNING game only. Making it a fixture needs a SECOND golden —
mutating `pc-parity` would invalidate every baseline just pinned against it
(skills, equipment, reputation, tinkering). That is a deliberate non-action here,
not an oversight: the next step is `pc-parity-rich` with the quest, schematics and
journal entries, kept alongside rather than replacing.

### Journal: the category strip is a DIFFERENT WIDGET, not a misaligned one

Cropping the header settled it in one look. Qud draws the journal sub-tab
selector as ICON BUTTONS — a `Q` keycap glyph followed by pictorial category
icons in boxes. Raves draws the category WORDS: "Locations  Chronology  Gossip
and Lore  Sultan His…".

That accounts for both symptoms exactly: Qud's header band runs x190-906 against
Raves' x190-589, and Qud has a band at y211-217 that Raves has nothing for. I had
been reading those as an alignment gap; they are two different controls.

So `cat_strip`'s 19.45 is not a fidelity number and should not be treated as one
— annotated in the spec accordingly. It becomes meaningful only once Raves draws
icons. The assets are plausibly already to hand: the `Q` is an input glyph from
the atlas we already load, and the category icons are the same class as the tile
exports.

This is the third time this session that a leaf scoring badly meant "something
here is wrong" rather than "this thing is misplaced" — filter strip, reputation
frame, now this. The crop answers it every time and the statistics never do.

### Tinkering: still unmeasured

No schematics on this golden, so its list rendering remains completely uncovered.
`filter_chip` (14.93) and `empty_state` (13.51) are chrome. Populating it needs
either a data-disk wish plus reading it, or a direct recipe grant — and like the
quest, it belongs in a `pc-parity-rich` second golden rather than mutating
`pc-parity`.

## Merge + regression — 2026-08-08 (second pull, both repos CLEAN)

raves `ed723fa`, highvisor `222f893`. **No conflicts either side** —
`docs/testing.md` and `gametree.json` both auto-merged this time.

Main brought one matched pair: raves `bfeb50e` ports Qud's popup BOX MODEL whole
(placement 6.75 -> 0.00) and highvisor `bbe412b` refreshes the item-popup leaves
to match. Same lesson as the keycap work this session — derive the model from the
game rather than tune constants at it.

`selftest_plan` + `selftest_evaluate` pass (gametree changed), Godot parse clean,
`hv state` reports both apps `via=scene`.

**All four baselines reproduce EXACTLY** after redeploy and restart:

| tab | baseline | measured |
|---|---|---|
| skills | 3.01 / 4.96 / 3.99 | 3.01 / 4.96 / 4.00 |
| equipment | 3.90 / 4.80 / 5.12 | 3.90 / 4.80 / 5.12 |
| reputation | 6.27 / 2.81 / 5.28 | 6.28 / 2.81 / 5.28 |
| tinkering | 3.58 / 7.58 | 3.58 / 7.58 |

Which is the point of having pinned them: a merge that touches a different screen
can now be confirmed harmless in one pass instead of argued about.

### The item popup CANNOT be driven on Lumpy — it has leaves but no route

Planned to score main's changed screen and could not. `item_popup` appears in
`gametree.json` only as LEAF NAMES under `equipment_item_popup`; there is no
transition to or from it, so `parity.py capture` has nothing to drive and the
screen is scored on main from committed reference captures.

Scoring main's committed set does validate that the merged spec and captures are
self-consistent, and they are — placement 0.00, image geometry 0.00, image colour
0.00, frame 2.28, text content 4.98. But that measures main's captures, not this
box, so it is NOT a Lumpy result and must not be quoted as one.

NEXT, and it is the gap worth closing: give the item popup a real route
(in_game -> equipment -> select item -> open popup) so it can be captured and
scored like every other screen. Everything else in the tree is drivable; this is
the one screen whose numbers can only be inherited.

### A route for the item popup: the mechanism exists, the ADDRESSING does not

`invaction` is the lever. `Bridge.cs`: `{"bridge":"invaction","args":{"id":…,"mode":…}}`
calls `InventoryExporter.Twiddle(id, mode)`, which opens "Qud's own item
interaction popup for the selected object" — exactly the screen
`parity-item-popup.json` measures, and the popup mirrors back over the popup
channel rather than being rebuilt.

**But `Twiddle` takes an ID, and a gametree edge cannot carry one.** This repo's
own rule (CLAUDE.md, the fixture workflow): *ids are NOT stable across a save
reload — resolve objects by NAME, never by a carried id.* An edge with a baked id
would work until the next reload and then silently open nothing, or the wrong
object. That is worse than no route: it would produce item-popup numbers that
look like a Lumpy result while measuring whatever the id happened to hit.

The other arm, `{"mode":"equip","part":…}`, needs no id and part names ARE stable
— but `EquipPicker(part)` raises the EQUIP PICKER, a different popup from the one
the spec measures. Wiring it would give a drivable route to the wrong screen,
which is the exact failure this session kept catching (a leaf whose name lies
about what it covers). Deliberately not done.

WHAT ACTUALLY CLOSES IT, and it is small: teach `invaction` a `name` argument
that resolves the object off the player's inventory by display name, the same way
`loadsave` resolves a save row from DISK metadata instead of taking a row number.
Then the edge is stable and readable:

    {"bridge":"invaction","args":{"name":"leather boots","mode":"twiddle"}}

Detection should already work — the mod's heartbeat carries a `popup` key and
Raves' UiState carries `_popup`, so `equipment_item_popup` can detect on the
popup signal rather than needing a new reporter.

Two more commands worth knowing about, found while looking: **`journalfixture`
and `tinkerfixture`** — the mod already ships fixture-populating commands for the
two tabs recorded above as empty and unmeasurable. `pc-parity-rich` may not need
wishes at all.

## Mac merge of `dd/pc-lumpy-merge` — 2026-08-08 (branch `dd/mac-pc-merge-0808`)

Executed against the plan in `highvisor/docs/merge-plan-2026-08-08.md`, whose execution log holds
the full detail. Both repos merged with **zero textual conflicts**; the re-survey at execution
time found **16 rewritten edges, not the 11 the plan predicted**, plus a chargen subtree (2 nodes,
9 edges, 3 detectors) that postdated it.

**SPOT 5/5, apps down.** typing-guard audit PASS with the field inventory 14 → 15 — checked by
DIFFING the inventory against `main`, not by reading the total, and the single new entry is
`MapEditorScreen.gd`'s `LineEdit`, exactly as predicted. `Godot --check-only` on all eight changed
`.gd` files plus Main.gd's deep check: every "failure" is the missing-autoload artefact and `main`
produces them identically. `dotnet build` 0 errors / 18 pre-existing CS0618, which clears
`PlayerBridgeLoadAttach.cs` against this Mac's Qud assembly.

**FULL 2 — both pinned baselines hold on the merged tree.**

| gate | baseline | result |
|---|---|---|
| Equipment, 33 leaves | B1 `reports/2026-08-08-parity-baseline/` | **33/33 within ±0.01**, max abs delta 0.010 |
| Item popup, 7 leaves | B2 `reports/2026-08-05-item-popup/` | **7/7 at exactly +0.00** |

The plan's sharp prediction about the PC's inventory filter-strip recentre **held**:
`filter_image[0..4]` moved `+0.00` in both capture runs, so the strip really is 12 cells and
`_filt_left(12) == 590.0 == the old hardcoded constant`.

**Score a small move TWICE before believing it.** The first capture run showed a *uniform* `+1.43`
on all five `filter_frame` leaves and `+0.71` on all five `filter_cell` leaves while
`filter_image` stayed flat; the second run reproduced B1 exactly. It was a capture-time artefact.
Two things to keep from that: a single capture can be off by ~1.4 on this leaf family, and the
uniform-across-a-whole-family signature is the tell that a move is NOT geometry — a real strip
shift makes the diffs vary wildly (the 38–79 numbers of 08-07), it does not move ten leaves by the
same number.

**What actually blocked the parity run for an hour, and it was not what it looked like.** Qud's
`in_game -> status_screens` edge failed with the pointer provably on target — the hover tooltip
("Character Sheet") was rendering on the right icon in the capture. The cause was that **the two
windows overlapped by 124px**: the toolbar click at global y=-1130 fell inside the Raves window
(-2156..-1076), so Raves received it. `hv launch raves` had already said
`anchor 'CavesOfQud' not found` — the auto-placer ran before Qud's window existed and Qud was
never placed — and that one line was the whole diagnosis, ignored for an hour while focus,
window chrome and click coordinates were investigated instead.

Corollaries worth not rediscovering:

- **`hv launch raves` is the pair start.** It spawns Qud BORDERLESS at 1920x1080, which is the
  geometry the baselines were captured at. Launching Qud first from Steam gives it a title bar,
  so the window is 1920x**1108**, every window-relative Y is 28px out, and captures no longer
  match a 1080-tall spec.
- **Do NOT run `hv layout loop` before a capture.** It is a desktop working arrangement and its
  saved rects resize Qud to 1793x997. `hv layout pair` — which `parity.py`'s size-mismatch message
  tells you to run — **does not exist on this machine**; only loop/halves/quads do.
- After placing, assert the two windows do not overlap. Stacked cleanly on the 4K
  (Raves 0,-2160 / Qud 0,-1080, both 1920x1080) the failing edge passed first try.

### FULL 3 / 4 / 1 on the merged tree — 2026-08-08

| gate | was | now |
|---|---|---|
| FULL 3, raves Wander whole-tree tour | 21/21 | **22/22 arrived, 0 EDGE, 0 ENV, 0 REFUSED** (18.2 min, RE-RUN — see the correction below). 22 because the chargen work added `caste`. |
| FULL 4, `hv loadsave` + popup round-trip | pass | pass — popup mirrored (`popup=menu`, `popup_n=2`) and answered; loadsave `via bridge loadsave`. |
| FULL 1, typing guard on the NEW field | 14 fields | **15** — typed `e j q x n 1 2` into the Map Editor blueprint filter, read **`ejqxn12`** back out of the pixels, scene never left `map_editor`. |

**The tour is a script now: `highvisor/tools/tour.py`.** It had been re-typed as ad-hoc shell in
every session, and an earlier version string-matched the daemon's output and mis-labelled an
arrival as REFUSED. Arrival is decided by `hv assert` — the tree's own detectors — never by
`goto`'s exit code. Its own first run reported 0/8 EDGE while every goto underneath had arrived,
because the assert was called with the wrong flags and could never pass; it now prints a warning
when a run fails EVERYTHING, since a clean sweep is far likelier to be a broken harness than N
simultaneous defects.

Three nodes arrived while `goto` said no (`status_quests`, `caste`, `blueprint_browser`) — those
edges' `verify` blocks disagree with the detector that finally resolves them. Open, not blocking.

**Two capture hazards found the hard way.** `hv layout pair` did not exist even though
`parity.py`'s size-mismatch message tells you to run it — it does now (Raves 0,-2160 / Qud
0,-1080, both 1920x1080, no overlap), trimmed to the two apps because `layout-save` otherwise
captures every window on screen. And the merged tree's layout restoration **re-applies the last
layout on every restart**: `hv loadsave` restarts Qud and silently put both windows back to
1793x997 mid-session. Any capture taken after a restart can be off-geometry — apply `pair` first.

### Map Editor context menu — RESOLVED 2026-08-08: macOS was rewriting Ctrl+left into a right-click

**Root cause, measured with a print at the top of `_canvas_input`: nothing was ever lost.** Every
button reached the canvas handler and dispatched correctly — right → `btn=2` → `_erase_top`,
middle → `btn=3` → `_open_context`. Both returned instantly because the cell was **empty**
(`objs=0`), and it was empty because the *setup step* had silently failed: macOS's display server
converts **Ctrl+left-click into a RIGHT button event** (the platform's "control-click == secondary
click" convention, applied in Godot's `GodotContentView` `mouseDown`/`mouseDragged`/`mouseUp`;
Godot exposes no switch for it). So Ctrl+click ran the **eraser**, never `_paint`. Nothing could
ever be painted, so the eraser and the context menu were correctly no-opping on empty cells.

The probe log is unambiguous — a converted click and a genuine one differ only in the ctrl flag:

```
canvas btn=2 pressed=true ctrl=true    <- Ctrl+left, converted by macOS
canvas btn=2 pressed=true ctrl=false   <- a real right-click
canvas btn=3 pressed=true ctrl=false   <- a real middle-click
```

**Fix** (`MapEditorScreen.gd`, `_mac` + `_canvas_input`): un-convert at the one place it enters the
editor — a RIGHT button carrying ctrl is really the Ctrl+left paint gesture, since a genuine
right-click always arrives with ctrl clear and Ctrl+right is not a Map Editor binding. The
paint-along-the-drag mask accepts the RIGHT mask too, because a ctrl+drag is held down as the right
button for its whole duration. Only **ctrl** is converted — shift and alt arrive as `btn=1`, verified.

Verified on the exported build: Ctrl+click paints an AgateWall, middle-click opens the per-object
menu (`objs=1`, all five rows drawn), right-click erases it, plain/shift/alt left unchanged.

**Two gestures remain UNVERIFIED, and not because of Raves: `hv drag` raises `NotImplementedError`
on the darwin backend** (only the abstract base in `backend.py` exists). Ctrl+drag continuous paint
and Shift+drag region select therefore cannot be exercised from the Mac at all — and the "Shift+left
region select **works**" row in the original table below was a shift *click* (a 1×1 region), not a
drag. Fix belongs in highvisor.

**Third false trail, and the important one: the ruled-out cause was the actual cause.** The entry
below records "NOT the ctrl modifier" as settled — on evidence that only ever showed ctrl *reaching*
Raves, never that it painted. This is another "check that cannot fail": the test's own precondition
was broken, so the thing under test could not have passed, and its silence was read as a finding
about right/middle click.

<details>
<summary>Original (superseded) diagnosis — kept for the false-trail record</summary>

### Map Editor context menu — now TESTABLE on the Mac, and it does not work — 2026-08-08

The merge's headline Raves feature (`MapEditorScreen.gd` +405: the per-object context menu and its
Qud-modding dialogs) was hung off MIDDLE click, and `backends/darwin.py` had no middle button — so
the plan recorded it as untestable here rather than broken. The Mac now has one, so it was tested.

**Result: right-click and middle-click do not reach the Map Editor canvas on macOS.**

Measured, all at the same cell, with Raves frontmost and an AgateWall painted under the cursor:

| gesture | canvas response |
|---|---|
| left click | **works** — "Selected Cell: 36, 10" |
| Ctrl+left (paint from palette) | **works** — cell painted |
| Shift+left (region select) | **works** — region drawn |
| **right click** (Qud's eraser, `_erase_top`) | **nothing** |
| **middle click** (`_open_context`) | **nothing** |

It is NOT the backend and NOT the OS: **Cmd+right-click in-game opened the feedback form**, so
right-button CGEvents reach Raves fine. It is also not an `_input`-level consumer — `FeedbackTool`
returns early unless the event is right+meta, `CellInspector` has no `_input`, and `Main.gd`'s
right/middle camera-pan branch is in `_unhandled_input`, which runs AFTER `gui_input`. So the
loss is inside the Map Editor's own canvas input path (`_canvas.gui_input -> _canvas_input`,
MapEditorScreen.gd:895/1027) and is unexplained. **Open.**

**Two false trails, recorded because both looked conclusive:**

1. "Ctrl does not reach Raves." It does. Ctrl+click paint appeared to fail only because the brush
   was **AcidGas** — a gas, which paints no visible pixels. Repeating with `AgateWall` painted a
   cell immediately. The check that settles it is file-based: Raves' in-game Ctrl+click inspector
   rewrites `selection.txt`, and its mtime moved.
2. "Middle click does nothing" at (700,500) — that point is on the *edge* of the painted cell.
   Re-aimed at the cell centre (698,487). Still nothing, so the finding survives, but the first
   reading was not yet evidence.

**Driving the Map Editor canvas needs `hv mouse` FIRST.** A bare `hv click` warps and clicks but
Godot never updates its own cursor position, so the editor reported `Mouse Position: 0, 0` and
`Selected Cell: none` while clicks "succeeded". `hv mouse <win> x y`, then click.

</details>

### Correction — the first FULL 3 run could not have failed, and what it hid

`hv assert` returns **both** `ok` (the envelope: the op ran) and `passed` (the verdict).
`tour.py` read `ok`. So every node counted as arrived regardless of the assertion, and the
first 22/22 was guaranteed before the tour started — it was reported as a result before being
caught. Ninth instance of this family recorded in this repo.

The tour now reads `passed` and **exits** rather than guessing if that field is ever absent.
Re-run from scratch: **22/22, 0 EDGE / 0 ENV / 0 REFUSED, 18.2 min.** The number was right, but
only the second run is evidence for it. Also: no node printed `(goto said no)` on the re-run
(the three that did on the first run all drove cleanly), and `status_quests` went 39.2s → 14.2s.

**The bug was hiding a real gap: `map_editor` had no `raves` detector.** Its `detect` block in
`gametree.json` carried a `qud` entry only, so Raves — which publishes `scene=map_editor` —
resolved as `running · unknown screen  via=window`, and every assert on that node timed out
silently under the broken check. Added; it now reads `Map Editor  scene=map_editor  via=scene`.

Also landed (Mac-side Stage H): `plat_mac.qud_install_dir()`, so `tools/capture/fonts.py` no
longer carries a `getattr(plat, "qud_install_dir", None)` fallback plus a duplicate copy of each
platform's path. Verified end-to-end — the extractor carved 4 faces out of this Mac's install
through the unified call.

### Second merge with Lumpy, and the letter-key question settled — 2026-08-08

`origin/dd/pc-lumpy-merge` merged again (their answers, the WM_CHAR/VK fix, `hv bridge`, the
chargen carousel). Detail and the conflict-by-conflict resolutions are in
`highvisor/docs/merge-plan-2026-08-08.md`.

**The letter keys: both of us were half right.** Lumpy measured that on Windows `k/x/e/n/q` do
nothing while `j` raises a PopupMessage *in Qud* — so in 1:1 Raves forwards letters to Qud and
`MainFrame.STATUS_TAB_KEYS` never sees them. Their conclusion (use one form everywhere) is right.
Their reason — "identical on both platforms" — is not: **measured here, `hv key raves k` opens
Skills, and so does F2 + tab-click.** The letters do reach MainFrame on macOS. So the ground for
one form is that F2 + tab-click works on BOTH and the letters work on one. The per-OS seam is gone
from all seven status edges, and the note now carries both machines' measurements — worth keeping
distinct, because a future Windows fix to the forwarding cannot be inferred from macOS behaviour.

**Gates on the merged tree:** SPOT 5/5 · B1 Equipment **33/33 within ±0.02** · B2 item popup
**7/7 at +0.00** · raves whole-tree tour **22/22, 0 EDGE / 0 ENV / 0 REFUSED** · qud tour
**30/31**, whose one EDGE (`title->modding_toolkit`, a coordinate double-click) passed twice on
immediate retry.

**The Map Editor context menu works on macOS now** — ctrl+click paints an AgateWall, middle-click
opens the five-row per-object menu, right-click erases. The earlier "right and middle click are
dead" reading was wrong: macOS's display server converts Ctrl+left into a RIGHT button before Godot
sees it, so Ctrl+click ran the ERASER and nothing could ever be placed — both handlers were
correctly no-opping on an empty cell. `MapEditorScreen.gd` un-converts on `btn==RIGHT && ctrl`.
The precondition of the test was broken and its silence was read as a finding.

**A UI-sampler latch worth knowing about.** `StartupHook._uiSamplePending` is cleared by the
sampler task itself, so a task queued and never run latches it true forever and sampling stops
silently. That only became load-bearing with Lumpy's positive title naming, which needs a FRESH
sample: after one deploy Qud sat at its title reporting `scene=MainMenu` and `hv state` answered
`unknown` — the root of most Qud routes. A clean `hv restart qud` fixed it. The watchdog added here
re-arms and logs; it did NOT fire in the clean run, so the restart is what recovered detection,
not the watchdog.

## A standing fire, for anything that burns

Fire in normal play is intermittent and short — a dawnglider's flaming ray lights you for a turn or
two, then it is out, and by the time a rebuild finishes there is nothing to look at. Several rounds
of flame/smoke tuning were "verified" against a character who had stopped burning. These zones burn
on their own; `zonetp` reaches any of them without touching the character sheet:

| zone | what is there |
|---|---|
| `JoppaWorld.53.3.2.2.9` | **the flame room** — Crematory: 22 `WalltrapFireCrematory`, 184 conveyor pads, Ashes, Grave Moss, 4 Graverobbers |
| `JoppaWorld.53.3.1.2.9` | the other Crematory — 180 conveyor pads, 13 animated objects, no walltraps |
| `JoppaWorld.53.3.0.2.9` | Columbarium — conveyor drives + Crematory Mainframe Status Panels |
| `JoppaWorld.53.3.0.2.8` | Lower Crypts — graves, Grave Goods, and a **Campfire** (a fire that just stays lit) |

```bash
hv bridge zonetp zone=JoppaWorld.53.3.2.2.9 x=39 y=14
```

**The zone id encodes depth: `strata high = 10 - z`**, the last component. `.2.9` is 1 stratum high,
`.2.6` is 4, `.0.1` is 9. That is how the Crematory was found — the graves sat at z=8 and the room
"below the graves" is z=9.

**A blocking popup silently eats every bridge command.** The mod refuses them with a reason ("Qud is
on PopupMessage, where the turn thread is parked and Server.Incoming never drains"), and that
refusal only reaches Qud's `Player.log` — the caller sees a command that appears to do nothing. A
hop loop must clear popups BETWEEN hops (`hv back`), not once at the start: a zone arrival can raise
one. Ten minutes of a survey run went into a wall this way, every command refused, nothing logged
caller-side.

**Being `wet` resists ignition** — worth knowing when you are standing in a flame room wondering why
nothing catches.

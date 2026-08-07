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

**NOT RUN:** FULL 1 (live typing guard) and FULL 2 (parity) were not repeated on the merged
tree. They were run pre-merge and neither touches the merged surface, but that is an argument,
not a measurement — treat them as unverified here.

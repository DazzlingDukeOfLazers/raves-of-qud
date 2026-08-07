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

# FULL 1 — live typing guard, 2026-08-18

Ran the tier's first item, open since 2026-08-17 (the route to Raves' Options screen looked
broken; it was not — see below). Pin: `Cirdidinus Fegina` (Classic), Joppa
`JoppaWorld.11.22.1.0.10`, both windows 1920x1080 on the 4K, Raves in **user** mode.

Method per field: focus it, type `e j q x n 1 2`, then check BOTH halves — the characters land
in the field (read back from a screenshot, never from an `ok: true`), and `hv state` does not
change screen (no ability, tab, or menu fires).

## Result: all 7 categories PASS

`docs/testing.md` names seven categories. Host and port are one category there; counted as
separate widgets it is 8 fields, all verified.

| # | category (docs/testing.md) | widget | characters land | no screen fired |
|---|---|---|---|---|
| 1 | feedback note (Cmd+Right-click an ELEMENT) | `FeedbackTool.gd` TextEdit | `ejqxn12` | stayed `in_game`, `popup=feedback` |
| 2 | Options search | `OptionsScreen.gd` LineEdit | `ejqxn12` | stayed `options` |
| 3 | Options host/port | `OptionsScreen.gd` LineEdit x2 | `127ejqxn12.0.0.1` / `ejqxn1248710` | stayed `options` |
| 4 | status-screen search | `StatusScreens.gd` LineEdit | `ejqxn12` | stayed `status_skills` |
| 5 | control-mapping | `ControlMappingScreen.gd` LineEdit | `ejqxn12` | stayed `control_mapping`, nothing rebound |
| 6 | chargen name | `PopupOverlay.gd` LineEdit (mirrored AskString) | `ejqxn12` | both apps held their popup state |
| 7 | tile report | `TileReport.gd` TextEdit | `ejqxn12` | stayed `in_game` |

Nothing was committed by the test: host/port restored to `127.0.0.1` / `48710`, the tile report
and feedback note were CANCELLED, and the wish prompt was cancelled rather than submitted. The
character was at Joppa `.1.0.10` (79,7) before and after.

### Where "chargen name" actually lives (row 6)

**Raves' chargen has no name field of its own** — `ChargenCardScreen.gd` contains zero LineEdits,
and `CharacterCreator.gd` is the "become anything" menu whose LineEdit is a blueprint *filter*, not
a name. Qud owns the naming step: it is a `Popup.AskString`, mirrored into Raves as popup kind
`input` and rendered by `PopupOverlay.gd`. So the widget under test is that mirrored input, raised
here with `CmdWish` — the way `docs/testing.md`'s own popup-kinds table says to raise an AskString.
This is the right target rather than a substitute: it is the same LineEdit a chargen name would
use, and `PopupOverlay.gd:_input` is one of the two EXEMPT dispatchers in the SPOT audit (it must
handle Esc/Enter *while* typing), which makes it the one most worth checking live.

### The two that matter most

**Control mapping** is a key-BINDING screen — a leaked key rebinds a control rather than merely
opening a menu. **The tile-report note** is typed straight over the live Holodeck, where every one
of `e j q x n 1 2` is a live binding. Both held.

## Two harness findings, both now in docs/gotchas.md

**`hv text` silently no-ops on Godot-drawn fields.** It returned `ok: true` with detail
`no editable AX element found` and nothing arrived, while the caret was visibly blinking in the
field. Godot's `LineEdit` exposes no AX text element, so `hv text` falls back to a HID tap the
status screens drop. `hv key` per character works. Options' fields DO take `hv text`, so it is
per-field — which is why every field here was read back from a screenshot. A check that reports
success while doing nothing is the same defect class this suite exists to catch.

**The Options route was never broken.** `hv goto raves options` from `in_game` on a CLASSIC save
restarts Raves by design: the direct `in_game -> title` edge quits via `CmdQuit`, hits Qud's
Classic-only "type ABANDON to confirm" prompt, and deliberately refuses to type it (completing it
would end a permadeath run). The planner reads that refusal, excludes the edge, and re-plans onto
the `* -> title` RESTART route. Verified safe: only the Raves process is killed — Qud's pid, zone
and player position were identical across the restart. It costs ~20s and produces a new pid and no
crash report, which is what made it look like a crash on 2026-08-17 when the display topology was
also changing mid-run.

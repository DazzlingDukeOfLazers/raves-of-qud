# FULL 1 — live typing guard, 2026-08-18

Ran the tier's first item, which had been open since 2026-08-17 (the route to Raves' Options
screen looked broken; it was not — see below). Pin: `Cirdidinus Fegina` (Classic), Joppa
`JoppaWorld.11.22.1.0.10`, both windows 1920x1080 on the 4K, Raves in **user** mode.

Method per field: focus it, type `e j q x n 1 2`, then check BOTH halves —
the characters land in the field (read back from a screenshot, never from an `ok: true`), and
`hv state` does not change screen (no ability, tab, or menu fires).

## Result: 6 of 7 fields PASS, 1 not reached

| # | field | characters land | no screen fired | verdict |
|---|---|---|---|---|
| 1 | Options search | `ejqxn12` | stayed `options` | PASS |
| 2 | Options Host | `127ejqxn12.0.0.1` (mid-string) | stayed `options` | PASS |
| 3 | Options Port | `ejqxn1248710` | stayed `options` | PASS |
| 4 | status-screen search | `ejqxn12` | stayed `status_skills` | PASS |
| 5 | control-mapping search | `ejqxn12` | stayed `control_mapping`, nothing rebound | PASS |
| 6 | tile report note | `ejqxn12` | stayed `in_game` | PASS |
| 7 | chargen name | — | — | NOT REACHED |

Host and Port were restored to `127.0.0.1` / `48710` after testing; the tile report was
**cancelled**, not submitted.

Two of these are the cases that actually matter. **Control mapping** is a key-BINDING screen, so a
leaked key would rebind a control rather than merely open a menu. **The tile report note** is typed
straight over the live Holodeck, where every one of `e j q x n 1 2` is a live binding. Both held.

Field 7 (chargen name) was not reached: it lives behind the character-creation chain, and getting
there means leaving the live game. Not a failure — untested.

## Two harness findings, both now in docs/gotchas.md

**`hv text` silently no-ops on Godot-drawn fields.** It returned `ok: true` with detail
`no editable AX element found` and nothing arrived, while the caret was visibly blinking in the
field. Godot's `LineEdit` exposes no AX text element, so `hv text` falls back to a HID tap the
status screens drop. `hv key` per character works. Options' fields DO take `hv text`, so it is
per-field — which is exactly why the field must be read back from a screenshot. A check that
reports success while doing nothing is the same defect class this suite exists to catch.

**The Options route was never broken.** `hv goto raves options` from `in_game` on a CLASSIC save
restarts Raves by design: the direct `in_game -> title` edge quits via `CmdQuit`, hits Qud's
Classic-only "type ABANDON to confirm" prompt, and deliberately refuses to type it (completing it
would end a permadeath run). The planner reads that refusal, excludes the edge, and re-plans onto
the `* -> title` RESTART route. Verified safe: only the Raves process is killed — Qud's pid, zone
and player position were identical across the restart. It costs ~20s and produces a new pid and no
crash report, which is what made it look like a crash last session when display topology was also
thrashing.

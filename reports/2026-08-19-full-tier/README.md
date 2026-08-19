# FULL tier — 2026-08-19, at `the-user-mode-seam-update`

Pin: `Cirdidinus Fegina` (Classic), Joppa, both windows 1920x1080 stacked on the 4K
(main display is 1512x982, so the pair cannot live there). Raves in **user** mode except
where a section says otherwise.

## Result: 4/4 run, no regression attributable to the tag

| item | result |
|---|---|
| FULL 1 — live typing guard | **7/7 categories pass** |
| FULL 2 — 1:1 parity sweep | no attributable regression (noise-controlled) |
| FULL 3 — menu recipes | Raves **23/24**, Qud **31/31** |
| FULL 4 — mod round-trip | **pass**, all parts |

## FULL 1 — live typing guard, 7/7

Method per field: focus it, type `e j q x n 1 2`, then check BOTH halves — the characters
land (read back from a screenshot, never from an `ok: true`) and `hv state` does not change
screen. `hv key` per character, because `hv text` no-ops on most Godot-drawn fields.

feedback note · tile report · status-screen search · control-mapping · chargen name
(the mirrored `AskString`, raised with `CmdWish`) · Options search · Options host/port.

Host and port were restored to `127.0.0.1` / `48710`; every form was cancelled, and the
wish was cancelled rather than submitted.

**A false failure I nearly filed.** Typing into the tile report jumped Raves to
`status_equipment` — exactly what a leaked `x` looks like. The screenshot showed the
placeholder still dimmed, so nothing had landed: the click had missed the field and the keys
correctly reached the global handler. Clicking the OCR-measured centre passed cleanly. **A
screen firing is only guard evidence once you have proved the field had focus.**

**And then the guard proved itself.** Later, with that field focused, an `x` meant to open the
status screens typed into the field instead. That is the runtime case the SPOT audit cannot
reach, arriving by accident.

## FULL 2 — 1:1 parity, status_equipment

| | run 1 | run 2 | 0.8.2 baseline |
|---|---|---|---|
| image | 8.40 | 3.56 | 4.30 |
| frame | 3.91 | 2.63 | 2.10 |
| composite | 4.01 | 3.07 | 3.06 |

Both runs are the SAME build, minutes apart. Image swings **4.84** between them — larger than
any gap to the baseline — and run 2 lands essentially on it. Run 1 is a first-capture-after-
launch artifact. **Score this screen twice or not at all**; a single run is inside the noise.

## FULL 3 — menu recipes

**Raves 23/24** (18.6 min). One EDGE, `raves:title->continue#34`: it lands `in_game` rather than
the `loadgame` picker, because Qud already has a live session for Continue to resume. Pre-existing,
unrelated to this tag, still filed.

**Qud 31/31, EDGE 0** (96.3 min) — including the seven that failed the previous run (`options`,
`records`, and the five `me_menu_*`). Nothing in Qud's routes changed between the two runs, so
those failures were ENVIRONMENTAL, not tree defects: the earlier run was taken during the
display-topology churn against the Wander golden, this one on a stable rig. The chip for them is
stale. Several nodes report `(goto said no)` while still arriving — the tour decides arrival by
`hv assert`, never by `goto`'s exit code, which is exactly the distinction it exists to make.

## FULL 4 — mod round-trip, pass

Popups mirror and answer; `statustab -> journal (4)` moved the reported tab; autoexplore, wait
and POI each reached Qud and raised a popup that mirrored back.

**The popup id was 24 this run, not 1.** Answers are refused against a stale id, so read the id
off the announcement rather than assuming — `fixture.py twiddle` prints it.

`fixture.py`'s own inline "raves mirror: (not mirroring)" line fires too early to be believed;
`fixture.py state` a moment later showed `popup=menu` both times. Trust the state read.

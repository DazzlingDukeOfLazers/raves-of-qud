# Menu parity scoreboard — V3 baseline (2026-08-03)

Same-screen pairs driven + captured entirely via `hv goto`/`hv shot` (recipes and
first-party scene asserts validated both apps; AUTO_META disabled so titles stay put).
Metrics over full 1920×1080 frames: mean |Δ| per channel, and % pixels with any
channel Δ>32. Playfield congruence for reference: mean-diff ≈ 2, hot ≈ 0%.

| screen  | meanAbsDiff | %px>32 | verdict |
|---------|------------:|-------:|---------|
| title   |  7.35 |  6.6% | layout aligns after the chromeless fix; remaining heat = wordmark x-offset, menu hover/selection styling, hint bar, version-line ("build …" extra in Raves) |
| options | 15.80 |  4.8% | RAVES section now HIDDEN under --one-to-one (raves_solo passes it; 1:1 locked for the run) — remaining delta is pure layout: Raves is a narrow centred column + Save/Load preset bar; Qud is a full-width two-pane with left category rail |
| records | 18.44 | 11.0% | different design generation: Raves = "◆ Records ◆" score-list + summary pane; Qud = ENDED RUNS entry stack with left rail (Ended Runs / Daily ×2 / Achievements) + per-entry delete |
| mods    |  5.10 |  2.9% | ✅ **DONE — Daniel signed off 2026-08-03.** Full Qud reproduction incl. container grid (one-cell header + [thin][list][pane][thin] + full-width footer line + darkspace), frame sprites (5-dot corners, imperfect borders), 7×7 dither tiles (bands/chips/highlight, phase-anchored), hover-SELECT persistent highlight (hv mouse discovery), dotted row separators, `<...>` path elision, exporter version/size fixes. Residual = glyph AA + title-screen corner below the panel |

(First baseline had title 14.60/13.4% — a systemic ~28px offset from Raves' window
title strip. Fixed at the source 2026-08-03: 1:1 runs CHROMELESS like Qud's
-popupwindow, and both windows now tile the 4K exactly — Qud flush to the display
bottom at CG (693,-1080), Raves directly above at (693,-2160), gap 0, because
1080+8+1080 never fit the 2160pt display. Placement goes through Raves'
window_rect.json file channel; macOS AX cannot move a borderless Godot window.)

## Suggested work order

~~mods~~ (DONE) → title polish (wordmark offset, hover styling, version line)
→ options (two-pane + rail relayout) → records (full redesign to the ENDED RUNS
stack + left rail).

Files: `{screen}_{qud|raves}.png` + `contact_sheet.png` (qud | raves | diff>32 per row).

# Menu parity scoreboard — V3 baseline (2026-08-03)

Same-screen pairs driven + captured entirely via `hv goto`/`hv shot` (recipes and
first-party scene asserts validated both apps; AUTO_META disabled so titles stay put).
Metrics over full 1920×1080 frames: mean |Δ| per channel, and % pixels with any
channel Δ>32. Playfield congruence for reference: mean-diff ≈ 2, hot ≈ 0%.

| screen  | meanAbsDiff | %px>32 | verdict |
|---------|------------:|-------:|---------|
| title   |  7.35 |  6.6% | layout aligns after the chromeless fix; remaining heat = wordmark x-offset, menu hover/selection styling, hint bar, version-line ("build …" extra in Raves) |
| options | 15.56 |  4.6% | partially mirrored (SOUND sliders etc.) but Raves is a narrow centred column with its own RAVES section + Save/Load preset bar; Qud is a full-width two-pane with left category rail |
| records | 18.44 | 11.0% | different design generation: Raves = "◆ Records ◆" score-list + summary pane; Qud = ENDED RUNS entry stack with left rail (Ended Runs / Daily ×2 / Achievements) + per-entry delete |
| mods    | 16.50 | 15.5% | closest content (same two mods, same metadata lines); differs in frame ("◆ Mods ◆"), selection styling, preview pane behaviour, bottom command bar (Qud: space/v/Save+Reload/undo) |

(First baseline had title 14.60/13.4% — a systemic ~28px offset from Raves' window
title strip. Fixed at the source 2026-08-03: 1:1 runs CHROMELESS like Qud's
-popupwindow, and both windows now tile the 4K exactly — Qud flush to the display
bottom at CG (693,-1080), Raves directly above at (693,-2160), gap 0, because
1080+8+1080 never fit the 2160pt display. Placement goes through Raves'
window_rect.json file channel; macOS AX cannot move a borderless Godot window.)

## Suggested work order

mods (bounded scope: frame, selection styling, preview pane, bottom command bar)
→ title polish (wordmark offset, hover styling, version line)
→ options (two-pane + rail relayout) → records (full redesign to the ENDED RUNS
stack + left rail).

Files: `{screen}_{qud|raves}.png` + `contact_sheet.png` (qud | raves | diff>32 per row).

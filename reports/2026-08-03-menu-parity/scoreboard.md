# Menu parity scoreboard — V3 baseline (2026-08-03)

Same-screen pairs driven + captured entirely via `hv goto`/`hv shot` (recipes and
first-party scene asserts validated both apps; AUTO_META disabled so titles stay put).
Metrics over full 1920×1080 frames: mean |Δ| per channel, and % pixels with any
channel Δ>32. Playfield congruence for reference: mean-diff ≈ 2, hot ≈ 0%.

| screen  | meanAbsDiff | %px>32 | verdict |
|---------|------------:|-------:|---------|
| title   |  3.04 |  2.4% | layout aligns after the chromeless fix; remaining heat = wordmark x-offset, menu hover/selection styling, hint bar, version-line ("build …" extra in Raves) |
| options |  4.77 |  3.9% | **1:1 REBUILD (2026-08-03)**: Qud console-screen reproduction — interlace + gamma comp (shared w/ records), dotted rail divider, right-aligned category rail (click-jumps), OPTIONS header w/ functional search field + magnifier + advanced toggle, full-width rows (dotted-track sliders w/ dither thumbs, [■] checkboxes, value lists w/ gold current), scroll track, [Esc] Back chevron, hint bar. Rows visual-first (write-back stays user-mode). Pitches tuned: DISPLAY header lands px-exact (626) |
| records |  3.29 |  2.4% | **1:1 REBUILD (2026-08-03)**: full ENDED RUNS reproduction — bare interlaced bg (Qud console-style: odd rows ×0.5, a filter Mods lacks!), dotted rail divider + end caps, right-aligned rail, entry stack from Details parsing (date/cause/score/turns), persistent dither selection + > cursor + delete, dotted separators, 10px scroll track, [Esc] Back chevron, hint bar. 2D-canvas gamma compensation (_q ×1.13 above 20) discovered + applied. Remaining: title letterspacing, scroll thumb geometry, glyph AA |
| picker  |  2.23 |   — | **NEW 1:1 BUILD (2026-08-03)**: Continue → LOAD GAME (ModernSaveManagement) — reads Synced/Saves/*/Primary.json off disk (newest first), per-save char tile recoloured FColor/DColor via QudTiles at Qud's ×3.646 non-integer scale (H-FLIPPED — the sprite-facing rule; non-integer NEAREST reproduces Qud's duplicated-row texture), dotted icon frame w/ measured dash cadence (gold+taller when selected), screen-phase-anchored 7×7 selection dither (measured colourway, ≠ mods tile), hover-select persists, gold selected header, Total-size line stays dim even selected, [Esc] Back + nav/select/delete hint. Best score on the board. Residual = glyph raster on bright rows, hint/title letterspacing family |
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

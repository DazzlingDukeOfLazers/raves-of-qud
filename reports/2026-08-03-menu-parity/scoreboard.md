# Menu parity scoreboard — V3 baseline (2026-08-03)

Same-screen pairs driven + captured entirely via `hv goto`/`hv shot` (recipes and
first-party scene asserts validated both apps; AUTO_META disabled so titles stay put).
Metrics over full 1920×1080 frames: mean |Δ| per channel, and % pixels with any
channel Δ>32. Playfield congruence for reference: mean-diff ≈ 2, hot ≈ 0%.

| screen  | meanAbsDiff | %px>32 | verdict |
|---------|------------:|-------:|---------|
| title   | 14.60 | 13.4% | layout matches; a GLOBAL vertical offset ghosts every glyph (see systemic #1) + background tint darker in Raves |
| options | 15.59 |  4.7% | partially mirrored (SOUND sliders etc.) but Raves is a narrow centred column with its own RAVES section + Save/Load preset bar; Qud is a full-width two-pane with left category rail |
| records | 18.28 | 11.3% | different design generation: Raves = "◆ Records ◆" score-list + summary pane; Qud = ENDED RUNS entry stack with left rail (Ended Runs / Daily ×2 / Achievements) + per-entry delete |
| mods    | 16.79 | 14.6% | closest content (same two mods, same metadata lines); differs in frame ("◆ Mods ◆"), selection styling, preview pane behaviour, bottom command bar (Qud: space/v/Save+Reload/undo) |

## Systemic issues (fix before per-screen pixel work)

1. **Raves' capture includes its window title strip** ("Raves of Qud (DEBUG)", ~28px)
   — the whole content area is shifted down vs Qud's borderless window, so every
   pair ghosts vertically. Fix at the source: borderless/chromeless window in 1:1
   mode (Qud ships `-popupwindow`), not by cropping captures.
2. **Title background tint**: Raves renders the cover art darker than Qud.
   Re-measure after #1 (the offset contaminates the tint read).

## Suggested work order

mods (smallest delta, bounded scope) → title offset fix (#1, unlocks honest scores
everywhere) → options (two-pane + rail relayout) → records (full redesign to the
ENDED RUNS stack + left rail).

Files: `{screen}_{qud|raves}.png` + `contact_sheet.png` (qud | raves | diff>32 per row).

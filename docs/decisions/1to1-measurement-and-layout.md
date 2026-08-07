# 1:1 parity — measurement & layout discipline

The per-screen *recipe* lives in [`goals.md`](../goals.md) ("measure → reproduce behind the switch →
re-verify"). This page is the **how** that made the top-bar pass land at ≤1–2px per element after many
earlier rounds of thrash. It's the load-bearing detail step 3 ("diff / measure") and step 4
("reproduce") only gesture at. Copy this discipline onto every remaining HUD row / screen.

## The one idea: reproduce Qud's *layout model*, not its pixels

The thrash came from chasing pixel offsets — nudge a value, rebuild, re-measure, nudge again. Each
rebuild is ~90s, so nudge-loops cost a whole session. The fix is to spend the first measurement pass
figuring out **how Qud lays the row out**, port that structure in **one** build, then set **one**
calibration constant. Concretely, on the top bar Qud turned out to use:

- **Fixed-width separator boxes.** Every `||—————||` is the *same* ~258px box, floated in the gap —
  NOT a rule stretched to fill it. We were stretching all three; that's why their widths and caps
  drifted. Fix: `_place_sep(sep, lg, rg, rpad, fixed_w, centered)` with three modes — stretch,
  right-anchored fixed, centred fixed.
- **Uniform grids for repeated elements.** The five stats (`QN…MA`) are each *centred on a uniform
  ~86px cell*, regardless of value width — so `AV/DV/MA` don't bunch up the way natural HBox flow made
  them. Fix: each label is a fixed-`STAT_PITCH` centred cell; the `::` sits at the cell boundary.
- **Looser `::` than word spaces.** In the T-group Qud's `::` gaps are ~44px vs ~12px word spaces.
  Fix: `_dots(cell_w)` floats the dot block in a wider cell for the `::` only; word spaces stay tight.
- **Groups centred on a % of the bar; separators float between, anchored to the *aligned* side.**
  Left/right groups edge-anchored, T-group & stats centred on their Qud %, each separator sized to the
  live gap. When a separator's neighbour isn't aligned yet, anchor the fixed box to the side that *is*
  (sep3 → the disc) so its far cap lands on Qud regardless of the unaligned side.

Once the model matches, a single per-group constant (a centre %, an inset) lands the whole group.

## Calibrate across content states — a single snapshot hides the *rule*

The sharpest trap: fit the layout to **one** content state, get it pixel-perfect, and ship a rule that's
secretly wrong. The top bar was tuned with the zone name "Joppa" (short); we set the T-group and stats to
fixed fractions of the **window width** (`w×0.30`, `w×0.66`) and it matched to 1px. Then the player walked
to "desert canyon, surface" — the right cluster grew ~150px, slid left under the fixed-position stats, and
`sep3` collided *into* the middle of the stats. `w×0.66` had only ever *coincidentally* equalled the right
answer because the right cluster happened to sit where it did in Joppa.

The fix was to **derive the rule from the relationships between elements, measured across several content
states**. Capturing Qud at three zone lengths (Joppa / Rustwell / desert) and computing ratios showed the
real rule: Qud positions T and stats relative to the **right cluster's left edge** (`Rl`), not the window —
`T = 0.328 × Rl` held *exactly* across all three, and the three inter-group gaps came out **equal**. So the
layout is "split the leftover space into three equal gaps," computed from the **live** group widths
(`get_combined_minimum_size()`), which adapts to zone name, status word ("Hungry" vs "Sated"), and stat
digits alike. No magic percentages.

Rules for not getting fooled again:

- **Any absolute constant tied to the window (`w×k`, a hardcoded x) is a red flag** — it can't know about
  its neighbours, so it breaks the moment a neighbour's width changes. Prefer relationships (anchor to the
  adjacent element, or distribute slack) over absolute positions.
- **Vary the content before believing a fit.** Long *and* short zone, 1- and 3-digit stats, longest status
  word. If the rule only holds for one, it's a coincidence, not the rule.
- **Watch out for measurement contamination.** The stats "centre" wobbled across zones only because the
  extent-midpoint I measured shifts with the *digits shown* (value-dependent glyph widths) — the position
  rule was actually clean. Measure a value-independent anchor (a constant-width group, a cell edge) when the
  content varies.

## The measurement loop (do this, don't eyeball, don't infer)

1. **Capture both apps in the *same* frame.** `hv shot 'CavesOfQud' q.png` + `hv shot 'Raves…' r.png`
   back-to-back. Top-bar values (temp/weight/stats) jitter; a stale Qud shot invents phantom offsets.
   Both windows are 1× (`allow_hidpi=false`) so **capture px == Godot px == Qud px** — no scale factor.
2. **Measure with a short PIL script, not your eyes.** The toolkit that worked:
   - **Column profile** — count bright/saturated pixels per column, find runs → element left/right/width.
   - **Gap-segmentation** — merge bright runs with a gap threshold to join `label+value` into one token
     (or split `::`); pick the merge gap to match what you're isolating.
   - **Cluster centres + pitch** — centre of each token; the *pitch* (centre-to-centre) is what reveals
     a uniform grid vs natural flow.
   - **Pipe/cap detection** — columns with a tall vertical run (`>~8` rows) = separator `||` caps; cluster
     adjacent columns into one cap. Text stems are false positives — scope to the separator's region.
   - **Sprite overlay** — to test *size* vs *position*, crop each sprite to its bbox top-left and overlay
     (Qud green / Raves red); mostly-yellow = same size, the offset was position. (This is how we proved
     the avatar was already 1:1 and the "size" complaint was really a 5px position drift.)
3. **Read the diff pattern — it tells you position vs structure:**
   - **Uniform** diff across a group (every element off by the same N px) → a single **position** offset;
     one shift/inset fixes it.
   - **Growing / varying** diff (aligned on the left, drifting toward one end) → a **structure/pitch**
     problem; fix the model (fixed cells, fixed box), not individual elements.
4. **Change the structure once, then calibrate once, then verify once.** Resist the nudge-loop.

## Anti-patterns (what caused the earlier thrash)

- Eyeballing a screenshot and guessing "a few px left"; nudging a magic number per rebuild.
- Comparing a fresh Raves shot against a stale Qud shot (values had changed → false offsets).
- Treating a *structural* mismatch (stretch vs fixed box, natural flow vs grid) as a position offset —
  you can null one element but the rest stay wrong, so you chase them forever.
- Anchoring a separator to a neighbour that isn't aligned yet (its error propagates into the separator);
  anchor to the aligned side instead.
- Conflating size / position / spacing. Measure all three (bbox, left-edge, gap); overlay to isolate size.

## Worked reference — the top bar (raves, this round)

Left→right, every element within ~1px of Qud: `avatar(x22) + name(x61) → ||box → T-group(ctr%,
::=17px dots) → ||box → stats(86px grid, ctr 0.66) → ||box → disc(48px) :: zone`. The gains came from
the model fixes above, each verified by a PIL measurement, one build apiece — not from nudging.

See also: [`goals.md`](../goals.md) (the recipe + gating), CLAUDE.md ("capture and inspect; do not
infer" and the Python-first rule).

## Addendum — read the layout model out of the app, don't infer it (the picker pass)

The loop above assumes the model has to be *inferred* from captures. For a Unity target it usually
doesn't: the model is sitting in the RectTransforms. `mod/UiProbe.cs` (`hv`-triggered via the
bridge's `uiprobe` command) dumps every RectTransform of a live screen — screen rect in TOP-LEFT
pixels, i.e. the same space as an `hv shot` capture — plus each text's content, font size, colour
and alignment, and each Image's sprite name and tint. The picker's entire layout came out of two
dumps, and the resulting height rule reproduced Qud's panel to **0.00px** across every state.

Use it first. It removes the whole class of errors the top-bar pass fought: no value-dependent
glyph-width contamination, no guessing which of two similar bands you measured, and the sprite
names tell you what the chrome actually *is* (the picker's border is a 9-slice sprite; we had been
reproducing it with the popup dialog's drawn notch lines, which no amount of pixel-nudging fixes).

Its own traps, all of which produce confident-looking wrong answers:

- **Filter on `activeInHierarchy`.** Pooled rows keep inactive variants (a `Modes` node holds both a
  Category and an Item child). Reading an inactive one gave a category font size of 24 when the live
  one is 16.
- **Trust the geometry, not the TEXT.** Pooled `TMP_Text` components hold stale strings from
  whatever last used them — every row in one dump claimed to be the same item, and one claimed a
  category that wasn't in the list. Classify rows by STRUCTURE (has an `icon` child => item row).
- **Vary the content anyway.** The panel looked fixed at 412x460 until a second picker came out
  510.8x539. The *insets* were constant across both; the size was not. This is the same lesson as
  the top bar, and it still applies when the numbers come from the engine.
- **Capture and probe in the same breath.** Qud's footer bar gains and loses a context-dependent
  entry between frames, so a capture taken seconds before a probe can disagree with it about the
  panel's height — and the disagreement looks like a layout bug in the client.

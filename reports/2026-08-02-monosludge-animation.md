# Monosludge animation — captured frames + decoded programs (2026-08-02)

Daniel selected a `{{c|soupy}} {{Y|sugary}} monosludge` (blueprint **SoupSludge**) at (38,12) in
JoppaWorld.53.17.1.1.10, sitting in a `deep pool of primordial soup` (ProteanDeepPool), and asked
to capture the animation frames. 20 Qud window shots at ~0.5s cadence yielded **4 distinct cell
states** — contact sheet: [`2026-08-02-monosludge-animation-frames.png`](2026-08-02-monosludge-animation-frames.png)
(left→right: gold-on-green, teal-on-green, gold-on-dark, blue wave glyph).

Observed sequence (one hash per shot):
`e127 7f88 f617 f617 e127 e127 afea f617 e127 7f88 f617 f617 e127 7f88 f617 f617 e127 e127 afea f617`

## Decoded programs (decompiled)

Three independent systems compose in this one cell:

1. **The sludge body blink — `SoupSludge.Render`** (this specimen runs the **Hero == 1** path):
   - `FrameTimer.ElapsedMilliseconds % 480 > 240` → return early → base colours only
     (`&c` teal body, detail from `FindLastForeground` cache).
   - else → append `"&" + component liquid colour` → fg becomes the liquid's letter
     (sugar → gold; "monosludge" = exactly one component liquid, so no multi-liquid cycling).
   - Net: a **240ms gold / 240ms teal square-wave**. Non-hero sludges never blink — they cycle
     component colours continuously at 240ms per liquid (`ms % (240*N) / 240` indexes the list).
     Hero detection: `HasIntProperty("Hero") || HasPart<GivesRep>()`.

2. **The pool glyph blink — `LiquidProteanGunk.RenderPrimary`** (wading+ depth only):
   - `RandomCosmetic(1,60)` per frame → mutate the Render PART fields: glyph cycles
     `÷ / ~ / \t / ~` by `(CurrentFrame+offset)%60` quadrant, colours pinned `&c^C`.
   - `RandomCosmetic(1,600)` → a one-frame `` sparkle.
   - The captured **blue `~` wave frame** is this branch winning the cell with `E.Tile` nulled —
     the whole cell renders as the glyph for that frame.
   - `RenderSmearPrimary` (covered objects): `CurrentFrame%60 in (6,14)` → `&c` flash — same
     shape as convalessence's smear (9-in-60 frames).

3. **Background green↔dark**: the pool cell background alternates a green fill with the plain
   field in step with (or near) the sludge blink. Source NOT yet pinned in the decompile
   (candidates: the gunk pool paint atlas phase, or a `^` background applied on the append
   frames). **Open question — pin it before implementing any of this.**

## What Raves renders today (policy)

The 1:1 no-animation baseline: the wire ships the static Render fields (`&c` / detail `C`), so
Raves shows the **teal phase** steadily. NB for a HERO sludge there is no majority phase — the
blink is a 50/50 duty cycle, so a single-frame congruence capture of a hero sludge disagrees
with Raves ~half the time. This is the first animated part measured where "steady clamp" has
no defensible answer — if/when Raves grows an animation pass, the sludge blink (fixed 480ms
wall-clock period, trivially reproducible from `ElapsedMilliseconds`) is the easiest candidate:
the wire would need the component-liquid colour letters (and the hero flag).

## Capture method (reusable)

Burst `hv shot` the focused Qud window (~0.5s cadence, 20 shots), crop the target cell, md5 the
crops to dedupe distinct frames, contact-sheet them, and match distinct states against the
decompiled per-frame programs. Frame-timing finer than the shot cadence comes from the decompile
(ms constants), not the captures.

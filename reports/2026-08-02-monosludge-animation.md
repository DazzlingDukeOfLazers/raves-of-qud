# Monosludge animation — captured frames + decoded programs (2026-08-02)

Daniel selected a `{{c|soupy}} {{Y|sugary}} monosludge` (blueprint **SoupSludge**) at (38,12) in
JoppaWorld.53.17.1.1.10, in a `deep pool of primordial soup` (ProteanDeepPool). Two capture
rounds — the first sludge was the CURRENT COMBAT TARGET, which composits an extra animation
(Daniel caught this); a second round captured untargeted sludges.

Contact sheets:
- targeted (38,12): [`2026-08-02-monosludge-animation-frames.png`](2026-08-02-monosludge-animation-frames.png)
  — gold-on-green / teal-on-green / gold-on-dark / blue wave glyph
- untargeted (38,11): [`2026-08-02-monosludge-untargeted-frames.png`](2026-08-02-monosludge-untargeted-frames.png)
  — wave glyph / gold-on-dark / teal-on-dark

## Decoded programs (decompiled + measured, 20-shot bursts @ ~0.5s)

Composited systems in a sludge cell:

1. **Sludge body — `SoupSludge.Render`, non-hero path** (this specimen): appends
   `"&" + componentLiquid.GetColor()` EVERY frame → **steady gold** (sugar; "monosludge" = one
   component liquid). Multi-liquid sludges cycle at 240ms/liquid (`ms % (240*N) / 240`).
   A HERO sludge (`HasIntProperty("Hero") || HasPart<GivesRep>()`) instead BLINKS 240ms
   appended-colour / 240ms base `&c` — not observed here.

2. **Gunk smear — `LiquidProteanGunk.RenderSmearPrimary`** (the sludge is liquid-covered):
   `CurrentFrame % 60 in (6,14)` → fg `&c` teal for those frames (~15% — measured 3/20 shots
   on BOTH targeted and untargeted sludges). Same shape as convalessence's smear.

3. **Pool glyph — `LiquidProteanGunk.RenderPrimary`**: 1-in-60 per frame mutates the Render
   part through the `÷ / ~ / \t / ~` glyph cycle (colours `&c^C`), 1-in-600 sparkle; the
   captured blue `~` wave frame is that branch with `E.Tile` nulled — the whole cell renders
   as the glyph for a frame.

4. **TARGET highlight — `Cell.RenderTarget`** (targeted sludge only): the current
   `Sidebar.CurrentTarget` gets a **background fill that BLINKS** in ~250ms windows
   (CurrentFrame 0-15 / 30-45): neutral → `^g` GREEN (this case), hostile → `^r` red,
   party member → `^b` dark blue, the player as own target → `^B`. Measured: green-bg
   frames ≈ half the shots on the targeted sludge, absent on untargeted ones.
   (A 1-px column of green in the (39,12) crops was cell-boundary rounding bleed from the
   targeted neighbour — cw = 20.25 px doesn't land on integers; account for it when cropping.)

## What Raves renders today (policy + gaps)

The 1:1 no-animation baseline ships static fields (`&c`/`C`) → Raves shows a steady TEAL body.
Two deltas vs Qud's typical frame:

- **The steady body colour should be GOLD** (the non-hero append runs every frame — it IS the
  steady state, same class as the hologram clamp). Candidate wire fix: ship the component-liquid
  colour like the other render-time overrides. Hero sludges blink 50/50 — no steady answer.
- **The target highlight doesn't exist in Raves** — Qud blinks a bg fill under the current
  target ~half the time. If Raves renders a steady bg fill for `target.present` at (target.x,y)
  (colour by disposition), congruence captures of targeted creatures would match Qud's
  highlight-on frames instead of never. Blink fidelity would need an animation pass.

## Capture method (reusable)

Burst `hv shot` the focused Qud window (~0.5s cadence, 20 shots), crop the target cell, md5 the
crops to dedupe distinct states, contact-sheet them, and match states against the decompiled
per-frame programs (ms constants from the decompile, not the capture cadence). Watch for:
the CURRENT TARGET composits the highlight blink (pick untargeted specimens, or Esc-clear the
target first), and non-integer cell pitch bleeds 1-px columns between crops.

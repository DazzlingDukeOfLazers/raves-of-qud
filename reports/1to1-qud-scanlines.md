# Disabling Qud's scanlines (1:1 test) — findings + mod fix

Qud renders visible **horizontal scanlines on its UI chrome** (top bar, panels, dock,
command bar). The play field / tiles are **clean** — scanlines only appear on the chrome.
For clean 1:1 colour-matching we suppress them from the Qud side, via the bridge mod
(`mod/Bridge.cs`, `Bridge.EnsureScanlineState`), gated by `Bridge.DisableQudScanlines`
(default true; set false to restore Qud's authentic look — originals are captured per
material).

## Why the built-in controls do nothing
- **`OptionDisplayScanlines`** (Options.xml, default Yes) is set to "No" in
  `PlayerOptions.json` but has no effect: the option is read in exactly ONE place —
  `GameManager.cs:3017`, inside the screen-warp **"Fuzzing"** branch — never at startup or
  on an options change. In normal play nothing consults it.
- **`Display.txt` → `shaders.scanlines.enable=false`** does nothing: no code reads the
  `shaders` block (grep the decompiled `Assembly-CSharp` for `"scanlines"`/`cubicdistortion`
  → zero readers). It's dead config from an older version. (`LetterboxCamera.cs:303`
  hard-codes `scanlinesCount = 1853`, matching the file, but set in code not read from it.)

Measured proof: a fresh instance with both set "off" has the SAME period-2 amplitude as
before (global `mean|even−odd|` ≈ 4.2; a clean 13→23 lift in flat chrome).

## The three actual sources (found by walking the live scene from the mod)
1. **`CC_AnalogTV`** camera post-effect (`scanlinesIntensity`, `scanlinesCount=1853`). Always
   on, but at 1853 lines over ~1108 px it aliases to **sub-visible** — zeroing it changes
   nothing you can see. We zero it anyway for completeness.
2. **Modern-UI chrome SHADERS** (top bar, panels, dock, sidebars):
   - **`UI/Textured-Overlay`**: multiplies each panel by an overlay texture
     `_OverlayTex = "distress-diagonal"` tinted by `_ColorOverlay`.
   - **`UI/ThreeColorOffset`**: a per-row `_Offset` (0.66).
   There is **no `_ScanlinesIntensity`** on these UI materials — that name belongs to
   `CC_AnalogTV` only. (Diagnosed by dumping each UI shader's full property list from the mod.)
3. **SPRITE-based patterns on plain `UI/Default` Images** (the bit the shader sweep missed):
   - the bottom **`AbilityBar`** Image uses a sprite literally named **`horizstripetexture`** —
     THE command-bar scanlines;
   - a full-screen **`Creases`** Image uses a **`creases`** grunge sprite.
   These carry the pattern in the sprite, not a material knob, so `_MainTex` reads null and the
   overlay-shader sweep never touched them. (Found by dumping every bottom-region Graphic's
   `Image.sprite` / CanvasRenderer texture.)

All are screen-row-keyed, so the lines are consistent across every panel (bright = even screen
row everywhere) and show **through the translucent chrome**; the opaque play field covers them,
which is why the world is clean.

## The fix (mod)
`EnsureScanlineState()` (driven from `Bridge.Tick` / `TickAction` / `TickRender`, marshalled
to the main thread via `uiQueue`), gated by `Bridge.DisableQudScanlines`:
- zeros every `CC_AnalogTV.scanlinesIntensity`;
- on every UI material that has them, neutralises `_ColorOverlay` (→ transparent), `_OverlayTex`
  (→ white), `_Offset` (→ 0);
- on every `UI.Image` whose sprite/texture name matches `stripe|scanline`, **flattens** it to a
  solid chrome-dark quad (drops the sprite, sets fill `#0c0f10`); whose name matches
  `crease|distress|grain`, **hides** it (alpha → 0).
It **re-sweeps on a throttle** (every ~20 ticks) because Qud instantiates some panels after the
first sweep. Originals captured per material/image so the flag can restore Qud's look.

### Verified (1× capture, capture px == Qud px) — full-screen residual scan
| chrome region | with scanlines (even−odd dev) | after fix |
|---|---|---|
| top bar | ~10 | **1.3** ✓ |
| right sidebar | ~4 | **0.15** ✓ |
| bottom command bar | ~9.6–17 | **~0–1.4** ✓ |

A full-screen scan confirms **no flat-chrome scanline residual** remains. The only even-odd
hits left are genuine UI elements — the HP-bar edge, the selected-ability green border, world
tiles — and (on a standalone launch) the macOS window titlebar, which the borderless 1:1
window doesn't have.

## Reproduce / iterate
Mods compile at Qud **startup**, so each change needs a Qud restart. Drive:
`hv launch qud` → hover-click **Continue** (`hv click --hover <win> 958 608`) → hover-click
the save row (`… 950 195`) → in-game. **`Down` does not navigate Qud's Unity title menu — use
hover-clicks.** The mod logs `[raves] scanlines disabled — …` to
`~/Library/Logs/Freehold Games/CavesOfQud/Player.log`. Measure period-2 with a PIL script
(`even_rows.mean() − odd_rows.mean()` over a flat chrome strip).

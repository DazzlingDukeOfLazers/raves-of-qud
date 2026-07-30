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

## The two actual sources (found by walking the live scene from the mod)
1. **`CC_AnalogTV`** camera post-effect (`scanlinesIntensity`, `scanlinesCount=1853`). Always
   on, but at 1853 lines over ~1108 px it aliases to **sub-visible** — zeroing it changes
   nothing you can see. We zero it anyway for completeness.
2. **The Modern-UI chrome shaders** — THE visible ones:
   - **`UI/Textured-Overlay`**: multiplies each panel by an overlay texture
     `_OverlayTex = "distress-diagonal"` tinted by `_ColorOverlay`.
   - **`UI/ThreeColorOffset`**: a per-row `_Offset` (0.66).
   These are keyed to screen rows, so the lines are consistent across every panel (bright =
   even screen row everywhere) and show **through the translucent chrome**; the opaque play
   field covers them, which is why the world is clean. There is **no `_ScanlinesIntensity`**
   on these UI materials — that name belongs to `CC_AnalogTV` only. (Diagnosed by dumping
   each UI shader's full property list from the mod on the main thread.)

## The fix (mod)
`EnsureScanlineState()` (driven from `Bridge.Tick` / `TickAction` / `TickRender`, marshalled
to the main thread via `uiQueue`) walks all `UnityEngine.UI.Graphic`s and, on every material
that has them, neutralises `_ColorOverlay` (→ transparent), `_OverlayTex` (→ white), and
`_Offset` (→ 0); it also zeros every `CC_AnalogTV.scanlinesIntensity`. It **re-sweeps on a
throttle** (every ~20 ticks) because Qud instantiates some panels after the first sweep
(each with its own material instance). Originals are captured per material so the flag can
restore Qud's look.

### Verified (1× capture, capture px == Qud px)
| chrome region | with scanlines (even−odd dev) | after fix |
|---|---|---|
| top bar | ~10 | **1.3** ✓ |
| right sidebar | ~4 | **0.15** ✓ |
| bottom command bar (highlighted button) | ~17 | 12.4 ✗ (residual) |

The **top bar** (the element we're actively 1:1-matching) and the sidebars are clean.

## Known residual / TODO
The **highlighted ability-bar button** still shows lines and is **unchanged by every UI knob
above** — its source is a separate material/element the `Graphic` sweep doesn't reach (a
selection-state overlay, or a non-UI/camera element). Not yet isolated. Next step if needed:
extend the scene walk to non-`Graphic` renderers and selection-highlight objects, or diff
the button's material set between selected/unselected states.

## Reproduce / iterate
Mods compile at Qud **startup**, so each change needs a Qud restart. Drive:
`hv launch qud` → hover-click **Continue** (`hv click --hover <win> 958 608`) → hover-click
the save row (`… 950 195`) → in-game. **`Down` does not navigate Qud's Unity title menu — use
hover-clicks.** The mod logs `[raves] scanlines disabled — …` to
`~/Library/Logs/Freehold Games/CavesOfQud/Player.log`. Measure period-2 with a PIL script
(`even_rows.mean() − odd_rows.mean()` over a flat chrome strip).

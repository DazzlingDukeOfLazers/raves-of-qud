# 1:1 top bar — next elements: the "meta" name + the separator

Working left-to-right across Qud's top status row. Avatar (icon) is DONE — matched
Qud pixel-exact (white body, red detail, size/position, facing). Next two elements:
the **character name** ("meta") and the **separator** after it (before `T:25°`).

## The workflow (how to iterate on top-bar 1:1)

The apps are the source of truth — capture and measure, don't eyeball. See
[[reference-qud-visual-style]] and [[project-raves-of-qud-env]].

1. **Render is 1× now** (`allow_hidpi=false`, commit ce84c86). So **capture px == Godot px
   == Qud px**. Measure a pixel in an `hv shot` and set the Godot value 1:1 — no scale
   factor. `body` px ≈ 21 at 1920×1080 (`UiFont.px`; MIN floor is 14).
2. **Effects are OFF** (the minimal "1:1 test" profile: fx_scanlines/vignette/particles/
   lighting all false — commit addbedd). Colors read true; no vignette/grade tint. Keep
   them off while colour-matching.
3. **Iterate without wrecking Daniel's game** (the bridge is multi-client; QudLauncher only
   kills Qud on a GRACEFUL close):
   `kill -9` the Raves viewer (Qud + its game survive) → edit .gd → `tools/build_macos.sh`
   → `hv launch raves` (adopts the running Qud) → menu **Continue** (inject `down` then
   `space`) enters the viewer on the live game → `hv shot <ravesWin>` + measure.
   **AX move now works on the borderless Raves window** (since the 1× change) — `hv move`
   repositions it fine.
4. Measure both captures in the SAME top-left region and align. `/tmp/qud_game.png` is a
   good Qud reference (Joppa, day). Compare RGB + bbox with a short PIL script.

## Element 1 — the "meta" name  (`MainFrame._l_name`, in `_row_status`) — ✅ DONE (commit 89e7ec0)

**Result:** `_l_name = _text("—", COL_NAME, "caption")` where `COL_NAME := Color("b0b0b0")`
(neutral grey) and the `caption` role = 0.85×body = 18px. After: Raves name x-height
**9px, rows 20–28**, peak (166,166,166) — pixel-aligned with Qud (rows 20–28, peak ~161
neutral grey). The caption role landed the x-height exactly; `custom_minimum_size` 90px
min left as-is (it's just a floor). Original brief below.



Currently `_l_name = _text("—")` → theme default colour (`y` = #b1c9c3, a TEAL-tinted grey)
at `body` size (~21px). Plus `clip_text` + `custom_minimum_size = (90, 0)`.

**Qud target (measured from /tmp/qud_game.png):**
- Colour: **neutral grey ≈ (170, 170, 170)** — NOT the teal `y`. Qud's name is desaturated.
- Cap height ≈ **10px** → font ≈ **14px**, i.e. SMALLER than Raves' body (21px). Likely a
  `caption`-ish role or an explicit smaller size.

**To do:** give `_l_name` a smaller font size (measure Qud's cap height, back out the font
px — try `UiFont.px(vp,"caption")` ≈ 0.85×body, or explicit) and a neutral-grey colour
(≈#aaaaaa) instead of the theme `y`. Re-capture, match cap height + colour, iterate.
(Watch the `custom_minimum_size` 90px min — it was there to stop the name collapsing to 0
next to the expanding rule; keep a min but re-check it at the new size.)

## Element 2 — the separator  (`MainFrame._rule()`)

Currently a `ColorRect` line coloured `COL_BORDER` (= `y` grey at **alpha 0.16**, nearly
invisible), 2px tall (offset_top −1, offset_bottom 1), vertically centred (anchor 0.5),
6px inset each side, inside a `SIZE_EXPAND_FILL` Control (min 16 wide).

**Qud target (measured):** a **dark teal line ≈ (47, 65, 60)**, ~1–2px thick, at the row's
vertical centre (y≈22 in the ~44px row), spanning the gap between the name and `T:25°`.
This is the "teal horizontal line" Daniel flagged earlier as a future step.

**To do:** change `line.color` from the faint `COL_BORDER` to the teal (≈#2f413c /
(47,65,60) — add a `COL_SEP` const). Check thickness (Qud ~1–2px) and vertical centring
against a capture. The rule appears between groups (name↔temp, and elsewhere via `_rule()`),
so the colour change applies to all separators — verify each still reads like Qud.

## After these
Continue left-to-right: temperature `T:25°`, the `::` dots (`_dots()`, currently `COL_DIM`),
food/water state colours, weight/water, the `AV/DV/MA` group (Daniel wanted a cyan tint),
zone name at the far right. Same measure-and-match loop.

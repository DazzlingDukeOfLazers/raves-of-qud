# Parity baseline — item interaction popup, 2026-08-08

**Completes** the 2026-08-05 spec rather than superseding it. The spec's design was already right —
named regions with distinct kinds, and an `anchor` so the header leaves are scored relative to each
app's own popup top line instead of silently also scoring the popup's placement. What it lacked was
the baseline discipline: no `--stable` capture, no recorded pin, no scoreboard, and no statement of
which leaves are safe as controls. The captures are replaced; the spec is extended by one leaf.

## The pin — reproduce this exactly before re-scoring

| what | value |
|---|---|
| save | **`sync-raves-and-qud`** (row 1 of `hv saves`), Wander |
| zone | `JoppaWorld.11.22.1.1.10` — Joppa surface |
| loaded via | `python3 tools/capture/fixture.py reload sync-raves-and-qud` |
| **item** | **cloth robe** — `pack/Armor`, present deterministically in this fixture's 14 pack items |
| popup raised by | `python3 tools/capture/fixture.py twiddle robe` — resolves the item BY NAME and verifies the popup came up **from QUD's own `popup` frame on the bridge**, not from `raves_state.json` (a Raves at the title reports "no popup" exactly as convincingly as a Qud that never raised one). Never by id (ids are not stable across a reload) and never by clicking whatever is under the cursor |
| mirrored | Qud raises it; Raves receives it over the popup bridge (`popup=menu`) |
| capture | Qud activated and given ~3s to repaint (it does not repaint unfocused), captured TWICE for `--stable`; then Raves activated and captured |

```bash
python3 tools/capture/fixture.py reload sync-raves-and-qud
hv goto raves in_game
python3 tools/capture/fixture.py twiddle robe
# activate + settle + capture each, then:
python3 tools/capture/parity.py score \
  reports/2026-08-05-item-popup/parity-item-popup.json \
  <qud.png> <raves.png> --stable <qud2.png> --json
```

## Reproducibility — checked, not assumed

The entire pin was re-driven from scratch (reload → re-attach Raves → re-raise the popup →
re-activate → re-capture) and re-scored. **All 7 leaves reproduced EXACTLY (+0.00)**, better than
the ±0.01 the Equipment baseline managed. An item popup raised by name off a reloaded fixture is
about as deterministic as this harness gets. Re-checked on 2026-08-08 after the box-model port:
two consecutive re-drives of the whole pin scored identically to two decimal places on all seven.

**One hazard the pin does not remove: the FIRST twiddle after a fixture reload sometimes raises a
SHORT option list** (the cloth robe's 8 options arriving as 2 or 6, with Qud still settling). It is
a different popup, so a run that captures it silently compares two different things — the header
leaves still score, because they are anchored to each app's own top line. Verify the option count
before capturing (the mirrored `popup` frame carries `options`), and re-raise if it is wrong.

**2026-08-08 — the mechanism behind the short list: FOUND AND FIXED.** Nothing was "answering" the
menu. Nothing delivered a keystroke, a click, or a hover; `ControlManager`'s command queue was
empty on every affected raise. The popup was **hidden out from under itself**, and Qud's own
`Popup.PickOption` reports a cancelled popup as **the highlighted row**.

The chain, read off `mod/InputDiag.cs` (the game-view stack + the popup's visibility, per frame):

    pm f4322  view=PopupMessage/PopupMessage  stack=Stage,Stage,PopupMessage   cmd=True sel=True
    pm f4323  view=Stage/PopupMessage         stack=Stage,Stage,Stage          cmd=True sel=True
    pm f4324  canv=False hnf=1 onHide=False   cmd=True sel=True                <- hidden, unanswered

The mod raised the menu through `APIDispatch.RunAndWaitAsync`, which runs on a **threadpool**
thread, so Qud's TURN thread stayed free and spinning in `XRLCore.PlayerTurn`'s wait-for-input
loop — a loop that executes `GameManager.Instance.CurrentGameView = Options.StageViewID;` every
iteration. It slammed the view back to `Stage` under the live popup, `UpdateView` re-hosted the
canvas, `PopupMessage.Hide()` fired `onHide`, that cancelled the awaiting task, and because
`Popup.WaitNewPopupMessage` is `async void` the cancellation never reached `PickOption` — which
returned its untouched `SelectedOption`, i.e. `DefaultSelected`. `TwiddleObject` then performed
that action for real, which is why the robe kept toggling pack↔body and the next raise honestly
offered 6 options instead of 8.

`cmd=True sel=True` at the close is the discriminator: Qud nulls `commandCallback` in
`OnActivateCommand` and `selectCallback` in `OnSelect`, so both still set means **no one
answered**. From the wire, from `raves_state.json` and from a screenshot the two cases are
indistinguishable — which is why the earlier passes blamed the bridge and then the
fabricated-Cancel path, and both were wrong.

**Fix** (`mod/InventoryExporter.Twiddle`): raise the menu the way Qud's own idle-game caller does
— `GameManager.Instance.gameQueue.queueSingletonTask(...)`, per `NearbyItemsWindow.OnSelect` — so
`TwiddleObject` runs ON the turn thread with that loop inside it. Full write-up in
`docs/gotchas.md`.

**Rate, same fixture, same harness (`invaction` over the bridge, verified from QUD's `popup`
frames — never from Raves):**

| build | self-answered |
|---|---|
| before (`APIDispatch`) | **6 / 8** and **7 / 8** on two runs |
| after (`gameQueue`) | **0 / 12** (export per cycle, the `fixture.py twiddle` shape) and **0 / 4** (no export) |

All 16 post-fix raises came up with the correct 8 options and the robe never left the pack.

The old workaround — reload the fixture rather than retry — is no longer needed, but checking the
option count before capturing is still cheap insurance.

## Which leaves are safe as CONTROLS

`fixture_dependent` is recorded per leaf in the spec, because that distinction was already got
wrong once on the Equipment spec (`list_cat`/`list_item` were treated as chrome and are not).

- **Controls (fixture-independent): `popup_image_frame`, `popup_placement`** — the header block's
  border lines and the popup's own placement. Only these two are valid for validating a future
  retake.
- Everything else moves with the item: the name text, its colour and its box, and the tile's
  geometry and palette.

That is a thin control set — two of seven — which is precisely why the pin has to name the item.


## 2026-08-08 — Qud's popup BOX MODEL, ported whole

The two offsets recorded here on 2026-08-05 (the popup "16px low", the item name "1px left") are
closed. Neither was nudged: the model in the spec's `qud_model` block was applied whole, and both
fell out of it.

| leaf | was | now | |
|---|---|---|---|
| `popup_placement` | 6.75 | **0.00** | the popup's own top-line placement, absolute |
| `popup_frame_text_content` | 15.40 | **4.98** | the item-name line |
| `popup_frame_text_geometry` | 0.75 | **0.25** | same x, same y, same width; 1px of ink height left |
| `popup_image_geometry` | 0.25 | **0.00** | identical tile bbox |
| `popup_image_frame` | 2.50 | **2.28** | header chrome |
| `popup_frame_text_color` | 2.26 | 2.30 | +0.04, inside run-to-run noise |
| `popup_image_color` | 0.00 | 0.00 | |

### What changed

Qud centres `MenuControll` — spacing 10, pad L20 R20 T0 B5 — and hangs the visible chrome OFF that
box: the top rule 16 **above** it, the opaque fill from box_top−20 to box_bottom−2, the bottom rule
15.5 **inside** it. Raves centred the PANEL and drew its top rule 8px inside. So this was never a
margin to add; it changed which box is centred, and it is shared by every popup kind.

Inside the box, Qud's own structure now drives the sizes rather than a fitted height: the 138.12
context block, a Scroll View that is `Message + 2 + options area + 2 + inputbox` (26 per row,
spacing 2), and a 20px `MenuCrome` bar whose entries are `padL 2 + an 8px cursor cell + spacing 5 +
text + padR 20`.

### Verified across sizes AND kinds — six popups, four kinds, six widths

The spec is pinned to one item at fixed coordinates, so it cannot see a differently sized popup.
These were measured wherever they land, against Qud's own `MenuControll` from
`uiprobe target=PopupMessage`. **Exact** = the opaque fill, the top rule, the context divider and
the bottom rule all landed on Qud's pixel rows/columns with zero delta.

| popup | kind | Qud's box | |
|---|---|---|---|
| cloth robe, 8 options | menu + context | 278.21×407.12 @ 820.90,336.44 | exact |
| basic toolkit, 7 options | menu + context | 239.81×379.12 @ 840.09,350.44 | exact |
| data disk, 9 options | menu + context | 433.61×435.12 @ 743.20,322.44 | exact |
| wish prompt (`CmdWish`) | AskString input, 2 entries | 650.00×76.72 @ 635.00,501.64 | exact |
| quest notice | message, 1 entry | 462.81×57.12 @ 728.59,511.44 | exact |
| quit confirm (`CmdQuit`) | yes/no, 3 entries | 453.40×57.12 @ 733.30,511.44 | exact |
| **death screen** | menu, **0 entries** | **278.21×202.34 @ 820.90,438.83** | exact, after the fix below |

Three of those exist because **each term of the width rule wins on a different popup**, which one
capture could never have shown:

- the cloth robe is sized by its widest COMMAND (67 + 211.21 = 278.21)
- the data disk by its 41-character NAME (40 + 393.6 = 433.61) — its commands only ask for 199.81,
  so a client that sized on the list alone would draw that popup a little over half Qud's width
- the quit confirm by its COMMAND BAR (3 entries + 2 spacings + 2 line sprites at a 25px floor =
  453.40) — its message only asks for 383.40, and nothing but a multi-button confirm reaches it

### 2026-08-09 — a seventh popup, and the term it exposed: an EMPTY MenuCrome is 15, not 20

The six above all have at least one bottom command, so all six pin `MenuCrome` at 20 and none of
them can see what it does with none. Qud's death screen has none — four options, no bottom bar —
and its MenuCrome holds only the two line sprites, standing **15.00**. Read off Qud's own
`MenuControll` (`uiprobe target=PopupMessage`, with the popup live):

    MenuControll  278.21x202.34 @ 820.90,438.83   sp=10 pad=20,20,0,5
      Scroll View 238.21x172.34
        Message   228.21x60.34     <- 3 lines
        options   228.21x110.00    <- 4 x 26 + 3 x 2
      MenuCrome   238.21x15.00     <- two line sprites, no entries

    5 padB + 10 spacing + 172.34 content + 15 = 202.34, against 207.36 for a fixed 20.

Those 5px went into the box height, and because the box is CENTRED they came out as every option
row sitting ~4px off Qud's — a uniform offset across the whole row family, which is the signature
of one term rather than a per-row bug. Fixed in `PopupOverlay` (`CROME_H_BARE`); the three
measured box heights (this one, the quest notice, the cloth robe) are asserted in
`tests/popup_overlay_render.gd`, and the death-screen one fails with the old fixed 20.

Verified live, Raves against Qud on the same popup: the opaque fill is **identical** —
top 419, bottom 638, left 821, right 1098 in both. Text rows land within 1px, which is the ink-top
grouping's own noise (Qud's own option steps read 29/28/28 for rows that are exactly 28 apart).
Region diff 7.45% -> 3.00% of pixels, at parity with the message-less system menu's 3.31%.

**Still open on this popup:** the bottom rule. Qud draws the entry-less MenuCrome as `--|` + `|--`
with a centred gap (two 136.60 sprites at 820.90 and 962.50); Raves draws one plain rule. That is
3.42% of the region on its own.

### The one concession, stated rather than buried

Godot snaps every Control rect to a whole pixel, so the carrier `PanelContainer` cannot be 278.21
wide. Two consequences, both handled deliberately:

1. **A Container CEILS a fractional minimum** — a row asking for 228.2 is handed 229 — and the box
   came out 279, whose centred left edge is 820 where Qud's 278.21 rasterises from 821. The model's
   own widths are rounded to the NEAREST pixel instead, which reproduces Qud's pixel on all six.
2. **The chrome is drawn on the exact fractional box**, offset from the carrier by the sub-pixel
   difference. That is what puts the AskString's rules on Qud's rows despite a 76.72 box living in
   a 77px carrier. The offset is derived from SIZES only: a Control's `position` reads (0,0) from
   inside its own draw callback on the show frame, and since nothing dirties the panel afterwards
   that stale draw is the one left on screen.

### Where the 1px name shift actually came from

The prediction on record — that it was downstream of the 2px width difference and would resolve on
its own — is **confirmed**. Nothing in the name's own layout changed.

The cause was measurement, not placement: Godot's `get_string_size` returns a whole number where
Qud lays this text out at exactly 0.6em (9.6px at font 16), and summing the per-run pieces of a
coloured string rounds again — the widest option row measured 213 against Qud's 211.21. Measuring
and advancing on the font's own pitch puts the name's ink box at Qud's x, y and width; the residual
0.25 is one pixel of ink HEIGHT, which is the rasteriser and a documented floor.

### Controls, and what did not move

- `popup_image_frame` (fixture-independent) 2.50 → 2.28 — the header chrome did not regress.
- **Raves' header block still measures 151.0 against Qud's 151.0.** It was already Qud's model, and
  the port deliberately left its internals alone: the top rule moved to box_top−16 and every header
  offset is still quoted from that line, so the arithmetic is unchanged by construction.
- The Equipment spec was re-scored on the same build: **all 33 leaves within ±0.02** of
  `reports/2026-08-08-parity-baseline/scoreboard.json`. No shared layout rule reached it.

## 2026-08-08 (later) — the titled branch: measured, fixed, render check outstanding

The port left one branch resting on the probe's *structure* rather than on a measurement: the
title row (`PolatFrameSuperHeader`), because none of the six popups above has one. It is now
measured on Qud's side and fixed — but the confirming re-capture is missing, and that is stated
here rather than left to look like a merge defect later.

### Raising one — Qud's own code path, no scaffolding

`Qud.UI.KeybindsScreen.SelectInputType()` calls `Popup.PickOptionAsync("Select Controller", …)`.
Reached entirely through Qud's own UI:

```bash
# in-game, fixture loaded
python3 -c "…Bridge().send('command', command='CmdSystemMenu')"     # system menu
python3 -c "…Bridge().send('popup', action='option', index='2')"    # [c] Control Mapping
hv click CavesOfQud 675 117 --hover                                 # "Configuring Controller: …"
```

The click needs `--hover`; bare does nothing (the click matrix in `docs/gotchas.md`).

### What Qud does

`MenuControll` 221.13×121.00 @ 849.43,479.50 — `20 + 10 + 56 + 10 + 20 + 5 = 121`, and the Scroll
View's 56 is `2 + (2 rows × 26 + 2)`. The title row is the box's **first** child when there is no
context block. Its minimum rect is its Header's own text width (the two edge assemblies floor at
10 each and the spacing is 10), so on this popup **the title sizes the box**: 181.13 against a
command area asking for only 180.61.

**Header text is tracked.** Same face and size as the body text (SourceCodePro-Regular SDF, 16, per
the probe) and still wider: 181.13 for 17 characters, i.e. 0.67em advance against the body's 0.6em.
That is not fitted to this one sample — it is the constant the journal header already established
at a different size, whose shipped widths give `16.079·len − 1.66` at size 24; the same model
predicts `0.67·16·17 − 0.07·16 = 181.12` here.

### What Raves had wrong, and what changed

One mirrored capture was obtained before the fix. It showed the branch wrong three ways:

| | Qud | Raves (before) |
|---|---|---|
| box width | 221.13 (fill x849–1070) | 211 (fill x854–1064) — the title never contributed |
| title ink | 178px wide | 161px — drawn at the body pitch |
| edge assembly | 10px bar, 3 tall, 2×20 tick at its inner end | 10×2 bar plus a separate 2×16 tick one pixel further in (12px) |
| top rule | row 463 | row 463 — already exact |

All three are fixed on the model. The title row is now an owner-drawn 20px Control (a
RichTextLabel reports 21), it asks the content box for its Header width, and it draws on the
header pitch.

## 2026-08-08 (later still) — the render check is CLOSED, and why it could not run before

### What was actually broken

Not the mirror, and not Qud. **`PopupOverlay` never built at all**, so Raves displayed no popup of
any kind.

The title row was converted to an owner-drawn `Control` and the field's declaration was left as
`var _title: RichTextLabel`. GDScript only catches that at RUNTIME: the assignment threw inside
`_build()`, which **aborted the whole builder**, so `_msg`, `_ctx_box`, `_ctx_img`, `_edit` and the
rest never existed and `show_popup()` died on the first null it touched. Every popup kind, not just
titled ones.

That failure is silent from every angle anyone was looking from. An overlay that never got built
just stays `visible = false`, so `raves_state.json` reports no popup, `hv state` shows none, and
`fixture.py twiddle` — which verifies through **Raves** — prints "no popup appeared". All of which
reads exactly like a mod that never announced, a watcher that never armed, or a Qud that never
raised one. Those three were hunted, in that order, and the previous session's conclusion ("no
popup raises in Qud at all, surviving a clean pair restart") was drawn entirely from Raves-side
signals. Qud was raising popups the whole time — a bridge tap sees the `popup` frames, and a
screenshot of Qud's own window shows the modal.

**The lesson is the one already written on the mod side, applied to the client: the mirror has two
halves and only one of them was observable.** It is now guarded by a SPOT test that drives the real
`show_popup` over the real wire frames headlessly —
`godot/tests/popup_overlay_render.tscn`. It reproduces the whole failure in about a second and
would have caught it before the build.

### The titled popup, measured

Re-captured with both apps in the driven state (`titled_qud.png`, `titled_qud2.png`,
`titled_raves.png`). Raised by Qud's own path, and it **mirrored on the first attempt** — twice,
across two runs.

| | Qud | Raves | |
|---|---|---|---|
| fill left/right | x849–1070 | x849–1070 | **exact** (849.43 + 221.13 = 1070.56) |
| box width | 221 | 221 | **exact** (was 211) |
| top rule row | 463 | 463 | **exact** (rows 463–464, full width) |
| fill top row | 459 | 459 | **exact** (box_top − 20 = 459.50) |
| edge assembly ticks | cols 857–858, 1061–1062 | same | **exact** |
| title ink | x870–1049, 180 wide, 12 rows | x870–1048, 179 wide, 11 rows | same left edge; **1px narrow, 1 row short** (was 161 wide) |
| fill bottom row | 598 | 597 | **1 row short — the one thing still off** |

Six of seven are exact. Two residuals, both stated rather than rounded away:

- **The title ink is 1px narrower and 1 row shorter.** Same left edge and the same pitch; this is
  the rasteriser floor every text leaf in this spec carries (`popup_frame_text_geometry` sits at
  0.25 for the same reason). The recorded expectation was "~178"; Qud actually inks 180 and Raves
  179.
- **The fill's bottom row is 1px high.** Qud renders 140 fill rows (459–598) where Raves renders
  139 (459–597), i.e. Raves' titled box is **120 tall against Qud's 121**. The model says
  `20 + 10 + 56 + 10 + 20 + 5 = 121`, so one term is losing a pixel; which one is **not** diagnosed
  here, and it is not guessed at either. It is specific to the titled branch — the untitled popups
  below are pixel-exact top and bottom.

### The other six: measured, not reasoned

The claim on record was that they are unaffected by construction, every new path being inside an
`if _title.visible` branch. That reasoning was **wrong in the only way that mattered** — the
`_title` declaration is outside any branch, and it broke all six — so they were measured.

| popup | re-raised | fill box, Qud | fill box, Raves | |
|---|---|---|---|---|
| cloth robe, 8 options | yes | x821–1098 (278), y316–741 (426) | identical | **exact** |
| data disk, 9 options | yes | x743–1176 (434), y302–755 (454) | identical | **exact** |
| wish prompt (AskString) | yes | x635 left edge, y482–575 | same edges; width 650 = Qud's 650.00 | **exact** |
| basic toolkit, 7 options | **no** | — | — | not re-raised |
| quest notice | **no** | — | — | not re-raised |
| quit confirm | **no** | — | — | not re-raised |

The three that were re-raised cover both container kinds (menu + context, and a bare input) and two
of the three width-driving terms — the widest COMMAND (cloth robe) and the item NAME (data disk).
The three that were not are named rather than implied: the toolkit adds no term the other two
menus do not already exercise, the quest notice needs a quest grant, and the quit confirm is the
one whose third prompt can end a run (see `docs/gotchas.md`). **The COMMAND BAR term is therefore
still unmeasured on this build** — only the quit confirm reaches it.

The full spec was also re-scored on this build against the scoreboard: **all 7 leaves +0.00**, from
a pin re-driven from a fixture reload. And `popup_placement`, one of the two fixture-independent
controls, is among them.

### A separate defect, spotted and now FIXED (2026-08-08)

Qud rendered the first option as `Keyboard & Mouse`; Raves rendered `Keyboard  Mouse`. Qud's
`EscapeNonMarkupFormatting` doubles a literal `&` to `&&` on the wire (`^` to `^^` likewise) and
`QudText` read the pair as a colour code, eating BOTH characters. All three parsers
(`to_bbcode` / `strip` / `runs`) now treat a doubled sigil as the literal character; a single
`&X` is still a colour code. Guarded in the SPOT tier by `tests/popup_overlay_render.gd`.

## 2026-08-09 — the cap change re-scored, and the TREE EMBLEM added

Two separate things landed on this screen and they are scored separately on purpose, because
`f097c16` (the 2x10 → 2x4 rule caps) shipped **without** re-driving this pin and its commit
message said so.

### The cap change: no effect on any leaf, measured

The whole pin was re-driven from a fixture reload on the `f097c16` build, before touching
anything. **All 7 leaves reproduced the pinned scoreboard exactly (+0.00.)** So the caps are not
covered by this spec — the assumption recorded in `f097c16` is now a measurement. It follows from
the rects: `popup_image_frame` is anchored at the top rule and reaches DOWN 152 rows, and
`popup_placement` is absolute `y320..380`, so a 4px cap centred on the rule changes the leaf's ink
BBOX not at all and its 12px frame band only where Raves already matched.

### The emblem: Qud drew one, Raves drew nothing

Qud draws a tree/vine glyph ABOVE the popup box. It is `polat-frame-top`, the `PolatFrameTopping`
child of `PolatFrame`, laid out 183x60 with its BOTTOM on the box top — screen `(868.5, 276.44,
183, 60)` against a box at `(820.9, 336.44)`, from the mod's own chrome dump.

**Extracted first-party, not redrawn.** New bridge command `popupchrome`
(`hv bridge popupchrome`) runs `TitleExporter`'s existing chrome walk over the ACTIVE
`PopupMessage`'s transform, so the sprite lands as a real PNG in `<support>/title/chrome/`
beside the main menu's. It rides the `uiQueue`, not the main-thread command queue, because a
modal parks Qud's turn thread and `Tick`/`TickRender` may never drain while the thing being
exported is on screen. `ExportNamedSprite` cannot do this job at all — the popup's chrome is a
SpriteAtlas instance that `Resources.FindObjectsOfTypeAll<Sprite>()` never sees.

Drawn through **one shared accessor**, `QudChrome.popup_emblem()` — decoded once into a static,
handed out by reference. The `nav_icon` above it records what the alternative costs: seven screens
grew seven copies of one glyph and they drifted. The chargen header carries this same art
(`chargen_emblem.png` is a byte-identical 434-pixel mask of the same tone), so the second caller
already exists.

### Verified by re-measuring, not by eye

`measure_emblem.py` in this directory. It matches the glyph's flat TINT with a tolerance rather
than thresholding brightness — Qud dims the live playfield behind a modal instead of blanking it,
so `sum(rgb)>140` returns the whole scan window (measured: `x800..1119`). Tolerances 0 through 6
all give the same answer; at 8 a dimmed wall segment joins in.

| | Qud | Raves | |
|---|---|---|---|
| ink bbox | x940..978 (39), y276..318 (43) | x940..978 (39), y276..318 (43) | **exact** |
| centre | 959.0, against a box centre of 959.5 | 959.0 | **exact** |
| tone | (68,99,111) | (68,99,111) | **exact** |
| lit pixels | 453 | 428 | 418 shared, 92.3% of Qud's |

**The 35-pixel residual is the central stem's dashes, and it is in the EXTRACTION, not the
placement.** Where Qud renders the glyph's 1px spine, the extracted PNG holds the disc colour at
alpha 128 — no glyph tone in it at all — so the pixels are not recoverable from the file. Three
things were tried and are recorded so they are not retried: forcing Point sampling in
`WriteRegion` changed the PNG by **zero bytes**; `chargen_emblem.png`, extracted from a different
sprite through the same path, agrees with Qud's render *worse* (397 against 418); and growing the
tone mask into the half-alpha pixels by vertical continuity reaches 447/453 but floods 316 pixels
of the disc with it. The atlas region genuinely holds those values.

The same overreach is why `EMBLEM_CLIP_RIGHT` exists: the extracted glyph is 40 columns and Qud
inks 39. The dropped column is the right wing's 2px tip at rows 16-17 whose mirror on the left IS
drawn — so it is the region reaching one column too far, not an asymmetric glyph. The PNG also
carries a wide (60,96,103) band across its middle rows that Qud provably never puts on screen
(outside the glyph, the two apps differ nowhere in those rows).

### Re-scored after: all 7 leaves +0.00 again

| leaf | pinned | before (f097c16) | after (emblem) |
|---|---|---|---|
| `popup_image_frame` | 2.28 | 2.28 | 2.28 |
| `popup_frame_text_content` | 4.98 | 4.98 | 4.98 |
| `popup_frame_text_color` | 2.30 | 2.30 | 2.30 |
| `popup_frame_text_geometry` | 0.25 | 0.25 | 0.25 |
| `popup_image_geometry` | 0.00 | 0.00 | 0.00 |
| `popup_image_color` | 0.00 | 0.00 | 0.00 |
| `popup_placement` | 0.00 | 0.00 | 0.00 |

Unchanged is the CORRECT result, not a null one: every leaf's rect starts at the top rule or
below it, and the emblem lives entirely above it (`y276..318` against a rule at `y320`). The
anchor is unaffected too — it needs 100 matching pixels in a row and the emblem's widest row has
39. Captures replaced with this run.

### Still open on this rule, and now one more

`f097c16` measured two things it did not fix, and both stand:

- Qud caps BOTH sides of each outer break, its inner caps 4 wide (offsets 53-56 and 183-186);
  Raves caps only the outer side.
- Qud's CENTRE break carries an ornament spanning offsets 107-131, `y308-332`, where Raves draws
  plain caps.

The second one now has a visible edge: the emblem's spine continues DOWN through the rule as part
of that ornament (sprite rows 43-59), and the emblem stops 2px above the rule as specified, so
Raves shows the glyph without its descending tail. That is the same outstanding item, not a new
defect — it is listed here because the side-by-side makes it the most obvious remaining difference
on the screen.

## Re-taken 2026-08-09, after the popup chrome work

Five rendering commits landed on this popup after the baseline above was recorded — the rule
caps changed from 2×10 ticks to Qud's 2×4 squares, the emblem was extracted and drawn, its three
strokes were carried below the top rule, the context divider gained its own three-stroke
ornament, and every rule break is now capped on BOTH sides. The pin is unchanged
(`sync-raves-and-qud`, cloth robe by name via `fixture.py twiddle robe`).

**Scored against the OLD baseline before re-taking, so the effect is visible rather than
absorbed** — the trap this directory's first README was written about:

| leaf | old | now | delta |
|---|---|---|---|
| popup_frame_text_color | 2.30 | 2.30 | +0.00 |
| popup_frame_text_content | 4.98 | 4.98 | +0.00 |
| popup_frame_text_geometry | 0.25 | 0.25 | +0.00 |
| popup_image_color | 0.00 | 0.00 | +0.00 |
| **popup_image_frame** | **2.28** | **1.36** | **−0.92** |
| popup_image_geometry | 0.00 | 0.00 | +0.00 |
| popup_placement | 0.00 | 0.00 | +0.00 |

Six of seven unmoved, and the one that moved got BETTER: `popup_image_frame` is the chrome
around the item tile, which is exactly what the cap and ornament work touched. Nothing
regressed, so this retake cannot be hiding one — the standing risk with any re-baseline.

The previous numbers are kept in `scoreboard.json` under `previous`.

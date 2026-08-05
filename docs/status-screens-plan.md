# V4 — In-game status screens (the 8-tab StatusScreensScreen)

Qud's in-game menus are ONE modern super-screen — `StatusScreensScreen` (the scene the
heartbeat reports for every tab) — with eight tabs sharing a chrome. Reference captures
for all eight (driven via `hv click --hover` on the tab headers — plain clicks only
hover-select; the hover event must precede the click for Qud to route it) live in
[`reports/2026-08-04-status-screens/`](../reports/2026-08-04-status-screens/).

## The shared chrome (build ONCE — Phase 1)

Measured off the captures:

- **Overlay over the live game**: the screen draws on a translucent scrim over the
  DIMMED playfield + chrome (unlike the title menus' opaque console background). The
  in-game top bar / HP / ability bar stay visible behind it, darkened.
- **Tab bar** (y≈110..160): 8 tabs, each icon + letterspaced name; ACTIVE tab = white
  text + coloured icon on a lifted background; inactive = dim teal. Page-flip chevron
  clusters with keycap hints at both ends.
- **Bottom hint bar** (y≈962): nav icon + per-tab hints ("[Space] Accept", "[M] Buy
  Mutation", …), and the `<search> X` field bottom-left (most tabs).
- Tab flip: click a tab header, or the page keys (the chevron hints).

Raves side: a `StatusScreens.gd` overlay opened from the viewer (natural opener: the
1:1 compact top-menu icons, currently cosmetic placeholders), scrim + tab bar +
hint bar 1:1, per-tab content panes plugged in as they're built, scene report
`status_<tab>`, Esc closes back to `in_game`.

## Data audit (what each tab needs from the mod)

| tab | data | mod work |
|---|---|---|
| Message Log | message history — the client ALREADY receives it (MessageLog panel) | none |
| Attributes & Powers | stats (mostly in the snapshot already) + mutations w/ ranks + descriptions | small exporter |
| Skills | skill tree: categories, skills, SP costs, learned state | exporter (SkillFactory + player parts) |
| Quests | quest list + steps + completion state | exporter (quest manager) |
| Reputation | faction table + standing values | exporter (PlayerReputation) |
| Journal | JournalAPI entries by category | exporter |
| Equipment | body-part tree + equipped items (+ tiles via TileExporter) | exporter |
| Tinkering | known recipes, bit pouch, build/mod modes | exporter (TinkerData) |

Heartbeat extension: export the CURRENT TAB index/name alongside the scene (reflection
on the StatusScreensScreen instance) so highvisor can tell tabs apart first-party —
today every tab reports the same scene and OCR can't distinguish them (all 8 names are
always visible in the bar).

## Porting order (data-simplicity first; each = exporter → pane → capture-diff → eyes-on)

1. **Shared frame + Message Log** — no mod work; validates the frame, scrim, tab bar.
2. **Attributes & Powers** — reference already studied; stats mostly present.
3. **Skills** — DONE (2026-08-04, **4.83 mean-diff**): `SkillsExporter.cs` → `skills.json` carries
   QUD'S OWN row markup (`SPNode.ModernUIText` for powers; `SkillsAndPowersLine.setData`'s left/right
   strings for categories) so `StatusPaneSkills.gd` has NO colour/cost logic — it lays strings out and
   resolves `{{…}}` through the palette. New `QudText.runs()` renders markup as canvas draw runs (a
   RichTextLabel per row is far too many nodes at ~140 rows). Category column is RIGHT-aligned at
   x1135. INTERACTIVE (2026-08-04): Space accepts a row → `SkillsAndPowersScreen.SelectNode` (Qud's
   OWN purchase flow, so its "Are you sure you want to buy X for N sp?" / "already have that" /
   "not enough SP" popups mirror to Raves and the answer round-trips), Left/Right collapse/expand a
   category (Qud's XAxis model), click selects. Verified live: collapse 40→30 rows, buy Acrobatics
   164→89 SP with the confirm answered in Raves, then a save reload restored the character. NOTE:
   the pane is canvas-drawn (no per-row Controls), so mouse events are routed from the screen's
   modal root — a full-rect child's own `_gui_input` never fires under it. MOUSE MODEL mirrors
   `SkillsAndPowersLine` exactly: the `[+]/[-]` expander toggles a category; a BODY click toggles it
   too when the skill is already learned, and otherwise accepts (Qud's buy confirm protects
   misclicks). **Accepts MUST run through `APIDispatch.RunAndWaitAsync`** like Qud's own `Accept()`
   does — `SelectNode` uses the SYNCHRONOUS `Popup.ShowYesNo`, and calling it straight from a uiQueue
   task deadlocked the modal wait so the purchase completed EVEN WHEN THE PLAYER ANSWERED NO.
   Verified after the fix: decline leaves SP untouched, accept spends correctly.
4. **Quests** → 5. **Reputation** → 6. **Journal** — read-only lists/tables.
7. **Equipment** — IN PROGRESS (2026-08-04). Exporter DONE and verified live:
   `InventoryExporter.cs` → `inventory.json` mirrors `InventoryAndEquipmentStatusScreen` +
   `InventoryLine` — items grouped by Qud's `GetInventoryCategory()`, row label = `go.DisplayName`
   (markup intact), item weight `[n lbs.]`, category weight `|n lbs.|`, header `${GetFreeDrams()}` +
   `carried/max` (verified $32, 45/285 against the reference). NOTE: `RenderForUI` returns a
   RenderEvent — read its `_Tile`/`ColorString`/`DetailColor` FIELDS, not the Renderable accessors.
   `StatusPaneInventory.gd` RENDERS (list area **7.49 mean-diff**): letters, category rows with
   `[-]`/`[+]` + `|n lbs.|`, item tiles + names + `[n lbs.]`, and the `$drams | carried/max` header.
   The earlier "blank pane" was a STALE BUILD, not a code fault — instrumentation showed setup/rows/
   draw all firing correctly on a rebuild (lesson: verify the running build before debugging the
   code). Hotkey letters match Qud's spread exactly on this character, including the d/e/q/s skips.
   PAPER DOLL DONE (**4.98** in that region; full frame **4.76**): Qud's fixed 14-slot grid — 55x62
   boxes on columns x{283,373,463,553,643} and rows y{246,366,486,606,726}, each drawing its equipped
   item's tile with the label centred beneath and Qud's `*` on the primary limb. Body parts come from
   Qud's own `Body.GetParts()` (name/type/Primary/Equipped-or-DefaultBehavior); part names arrive
   LOWERCASE, so the cell label is rebuilt from TYPE + side ("hand"+left -> "Left Hand", "back" ->
   "Worn on Back"). ITEM NAMES FIXED: `DisplayName` is `GetDisplayNameEvent` over `Render.DisplayName ?? Blueprint`,
   and for some worn items that base comes back empty so only the AV/DV badges arrive — the exporter
   now detects a nameless result (markup/punctuation only, <2 letters) and falls back to
   `GetDisplayName(int.MaxValue)`, then `DisplayNameOnly`, then the blueprint. BADGES FIXED globally:
   Qud stores them as raw CP437 CONTROL bytes (AV 0x04 ♦, DV 0x09 ○, damage 0x03 ♥), which render as
   nothing in a modern font — `QudText.cp437()` maps 0x01-0x1F and runs in BOTH `runs()` and
   `to_bbcode()`, so every pane benefits ("cloth robe ♦1 ○0" now matches Qud). FILTER STRIP ported
   (44x38 cells from x620, 58px pitch, y178: an ALL cell then one per category present, mirroring
   `filterBarCategories`) — DEVIATION: Qud draws fixed per-category icons inside a bracketed frame;
   we stand in with each category's first item tile in a plain box until those icons are extracted.
   FILTER SELECTION WIRED: clicking a cell toggles that category in/out of an enabled set (Qud's
   `enabledCategories` model — multi-select), ALL clears it, and an empty set means "*All"; the active
   cells are gold-framed and the list + hotkey letters rebuild. Verified live: 341 rows of content ->
   Food only, then Food+Meds, then ALL back to 341. CATEGORY ICONS are now QUD'S OWN: the exporter reads
   `FilterBarCategoryButton.categoryImageMap` (Light Sources -> sw_torch_lit, Armor -> sw_leather_armor,
   …) and the strip paints them in that button's fixed two-tone (0.596,0.529,0.372 / 0.545,0.4,0.18),
   falling back to the category's first item tile for an unmapped category.
   **RECAPTURE SOLVED (2026-08-04):** the opener is the ordinary TURN-THREAD command path —
   bridge `command CmdEquipment` (likewise CmdSkills / CmdCharacter / …) opens Qud's status screens
   at that tab and works UNFOCUSED. `StatusScreensScreen.show()` hangs from both a uiQueue task and
   a `UiContext.Post` (its `NavigationController.SuspendContextWhile` waits on the gameplay input
   context the turn thread owns), so don't call it directly. `equipment_qud.png` is now a
   MATCHED-STATE capture from the live save; the earlier caveat is retired. Matched diffs:
   full frame 5.19, paper doll 5.59, inventory list 7.94, filter strip 12.92, header 15.83 —
   the strip and header are the real remaining work.
   STRIP ALIGNED (2026-08-04): cell borders measured off the matched reference — ALL at x560, category
   cells from x618 on a 58px pitch, 44 wide — and Raves' borders now land within 1px (559/617/675 vs
   Qud's 618/676). The band diff ROSE (12.9 -> 15.4) even so, which means the geometry is right and the
   CONTENT per cell differs: prime suspect is ORDER — the exporter sorts categories alphabetically for
   the list, while Qud's `filterBarCategories` is built in INVENTORY-ENCOUNTER order, so icon N in the
   strip isn't the same category. Fix: export the strip order separately from the list order.
   HEADER: the "header band" diff was measuring the wrong thing — the bbox y220..254 that looked 43px
   too narrow includes the list's `|5 lbs.|` category-weight column underneath, not just the
   `$32 | 45/285 lbs.` line. Re-measure the header alone before touching it again.
   **(superseded) earlier note:** re-shooting `equipment_qud.png` on the current save failed —
   Qud's status screens ignore OS-synthesized keys (the modern-UI law), the bridge
   `command CmdEquipment` doesn't open them either, and a hover-click on Qud's character chrome icon
   didn't land. Qud's heartbeat ALSO reports `StatusScreensScreen` while the playfield is actually
   showing (its `_ActiveGameView` goes stale — the same class of bug fixed on the Raves side), so
   `hv state` can't be trusted here; verify with pixels. The mod command EXISTS now — bridge `statusscreen {tab:N}` calls Qud's own
   `StatusScreensScreen.show(index, player)` (tab order: 0 skills, 1 attributes, 2 equipment,
   3 tinkering, 4 journal, 5 quests, 6 reputation, 7 message log) and logs success — BUT THE SCREEN
   STILL DOESN'T APPEAR: `show()` is async (`SuspendContextWhile` -> `showScreen` -> `await
   The.UiContext`) and a one-shot `PumpSyncContext` after the call isn't enough; it likely needs
   pumping across several frames, or must be invoked with the NavigationController idle. DIAGNOSED, still unopened: the sync pump is a NO-OP on this build (IL2CPP strips
   `UnitySynchronizationContext.Exec`; see gotchas), and `show()`'s task never completes or faults —
   so the hang is re-entrancy, not starvation: we call `show()` from INSIDE a uiQueue task while it
   wants `NavigationController.SuspendContextWhile`. NEXT LEAD: invoke it from a non-uiQueue path
   (a one-shot MonoBehaviour Update hook, or whatever Qud's own chrome button uses) rather than
   pumping anything.
   **Verification gotcha (cost a bad reference):** (17,52,51) is BOTH the status-screen scrim and
   Qud's ground colour, so "scrim coverage" reported 96% on a plain playfield. Check the tab-bar
   strip at (740,137) = (136,165,144) or a paper-doll box border at (486,247) = (51,80,91) instead.
   **MEASUREMENT CAVEAT for this tab:** `equipment_qud.png` was captured on a DIFFERENT inventory
   (cloth robe / canteen) than the live save, so per-region diffs here include real CONTENT
   differences — only geometry/structure comparisons are meaningful until a matched-state reference
   is recaptured. OPEN: the header block still doesn't line up — Qud's spans x1548..1753 (205px) and
   y220..249 where ours renders 160px at 16px; drawing at 20px matched the left edge but WORSENED the
   glyph diff (13.3 -> 16.0), so it is a different face/tracking, not just size. Left at the
   better-scoring 16px form.
8. **Tinkering** — most complex (bits, recipes, modes).

Interactivity (buy mutation, equip, tinker, quest tracking) follows the menus-V3 law:
visual parity first, actions wired per-screen afterwards over the bridge.

**Done off-order — Control Mapping** (2026-08-04, `ControlMappingScreen.gd`, its own screen, not a
tab): system-menu popup pick mirrors into Raves (`popup_option` by text), data from
`BindingsExporter.cs` (Qud's own formatted binds via `CommandBindingManager.GetCommandBindings`,
CP437 arrows mapped client-side), read-only v1 at **5.56 mean-diff** measured WITH the
faithfully-mirrored ghost legacy-console frame Qud leaves behind the modern list.
**Deliberate deviation** (Daniel): the ghost is HIDDEN by default (`SHOW_GHOST=false`) — it makes
the real content hard to read; flip it on to re-measure full parity. Also Raves-added UX (Daniel):
hovering a rail category jumps the list to that section and its marker square goes gold (clamped
at the list end, so the last sections can't reach the very top). INTERACTIVE (2026-08-04):
click/arrow to a cell, Space (or click again) captures the next key combo → `KeybindApplier.cs`
applies it through Qud's own `ReplaceCommandBindingIndex`/`InitializeInputManager`/`SaveCurrentKeymap`
(conflict + confirm popups mirror back through the popup bridge); Delete clears (Qud confirm
mirrored); [+] = Qud's RestoreDefaults flow. GOLDEN COPY: before the first Raves-side edit the mod
snapshots `bindings.golden.json` + `keymap.golden.json` (support dir; reference committed at
`reports/2026-08-04-status-screens/bindings.golden.json`); `rebind action=regolden` RE-SNAPSHOTS it
from the current bindings (confirmed in-app — the auto-snapshot only ever fires once, so a keymap
tuned since then needs an explicit refresh; both actions are rows in the user-mode RAVES section);
bridge `rebind action=golden` restores it
via LoadCurrentKeymap — full set→remove→golden-restore loop verified live. Esc closes both sides (`uiback`
`KeybindsScreen.Exit()` special-case + a SynchronizationContext pump so the async close chain — which
macOS stops draining for an unfocused window even with runInBackground — resolves without a focus;
turns verified unblocked with Qud never activated). REMAPS WORK IN RAVES: `QudBinds.gd` parses the
exported display strings and Main routes any unclaimed key combo matching a binding to Qud's command
executor (hardcoded Raves keys keep precedence; "{" → Move east verified by player position).
USER MODE ONLY: a RAVES rail category below Debug with the golden-restore action row (hidden in 1:1;
the screen now opens from the mirrored menu in both modes). Residual diff lives in the hint row
(ability-bar z-order differs) + title glyphs.

**Popup chrome (2026-08-04, PopupOverlay.gd)**: mirrored dialogs now wear Qud's frame, measured off
`sysmenu_qud.png` — panel (6,37,37), inset top line (53,90,98) with the centred notch + stops, bottom
line (64,106,115) running through the button row's gap, 26px selection bar (23,59,60) with gold ">",
option/hotkey/disabled colours straight from Qud's own {{...}} markup via QudText.to_bbcode (the
palette ships in snapshots; Qud's 'W' is the gold #cfc041). Same +6 capture-fit compensation as the
control-mapping screen. Menu + yes/no verified live side-by-side. TITLED dialogs (2026-08-04, off the
"Selected Bind Set" picker): the top line is FULL WIDTH with a 10px centre notch (down-ticks) and 6px
side notches at ±w/3.1 (outward ticks) — not one big gap; a title gets its own row beneath (gold 'W',
centred, natural width drives the panel) flanked by ─┤ ├─ edge assemblies; the line drops to +16.
Verified 213px vs Qud's 221 on the same popup. BANNER MODE (2026-08-04): plain messages/confirms
render as Qud's wide strip — it measured OPAQUE (6,37,37), not transparent (strip 673x76 for a
one-line confirm): top line at +4 with the same notches, message width drives the strip (wraps at
1240), button row in the bottom line with the gold-family "> " keyboard cursor (Left/Right move,
Space/Enter answer) and 34px spacing. Backdrop = flat _cq(17,52,51) at 0.88 alpha (the popup layer
sits ABOVE the CRT, so the status-screens scrim formula rendered too dark — fit to the measured
flat value instead); landed (18,51,50) vs Qud (17,52,51). FLICKER FIX: async popups never block the
turn thread, so Main's "any snapshot hides the popup" rule made mirrors flicker (show → hide →
re-announce) — the watcher's active:false is now the only dismissal channel (Esc always escapes a
stranded overlay locally). ASYNC ANSWERS FIXED (2026-08-04): the copyWindow class (ShowYesNoAsync / PickOptionAsync /
AskString) now round-trips. Two causes: (a) answers re-scanned for the popup and could hand the
answer to a different instance — the watcher now HOLDS the exact instance it announced and answers
that; (b) UIManager pools popup copies in a private static Queue and a RELEASED copy still looks
"live" (visible + non-null callback), so scans picked pooled ghosts — candidates in the free pool
are now excluded. Input submit uses Qud's own OnInputSubmit. Every answer pumps the sync context
(Bridge.PumpSyncContext) so the awaiting chain resumes on an UNFOCUSED Qud. Verified live with Qud
never focused: yes/no No dismissed Qud; Yes advanced to the async PickOption picker; option 0 picked
and applied defaults; golden restore + a fresh rebind both round-tripped. NOTE: PickOptionAsync
defaults to AllowEscape=false, so Esc doing nothing on that picker is QUD'S behaviour, not a bug. Also fixed: popup hotkey answers no longer leak into MainFrame's status-tab keys (_input vs
set_input_as_handled), and popup row rebuilds remove old children immediately (queue_free lingers a
frame and poisons same-frame re-shows).

## Per-screen workflow (the proven V3 loop)

1. `hv goto` recipes + first-party asserts for the tab (gametree nodes exist).
2. Numeric anatomy off the reference (geometry, palette via QudChrome, fonts).
3. Mod exporter (if needed) → JSON in the support dir, re-export on bridge command.
4. Build the pane; capture-diff both apps to the 2–5 mean-diff family.
5. Commit + push (author guard) per converged screen; Daniel eyes-on rounds.


## Equipment filter strip — icon tint finding (2026-08-04)

The two-tone already matches Qud to 1/255 (Qud 141,124,84 / 128,91,41; ours 140,123,83 / 127,91,40),
so tint was never the problem. The real gap is INK COVERAGE: Qud's per-cell icon ink spans ~18x23
where ours spans ~13x13 — we draw a sprite with a smaller opaque area, not a mis-tinted one. Two size
attempts (26x26, then an aspect-correct 18x27) both scored WORSE (11.53 -> 11.89 / 11.61) and were
reverted. NEXT: chase WHICH sprite each cell receives (the category-to-icon pairing under Qud's
ordering), not its size or colour. Strip stands at **11.53**, full frame **4.52**.


## Equipment paper doll — item tile size (2026-08-04)

Daniel: "Qud's doll images look ~20% bigger." Measured: Qud's equipped-item INK spans ~47x48 inside
the 55x62 slot (bark armor 47x48, torch 47x45, boots 47x43) where ours spanned 22x25 — more than
DOUBLE, not 20%. The draw rect is now 47x50 at slot+(4,6); our ink measures 41x32, closer but still
short of Qud's, which suggests Qud renders these at a larger source scale rather than stretching the
16x24 tile (our sprite runs out of opaque rows before filling the box).

Numbers after the change: doll band 5.59 -> 5.63 (flat), FULL FRAME 4.52 -> 5.20. That full-frame
jump is NOT explained by the doll region alone and was not investigated — re-measure with a fresh
matched reference before drawing conclusions from it.


## Equipment paper doll — tint (2026-08-04)

Measured, both apps, same slots. Qud paints doll items in a FIXED two-tone: main (141,124,84) — the
same tan as the filter bar — plus an accent (armor gold 200,184,57 / torch red 156,65,41 / boots pale
168,194,187). Raves was drawing each item's OWN main colour (142,91,24 / 169,169,169), a completely
different palette.

FIXED (main): the doll now draws with the filter-bar tan and our main tone measures (140,123,83) vs
Qud's (141,124,84).

STILL OPEN (accent): our accent comes from the item's detail code and renders (255,203,0) where Qud
shows (200,184,57) — brighter and more saturated, so the accent is NOT a straight palette lookup;
find what EquipmentLine feeds the third colour. Also STILL OPEN: source scale — our ink is 41x32 vs
Qud's 47x48, so Qud renders these sprites from a larger source, not a stretched 16x24 tile.
Doll band is flat at ~5.6 through both changes because shape/scale mismatch dominates the average.


## Equipment tiles — NEAREST filter + doll aspect (2026-08-05)

Daniel spotted the doll tiles looking BLURRED. Cause: the pane's drawing Controls inherited the
default LINEAR texture_filter — the same law that bit the status-screens tab icon
("draw_* calls inherit the drawing Control's texture_filter"). `_static` and `_content` are now
NEAREST, so doll items, filter icons and inventory row tiles are all crisp.

Doll tiles also re-shaped to the source 2:3 (36x54 in the 55x62 slot, was a stretched 47x50):
narrower and taller, ink 32x36 (was 41x32).

**The band averages got WORSE for both changes** — doll 5.64 -> 5.72, strip 11.53 -> 12.62, full
5.20 -> 5.22 — while the pane visibly improved. That is the metric misleading, not a regression:
BLUR REGRESSES TO THE MEAN, so a soft tile scores better against a mismatched reference than a sharp
one does. Treat per-band means as a coarse guide only; for tile work compare crops and ink boxes.
Qud's doll ink is 47x48 (nearly square) vs our 32x36, so Qud is NOT drawing a 2:3 tile scaled — it
renders these from a larger, wider source. That remains the open item.

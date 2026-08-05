# Checker pixel-pass findings — first full scored sweep (PC, 2026-08-04)

**BASELINE (2026-08-05, daylight-guarded, all fixes applied): 2482/2483 scored —
2432 PASS (98.0%) / 30 WARN / 6 FAIL / 14 KNOWN. Wire 2483/2483.** The 6 FAILs:
the Switch class (4, section 6) + one food + one creature single.

Original first-sweep numbers below for the record. All seven categories complete: walls 222/1/0 (PASS/WARN/FAIL), plants 178/1/1,
liquids 74/1/2, furniture 688/28/22, food 270/0/0, implants 0/31/45,
creatures 864/10/9 — pixel-scored 2492 elements, 93.7% PASS. Wire-level:
everything PASS. Cell-crop pairs for every flagged element are committed under
`reports/checker/evidence/<cat>/` (full frames are scratch, gitignored). The
failures collapse into four families (+ creature singles):

## 1. ~~Implants render a DIFFERENT TILE~~ FIXED 2026-08-04 (76/76 pixel PASS)

Every cybernetic scores WARN/FAIL. Eyeballed `AirCurrentMicrosensor`: Qud's own
ground render is a small blue pile sprite; Raves draws the wire's tile — the
item's full device art (orange+blue). The mod's snapshot carries a tile that is
NOT what Qud's renderer chooses for cybernetics on the floor. Fix belongs in
`ZoneSnapshot`'s tile choice (reflect how Qud picks ground art for takeable
items — "reflect, don't guess") — not in the Godot client.
**Root cause: the `EpistemicDisguise` EFFECT substitutes the unknown-sample's art at render time for unexamined artifacts; the mod's getTile() bypass missed it. ZoneSnapshot now mirrors the substitution. Re-sweep: 76 PASS / 0 WARN / 0 FAIL.**

## 2. ~~Conveyor pads + DisabledSwitch~~ FIXED 2026-08-04 (all ~1.5 PASS)

Root cause: these blueprints carry NO static tile — ConveyorPad.Render(E)
computes `Tiles/sw_conveyor_<dir>_<frame>` inside the render-event pipeline,
which getTile() bypasses; the wire shipped a dark glyph and Raves drew bare
floor. ZoneSnapshot now runs ComponentRender as last-resort art resolution
for tile-less objects (EventArt). ConveyorPad 118.2→1.52, DisabledSwitch
116.7→1.50, Crematory variants ~1.51 — all PASS.

## 3. Multi-cell / oversized sprites mis-crop — now KNOWN-listed (fixtures/checker_known.json)

100% hot = the stage-cell crop catches entirely different content — these
blueprints occupy >1 cell or anchor their sprite off the stage cell. The
CHECKER needs a multi-cell staging rule (detect Render size / OccludesTiles?)
before these can be scored; today they are false positives of the harness.

## 4. Animation-phase singles (expected; rung 4's job)

`FreshWaterPool500`, `WarmStaticPuddle` family, `MachineWall*Tubing` (now only
WARN at exact rects), assorted furniture WARNs. Same-turn pairs catch different
animation phases (~1.5s between the two captures). These route to the
animation-fixture pass (`docs/pc-test-rig.md` rung 4), not single-frame
congruence — consider auto-tagging elements whose re-check score varies
run-to-run as "animated" in the report.

## 5. Creature singles (9 FAIL / 10 WARN of 896)

Jilted Lover, Livid Creeper, Madpole, HumanApothecary, Gyre Wight of Qon,
Ehalcodon, Gyrohumor, Conservator Special, Dawnglider. The names read as
animated/glowing/flying — likely rung-4 fixtures or drift-off-cell (fliers bob).
Triage individually from the evidence crops.

## 6. Switch / TempleSwitch: render-event TILE REPLACEMENT (open — design fork)

Post-EventArt furniture re-sweep: `Switch` and `TempleSwitch` still show the
pre-fix conveyor signature (~117 mean / 78%% hot = bare floor in Raves). They
DO carry a static tile, so the tile-less EventArt gate skips them — but Qud's
handler REPLACES the tile per frame (blinking switch). Adopting event tiles
unconditionally would make every wire tile frame-tracked, which collides with
the client-side animation architecture (monosludge/engulfed decode work).
DECISION NEEDED (with the Mac): per-frame wire tiles vs a client-side switch
fixture. Daylight-guarded final list of true furniture FAILs (7): Switch,
TempleSwitch, Unicomputer (62.2 — blinking computer, likely same class),
SolidHighTechInstallation, Starship 1 Platform N/S, Sign (29.4 — variant
divergence?). Everything else in furniture: 711 PASS / 15 WARN / 12 KNOWN.

## 7. Singles triage (2026-08-05)

- **CaverCorpse / CaverCorpse2 — ~~export bug~~ FIXED 2026-08-05: it was the
  WINNER TIE RULE.** The Bones colour trail was a red herring — the wire's
  `tilecolor &M` was right all along (RandomColors mutates ColorString only;
  the RandomTile variant re-roll is builder behavior, benign). The real bug:
  the corpse spills its inventory into the cell, giving TWO layer-6 objects
  (corpse idx 0, unexamined trinket idx 5). Classic Cell.Render breaks ties
  last-wins (`>=`), which the 1:1 winner had faithfully copied — but Qud's
  MODERN tile stage draws FIRST-of-ties (measured). ZoneRenderer's 1:1 winner
  now uses strict `>`. Probes: CaverCorpse 22.7 WARN → 5.33 PASS,
  CaverCorpse2 3.56 PASS; liquids regression re-sweep clean (the only flags
  are the warm-static animation family, section 4).
- **Fire Ant Queen — one-off staging interference, not a render bug.** The
  baseline pair caught her mid-BURROW: Qud's frame shows the staircase tile
  she left behind. Re-probe: PASS 1.72 clean. Watch for recurrence; if it
  repeats, clear Burrowing goals in ObjectChecker.Pacify.
- **Sign — intermittent variant divergence.** FAILed one run (29.4), PASSed
  the baseline: Qud and the wire roll RandomTile sign variants independently
  per staging. Variant determinism is a small follow-up (export the variant
  Qud actually drew — likely falls out of the Bones-part fix pattern).
- Furniture's four baseline FAILs (Phasic Screw, PistonPressElement,
  Platform, Powered Telescope) are the section-6 animation / tile-replacement
  class — Phasic Screw's evidence shows literal phase bands.

## 8. Rung-4 first animation baseline (2026-08-05) — two real gaps, two exonerations

Measured with `checker.py anim` (12-frame jittered bursts, distinct-state counts
per app, behaviour-class agreement; fixtures/checker_anim.json holds the bands):

- **MachineWall*Tubing: qud 11-state continuous, raves 1-state STATIC** — the
  coolant animation is not ported. Real renderer gap (the walls WARNs).
- **Phasic Screw: qud 5-state discrete, raves STATIC** — phase flicker missing.
- Warm-static liquids: 4-vs-4/3 discrete, AGREE — their recurring pixel
  WARN/FAILs are pure capture-phase mismatch; the animation is congruent.
- Switch/DisabledSwitch: 1-vs-1 static — an UNPOWERED switch doesn't blink, so
  the section-6 'blink' theory is wrong for the pixel FAILs: those are a static
  art difference. Re-triage Switch/TempleSwitch/Unicomputer from evidence crops.
- Campfire sanity: 11-vs-12 continuous, AGREE. ConveyorPad: 4-vs-3, AGREE.

Also fixed en route: Godot's animation clock freezes unfocused on Windows (the
anim burst focuses each app for its own capture), and plat_win.activate no
longer SW_RESTOREs un-minimized windows (it shrank the borderless viewer to its
pre-size default — the same class as highvisor's UIA quirks).

*Delete sections as addressed (repo ticket lifecycle).*

# Checker pixel-pass findings — first full scored sweep (PC, 2026-08-04)

All seven categories complete: walls 222/1/0 (PASS/WARN/FAIL), plants 178/1/1,
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
fixture. ~2 elements; also triage `Sign` (29.3 — variant divergence?) and the
wormhole/platform/turbine WARN band (animated).

*Delete sections as addressed (repo ticket lifecycle).*

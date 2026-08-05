# Checker pixel-pass findings — first full scored sweep (PC, 2026-08-04)

All seven categories complete: walls 222/1/0 (PASS/WARN/FAIL), plants 178/1/1,
liquids 74/1/2, furniture 688/28/22, food 270/0/0, implants 0/31/45,
creatures 864/10/9 — pixel-scored 2492 elements, 93.7% PASS. Wire-level:
everything PASS. Cell-crop pairs for every flagged element are committed under
`reports/checker/evidence/<cat>/` (full frames are scratch, gitignored). The
failures collapse into four families (+ creature singles):

## 1. Implants render a DIFFERENT TILE in Qud vs the wire (whole category)

Every cybernetic scores WARN/FAIL. Eyeballed `AirCurrentMicrosensor`: Qud's own
ground render is a small blue pile sprite; Raves draws the wire's tile — the
item's full device art (orange+blue). The mod's snapshot carries a tile that is
NOT what Qud's renderer chooses for cybernetics on the floor. Fix belongs in
`ZoneSnapshot`'s tile choice (reflect how Qud picks ground art for takeable
items — "reflect, don't guess") — not in the Godot client.
**All 76 flagged implants are one bug.**

## 2. Conveyor pads (+Crematory variants, DisabledSwitch): uniform ~118 mean / 78% hot

All ten pad orientations identical scores — systematic, likely an unrendered /
differently-rendered animated surface in Raves (conveyor belt animation).
Includes `DisabledSwitch` (116.7). One renderer gap, ~12 elements.

## 3. Multi-cell / oversized sprites mis-crop: Marble Dais (135.8/100%), TauSoft (89.6/100%)

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

*Delete sections as addressed (repo ticket lifecycle).*

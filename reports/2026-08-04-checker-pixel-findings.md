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

## 9. THE DAYLIGHT WIDGET (2026-08-05) — root cause of every "dim zone" symptom

ObjectChecker.ClearZone was obliterating the invisible DaylightWidget with the
rest of the zone, so BeforeRenderEvent radiated NO time-of-day light: every
cell shipped light=None(1), BOTH apps rendered ghost-dark (pixel parity kept
passing — dark compared against dark — masking it for days), and the 1:1
client never registered ANIMATIONS on the "unlit" stage. Fixed: ClearZone
spares Render.Visible=false bookkeeping objects (the plan's own
"widgets-excluded" rule) and Check re-seeds a missing widget to heal zones
damaged by older clears. Verified: stage light 1 -> 200, the zone renders in
true daylight for the first time since slice 2. NOTE: all committed pixel
baselines were measured dark-on-dark — still valid parity, but a bright-world
re-baseline will shift absolute numbers.

## 10. Phasic Screw port DONE (raves side verified); tubing exonerated; qud bursts open

- AnimatedMaterialGeneric is now exported ("animFrames" spec: len|frame=tile|...)
  and played by the client's frames program on the shared 60fps clock. Measured
  on the live viewer: raves 5-6 discrete states (was 1 static) — matching Qud's
  own 4-6. The port covers ANY AnimatedMaterialGeneric element generically.
- The tubing walls were EXONERATED: their "11 continuous states" were sub-noise
  brightness breathing (~1.8 mean between every frame pair vs the Phasic
  Screw's real 4.4-8.2). The measurement now clusters states over a 3.5
  noise floor; tubing reads 1-vs-1 AGREE. Fixture bands updated.
- OPEN: this boot's QUD bursts read everything static (a staged campfire's
  cell diffs 0.8 over 2s even focused) — Qud's mid-turn presentation isn't
  reaching ScreenCapture this session; cause undetermined (no exceptions in
  Player.log). Re-measure the qud side on a fresh boot before trusting
  qud-side anim numbers from this one. Also REVERTED: the ALT-tap foreground
  unlock injected input into Qud ("You toggle Butcher Corpses off") — plain
  verify+retry stays, AttachThreadInput is the clean path if ever needed.

## 11. FIRST-LIGHT BASELINE (2026-08-05, true daylight) — the next stratum

With the DaylightWidget fix, the first bright-world sweep re-scored everything:
walls 97/114/18, plants 166/6/8, liquids 76/2/1, furniture 649/37/47,
food 275/0/0, implants 77/0/0, creatures 322/45/528 — overall 67.0% PASS.
Items are essentially perfect; the drops are structured, not noise:

- **Creatures (528 FAIL): WITHDRAWN — there is no two-tone rule.** The cherub
  evidence was SPAWNER TIMING (CherubimSpawn replaces itself between the two
  captures; real cherubs are &Y white natively) and the mass failures were
  POPUP POLLUTION: Raves renders mirrored Qud popups as overlays covering the
  playfield, and an undismissed creature-triggered message sat over the stage
  cell for most of the leg (dromad-class crops scored against popup text).
  Glowfish et al confirm creature tints are faithful. shots_for now clears
  the viewer's reported popup before capturing; creatures re-ran guarded.
- **Walls: RE-BANDED + the gold-frame family FIXED (2026-08-05).** Bands
  PASS<=26 / WARN<=34 (anchored on eyeballed pairs). The Starship fix was a
  RULE, reflected from the XML: gap fill = the ^X component of TILECOLOR when
  present (Starship '&y^W' gold, HangarWall '&y^Y'), else world bg — which
  reconciles BOTH prior measurements (metal walls flooded cyan off
  COLORSTRING's ^R, glyph-mode noise; the salt puddle's compound stays
  glyph-only). Flat-mode occluding walls with a ^ TileColor now fill.
  Starship family 31-47 -> 10-12 PASS; walls certify 224/0/5. The 5
  remaining (Stasisfield, HangarWall-intermittent, Cryochamber, Resheph,
  YdFreehold pipes) behave run-to-run variable — animated-tail candidates
  for the rung-4 fixture list.
- Furniture 47 + walls 18 + plants 8: triage after the two big levers above.
- MID-RUN INCIDENT, fixed: the merged stack/dock op applied a MAC-layout rect
  via window_rect.json (y=-1269) and silently rescaled the viewer mid-sweep
  (557 phantom furniture FAILs). The viewer now rejects off-screen
  placements; the poisoned categories were re-swept clean.

Dark-era baselines remain in git history as valid dark-parity records; THIS
is the canonical baseline lineage going forward.

## 12. THE ANIMATED TAIL, FULLY MEASURED (2026-08-05 evening)

Every remaining FAIL was burst-measured (fixtures walls-tail / plants-tail /
furniture-tail / creatures-tail). Reports now band four ways: ANIM =
agreement + actual animation (verified by state agreement, single-frame diff
is phase); KNOWN = unverifiable (spawners, multi-cell); FAIL = attributed.

**PORT BACKLOG — real animation gaps, with measured targets (qud states):**
- Stasisfield shimmer (3), ReshephWall2 blink (2)
- Chavvah Chime L+R — continuous swing (11)
- Wormhole swirl (7), Wooden Water Wheel (6 vs raves 3 — partial port)
- Mechanical Succulents Cherub (3)
- ~~POWERED-DEVICE BLINK FAMILY~~ PORTED (2026-08-05 late). Mechanism:
  AnimatedMaterialGenericAlternate — an EMPTY subclass of
  AnimatedMaterialGeneric carrying the power-cut icon frames, gated on
  RequiresAnyUnpoweredActivePart; GetPart<T> is exact-type so the old
  export never saw it (it sits on HighTechInstallation, inherited by the
  whole family). Export now: subclass-aware lookup, the part's full
  condition ladder evaluated at export (private StatusOf via reflection),
  all three frame axes (tile/colour/detail) merged into ONE schedule
  "len|f=tile;color;detail|..." with thresholds pre-scaled by
  SpeedMultiplier onto a plain 60fps clock. Client plays it with
  replacement frames built OPAQUE (Fill.ALL masks the steady base — Qud
  swaps the whole tile). Covers the Force Projector detail-colour cycle
  (r/R/y) too. All 8 members re-measure AGREE; Phasic Screw regression
  AGREE 5/5 on the new format.
  ~~Eater Sign / Wormhole~~ BOTH PORTED (2026-08-06 small hours):
  - Wormhole: Render(E) re-rolls a RANDOM colour (5 on ^k) x glyph
    (Text 9/233/21/15) combo per repaint — a shimmer, not a cycle. New
    wire member animShimmer ships the combo tables; the client
    prebuilds every combo (each on its ^X background — the Text-tile
    branch now honours bg fill) and re-rolls every ~400ms. Measures
    AGREE continuous (7-9 states) both apps; pixel is phase (ANIM).
  - HologramMaterial is a WEIGHTED SHIMMER, not a cycle: FrameOffset +=
    Random(0,20) EVERY render, so its 200-space clock random-walks. The
    steady-last-entry export is the distribution's MODE (~94-96%) —
    right for soft palettes, wrong for Eater Sign's &W/&w contrast. New
    member animHolo ships exact combo weights; the client re-rolls by
    weight. Verified with a 60-frame burst (4%-duty flashes are
    invisible to 12-frame bursts — expected hits 0.5): qud 3 / raves 2
    discrete AGREE; pixel 45 -> 6.5 PASS.
  Furniture stands at 719 PASS / 6 FAIL (Switch fork x5 + water wheel).
- Creature programs: Gyre Wight of Qas (8!), Sleeping Plated Chromeling (6),
  Ogre Ape (6 vs 2 partial), Livid Creeper-as-creature (3), Bloated
  Pearlfrog (2), Ehalcodon (2)
- ~~CONVEYOR FRAME-SYNC~~ FIXED (2026-08-05 night) — and the theory was
  wrong twice over. Measured: Qud's idle belt is FROZEN (the 150ms advance
  runs inside Render(E), which only fires on map REPAINTS; the idle prompt
  doesn't repaint — 8 captures over 1.5s, zero structural change, while
  export-path Render calls stepped the frame w_4→w_3→w_2). So the static
  EventArt frame IS the right 1:1 baseline. The real divergence: the belt
  bmps are opaque black+white two-tone art and ConveyorPad paints "&y" via
  RenderEvent.ApplyColors at render time — EventArt resolved those colours
  and threw them away, shipping the static "&K^k" instead (pale slab vs
  dark slab, ~104). EventArt now hands back the event's applied colours.
  All 10 pads: ~104 → 4.2 PASS.

**STATIC-DIVERGENCE LIST, RE-MEASURED CLEAN (2026-08-05 late): mostly
contamination.** The first triage list was read off a rotted zone — staging
sessions corrupt the world over time (qudzu vines across cells, pacified
creatures wander off the stage cell, ambient encounters brawl; a stray
CherubimSpawn variant even killed the player). An 88-element re-probe on a
fresh golden boot dissolved almost all of it: Qudzu 88→4, ScrapChest 30→3.6,
CryochamberWallNE (the "white-vs-cyan frame") →4.1, star charts →3.4/3.9,
HangarWall 47→12, the golems/turrets/installations all single digits.
Sweeps now guard against this (`--reload-every`, default 150; reboot_rig).

Surviving TRUE static divergences — four elements:
- Jilted Lover (62, plants AND creatures stagings) — Raves floods a tan
  background Qud doesn't draw
- Panhumor (60) — humor family colour/art divergence (Humor/Gyrohumor sit
  at 27/32 WARN, likely same rule)
- Holographic Dogthorn Tree (41) — hologram palette handling
- VehicleTemplarMech3_Warleader (37) — mech variant art

Plus the documented Switch-family design fork (5 switches, ~116, s6) and
conveyor frame-sync (10 pads, ~104, port backlog).

*Delete sections as addressed (repo ticket lifecycle).*

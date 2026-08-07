# Rung 6 — zones & zone-specific artwork (the composition rungs)

The certified board (`reports/2026-08-04-checker-pixel-findings.md` §13) reads
2483/2483 wire, **0 pixel FAIL**. That certifies *elements in isolation*. This
document is about everything that only exists when elements are **composed into
a zone** — and it is, as of today, almost entirely unverified.

## Why the Object Checker cannot answer this

The checker's method is deliberate isolation: clear a rect, stage one blueprint,
crop one 16×24 cell, score it. That isolation is exactly what made it
trustworthy — and exactly what puts composition out of frame by construction.

Two measurements make the gap concrete rather than theoretical.

**Grass was never tested.** The green tufts in every Joppa capture this week are
not plants — they are `[painted ground]` objects carrying
`assets_content_textures_tiles_tile-grass1.png`, painted by the zone builder.
They appear in our captures only as scenery *outside* the scored crop. (The
catalog's `Eel Grass` / `Noisegrass` / `Slime Grass` are staged plant blueprints
— different things entirely, and those *are* certified.) Zone-painted ground —
grass, dirt, salt, ash — is 0% covered.

**Wall joinery was never tested.** Across all 229 certified wall stagings, the
sweep exercised **4 of 256 autotile bitmasks**, and 225 of the 229 were
`-00000000` — the isolated-pillar variant. The other three were accidents of
staging leftovers. We certified wall *materials* at one variant each; corners,
tees, edges, and the actual look of a room are unverified.

## The untested surface

1. **Painted ground / terrain tiles**, per biome.
2. **Wall autotiling** — 252 unseen bitmasks; the joinery rules.
3. **Per-zone camera background.** The wire ships `bg` (Joppa: `#40a4b9`) plus
   the palette; we have only ever rendered one zone's tint.
4. **Lighting.** We deliberately *pin* bright daylight (`ensure_daylight`) for
   determinism, so the entire cycle is unverified: dark zones, point sources,
   the explored-but-not-visible ghost/memory look, visibility edges.
5. **Liquid at depth** — pools vs wading vs swimming, mixes, bridges and decks
   over water, submerged sprites. (Liquid *blueprints* are certified; liquid
   *terrain* is not.)
6. **Remembered neighbour zones** — the frozen strata, global offsets, dz
   stacking, distance cull.
7. **Biome variety** — every zone type composes differently.
8. **The world map** — its own art path end to end (below).

Adjacent, object-level, worth naming here because it is also world artwork:
`weapons` = 4044 catalogued and **never swept**, `items` = 0 (the Rung 5
category-split bug). Dropped weapons render on the floor.

## Method — composition needs different primitives than isolation

The checker's three primitives (stage / crop / score) do not transfer. Three new
ones, cheapest first:

### 6a. Structural census — no pixels, no calibration

The client *already* records a placement verdict for every object: `_note(...)`
feeds CellInspector's `RENDERED <kind> y=<...>` and
`RENDERED (nothing — object was dropped)`. Turn that into a test: for a zone,
diff the wire's cell list against the client's placement log. Every wire object
should have a placement; anything dropped is a defect unless it is on the
documented skip list (no tile *and* no glyph).

This catches the loudest class of defect — "we drew nothing here" — across an
entire zone in one pass. It needs no geometry calibration, no focus, no phase
control, and therefore **cannot be poisoned by any of the six rig failure modes
that plagued certification**.

**BUILT (2026-08-06).** `tools/capture/census.py` + a `census` command on the
viewer's existing file channel (`ZoneRenderer.placement_census()` →
`census.json`). Runs in seconds, no calibration.

    pristine JoppaWorld.11.22.1.1.10 — 2000 cells: 733 ok / 1267 unexplored / 0 DROPPED

The audit must mirror the client's 1:1 contract exactly or it lies: the first
run reported **1267 DROPPED**, every one of them an *unexplored* cell that the
client correctly draws as nothing. `eligible()` now encodes the real rule —
unexplored draws nothing, visible+lit draws everything, otherwise only the
RenderIfDark ghost. That false alarm is also the proof the detector is not
vacuous: the "wire sent art, client placed nothing" path demonstrably fires.

Verdicts: `ok` / `unexplored` / `empty` / `skipped` (documented no-tile-no-glyph
rule) / `DROPPED` (defect) / `PHANTOM` (drew something the wire never sent).

### 6b. Whole-playfield congruence — pixels, masked  **[BUILT 2026-08-06]**

`tools/capture/playfield.py`. Per-cell scoring over the grid derived from the
calibrated stage cell (always zone cell 40,12) plus stride. Two corrections the
first runs forced, both worth keeping:

- **Clip to the MAP VIEWPORT, not the window.** Qud's right edge is the sidebar;
  the first run's 28 "FAIL"s were every one of them message-log text
  ("moc/ur", "10she") scored against painted ground. It also made a fractional
  stride fit chase that noise — the fit was reverted once the clip landed.
- **A PASS is not automatically evidence.** Deliberately misaligning Raves by a
  whole cell over Joppa moved the tally by 26 of 775 — dirt matches dirt
  wherever you sample it. Each cell is now also scored against its neighbour and
  reported `vacuous` when the margin is under 8. On Joppa that is **768 of 774
  cells**: sparse outdoor ground proves almost nothing, and the tool now says so
  instead of printing a green wall.

    joppa   — 1 PASS / 5 WARN / 0 FAIL / 768 vacuous
    village — 39 PASS / 76 WARN / 116 FAIL / 543 vacuous

**RETRACTED — the "remembered cells are not dimmed" finding was WRONG.**
The mod already emits `visible:false` whenever `!c.IsVisible()` ("sent only when
false; the client defaults true"), so `visible=None` meant Qud considered those
cells *visible* — the opposite of what I inferred. The actual cause: **playfield
runs never pinned daylight.** The golden save loads at segment 3250, "Harvest
Dawn" — the dimmest daylight there is — where Qud's sight radius is short and
distant cells render as dim memory while Raves draws them lit. The sweep has
always called `ensure_daylight`; `playfield.py` did not. With it pinned, the
village drops from **116 FAIL / 775 scored to 4 FAIL / 84 scored**.

Lesson, the same one the certification kept teaching: an instrument that does
not control its environment measures the environment. Daylight, window
placement, zoom and viewport all have to be pinned before a pixel number means
anything.

**RESIDUAL: also retracted. There is no water bug.** The four
`SaltyWaterPuddle` FAILs were Qud's BOTTOM STATUS BAR bleeding into row-15
crops — the montage shows "TARGE" and "T: [none]" inside the cells. I had
clipped the viewport horizontally (the sidebar) but never vertically. With both
axes clipped the village reads **14 PASS / 45 vacuous / 0 FAIL**.

That is THREE false findings from one root cause — sidebar text, unpinned dawn
lighting, and now the status bar. The rule earned the hard way: **before
believing any per-cell number, prove the crop is inside the map viewport.** All
four bounds are now constants at the top of `playfield.py`.

**What genuinely survives — a real coverage gap, found on the way.** Composed
water is AUTOTILED like walls: the village pool ships
`Liquids/Water/deep-11111000.png`, `deep-11111111.png`, `deep-11101111.png`,
while `SaltyWaterPuddle` staged alone is the isolated variant and passes at 6.1.
So the liquids category is certified at ONE autotile variant each, exactly as
the walls were. Liquid joinery belongs on the same list as wall joinery.

**GRID ANCHOR BUG (fixed in code, NOT yet verified end to end).** `cell_rect`
anchored on a hardcoded zone cell (40,12), but Qud centres the view on the
PLAYER — so the calibrated rect only names (40,12) while the player stands
where calibration left them. Every village run happened to line up only because
`goto:` preserved the player's cell (39,12), which is also where staging leaves
them. Calibration now records the player cell (`pcx`/`pcy` in the geometry
fixture) and `playfield.anchor_shift()` offsets the grid by how far the player
has moved since. **Unverified**: the rig would not calibrate again before the
session ended, so no run has yet exercised a non-zero shift.

**CALIBRATE ONLY IN A CLEAN ZONE.** Calibrating while standing in the village
fails the aspect guard (Raves cluster 66x56, ratio 1.18): the staged Wax Block
AUTOTILES with the village's existing walls, so the two differential frames
differ across more than one cell. The guard caught it correctly. Warp home,
calibrate, then warp to the station.

**And a real limitation.** At the zoomed-in pixel geometry only ~60 cells clear
the viewport, so a village run scores 14 informative cells. Whole-playfield
congruence needs the ZOOMED-OUT view to be worth its runtime; that is the next
piece of work here, not more scoring at this zoom.

*(superseded text below, kept for the reasoning trail)*
**FINDING (candidate, needs a fix decision): remembered cells are not dimmed.**
The village's 116 FAILs are dominated by water at ~91 mean, and the crops show
Qud drawing those cells DARK while Raves draws them full-colour blue. The wire
sends `explored=true, light=200` and **omits `visible` entirely**; the client
reads `bool(cell.get("visible", true))`, so a missing flag becomes *visible*,
and the explored-but-unseen memory look never engages. Either the mod must
always emit `visible`, or the client's default must invert. This is invisible to
the Object Checker by construction — it stages one cell next to the player,
which is always visible — and only appears once a zone has regions you have seen
but are not looking at.

#### original design notes

Same-turn pair as today, but scored over the full playfield instead of one cell.
Two problems, both solvable with what we already have:

- **Thresholds.** A one-sprite divergence vanishes in a whole-screen mean. So do
  not take a global mean: score **per cell over the 80×25 grid** and report a
  *failing-cell count*. The certified per-cell thresholds transfer directly —
  the calibrated cell rect is just cell(0,0), and the rest is a stride.
- **Motion.** Creatures wander between the two captures. Mask cells whose wire
  objects include a creature and score terrain/wall/ground/furniture cells only.
  Nothing is lost: the creature layer is already certified in isolation.

### 6c. Warp stations

`wish goto:<zoneID>` against the golden save's fixed world seed. Because the
seed is fixed, a zone ID composes identically on every load — the same
determinism trick that made Rung 2 work, applied at zone scale.

**BUILT (2026-08-06).** `tools/capture/stations.py` +
`fixtures/checker_stations.json`. First run, census at each station:

    joppa       JoppaWorld.11.22.1.1.10 — 2000 cells:  733 ok / 1267 unexplored / 0 DROPPED
    village     JoppaWorld.11.22.1.2.10 — 2000 cells: 2000 ok / 0 DROPPED
    underground JoppaWorld.11.22.1.1.11 — 2000 cells: 1990 ok / 10 empty / 0 DROPPED

And the payoff this rung exists for: **the village station alone exercises 23
distinct autotile bitmasks and the underground 85, against 4 for the entire
certified 229-wall sweep.** The underground also puts **1977 cells through the
explored-but-dark memory-ghost path** — a whole render mode the object checker
could never reach, since it pins every stage bright by design.

**Stations must be REVEALED before censusing.** A freshly warped-into zone is
almost entirely unexplored — underground measured **8 of 2000 cells** on its
first run — and the client correctly draws nothing there, so there is nothing
to verify. `Zone.ExploreAll()` is not wish-exposed, so the mod gained a
`reveal` verb; the driver calls it after every warp. Revealing is also what
creates the explored-but-not-visible cells that exercise the ghost path at all.

Three hard-won rules are baked into the driver:

- **The wish field is `wish`, not `text`.** `b.send("wish", text=...)` silently
  no-ops. That is why `goto:` appeared broken — and why **godmode was never
  actually applied on any boot**, which is how a CherubimSpawn's cherub killed
  the player mid-sweep during certification. Fixed in `checker.py` too.
- **Warps are paced by CONFIRMATION, never by a timer.** `goto:` triggers
  procedural zone generation that can outlast any guessed sleep. Six warps on
  fixed 3.5s sleeps deadlocked Qud outright — frozen frame, no UI, unreachable
  over the bridge, needing a process kill and a menu-driven reload. `warp()`
  polls until the zone id actually changes, tolerating the connection drops
  generation causes.
- **Warping mutates the golden save.** Qud autosaves on zone change, so the save
  the entire rig's determinism rests on ends up wherever you warped last.
  Restore it after station runs, Qud down:
  `python tools/capture/saves.py restore checker`.

## The determinism budget (honestly)

Zones are procedurally generated, but the golden save pins the seed. What still
moves between captures: creature positions (masked in 6b; pacify helps),
daylight (pinned bright as today), liquid animation (ANIM-banded), weather. What
does **not** move: ground paint, walls and their autotiling, furniture, zone
background, terrain.

The stable set is precisely the untested set. That is the argument for doing this.

## Station list (first pass, golden save world)

| Station | Zone | What it exercises |
|---|---|---|
| Joppa surface | `JoppaWorld.11.22.1.1.10` | grass/dirt paint, huts, brinestalk walls |
| Joppa hut interior | (adjacent) | **wall joinery at room scale** — the autotile payoff |
| Salt desert | west of Joppa | uniform paint, dune variety |
| Cave / underground | any `z > 10` | dark lighting, point sources, ghost cells, rock autotiling |
| River / water | Joppa river | liquid depth, bridges, submerged sprites |
| Ruin (Golgotha et al.) | warp | mixed walls, rubble, structural density |
| Remembered neighbour | walk one zone east, look back | frozen strata, offsets |
| World map | `z < 0` | see below |

## The world map — add it to the tree

Three gaps with one root: the world map is a distinct *screen* that nothing
treats as one.

- **Not in `gametree.json`.** `in_game` carried a `world` node but no
  `world_map`. **Added** (`highvisor/gametree.json`, after `world`), so the
  coverage is visible in the cockpit and `hv goto` / `hv assert` have a node to
  target. `done.raves` seeded at 0.4 — implementation exists, verification does
  not; adjust once measured.
- **Not a reported scene.** `UiState` reported `in_game` for both a zone and the
  parasang overview, so the rig could not tell them apart — the same class of
  bug as the menu drift that poisoned a certification band, since the clear
  guard would happily pixel-score a world map against a zone. **Added**
  (`UiState.note_world_map()`, driven from `Main._on_snapshot`). It only flips
  between `in_game` and `world_map`, so status screens and popups still own the
  report while they are up.
- **The detection rule was dead code — found while trying to verify the flip.**
  `ZoneRenderer._world_map` tested `zone.z < 0`. Qud's `ZoneRequest` assigns
  world zones **`Z = 10`** — identical to the surface — in *both* of its
  world-zone branches, alongside `WorldX = WorldY = X = Y = -1`. So `z < 0`
  never fires, and **the entire world-map render mode has never run**: standing
  cards (`WM_STANDING_CARDS`), flat-and-lit, no-torch-glow. Corrected to Qud's
  own `IsWorldMap()` definition — *a ZoneID with no dot* (`JoppaWorld` vs
  `JoppaWorld.11.22.1.1.10`) — off `zone.id`, which the wire already ships. No
  mod change or protocol bump needed. Both `_world_map` and the scene report now
  use it.
  **Status: false-case verified** (a zone still reports `in_game`, no script
  errors). **True-case NOT verified** — I could not reach the world map:
  `wish goto:JoppaWorld` silently no-ops, the climb-up key does nothing on the
  surface, and Qud's `Commands.xml` has no world-map command. Getting there is
  an open question and step 1 below; it may be a legacy screen, which would
  itself change this rung's priority.
- **Its art path is untested end to end**: `worldTerrain` tiles (on the wire
  today: `Terrain/sw_joppa.bmp` + colour/detail), landmarks (Spindle, Red Rock —
  `_landmarks_root`, `LANDMARKS_ENABLED`), standing world-map cards
  (`WM_STANDING_CARDS`), the "you are here" player card with its no-depth-test
  override, and parasang-scale layout.

Once it is a distinct scene, the world map is testable exactly like a zone:
warp, census, masked congruence.

## Sequencing

1. **Find a way to reach the world map at all**, then verify the flip's
   true-case. Open question — see above; three approaches failed. Worth asking
   the Mac side, who built the world-map render path, how they got to it.
2. **6a structural census** — cheapest, loudest defect class, immune to the rig
   failure modes.
3. **6c station list + warp driver** — `goto` recipes per station.
4. **6b masked whole-playfield congruence** — most expensive; last, and only on
   stations already proven by 6a.

Rung 5's category-split fix (weapons/items) folds in wherever convenient — it is
a small shared-file change and needs Mac coordination.

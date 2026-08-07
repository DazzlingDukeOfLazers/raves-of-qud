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
that plagued certification**. Do this first; it is likely seconds per zone.

### 6b. Whole-playfield congruence — pixels, masked

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

`wish goto:<zoneID>` (verified in Workstream B) against the golden save's fixed
world seed. Because the seed is fixed, a zone ID composes identically on every
load — the same determinism trick that made Rung 2 work, applied at zone scale.

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

# World model & roadmap

Strategy for six forward-looking asks (fog of war, remembering visited zones, memory
freeze/unfreeze, Z-height, cross-zone distance, and a future Minecraft-style editing fork).
The insight that shaped it: all six are the *same* architectural change wearing six hats — a
persistent, chunked, block-first world store that the live snapshot merely writes into.

> **Status (2026-07-28): Phase 0 shipped; Phase 1 partially shipped.**
> Raves no longer renders the wire directly — it ingests each snapshot into a persistent
> [`WorldStore`](../godot/WorldStore.gd), keys saved zones by the mod's `gameId`, records structured
> zone coordinates, persists explored zones to disk, and renders remembered neighbours (dimmed,
> static-only). New-game isolation and disk round-trip are covered by
> [`tests/test_persist.gd`](../godot/tests/test_persist.gd).
>
> - **Now:** UI / visual-parity work (menu screens — Records is next — then in-world parity), plus
>   Phase 1 hardening. The store spine is in; this rides on top of it.
> - **Next:** finish Phase 1 — render-radius policy, LRU eviction under a memory budget, grow the
>   ground plane, and Tier-0 biome fog plates. See [acceptance criteria](#phase-1-acceptance-criteria).
> - **Later:** Phase 2 (stacked strata / caves) and Phase 3 (the editing fork) — still proposals.
>
> The design rationale below is unchanged and still governs; only the "what exists yet" framing has
> been corrected. A dated build log lives in the [progress appendix](#build-log-2026-07-24).

---

## The one change that unlocks all six

The original model rendered **the live snapshot** directly: Qud sent the current zone every turn, we
built meshes from it, and it was replaced next turn — nothing persisted, nothing but the active zone
existed. Every one of the six asks died on that model.

**The pivot (now shipped for one axis of it):** stop rendering the wire. The live snapshot is just
*one writer* into a persistent, chunked, block-first world store; the renderer reads the store. This
is in place today for per-zone persistence and remembered neighbours; the chunk-lifecycle and
block-column parts below are the remaining build-out.

```
  OLD:      wire ──► build meshes ──► screen         (one zone, ephemeral — replaced)

  CURRENT:  wire ──► WorldStore ──► renderer          (many zones; explored zones persist to disk,
                        │                               keyed by gameId; neighbours render dimmed)
                        ▼
                   disk (per-zone JSON, keyed by gameId)

  NEXT:     …  ◄── player edits  (fork only, Phase 3);  chunk load/evict lifecycle + block columns
```

Once the store exists, each ask is a small feature on top of it — not its own subsystem:

| ask | becomes… |
|---|---|
| 1. Fog of unvisited zones | a chunk that isn't in the store yet |
| 2. Display visited zones | render stored chunks, dimmed, static-only |
| 3. Freeze/unfreeze memory | chunk lifecycle: hot → warm → cold → evicted-to-disk |
| 4. Z-height / levels | strata are chunks stacked on the global Z axis |
| 5. Cross-zone distance | subtract two global coords (derived from the zone id) |
| 6. Block editing fork | edits mutate the same store the snapshot writes |

**If we build nothing else first, build the store and make the renderer read from it** (even for a
single zone, changing nothing visible). That de-risks everything after.

---

## Core types

- **GlobalCoord** `(gx, gy, gz)` — integer world cell coordinate, derived from the Qud zone id
  (see [Global coordinates](#global-coordinates)). The spine for placement, stacking, and
  distance.
- **Chunk** — one zone × one stratum (80×25 cells at a given Z). The unit of persistence, loading,
  and eviction. Keyed by `(world/seed, parasangX, parasangY, zoneX, zoneY, stratum)`.
- **Column / Block** — a cell is **not a flat tile**; it's a short vertical stack of blocks, each
  `{ material, shape, state, provenance }`. Even the Qud viewer should translate a wall into a
  block-of-material (rusted-metal) as the snapshot lands, and render from *that*. This is the single
  most important forward-looking decision — it's what makes ask 6 (editing) and ask 4 (Z relief,
  recessed water) natural instead of bolted on.
- **provenance** ∈ `{ SIM, REMEMBERED, PLAYER }` — where a block came from. **Decided: Qud is the
  source of truth, always synced → SIM is authoritative and overwrites REMEMBERED.** So Phases 0–2
  only ever use SIM/REMEMBERED and need **no merge logic** — the store just mirrors Qud. `PLAYER`
  and precedence rules stay unbuilt until the fork (Phase 3); keep the enum slot so the format
  doesn't churn later.
- **Keying by game seed** — the store must carry Qud's game/seed/world id so a *new game* or a
  regenerated world doesn't render a stale mirror. **✓ Shipped:** the snapshot carries `gameId`
  (`The.Game.GameID`) and `WorldStore` namespaces every zone file under it (see
  `WorldStore._resolve_dir`); cross-game isolation is asserted in `test_persist.gd`. Critically, this
  is *our* mirror on disk — we never write into Qud's saves.

---

## Global coordinates

**Confirmed by reflection (2026-07-24, Assembly-CSharp `XRL.World.Zone`):** the zone id
`JoppaWorld.11.22.1.1.10` decomposes as `world.wX.wY.X.Y.Z`, where `Zone` exposes these as **direct
int fields** — `wX, wY` (parasang), `X, Y` (zone within the 3×3 parasang), `Z` (stratum) — plus
`Width, Height`. Our sample: parasang (11,22), zone (1,1), stratum 10. Zone dims `80×25`.

**✓ Shipped:** the mod emits `wx/wy/zx/zy/z` structured off `The.ActiveZone` in the `zone` block (no
string parsing), and `World.gd` derives global coordinates from them. Then:

```
gx = (wX * 3 + X) * 80 + cellX          # (wX*3+X) is the global zone column
gy = (wY * 3 + Y) * 25 + cellY          # (wY*3+Y) is the global zone row
gz = Z                                  # raw stratum; distance uses the DIFFERENCE, so the
                                        # surface baseline/sign doesn't matter for ask 5.
```

Cross-checks Qud provides (use to validate, don't reimplement blindly): `Zone.XYToID(world, xp, yp,
z)` builds an id from global zone indices `xp=wX*3+X, yp=wY*3+Y`; `Zone.zoneIDTo240x72Location(id)`
returns the global zone location (240 = 80 parasangs × 3 zones wide; 72 = 24 × 3 tall).

**Bonus found in the same probe (for asks 1–2):** `Zone` carries `ExploredMap`, `VisibilityMap`,
and `FakeUnexploredMap` — per-cell explored/visible bits Qud already maintains. The mod can send
these so fog of war and remembered-vs-live use Qud's own bookkeeping instead of our own tracking.

- **Vector** between two cells = `(gx2-gx1, gy2-gy1, gz2-gz1)`.
- **Distance** — pick per use: Chebyshev/manhattan for gameplay ("3 parasangs NE, 2 strata down"),
  or weighted Euclidean if we ever want a true metric (weight gz by the world-Y we give a stratum).
- **Edge cases:** only defined within one `world` root — cross-world (pocket dimensions, other named
  worlds) has no shared metric; guard on equal world id. World does not wrap.
- **✓ Shipped:** `globalCoord(zoneId, x, y)` lives in `godot/World.gd` (used by `WorldStore` as
  `WorldMath`); the parasang-vs-zone field order and stratum baseline were confirmed against Qud's
  live `ZoneID` before wiring the math.

This function also *places zones in the 3D scene* (asks 2 & 4), so it's foundational, not just a
utility.

---

## Chunk lifecycle: freeze / unfreeze

Each chunk moves through states by distance from the player:

| state | in RAM? | meshed? | when |
|---|---|---|---|
| **LIVE** | yes | yes, full detail, actors | the active zone |
| **WARM** | yes | yes, dimmed, static-only | within render radius R (neighbors, adjacent strata) |
| **COLD** | yes (records) | no (meshes freed) | seen recently, out of render radius |
| **EVICTED** | no (on disk) | no | beyond memory budget (LRU by last-visited turn / distance) |

- **Godot side:** freeing a chunk = `queue_free` its per-cell MeshInstances and drop them; **keep the
  shared caches** (`_voxel_cache`, recolored textures — keyed by tile+colours, not by zone), so
  re-entry rebuilds meshes cheaply. Freeze is mostly about per-cell instances, not the atlases.
- **Mod side:** never hold Unity/Qud objects for distant zones — Qud's own `ZoneManager` already
  suspends them. The mod streams the active zone and can *serve stored chunks on request*, but must
  not pin them.
- **Budgets:** cap meshed chunks (≈9–25) and RAM records (a few hundred → spill to disk). Consider
  `MultiMesh` per (variant, mesh, rotation) if instance counts hitch at radius.

---

## Fog of war + remembered zones

Two tiers, both falling out of "is the chunk in the store?":

- **Tier 0 — never visited:** no chunk. Render a low-detail **biome plate** at the zone footprint —
  a flat, dark, desaturated plane tinted by the overworld terrain, if we can read it (**mod should
  expose the overworld/world-map cell** biome + colour per parasang; otherwise fall back to plain
  fog). This is the classic "unexplored" haze.
- **Tier 1 — visited, not current:** render the stored chunk **dimmed and static-only** — walls,
  floors, furniture, remembered features; **no creatures** (decided). Tag mobile objects via
  `IsCreature` and skip them in any remembered chunk. This is "explored but not in view."
- **LIVE — within the actor radius:** full detail + creatures + dynamic light. The radius is a ring
  of chunks, but since **Qud only simulates the active zone**, radius 0 (the current zone) is what
  we have creature data for by default; a wider live ring needs the mod to read actors from adjacent
  resident zones each turn. Everything outside the ring falls to Tier 1 (static, no creatures).

Reveal = the moment a chunk transitions Tier 0 → stored (first visit). Remembered chunks refresh
their static layer each time you re-enter.

Requires the render to build from the **store**, not the wire, and the store to distinguish
static vs mobile and live vs remembered — so this is really the same work as the pivot + ask 3.

---

## Z-height, levels, recessed water

- **Strata = chunks stacked on gz.** A multi-level place (a tower, a cave complex) is several
  chunks sharing `(parasang, zone)` at different strata. Place each stratum's slab at world-Y =
  `f(gz)` (a fixed slab height per level). Show the current stratum solid; render adjacent strata
  above/below as **cutaway or translucent** so you can see the vertical structure without clutter.
- **Vertical connections:** stairs/shafts (`<`/`>`, `StairsUp`/`StairsDown`). **Mod should expose
  z-transition objects and their targets** so the client can punch a visual shaft between slabs and
  (later) let you travel/look down it.
- **Recessed water & per-cell relief:** give every cell a **floor-height offset** in the block
  column. Liquids render their surface slightly *below* the floor plane (a shallow inset); actors in
  wading/swimming depth already recess. Generalizing floor height to the column is the same
  primitive that block-editing (ask 6) needs — do it once.
- This is the strongest reason the cell must be a **column**, not a flat tile: levels, shafts, and
  water depth are all Z within a cell.

---

## Block editing fork

The fork (Minecraft-style place/remove, *after* the viewer is done) is why the store is
**block-first from day one**, even though the viewer is read-only:

- The renderer already reads a block/column model; Qud snapshots *populate* it (wall → block of
  material `rusted-metal`), player edits *mutate* it. Same store, same renderer.
- **The tension to resolve at Phase 3:** the viewer decision is *"always synced, Qud is truth."*
  Free-form block editing pulls the other way — if Qud keeps overwriting, edits can't persist. Two
  ways to keep faith with "Qud is truth":
  1. **Round-trip edits through Qud** — placing/removing a block issues the real Qud mutation
     (dig/build a wall, place an object) and the sim reflects it back. Stays perfectly synced, one
     truth, no merge logic — but edits are limited to what Qud can represent (Qud's materials and
     objects), so it's a *Qud builder*, not an arbitrary voxel sandbox.
  2. **Detach at fork time** — seed the fork's store from a Qud snapshot, then stop syncing; PLAYER
     becomes authoritative and edits are unbounded. This is a true Minecraft-style fork but abandons
     Qud-as-truth for that build.
  These aren't mutually exclusive across builds: the **viewer** stays option-0 (pure mirror), and
  the **fork** picks (1) or (2) later. Nothing before Phase 3 depends on the choice — which is the
  point of keeping the store block-first now.
- **Storage format:** chunked like Minecraft region files — palette-compressed block arrays per
  chunk, one file per `(seed, parasang, zone, stratum)`. JSON to start (debuggable), binary/palette
  later. This *same* format serves persistence (ask 2), eviction (ask 3), strata (ask 4), and fog
  (ask 1 = absent file).

---

## Wire fields — status

Each is additive to the snapshot. Exact field names as emitted by `ZoneSnapshot.BuildJson` (see
[`protocol.md`](protocol.md) for the full contract).

| field(s) | for | status |
|---|---|---|
| `gameId` | namespaces the store the moment we persist | **shipped** |
| `zone.wx/wy/zx/zy/z` (structured, off `The.ActiveZone`) | global coords (ask 5) | **shipped** |
| `worldTerrain` (world-map tile + biome name) | Tier-0 fog plate identity / travel log | **shipped** (biome *colour tint* for the fog plate is not yet consumed) |
| per-object `creature` (`IsCreature`) | static-vs-mobile split; drop actors from remembered zones | **shipped** |
| object `name` (`Blueprint`) | block-model material identity (starting point) | **shipped** |
| per-cell `wade`/`swim` liquid depth | recessed water | **shipped** (a general per-cell **floor offset** for column relief is not) |
| overworld biome **colour** per parasang/zone | real biome-tinted Tier-0 fog plates | **not started** — locate the world-map/region render API by reflection |
| `Zone.ExploredMap` / `VisibilityMap` / `FakeUnexploredMap` (per-cell bits) | drive fog/remembered state from Qud's own bookkeeping | **not started** |
| adjacent-resident-zone actors | a live creature radius > the active zone | **not started** |
| z-transition objects (stairs/shafts) + target zone id | level linking (Phase 2) | **not started** |
| explicit per-block material / column model | the block-first store (Phase 3 fork) | **not started** (blueprint name is the stopgap) |

---

## Phased roadmap

- **Phase 0 — the pivot (de-risk, invisible): ✅ shipped.** GlobalCoord (`World.gd`) + a persistent
  per-zone store keyed by `gameId` (`WorldStore.gd`); renderer reads the store instead of the wire.
  Nothing changed on screen. Distance (ask 5) is free here.
- **Phase 1 — neighbours & memory: 🟡 partially shipped.** Done: remembered-neighbour rendering
  (dimmed, static-only, ask 2), depth-fog dimming, on-disk persistence, the static/dynamic freeze.
  Remaining: hot/warm/cold/**evicted lifecycle + LRU under a memory budget** (ask 3), a configurable
  **render radius**, growing the ground plane, and **Tier-0 biome fog plates** (ask 1). See the
  [acceptance criteria](#phase-1-acceptance-criteria).
- **Phase 2 — the third dimension: ⬜ proposal.** Strata stacking + cutaway/translucent levels;
  z-transitions; per-cell floor offset + recessed water (ask 4).
- **Phase 3 — the fork: ⬜ proposal.** Block-column editing on the store the viewer already uses
  (ask 6). The store is block-first by design, so this is features, not a rewrite.

### Phase 1 acceptance criteria

Phase 1 is **complete** when the store can:
1. load and render neighbours out to a **configurable render radius** (not just the immediate ring);
2. **evict** cold records to disk under a defined memory budget (LRU by last-visited tick — the
   `_tick` counter already exists as the ordering key);
3. survive a scene reload / Qud restart with the explored world intact — **✓ already covered** by
   `test_persist.gd`;
4. prove **new-game isolation** in an automated test — **✓ already covered** by `test_persist.gd`;
5. render **Tier-0 biome plates** for never-visited zones using real overworld biome colour.

(3) and (4) are done; (1), (2), and (5) are the remaining work.

---

## Open questions for Daniel

**Decided (2026-07-24):**

- **Remembered actors → HIDE creatures** in explored zones. Nuance from Daniel: the live-vs-
  remembered boundary is a **radius of chunks**, not just the single active zone — creatures show
  within a live radius and are hidden beyond it. Practical constraint: **Qud only fully simulates
  the active zone**, so today we only have fresh creature data for radius 0. To show creatures in a
  ring around the player, the mod must also read actors from adjacent *loaded* zones each turn
  (Qud's `ZoneManager` keeps a few resident); otherwise the live radius is effectively the current
  zone and everything else is static-only. Either way: **no creatures in remembered chunks.**
- **Tier-0 fog → READ Qud's overworld map for biome tint.** The mod exposes the overworld/world-map
  terrain + colour per parasang so unvisited zones get a real biome-coloured haze plate, not generic
  fog. (Find the API by reflection — likely the `JoppaWorld` overworld zone / world-map cell's
  region+render; verify, don't grep.)
- **Sync model → ALWAYS SYNCED, Qud is the source of truth.** SIM is authoritative; the store is a
  mirror of Qud. **This defers all provenance/merge logic** (PLAYER-wins precedence) out of Phases
  0–2 — a real simplification: the store just records what Qud last said, SIM overwrites REMEMBERED,
  done. See the [fork note](#block-editing-fork) for how this choice reshapes Phase 3.

**Still open (not blocking Phase 0; defaults noted):**

1. **Persistence scope:** whole world forever, or an LRU of the last N zones? *Default: LRU of a few
   hundred zones, spill to disk — revisit if it's ever a problem.*
2. **Z presentation:** cutaway (current stratum + a peek), translucent stack, or explicit
   exploded/elevator view? *Default: cutaway, decide from a screenshot in Phase 2.*
3. **Distance semantics:** component vector + parasang/stratum deltas ("3 parasangs NE, 2 down"), or
   a single weighted scalar? *Default: expose the vector + deltas; add a scalar only if a feature needs it.*

---

## Parked (post-MVP polish)

Deliberately deferred until the MVP is together — hardcoded sensible defaults for now.

- **User-facing sliders** for the render/atmosphere tunables: fog begin/end/curve (currently
  `Main` constants), and likely ambient/sun energy, `SIDE_CARVE`/`CAP_CARVE`, day-length. An
  in-viewer settings panel so Daniel dials the look live instead of editing constants + reloading.

---

# Historical decisions & progress log

Below is the dated record that shaped the plan above. The **canonical current status is the top
status block** — this section is history, not a second source of truth.

## MVP definition (Daniel, 2026-07-24)

**MVP = a reviewable tool for feedback.** Concretely:
- More passes at **sprite → voxel** creation and **categorization** (extend beyond walls).
- **Walking about to find escapes** — exploration that surfaces rendering edge cases / gaps.
- **Caves (subterranean)** — Z-strata / vertical (Phase 2).
- **Navigating the main map** — overworld / parasang travel.
- **Hardening Phase 1** (radius/eviction, ground plane, robustness).
- **Timestamps to Pareto the longest delays** — the profiler (F9 → profile.txt).

## Build log (2026-07-24)

Phase 0 done (global coords + store). Phase 1 landed: remembered-neighbour rendering (full
fidelity, frozen), **depth-fog dimming**, **on-disk persistence** keyed by `gameId`, the **profiler**,
and the **static/dynamic freeze** (per-step render ~85ms → a few ms). Also that session:
- **Camera**: modes + `` ` `` debug menu (compass default = the disorientation fix; first-person,
  cinematic-v1, orbit, fly); seamless zone crossings. See docs/tools.md "Camera modes".
- **Remote control loop**: `control.py` drives Qud (move) + Godot (cam/shot via godot_cmd);
  works while **Qud is focused** (not fully unattended — Qud pauses input/render unfocused). See
  docs/tools.md "Remote control".

Deferred camera work (unchanged): Follow smoothing, Godot→Qud control-translation (up = forward at
any heading; FP rotate-vs-strafe). Cinematic v2 (combat event buffer) waits on the mod sending
combat events.

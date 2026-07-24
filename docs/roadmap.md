# World model & roadmap

Strategy for six forward-looking asks (fog of war, remembering visited zones, memory
freeze/unfreeze, Z-height, cross-zone distance, and a future Minecraft-style editing fork).
**No code yet — this is the plan.** The point of writing it down: all six are the *same*
architectural change wearing six hats.

---

## The one change that unlocks all six

Today the client renders **the live snapshot**: Qud sends the current zone every turn, we build
meshes from it, and it's replaced next turn. Nothing persists, nothing but the active zone exists,
and the geometry is derived straight off Qud's tile art. Every one of the six asks dies on that
model.

**The pivot:** stop rendering the wire. Maintain a **persistent, chunked, block-first world store**;
the live snapshot becomes just *one writer* into it. The renderer becomes a pure function of the
store.

```
  NOW:   wire ──► build meshes ──► screen        (one zone, ephemeral)

  TARGET: wire ──► WorldStore ◄── player edits    (many zones, persistent, block-first)
                      │                                    ▲ (fork only)
                      ▼
                  renderer (pure fn of store, per chunk, with load/evict lifecycle)
                      │
                   disk (chunk files, keyed by game seed)
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
  (see [Global coordinates](#global-coordinates--ask-5)). The spine for placement, stacking, and
  distance.
- **Chunk** — one zone × one stratum (80×25 cells at a given Z). The unit of persistence, loading,
  and eviction. Keyed by `(world/seed, parasangX, parasangY, zoneX, zoneY, stratum)`.
- **Column / Block** — a cell is **not a flat tile**; it's a short vertical stack of blocks, each
  `{ material, shape, state, provenance }`. Even the Qud viewer should translate a wall into a
  block-of-material (rusted-metal) as the snapshot lands, and render from *that*. This is the single
  most important forward-looking decision — it's what makes ask 6 (editing) and ask 4 (Z relief,
  recessed water) natural instead of bolted on.
- **provenance** ∈ `{ SIM, REMEMBERED, PLAYER }` — where a block came from. In the viewer SIM wins;
  in the fork PLAYER edits win. Lets one store serve both builds.
- **Keying by game seed** — the store must carry Qud's game/seed/world id so a *new game* or a
  regenerated world doesn't render a stale mirror. **Add a `gameId` to the wire** and namespace all
  chunk files under it. Critically, this is *our* mirror on disk — we never write into Qud's saves.

---

## Global coordinates  (ask 5)

Qud zone ids look like `JoppaWorld.11.22.1.1.10` = `world.parasangX.parasangY.zoneX.zoneY.stratum`,
zone dims `80×25`, parasang = `3×3` zones. So:

```
gx = (parasangX * 3 + zoneX) * 80 + cellX
gy = (parasangY * 3 + zoneY) * 25 + cellY
gz = stratum                      # 10 = surface; larger = deeper, smaller = higher (CONFIRM sign)
```

- **Vector** between two cells = `(gx2-gx1, gy2-gy1, gz2-gz1)`.
- **Distance** — pick per use: Chebyshev/manhattan for gameplay ("3 parasangs NE, 2 strata down"),
  or weighted Euclidean if we ever want a true metric (weight gz by the world-Y we give a stratum).
- **Edge cases:** only defined within one `world` root — cross-world (pocket dimensions, other named
  worlds) has no shared metric; guard on equal world id. World does not wrap.
- **Action:** implement `globalCoord(zoneId, x, y)` **once**, mirrored in C# and GDScript (same
  discipline as `tile_family`). **Confirm the parasang-vs-zone field order and the stratum baseline
  against Qud's `ZoneID` in the mod** before trusting the math — verify a value, don't trust the
  field name.

This function also *places zones in the 3D scene* (asks 2 & 4), so it's foundational, not just a
utility.

---

## Chunk lifecycle: freeze / unfreeze  (ask 3)

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

## Fog of war (ask 1) + remembered zones (ask 2)

Two tiers, both falling out of "is the chunk in the store?":

- **Tier 0 — never visited:** no chunk. Render a low-detail **biome plate** at the zone footprint —
  a flat, dark, desaturated plane tinted by the overworld terrain, if we can read it (**mod should
  expose the overworld/world-map cell** biome + colour per parasang; otherwise fall back to plain
  fog). This is the classic "unexplored" haze.
- **Tier 1 — visited, not current:** render the stored chunk **dimmed and static-only** — walls,
  floors, furniture, remembered features; **no creatures** (they've moved — tag mobile objects via
  `IsCreature` and skip them in remembered chunks). This is "explored but not in view."
- **LIVE** current zone: full detail + actors + dynamic light, as now.

Reveal = the moment a chunk transitions Tier 0 → stored (first visit). Remembered chunks refresh
their static layer each time you re-enter.

Requires the render to build from the **store**, not the wire, and the store to distinguish
static vs mobile and live vs remembered — so this is really the same work as the pivot + ask 3.

---

## Z-height, levels, recessed water  (ask 4)

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

## Block editing fork  (ask 6)

The fork (Minecraft-style place/remove, *after* the viewer is done) is why the store is
**block-first from day one**, even though the viewer is read-only:

- The renderer already reads a block/column model; Qud snapshots *populate* it (wall → block of
  material `rusted-metal`), player edits *mutate* it. Same store, same renderer.
- **Provenance decides precedence:** viewer = SIM overwrites; fork = PLAYER edits are sticky and
  win over SIM (or the fork detaches from the sim entirely after seeding). Decide the divergence
  model (seed-then-standalone vs always-synced-with-player-overrides) — it drives whether we need
  merge logic.
- **Storage format:** chunked like Minecraft region files — palette-compressed block arrays per
  chunk, one file per `(seed, parasang, zone, stratum)`. JSON to start (debuggable), binary/palette
  later. This *same* format serves persistence (ask 2), eviction (ask 3), strata (ask 4), and fog
  (ask 1 = absent file).

---

## New wire fields the mod should add (incremental)

Ordered by when they're needed. Each is additive to the snapshot.

1. `gameId` / world seed — namespaces the store (needed the moment we persist).
2. Parsed zone components confirmed against Qud `ZoneID` (parasang, zone, stratum) — for global coords.
3. Overworld biome + colour per parasang/zone — for Tier-0 fog plates.
4. Per-object `static` vs `mobile` is mostly derivable (`IsCreature`), but confirm furniture/items.
5. Z-transition objects (stairs/shafts) + target zone id — for level linking.
6. Per-cell floor offset / liquid depth beyond `wade`/`swim` — for recessed water and column relief.
7. Material identity per wall/block (blueprint name is already sent) — for the block model.

---

## Phased roadmap

- **Phase 0 — the pivot (de-risk, invisible):** GlobalCoord + a persistent per-zone store keyed by
  `gameId`; renderer reads the store instead of the wire, for the single live zone. Nothing changes
  on screen. Ships the spine. *Distance (ask 5) is free here.*
- **Phase 1 — neighbours & memory:** stream stored neighbour chunks; remembered rendering (dimmed,
  static-only, ask 2); Tier-0 fog plates (ask 1); hot/warm/cold/evicted lifecycle + LRU (ask 3).
  One subsystem, three asks.
- **Phase 2 — the third dimension:** strata stacking + cutaway/translucent levels; z-transitions;
  per-cell floor offset + recessed water (ask 4).
- **Phase 3 — the fork:** block-column editing on the store the viewer already uses (ask 6).
  The store was block-first from Phase 0, so this is features, not a rewrite.

---

## Open questions for Daniel (decide before Phase 1)

1. **Persistence scope:** remember the whole world forever, or an LRU of the last N zones?
2. **Remembered actors:** hide creatures entirely in explored zones (recommended), or show them as
   faded "last-seen" ghosts?
3. **Tier-0 fog:** can we read Qud's overworld map for biome tint, or is plain fog fine to start?
4. **Z presentation:** cutaway (current stratum + a peek), translucent stack, or an explicit
   "elevator"/exploded view?
5. **Fork divergence:** seed-from-a-snapshot-then-standalone, or always-synced with player edits
   winning? (Drives whether we need merge/provenance logic or can keep it simple.)
6. **Distance semantics:** is a component vector + parasang/stratum deltas enough ("3 parasangs NE,
   2 down"), or do we need a single weighted scalar metric?

---

## Smallest first step

`globalCoord(zoneId, x, y)` in the mod + a headless print of two cells' vector — one afternoon,
zero render risk, and it forces us to confirm the zone-id field order (ask 5) that everything else
stacks on. From there, Phase 0's store is the real spine.

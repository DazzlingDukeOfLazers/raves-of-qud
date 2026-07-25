# Deep-water depth — plan (branch `dd/mac-waterdeep`)

Goal: let you see a **submerged creature through the water**, keeping it a normal upright
billboard, without the failures of the earlier "make the water tile transparent" attempt
(see [rendering.md](rendering.md) §6a/§6b for why that couldn't work).

## The model — a shallow prism per deep-water tile

Replace the flat deep-water quad (near the player) with a **rectangular prism the shape of
the tile**:

- **Top face** = the current water texture, at a **raised** surface height (`FLOOR_Y + depth`).
  Rendered **semi-transparent** so a creature standing inside reads through it.
- **Side + bottom faces** = nothing (omitted). Open, so the tilted camera sees *into* the
  basin from the near side.
- The prism sits **above the ground plane**: its floor is at `FLOOR_Y` (where the creature
  stands), its top at `FLOOR_Y + depth`. Nothing is drawn below `y ≈ -0.02`, so the world's
  opaque ground plane never occludes it. This is the key trick — we raise the surface up over
  the actor instead of digging the actor down under the surface.

The submerged creature is drawn **uncropped, standing on `FLOOR_Y`**: its lower `depth` is
inside the prism (below the translucent top → reads as underwater), its top pokes out clear.

`depth` is the existing **`deep_water_depth`** slider (0–1 tile), so it's live-tunable.

## Scope — only near the player (perf + realism)

Deep-water prisms are **not** built for the whole zone. A flat quad is fine — and cheaper —
everywhere you can't see into the water anyway:

- Only deep-water cells within a **square radius `R`** of the player are candidates.
- A candidate becomes a prism only when there's a **submerged creature within the reveal
  radius**; otherwise it stays the normal flat opaque quad.
- Far water stays flat — at that shallow a viewing angle you couldn't see in regardless
  ("that's like real life"). This also bounds the cost to a handful of tiles.

Because the set depends on the **player position**, these prisms can't live in the frozen
static zone; they're rebuilt in a bounded per-step pass (like creatures), capped by `R`.

## Open decisions (to confirm before building)

1. **Which cells become prisms** — just the creature's own cell, or a small patch of deep
   water around each submerged creature? A lone raised tile amid flat water may read as an odd
   box; a small patch blends better. *Proposed: a small patch (e.g. the creature's cell + its
   deep-water neighbours within reveal radius 1–2).*
2. **Top opacity** — how see-through the raised surface is. *Proposed: reuse
   `WATER_REVEAL`-style ~0.5 alpha; tune by screenshot.*
3. **Radius `R`** — how far from the player we bother. *Proposed: ~6 tiles.*
4. **Boundary lip** — near-field surface is raised by `depth`, far-field is flat, so there's a
   small step at the radius edge. *Proposed: accept it (depth is small; far water is dim/steep).*

## Verification

Screenshot a submerged glowfish/glowpad at `deep_water_depth` = 0.3 / 0.6 / 0.9, day and
night, and check: creature reads as underwater, no ground-plane clipping, the near-field
boundary is acceptable, and the perf cost (profiler) stays flat.

# Readability stack, prototype — 2026-08-12

Brief: "The main problem is not missing detail. It is missing hierarchy." Three changes, by
semantic role, 3D-upright user mode only:

1. **Semantic depth ordering** — `_role()` (scenery / furniture / item / creature / player) from
   wire data; dynamics (creatures, player) pulled a few cm toward the camera (`ROLE_PULL`), fresh
   per dynamic rebuild. Statics stay put; the conflicts that matter are dynamic-over-static.
2. **Selective keylines** — baked two-tone contour at 3x in the recolour pipeline (`_bake_keyline`),
   1/3-texel thin. Strength = TONE, not alpha (ALPHA_CUT_DISCARD makes alpha a mask). Creatures &
   player: near-black + pale two-tone; items: charcoal; furniture: soft charcoal-teal; scenery,
   walls: none. Baked rather than duplicate nodes because the sprites depth-write: an outline quad
   z-fights its parent or swaps in front when the camera crosses the sprite plane.
3. **Contact shadows** — hard-edged low-res ellipse under standing sprites, width from the art's
   opaque band (`_opaque_h`) x role factor, under the darkness overlay so it dims with the cell.
   Skipped: underwater, floated, stair shafts, in-wall, world map.

Mod: `takeable` (Physics.Takeable) now on the wire — the chest/dagger split flags could not make.
Build tag `2026-08-12 takeable`.

## Verified (inspector = the renderer's own placement report)

| check | evidence |
|---|---|
| keyline bakes | billboard notes read 48/50/64px (= 3x source) |
| shadow places, role-correct | `shadow(role=4 w=0.32 a=0.32)` player; `role=2 w=0.18` pre-takeable chest |
| chest was misroled | fixture-caught: ITEM on flags alone -> `takeable` export + role split |
| 1:1 untouched | fresh 1:1 inspect: `RENDERED floor` only, no shadow/billboard/keyline; new build tag |
| SPOT | 6/6 |

**Baseline traps hit and recorded:** a pixel diff against camA read 100% "regression" — the solo
app was actually sitting on CHARGEN (a silently failed goto), and the first "1:1 leak" was a
stale selection.txt whose old build tag gave it away. Verify the screen and the build tag before
reading any report.

## Not yet verified / known approximations

- **Same-cell creature-over-furniture win** — the pull is live but unstaged. Fixture recipe:
  wish-spawn `Chest` + a tan creature (`snapjaw scavenger`) same cell against a tan wall; a dark
  object on a dark wall; several angles (compass rotations, follow low pitch) and 2 window sizes.
  Assert: creature silhouette >= threshold visible; boundaries keep local value contrast.
- **Tree classifies FURNITURE** (layer>=5, non-takeable). Output is adjacent to intent (weakest
  keyline + shadow ≈ "plants: weak or none") — a `plant` wire flag is the honest fix.
- **Pull staleness**: camera rotation between turns leaves the pull one turn stale (worst case =
  the old z-fight until the next step).
- **Pale keyline unmeasured** on-glass; wet-cell shadow attenuation untuned.
- Stages 4–6 of the brief (architecture subordination, light rim, interaction emphasis) not started.

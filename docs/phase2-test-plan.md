# Phase 2 — Definition of Work: the distributable test-game

*Drafted 2026-08-03 (Daniel's direction, written up by Claude). Status: agreed plan, work not started
except where noted. Companion to [`goals.md`](goals.md) (V3 = per-screen 1:1 parity); this document
covers the TESTING infrastructure that must precede distribution.*

## Purpose

Phase 2 ships a distributable test build so outside people can find issues. Before that, we nail the
issue classes they will report — with deterministic tooling, not luck. Qud is an outlier in surface
area (only games like Dwarf Fortress carry more), so coverage must be systematic: enumerate, verify,
then let chaos find what enumeration missed.

## The chaos principle (the zoo lesson)

Random mobs in a zone produce chaos. Chaos is GOOD for edge-case discovery (the zoo proved it — and so
did every wandering perch and hungry dacca this week) and BAD for design and first-principles
validation. So the ladder is:

1. **One element at a time** (deterministic — the Object Checker)
2. **Curated zones** (inanimate / liquid matrices / peaceful mobs — the Proving Grounds)
3. **Chaos zones** (random spawns — edge-case discovery, LAST)

Validate each rung before climbing to the next.

## Workstream A — the Object Checker (recommended first)

A harness that loads Qud elements one at a time and verifies each — faster to build than a test
world, and it directly generates the regression suite Phase 2 needs.

- **Stage**: evolve the existing mod `ZooBuilder` ("zoo" bridge command — already paginates
  categories into the current zone) into a SINGLE-ELEMENT stage: one blueprint on a clean field,
  player adjacent (several proximity-gated effects need distance ≤ 1: ConcealedHologramMaterial's
  glitch flicker; puffers puff).
- **Enumeration**: walk ObjectBlueprints by category (walls, plants, creatures, liquids, furniture,
  items, widgets-excluded), plus a dedicated ANIMATION list — every decoded program gets a named
  fixture: gas swirl, fire layers, smear flash (per liquid), hologram clamp, concealed-hologram
  flicker, sludge blink/cycle, engulfed alternation, target blink, sparkles (per liquid family),
  Mimic camouflage, stains, mix compounds.
- **Verification, automated**: the congruence harness we already run by hand becomes the loop —
  same-turn Qud/Raves pair, per-cell mean-diff plus the strict checks that caught real bugs
  (dominant-colour-vs-wire, pure-white pixel parity). ANIMATED elements verify by the measured
  playbook: jittered-cadence bursts (never ~0.5s — phase-lock), distinct-state counts, duty-cycle
  bands vs the decompiled constants; Qud focused for anything that moves.
- **Output**: a per-element PASS/FAIL report + contact sheets under `reports/checker/`; failures
  become tickets. Re-runnable = the regression suite for every future change.
- **Done when**: a full category sweep runs unattended and reports; all decoded animation fixtures
  pass; the sweep is documented in `docs/tools.md`.

## Workstream B — the Proving Grounds (curated test world)

A loadable test save whose zones are designed, not generated — the tester warps between stations.

- **Warp rig**: the `goto:<zoneID>` wish (verified) + a station index; expose warps in the highvisor
  cockpit (a "test stations" panel) and/or a Raves debug menu. Godmode re-armed on load —
  **The.Core.IDKFA resets every Qud restart** (learned the hard way; the load flow must re-wish it).
- **Peaceful-mobs mode**: pacify spawned creatures (Brain hostility off) for design/validation
  zones. KNOWN EXCEPTIONS to hunt down and document — hostility is not the only aggression:
  Engulfing plants pull regardless (the dacca ate a non-hostile-flagged player), puffers burst on
  proximity, AoE auras, traps. The exceptions list is itself a deliverable.
- **Zone stations** (initial set):
  - *Inanimate*: walls (autotile variants), furniture, items on floors, stairs, bridges/decks.
  - *Liquid matrix*: liquid × depth (puddle / wading / swimming) × mixes (primary+secondary —
    compound colours) × occupants (native vs non-native flora, aquatic creatures, covered objects,
    stained objects). This crosses every liquid rendering rule decoded this week.
  - *Animation stations*: one per program (fires, gases, holograms, glitchwood row, sludge pool,
    an engulfing pair).
  - *Lighting*: dark zone with point sources, ghost/memory transitions, visibility edges.
  - *Chaos zone(s)*: random spawn tables — LAST, for edge-case discovery.
- **Done when**: the save loads from the picker, every station is reachable by warp, and a scripted
  smoke pass (warp → same-turn pair → diff) is green across stations.

## Workstream C — PC platform split (saves + test files)

The PC (Windows) branch works against its OWN save set and test fixtures — never the Mac's.

- Saves live per-machine already (Qud's own data dir); the convention to establish: each platform
  keeps its own anchor saves (the Mac's "meta"; the PC creates its equivalent) and its own Proving
  Grounds copy — zone IDs and warp indexes are shared (committed), the binary saves are not.
- Test fixtures split where platform-dependent: goldens/screenshots are per-platform (renderer +
  scale differ); wire-level fixtures (expected snapshot fields) are shared.
- Repo mechanics per the existing seam rules (CLAUDE.md): OS-specific tooling behind
  `tools/capture/plat.py`; PC implements `plat_win.py`; neither branch edits the other's backend.
  Committed test INDEXES (station lists, blueprint sweeps) are cross-platform by construction.
- **Done when**: the PC branch runs the Object Checker against its own saves with zero references
  to Mac paths/fixtures, and the shared indexes drive both.

## Sequencing

1. **A. Object Checker** — fastest to value; produces the regression suite.
2. **B. Proving Grounds** — built with the checker's fixtures as seed content.
3. **C. PC split** — formalised as A/B land (the conventions above keep new work split-clean from
   day one).
4. Then the Phase 2 gate proper: **startup stability** (launch/load/reconnect hardening — the
   double-instance, wrong-save-row, and checkpoint-drift classes all get fixed or fenced), then
   **menus** (per-screen 1:1 across the state tree, per `goals.md` V3).

## Issue classes already known (what testers WILL report — pre-empt them)

The week's log, distilled — each is either fixed, fenced, or needs a checker fixture:
render-time colour overrides (stains/mimic/holograms/mixes — fixed, fixture each); animation
presence/absence and duty (fixtures); winner-selection ties (engulfed — fixed); ghost/visibility
edges (fixture); wandering-creature phase lag (documented behaviour — expect reports; consider a
FAQ note in the test build); frozen-window comparisons (FAQ note); save-picker top-row roulette
(startup stability); godmode-per-boot (test-build loader must re-arm).

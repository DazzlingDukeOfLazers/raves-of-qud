# Checker finding: Chiliad Creature blueprints NRE on bare staging

**Element:** `Chiliad Creature Newly Sentient Beings` (creatures) — and intermittently the
other `Chiliad Creature *` variants (Prey, Robots) before the stage was hardened.

**Symptom:** `check` reports `stage threw: Object reference not set to an instance of an
object` — a NullReferenceException out of `Cell.AddObject`'s object-entered event chain.
Reproducible in the full creatures sweep (907/908, this is the 1); the other Chiliad
variants pass individually, so the family is borderline.

**Read:** Chiliad creatures are procedural-history elements; a bare
`GameObjectFactory.CreateObject` + `AddObject` gives them no history context to hang
their setup on. Likely needs either a seeded history in the checker's zone or a
skip-list entry (widgets-excluded style) declaring them un-stageable bare.

**Next:** decide skip-list vs. context seeding when the Proving Grounds (Workstream B)
save exists — a curated test save may carry enough world history for them to stage.

*Delete once addressed (repo ticket lifecycle).*

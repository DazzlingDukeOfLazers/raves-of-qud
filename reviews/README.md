# reviews/ — ChatGPT doc-review tickets (raves-of-qud)

The local drop zone for the [work-cycle loop](https://github.com/TheMutantFactory/highvisor)'s
documentation-review step (canonical loop: highvisor `docs/09-work-cycle.md`). ChatGPT reviews this
repo's docs and writes suggestions here as dated tickets:

    reviews/2026-07-28-docs-protocol.md

**Rules:**
- **ChatGPT writes tickets only — never edits source.** Each ticket's first line names the target doc
  path, then gives concrete, quotable notes.
- **Claude applies** the accepted changes to the source docs, then **deletes the consumed ticket**
  (ticket-like lifecycle). Claude verifies factual claims against the code before applying — a review may
  be wrong; the code is ground truth.
- **Cross-project rollups live in highvisor**, not here: `highvisor/reviews/UPDATE.{terse,verbose,consumer}.md`
  and `highvisor/reviews/CONTEXT.chatgpt.md`. An SEO keyword list, if produced for this repo, may live
  here as `reviews/seo-keywords.md`.

These are transient working artifacts, not canonical docs — the docs under `docs/`, `README.md`, and
`CLAUDE.md` are the source of truth.

# In-game feedback, and where it goes

**Status:** envelope + client changes landed 2026-08-10. Transport is designed, not built.
**Scope:** this outlives Raves. The reusable asset is the ENVELOPE, not the service.

## The thesis

Most games send you to a forum or a Discord. The player has to leave the game, reproduce the
problem, take their own screenshot, find the right channel, and describe where they were. Almost
nobody does it, and what does arrive is "the inventory screen looks wrong" with no build, no
state, and no way to tell two reports about the same thing apart.

In-game feedback attached to an ELEMENT inverts that. The player Cmd+Right-clicks the thing that
looks wrong and types a sentence. The report carries what they would otherwise have had to
assemble by hand: which screen, which element, which build, and a picture of the element already
cropped.

That is the product argument. The engineering consequence is the whole of this document: **a
report that assembles state on the player's behalf is a report that carries state the player never
consciously chose to send.** Everything below follows from taking that seriously.

## The envelope (v1)

One JSON object per report, product-agnostic in its first six fields so other software can use the
same reader, the same triage view and the same server:

```json
{
  "v": 1,
  "app": "Raves of Qud",
  "app_version": "0.2.0",
  "platform": "macOS",
  "install_id": "efd4b9d8be4252fd",
  "ts": "2026-08-11T17:41:58",

  "scene": "status_equipment",
  "element": "status_equipment · StatusScreens · filter · Food",
  "element_key": "status_equipment/MainFrame/StatusScreens/Control",
  "text": "…the player's note…",
  "shot_attached": true,
  "shot": "feedback/2026-08-11T17-41-58.png"
}
```

`v` is the schema version. **A reader meeting an envelope it does not understand keeps it, never
drops it** — the number is how it decides, and a dropped report cannot be recovered.

Everything after `ts` is per-product and may be extended freely. Raves also carries `mode`, `pos`,
`rect`, `action`, `image`, and `path`.

### `app_version` and `platform` are not optional

A report you cannot pin to an exact build is close to worthless — "it's broken" against an unknown
binary is a conversation, not a bug. **`Brand.RAVES_VERSION` is currently `0.2.0` and needs to
track the real release before this opens to anyone.**

### `element_key` — the field reports GROUP on

`path` cannot do this job and never could. Godot names anonymous nodes `@Class@<instance>` and the
counter is per-RUN. Measured across 37 local records: **95 distinct auto-names** for a handful of
real nodes, and one element reported in different sessions came back as
`.../StatusScreens/@Control@6773` and `.../StatusScreens/@Control@265`. Two users reporting the
same button produce different paths, and so does one user across two launches. Dedupe, "14 people
hit this", and per-element history all collapse on that.

(Instance numbers are not guaranteed to differ either — a relaunch may reuse one, and in one
verification pair it did. Unreliable in both directions is the problem.)

`element` cannot do it either: it embeds live text, so it drifts with game state and is exactly
where character names and world strings leak into a payload that leaves the machine.

So `element_key` is derived by two rules, in order:

1. the nearest ancestor (or the element) carrying a **`feedback_id` meta** wins — same idiom as the
   existing `feedback_skip` / `feedback_pass`. Put one on anything worth tracking by name across
   redesigns; the tree can then be rearranged underneath without breaking the key.
2. otherwise the ancestor chain with every auto-name **collapsed to its bare class**. Derived from
   tree SHAPE, so it survives relaunches, machines, and builds that do not restructure the screen.

Verified: same element, two launches, identical `element_key`.

## Consent is part of the feature

Nobody reads a JSON line before submitting. So the form states in one sentence what leaves the
machine, and the one component that can hold something unintended — the picture — is the one the
reporter can drop:

```
Sends: your note, the element you picked, and Raves of Qud 0.2.0 on macOS.
[x] …and the picture above
```

The record keeps `shot_attached` either way, so a reader can tell "declined" from "failed to
write" instead of inferring it from an absent file.

It names the KINDS of thing, not their values — a raw `element_key` is meaningless to the person
being asked to agree to it, and long enough to wrap the panel off the screen.

**Screenshots default to the ELEMENT CROP, not the window.** One real report was 76×76. Small
payload, less incidental PII, and — for this project specifically — less of Caves of Qud's
artwork, which this repo ships none of and must not start hosting.

## The client is an outbox, not a client

`feedback.jsonl` in the support dir stays the source of truth. Games run offline; a failed POST
must never lose a report. The server drains the queue; it does not receive writes directly. This
is already how the tool behaves and it should not change.

## Transport

**Not yet built.** The design constraints, in the order they bind:

| constraint | consequence |
|---|---|
| user-submitted text and images | you are HOSTING content — moderation surface, and nothing may auto-publish |
| third-party game art in screenshots | intake is private by default; promotion to a public issue is a human step, text-first |
| open endpoint, no accounts | rate limit, size cap, kill switch; `install_id` lets you drop an abuser without auth |
| offline play | retry forever from the outbox; never block the game on a POST |
| several products later | freeze the envelope, keep the service swappable |

Recommendation: the most boring managed thing you will still want to own in three years — an HTTP
POST endpoint, object storage for images, one table. Not a bespoke stack. The service is
replaceable; the envelope is the asset.

### What was rejected, and why

- **Webhook → `gh issue` on the public repo.** Publishes Qud artwork automatically, at volume —
  the exact thing two force-pushes cleaned up on 2026-08-10. Also: GitHub has no public API for
  attaching an image to an issue body, so an automated create carries the text and not the picture
  without a side channel you have to build anyway.
- **A private sidecar git repo.** Right answer for a two-person dev loop, and it was the
  recommendation until the goal became "any user". You cannot hand a stranger a git remote.
- **Nothing / keep reading the file.** Correct while the only reporters are the two of us.

## Triage is the bottleneck

At any volume the constraint is reading, not transport. Design the read side — a list someone will
actually open, grouped by `element_key`, sorted by count — before the ingest gets clever. Reports
that become work get promoted to a public issue by hand, text-first.

## Status

| item | state |
|---|---|
| envelope v1, `install_id`, build + platform | **done** |
| `element_key` (stable, content-free) | **done**, verified across relaunch |
| consent line + screenshot opt-out | **done** |
| element-crop screenshot default | **already the behaviour**; keep it |
| `feedback_id` metas on elements worth naming | **not started** — rule 2 covers everything until then |
| `Brand.RAVES_VERSION` tracking the real release | **stale at 0.2.0** |
| transport, moderation, triage view | **designed, not built** |

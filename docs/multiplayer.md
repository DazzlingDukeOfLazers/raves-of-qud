# Multiplayer — architecture & roadmap

> **Status: design proposal — multiplayer is NOT implemented.** This is the plan, not shipped code.
> Unvalidated assumptions to prove before trusting any of it: zone serialization, deterministic
> regeneration, multi-body turn control, real-time ticking, and NAT traversal.

Direct-P2P co-op for the Raves viewer, written before the first slice so the seams are chosen
deliberately. Companion to `docs/roadmap.md` (the world-store pivot) and `docs/protocol.md` (the bridge wire).

Decisions in this doc were made with Daniel on **2026-07-27**; see [Decided](#decided) and
[Open questions](#open-questions).

---

## The one constraint everything hangs on

There are **two independent axes** people conflate, and only one is a real engineering wall:

1. **Input arbitration (anti-cheat).** *Who validates a player's actions?* — **Decided: nobody.**
   Anti-cheat is purely social. Qud has a wishmenu; a cheater is dealt with by `/block`, and a
   blocked player can't join your world. You play with people you want to play with. No central
   validator, ever.

2. **Simulation authority.** *Which machine steps the sim for a given zone?* — **This is not a
   policy choice; it's a determinism wall:**

   > Two independent Qud instances cannot mutate the same zone and reconcile. Qud's RNG, turn
   > order, and AI diverge the instant both act. There is no merge.

   So the invariant, regardless of philosophy: **exactly one simulator per zone at a time.**

Crucially, (2) is *not* a central server. It's "for this room, right now, one peer runs the
sim." Authority is **sharded by place**, which is fully compatible with symmetric, host-less,
trust-based P2P. Don't let the word "authority" smuggle in a boss server — there isn't one.

---

## The linchpin: Godot is the network node; the mod stays localhost

The C# mod already runs a localhost TCP server that **broadcasts snapshots to every connected
client** and accepts commands from any of them (that's how `control.py` and Godot coexist today —
see `mod/BridgeServer.cs`). So **V1 adds zero networking to the mod.** All peer traffic lives in
Godot, where WebRTC/ENet are native.

```
Host:   Qud(H) ──localhost──► Godot(H) ──WebRTC/ENet──► Godot(G) ──localhost──► Qud(G)
                 ◄──inject───           ◄───intents────                     (idle: tiles + standby)

  • Godot(H) subscribes to its local Qud (as today) and forwards snapshots to guest Godots.
  • Guest intents return over the peer link; Godot(H) injects them into its local Qud bridge.
  • Only the host simulates the shared zone.
```

Why the guest still runs its own Qud in puppet mode:

- **Tile assets.** Snapshots carry tile *names* (`Creatures/sw_bearman.png`), not pixels; each
  client resolves them against its **own** local tile export (per-install `tilesDir`). So the guest
  renders the host's zone using the guest's own exported art.
- **Standby authority.** When the guest leaves the shared zone to explore alone, its Qud takes over
  as authority for wherever it goes (see [Hybrid handoff](#slice-4--hybrid-handoff-the-big-lift)).
- **Free ownership property.** Because assets never cross the wire, **no Qud content is ever sent to
  a non-owner** — this keeps faith with the "requires a purchased copy" / Freehold attribution
  stance automatically, at no extra effort.

This decision is why the hard part (NAT traversal, signaling) never touches the game mod.

---

## Simulation models

| model | shape | cost | when |
|---|---|---|---|
| **Shared host / puppet** | one player's Qud *is* the world; others embody avatars inside it (extend `become` + command-inject; transport already broadcasts to N) | lowest — **zero new serialization** | V1 prototype, and the spine for real-time |
| **Zone-handoff** | everyone runs their own Qud; seed-shared world regenerates untouched zones identically; sync **serialized zone blobs** only for changed zones; exactly one authority per zone | needs Qud's zone-serialize API (unproven — spike) | the "sync the world files" end-goal |
| **Hybrid** | handoff by default; when 2+ players occupy one zone, one becomes that zone's local host and the others puppet until they leave | most complete, most work | V1 target |

**Decided: hybrid, but prototype puppet-first.** Puppet is the cheapest demo (the pipe already
broadcasts), the most motivating ("two players in one room"), and it de-risks exactly the
co-location case that pure handoff can't do alone. "Sync world files" (handoff) is the bigger,
later lift.

Puppet-first is also **directly on the path to real-time** (see below), so it is not throwaway.

---

## V1 slices

Each slice is independently demoable.

### Slice 1 — two bodies, one Qud, one machine
Prove the engine interleaves two player-driven bodies before any networking exists.
- **Mod:** a `spawn-avatar` command that creates a controllable body and returns an id; `move`/`key`
  gain an optional target-body id so inputs can be scoped to a specific avatar. Built on the existing
  `become` (body-swap, `mod/PlayerBecome.cs`) and `zoo` (spawn, `mod/ZooBuilder.cs`) primitives.
- **Tooling:** `control.py` drives body #2; verify via `qudshot` that both act in one zone.
- **Risk:** Qud's turn/energy (segment) system already interleaves multiple actors (followers,
  combat), so a second player body is within engine capability — confirm turn/energy accounting for a
  non-follower player-controlled body.

### Slice 2 — relay through Godot, LAN / direct
The real "two players in one zone" moment.
- **Godot(H) ↔ Godot(G)** over a hand-typed IP. Start with **ENet** (`ENetMultiplayerPeer`) — simplest
  reliable transport; defer WebRTC to slice 3.
- Host forwards snapshots; guest sends intents that drive avatar #2. Snapshots already contain every
  body in the zone (they're just `GameObject`s), so rendering N players is free — the guest's camera
  just follows its own avatar id.

### Slice 3 — DIY signaling + WebRTC
Replace the hand-typed IP with matchmaking.
- **~100-line WebSocket rendezvous:** create/join room by code → exchange SDP/ICE candidates → drop to
  a **direct** `WebRTCPeerConnection` data channel (`WebRTCMultiplayerPeer`).
- **TURN relay** as fallback for symmetric NATs (a small box that forwards bytes it can't interpret —
  not a sim arbiter).
- Storefront-independent; works regardless of where players bought Qud.

### Slice 4 — hybrid handoff (the big lift)
Symmetric, own-Qud exploration when players split up.
- **Exclusive per-zone authority** + **serialized zone-blob transfer** when a guest wanders off alone.
- **Blocked on a spike:** does Qud expose a usable zone serialize/deserialize API (`XRL.World.ZoneManager`
  / `Zone`)? Can a live zone be serialized to a blob and reloaded into a *different* Qud instance at the
  same seed? If not, handoff falls back to "guest re-enters as authority and re-generates from seed,
  losing that zone's local mutations" — acceptable degradation, but confirm before committing.
- Seed-shared world: untouched zones regenerate identically from the shared world seed, so peers only
  exchange diffs for zones someone actually changed. (Verify seed-determinism across installs at equal
  Qud version — state it as an assumption until proven.)

---

## Real-time / "Diablo" mode (post-V1)

Daniel wants to try a Diablo-style **real-time** co-op mode **after V1**. Two guardrails now so the
architecture doesn't preclude it:

- **Model input as *intents* ("move N", "attack"), never "submit turn."** Turn-based V1 advances the
  sim on input; real-time advances it on a **wall-clock timer** and samples queued intents. Same
  plumbing, a clock swapped behind a seam.
- **Keep the clock policy in one place on the host.** V1 = "any player's action steps the shared
  turn." Real-time later = host ticks Qud's segment engine on a timer. Don't leak turn-based
  assumptions into transport or avatar control.

Diablo co-op is **host-authoritative small-instance** — i.e. exactly the **puppet topology**. So the
puppet layer built in slices 1–3 *is* the real-time spine; hybrid handoff (slice 4) is the
big-persistent-world flavor and is orthogonal to the real-time mode.

**Honest risk (not a V1 blocker):** real-time in Qud is a genuine spike. Its turn/segment engine is
single-threaded and event-driven; making it tick continuously — and *feel* continuous through the
already-throttled ~15 snapshots/sec cadence (`docs/protocol.md`, "publish cadence") — is unproven.
Nothing in V1 blocks it, but don't promise it until it can be spiked honestly (around slice 4).

---

## Matchmaking

**Decided: DIY thin signaling.**

- Direct P2P for game traffic; a thin always-on **signaling/rendezvous** server only introduces peers
  and swaps ICE candidates. It forwards bytes it can't interpret — **not** an arbiter, consistent with
  the no-central-authority stance.
- **Steam / GOG SDKs** give free lobbies + P2P but require Raves to ship on that store with its **own
  appid** — Raves is a separate MIT viewer and can't borrow Caves of Qud's appid. Park those until/if
  Raves is distributed on a storefront.
- DIY keeps the self-host / MIT ethos and works no matter where players bought Qud. Cost: run a tiny
  box, own the NAT-traversal headaches (mitigated by TURN fallback).

Keep a `MatchmakingProvider` seam so Steam/GOG can slot in later without touching sim/transport code.

---

## Player cap

Cap **16**; ship **2 first, then 4**. Puppet/host-authoritative scaling is bounded by how many bodies
one host Qud can interleave per zone and the host's uplink for snapshot fan-out — both fine at 2–4,
re-measure before 8+.

---

## Decided (2026-07-27)

- **Anti-cheat = social only** (`/block` via the wishmenu). No input arbitration.
- **One simulator per zone at a time** (determinism wall, not policy).
- **Sim model = hybrid, prototyped puppet-first.**
- **Networking lives in Godot; the mod stays localhost-only.**
- **Matchmaking = DIY thin signaling** (WebSocket rendezvous → WebRTC direct; TURN fallback).
- **Cap 16, start 2 → 4.**
- **Real-time "Diablo" mode is a post-V1 target**; V1 must not preclude it (intents + clock seam).

---

## Open questions

1. **Zone serialization (blocks slice 4).** Does Qud expose serialize/deserialize for a live zone that
   round-trips into another instance? Spike by reflection before committing to handoff.
2. **Seed-determinism across installs.** Do two installs at equal Qud version generate identical
   untouched zones from the same world seed? Assumed; verify.
3. **Turn timing in shared zones (V1).** "Any action steps the turn" is the permissive default — does it
   feel right with 2 players, or do we need a submit/ready gate? Decide from the slice-2 demo.
4. **Avatar identity & lifecycle.** How is a guest's body created, named, saved/discarded on
   disconnect, and reconciled if the guest's *own* character should persist across sessions?
5. **Host migration.** If the host drops, can the shared zone's serialized state (once slice 4 exists)
   promote a guest to host, or does the session end?
6. **Real-time feel.** Deferred spike — can Qud's segment engine tick on a clock and read continuously
   through the snapshot throttle? (post-V1)

---

## Smallest first step

**Slice 1**, headless: a `spawn-avatar` command + scoped `move`, verified with two bodies acting in one
zone via `control.py` + `qudshot`. Zero networking, zero render risk, and it proves the single
assumption the whole puppet model rests on — that Qud will interleave two player-driven bodies.

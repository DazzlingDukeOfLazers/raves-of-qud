# Raves of Qud — bridge protocol

localhost TCP, default port **48710** (`mod/Protocol.cs` `DefaultPort` ==
`godot/BridgeClient.gd` `PORT`).

> **Security:** the bridge binds to **localhost only** and has **no application-layer authentication** —
> any local process that connects is trusted. Do **not** expose port 48710 to a LAN or the internet. To
> reach it from another machine, tunnel over SSH (never bind it publicly).

Every message is a frame:

```
[ 4 bytes: payload length, big-endian ][ payload: UTF-8 JSON ]
```

## At a glance (normative)

| property | value |
|---|---|
| Transport | TCP, **localhost only**, default port **48710**. No authentication (see the security note above). |
| Framing | `[4-byte big-endian length][UTF-8 JSON]`. The prefix could address 4 GiB, but the **receiver rejects any frame > 16 MiB** (`BridgeServer.cs`: `len > (16 << 20)` → drop the connection). Real snapshots are tens of KB. |
| Direction | **server → client** `snapshot` frames are **broadcast** to every connected client. **client → server** `command` frames are applied by the mod; the effect appears in the next snapshot (no per-command ack). |
| Ordering | in-order per connection (TCP). A `snapshot` **fully replaces** the client's world state — it is not a delta. |
| Cadence | throttled to ~15/sec; published on turns, driven commands, zone changes, and reactive signature changes — see [publish cadence](#server-cost--publish-cadence--read-before-touching-bridgetick). |
| Lifecycle | the client connects and **retries** ~1/sec until the mod opens the socket (first turn). Restarting Qud drops the socket → the client reconnects. The mod is **inert with no client connected** (gated on `ClientCount`). |
| Compatibility | every snapshot carries `mod` (`Protocol.Build`, human string) **and** `protocol` (`Protocol.Version`, int); a mod `.cs` compiles only at Qud startup, so "deployed but not restarted" silently runs old behaviour — check the build (see handshake below). |
| Encoding | UTF-8 JSON. Unknown fields are ignored (forward-compatible); a missing field means absent/default (the client falls back, e.g. `—`). |

Field-level detail is in the sections below (snapshot anatomy → per-cell → per-object → colours → water → panels → commands).

## Version handshake

A mod `.cs` only compiles at Qud startup, so "deployed but not restarted" silently runs old behaviour.
Every snapshot carries `mod` (a human build stamp, `Protocol.Build`, e.g. `"2026-07-28 options-writeback"`)
**and** `protocol` (int, `Protocol.Version`, monotonic). **Bump `Protocol.Build` on every mod change** — it
is the diagnostic that catches deployed-but-not-restarted code, so a stale stamp defeats its own purpose. The client (`MainFrame.gd` `MIN_MOD_PROTOCOL` /
`CLIENT_PROTOCOL`) compares and pins a message-log line: green "up to date", red "restart Caves of Qud"
(mod too old), or yellow "re-export Raves" (client too old). **Bump `Protocol.Version` whenever the client
comes to depend on a new field**, and raise `MIN_MOD_PROTOCOL` to match. History (from `Protocol.cs`):

- `1` — baseline (pre-handshake)
- `2` — per-object `liquid` flag (static-signature fix) + the `protocol` field itself
- `3` — per-object `onFire` flag (daytime campfire flame + smoke) — **current**

## Server → client: `snapshot`

Published per turn (throttled), plus on driven commands / zone changes / reactive signals — see
[publish cadence](#server-cost--publish-cadence--read-before-touching-bridgetick). One snapshot is the
**whole observed world + all panel state**, built by `ZoneSnapshot.BuildJson`.

```jsonc
{
  "type": "snapshot",
  "tilesDir": "/…/RavesOfQud/tiles",   // where the mod writes exported tile PNGs
  "mod": "2026-07-28 options-writeback", // Protocol.Build — which build produced this frame
  "protocol": 3,                       // Protocol.Version — client checks vs its minimum
  "gameId": "abc123…",                 // The.Game.GameID — client namespaces its zone store by this
  "serverUs": 14200,                   // prior turn's BuildJson time (µs), for the profiler
  "renderBaseUs": 0,                   // this turn's Qud RenderBase cost (µs; 0 if skipped on the world map)
  "time":    { "segment": 4200, "segmentsPerDay": 12000, "startOfDay": 3250,
               "startOfNight": 10000, "isDay": true, "label": "10:24 AM" },
  "palette": { "r": "#a64a2e", "…": "…", "k": "#0f3b3a", "bgRaw": "b", "bg": "#40a4b9" },
  "zone":    { "id": "JoppaWorld.53.3.1.0.10", "width": 80, "height": 25,
               "wx": 53, "wy": 3, "zx": 1, "zy": 0, "z": 10 },
  "player":  { "x": 40, "y": 12, "glyph": "@", "tile": "Creatures/sw_humanoid.png", "color": "&Y", … },
  "worldTerrain": { "name": "Salt Marsh", "glyph": "≈", "tile": "…", "color": "&g" },
  "stats":    { "name": "…", "hp": 21, "hpMax": 21, "level": 1, "xp": 0, … },
  "effects":  [ { "name": "{{B|wet}}", "duration": 18, "indefinite": false, "bad": false } ],
  "target":   { "present": false },
  "context":  { "kind": "none", "text": "No missile weapons equipped." },
  "abilities":[ /* activated-ability entries */ ],
  "messages": { "msgCount": 132, "messages": [ "You enter Joppa.", … ] },
  "cells": [
    {
      "x": 41, "y": 12,
      "bridge": false, "wade": true, "swim": false, "light": 200,
      "objs": [
        { "name": "[painted ground]", "display": "ground", "ground": true,
          "tile": "Terrain/sw_grass1.bmp", "color": "&g", "detail": "G", "layer": 0,
          "wall": false, "solid": false, "occluding": false, "bridge": false, "sinks": false },
        { "name": "Pond", "display": "pond", "glyph": "~", "layer": 2,
          "tile": "Liquids/Water/deep-11111111.png", "color": "&b^B", "liquid": true },
        { "name": "Snapjaw", "display": "snapjaw", "glyph": "s", "layer": 10,
          "tile": "Creatures/sw_snapjaw.png", "color": "&y", "creature": true, "sinks": true }
      ],
      "nHeld": 2, "nRendered": 2, "nSent": 3
    }
  ]
}
```

### Frame anatomy — top-level keys

| key | source | meaning |
|---|---|---|
| `type` | constant | always `"snapshot"`. |
| `tilesDir` | `TileExporter.Dir` | where the mod writes exported tile PNGs; the client loads `tilesDir/<tile-with-slashes-as-underscores>` (e.g. `Creatures/sw_bearman.png` → `Creatures_sw_bearman.png`). Missing files fall back to the glyph and retry on later frames (export is on-demand). |
| `mod` | `Protocol.Build` | which mod build produced this frame (human string). |
| `protocol` | `Protocol.Version` | numeric wire version; the client checks it vs `MIN_MOD_PROTOCOL`. |
| `gameId` | `The.Game.GameID` | stable per-game id; the client namespaces its on-disk remembered-zone store by it so a new game never renders a previous game's zones. |
| `serverUs` | `ZoneSnapshot` | previous turn's `BuildJson` serialize time in µs (measured one turn late; the current turn isn't done until the JSON is written). |
| `renderBaseUs` | `Bridge.LastRenderBaseUs` | this turn's Qud `RenderBase` cost in µs; **0** when skipped (world map, `z < 0`). |
| `time` | `Calendar` | day/night grade: `segment` / `segmentsPerDay` (12000; **segments, not hours**), `startOfDay` 3250, `startOfNight` 10000, `isDay`, `label`. Qud has no moon phase; the client tints night generically. |
| `palette` | `ConsoleLib` | colour char → `#rrggbb`, plus `bgRaw` (the raw world-background colour string) and `bg` (its resolved hex). See [Colours](#colours). |
| `zone` | `Zone` | see [Zone coordinates](#zone-coordinates). |
| `player` | player `GameObject` | `x`,`y` + the player's own render fields (glyph/tile/colours) for the log's "you" pictograph. |
| `worldTerrain` | `Zone.GetTerrainObject()` | the location's world-map tile + landmark/biome `name` (e.g. "Salt Marsh"); the client accumulates these as the player travels. Absent off the world map / mid-teardown. |
| `stats`,`effects`,`target`,`context`,`abilities`,`messages` | player state | the gameplay-chrome panels — see [Panel blocks](#panel-blocks). |
| `cells` | `Zone.GetCell` sweep | the rendered world — see [per-cell](#per-cell-accounting) / [per-object](#per-object-fields). |

### Zone coordinates

`zone` carries the structured coordinates straight off the `Zone` (confirmed real int fields by reflection),
so the client never parses the `id` string:

| field | source | meaning |
|---|---|---|
| `id` | `Zone.ZoneID` | the raw zone id string (kept for logging/keys). |
| `width`,`height` | `Zone.Width/Height` | zone dimensions in cells (80×25 for a surface zone). |
| `wx`,`wy` | `Zone.wX/wY` | parasang (world-map cell). |
| `zx`,`zy` | `Zone.X/Y` | zone within the 3×3 parasang. |
| `z` | `Zone.Z` | stratum; **`z < 0` is the world map** (the client and mod both special-case it). |

The client derives global cell coordinates from these.

### The painted ground layer  ← read this first

**A cell is not just its objects.** Qud composites a ground layer onto cells that hold **no `GameObject`
at all** — in a Joppa zone, 1103 of 2000 cells. `Cell.Render()` returns a `RenderEvent` with the tile,
colours and flip flags; the mod emits it as a `RenderLayer 0` floor, **first in `objs`**, tagged
`"ground": true`. The ground object always carries fixed
`wall:false solid:false occluding:false bridge:false sinks:false ground:true` plus `tilecolor:""` and
optional `hflip`/`vflip`.

Without it you get a world with no grass or dirt — and no amount of querying the objects will reveal the
problem, because the objects genuinely aren't there.

> **Cost rule:** `Cell.Render()` is resolved **only on empty cells** (`objects.Count == 0`). On an
> occupied cell it composites the whole cell and returns the *top* object's tile — which the objects
> already draw and which is deduped away — so resolving it there was pure waste (2000 `Cell.Render()`
> calls + 2000 `HashSet` allocs every turn was the overworld movement lag). See `ResolveGround`.

### A cell is sent when…

A cell reaches the wire if it has objects **or** a painted ground tile; only truly blank cells are omitted.
Objects are ordered bottom→top, with the painted ground first.

### Per-object fields

Fields come from `XRL.World.Parts.Render`, but via its **accessors**, not its fields:
`glyph`=`getRenderString()`, `tile`=`getTile()` (the `Tile`/`RenderString` *fields* are static blueprint
values, empty for runtime-chosen art). `color`=`ColorString`, `tilecolor`=`TileColor`,
`detail`=`DetailColor`, `layer`=`RenderLayer`.

| field | source | meaning |
|---|---|---|
| `name` | `GameObject.Blueprint` | identity — an object with no tile is otherwise unidentifiable. |
| `display` | `GameObject.DisplayNameOnly` | plain display name (read defensively — the getter runs Qud's markup pipeline). |
| `glyph` | `Render.getRenderString()` | ASCII fallback / classification hint. |
| `tile` | `Render.getTile()` (or `RenderTile` paint) | tile path; empty ⇒ client draws the glyph. |
| `color` | `Render.ColorString` | raw Qud colour string (e.g. `&Y`, `&b^B`). See [Colours](#colours). |
| `tilecolor` | `Render.TileColor` | raw tile colour string. |
| `detail` | `Render.DetailColor` | raw detail colour string. |
| `layer` | `Render.RenderLayer` | 3D treatment selector — see [RenderLayer values](#renderlayer-values). |
| `wall` | `GameObject.IsWall()` | client draws a `BoxMesh` prism. |
| `solid` | `Physics.Solid` | blocks movement (informs the 3D silhouette). |
| `occluding` | `Render.Occluding` | blocks sight (used with `layer`/`wall` for classification). |
| `bridge` | `GameObject.HasIntProperty("Bridge")` | this object *is* the deck surface — see [Water & bridges](#water--bridges). |
| `sinks` | `IsCreature && !IsFlying` | submerge this one in liquid; scenery/flyers keep height. |
| `creature` | `GameObject.IsCreature` | mobile actor — the client drops these from a **remembered neighbour** zone (they've since wandered off). |
| `liquid` | `GameObject.LiquidVolume != null` | a liquid pool — **VOLATILE**. Client excludes it from the frozen-zone static signature, else a wet player's wading sloshes water onto every cell and rebuilds the zone each step ("tiles vanish while walking"). |
| `lightRadius` | `LightSource.Radius` (only when `Lit`) | client places an additive glow-pool + flame of this radius. The flame is procedural in Qud (no tile), so only the light is sent. |
| `onFire` | `HasPart("AnimatedMaterialFire")` (only when true) | Qud draws the flame procedurally, so the tile is flameless (a campfire's `sw_campfire_noflame.png`); client draws a daytime-visible flame + smoke. |

Client render classification: `wall` → BoxMesh prism; else `layer` ≤ 2 → flat ground quad; else → upright
billboard. (Calibrated: layer 0 = ground clutter, 3 = trees, 7 = rock walls, 10 = creatures.)

**Resolved (painted) colours** — only when `RenderTile` actually painted a tile (rare): `fgHex`, `bgHex`,
`detailHex` carry already-resolved RGB and `hflip`/`vflip` carry Qud's sprite flipping. The client prefers
these over the palette. In practice `RenderTile` fires for almost nothing, so most objects use the
`ColorString` path.

**Perceived override** — for an object the player does **not** understand, the mod adds `glyphP`/`tileP`/
`colorP`/`detailP` from `GameObject.RenderForUI()` (Qud's own identification-honouring render), so the
client can show the generic "unknown" icon in perceived mode. Understood objects (the common case) carry no
override, so the expensive `RenderForUI` call only runs for the rare unidentified item.

### Per-cell accounting

| field | source | why |
|---|---|---|
| `nHeld` | `Cell.GetObjectCount()` | what Qud says the cell contains |
| `nRendered` | `Cell.RenderedObjectsCount` | what Qud considers renderable |
| `nSent` | count actually emitted | what reached the wire (incl. the ground layer) |

`nHeld > nSent` means **we are dropping objects** and the number says where. These exist because "the client
shows nothing here" and "the mod sent nothing here" were previously indistinguishable — which is exactly how
the missing ground cover hid through six rounds of debugging.

### Server cost & publish cadence — read before touching `Bridge.Tick`

The mod runs inside Qud, so wasted work here slows **the game itself**, not just Raves. Hard-won rules (the
"overworld was unplayable" saga):

- **Do nothing without a client.** The per-turn hook returns immediately when `server.ClientCount == 0`. It
  otherwise built a full snapshot + recomposited Qud's map on *every* turn even with Raves closed — so plain
  solo Qud lagged on every move.
- **Throttle publishing.** A single world-map step **auto-advances a burst of turns**, and building a
  2000-cell snapshot per intermediate turn published ~60–100/sec (each ~10ms) — pinning Qud's turn thread
  *and* flooding Godot so its frame loop starved. `Tick` marks state dirty and publishes at most once per
  `PublishThrottleMs` (66ms, ~15/sec); `TickRender` flushes the last coalesced state right after the burst.
  A *driven* command still publishes immediately. Normal play (turns seconds apart) is unchanged.
- **A zone change always publishes NOW, bypassing the throttle.** The trailing-edge flush lives in
  `TickRender` (`BeforeRenderEvent`), which does **not** fire while Qud is backgrounded — the normal
  "watching Raves" case — so a coalesced final frame could strand until the next input. `Tick` (and
  `TickRender`) compare the player's `Zone.ZoneID` to `_lastPublishedZone` and force-publish on any change:
  startup (null → first zone) and every z-transition appear immediately. Same-zone bursts still throttle.
- **No-turn reactive refresh.** `TickRender` diffs a cheap `BuildSignature` fingerprint (~10/sec) of the
  observed panel state — combat target, HP, position, level/XP, effects, message count, body temperature,
  zone — and marks the snapshot dirty on any change, so targeting and other no-turn changes appear without a
  move. To make more things reactive, add the signal to `BuildSignature`; nothing else changes.
- **Off-turn prompt flush.** `ForcePublishSoon` (set when Raves answers/cancels a `dir`/`dircancel` prompt)
  forces one publish after the game unblocks, so a result created during the prompt (e.g. a new campfire)
  shows. `TickAction` (`BeginTakeActionEvent`) also flushes it even while unfocused.
- **`RenderBase` is skipped on the world map** (`z < 0`) — recompositing Qud's own console every turn is
  wasted while you watch Raves, and the map barely changes step to step. Normal zones keep it.

Two timing fields ride in every snapshot so this is measurable, not guessed: `serverUs` (`BuildJson` time,
previous turn) and `renderBaseUs` (this turn's `RenderBase`, 0 if skipped). Watch the **publish rate** too —
snapshots arriving 10ms apart mean a burst is flooding.

### Colours

`palette` (top level) maps each colour char to `#rrggbb`, read from
`ConsoleLib.Console.ColorUtility.colorFromChar` for the 16 chars `rRgGbBcCmMwWoOyYkK`. **`Base/Colors.xml`
names the colours but contains no RGB** — the values live in code. Notably **`k` is `#0f3b3a`, a dark teal,
and is the colour of the Qud world**, not black. `palette` also carries `bgRaw` (the raw world-background
colour string, `ColorUtility.CAMERA_BACKGROUND`) and `bg` (its resolved hex); `CAMERA_BACKGROUND` is **not**
the field colour despite the name — it's `#40a4b9`, plain cyan.

The colour chars → measured RGB (shipped live in `palette`, so the client never hardcodes them — this table
is reference; the client's `WORLD_BG` derives from `k`):

| | | | |
|---|---|---|---|
| `k` **#0f3b3a** | `K` #155352 | `y` #b1c9c3 | `Y` #ffffff |
| `w` #98875f | `W` #cfc041 | `g` #009403 | `G` #00c420 |
| `b` #0048bd | `B` #0096ff | `c` #40a4b9 | `C` #77bfcf |

**How the client resolves a raw colour string** (`ZoneRenderer._qud_color` / `_fg_letter`): it takes the
**foreground** char — the part *before* any `^background` — strips the leading `&`, and uses its last
character; then it prefers the `palette` value the mod sent for that char, falling back to a built-in table
only if the char is absent. So `&Y` → `Y` (white), and `&b^B` → foreground `b` (the `^B` background is
dropped). Do **not** read the trailing letter of the *whole* string — for `&b^B` that would wrongly pick the
background `B`. Qud's palette to remember: `Y`=white, `y`=gray, `W`=gold, `w`=brown.

When `RenderTile` paints an object, `fgHex`/`bgHex`/`detailHex` carry already-resolved RGB (and
`hflip`/`vflip` Qud's sprite flipping); the client prefers those over the palette path.

### RenderLayer values (the `layer` field → 3D treatment)

Calibrated from live capture; classification off `layer` + `wall`/`occluding` is in
[`rendering.md`](rendering.md) §1.

| layer | contents | 3D treatment |
|---|---|---|
| 0 | ground clutter (`sw_ground_dots`) | flat floor |
| 2 | liquids (`deep-*` water) | flat floor |
| 3 | trees, plants, watervines | upright billboard |
| 5 | small stones | upright billboard |
| 6 | furniture, torches | upright billboard |
| 7 | walls, fences, doors, tents | prism / oriented panel |
| 10 | creatures | upright billboard |
| 100 | special NPCs | upright billboard |

### Water & bridges

Per **cell** (all from first-class Qud predicates, no heuristics):

| field    | source                          | meaning                                    |
|----------|---------------------------------|--------------------------------------------|
| `bridge` | `Cell.HasBridge()`              | something decks over this cell              |
| `wade`   | `Cell.HasWadingDepthLiquid()`   | liquid deep enough to wade through          |
| `swim`   | `Cell.HasSwimmingDepthLiquid()` | liquid deep enough to swim in               |
| `light`  | `(int)Cell.GetLight()`          | Qud's `LightLevel` byte (Blackout=0, None=1 … Light=200 …); the client falls off to black away from sources **underground** |

Per **object**: `bridge` (`HasIntProperty("Bridge")` — this object *is* the deck), `sinks`, `liquid`,
`lightRadius`, `onFire` — all defined in [per-object fields](#per-object-fields) above.

The client's rule: **the water stays flat, the actor recesses.** `_cell_sink()` turns `wade`/`swim` into a
fraction of the sprite's art to hide, and `bridge` cancels it — you cross at full height. A `bridge` object
is drawn as a flat opaque quad (`fill = true`, so the brick line-art's transparent field becomes ground
colour) lifted above the water it spans.

### Panel blocks

The gameplay-chrome panels (`MainFrame`'s 5 rows) are filled from these top-level blocks. **They default to
Qud's PERCEIVED information** — what the game's own look/target line would show — with exact values hidden
behind the client's "Full info" debug toggle.

| block | shape | notes |
|---|---|---|
| `stats` | object | `name`, `hp`/`hpMax`, `level`, `xp`/`xpFloor`/`xpNext`, `temp`, `qn` (Quickness), `ms` (MoveSpeed), `av`/`dv`/`ma` (Qud's displayed combat values), `weight`/`weightMax`, `water` (fresh-water drams = currency), `hunger`/`thirst` (markup-stripped), `terrain` (zone display name), `stairsUp`/`stairsDown` (does the zone contain any StairsUp / StairsDown object — cached per zone, first hit wins; the client greys its Up nav icon when `stairsUp` is false). Every read is guarded — a missing part never fails the snapshot. |
| `effects` | array | active buffs/debuffs: `name` (keeps `{{colour|…}}` markup so the client colours it — e.g. wet is blue), `duration` (turns), `indefinite` (`≥ DURATION_INDEFINITE`), `bad` (Qud's `TYPE_NEGATIVE`). |
| `target` | object | current combat target (`Sidebar.CurrentTarget`). `present:false` when none. Else `display`, `hostile`, position `x`/`y`, **perceived** `wound`/`feeling`/`difficulty` (the look-line descriptors), full render fields, and `hp`/`hpMax` (**hidden info — for the Full-info toggle only**). |
| `context` | object | the contextual command menu (row 4). `kind:"none"` + `text` when no missile weapon; else `kind:"missile"` with `actions` (`fire`/`reload`, each with Qud's live hotkey via `ControlManager`) and `weapons` (name, `id`, `canReplaceCell`, `ammoRemaining`/`ammoTotal`, `status`, render). |
| `abilities` | array | activated abilities in Qud's own bar order: `name`, `command`, `hotkey`, `visible`, `toggleable`, `toggle`, `enabled`, `cooldown`, plus a state-appropriate icon (toggle-on / cooling-down / disabled / default). |
| `messages` | object | `msgCount` (total ever, so the client can diff for NEW lines) + `messages` (the last ~80 log lines, keeping `{{colour|…}}` markup). |

### Deferred (not yet on the wire)

- **FOV / fog-of-war** — every object with a `Render` is currently sent; `Render.Visible` is available to
  gate this later.
- **Neighbour-zone payloads** for over-the-horizon streaming (the 3×3 parasang). The client already
  *renders* remembered neighbours from prior snapshots (and drops `creature` objects from them); what's
  deferred is the mod proactively **sending** adjacent zones in one frame.

## Client → server: `command`

```json
{ "type": "command", "name": "move", "dir": "N" }
{ "type": "command", "name": "wait" }
{ "type": "command", "name": "setoption", "id": "OptionSomething", "value": "true" }
```

The mod dispatches on `name`. Commands split by **which thread applies them**, because that determines
whether they can drive an *unfocused* game:

**Socket-thread (applied the instant the frame arrives, in `Bridge.OnPayload`)** — these inject straight
into Qud's input queue (`Keyboard.Push*`), which wakes the main thread even while the window is unfocused
(the render-tied ticks don't fire when backgrounded, so they can't drive an idle game):

| `name` | fields | effect |
|---|---|---|
| `move` | `dir` (`N S E W NE NW SE SW`) | one step — `Keyboard.PushCommand("CmdMove"+dir)`. Resolves the full turn (combat, doors, NPCs) exactly as a keypress. |
| `wait` | — | pass one turn (`CmdWait`). Godot sends one on (re)connect to prime the first render; Shift+Space is a manual passthrough. **Passes a turn.** |
| `command` | `command` (a Qud command id) | inject an arbitrary command (`CmdFire`, `CmdReload`, …) via `PushCommand`; any targeting UI opens in Qud's window. Binding-independent (no key guessing). |
| `key` | `key` (one char) | raw key routed through Qud's **keymap** (`PushKey`, `bAllowMap:true`) — fires whatever the player has that key **bound** to (e.g. soar/descend). Letters/digits only. Raves forwards **S/D** this way. |
| `dir` | `x`,`y` | answer a Qud **PickDirection** prompt with a `LeftClick` at cell (x,y); Qud derives the direction (adjacent → that way, own cell → self). Used by the direction picker (e.g. Make Camp). Sets `ForcePublishSoon`. |
| `dircancel` | — | cancel a PickDirection prompt (`RightClick`), unblocking Qud. Sets `ForcePublishSoon`. |

**Main-thread (queued to `Incoming`, drained by `Tick`/`TickRender`, applied in `Bridge.Apply`)** — these
mutate game state or make graphics calls, so they must run on the main thread:

| `name` | fields | effect |
|---|---|---|
| `shot` | — | Qud screenshots itself → `qud_shot.png` (marshalled via `uiQueue`; file appears at end-of-frame). |
| `export` | — | re-run the data exporters (mods + options) on demand — the clean replacement for ticking a fake turn. Title art is one-shot, so it's skipped. |
| `setoption` | `id`, `value`, `defer` | apply a Qud option (`Options.SetOption`) + re-export so Raves reflects it. `defer:"1"` **batches**: skip the per-call re-export; the caller sends one `export` after the last. (Some options need a restart — `o.Restart`.) |
| `itemaction` | `item`, `command` | invoke an inventory action on the player's equipped missile weapon with `GameObject.ID == item` (e.g. `ReplaceSocketCell` — change the battery) via `InventoryActionEvent.Check`. |
| `become` | `bp` | **debug:** turn the player into blueprint `bp` (re-homes control, retires the old body). |
| `zoo` | `cat`, `page` | **debug:** build a showcase of blueprints (`cat`, paged) into the current zone. |
| `catalog` | — | **debug:** dump the pickable-blueprint catalog to disk for the Godot menu. |

The sim resolves each fully as the game would; new state returns as the next `snapshot` (a driven command
publishes one immediately). Extend either set by adding a `name` case in the matching handler.

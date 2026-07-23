# Raves of Qud

A 2.5D augmentation layer for [Caves of Qud](https://www.cavesofqud.com/). It does
**not** reimplement the game. The real, paid, modded game runs as the authoritative
simulation; a small in-game C# mod publishes what the player sees each turn over a
localhost socket, and a Godot client renders it as billboarded sprites with an
orbiting camera. Input round-trips back to Qud, which resolves every turn.

> Requires your own paid copy of Caves of Qud. Ships **no** game assets.

```
┌─────────────┐   command frames (TCP 48710)   ┌────────────────────────┐
│   Godot     │ ─────────────────────────────▶ │  Caves of Qud (real)   │
│ 2.5D client │                                │  + Raves bridge mod    │
│  (view)     │ ◀───────────────────────────── │  = authoritative sim   │
└─────────────┘   snapshot frames (per turn)    └────────────────────────┘
```

Qud owns worldgen, AI, combat, items, saves — everything. This repo owns only
two mappings: Godot input → Qud command, and Qud zone state → 3D billboards.

## Layout

```
mod/     Caves of Qud C# scripting mod (the bridge / server)
  Protocol.cs, Json.cs, MiniJson.cs, BridgeServer.cs   ← pure .NET, no Qud types
  Bridge.cs, BridgePart.cs, PlayerBridgeMutator.cs,
  ZoneSnapshot.cs                                       ← the only Qud-coupled code
  manifest.json
godot/   Godot 4.x client (StreamPeerTCP → billboards + orbit camera)
docs/    protocol.md — the wire format
```

## Design notes

- **The uncertain surface is contained.** All Qud API calls live in `Bridge.cs`,
  `BridgePart.cs`, and `ZoneSnapshot.cs`, each headed by a `CONFIRM` block. The
  networking/serialization half references no game types and can be exercised
  standalone. Re-targeting a Qud patch = fixing symbols in those three files.
- **Threading is the trap.** The socket accepts/reads on background threads and
  queues inbound commands; all game-state access (applying commands, reading the
  zone) happens on Qud's main thread via the per-turn hook. Never touch a
  `GameObject` off a background thread — it will crash the sim.
- **Asset-free by construction.** The MVP renders glyphs as `Label3D`, so it runs
  with zero Qud art. Swap to `Sprite3D` pointed at the user's *own* local tile
  PNGs later; never commit Qud's assets (see `.gitignore`).

## Setup (once you've installed the game)

### Mod
1. Copy `mod/` into your Qud mods folder as `RavesOfQudBridge/`:
   - **macOS (confirmed on this install):**
     `~/Library/Application Support/com.FreeholdGames.CavesOfQud/Mods/`
     (create the `Mods/` dir if it doesn't exist yet)
   - Windows: `%USERPROFILE%\AppData\LocalLow\Freehold Games\CavesOfQud\Mods\`
2. In-game, enable the mod and **allow C# scripting mods** (Options → Mods; local
   scripting mods need to be trusted).
3. Start a game. On the first turn the mod opens `127.0.0.1:48710`.

> **Decompiling for the CONFIRM items:** the assembly is at
> `CoQ.app/Contents/Resources/Data/Managed/Assembly-CSharp.dll`, and it retains
> source-file path metadata (e.g. `.../Parts/Render.cs`), so ILSpy gives you clean,
> navigable output. The moddable XML is under
> `CoQ.app/Contents/Resources/Data/StreamingAssets/Base/` (`Commands.xml`,
> `Colors.xml`, `ObjectBlueprints.xml`, …).

### Client
```bash
# open godot/ in Godot 4.x, or:
godot --path godot
```
The client auto-connects and retries once a second until Qud is listening.

## First milestone (de-risk the live loop before any polish)

Prove the round trip end to end with **one live zone**:
1. Mod streams the active zone each turn → client renders billboards.
2. Arrow keys in Godot → Qud steps the player → next snapshot re-renders.

Only after that's solid: neighbor-zone (3×3 parasang) streaming for the
over-the-horizon look, FOV, and the stats/log chrome mirror.

## CONFIRM checklist

Confirmed against this install by grepping `Assembly-CSharp.dll` metadata
(existence + casing) and reading the XML data files. Signatures/overloads still
want ILSpy — string metadata proves a name exists, not its parameters.

Confirmed ✓
- `[PlayerMutator]` + `IPlayerMutator` present; method is lowercase `mutate`
- `The.ActiveZone` (`get_ActiveZone`), `CurrentCell` (`get_CurrentCell`)
- `GetFirstPart<T>()` + `AddPart` present (`GetPart<T>`/`HasPart<T>` were NOT)
- `Render` fields are **lowercase**: `renderString`, `colorString`, `detailColor`
- Movement command IDs: `CmdMoveN/S/E/W/NE/NW/SE/SW` (`Commands.xml`)
- `CommandEvent` exists (`World/Events/CommandEvent.cs`) — used to inject moves
- Color letters: `Y`=white `y`=gray `K`=black `W`=gold `w`=brown `O/o`=orange
  (`Colors.xml`) — palette baked into `godot/ZoneRenderer.gd`

Still confirm in ILSpy ☐
- [ ] `IPart.Register(GameObject, IEventRegistrar)` + `FireEvent(Event)` signatures,
      and the `"EndTurn"` event name (or the pooled `EndTurnEvent`)
- [ ] `CommandEvent.Send(actor, command)` exact signature
- [ ] `Zone.Width/Height/GetCell/ZoneID`, `Cell.Objects/X/Y` (property chains)
- [ ] Render **tile** field names (sprite path / tile color / render layer) —
      didn't surface as bare strings; read them off `Parts/Render.cs`
- [ ] `manifest.json` required fields + enabling a local scripting mod

## PERF (defer until it bites)

- Snapshots are a few KB (80×25 ≈ 2000 cells); JSON per turn is fine. If the
  socket write ever stutters a turn, move `Publish` to a background writer thread
  fed by a queue.
- Full re-render per snapshot is brute force; add cell-level diffing later.

## License

MIT (see `LICENSE`). Requires a separately-purchased copy of Caves of Qud;
Caves of Qud and its assets are © Freehold Games.

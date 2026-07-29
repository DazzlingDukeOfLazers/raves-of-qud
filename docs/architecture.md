# Raves of Qud architecture: Godot client, C# bridge, and the Qud thread model

The runtime structure of the player-facing view (the **Holodeck** — the Godot 2.5D window).
`CLAUDE.md` keeps a one-paragraph map and points here for the detail. For the render *pipeline* specifically see [`rendering.md`](rendering.md); for the wire format
see [`protocol.md`](protocol.md).

## Boot chain

`project.godot`'s main scene is **`MainMenu.tscn`** — a launcher (`MainMenu.gd`) that stamps the window
title from the **`Brand`** autoload (`Brand.gd`, the runtime source of truth for the game name / tagline /
attribution / URLs; `config/name` in project.godot is just the export literal) and, on Play,
`change_scene_to_file("res://MainFrame.tscn")`. Runtime order: **MainMenu → MainFrame → Main (the Holodeck)**.

## `Main.gd` is decomposed

It was a ~1800-line god-object; the camera and its neighbours now live in their own files, each created in
`Main._ready` and driven by thin delegates:

- **`SkyGrade.gd`** — day/night atmosphere (WorldEnvironment/fog, the MULTIPLY grade, sun/moon, time→tint).
- **`CameraRig.gd`** — the `_pivot`+`_cam` nodes, all 7 camera modes + placement math (`_cam_rig`; untyped
  on purpose — a `class_name`'s cache is flaky under headless `--check-only`, so locals off `_cam_rig.*`
  take explicit types, not `:=`).
- **`Multiview.gd`** — the all-views SubViewport grid (`mv` godot-cmd toggles it headlessly).
- **`RemoteControl.gd`** — the `godot_cmd` file poller (control.py channel); Main keeps `_exec_godot_cmd`.
- **`DebugMenu.gd`** — the backtick menu (`dbg` godot-cmd toggles it); Main keeps the shared `_toggle_flat_2d`.
- **`DirectionPicker.gd`** — the ability-prompt cursor (Make Camp). It `gui_release_focus()` on end so the
  movement arrows return to the Holodeck; **any clickable UI over the Holodeck must be `FOCUS_NONE`** or the
  focused control swallows the arrows (bit the command bar: "can't move after Make Camp").

## `MainFrame.gd` — the gameplay chrome

`MainFrame.gd` (a `Control`, built in code like the rest) is the 5-row gameplay chrome: status strip;
HP/EXP + top menu; the **Holodeck | side panels** row; effects/target/context; command bar. The Holodeck
(`Main.tscn`) renders **FULL-WINDOW into the root viewport** — its original, crash-free home. The chrome
floats on top and row 3's left cell is a transparent **hole** the 3D shows through (`_holo_hole`,
mouse-ignore, no stylebox). There is **no `SubViewportContainer`/`SubViewport`** — that was the Metal crash
source and is gone. See `_holodeck_cell()`. MainFrame drops its full-window bg ColorRect (it would cover the
3D) and sets `RenderingServer.set_default_clear_color(COL_BG)` for the gaps/pre-connect look.

- **`Main.embedded`** (set by MainFrame before add_child) hides the Holodeck's own chrome (mode label,
  Reset/2D buttons) so the frame owns them, AND moves Main's day/night MULTIPLY grade to a **negative
  CanvasLayer** so it tints only the 3D, never the frame's chrome. Standalone `Main` is unchanged.
- **Data flow, ONE bridge:** `Main` emits a `snapshot(data)` signal each frame; `MainFrame._apply_stats`
  fills the status bar/vitals from it — no second bridge connection. Missing fields fall back to `—`.

## Player stats (the `stats` block)

Player stats come from the mod's `stats` block (`ZoneSnapshot.WriteStats`). Verified Qud APIs:
name=`DisplayNameOnly`; hp=`hitpoints`/`baseHitpoints`; level/xp=`GetStatValue("Level"/"XP")`; xp
thresholds=`Leveler.GetXPForLevel(lvl)`/`(lvl+1)`; temp=`pPhysics.Temperature` (a legacy shortcut still used
here; `Physics` is the field to prefer for new code — see [`qud-api.md`](qud-api.md));
QN/MS=`GetStatValue("Speed"/"MoveSpeed")`; **AV/DV/MA=`Stats.GetCombatAV/DV/MA`** (displayed values with
attribute mods — plain `GetStatValue` matches AV only by luck); weight=`GetCarriedWeight`/
`GetMaxCarriedWeight`; water=`GetFreeDrams("water")` (liquid ids are **lowercase**);
hunger/thirst=`Stomach.FoodStatus()`/`WaterStatus()` (strip `{{color|text}}` markup); biome=`Zone.DisplayName`.
Adding a field is: emit it in WriteStats → read it in `_apply_stats`.

## Panels (each its own scene)

Fed by `_apply_stats`: `MinimapView` (full/minimal toggle), `NearbyObjects` (3x3, client-side from `cells`),
`MessageLog`, `ActiveEffects` (row 4 L), `TargetView` (row 4 M), `ContextMenu` (row 4 R).

- **Message log:** verbatim/filter toggle (filter = one line per unique message, `(xN)` on repeat, decays
  off after a grace of quiet rounds; a "round" = a snapshot with NEW messages, diffed via `msgCount`;
  **seeded from the backlog on connect** so it's never empty). It also inlines **object icons** matched from
  each line's text against a zone name→object index, a **"you"** pictograph (the player's own render) on
  player-subject lines, and **landmark** world-map tiles accumulated from `worldTerrain` as you travel.
- **Active effects / Target / Context (row 4).** Effects = `player.Effects` DisplayName (coloured;
  LiquidCovered → the liquid's `GetSmearedName`, e.g. "wet"). Target = `Sidebar.CurrentTarget`: name + Qud's
  perceived descriptor line (`Strings.WoundLevel` / `Description.GetFeelingDescription` /
  `GetDifficultyDescription`) + direction. Context = the missile-weapon area (`GetMissileWeapons` +
  `MissileWeapon.Status`) with clickable **`[F] fire` / `[R] reload` / `[?]`** (change cell).
- **Perceived vs full (global toggle in the top menu, 👁).** Panels default to what the player PERCEIVES;
  the toggle reveals full/debug info. Icons: the mod sends the full tile + a perceived override
  (`tileP/colorP/detailP/glyphP` via `GameObject.RenderForUI()`) **only when `!Understood()`**, so an
  unidentified artifact shows Qud's "unknown" icon; `QudTiles.texture_for(obj, full)` picks. Text: Target
  shows the wound WORD by default, exact HP only in full.

## Driving Qud from the UI

- **Buttons drive Qud over the bridge.** Client → `send_command("command", {command})` (e.g. `CmdFire`)
  which the mod injects via `Keyboard.PushCommand` (binding-independent), or `send_command("itemaction",
  {item, command})` → main-thread `InventoryActionEvent.Check` (e.g. `ReplaceSocketCell`). `F` in Raves =
  fire (a Raves keybind being retired for Qud's own controls).
- **Command bar (row 5, `CommandBar.gd`).** The player's activated abilities in Qud's bar order
  (`ActivatedAbilities.GetAbilityListOrderedByPreference`; do NOT filter on `Visible` — it defaults false
  and `AddAbility` never sets it). Each: name + state-appropriate UI-tile icon + `[on/off/cd]` + `<hotkey>`,
  name clickable to activate (the ability's `Command`). Far-left **Ⓐ Abilities** button = `CmdAbilities`
  (Qud's `a` menu).
- **Direction picker (for abilities that prompt, e.g. Make Camp = `CommandSurvivalCamp`).** Qud's
  `PickDirection` **blocks the turn thread** waiting for a LeftClick at a CELL. Clicking the ability starts
  `Main.start_direction_picker(icon)`: the ability icon becomes the cursor over the Holodeck, the mouse→cell
  ray (reusing the inspector's mapping) finds the tile, clicking an adjacent one sends `send_command("dir",
  {x,y})` → `PushMouseEvent("LeftClick", x, y)` (Qud derives the direction), a non-adjacent/right-click/Esc
  sends `dircancel` → RightClick (Qud must be UNBLOCKED or it freezes). **Gated to known direction commands**
  (`CommandBar.DIR_ABILITIES`) so we never orphan a blocked prompt. Picker input is handled in `Main._input`
  (the frame's containers eat clicks before `_unhandled_input`).
- **Off-turn refresh after a prompt.** `PickDirection` blocks and Make Camp costs no turn, and render-tied
  `TickRender` (BeforeRender) does NOT fire while Qud is unfocused — so a `dir`/`dircancel` sets
  `Bridge.ForcePublishSoon`, flushed on **`BeginTakeActionEvent`** (a TURN-thread event that fires each
  player action even unfocused). Then the renderer must notice the new object: **live STATIC geometry is
  frozen per zone** (only creatures rebuild per step), so `ZoneRenderer` rebuilds static when a cheap
  **static signature** (`_static_signature`, static objects only) changes — that's what draws a placed
  campfire without leaving the zone.

## Text, input, and enabling the 3D

- **Qud markup** (`{{code|text}}` spans AND running `&X` foreground / `^X` background) is handled by the
  shared **`QudText`** util (`to_bbcode(s, palette)`, `strip(s)`). Messages/nearby names render coloured;
  status-bar name/biome are stripped. The palette (code→hex) rides each snapshot.
- **Input:** Main renders into the ROOT viewport, so it receives keyboard directly via its own
  `_unhandled_input` (the chrome's menu buttons are focus-less, so they never swallow keys). One keypress →
  one delivery → one step. Do NOT re-add key forwarding. (The old SubViewport path needed a no-forward rule
  to avoid double-stepping; full-window has no such duplication.)
- **Enabling the Holodeck — still TWO stages (data-first), but no SubViewport dance:** `Connect (data)`
  instances `Main` into the root viewport with **`Main.render_3d = false`** — `_on_snapshot` skips ALL 3D
  build/render, so the bridge + status bar + panels run with ZERO GPU work, and only the empty 3D world
  (sky) shows in the hole. `Turn on viewport` calls `set_render_3d(true)`, which builds + renders the
  current zone into the root viewport — the exact path standalone `Main` always used, so there is **no
  separate Metal render target to overrun** (that was the crash). The two stages remain because data-first
  is cheap insurance: it keeps the data view provably independent of the 3D. The old SubViewport mitigations
  (quarter-res `stretch_shrink`, `_present_viewport` timer) are gone with the SubViewport itself. If a crash
  somehow recurs, capture it via the dev editor (see [`decisions/debugging-lessons.md`](decisions/debugging-lessons.md)).

## When a snapshot is sent (the bridge cadence)

`BridgePart` hooks two Qud events: `EndTurnEvent` → `Bridge.Tick` (per turn) and `BeforeRenderEvent` →
`Bridge.TickRender` (every rendered frame while Qud is focused). A snapshot (`ZoneSnapshot.BuildJson`, a
full zone scan) publishes via `PublishNow`, rate-limited to `PublishThrottleMs` (~15/sec). Triggers:

- **Turn-based** (`Tick`) — any action that ends a turn. Always publishes (throttled).
- **A command Raves drove** — split by kind (see the [command table in `docs/protocol.md`](protocol.md)):
  input-queue commands (`move`/`wait`/`key`/`command`/`dir`) **wake an unfocused Qud** through its input
  queue and are observed after Qud processes them (usually a turn snapshot). Queued
  mutation/export/screenshot (`become`/`zoo`/`shot`/`itemaction`/`export`/`setoption`) run only when a Qud
  event hook next drains `Incoming`, and a screenshot then completes asynchronously on Unity's UI queue.
  **Don't promise an immediate response or a per-command ack.**
- **Zone change** (`Tick` + `TickRender`) — walk over an edge, soar/descend, travel → forced past the throttle.
- **No-turn reactive refresh** (`TickRender`) — `BuildSignature` fingerprints the observed state ~10×/sec
  (`SigCheckMs`); any change marks it dirty and the throttle republishes. This is what makes targeting (and
  other no-turn changes) show without a move. The signature covers: **combat target**, **player HP**,
  **position**, **level/XP**, **active effects**, **message count**, **body temperature**, **zone**.
  **To make more things reactive, add the signal to `BuildSignature` — nothing else changes.** Keep each
  read cheap + guarded (it runs 10×/sec); never do a zone scan there.

The mod is INERT with no client connected (gated on `server.ClientCount`), so solo Qud is unaffected.

## Threading model

The single most important thing to internalise, because it dictates everything:

**Qud runs its turn logic on a dedicated BACKGROUND thread** (`XRLCore._ThreadStart` → `RunGame` →
`ProcessSingleTurn`), *not* Unity's main/render thread.

- **Reading game state** (Zone, Cell, Render, GameObject) is safe on that turn thread — that's where the
  objects live. `EndTurnEvent`, and thus `Bridge.Tick`, fire there. Qud's whole event system runs on the
  turn thread — even `BeforeRenderEvent` fires there, not the main thread.
- **Any Unity graphics call** on the turn thread (`Texture2D` ctor, `Graphics.Blit`, `ReadPixels`,
  `SpriteManager.GetUnitySprite`) → **"Graphics device is null" → an uncatchable native crash.**

So the mod is split by thread:
- **Turn thread** (`Bridge.Tick` via `EndTurnEvent`): read the zone, serialize JSON, enqueue tile-export
  requests, publish over the socket. **No Unity graphics, ever.**
- **Main thread**: tile export runs here via `GameManager.Instance.uiQueue.queueTask(...)` — the only place
  graphics calls are legal.

The socket server (`BridgeServer.cs`) is pure .NET on its own background threads. The reader parses **every**
command, but they take **two different paths** (this is the part that misleads if you skim it):

- **Consumed inline in `OnPayload`** (on the socket-reader thread): `move`, `wait`, `command`, `dir`,
  `dircancel`, `key`. These only push into Qud's **locked input/event queues** (`Keyboard.Push*`), which is
  thread-safe and wakes the turn thread even while the window is unfocused.
- **Placed in `BridgeServer.Incoming`** and drained by `Tick`/`TickRender` on Qud's **turn/event thread**:
  everything else (`shot`, `become`, `zoo`, `catalog`, `export`, `setoption`, `itemaction`). Unity **graphics**
  work (screenshot capture) is then a *third* step, marshalled to Unity's main thread via `uiQueue`.

So "queued" ≠ "runs immediately while Qud is idle." A cheap crash-proof main-thread guard:
`SynchronizationContext.Current is UnitySynchronizationContext` is true **only** on the main thread.

## Platform constraints (macOS / Apple Silicon)

| Constraint | Consequence |
|---|---|
| Turn logic is off Unity's main thread | Graphics on the turn thread crashes hard — marshal to main thread via `uiQueue`. |
| **Harmony is blocked on Apple Silicon** (`mprotect EACCES`) | Runtime method-patching doesn't work; use Qud's own events, not patched `LateUpdate` etc. |
| Tiles are packed in Unity-6 atlases, not loose PNGs | Can't point Godot at files on disk — extract via the running game (below). |
| Exported tile files are PNG content even when named `.bmp` | Godot's `Image.load_from_file` picks the loader by extension and fails; read bytes + `load_png_from_buffer`. |
| String-grepping `Assembly-CSharp.dll` lies about casing | It reported `Render` fields lowercase; they're capitalized. Reflect with `MetadataLoadContext` for ground truth. |

## Tile extraction (engine-assisted)

Qud has **~44,525 tiles** packed into a few dozen Unity-6 atlas pages, with a path→rect lookup baked into a
MonoBehaviour. Decoding atlases offline is fragile — so we don't. **The running game already has the atlas
loaded; the mod asks it for pixels:**

1. Turn thread (`TileExporter.Ensure`): dedupe + enqueue the tile path. **No Unity calls.**
2. Main thread (`TileExportPump.Export`, via `uiQueue`): `Kobold.SpriteManager.GetUnitySprite(path)` →
   `sprite.texture` (atlas) + `sprite.textureRect` → scaled `Graphics.Blit` of just that rect into a small
   `RenderTexture` → `ReadPixels` → `EncodeToPNG` → write to `<support>/tiles/`.
3. On-demand (per distinct tile seen), cached, resumable. The snapshot carries `tilesDir`.

**Force-export tiles that never occur naturally** (e.g. the isolated wall variant for a fully-bordered top):
`TileExporter.Ensure("Assets/Content/Textures/Tiles/wall_rock-00000000.bmp")` — the atlas has all 256
autotile variants regardless of what's placed in a zone. Tile path → filename: replace `/ \ :` with `_`;
content is always PNG.

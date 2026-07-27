# Gotchas & Checklists

Non-obvious rules that bite, and what to verify when adding a kind of thing. Most entries here cost a
round-trip to learn — the point is to never pay for them twice. Keep it current: when a new quirk bites,
add a one-liner (symptom → rule).

---

## Part 1 — Invariants (symptom → rule)

### Qud internals
- **Unfocused Qud runs only the TURN thread.** `BeforeRenderEvent` (→ `Bridge.TickRender`) does NOT fire
  while Qud's OS window is unfocused (the normal "watching Raves" case); `EndTurnEvent` (→ `Tick`) and
  `BeginTakeActionEvent` (→ `TickAction`) DO. *Symptom:* an off-turn change never shows until you move.
  *Rule:* any off-turn publish must be flushed from a turn-thread event.
- **`PickDirection` (Make Camp, targeting) BLOCKS the turn thread** until it gets a raw direction key OR a
  `LeftClick` at a CELL. A forwarded `CmdMove` does NOT answer it. If a prompt opens and is never answered,
  **Qud freezes.** *Rule:* only open the picker for abilities you KNOW prompt, and always have a cancel path
  (`dircancel` → RightClick) so the prompt can't be orphaned.
- **Activated-ability `Visible` defaults FALSE** and `AddAbility` never sets it — don't filter on it or you
  drop every ability. Use `ActivatedAbilities.GetAbilityListOrderedByPreference`.
- **Perceived vs full is hidden info — including the TILE.** Use `GameObject.RenderForUI()` for a panel icon
  (unidentified → Qud's "unknown" icon), `Strings.WoundLevel` / `Description.GetFeelingDescription` /
  `GetDifficultyDescription` for target text. Raw `Render`/`hitpoints` is the full/debug view only. See
  the perceived-vs-full memory.
- **A placed object's LIGHT can attach a snapshot AFTER its sprite appears** (a just-made campfire lights
  up next tick). Anything keyed on "the object appeared" must also react to "the object lit up."
- **API details, always decompile — don't guess.** `pPhysics` is obsolete (use `Physics`); liquid ids are
  lowercase; AV/DV/MA need `Stats.GetCombat*`, not `GetStatValue`; `PushMouseEvent("LeftClick", x, y)` takes
  CELL coords. `dotnet build mod/…csproj` fails on a wrong name before the user ever runs.

### Renderer (ZoneRenderer)
- **LIVE STATIC geometry is built ONCE per zone and frozen** — walls, furniture, sprites, lights. Only
  creatures rebuild per step. A new/changed static object won't render mid-zone unless `_static_signature`
  changes, and that signature must include every state that matters (name AND `lightRadius`, since light lags).
- **`_static_signature` must EXCLUDE volatile objects, or a rebuild fires every step.** It excludes ground,
  creatures, and **liquids** (`obj.liquid`, set from `GameObject.LiquidVolume`). A wet player's wading sloshes
  water pools onto every cell they cross; if liquids counted, the signature changed each step → the frozen
  zone dropped+rebuilt (far→near incremental) mid-walk → "foreground tiles vanish until you stop." Only
  genuinely PLACED structures (campfire, dug wall) should trigger a rebuild. Adding a new object CLASS that
  moves/spreads/decays each turn? exclude it here too, or verify it can't appear on a cell the player traverses.
- **"Light" in Raves is the per-cell DARKNESS OVERLAY** from Qud's light map (`cell.light`), not real 3D
  lights (the world is UNSHADED). A campfire/torch glow is additive geometry placed in the static build.
- **Billboard parallax:** a flat `y=0` ground ray overshoots standing sprites at the low camera angle. The
  inspector's `_pick_cell` marches back to the occupied cell; the direction picker wants the literal ground cell.

### Bridge / snapshots
- **Snapshots fire on:** EndTurn (throttled), a Raves-driven command (immediate), a zone change (immediate),
  and the no-turn reactive signature (`BuildSignature`, ~10 Hz, focused only). A change that's neither in the
  signature nor turn-based won't publish — set `Bridge.ForcePublishSoon` and flush it on a turn-thread event.
- **`send_command(name, extra)` → `OnPayload` (socket thread)** for movement/command/dir/key — this path can
  wake an *unfocused* game. Main-thread-only work (itemaction, become, zoo, shot) is enqueued to `Incoming`,
  drained by Tick/TickRender.

### Godot / the frame
- **Mouse clicks over the Holodeck are eaten by the frame's container Controls** before `_unhandled_input`.
  Handle Holodeck mouse in **`Main._input`** (fires before GUI). Keyboard is fine in `_unhandled_input`
  (focus-less menu buttons don't swallow it). This bit the **inspector**: Ctrl/Cmd+click → `_inspect`
  sat in `_unhandled_input` and silently stopped working once the Holodeck was embedded (hover+**I**, a
  keyboard path, still worked — the tell). Any NEW Holodeck mouse gesture (inspect, pick, a future
  click-to-target) goes in `_input`; only the camera's own MOUSE-mode orbit/pan/wheel stays in `_unhandled_input`.
- **`var x := load("res://Y.gd").new()` won't parse** (`load()` is typed `Resource`, has no `.new()`) — declare
  the member typed, assign in `_ready`. **`var x := dict.get(k)` won't parse** either (can't infer from
  `Variant`) — annotate the type (`var x: Array = ...`).
- **Full-window Holodeck renders into the ROOT viewport**; the day/night MULTIPLY grade must sit on a
  NEGATIVE `CanvasLayer` so it tints only the 3D, not the chrome.
- **The exported app writes NO `godot.log` / crash report** (ad-hoc signed). Trace via a file under
  `InputModel.support_dir()` (`~/Library/Application Support/RavesOfQud`), or run the dev editor.

---

## Part 2 — Checklists (adding X → verify Y)

### A new snapshot field / status
- [ ] Emit in the right `Write*` (`ZoneSnapshot.cs`); read in `MainFrame._apply_stats`.
- [ ] Perceived vs full? gate exact/hidden data behind the 👁 toggle (`set_full_info`).
- [ ] Should a change refresh Raves *without a turn*? add a cheap signal to `BuildSignature`.

### A new panel / view
- [ ] Its own scene (`.gd`), fed from `_apply_stats`; render markup via `QudText`, tiles via `QudTiles`
      (don't re-inline the colour table / recolour).
- [ ] Honour the 👁 perceived/full toggle if it shows icons/stats (`set_full_info`).

### A placeable / changeable world object (campfire, dug wall, dropped item)
- [ ] Will the renderer see it mid-zone? it must change `_static_signature` — include any state that matters
      (name, `lightRadius`, …).
- [ ] Does the change happen off-turn? `ForcePublishSoon` + a turn-thread flush (`TickAction`).

### A new interaction (click / prompt / targeting)
- [ ] Holodeck mouse → `Main._input`, not `_unhandled_input`.
- [ ] Does the Qud command BLOCK (PickDirection / targeting)? gate it to known commands, and ALWAYS provide
      a cancel path or Qud freezes.
- [ ] Answer `PickDirection` with a LeftClick at a cell (`dir`) — Qud derives the direction; cancel = `dircancel`.

### A new ability in the command bar
- [ ] No `Visible` filter. Does it prompt for a direction/target? add its command to
      `CommandBar.DIR_ABILITIES` so the picker opens (and only then, or Qud can be left blocked).

### Every mod change
- [ ] `dotnet build mod/…csproj` first (catches API drift). Deploy = copy `.cs` + **full Qud restart**.
      Client-only `.gd` changes need no restart.
- [ ] Run the author guard before every push: `git log --all --format='%ae' | grep -i allspice` (must be empty).

# Gotchas & Checklists

Non-obvious rules that bite, and what to verify when adding a kind of thing. Most entries here cost a
round-trip to learn — the point is to never pay for them twice. Keep it current: when a new quirk bites,
add a one-liner (symptom → rule).

## Fast lookup (symptom → first check)

| Symptom | Likely cause | First check | Section |
|---|---|---|---|
| A change never shows until you move the player | unfocused Qud runs only the turn thread — `TickRender` doesn't fire | is Qud's window unfocused? did a turn actually end? | Qud internals |
| Deployed a fix but nothing changed | mod `.cs` only compiles at Qud **startup** — a stale build is running | `Protocol.Build` in the snapshot / inspector | Qud internals |
| A placed object (campfire, wall) doesn't draw | static geometry is frozen per zone; the static signature didn't change | did `_static_signature` change? | Renderer |
| Can't move after an ability prompt (Make Camp) | a focused clickable UI over the Holodeck swallowed the arrows | is that control `FOCUS_NONE`? | Godot / the frame |
| Can't move after clicking a PANEL (row 4 / sidebar) | `selection_enabled` RichTextLabels grab focus on click — same wall | selectable text needs `FOCUS_NONE` + selection OFF (the command-bar fix, applied to all panels in db39608+1) | Godot / the frame |
| "Crash" but no crash report written | it's a **hang** (GPU timeout / fillrate), not a crash | is there a fresh `Godot-*.ips`? if not → hang | Renderer |
| Headless run is "fine" but the windowed app crashes | `--headless` uses a dummy driver — never touches Metal | run a real windowed build to prove a render path | Renderer |

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
- **API details, always decompile — don't guess.** `GameObject.Physics` is the reflected field to prefer
  for new code; `pPhysics` is a legacy convenience accessor **still compiling** (the mod uses
  `player.pPhysics.Temperature`) but marked obsolete by the assembly (`CS0618: Use Physics`) — don't assume
  one swaps for the other without compiling against the shipped DLL. Liquid ids are lowercase; AV/DV/MA need
  `Stats.GetCombat*`, not `GetStatValue`; `PushMouseEvent("LeftClick", x, y)` takes CELL coords.
  `dotnet build mod/…csproj` fails on a wrong name before the user ever runs.
- **Driving Qud's MENUS / character creation from outside = MOUSE, not keys** — Qud (Unity) drops synthetic
  keyboard events pre-game and exposes no accessibility tree for its menus. But the **click shape is
  surface-specific**, not one universal recipe: plain Unity buttons + world cells take a **bare** click (no
  pre-move, no `kCGMouseEventClickState`); legacy console popups and the **title menu** need a **hover**
  (a pre-move event) first — try bare, then hover when the highlight doesn't move. Highvisor's `hv click
  [--hover]` implements this verified matrix; full write-up in highvisor `docs/05-driving-input.md`.
  *Symptom of the wrong shape:* the menu highlight follows your cursor but clicks never activate. In-GAME,
  keep using the mod's `PushCommand`.

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
- **`cell.light` is Qud's per-cell DARKNESS/visibility OVERLAY, not Godot lighting** — the two are
  different things; say which layer you're changing. World walls and ground **are** per-pixel shaded today
  (`ZoneRenderer.SHADED_WORLD = true`); many sprite/effect materials remain unshaded or additive. A
  campfire/torch glow is additive geometry placed in the static build.
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
  `Variant`) — annotate the type (`var x: Array = ...`). Same trap comparing a Variant loop var:
  (Colour-precedence copies: `_pick_color_string` is THE rule — a site deriving main colour as
  "tilecolor else color" also poisons the MATERIAL cache key: a compound '&c^C&K' pool collided
  with a plain '&c' pool and served the wrong material. Grep for `get("tilecolor"` when adding
  colour paths.)
  `var up := key == "up"` fails when `key` iterates an untyped Array — `var up: bool = ...`.
  **After editing ANY `.gd`, run `--check-only --script res://<That>.gd`** — the headless boot check
  only deep-parses scripts it loads, and a broken `MainFrame.gd` shipped as a BLANK title screen
  (MainMenu references it) with `--quit-after` still printing clean.
- **Full-window Holodeck renders into the ROOT viewport**; the day/night MULTIPLY grade must sit on a
  NEGATIVE `CanvasLayer` so it tints only the 3D, not the chrome.
- **The exported app writes NO `godot.log` / crash report** (ad-hoc signed). Trace via a file under
  `InputModel.support_dir()` (`~/Library/Application Support/RavesOfQud`), or run the dev editor.
- **Per-screen colour compensation differs.** `QudChrome.q8` (×1.13, Records-fitted) OVERSHOOTS on the
  Control Mapping screen — capture-fitting its solids gave `captured ≈ drawn − 6` above the dark knee
  (`ControlMappingScreen._cm8`, +6/channel). Fit each new screen from its OWN solid fills (border/bg),
  not glyph edges, before trusting either curve. Also: Qud's "letterspaced" headers are NOT tracked —
  they're the SEMIBOLD face at a bigger size (SCP advance = 0.6×size explains every measured pitch).
- **Main's Esc handler runs before overlay screens** (`_unhandled_input` is reverse tree order; the
  Holodeck is the LAST child). Frame overlays (status screens, control mapping) must be reflected in
  `Main.overlay_check` or 1:1 Esc ALSO fires `CmdSystemMenu` at Qud underneath the overlay's own close.
- **Qud modal answers: mirror menu picks by TEXT, not index.** `PopupOverlay` rides the picked option's
  stripped text along in the answer payload (`popup_option` signal); the text keeps its hotkey prefix —
  match `ends_with("control mapping")`, not equality.
- **`KeybindsScreen` needs the `uiback` Exit() special-case** (inherited `OnCancel` is a no-op, same as
  `StatusScreensScreen`), and its `async void Exit()` only COMPLETES while Qud's main loop runs — an
  unfocused Qud stays on the screen until next activation (the heartbeat scene flips then, not before).
  Worse: while it (or any modal screen) is up, TURNS ARE BLOCKED — "my remapped key does nothing" was
  Qud parked on Keybinds. The uiback handler now pumps Unity's SynchronizationContext (private `Exec()`,
  reflection) after invoking Exit so the close chain resolves unfocused; macOS stops draining those
  continuations for a backgrounded window even with `runInBackground=true` (turns + uiQueue keep running).
- **A Control Mapping remap only works in Raves via `QudBinds.gd`** — Raves' in-game keys are hardcoded;
  the custom-bind fallback (end of Main's key chain) routes unclaimed combos to Qud's command executor.
  Movement keys the `match` just handled MUST bail before the fallback or they double-send. Bare digits
  in Qud's display strings are ambiguous (numpad7 renders "7") — match both keycodes.
- **`hv restart raves` relaunches via the `raves_solo` launcher = `--one-to-one` LOCKED** (highvisor
  apps.py profile) — every restarted instance is 1:1 regardless of settings. User-mode testing needs the
  `raves_user` launcher (no flag, in ~/.config/highvisor/launch.json). The lock used to leak into
  settings.json via `_on_one_to_one_changed` persisting it (making unflagged launches come up 1:1 too) —
  now guarded; `UiState` reports the EFFECTIVE mode (`Settings.one_to_one()`), not the stored value.

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

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
- **AtlasTexture regions are IGNORED by 3D materials** — `StandardMaterial3D.albedo_texture`
  samples the WHOLE atlas (measured: the signpost quad showed the entire tile, dark fill and
  all). To texture 3D geometry with a sub-rect, crop for real: `img.get_region(...)` ->
  `ImageTexture.create_from_image(...)`.
- **Godot popups are NATIVE OS windows unless `embed_subwindows=true`** (now set in project.godot):
  a native OptionButton dropdown is invisible to `hv ls` and un-clickable by `hv click`. Embedded,
  the popup still selects only via KEYBOARD from the harness (open, then plain `hv key raves DOWN
  ... RETURN` — no `--focus`, activate closes it; the popup opens unfocused so the FIRST down lands
  on item 0). Posted clicks close it without selecting — drive dropdowns by keys.
- **Cap-gap grids differ in size BETWEEN cells — never index a neighbour's grid with your own
  dimensions.** `_wall_split` is per-variant: a couple of opaque frame pixels in the separator row
  push it to the fallback (metal: 15 variants at 13 cap rows, 93 at 14; brinestalk 15), so the
  seam pass sampling the neighbour's edge with MY row count walked off the end — a silent runtime
  error in the exported app that aborted the seam mid-cell and left holes at wall boundaries.
  Sample by scaled index (`i * nb_h / hh`), like the cap az mapping.
- **Tile files are PNG BYTES regardless of the .bmp extension** (Qud's naming quirk), and every
  loader reads them as PNG. An external tool that honours the extension (PIL `im.save(path)`)
  writes a REAL BMP — `_mask` then fails silently and wall faces fall back to each cell's own
  stock band ("roof pattern on the side"). Write `format="PNG"` explicitly; `_mask` now also
  accepts genuine BMP bytes as a backstop.
- **Wall CUSTOM art is as-authored; transparent = carve.** `_cap_tex`/`_wall_region_tex` skip
  the mask recolour for tiles_custom files and fill transparency with the wall bg — which IS the
  carve predicate. The custom watch must clear `_wallmat_cache`/`_cap_gap_cache`/`_voxel_cache`
  (`_wall_caches_clear`) or edits go stale; overrides re-parse clears them too (core colour).
- **Walls are ONE watertight voxel volume per cell** (`_wall_cell_mesh`; proven in
  `tools/capture/voxwall.py` — run it after any wall-builder change). Full block, cap art carves
  the roof, face art carves exposed faces, carves never enter the shell beside a wall neighbour.
  Do NOT reintroduce separate skins/cores/patch passes: every historical see-through, z-fight and
  Escher bug lived in the gaps between those pieces.
- **A wall variant's art band below `_wall_split` is a real elevation ONLY when that variant's own
  face is open** — heavily-connected variants (`-11111111` and friends) are pure interior fill,
  measured one flat colour per row. Cropping a per-cell "effective" variant's band onto side faces
  dressed walls in the cap pattern ("some of the walls look like the ceiling"). Side art is per
  FACE: `_face_variant` picks from the four horizontal-run tiles (own face open, only the art-E/W
  continuation bits set), and the continuation bits follow the ROTATED art axis, not world E/W
  (+90° about Y maps art +x onto −Z).
- **Never gate STATIC placement on the live camera** (`_top_down` etc.) — statics build once per zone
  and a camera-state gate bakes that moment's answer in forever. Place camera-independently and toggle
  VISIBILITY at runtime (the depth-halo experiment hit this; the halo is reverted, the rule stands).
- **1:1 runs must not write user-view state.** `Main._save_settings` returns early in `one_to_one()`:
  a parity run's TOP_FOLLOW leaked into `user://raves_settings.json` as `mode: 6` and every user-mode
  launch restored a top-down renderer the user never chose (symptom: depth halos placed hidden,
  Options camera "ignored"). The `win` key had the same bug earlier; the guard now covers the file.
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
- **The Quests and Journal maps are DIFFERENT TEXTURES**, despite being the same world. RefreshMap
  dims every cell outside `highlights`; Quests passes the quest locations (so most of the world goes
  dark) and the Journal passes null (nothing dims). One shared file drew the Quests' dimmed map
  inside the Journal's panel. Export per screen.
- **Pick the screen by NAME, not by `Visible`, and find it by COMPONENT, not `.instance`.** The
  status screens are tabs of one StatusScreensScreen, so the Quests instance still reports visible
  while the Journal tab is showing — a first-visible-wins check wrote the Quests map twice and the
  Journal's never. And `JournalStatusScreen.instance` is null even when the screen exists;
  `FindObjectOfType` finds it.
- **With nothing selected the map centres on the PLAYER's parasang**, not the texture's middle.
  Defaulting to the middle put Raves several parasangs from Qud's view, looking at forest while Qud
  showed Joppa's salt marsh.
- **The status screens' WORLD MAP is a texture Qud already built — export it, don't re-render it.**
  MapScrollerController.RefreshMap walks all 80x25 cells of `JoppaWorld`, renders each through a
  RenderEvent and blits its recoloured sprite into a **1280x600** texture (16x24 per cell), then the
  UI draws that at **2x** inside a 724x744 viewport, scrolled to the target. Reproducing it means
  reproducing Qud's whole world-map render -- terrain choice, per-cell colour, exploration state --
  forever. `mapTexture` is private but `mapImage.sprite.texture` IS it, and it is CPU-readable
  because RefreshMap builds it with `new Texture2D(...)`. It only exists once the screen has
  RENDERED, so the export has to run with the screen live.
- **The mod's uiQueue does NOT drain while Qud's window is in the BACKGROUND.** Measured with a
  `uiprobe` command: backgrounded it logged nothing at all; focused it ran instantly. So EVERY
  uiQueue-marshalled command (`uiback`, `uiprobe`, `statusscreen`, the chrome exporters) is
  accepted, queued, and silently deferred until focus returns. Comments in this repo claiming the
  uiQueue keeps running unfocused are wrong -- what keeps running unfocused is the TURN thread.
  highvisor's `_qud_bridge` now activates Qud and waits 2s before sending.
- **`PumpSyncContext` never worked.** It looked up `UnitySynchronizationContext.Exec` with
  `BindingFlags.NonPublic` only -- but `Exec()` is PUBLIC on that internal class, so the lookup
  always failed and the pump was a no-op, faithfully logging "no Exec on
  UnitySynchronizationContext" on every call while everything depending on it quietly stalled.
  Fixed to `Public | NonPublic | Instance`. Qud's log is at
  `~/Library/Logs/Freehold Games/CavesOfQud/Player.log` -- read it before theorising.
- **Snapshots fire on:** EndTurn (throttled), a Raves-driven command (immediate), a zone change (immediate),
  and the no-turn reactive signature (`BuildSignature`, ~10 Hz, focused only). A change that's neither in the
  signature nor turn-based won't publish — set `Bridge.ForcePublishSoon` and flush it on a turn-thread event.
- **`send_command(name, extra)` → `OnPayload` (socket thread)** for movement/command/dir/key — this path can
  wake an *unfocused* game. Main-thread-only work (itemaction, become, zoo, shot) is enqueued to `Incoming`,
  drained by Tick/TickRender.

### Godot / the frame
- **macOS turns Ctrl+left-click into a RIGHT-button event before Godot sees it.** The display
  server applies the platform's "control-click == secondary click" convention in
  `GodotContentView`'s `mouseDown`/`mouseDragged`/`mouseUp`; there is no project setting for it, and
  it holds for the WHOLE drag, not just the press. So any Ctrl+click binding silently runs the
  right-click branch instead — this is what broke the Map Editor's Ctrl+click paint (2026-08-08),
  and the failure presents as *the right-click and middle-click features being dead*, because
  nothing can be placed for them to act on. *Recognise it by:* `button_index == RIGHT` arriving
  with `ctrl_pressed == true`. **Disambiguate on the ctrl flag** — a genuine right-click always
  carries ctrl clear (measured). Shift and alt are NOT converted. Any new Ctrl+click gesture in
  Raves must handle the RIGHT button too, or it will not fire on the Mac.
- **A mirrored Qud MODAL eats Raves' own keys.** Qud's in-game system menu (Set Checkpoint /
  Control Mapping / Save and Quit) comes over the popup mirror and PopupOverlay is modal, so while
  it is up a Raves-local shortcut like the Tinkering Ctrl+Tab silently does nothing. Escape sent to
  Raves RAISES that menu (it is Qud's own binding), so "press Escape then try the key" is a way to
  create this, not clear it. Clear it with a popup answer over the bridge, then send the key.
- **RESOLVED: the "intermittent" status-screen openers were a STUCK MODIFIER in the harness.**
  `hv key` set the modifier as a flag on the key event and never released it, so after one
  `ctrl+tab` macOS believed Control was held and every later key arrived modified — a plain `n`
  reached Raves as Ctrl+N. Not intermittent at all: broken from the first combo onward, for every
  key, and unfixed by relaunching the app because the stuck state is in the OS. Fixed in highvisor
  (modifiers are pressed/released as real key events). *Recognise it by:* single keys stop working
  right after you first send a combo.
- **The instrument that found it: print what `_input` ACTUALLY receives.** Three separate bugs in
  this area (this one, the missing `handle_key`, and a mirrored modal eating keys) were each
  settled in one cycle by logging keycode/modifiers/visibility at the top of `_input`, after
  several rounds of hypothesis-guessing got nowhere. Reach for it first.
- **(historical) the openers once looked INTERMITTENT.** `n`/`j`/`q`/`e` opened
  their tabs reliably at one point in a session and then stopped on a fresh launch of the SAME
  build, with `hv goto raves status_*` failing its assert. Established: the keys DO reach the app
  (an `_input` trace logged the right keycode and modifiers arriving), no modal was up, it is not a
  settle-time issue (still failing after ~20s), not a focused-control issue (clicking the world
  first did not help), and it affects EVERY tab, not one. Cause still unknown -- start from the
  `_input` trace, which is the tool that settled the neighbouring bugs.
- **Raves' Continue greys out when it cannot READ QUD'S SAVES DIR — and that looks like a bridge
  failure.** `_saves_exist()` lists `~/Library/Application Support/com.FreeholdGames.CavesOfQud/
  Synced/Saves`, i.e. ANOTHER APP'S container. macOS TCC grants are per code-signature and this app
  is ad-hoc re-signed on every build, so the permission lapses after enough rebuilds:
  `DirAccess.open` returns null, 1:1 Continue disables, clicking and pressing Space do nothing, and
  Raves sits at its title while the bridge is perfectly healthy. Continue now also enables on a
  LIVE bridge game, and the failed listing warns once instead of silently reading as "no saves".
  *Symptom to recognise:* Raves at the title, Qud in-game, `qud_state.json` fresh with
  `live: true`, and NO "Raves bridge: connected" line in Raves' log.
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
- **Every scene must REPORT itself on load, not just on transitions.** `UiState` rewrites its file
  every 2s as a freshness heartbeat, so a scene that never calls `set_scene` republishes the PREVIOUS
  scene forever — `hv state` then reads fresh-but-wrong (it saw `status_skills` while Raves sat on
  the title after the lifecycle bounce, and driving clicked into the menu). `MainMenu._ready` now
  reports `title`, `set_scene` clears any popup (a modal can't survive a scene change), and the
  heartbeat sanity-checks the live scene root before republishing.
- **The reflection "sync pump" DOES NOT WORK on this build — retract any fix credited to it.**
  `Bridge.PumpSyncContext` looks up `Exec()` on the sync context by reflection. Qud's context is a
  `UnitySynchronizationContext`, which *does* declare a non-public `Exec()` in the assembly — but at
  RUNTIME `GetMethod("Exec", NonPublic|Instance)` returns null (IL2CPP strips non-public metadata on
  the Mac build; the mod logs "no Exec on UnitySynchronizationContext"). It was also pumping
  `SynchronizationContext.Current`, which is null inside a uiQueue task, so it was a double no-op.
  The `uiback` KeybindsScreen close that this pump was credited with is therefore explained by the
  nav-cancel rung, not the pump. Don't reach for it again; find a first-party path instead.
- **Qud APIs that raise a SYNCHRONOUS popup (`Popup.ShowYesNo`, `SelectNode`) must run through
  `APIDispatch.RunAndWaitAsync`, not straight from a uiQueue task** — the modal wait deadlocks and
  the call proceeds as if confirmed (a skill purchase went through on "No"). Mirror whatever wrapper
  Qud's own caller uses; here `SkillsAndPowersLine.Accept()` showed the way.
- **Answering a mirrored popup must target the ANNOUNCED instance.** Qud pools popup copies
  (`UIManager.popupMessages`, a private static Queue); a RELEASED copy stays visible with a non-null
  callback, so `FindObjectsByType` scans pick pooled ghosts and answers vanish into them. PopupBridge
  holds the instance it announced and excludes anything in the free pool. Also pump the sync context
  after answering (`Bridge.PumpSyncContext`) or an unfocused Qud won't resume the awaiting chain.
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

## Equipment tab: the cell frame is a real sprite, and the strip starts where you think it doesn't

- **The bracketed cell frame is Qud's own sprite, `polat-category-frame`** — 46x41 with Unity
  9-slice borders (left 12, bottom 11, right 13, top 12). `FilterBarCategoryButton.background`
  holds it, assigned in the PREFAB, so the name is invisible in the decompiled source; read it
  off a live instance (`TitleExporter.ExportCellFrame`). Hand-drawing the motif from a bitmap
  spec scored WORSE than the previous approximation; nine-slicing the real sprite took the frame
  leaves from ~14 to ~2.9. **Extract the sprite; don't redraw the art.**
- **The filter cells are drawn at the sprite's NATIVE 46x41** (58px pitch, 12px gap). The paper
  doll's boxes are the SAME sprite stretched to 64x64 — one design, two sizes, which is exactly
  what a nine-patch is for.
- **The paper-doll boxes are 64x64 at x{274,364,454,544,634}**, not the 55x62 at x+9 that eyeballing
  the lit area gives. Find a grid by scanning the capture for the frame's own long runs, then
  remember the runs BREAK at the two ornamented corners (top starts 9 late, bottom ends 9 early) —
  a naive "longest run" reads 9px short and lands you on the interior.
- **The strip's first cell is the "*All" button at x618**; categories start at 676. There is no
  cell at 560. Getting this wrong shifts the whole strip one pitch and silently compares every
  category icon against its NEIGHBOUR's — the frames still score well, so only the image leaves
  betray it.
- **Filter-cell colour is `FilterBarCategoryButton.LateUpdate`, verbatim:** enabled+focused
  `#FFFFFF`, enabled `#858951` (an olive, NOT gold), focused `#4A757E`, otherwise `#134F4E`.
  The catch: that method only writes `background.color` when the state CHANGES, so a button
  nobody has ever toggled keeps its PREFAB colour (~(51,80,91) on screen) and matches none of
  the four. Don't "fix" that to #134F4E.
- **Qud persists the enabled filter set with the save** (it survives a full restart), and the
  no-filter button reports as the category `"*All"`. Export it (`enabledFilters`) and strip
  `"*All"` on the client, or the list filters against a category no item has and renders empty.
- The teal stub on a filter cell's bottom line is **not in the sprite** — Qud paints it over the
  frame, filter cells only, at cell-relative (21,38), 4x3.
- When measuring the ink inside one of these cells, **inset past the corner motif (14px)**. At
  inset 6 the motif is inside the mask and every cell reports the same full-region bbox.
- **Icon sizing: read the RectTransform, don't fit the bboxes.** `FilterBarCategoryButton.icon`'s
  image is a 20x30 rect, centred (anchors+pivot 0.5), `preserveAspect FALSE`, `type Simple`, over
  a 16x24 sprite — i.e. Qud stretches the WHOLE tile 1.25x and never looks at the opaque sub-rect.
  Three successive attempts to normalise by the opaque box failed in opposite directions (small art
  too big, wide art too narrow). The "every icon is exactly 15 tall" observation that motivated them
  was an artefact of the ink threshold: an icon's dim rows land in the same 20-60 band as the scrim,
  so the measured bbox is the bright CORE, not the sprite. Fixing it took the filter icons from
  ~51 mean diff to ~4.
- **The client's fallback colour table is not Qud's palette, and one wrong entry repaints a
  whole screen.** `QudTiles.COLORS['w']` is a dark orange (0.60,0.40,0.10); Qud's real
  `colorFromChar('w')` is the khaki `#98875f` — the very value `FilterBarCategoryButton` hardcodes
  for its icons. Qud's palette normally rides on a ZONE SNAPSHOT, so a status pane built straight
  from an export file can render before one arrives and silently fall back. That looked exactly
  like run-to-run measurement noise (the same build scored 8.63 and 17.54 on the doll images).
  The export files now carry the palette themselves. **If a screen's colours are intermittently
  wrong, suspect the palette hasn't arrived before you suspect the capture.**
- **Colours belong on the wire, resolved.** `UIThreeColorProperties.FromRenderable` paints with
  `getColorChars()`, which resolves TileColor over ColorString — so exporting the raw ColorString
  and deriving client-side is a guess that comes out right for some items and wrong for others.
  The mod now exports the resolved `fg`/`dt`/`bg` chars (and the flips FromRenderable applies).
- **A matching ink BBOX is not the objective.** Nudging the doll tile +1px in x made every bbox
  line up with Qud's exactly and TRIPLED the pixel diff (16 -> 52): the bbox disagreement was a
  one-column dim edge. Score on pixels; read bboxes as a diagnostic only.

## Equipment tab, round two: the doll label, natural weapons, and TWO list font sizes

- **The primary-limb star is part of the label string, not a separate glyph.**
  `EquipmentLine.setData` builds `"{{G|*}}" + GetCardinalDescription()`, so the star wraps and
  centres WITH the text. Drawing it at a fixed offset left of the cell is what made it collide
  with a short first line ("Left Hand" put the L on top of the star). It is GREEN, not gold.
- **`DefaultBehavior` DOES render in the doll** -- `Equipped ?? DefaultBehavior`, and when it
  falls through it renders `GreyOutForUI()`'d, which just forces both tones to `K`. That is why
  a mutant claw shows as a dark teal ghost. An earlier note here claimed Qud leaves those slots
  empty; that came from a parity leaf reading 0 ink, **which is exactly what a brightness-
  thresholded ink mask reports for a sprite painted in `K`**. A dark sprite is invisible to the
  ink mask -- never read "0 ink" as "nothing there" without looking.
  (Qud greys the same way when an item spans several parts and this is not the first of them.)
- **The inventory list is drawn at TWO font sizes**, which is easy to miss because both row kinds
  share a 26px pitch: a CATEGORY name's glyphs advance 13.3px, an ITEM name's advance 9.75px --
  size 22 and 16 through the 0.6*size letterspacing. The hotkey column stays at 16 in both. No
  amount of column nudging lines up a row whose glyphs are the wrong size; measure the advance of
  a REPEATED letter ("Data" gives you three) before touching any x.
- Row icons follow the same 20x30 law as the filter bar and the doll (`InventoryLine.icon`),
  left-anchored rather than centred. We had them at 13x19.
- **Glyph ink starts are not advances.** Comparing "where does the ink of `[` begin" between apps
  measures the left bearing, not the layout; only same-character runs give a real advance.
- **A category row is ONE colour for all three of its parts, and it lives on the PREFAB.**
  `InventoryLine` does `categoryLabel.SetText(categoryName)` with no markup, so nothing in the
  source tells you the colour -- read it off a live instance like a RectTransform.
  `categoryLabel`, `categoryExpandLabel` and `categoryWeightText` are all
  `RGBA(0.231, 0.365, 0.443)` at alpha 1, which grades to (52,83,102) on screen. Our `{{c|}}`
  cyan rendered (56,154,176). Sampling the capture alone cannot tell you this: a sample cannot
  separate a dim colour from a bright one at low alpha, and the probe reports alpha directly.
- **Draw Qud's raw source colour; do not push it through `_iv8` first.** The helper's flat +6
  landed the category label at (51,79,97) against Qud's (52,83,102), while drawing Qud's own
  (59,93,113) matched exactly -- Raves grades Qud's source the same way Qud does.
- The category weight column is part of the category ROW's style: same colour AND same size as
  its name (ink 20px tall, 96px wide), not the item size. Right-aligning it on CAT_W_EDGE lands
  the ink 7px short, because the trailing `|` carries a right bearing.
- **A leaf that does not span the row cannot score the row.** `list_cat` was 420px wide and
  stopped at x1275, so the weight column at x1578-1673 was never in it -- changes there moved
  no number at all.
- **Item rows: `text` and `hotkeyText` are RGBA(0.690, 0.780, 0.760); `itemWeightText` is the
  SAME (59,93,113) as the whole category row.** Read off the live InventoryLine, like the rest.
- **...but for the ITEM_FONT text those are not the values to DRAW.** At 16px the glyph stems are
  thin enough that anti-aliasing decides the result, and Godot's rasteriser reaches nearer to full
  colour than Qud's. Qud proves it against itself: the item weight and the category name carry the
  identical (59,93,113), yet the category renders (52,83,102) at ROW_FONT and the weight only
  (40,67,81) at ITEM_FONT. So the three ITEM_FONT colours are FITTED to land Qud's rendered ink
  (name (147,171,166), weight (46,74,89), hotkey (139,164,160)) while every ROW_FONT colour stays
  Qud's literal value, which matches exactly. Same concession as the 2.5x sprite phase.
- Even at one size the fit is per-element: the hotkey and the name carry the same source colour and
  still render 9 apart, because ")" is thinner than a letter.
- **Sample a colour down a whole COLUMN, not off one row.** "b)" is two glyphs: it gave n=2 and a
  reading 16 off the truth, which sent one round of fitting the wrong way. The same column over all
  rows gives n>300 and a stable answer.

## The item interaction popup: drive QUD'S menu, don't build one

- `InventoryAndEquipmentStatusScreen.HandleSelectItem` answers a selection with
  `EquipmentAPI.TwiddleObject` (namespace **Qud.API**) inside `APIDispatch.RunAndWaitAsync`.
  TwiddleObject raises the option list, applies the choice and runs every follow-on prompt
  itself -- and our popup mirror already forwards Qud's modals. So the whole menu, with the
  right verbs per item and the right side effects, costs one bridge command. Same reasoning as
  the Skills tab's SelectNode.
- **...but copy Qud's THREAD, not just its call. `APIDispatch` is the wrong wrapper for a
  BRIDGE-driven twiddle, and it made the item menu answer itself 6 times in 8** (2026-08-08).
  `APIDispatch.RunAndWaitAsync` runs its delegate on a THREADPOOL thread (`Task.Run`). That is
  right for Qud's caller -- the status screen has already parked the turn thread -- and wrong
  for ours, because a twiddle driven over the bridge leaves the turn thread free and spinning
  in `XRLCore.PlayerTurn`'s wait-for-input loop. That loop, and `ActionManager.RunSegment`,
  each run `GameManager.Instance.CurrentGameView = Options.StageViewID;` unconditionally on
  every iteration. The chain from there is exact and none of it is visible from outside Qud:
  - `Popup.PickOption` shows the menu by PUSHING the `PopupMessage` game view;
  - the next loop iteration slams `CurrentGameView` back to `Stage`;
  - `GameManager.UpdateView` applies it and re-hosts the canvas, hiding the popup window;
  - `PopupMessage.Hide()` fires `onHide` -> `TaskCompletionSource.TrySetCanceled()`;
  - the `complete.Task.Wait()` inside `Popup.WaitNewPopupMessage` throws -- and that method is
    **`async void`**, so the exception is swallowed by the state machine and never reaches
    `PickOption`, which returns its untouched local `SelectedOption`. That local is initialised
    to **`DefaultSelected`**. So a CANCELLED popup returns the HIGHLIGHTED ROW, and
    `TwiddleObject` performs it (cloth robe: `equip (auto)`, which is why the item kept
    toggling pack/body and the "next" menu legitimately had 6 options instead of 8).
  Whether it fires is a race with where the turn thread is: if the Stage assignment lands
  *before* `UpdateView` ever applies `PopupMessage` there is no transition and the popup
  survives, which is the 2-in-8 that looked fine.
  **The fix is Qud's own pattern for exactly this situation** -- a UI window asking for an item
  menu with the game idle -- `NearbyItemsWindow.OnSelect`:
  `GameManager.Instance.gameQueue.queueSingletonTask(id, () => EquipmentAPI.TwiddleObject(go))`.
  The gameQueue drains inside `Keyboard.getvk(..., pumpActions: true)`, the turn thread's own
  input wait, so TwiddleObject runs ON the turn thread with that loop inside it rather than
  racing it. It is also the thread `WaitNewPopupMessage` is written for: off the UI thread it
  takes the blocking `uiQueue.awaitTask` branch the popup mirror already answers. Measured
  6/8 self-answered before, **0/16 after**. The deadlock `APIDispatch` exists to avoid is the
  one you get calling TwiddleObject from a **uiQueue** task -- not from the turn thread.
- **A popup that closes with BOTH callbacks still set was not answered -- it was hidden.**
  `OnActivateCommand` nulls `commandCallback`, `OnSelect` nulls `selectCallback`. `PopupBridge`
  logs both at every close (`[popup] closed: cmdCb=… selCb=…`) precisely because that is the
  only signal that separates "the viewer answered" from "something tore the modal down": from
  the wire, from `raves_state.json`, and from a screenshot the two are identical. The wider
  instrument (`mod/InputDiag.cs`, `Enabled=false` by default) prints the game-view stack and
  the per-frame ControlManager command next to the popup's visibility, and it is what turned
  three rounds of guessing into one run.
- **Export `go.ID`, not `go.IDIfAssigned`.** IDIfAssigned is null until something has caused Qud
  to assign one -- 13 of 14 items in a normal pack had never been asked, so every row shipped
  without a handle. `ID` just persists the object's existing BaseID; it invents no identity.
- **A modal's own hotkeys live in the row TEXT** ("[d] drop", "[E] Equip (manual)"), not in
  `QudMenuItem.hotkey`, which is empty for menu items. Scanning only the field matched nothing
  and every letter escaped the modal to the app underneath -- pressing "l" for look toggled the
  font ruler behind the popup. Case matters: "[e] equip (auto)" and "[E] Equip (manual)" are
  different rows, so the shift state has to agree.
- **A re-announced popup must not reset what the viewer has done to it.** The watcher re-sends
  with a fresh id; rebuilding on that threw away an option list's SELECTION, so the bar moved on
  Down and sprang back a second later -- which reads exactly like "arrows do nothing". The same
  bug had already been fixed once for half-typed input; the guard is now content-based and covers
  both.
- **Refresh a screen when the popup CLOSES, not when it opens.** An item action lands when the
  viewer answers, which can be many seconds later; timers started at open had all expired, and
  the list still showed an item that had just been dropped. `PopupOverlay.closed` -> Main's
  `popup_closed` -> `StatusScreens._refresh_after_popup`.
- A `LineEdit` left at the default focus mode holds focus and eats the ACCEPT key. The tell is
  that ARROWS still work: a LineEdit passes up/down through and swallows only what it uses.

## The popup context header (the "image frame")

- Qud's popup header is `PopupMessage`'s `contextImage` / `contextText` / `contextFrame`.
  `contextRender` and `contextTitle` are ShowPopup PARAMETERS, not stored fields, so there is
  nothing to read on the instance -- the live components are the source of truth.
  `contextImage.threeColorTile` gives the sprite plus already-RESOLVED Foreground/Detail, so the
  client needs no palette lookup for the tile at all.
- **That sprite has no name to ship.** Both `sprite.name` and `texture.name` come back empty (it
  is an atlas sub-sprite), so its PIXELS are its only identity: the mod dumps them into the tiles
  dir under a per-popup filename. Per-popup because the client caches tile textures by NAME -- a
  stable name would serve the previous item's art forever.
- Geometry, all measured as offsets from the popup's TOP LINE (not the panel, whose padding
  differs): tile box +26 at 48x72 (Qud's RectTransform, 3x the 16x24 sprite), name ink +113,
  divider +151, first command's ink 22 below that. Panel 240 wide; the tile centres on it.
- **Draw the header's tile and its name in the SAME pass.** They were a drawn texture plus a
  RichTextLabel positioned from a deferred callback -- two readings of the same offset at two
  different moments. When the layout shifted between them the tile landed right and the name did
  not, INTERMITTENTLY: the identical build measured +113 one run and +89 the next, and the drift
  looked like state churn for hours. One pass, one reading. It also retires a guessed label
  leading in favour of the font's own ascent (less 5px: ascent overshoots the cap height).
- **The reconnect resend WORKS** -- an earlier note here said it did not, and that was wrong.
  `BridgeServer` fires `OnConnect` per accepted client and `PopupBridge.OnClientConnect` sets a
  one-shot `_resend` that overrides the signature dedupe, so a client that restarts while a popup
  is open does get it re-announced. The "Raves shows no popup" cases that prompted the wrong
  diagnosis were a popup that had actually been dismissed in Qud (Esc closed the status screen
  underneath it), plus stale item ids after a save reload.
- **...but every connect forces a full re-announce, and there are a LOT of connects.** highvisor's
  state poller opens and drops a bridge connection about twice a second, and each one set
  `_resend`. With a context header that meant a GPU texture readback, a PNG write and a delete at
  2Hz forever -- and a fresh popup id each time, which is what kept resetting the client's menu
  selection. The context sprite is now cached against the popup's signature and only re-dumped
  when the popup actually changes. **A per-connect hook is not a per-CLIENT hook**: anything that
  polls the bridge trips it.
- `tools/build_macos.sh` reports `✓ built + signed` even when a script has a PARSE ERROR. Read
  the `--check-only` output; a green build is not evidence the scripts are sound.

## UiState's heartbeat: name the GAMEPLAY scenes, never the allowed menus

`UiState._heartbeat` re-checks the live scene root and corrects the report when it cannot be
true -- the guard that stops a crashed Raves pinning highvisor's tree to a screen we already
left. It used to do that with an ALLOW-LIST: correct to "title" unless the scene is one of
title / chargen* / quit_dialog / records / options / mods.

Every menu screen added afterwards was therefore silently reverted two seconds after it opened.
`LoadGameScreen` was one. It reported `loadgame` correctly, the heartbeat undid it, and the
consequences ran a long way downhill:

  - highvisor believed Raves was on the TITLE while it was showing the save picker
  - so `goto in_game` clicked for a "Continue" that is not on the picker, and failed
  - so did every retry, identically, because nothing moved -- only a restart appeared to help
  - and the title recipe could not back out either, because its self-heal list had the same
    omission (mods/options/records/quit_dialog, no loadgame)

That is the intermittent `restart -> goto -> assert` failure chased for most of a session, and
it was never a race. The check now names the handful of GAMEPLAY scenes that genuinely cannot
coexist with a MainMenu root (`in_game`, `status_*`), so a new screen works without being
enumerated anywhere.

**The general shape:** an allow-list you must remember to extend is a trap. State it as the small
closed set of things that are wrong, not the open set of things that are fine.
- **Ship the filter strip's LIVE colours; its state is not derivable.**
  `FilterBarCategoryButton.LateUpdate` paints `background` from four states, but only ON CHANGE,
  so a button nobody has ever toggled keeps its PREFAB colour while one that has been toggled
  keeps `#134F4E`. Which of those a given cell shows depends on the save's whole interaction
  history -- unknowable from outside. Modelling it left every cell ~8 off and put the enabled
  one on the wrong index. The mod now reads `background.color` per category (plus the "*All"
  button's) and the client draws exactly that, falling back to the four-state law only when no
  live colour rides along. Hover stays client-side, since that is ours to render.
  Caveat: the colours are only readable while Qud's equipment screen is OPEN -- its buttons are
  inactive otherwise, and the export correctly omits them rather than shipping stale ones.
- When merging two export lists into one view, **copy every field you need, not the first one you
  noticed**: the strip took its icon from `filterOrder` and its base object from `categories`, so
  a colour added to `filterOrder` was silently dropped and the cell kept deriving what it was
  meant to stop deriving.
- **A doll slot is clickable, and WHICH object is in it decides what a click does.**
  `EquipmentLine.HandleSelectItem` twiddles an `Equipped` item but only LOOKS at a
  `DefaultBehavior` one -- so a click on the greyed natural weapon must not offer to drop a body
  part. The export marks those slots `greyed`, the client sends `mode:"look"`, and the mod runs
  `InventoryActionEvent.Check(obj, player, obj, "Look")`.
- `FindById` has to walk `DefaultBehavior` as well as `Equipped`/`Cybernetics`, or every click on
  a natural weapon comes back "no object with id".
- Hover state on a redrawn grid must key on something STABLE (here the slot's object id), not an
  index into the rect list -- that list is rebuilt during the very draw that reads the hover, so
  an index is half-stale exactly when it is used.
- **Escape closes the equipment tab when no popup is up.** Dismissing a mirrored popup with
  Escape during a test therefore closes the screen too if the popup has already gone, and every
  later click lands on the Holodeck instead -- which reads exactly like "clicks stopped working".
  Cancel a popup over the bridge (`popup / action:button / btn:Cancel`) when scripting.
- **The equipment screen's X axis switches PANE; it does not toggle a category.**
  `InventoryAndEquipmentStatusScreen` builds `horizNav.contexts = [paperdoll (or equipment
  list), inventory]`, so Left/Right moves between the doll and the list while Up/Down moves
  within whichever holds focus, and a category expands on Accept. Raves had Left/Right toggling
  the category, borrowed from the skills tree -- plausible, and not what Qud does.
- Qud's `PaperdollScroller` scrolls the WHOLE body, so every slot is selectable, empty ones
  included; do not skip to the filled ones.
- **An empty doll slot opens Qud's "what fits here" picker.**
  `HandleSelectItem`'s tail is `else if (!IsRightClick() || bodyPart.DefaultBehavior == null)
  EquipmentScreen.ShowBodypartEquipUI(GO, bodyPart)` -- so a LEFT click on an empty slot, and on a
  greyed natural-weapon slot, opens the equip picker; Look is the RIGHT-click case only. (An
  earlier pass here had left-click doing Look on greyed slots, which is the right action bound to
  the wrong button.) It is addressed by `BodyPart.ID` -- an empty slot has no object to name --
  and resolved with `Body.GetPartByID`, which also has to be searched by `FindById`.
- **JSON numbers reach GDScript as FLOATS.** The part id exported as `188` arrives as `188.0`, so
  `str()` yields `"188.0"`, the mod's `int.TryParse` rejects it, and the picker silently never
  opens. Use `"%d" % int(v)` when a number is going back over the wire as a key. The mod parses
  leniently now AND logs a bad id, because a silent `return` on a parse failure is
  indistinguishable from a click that never happened.
- **The equip picker is a SCREEN, not a popup**, so it does not come back over the popup mirror.
  `ShowBodypartEquipUI` -> `PickItem.ShowPicker` -> `Qud.UI.PickGameObjectScreen.show()`, which
  never touches `getWindow("PopupMessage")`. MIRRORED NOW by `mod/PickerBridge.cs` +
  `godot/PickerOverlay.gd` on its own `"picker"` frame type. Three things that only came out by
  reading the live screen rather than modelling it:
  - `PickGameObjectLine.setData` writes the hotkey AFTER its `go == null` branch closes, so
    CATEGORY rows are lettered too (`a) [+] Armor`) -- those letters are the keyboard collapse.
  - The opening selection is `itemScrollerController.selectedPosition`, which lands on the first
    ITEM (not the leading category) and re-clamps after every collapse. Export it; don't re-derive it.
  - `GameObject.GetWeight()` returns a **double**, not an int.
  Selection round-trips as a row INDEX into `listItems` and Qud's own `HandleSelectItem` applies
  it, so "category toggles / item picks" cannot drift from the game.
- **The picker's footer is a MENU BAR, and it is not a fixed list.** `yieldMenuOptions()` = the
  defaults, plus style-specific entries (take all / store), plus whatever the ACTIVE navigation
  context contributes -- so `[Space] Select` is present only while a `PickGameObjectLine.Context`
  is active and legitimately disappears otherwise. Export it live; don't hardcode it. Two more
  traps: `MenuOption.getMenuText()` is Qud's own renderer (`"[{{W|key}}] " + Description`), and
  `TOGGLE_SORT.Description` is REWRITTEN with the current sort mode on every show, so reading the
  object once and caching it would freeze "sort: list/by class" on a stale half.
  Activating an entry has to pass the INSTANCE Qud yielded: `HandleMenuOption` dispatches on
  REFERENCE equality (`element == TAKE_ALL`), so a rebuilt MenuOption with the right Id falls
  through every branch and silently does nothing.
- **Qud emits input glyphs as PRIVATE USE AREA codepoints**, drawn from its own icon font:
  `U+E80A` navigate (kbd), `U+E90A` navigate (pad), `U+E816` Ctrl, `U+E818` Alt, `U+E802` Shift,
  `U+E809` LMB, `U+E814` RMB. Source Code Pro has nothing at U+E8xx, so every one rendered as a
  tofu `?` -- the picker footer read `[?] navigate`. `mod/GlyphExporter.cs` now EXTRACTS the real
  font (sweeping all of U+E000..U+F8FF, 66 glyphs) into a BMFont in `<support>/glyphs/`, and
  `UiFont` loads it as a Godot **fallback** -- so no call site changes and any mirrored string
  carrying one renders the true icon. `QudText.GLYPHS` keeps the word substitutes for when the
  export hasn't run yet, and stands down once the font is present.
  Three traps, each of which produced a plausible-looking wrong result:
  - **A character's glyph may live in a DIFFERENT font's atlas.** `characterLookupTable` also
    carries characters served by FALLBACKS; read the rect out of the table's own font and you
    sample a stranger's texture. `TMP_TextElement.textAsset` names the real owner. U+E80A came out
    as a `#` plus half its neighbour until this was fixed.
  - **The source fonts are rasterised at different point sizes** (201 and 120 here). A bitmap font
    has ONE nominal size, so glyphs must be resampled onto a common scale or they render at wildly
    different sizes next to each other. The Blit's UV window is the SOURCE rect; the RT's dimensions
    are the DESTINATION -- tying them together silently crops instead of scaling.
  - **BMFont channel fields say what each channel HOLDS** (0=glyph, 1=outline, 2=both, 3=zero,
    4=one). Our page is white with coverage in alpha => `alphaChnl=0 redChnl=4 greenChnl=4
    blueChnl=4`. Declaring `alphaChnl=1` renders every glyph as a SOLID BLOCK -- it looks like a
    broken atlas but is a broken *description* of a perfectly good one.
- **Picker geometry is MEASURED, from Qud's live RectTransforms** (`mod/UiProbe.cs` -> `hv`
  `uiprobe`), not from screenshots. The whole model is in `PickerOverlay`'s constants; the height
  rule `21 + 5 + listH + 21 + footH + 6` reproduces Qud's panel to **0.00px** in every content
  state measured, and the panel is centred on screen in both axes. Residual against a synchronised
  capture: **dx +1, dw -2, dy +8, dh -16**.
  What the probe corrected that a screenshot would not have:
  - The title is **left-aligned in a tab at the panel's top-left** (panel+16, flush with the top
    edge), not centred as we had it.
  - Item rows are **30px** (they carry a 20x30 icon); category rows are **20.12px**. We had one
    height for both.
  - The chrome is **sprites**: a 9-slice `polat-char-frame-border` (border l6/b6/r6/t21) plus a
    two-piece mirrored `polat-frame-reverse-top-header-filler` divider — not the popup dialog's
    drawn notch-and-tick lines, which is what we were incorrectly reusing.
  - Row columns are FIXED cells: caret 15, hotkey 24 (**48 when indented** — `setData` prefixes
    three spaces), icon 20, spacer 2, so text lands at +61 / +85 / +39.
  Three traps in the probe data itself: pooled rows keep **stale TEXT** on their TMP components
  (geometry is sound, strings are not — classify rows by structure), a `Modes` node holds both a
  Category and an Item child with only one **active** (filter on `activeInHierarchy` or you read a
  font size off a hidden variant), and the panel is **content-driven, not fixed** — it looked fixed
  until a second picker was probed.
- **The footer's WRAP is MIRRORED, not recomputed.** Qud's bar is a `FlowLayoutGroup` (read off the
  live component, not guessed) whose wrap test is `running + item > containerWidth` with a trailing
  `SpacingX` — so where it breaks depends on how **Qud** measures each label. Raves runs a different
  text rasteriser and measures them narrower, so no spacing constant we picked could ever match
  except by luck: 15px was consistent with two observed states and changed nothing when applied.
  The mod now ships each entry's LAID-OUT box (`lx/ly/lw/lh`, relative to the bar) and Raves places
  them absolutely, so the line breaks are Qud's by construction. Panel-height residual went
  **-16 -> +7** on the same fixture.
  The trap that cost a cycle: `GetComponentsInChildren` includes the component's OWN node, and the
  bar is called **"KeyMenuOptionBar"** — a `StartsWith("KeyMenuOption")` filter swallowed it, shifted
  every entry's rect by one, and gave entry 0 the whole 400x66 bar. The footer rendered as one
  overlapping line. Match the option prefabs exactly (`"KeyMenuOption"` / `"KeyMenuOption(Clone)"`).
- **The +7px residual: CLOSED.** It was never rounding — it was two container defaults.
  **(a)** Qud's category rows are 20.12px, but a 16px `RichTextLabel` reports a **21px minimum** and
  a *Container* takes `max(own, content)`, so every category row came out 21 and the list ran
  11 x 0.88 = 9.7px long. The row is a plain **`Panel`** now (same `"panel"` stylebox, no child
  layout), so it is exactly the height Qud draws and the label overflows into `clip_contents`.
  `line_separation` cannot fix this — it spaces lines *within* a label, so a single-line label keeps
  its full ascent+descent minimum regardless.
  **(b)** `yieldMenuOptions()` can yield an option the footer bar has not instantiated (the
  context-dependent `[Space] Select` is yielded while only three `KeyMenuOption` prefabs exist).
  Demanding a laid-out box for *every* entry threw the absolute layout back to our own flow, which
  wrapped to two lines against Qud's three — the last 24px. Any box is enough; entries without one
  are skipped, and the band takes the **bar's own height** (66) rather than the extent of its boxes
  (44). Final: panel `754/325/412/430` vs Qud's `754/324.84/412/430.32`.

## The picker's chrome: two solid rects, no frame

`polat-char-frame-border` is on the picker's Background node, but **none of that sprite's border
reaches the glass** — measured on the live screen there is no edge line on any side. Qud paints
only: the Background rect inset by its own `VerticalLayoutGroup` padding (L/R/B 6, **T 21**), plus a
solid tab behind the title. The 6px edges and the whole 21px title band are transparent, and the
dimmed world shows through them. Drawing the extracted sprite as a 9-slice invented a light border
and a full-width title BAR, and covered the tab.

- The tab's width is a **text measurement** (`Title` = 8px padding + text + 8px), so the mod ships
  `tabW`/`tabH` — same reason the footer ships its laid-out boxes.
- **No selection bar.** Every `InventoryItemScrollerLine`'s background Image is `#ffffff00` — alpha
  zero, selected row included. The selection is the caret: `SelectionCaret` is `#cfc041ff` on the
  selected line and `#7f7f7f00` on every other.
- Chrome that needs independent per-side insets must be **drawn**, not added as child Controls: a
  `PanelContainer` re-fits every child to its own rect and throws the offsets away.

### Godot container defaults that bit here

- A **`ScrollContainer` stretches its child to the viewport only when the child has `SIZE_EXPAND`** —
  plain `SIZE_FILL` gets the child's own minimum width. That used to come free from the rows'
  content; the moment the rows stopped reporting a content width the list collapsed to **zero wide**
  and drew nothing, while the panel height stayed correct.
- A **negative-width `Rect2` does not flip in Godot 4** — it simply does not rasterise. The
  divider's mirrored right half was missing entirely; draw from a pre-flipped copy.
- `Control.position` is relative to the **immediate parent**. Reading `_scroll.position` (inside a
  MarginContainer) as if it were panel-relative put the divider 26px high, straight through the last
  row of the list.

## The status screens have no outer frame — every rule belongs to a TAB

There is no frame around Qud's status screens. Each vertical rule is an element inside one tab's own
subtree (`Screens/<Tab>/.../Vertical Border`), so its x, its vertical extent, and whether that side
is drawn at all change with the tab. Measured across all eight:

| tab | verticals | top rule |
|---|---|---|
| attributes | 173 (y180-938), 1745 (y236-938) | none |
| equipment | 166, 1753 (both y197-938) | 158-204, 213-581, 1338-1705, 1714-1760 |
| journal | 1748 (y197-938) | gap 726-1193 |
| quests | 1748 (y180-938) | none |
| tinkering | 166 (y197-938) | gap 842-1077 |
| messagelog / reputation / skills | none | none |

Raves drew one fixed pair (166 / 1753) plus one fixed set of top segments on every tab. That is the
EQUIPMENT tab's chrome — where it was measured — so it was right on one tab in eight and painted a
full-height rule down the right of the other seven.

The top rule is a **centred gap**, not a segment list: `158-204 / 213..(959.5-g)` and
`(959.5+g)..1705 / 1714-1760`, with only the half-width `g` changing (equipment 378.5, journal
233.5, tinkering 117.5 — all three gaps centre on 959.5). Five tabs draw none.

Interior column dividers (attributes 816/834, journal 952, quests 1021) belong to the panes, not to
this chrome.

The rule always RESUMES at 213; only its left end moves (204 on equipment and tinkering, 208 on
journal), so the notch is 8px wide on two tabs and 4px on the third — not a fixed notch that shifts.

## The journal header is bracketed, not ruled

Two 1px VERTICAL ticks close the journal's header block, one at each edge — not the 16px horizontal
dashes we drew. Off the live element:

    Image (2)  x=170.50  1x16      the left tick
    Image (3)  x=171.50  16x16     icon
    Header     x=187.50  w=143.04  "Locations", font 24, #4383a4, SourceCodePro-Regular
    Image (1)  x=330.54  16x16     icon
    Image      x=346.54  1x16      the right tick

The right tick is NOT flush with the text: the icon sits between them, and that 16px is part of the
header's geometry even while we do not draw the icons themselves.

**The header is TRACKED, and the mod ships the width.** Qud measures "Locations" at 143.04 where
Source Code Pro's nominal 0.6em advance at 24px gives 129.6. One sample cannot tell per-character
tracking from a fixed pad — they disagree on every other string — so the mod asks the live component
instead: `TMP_Text.GetPreferredValues(s)` measures any string with the element's own font, size and
spacing *without disturbing what it is showing*, so all seven sub-tabs are measured off the one
header Qud has laid out. Cached per visit to the tab, shipped as `hdrW` per tab.

With all seven in hand the model is unambiguous — `width = 16.079 * len - 1.66` reproduces every one
to 0.01px, so it is **tracking at 0.67em**, not padding. Raves takes its glyph pitch straight from
the shipped width (`hdrW / len`), which needs no constant and survives a Qud restyle. Drawing the
string in one call had every glyph after the first sitting ~1.7px per character left of Qud's.

### The header's "icons" are spacers

`JournalHeader/Image (3)` and `Image (1)` are 16x16 with components **`[CanvasRenderer,
LayoutElement]` and no `Image` component at all** — pure layout spacers whose names are prefab
leftovers. There is nothing to extract or draw; only their 16px of space is real, and the closing
tick sits past it.

### One rule colour: #4d6e7a -> (68,99,111)

Every 1px rule element on the status screens carries `#4d6e7a` (54 of them across the probes) and
lands at **(68,99,111)** on the glass. The shared `S_RULE` targeted (60,84,92) — 12 too dark on the
top rule, both verticals, the bottom rule and the corner stub — while `S_KEYCAP` and the attributes
pane's `C_LINE` had both independently arrived at the right value. Journal's header ticks were drawn
in the pane's dim TEXT colour instead of the rule colour.

`QudChrome.q8()` is now **measured, not modelled** — see below — so asking for Qud's colour lands on
it: all three rules and both journal ticks render (68,99,111), exactly Qud's.

## The canvas curve is a SAG, not a gain — measure it, don't model it

Raves' 2D canvas does not scale colours; it sags in the middle and lifts near black. Measured on a
65-step ramp drawn through the pipeline itself: 96 renders 85 (-11, the worst point), while 8
renders 10 (+2) and both ends are exact. The old compensation was a flat ×1.13 above 20, which is
right around 68 and 3 out by 111 — that was the status rules' residual, and it would have been a
per-call-site fudge to "fix" locally.

`QudChrome.INV` is the inverted ramp: `INV[target]` is what to DRAW so the captured pixel lands on
`target`, within 0.5 for all 256. All three channels measured identically, so one table serves.
The re-measurement recipe is in QudChrome.gd's header. Beyond the rules it moved everything that
goes through `q8`/`brighten` — the picker's interior diff against Qud fell from mean 9.46 to 5.49.

### Not every draw path sags — verify per constant before compensating

The canvas curve is real but it is NOT universal. Surveying the in-game chrome turned up 16
constants stating a Qud-measured colour raw; compensating all of them would have been wrong, because
two of them (`PAGE_NUM` 141,124,84 and `COL_HP_RED` 209,58,0) **already land exactly** without
compensation — Qud and Raves both hold those values pixel-for-pixel today.

So test each one against the live frames rather than pattern-matching the source:

    QUD holds V  and  RAVES holds f(V)  and  RAVES holds no V   ->  it is a TARGET, wrap it in q8
    QUD holds V  and  RAVES holds V                             ->  leave it alone

On that test five needed it (`COL_HP_BAR_1TO1`, `COL_EXP_BAR_1TO1`, `CELL_FRAME_1TO1`, `SEP_OUTER`,
`SEP_CENTER`), and the "unclear" ones simply had too few pixels on screen in that state to judge —
which is an answer too: leave them until a state shows them.

### The probe reaches the in-game HUD, not just screens

`uiprobe target=AbilityBar` dumps Qud's whole bottom band while a game is live — the resolver
matches a COMPONENT type, then a substring, then a GameObject name, and the HUD answers to all
three. Two rounds of cell-geometry work were fitted by hand on the assumption it could not.

What it gives for the ability bar:

    AbilityBar        y=990    h=90        the whole bottom band
     Top              y=992    h=25.64     3 areas of 636: effects x=1, target x=642, missile x=1283
     AbilitySection   y=1017.64 h=62.36
      Ability Hotbar
       Hotbar Swapper x=20     w=155       the ABILITIES gutter
       ButtonArea     x=175    w=1745      cells start at 175; the 180 we match is 175 + padL 5
        AbilityBarButton  padL=5, UpperLeft, widths 192.96 / 167.76 / 159.36 / ...
          Spacer          w=1              the 1px divider between cells
          WorkableArea    spacing 10, MiddleCenter
            TopHalf       32 x 48          the icon element
            Ability Text  100.81 x 25

**...nor wholesale, without Qud's per-cell WIDTHS.** Rebuilding the cell to exactly that nesting --
outer box padL 5 / padR 0, a WorkableArea carrying the green frame, a fixed 32x48 icon element,
spacing 10, and the gutter moved to Qud's real 175 -- puts the frame on Qud's x180 and still scores
WORSE (bar mean 10.06 -> 16.09), because the cells come out far too wide: 373 / 579 / 782 against
Qud's 367 / 537 / 697.

The reason is the leftover, not the model. Both apps size a cell to its content and then share out
the slack, but Godot splits leftover space EQUALLY between expanding children while Unity's layout
distributes it by flexible width -- so the same minimums land on different widths. Modelling the
cell correctly makes our minimums *smaller* (5 of padding instead of 16), which leaves MORE slack to
distribute and pushes every boundary right. The flat, over-padded cell was accidentally compensating.

**The widths are now shipped** — `barCells` in the snapshot, e.g.
`192.96,167.76,159.36,159.36,159.36,260.15,117.36,285.35,243.35`, read off the live
AbilityBarButtons on the UI-thread watcher. The client does NOT use them yet, because pinning the
widths alone still scores worse (10.06 -> 12.39): the widths are Qud's for the CELL, and our cell
draws its green frame at its own edge where Qud insets it by padL 5, and our separator nodes add
width its 1px in-cell Spacer does not.

The three go together or not at all:

1. `barCells` pinned per cell (`custom_minimum_size.x`, `SIZE_FILL` not `EXPAND`)
2. the nested structure — outer box padL 5 / padR 0, the green frame on the inner WorkableArea,
   a 1px divider inside each cell but the first (Qud's Spacer, (46,75,83) on the glass)
3. `GUTTER_W_1TO1` = **175**, Qud's real ButtonArea x — the 180 the frame lands on is 175 + padL

Each of those alone makes the bar WORSE (12.39 / 16.83 / 16.09 against a 10.06 baseline). Applied
together they land: **9.04**, with the cell boundaries on Qud's own columns — 367, 537, 697 exactly,
where the flat cell drifted to 695 and 853. The icon ink comes out 45x40 against Qud's 43x40.

That is the shape of the whole lesson: a layout copied piecemeal from another engine reads as a
series of regressions, because each constant you have not copied yet is compensating for the one you
just did. Take the model whole, or leave it alone.

**A model you cannot copy piecemeal.** Qud's spacing of 10 and its padL of 5 both make our bar
worse (10.06 -> 14.78 and -> 15.07) because our cell's elements are not its elements: the spacing
only lands right once the icon element is 32 wide and the text element 100.81. Our own set — icon
box 47, padding 8, spacing 6, centred — puts the cell boundaries on Qud's columns, which is what
reads. Matching Qud's numbers means rebuilding the cell to its structure first.

### The ability bar's floor is the ±1 edge rounding

With Qud's per-cell widths shipped and its edges rounded cumulatively, the bar sits at 4.03 and the
leftover is not a defect to chase. Cells 4 and 6 score 6.55 and 3.89 against their neighbours' 1.6,
and splitting them says ICON (9.69 / 7.34) versus TEXT (4.49 / 3.15) — which looks damning until you
diff the pixels: the differing ones are the SAME COLOURS SWAPPED BETWEEN POSITIONS, Qud's blue where
ours is background and ours where Qud's is. Same sprite, same palette, shifted one pixel.

That pixel is structural. Qud's cell widths are fractional (192.96, 167.76, 159.36, ...) and ours
must be integers, so every edge lands within ±1 and the icon centred inside inherits it. Cells whose
edge rounds one way match to 0.03; cells that round the other carry a 1px offset, and a dense
40px sprite makes that offset expensive in the mean while being invisible to the eye.

Two checks worth repeating before calling an icon wrong:

- **Qud against Qud.** Two captures of the same screen scored 0.00 on every icon zone, which ruled
  out animation frames as the cause. Without that, "the icon differs" reads as a tile bug.
- **The differing PAIRS, not the mean.** Colours swapping positions means placement; colours
  changing value means palette or sprite.

### Small-text rasterisation: three levers, none of them help

The ability bar's gutter is its largest remaining share (26%), and inside it the keycap hint row is
42% at mean 28. The cause is that Qud's 5-8px text reaches FULL coverage — its "Tab" peaks at
(182,164,5) — where ours peaks around (155,140,7): at that size our grey antialiasing spreads each
stem over two partial pixels and never fills one.

Every available lever was measured, on the hint row alone:

| | "Tab" peak | hint row mean |
|---|---|---|
| regular, antialiased (kept) | (155,140,7) | **28.20** |
| antialiasing off | (182,164,5) ✓ | 30.61 |
| bold face | (182,164,5) ✓ | 29.20 |

Both of the last two get the peak exactly right and make the picture WORSE, because Qud's glyphs
have full-coverage cores AND soft edges — hard edges everywhere, or thicker strokes everywhere,
differ from that more than under-filled ones do. (App-wide MSDF and unhinted rendering were measured
and rejected earlier for the same reason.)

So the number is not a defect to close: at 5-8px, per-pixel agreement between two rasterisers is
mostly luck, and the honest move is to leave the lever that measures best rather than the one whose
peak matches.

## Measurement pass: the top status bars (NOT yet fixed)

The in-game top chrome (y0..92) scores **5.98** against Qud — the worst-matching surface left in the
1:1 frame, an order above the message log (0.63) and the playfield (0.17). Measured, not fixed:

| band | mean | share |
|---|---|---|
| y 20..46 (row 1 content) | 8.90 | 42% |
| EXP row | 5.47 | 22% |
| HP row | 5.28 | 19% |
| y 0..20 | 4.28 | 16% |

| column | mean | share |
|---|---|---|
| right (1400..1920) | 9.38 | 43% |
| left (0..300) | 8.18 | 21% |
| mid-left | 4.12 | 22% |

It is **group placement**, not glyphs or colour. The content matches closely when zoomed — same
text, same icons — but the groups sit in different columns:

    left group    QUD x 20..299    ours x 1..237     (starts 19 left, ends 62 short)
    middle group  QUD x 300..899   ours x 481..848
    right group   QUD x 1700..1900 ours x 1770..1918

So the top bar packs its groups on a different rule than Qud's. Read Qud's own layout before
touching it — the probe reaches the HUD (`uiprobe target=AbilityBar` works; the status bar will
answer to the same resolver), and this session's ability-bar work is the cautionary tale for
adjusting one group at a time against a container that redistributes the rest.

## The quit chain is a harness hazard: failed `goto title` attempts STACK

`hv goto raves title` from in-game walks Qud's quit chain (CmdQuit → "are you sure" → "save
first?"), and the mirrored confirms drain only while QUD is focused — a dismiss key sent to Raves
queues the answer in Qud's uiQueue, which macOS stops draining for a backgrounded window. So the
recipe can time out with the confirm still up, and EVERY RETRY QUEUES ANOTHER CmdQuit: each
dismissed confirm lets the next raise a fresh one, which reads as "the popup won't close" (ten
Escape+drain rounds, no visible progress).

Getting unstuck: the confirm is a LEGACY console popup — synthesized keys don't land on it, but a
`--hover` click on its own [Esc] Cancel does, and one cancel unwinds the whole stacked chain (the
game never actually quit). To reach the title without the chain at all, `hv restart raves` is the
clean lever.

The real fix (open): the title recipe's dismiss steps need the focus dance built in — answer in
Raves, then focus Qud so the uiQueue drains, then verify — and a guard against resending CmdQuit
while a quit confirm is already up.

### …and the chain is a different LENGTH for a Classic character

**CmdQuit is two prompts for a Wander/Roleplay save and THREE for a Classic one.** Decompiled from
the shipped assembly (`XRL.Core.XRLCore`, `case "CmdQuit"`), after "are you sure you want to quit"
→ Yes and "do you want to save first?", Qud raises a third confirm unless
`Options.DisablePermadeath || CheckpointingSystem.IsCheckpointingEnabled()` — and
`IsCheckpointingEnabled()` is true only for game state `Checkpointing == "Enabled"` or **GameMode
Wander/Roleplay**. For a Classic character it is
`Popup.AskString("…Type 'ABANDON' to confirm")`: a **text-input** modal, reported as
`DynamicPopupMessage`, not a button confirm.

Two consequences worth knowing before touching anything on this path:

- **Never answer it programmatically.** Typing ABANDON is the quit-*without*-saving branch: it sets
  a DeathReason and ends a permadeath run. A harness must not destroy a character to satisfy a
  state transition. highvisor now cancels that prompt and fails the edge with the reason; the
  non-destructive way to the title from a Classic game is a restart.
- **It is why "the quit edge breaks on a long-lived Qud" looked like process ageing for three
  sessions.** It never was age — a bare load/quit loop on the Wander fixture ran 40/40 clean in
  9.2 minutes (2026-08-07). The failing session simply had a Classic character loaded, so the
  chain hung on the ABANDON prompt every time. What made it look progressive is that
  highvisor's `in_game` detector accepts the stuck state, so every "retry on a fresh load" planned
  **zero** steps and re-tested the same stuck game.

Also note Qud **discards** the "save first?" answer (`XRLCore` assigns `DialogResult.No` and then
ignores the prompt's return value). Answer it correctly anyway — the modal is real and must be
cleared — but don't reason about the quit's outcome from what you pressed there.

`hv goto raves title` walks the same three-prompt chain through the mirrored modals and has the
same hole: its dismiss steps condition on `popup: message`, which an input popup does not match,
so an ABANDON prompt slips past as "not present" and the edge fails at its verify instead of at the
step. Worth closing the same way the Qud edge was.

## The sidebar's ||| grab-bar: the centre column is TWO pixels wide

Measured off a synced capture at 1080 — Qud's bar occupies x **1623 / 1627-1628 / 1632**, i.e.
panel-relative offsets **2 (1px) / 6 (2px) / 11 (1px)**. Both `MessageLog.gd` and
`NearbyObjects.gd` draw it, and both must agree or the sidebar edge visibly steps where the two
panels meet.

The first cut drew three 1px columns at 2/6/10: it read the 2px centre as one column and then
pulled the right outer in with it. Cost: a 23.25 mean-diff band down the whole sidebar that read
as "text antialiasing" until the columns were dumped pixel by pixel. Fixing it also took the
already-shipped **message log from 0.63 to 0.161** — a panel that had been called done.

**When a whole-panel diff won't come down, dump the actual pixel columns before blaming the
rasteriser.** A 1px structural offset and glyph AA look identical in a mean.

## `PanelContainer` CLAMPS `content_margin_top` at 0 — a negative margin does nothing

Silently. Setting `-2` moved the content by exactly the distance to 0 and no further, and setting
`-4` afterwards changed nothing at all (byte-identical capture) — which is what made it look like
the edit had not been picked up rather than that the value was being floored.

If 1:1 content has to sit ABOVE the panel's content origin, don't fight the margin: **draw it on
the owner-drawn surface** and place it with a measured offset (`NearbyObjects.TITLE_BASE_1TO1`).
Read the surface's real origin once with a `global_position` print rather than deriving it from
font metrics — the panel origin (93) and list origin (120) took one throwaway build and ended the
guessing.

## A hidden `CanvasLayer` still feeds its children INPUT

`CanvasLayer.visible = false` stops DRAWING, not processing, and `is_visible_in_tree()` on a child
Control does not see through the layer (a CanvasLayer is not a CanvasItem ancestor for that check).
So a "closed" overlay hosted in a hidden CanvasLayer keeps running `_unhandled_input`.

Cost, twice now: the feedback tool's paint-order hit test named elements inside closed screens until
it got an explicit layer-visibility guard, and the in-game Options overlay went on eating `ui_cancel`
after closing — Esc stopped opening the system menu entirely, which reads as "Esc is broken", nowhere
near the overlay that is actually swallowing it.

Two fixes, pick by lifetime: screens that live for the session guard their own handlers
(`if not visible: return`, as `ControlMappingScreen` does — it IS the CanvasLayer, so its `visible`
is the real one); screens built per open **free the host on close** (`queue_free()` + null the ref,
as `MainFrame._close_options_overlay` and `MainMenu._close_overlay` do). The second also re-reads
config on each open, which is usually what you want anyway.

## Our scanline suppression blanked Qud's OWN minimap

`Bridge.EnsureScanlineState` sweeps EVERY `UI.Graphic` every 20 ticks and neutralises
`_ColorOverlay` / `_OverlayTex` / `_Offset` on its material. Qud's minimap Image draws the 80x50
`minimapTexture` through one of those same overlay materials, so the sweep blanked it outright.

**It reported perfectly healthy while invisible** — `DisplayMinimap=True`, texture 80x50, all 4000
entries of `GameManager.minimapColors` non-zero (258 above alpha 200), GameObject active, Image
enabled with a sprite, colour opaque white, rect 240x104, canvas alpha 1. Every readable variable
said "drawing", and not one pixel reached the screen. Don't trust a state dump alone: confirm with
a whole-frame colour scan for the thing's own palette (canary doors / violet stairs found ZERO
matches anywhere, which is what proved it wasn't merely mispositioned).

Nothing caught it for a week because Qud's overlay options were "No" from 2026-08-01, and the sweep
shipped 2026-07-30 — **the feature was already switched off before the code that broke it landed.**

**Which property blanks it (bisected live 2026-08-06):** the minimap's material is
`UI/Textured-Overlay`, carrying `_ColorOverlay` and `_OverlayTex` (no `_Offset`).
`_ColorOverlay` -> transparent BLANKS the map (the shader MULTIPLIES by it); `_OverlayTex` ->
white is safe AND removes its scanlines. Measured, map region: untouched 1563 bright px /
even-odd gap 3.90; `_OverlayTex` only 1590 / 0.05; anything including `_ColorOverlay` 90 / 0.08.
So neutralise `_OverlayTex` only on that material (`Bridge.MinimapMask = 2`, live-settable with
the `mmmask` bridge command) — map visible, scanlines gone, chrome untouched elsewhere.

**Exempting the shared material is NOT the fix** — the sidebar panels draw with the same asset, so
skipping it handed their scanlines back (measured: the flat chrome's even/odd row gap returned to
13.67, the unsuppressed value). Clone a PRIVATE material for the minimap once and exempt only that:
map visible, chrome still flat at 0.00.

Measure suppression with the period-2 row alternation in a flat chrome patch
(`abs(rows[0::2].mean() - rows[1::2].mean())`), not by eye — 0.00 vs 13.67 is unambiguous.

## One state file, many writers — the scene report was a coin flip

`raves_state.json` had exactly one path and one writer *per running Raves process*. With three
instances alive (two leaked from earlier launches), all three heartbeats wrote the same file every
two seconds, so a single read returned whichever had written last:

```
in_game -> status_tinkering -> title -> in_game -> ...   (12s of samples, 0.5s apart)
```

This is the "`raves_state.json` lies" bug and it was NOT a lifecycle/`set_scene` defect — the
reporter was correct in every process. It presented as **highvisor confidently reporting a screen
Raves was not on** and as **`hv goto raves in_game` needing retries**, because with duplicate
windows `_find_win` picks the first match: the recipe could drive window A, read window B's report,
and fail a step that had actually worked. Any screenshot taken to "check" was also a coin flip.

Fixes, both sides:
- Raves stamps `pid` into the report and also writes `raves_state.<pid>.json`, sweeping sidecars of
  dead pids at startup (`OS.is_process_running`).
- highvisor reads the sidecar for the pid that owns the window it is evaluating, and REFUSES a
  shared file stamped with a different pid — None (fall back to OCR/port) beats a confident wrong
  answer. Reports with no `pid` (the Qud mod's `qud_state.json`) read exactly as before.
- `hv state` shouts `!! N INSTANCES`, and `hv goto` refuses to drive at all while duplicates exist.

**The general lesson:** a single-path status file is an implicit assumption that only one process
ever runs. State a process reports about ITSELF belongs in a per-process file; a shared path needs
an owner stamp the reader can check. And when a report and the screen disagree, count the
processes before you go looking for a bug in the reporter.

## q8 takes Qud's SCREEN value, not a Qud palette source

`QudChrome.q8` pre-compensates **Raves'** canvas shader: draw `q8(148)` (= 158) and the screen
measures back 148. So the argument must be the value you want ON THE GLASS.

Matching a Qud colour by looking up its palette entry and passing THAT through q8 double-counts a
curve Qud has already applied to its own output. Measured on the ability bar's `[on]` tag: the
mod's palette ships `g` = (0,148,3), but what Qud actually renders is **(3,123,6)** — 21% dimmer.
`q8(0,148,3)` put (0,148,2) on Raves' screen (too bright); `q8(3,123,6)` put (2,123,6) — exact.

Two corollaries, both measured on the same tag:

- **The lift matters most where it is least visible.** Drawn raw (no q8), the near-black brackets
  came back DIMMER than Qud's — they dropped out of a `sum>115` pixel scan entirely — while the
  bright grey word matched fine either way. Raves' shader compresses the dark end hardest, and
  that is the end q8 lifts. Never skip q8 "because the colour is nearly black".
- **Peaks wander ±8% between captures of the identical tag** (glyph AA lands differently by
  subpixel position). Sample the same glyph in both apps in the same run, and treat anything
  inside that band as matched rather than chasing it.

To identify an unknown Qud UI colour: drive the state over the bridge, screenshot, group the lit
pixels into glyph COLUMNS, and read each group's brightest pixel — per-glyph, because Qud colours
brackets separately from the text inside them.

## Raves infers its scene; F5 (QudSync) asks instead

MainFrame decides the game ended by watching `bridge_status.txt` go quiet for three reads, then
falls back to the title. That inference is right for the common cases and wrong at every
transition Qud handles with a SCREEN of its own. Abandoning a character is the one that bit: Qud
raises the tombstone and stops running a game, Raves sees silence, assumes "game over -> title",
and the two windows disagree with no way back but clicking around in Qud.

The mod already reported the truth — `qud_state.json` carries `live` (is a game actually running)
plus `scene`, the raw `_ActiveGameView`. Raves simply never read it. `QudSync` (F5, autoload) does:

- **`live` decides where Raves belongs.** It is a fact, not an inference from silence.
- **`scene` is REPORTED, never matched against a table of Qud view names.** We know "MainMenu" and
  "Stage"; anything else is named verbatim in the toast. A screen we have never seen produces a
  useful message instead of a wrong branch — and the tombstone's view id can only be learned by
  killing a character, so a rescue tool must not depend on having guessed it.
- **`uiback` is sent, then VERIFIED.** It reaches the active window's own OnCancel/Exit, which
  covers status screens and popups — but measured, `ModernHighScores` does not budge. So the tool
  watches Qud's report for ~3s and says which happened. "Sent" is not "worked", and a tool for
  un-stranding people must never report the one as the other.

Testing it needs no dead character: `hv goto qud records` parks Qud on a screen with no game
running, which is the same shape as the tombstone case.

## GDScript `or` is a BOOLEAN operator — the Python `x or default` idiom silently yields `true`

`some_dict.get(key) or {}` does **not** return the dictionary. GDScript's `or` evaluates both sides
to booleans and returns `true`/`false`, never the operand. So the reflex ported from Python —
`for x in (d.get("children") or [])`, `var a: Dictionary = d.get("apps") or {}` — becomes
"iterate `true`" and "assign `true` to a Dictionary".

Cost when it bit (StateGraphPanel, 2026-08-06): the panel drew a correctly sized, correctly
framed, perfectly **empty** box. The frame is Godot's, so it read as a layout or theme problem and
two export cycles went into chasing those; the real cause was three runtime errors inside the text
builders, invisible because a RichTextLabel handed nothing just draws nothing.

Use a shape guard rather than `get(k, default)` for anything off the wire — `get`'s default only
applies when the KEY IS ABSENT, so a JSON `null` still comes back as null:

```gdscript
static func _dict(v) -> Dictionary: return v if v is Dictionary else {}
static func _arr(v) -> Array:       return v if v is Array else []
```

**Check for this whenever a Godot panel renders blank but sized.** An empty draw with an intact
frame means the CONTENT threw, not the layout.

## A modified WHEEL needs the modifier really held; flags alone are not enough

`hv scroll --mods ctrl` set `kCGEventFlagMaskControl` on the scroll event, and Godot received the
wheel with `ctrl_pressed` **false** — Raves' Ctrl+wheel panel never opened, while a plain wheel
zoomed the camera every time. highvisor now presses the real modifier key around the event (release
in a `finally`, plus `_clear_stuck_mods` — this is the stuck-modifier class that cost a day once).
The flags-only trick documented on `click` is a different path and still works; don't unify them
without re-measuring.

**Corollary for UI design here:** a gesture that only a mouse can produce is a gesture the harness
may not be able to drive. Give any dev-facing overlay a KEY as well (StateGraphPanel: F6), or it
can only ever be tested by hand — and it will stop being tested.

## GDScript lambdas capture locals BY VALUE — a recursive closure cannot return a result

```gdscript
var found := {}
var walk := func(x, f):
    if x.id == want: found = x        # writes the LAMBDA's copy; the caller sees {}
    for c in x.children: f.call(c, f)
walk.call(root, walk)
return found                          # always {}
```

`_node_by_id` returned `{}` for a node plainly in the tree because of this. Write a plain
recursive **function** instead. (`_count_nodes` gets away with the same shape only because it
accumulates into an `Array`, which is a reference — the workaround hides the trap rather than
avoiding it, so don't read it as a pattern to copy.)

This is the second GDScript-vs-Python reflex to bite here; the first was `or` being a boolean
operator. Both produce silence rather than an error.

## A row that overflows a RichTextLabel WRAPS — the content is there and unusable

The state-graph panel's `[T]` run-a-check marker was pushed onto its own line at the far left,
because the row was a few characters wider than the panel. It rendered, so nothing looked
broken; it just could not be aimed at. If a fixed-column layout looks right in a fixture and
wrong on screen, measure the **widest** row, not a typical one — and prefer putting variable
elements in a fixed-width column so the widest row is a constant.

## Qud's popup box, and the two Godot rounding traps that hid inside it

Qud centres `MenuControll` (spacing 10, pad L20 R20 T0 B5) and **hangs the visible chrome off that
box rather than around it**: the top rule 16 *above* it, the opaque fill from box_top−20 to
box_bottom−2, the bottom rule 15.5 *inside* it. Raves centred the panel and drew its top rule 8px
inside, which read for two sessions as "the popup sits 16px low" — a number that looked like a
constant to add and was actually the sum of an anchoring error and a content-dependent height
error. Model, arithmetic and the six-popup verification are in
`reports/2026-08-05-item-popup/` and in `PopupOverlay.gd`'s header.

Two things about Godot's layout came out of it that are not specific to popups:

- **A Container CEILS a fractional minimum, and Control rects are snapped to whole pixels.** A row
  asking for 228.2 is handed 229, which made the box 279 wide against Qud's 278.21 — and 279
  centres on 820 where 278.21 rasterises from 821. So a subpixel model reaches the screen a whole
  pixel out, in the direction the ceil pushed it. Round the MODEL's own values to the nearest pixel
  yourself; do not let the container round them for you. (Centring floors: 820.5 lands at 820.)
- **`position` / `global_position` read (0,0) from inside a Control's own draw callback** on the
  show frame — sizes are valid there, positions are not. Nothing dirties the panel afterwards, so
  that stale draw is the one left on screen: chrome computed from a position read at draw time was
  displaced by the panel's whole offset and stayed that way. Derive placement from SIZES (the
  container's own rule is reproducible) or read it once outside the draw.

**And Godot's `get_string_size` returns a whole number.** Qud lays this text out at exactly 0.6em
(9.6px at font 16, which is every width its probe reports); Godot rounds the total up, and summing
the per-run pieces of a `{{...}}`-coloured string rounds again — 211.21 became 213. Measure and
advance on the font's own pitch (`get_string_size("AAAAAAAAAA")/10`) whenever a width has to agree
with Qud's. This is what the journal header found from the other end, and it is what put the item
popup's name 1px left of Qud's for two sessions: the name's own layout was never wrong.

### Raising popups to test: the retry that equips your fixture

`popup / action:button / btn:Cancel` is the documented dismissal, and on a MENU it is not safe: the
mod fabricates a Cancel item, Qud's `OnActivateCommand` falls through to the HIGHLIGHTED row, and
on the cloth robe that row is "equip (auto)". A retry loop written that way quietly equips the
fixture's item and then fails forever on a menu that no longer has 8 options — which reads as "the
popup stopped coming up". **Reload the fixture to clear a menu; a reload cannot activate anything.**

Also: **the first twiddle after a fixture reload sometimes raises a SHORT option list** (8 options
arriving as 2 or 6, Qud still settling). It is a different popup, and the anchored header leaves
still score against it, so a parity run captures it without complaining. Count the
`MenuOptionText(Clone)` rows in a `uiprobe` dump before capturing.

## The popup mirror has TWO halves, and only one of them was ever observable

Both halves are fixed and both are guarded now. The story is kept because the *shape* of the
mistake is what costs the time, not the bugs themselves.

### Half one: the watcher could not arm while a popup was up (FIXED, 165f44b)

`PopupBridge.Ensure()` — which starts the UI-thread watcher that mirrors Qud's modals to Raves —
had exactly one caller, `Bridge.TickRender`. `TickRender` is reached only from
`BridgePart.HandleEvent(BeforeRenderEvent)`, and `BridgePart` is attached to the **player**. So with
no player it could not be called at all, and while a modal parks the turn thread `BeforeRenderEvent`
stops firing: the popup that most needs mirroring was exactly the one that could never arm the
watcher.

Arming now runs off the mod's **heartbeat thread** (once a second, regardless of focus, turns,
render frames, or whether a game is live) plus `StartupHook.Init`. Verified in the failing case, not
the happy one: with Qud at its MAIN MENU (`live:false`, `player:false`, so `BridgePart` does not
exist) the title-screen quit confirm mirrors over the bridge. The old code could not have produced
that frame.

`_pumping` was also a flag that could not be falsified — the watcher re-queues itself onto the
uiQueue, so a torn-down and rebuilt queue leaves the chain dead with the flag still true, forever.
`Ensure()` now demands **proof of life** (the chain stamps `_aliveMs` on every drain; a stale stamp
re-arms) with a generation counter so healing cannot leave two pumps running.

### Half two: the CLIENT never built its overlay, and nothing could see that (FIXED)

`godot/PopupOverlay.gd` declared `var _title: RichTextLabel` after the title row had been converted
to an owner-drawn `Control`. GDScript only catches that at RUNTIME: the assignment threw inside
`_build()`, **aborting the whole builder**, so every widget created after it was null and
`show_popup()` died on the first one it touched. No popup of any kind displayed in Raves.

**This is the part worth remembering.** An overlay that never got built simply stays
`visible = false`, and from outside that is indistinguishable from every upstream failure:
`raves_state.json` reports no popup, `hv state` shows none, and **`fixture.py twiddle` prints "no
popup appeared" because it verifies through RAVES**. A whole session was spent concluding "no popup
raises in Qud at all, and it survives a clean pair restart" from those signals alone. Qud was
raising popups the entire time.

**So when a popup does not appear, split the halves before theorising:**

1. **Tap the bridge** and look for `popup` frames — the mod's half, decidable in seconds
   (`type:"popup", active:true`, with its `options`).
2. **Screenshot QUD's own window** (`hv shot CavesOfQud`) — Qud's half.
3. Only then look at Raves.

Never take a Raves-side signal as evidence about Qud. Guarded now by
`godot/tests/popup_overlay_render.tscn`, a SPOT test that drives the real `show_popup` over the real
wire frames headlessly and fails on any runtime error in that path.

### Answering a popup the mod never ANNOUNCED (FIXED, 165f44b)

`HandleCommand` used to target `_announcedPm` and, when that did not check out, fall back to "scan
for any visible popup". That answers a modal the viewer never saw — and for the async COPIES
(`ShowYesNoAsync` / `PickOptionAsync` / `AskString`, all via `UIManager.copyWindow`) the scan can
return a **pooled ghost** that still looks visible and still has a callback. The answer vanishes,
Qud's real modal keeps its `onHide` dangling, and it surfaces one popup later as
`ShowPopup::OnHide wasn't called!` followed by a Mono internal-call fault.

The fallback is gone. The bridge answers only the exact instance it announced, still live, still out
of `UIManager`'s free pool, and named by an id belonging to the episode on screen; Raves stamps the
id it is answering. Ids are checked against the **episode range**, not against the latest id: every
client connect forces a re-announce (highvisor's state poller connects ~2/s), so a valid answer
legitimately lags by a few and strict equality would reject good answers.

**That `ShowPopup::OnHide wasn't called!` chain does not stop Qud raising popups** — that was the
other half of the wrong diagnosis, and it is worth stating flatly so nobody re-hunts it. Measured on
a clean restart plus a fresh golden-save load: Qud raised the item menu, the wish AskString and the
title-screen quit confirm normally. The Mono `cant resolve internal call to
Marshal::GetHRForException_WinRT` lines are just what `MetricsManager.LogException` looks like on
this build — they mark an exception being REPORTED, not a broken runtime.

### The item menu sometimes answers ITSELF (OPEN — not diagnosed)

The item menu is sometimes answered within a fraction of a second of raising, with its **highlighted
row** — `equip (auto)` on the cloth robe. A bridge cancel then arrives too late and is refused
(`[popup] REFUSED button (id N): the announced popup is no longer live`, which is the new guard
doing its job). The item has moved between the pack and the body by then, so the next raise offers a
legitimately different list: **6 options equipped, 8 in the pack.** Measured 6/8 over eight scripted
raise-and-cancel cycles, with and without Qud focused.

Two things it is NOT: it is not the bridge answering (the log shows a refusal, never an accepted
answer), and it is not the mod's fabricated-Cancel path (the item menu's single bottom button really
is `command: "Cancel"`, so `FindByCommand` matches it and nothing is fabricated — an earlier note
blamed that path and was wrong). What delivers the answer is unidentified.

**Working rule for captures:** reload the fixture between raises rather than retrying, and check the
option count on the mirrored frame before you capture. A reload cannot activate anything.

## An EXTRACTED sprite is not always what Qud RENDERS — check the region before trusting it

Measured 2026-08-09 on the popup's tree emblem (`polat-frame-top`, extracted by the new
`hv bridge popupchrome`). The pipeline is sound and the pixels are Qud's own, but the region
`sp.textureRect` names **overreaches the sprite Unity actually draws**, three ways at once:

- a wide `(60,96,103)` band across its middle rows that Qud provably never puts on screen
  (outside the glyph, the two apps differ nowhere in those rows);
- one column too many on the right — the PNG's glyph is 40 wide, Qud inks 39, and the dropped
  column's mirror on the left IS drawn, so the glyph is not the asymmetric thing;
- the glyph's 1px spine stored as the DISC colour at alpha 128, where Qud renders glyph tone.

**So verify an extraction against a live capture before building on it** — `hv shot` both apps,
match the flat tone, compare the masks. Do not re-run these three: forcing `FilterMode.Point` in
`TitleExporter.WriteRegion` changes the file by **zero bytes** (it is kept as a guard, and its
result is recorded in the comment); a second extraction of the same art through a different sprite
(`chargen_emblem.png`) agrees with the render *worse*; and growing the tone mask into the
half-alpha pixels by vertical continuity floods the disc.

**And do not threshold BRIGHTNESS to measure anything over a modal.** Qud dims the live playfield
behind a popup instead of blanking it, so `sum(rgb)>140` returns the whole scan window — the
emblem's bbox came back as `x800..1119`. Match the flat TINT with a tolerance instead;
`reports/2026-08-05-item-popup/measure_emblem.py` is the worked example, and tolerances 0-6 all
give the same answer there.

**Adding a screen's extracted chrome → put the loader in `QudChrome`, not in the screen.** The
emblem is on the popup and on the chargen header, and `QudChrome.nav_icon` already records what
seven private copies of one glyph cost. `QudChrome.popup_emblem()` decodes once into a static.
It also does NOT call `brighten()`: the extracted tone `(77,110,122)` is exactly `q8(68,99,111)`,
i.e. already the value to draw so the captured pixel lands on Qud's rendered value — round-tripped,
not assumed. Compensating twice would have made it visibly pale.

**Exporting chrome from a MODAL runs on the `uiQueue`, never the main-thread command queue.** A
popup parks Qud's turn thread, so `Tick`/`TickRender` may never drain while the thing being
exported is on screen — the same argument that puts the popup mirror's watcher there.

## Blitting a Qud sprite at Qud's own coordinate BLENDS it — snap the destination

Qud's layout is full of half pixels: the reputation indicator's `RectTransform` reads
`x=227 y=183.5 w=22 h=17`. Copy that straight into a `draw_texture_rect` and Godot samples the
22x17 sprite across two rows: measured 98 of 374 pixels at a flat 50% mix, three colours where
Qud has two. The result is a soft, doubled-looking glyph — exactly the "wrong icon" report, and
easy to misread as the wrong sprite rather than the right sprite drawn badly.

Unity point-samples the same rect back onto the pixel grid, so **Qud's output is always crisp**.
Round the destination position (`Vector2(x, y).round()`) whenever a 1:1 bitmap lands on a
fractional coordinate. Text does not need this — the font rasteriser handles its own hinting —
so this only bites the handful of places a pane draws pixels.

Residual worth knowing: Qud's point-sample of a 17-tall sprite in a rect on a half pixel DROPS
one source row and leaves its bottom row blank, and *which* row varies per list entry (row 8 for
the first faction, row 12 for the second, both rects at `.5`). That is float noise in Unity's
rasteriser, not a rule; Raves draws all 17 rows and is one row taller. Don't try to reproduce it.

## An extracted UI sprite may only exist on a LIVE screen (the atlas trap, second instance)

`TitleExporter.ExportNamedSprite` scans `Resources.FindObjectsOfTypeAll<Sprite>()`, which never
sees an atlased sprite's runtime instance — it finds nothing and writes no file, silently. Read
the sprite off the `Image` that is DRAWING it instead: `UiProbe.ExportChrome(target)` walks a live
screen, and `UiProbe.ExportLoadedSprite(name, dest)` scans every loaded `Image` (including
inactive ones, so a status screen the player has opened once still works when it is off screen).

Getting the factions indicator out was therefore: `hv goto qud status_reputation`, then
`hv bridge uiprobe target=FactionsStatusScreen`. The client must degrade when the file is absent —
`StatusPaneFactions` falls back to the solid rect rather than drawing nothing.

## A screen's order is the SCREEN's, not the order the constants are declared

`XRL.UI.JournalScreen` declares `STR_LOCATIONS, STR_CHRONOLOGY, STR_OBSERVATIONS, …`; the journal
draws them in `Qud.UI.JournalStatusScreen.categoryInfos` order, which puts Chronology **fifth**,
not second. We had shipped the declaration order, so Raves' journal tabs — and Q/E cycling — were
in the wrong sequence.

It survived because the strip was drawn as TEXT: one plausible ordering of seven words looks like
another, and nothing in a capture said otherwise. It died the moment the cells became ICONS and
each one could be matched against Qud's own screenshot by pixel mask. Where a list's order comes
from a different type than its contents, check the type that DRAWS it.

## Qud on its OWN modern menu parks the turn thread — and `gameQueue` then swallows clicks

CLAUDE.md's rule is "gameQueue is dead while Qud is in the BACKGROUND". There is a second way to
kill it, and it is easier to hit: Qud sitting on one of its own modern menus. A status screen or the
Looker parks the turn thread inside that screen's loop, not in `Keyboard.getvk(pumpActions: true)`,
which is the only place `gameQueue` drains. A queued task does not fail — it waits.

Symptom, and it is a convincing impostor: every paper-doll and item-list click in Raves' Equipment
tab does nothing, and reads as a broken click handler. It is not. The handler ran, the hit test hit,
the action queued, and the queue was asleep. Then when Qud finally returns to play, the backlog
fires at once — on whatever the ids resolve to by then. Measured 2026-08-09: an interaction menu
opened for a "cracked lens" nobody had clicked.

`Bridge.GameQueueDraining(out view)` is the check; `InventoryExporter.Twiddle` refuses and logs
rather than queueing. Since 2026-08-10 the same refusal also sits on the RECEIVE path:
`OnPayload`'s fall-through — every command not handled inline on the socket thread — used to
`Server.Incoming.Enqueue` unconditionally, and Incoming drains on the same parked turn thread
(Tick/TickRender), so a `navclick`, `interact`, `moveto`, `nearby` or `wish` sent while Qud sat
on the Book logged *nothing* and fired the moment the popup chain cleared. Measured before the
fix: a LookButton press sent on the Book pressed itself after play resumed. Now the fall-through
asks `GameQueueDraining` first and refuses loudly, naming the command and the screen. The inline
handlers stay exempt on purpose — each already runs on a queue that drains (`uiQueue`) or wakes
the turn thread itself (`Keyboard.PushCommand`/`PushKey`).

(A correction to an earlier belief: `invaction` is handled INLINE on the socket thread, so
Twiddle's guard fires on any screen, the Book included — measured. The gap was never the click
path; it was the fall-through set.)

Two things follow for anyone driving the pair:

- **Don't leave Qud parked** after a parity capture. `hv goto qud in_game` when you are done.
- **A "regression" in a click path is worth testing against Qud in play first.** Also check the
  probe itself: the first click I sent to disprove this landed in the 10px gap BETWEEN two filter
  cells and changed nothing, which looked like more evidence for the wrong theory.

## A legacy VIEW NAME is not a legacy screen — check the sampled window

`GameManager`'s view name and the UI window behind it are two different facts, and Qud's Book is
the case where they disagree. Reading an item's "show effects" pushes the game view **`Book`** —
the same name `BookUI`'s console loop uses — but with `Options.ModernUI` on, `BookUI.ShowBookByID`
returns early into `BookScreen.show(...)`, a modern `Qud.UI` window. The mod's own sampler says so
in one line: `view=Book`, `window=BookScreen`.

That matters because the two kinds take input from different places and share none of it.
Measured 2026-08-09, exits tried against both the Book and the Looker (a genuine legacy screen):

| | Looker | Book |
|---|---|---|
| OS/HID Escape | no | no |
| the mod's LEGACY key queue (`key key=escape`, `Keyboard.PushKey`) | yes | **no** |
| the mod's `uiback` | **yes** | **yes** |

So the shape of the rule is: **`uiback` first, always.** It is the only exit that spans both
kinds — the Book through `FireInputButtonEvent(CancelButton)`, the Looker through `uiback`'s last
rung, whose injected `Cancel` FrameCommand `Keyboard.metaMousecommands` maps to `Keys.Escape`,
which is precisely what the Looker's `getvk` loop is waiting for.

The cost of not knowing this was a session: the OS-level attempts failed, the screen was written
off as having no exit, and Qud was restarted and the save reloaded. `hv back` was never tried.
Highvisor now models both screens with `uiback` exits, plus a generic `unknown -> in_game` edge so
an unmodelled screen costs one bridge call instead of a restart (highvisor `docs/05-driving-input.md`).

## `MOUSE_FILTER_STOP` does not stop the WHEEL

A full-rect Control with `MOUSE_FILTER_STOP` is the obvious way to make an overlay modal, and
for clicks it works: Godot finds the control under the cursor, delivers the button, and marks
the event handled, so nothing downstream sees it. **The wheel is not delivered that way.**
Godot propagates a wheel event UP the Control chain looking for someone who wants it (so that
nested `ScrollContainer`s work) and marks it handled only when a control calls
`accept_event()`. No call, no consumption — the tick continues to `_unhandled_input`.

Reported from use (2026-08-10): *"While you're scrolling Skills, the background playfield
receives the scroll wheel messages and zooms."* Exactly that — the status screens' root is
full-rect STOP and its panes scroll correctly, and every tick ALSO reached `Main`'s camera
handler. Measured against a control: two captures with no input differ by 0.00, one scroll
moved the playfield by 1.37 and visibly enlarged the tiles behind the modal.

Two things follow, and the second is the one that generalises:

- **Consume it at the modal.** `_root.accept_event()` for `InputEventMouseButton` /
  `InputEventMouseMotion` in the root's `gui_input` handler.
- **Guard the RECEIVER too.** `Main._modal_owns_input()` is one definition of "a modal owns
  input" (mirrored popup, item picker, or a MainFrame overlay), asked by every branch that
  drives the world. The mouse branch was the only one that never asked — the keyboard path,
  the Esc path and `cell_at` all did, and `cell_at` even states the rule in a comment ("a
  modal owns the whole screen even where it does not paint"). A rule written down in three
  places and applied in three of four is a rule with a hole in it.

`tools/regression/modal_input_audit.py` pins both halves statically. It found two more
instances on its first run: ControlMappingScreen had the same missing `accept_event()` (fixed
with it), and PopupOverlay/PickerOverlay have a STOP root with no handler at all — their
wheel is stopped only by the receiver-side guard, which the audit reports rather than hides.

## A synchronous Qud popup has THREE possible threads and only one is right

`Popup.ShowYesNo` / `Popup.Show` / `PickItem.ShowPicker` / `EquipmentAPI.TwiddleObject` all
BLOCK on a modal. Where the bridge calls them from decides what happens, and the three
outcomes look nothing alike:

| thread | outcome |
|---|---|
| `uiQueue` task | DEADLOCK — the modal's wait never resolves |
| `APIDispatch.RunAndWaitAsync` (threadpool) | the modal flashes up and **auto-answers its default** |
| `gameQueue.queueSingletonTask` | correct — the modal opens and waits for a real answer |

The middle one is the dangerous one, because it is also what Qud's OWN screens do — and
correctly, because those have already parked the turn thread. A bridge-driven call has not:
the turn thread is free, spinning in `XRLCore.PlayerTurn`'s wait-for-input loop, which runs
`GameManager.Instance.CurrentGameView = Options.StageViewID;` unconditionally every
iteration. The popup PUSHES the PopupMessage view, the next iteration slams it back to
Stage, `UpdateView` hides the window, `Hide()` fires `onHide` -> `TrySetCanceled`, and the
`Wait()` throws inside an `async void` where nothing can catch it. The Show call then
returns its untouched default.

Copied three times, fixed three times, a week apart each:

- `Twiddle` (2026-08-08) — the item menu executed its own highlighted row; measured 6/8.
- `SelectNode` (2026-08-10) — reported as *"clicking on a skill instabuys it — a popup pops
  up, but it goes away right away"*. The default of the buy confirm is **Yes**, so the
  player's skill points were spent by a question nobody was allowed to answer.
- `EquipPicker` (2026-08-10, same pass) — unreported, found by grepping `APIDispatch` after
  the second one. Same shape, same fix, before anyone lost an equip to it.

**The lesson that took three tries: a comment recording the wrong cause is worse than no
comment.** SelectNode's said "must run on the GAME thread via APIDispatch", which sounds
right, names the correct goal, and prescribes the thing that breaks it — so each new caller
copied it faithfully. When a fix lands, fix the SIBLING COMMENTS too, or the next
copy-paste reintroduces the bug with your own words as justification.

`Bridge.GameQueueDraining` refuses instead of queueing when the turn thread is parked; every
one of these three now asks it first (a silently-queued PURCHASE is the worst of all worlds).

## The cybernetics terminal is ONE channel, all the way down

Worth knowing before adding screens to it: every stage of the becoming-nook flow — the welcome
menu, the Learn sub-screens, the implant list, the **body-part picker**, the progress/result
screens, and Qud's own refusals — is the same `CyberneticsTerminalScreen` with a different
`CurrentScreen` behind it. They all arrive on the one `cyber` frame as body + options + footer.
No stage needed its own mirror, and a new stage Freehold adds will very likely need none either.

Two things the flow taught, both of which only appear once you drive it:

- **The body carries markup, and `&X` is a RUNNING colour.** Options always went through
  QudText; the body did not, because every body up to the install refusal happened to be plain.
  Parse the body WHOLE — `&y` set on line 1 is what paints line 4, so splitting into lines
  before parsing drops the carry and repaints the tail in the default.
- **The footer lags one screen, IN QUD TOO.** Installing a 1-point implant lands on a
  "successfully installed" screen still reading `Points Used: 0`; it reads `1` on the next
  screen. Qud composes FooterText in `BeforeRender`, so the completion screen shows the count
  from before the commit. Checked against Qud's own capture rather than assumed — a mirror that
  "fixed" this would be wrong, not better.

Qud's own guards run first-party and are the proof the round-trip is real: with 2 of 2 licence
points used, picking an implant returns "Insufficent license points to install", and the costs
in the list are `{{R|…}}` red. Free a point and the same list re-renders `{{C|…}}` cyan. Nothing
on the Raves side decides any of that.

The UPGRADE LICENCE branch behaves the same way: its body carries the credit-tier table in
`&`-markup, its option reads "Upgrade Your License [{{C|1}} credit] {{R|insufficent credits}}",
and driving it at 0 credits returns Qud's own "&RInsufficient credits to upgrade". Verified to
that guard; a SUCCESSFUL upgrade still wants a `CyberneticsCreditWedge` in hand.

**`hv wish <blueprint>` PUTS THE OBJECT ON THE FLOOR, NOT IN YOUR PACK.** Qud's wish handler
ends with

    foreach (Cell adjacentCell in who.CurrentCell.GetAdjacentCells())
        if (adjacentCell.IsEmpty()) { ...; adjacentCell.AddObject(gameObject22); ... }

— an ADJACENT EMPTY CELL, and `Popup.Show("No adjacent empty squares to create your wish!")`
when there is none. Nothing is ever added to the inventory.

I got this wrong twice in a row and the shape is worth keeping. First I blamed the blueprint
name; then I "proved" the whole wish path dead by wishing `Chem Cell` twice and watching
`inventory.json`'s chem-cell row count stay at 2 — a probe that could not have succeeded no
matter how well the wish worked, because wished items never go there. Reading the SNAPSHOT's
zone instead found every one of them on the ground, wedges included:
`{{C|cybernetics credit wedge}} {{C|1}} x2`.

**Check a wish on the FLOOR (the snapshot's cells), never in inventory.** And the general form,
which this session hit three times: when a check comes back negative, ask whether the check
could have come back positive at all before believing it.

**…but WALKING OVER one moves it to your pack, and `CmdGet` then reports "There's nothing to
take."** Qud auto-takes currency-like objects as you step on the cell. Collecting the wedges the
next day, one `move dir=W` was the whole pickup, and the `CmdGet` I sent afterwards to "do" it
raised a popup saying the floor was empty — which reads exactly like the move having failed.
Qud's own message log is the arbiter and said so plainly:

    :: You pass by a cybernetics credit wedge 1¢ x2 and a chem cell x2.
    :: You take the cybernetics credit wedge 1¢ x2.

So the pair of rules is: a FRESH wish is on the floor; once you have walked over it, it is in the
pack, and "nothing to take" is the confirmation rather than the failure.

**`snap.py find <text>` matches TILE PATHS, not display names.** `find wedge` and `find "chem
cell"` both printed `(none)` while the wedge was sitting in the inventory and the chem cell in a
stun rod — neither has "wedge" or "chem" anywhere in its tile filename, so no object of that name
could ever match. `find cyber` works only because the terminal's tile really is
`sw_cyberterminal.bmp`. Another probe that cannot succeed; it happened to agree with the truth
here, which is the dangerous kind. Search inventory/zone JSON by `name` when you mean a name.

Also ruled out for spawning a test object here: `check bp=…` calls `ObjectChecker.ClearZone`
first, which would delete the becoming nook itself.

**And the terminal is where the parked-queue guard earned itself in the field.** Wishing while
the terminal was UP was refused out loud:

    [raves] refused 'wish': Qud is on CyberneticsTerminalScreen, where the turn thread is
    parked and Server.Incoming never drains — the command would sit and fire late on whatever
    screen comes next.

Exactly right: `wish` is a fall-through command, the terminal parks the turn thread, and before
that guard the wish would have sat in the queue and fired later against whatever was on screen.
Quit the terminal first, then wish.

## The cybernetics terminal, measured against Qud a second time (2026-08-10)

Driving the licence upgrade end to end put three more parity defects on the board that the first
pass had missed. All three were invisible until the two screens were measured side by side; none
of them were guessable from the code.

**Qud draws the TOP rule MIRRORED.** Top and bottom rules are the same three sprites in the same
16px box, and Qud's own probe puts them exactly where Raves already had them (`polat top header`
y238.44 = vp+RULE_DY, `polat bottom header` y774.56 = vp+RULE_BOT_DY). Yet Qud's top-rule line
lands on rows 2-3 of its box and its bottom-rule line on rows 13-14: the sprite is flipped so the
line hugs the panel's OUTER edge and the notch always points inward. Drawing both unflipped put
the top rule 10px low on every terminal screen. The tell that it was not a constant: the bottom
rule matched to the pixel while the top did not, off the same anchor. Flip the IMAGE (`flip_y()`
into a second texture), not a negative-height `Rect2` — the fillers tile, and a negative size is
not reliably a mirror under `tile=true`.

**A trailing newline is not a line.** `split("\n")` on a body that ends with `\n` returns a final
empty element, and counting it pushed the option rows exactly one `LINE_H` (+21px measured) down
— but only on the screens whose body happens to end that way, which made a plain off-by-one look
screen-specific. The upgrade sub-screen's body ends `"…tiers 25+\n"` (8 elements, 7 rendered
lines); the welcome screen's does not, and matched all along. Qud puts the options one gap below
the last line WITH INK. Read the body off the wire before theorising about it — a 12-line socket
reader settled in one shot what the pixel arithmetic could only narrow to "n is 8, not 7".

**`_draw.size` is empty, so a full-rect draw off it is a silent no-op.** Qud dims the whole screen
behind the terminal (`OuterBackground`, 1920x1080, `#041111cc`), which Raves was not drawing at
all — its terminal read twice as bright as Qud's everywhere outside the text. The first fix,
`draw_rect(Rect2(Vector2.ZERO, _draw.size), C_SCRIM)`, changed nothing on screen: everything else
in that overlay is drawn in ABSOLUTE screen coordinates, and Controls do not clip by default, so
`_draw` renders correctly while its own rect stays (0,0). Size a full-screen rect from
`get_viewport_rect().size`. Caught only because the after-measurement was byte-identical to the
before — which is the whole reason to re-measure rather than re-look.

That scrim is also the counter-example to the "Icon Panel" rule one section up. Both are nodes in
the same layout dump; the difference is that the capture AGREES with this one. Raves' undimmed
playfield measures RGB(18,46,45) where Qud measures (7,23.3,23.2), and `#041111cc` composited at
alpha .8 over Raves' value predicts (6.8,22.8,22.6) — within half a level, on three separate
regions. Draw a dump node when the capture confirms it and not when it contradicts it; the
arithmetic tells you which case you are in.

## A POLL THAT RE-ARMS ON THE SUCCESS PATH IS NOT A POLL

Every `StatusScreens._load_*` ended with

```gdscript
get_tree().create_timer(1.2).timeout.connect(func():
    if visible and _tab == "equipment":
        _load_inventory())
```

and every one of them began with

```gdscript
if not force and _inv_pane != null and mt == _inv_mtime …:
    return
```

The re-arm sits BELOW the early return, so the chain dies the first time the file has not
changed — which is the normal case one tick after opening a tab. What looked like a 1.2s
heartbeat was really "read once at open, read once more 1.2s later, then never again", and
the pane then showed its open-time data until the tab was left and re-entered.

It hid for as long as it did because every visible symptom needs the data to change *while
you are looking at it*, and almost nothing does. Identification is the exception: examine a
weird artifact and Qud re-files the object out of Artifacts into its real category, the mod
re-exports — and Raves went on drawing `Artifacts / odd trinket` against an inventory.json
that already said `Trade Goods / gyre iron` (reported 2026-08-10).

**The rule:** a repeating `Timer` is re-armed by the engine. A one-shot re-armed by the code
path that just decided there was nothing to do can only run while there IS something to do,
which is the opposite of what a poll is for. If you write a self-re-arming timer, the re-arm
belongs above every `return` in the function, or it belongs in a `Timer` node.

Same family as **a check that cannot fail**: the loop reported healthy because it was never
running.

## Identification is the only thing that re-files an item, and it is three popups deep

Getting an item to change inventory category in-game means Tinkering's `examine`, which lives
inside the item menu, needs several tries at a random rate, and — observed 2026-08-10, driven
through Raves' mirrored menu — **drops the item the moment it succeeds** (`You identify your
odd trinket as a gyre iron.` / `You drop the gyre iron.`, four for four). A fixture that has to
survive that to observe one boolean is not a fixture.

So the bridge carries two test commands:

- `identify id=<objid>` / `identify all=1` — `GameObject.MakeUnderstood()` on the turn thread,
  then a re-export. Logs `was -> now` per object, because after the call there is no way to ask
  what the category used to be.
- `cybercarry count=<n>` — implants **unidentified in the pack** (the chest `cyberchest` builds
  is right for the terminal and useless to the inventory screen, and nothing cheap moves a
  chest's contents into the pack — walking onto it does not take them).

Category is not stored: `GetInventoryCategory()` raises an event that `Examiner` answers with
`"Artifacts"` while `!Understood()`. Flipping understanding re-files the object with no further
call, which is what makes the fixture a fair test of the export rather than a way of faking one.

## A SPAN'S COLOUR CODE IS NOT ALWAYS ONE CHARACTER

`{{rules|…}}`, `{{painted|…}}`, `{{rocket|…}}` — the code can be a SHADER NAME, and QudText
resolved those by taking the first character. `rules` became `r`, so every rules line in every
item description drew dark red where Qud draws it light blue
(`<shader Name="rules" Type="solid" Colors="C"/>`). Reported 2026-08-10.

Qud's registry (`ConsoleLib.Console.MarkupShaders`, 152 entries) is exported to `shaders.json` by
`ColorsExporter`, name -> `{kind, colors}`. Each kind is a pure function of character position, so
there is nothing time-varying to approximate:

| kind | colour of character `i` of an `n`-character run |
|---|---|
| `solid` | `colors[0]` |
| `sequence` | `colors[i % len]` |
| `alternation` | `colors[i * len / n]` (integer division, as in C#) |
| `bordered` | `colors[1]` on the first and last character, else `colors[0]` |

`QudText._expand_shaders` rewrites the positional kinds into one single-char span per character
before either parser runs, so `to_bbcode`/`runs` still know nothing about shaders and a `solid`
name stays one flat span. A run containing its own markup or a `{ } | & ^` is left alone rather
than re-escaped.

**An unknown multi-character code falls back to WHITE, never to its first letter.** That shortcut
is the bug; Qud's own renderer leaves a shader it cannot find uncoloured.

## PRE-COMPENSATION IS PER SPRITE, AND THE FILE TELLS YOU WHICH

`QudChrome.brighten()` pushes pixels through `INV` so Raves' canvas sag lands them on a target.
Whether a given sprite wants it is **not** decidable from "is it extracted" — both answers occur
among files sitting in the same directory, and an earlier version of this entry said otherwise and
was wrong in the dangerous direction (it would have had someone "fix" the status tab icons, which
are correct).

**The test, and it is one command:** compare the FILE's ink against what QUD draws.

| sprite | file texels | Qud draws | treatment |
|---|---|---|---|
| `title/chrome/statusIcon_equipment_on.png` | (166,149,73) | (166,149,73) | **brighten** |
| `tiles/divider_orn.png` | (56,79,90) | (51,70,82) | **raw** |

- **File ≈ Qud's screen** → the export already holds an OUTPUT value. It is a measured colour in
  sprite form, so it needs `INV` to survive the canvas, exactly like `S_RULE`. Most extracted
  chrome is this: `StatusPaneSkills` records the same finding independently — "the raw sprite drawn
  1:1 lands ~6/255 dim of Qud's capture".
- **File LIGHTER than Qud's screen** → the export holds Qud's INPUT, and Qud's own canvas sags it
  on the way out. Draw it raw and Raves' canvas performs the same sag. Brightening cancels Qud's
  and leaves the art ~12% light.

The divider ornament is the second kind, verified all three channels: texel (58,80,92) →
Qud (51,70,82), and `QudChrome.INV[51]=58`, `INV[70]=80`, `INV[82]=92`. Dropping `brighten` there
took its mean per-channel difference from 10.87 to 1.36 and made the knob pixel-identical.

The likely cause of the split is the EXPORT PATH — `UiProbe.ExportLoadedSprite` writes the texture
bytes, while the older chrome dumps appear to carry output-space values — but that has not been
confirmed, so **measure rather than infer from where the file came from**. All seven `brighten()`
call sites were checked on 2026-08-11 and every one of them is correct as written.

### Residual, recorded rather than chased
14 of 518 opaque ornament pixels still differ (max 53), all on the sprite's 1px dashed detail rows
(52, 75, 85, 88). Qud draws this Image at `y=516.5` — a half pixel — so Unity's bilinear softens
exactly those single-pixel details while leaving solid blocks alone. Matching it would mean
reproducing a Qud rendering artefact.

## INTERIOR COLUMN DIVIDERS ARE FRAME CHROME, NOT PANE CHROME

An old note in `StatusScreens` said interior dividers "belong to the panes". They do not, and no
pane drew them: the equipment tab ran its item list straight up against the paper doll and
tinkering had nothing between its three columns. They are in `TAB_VDIV` now, beside `TAB_VRULES`.

Read the geometry off Qud's own RectTransforms (`hv bridge uiprobe target=StatusScreensScreen`),
never off a screenshot — the dump names the rule halves (`VLine`/`Image`), the 7x7
`polat-center-divider-knob` caps and the 40x122 `polat-vertical-divider-decoration`, with exact
positions. **Equipment and tinkering assemble the same parts differently** (equipment inserts 11px
spacers and two inner knobs, tinkering butts the ornament straight onto both halves and caps only
the outer ends) — do not tidy them into one shape.

`hv bridge sprite img=<sprite-name> file=<dest.png>` extracts any named sprite off whatever Image
is drawing it, so new chrome no longer needs a mod edit and a restart. Note `img=`, **not** `name=`:
`name` is the command key in the same field bag, so asking for it back hands you the string
"sprite".

**Sprite y positions must be floored before drawing.** Qud's RectTransforms sit on half pixels and
Unity lands them on the pixel grid; drawn at the raw `y`, Godot blends each row across two and the
ornament grows a faint copy of every edge (measured: extra lit runs at 568/572 where Qud has bare
background). The frame Control is `TEXTURE_FILTER_NEAREST` for the same reason.

## THE PAPER DOLL'S TORCH IS SUPPOSED TO BE A DIFFERENT COLOUR EVERY TIME

Reported 2026-08-10: "switching between tabs sometimes makes the torch yellow, not red. It's
inconsistent." It is inconsistent, and so is Qud's.

A lit torch animates from `XRL.World.Parts.TorchProperties.Render` — **not** `AnimatedMaterialFire`,
which is what the matching colour set led me to assume first, and assuming it exported no `anim`
at all because a torch has no part by that name:

```csharp
if ((ChangeColorString || ChangeDetailColor) && pLight.Lit) {
    int num = (XRLCore.CurrentFrame + FrameOffset) % 60;
    if (!Options.DisableTextAnimationEffects) FrameOffset += Stat.Random(1, 5);
    char c = 'W';
    if (num < 15) c = 'R'; else if (num >= 30 && num < 45) c = 'r';
    if (ChangeDetailColor) E.DetailColor = c.ToString();
}
```

The two parts happen to share the cycle character for character, so ONE client-side table serves
both — but they are different parts and only one of them is on a torch. Note the `pLight.Lit`
guard: an unlit torch does not animate at all, because `Extinguish()` writes `DetailColor = "r"`
once and leaves it. That is why the unburnt torch in the item list is stably dark red.

The flame cycles **&R (bright red) / &W (gold) / &r (dark red)** — exactly the three colours that
turned up on screen. `Qud.UI.EquipmentLine.setData` calls `RenderForUI("Equipment")` **once**, when
the line is built, and the Image keeps that colour; Qud does not re-render the doll icon per frame.
So Qud freezes one arbitrary phase per screen open, and measured side by side:

| | sitting on the tab | re-opening the tab |
|---|---|---|
| Qud | dark red ×6 (frozen) | gold, gold, gold, gold, red, red |
| Raves | gold ×8 (frozen) | gold, dark red, gold, red, gold, gold |

Same three colours, same freeze-on-build, same randomness — Raves was mirroring the *mechanism*
faithfully, and two independent samples of a random phase cannot be made to agree. So the fix is
not a colour: the export now names the ANIMATION (`anim: "fire"`) instead of shipping one sampled
frame and calling it the object's colour, and the client decides.

**Gold is half the cycle**, which is why an unsuspecting sample kept coming up yellow:

| phase | colour | share |
|---|---|---|
| `num < 15` | `&R` bright red | 25% |
| `15–29`, `45–59` | `&W` gold | **50%** |
| `30–44` | `&r` dark red | 25% |

Two independent samples therefore agree only Σp² = **37.5%** of the time. User mode runs the cycle
(a torch reads as a torch); 1:1 pins the gold phase, which is the single likeliest thing Qud's
frozen icon is showing and lifts agreement to **50%**.

**`RenderForUI` is not a read, and it is not cosmetic either.** `FrameOffset += Stat.Random(1, 5)`
runs on every call — `Stat.Random`, the GAMEPLAY stream, not `RandomCosmetic` (that is
`AnimatedMaterialFire`; the two parts differ here even though their colour tables do not). So every
inventory export of a player carrying a lit torch drew from the same RNG the game rolls dice on.

**Fixed 2026-08-11 — never call `go.RenderForUI` directly; call
`InventoryExporter.RenderForUIStable`.** It clears `ChangeColorString`/`ChangeDetailColor` for the
duration of the call, which makes Render's own guard
(`(ChangeColorString || ChangeDetailColor) && pLight.Lit`) false and skips the whole animating
branch — no roll drawn, no offset drift — and restores them in `finally`, or a throw mid-export
would leave a torch permanently unable to flicker *in Qud itself*. What comes back instead is the
standing `DetailColor`, which `Light()` sets to `"W"`: the same gold 1:1 pins, and stable.

Measured on a genuinely lit torch (Qud's own item menu offering `[x] extinguish` is the proof it
was lit — not the export under test), 12 re-exports: `detail` **W ×12** where it used to wander
R/W/r, `tile` `sw_torch_lit.png` ×12, `anim` `fire` ×12. **That last column is the restore check**:
`AnimKind` returns `"fire"` only while one of the two flags is true, so a leaked suppression would
have shown up as `anim: (none)` from the second export on.

### Getting a torch to STAY lit for a test

`Options.AutoTorch` (`OptionAutoTorch`, default **Yes**) extinguishes a lit torch at end of turn
whenever the player `IsUnderSky() && IsDay()` — so on any surface fixture in daylight it lights and
goes straight back out, and the export you then read says `torch (unburnt)` while you are certain
you just lit it. Turn it off for the run and back on afterwards:
`hv bridge setoption id=OptionAutoTorch value=No`. Two other refusals print a message first
(`IsUnlightableBecauseOfLiquidCovering` / `…BecauseOfSubmersion`); AutoTorch is the silent one.

Two more traps met while driving this:

- **`hv bridge popup` with no `action` is not a query.** It falls to the `else` branch, fabricates
  an `Accept`, and activates the highlighted row — which unequipped the torch. Reading a popup
  means reading the `popup` FRAME (`Bridge.read_frame("popup", …)`), never sending the command.
- **Item-menu labels carry markup INSIDE the word** — `l{{hotkey|i}}ght`, so matching `"light"`
  against the raw label finds nothing. Strip `{{tag|text}}` innermost-first before matching, and
  refuse to act when the match is not unique rather than falling back to an index.
- **`itemaction` cannot reach a torch.** `FindEquippedById` searches `GetMissileWeapons()` only; it
  was written for the battery-swap case. Drive the item menu for anything else.

## THE ITEM MENU RE-OPENS AFTER AN ACTION THAT DOES NOT MOVE THE ITEM

`EquipmentAPI.TwiddleObject` is a **loop**, and this is the shape of it:

```csharp
InventoryAction a = ShowInventoryActionMenu(...);
...
a.Process(GO, Owner, Telekinetic);
if (!GO.IsInvalid() && currentCell == GO.CurrentCell
    && inInventory == GO.InInventory && equipped == GO.Equipped)
    continue;          // <- nothing moved: SHOW THE MENU AGAIN
break;
```

Drop, equip and throw all move the object, so the loop breaks and the menu closes. **Examine does
not**, so the menu comes straight back — and that is Qud's behaviour, not Raves': the same loop
runs behind Qud's own status screen. A human sees the menu reappear and presses Esc.

**The trap: the menu's default row is `> [d] drop`.** Any input that arrives at a re-shown menu
without being aimed at it activates the default and destroys the item. That is how "examining an
artifact drops it (4 for 4)" got into the 0.8 tag as a Raves bug — a scripted key sequence sent
`space` after the examine result, the menu had already re-opened underneath it, and the space took
`drop`. **The report was my harness, not the app.**

Re-measured 2026-08-11 with deliberate, observed steps: raise menu -> `x` (examine) -> dismiss the
result -> **menu re-opens** -> Esc. The artifact survived, identified as an air current microsensor,
and re-filed from Artifacts into Cybernetic Implants. No drop.

**When driving the item menu, never send a blind key after an action.** Read the popup kind first
(`hv state` reports `popup=menu` vs `popup=message`) and aim each key at the popup that is actually
up. Same family as the torch: a bug reported against the app that measurement dissolves into the
way it was being measured.

# Working notes for Claude (and future humans)

**Docs map:** `README.md` is the hub (architecture, platform constraints, Qud data model, API).
Subsystems: [`docs/rendering.md`](docs/rendering.md) (the 3D pipeline + **voxel walls**),
[`docs/tools.md`](docs/tools.md) (Python tools + in-viewer inspector/report + the **Python-first
workflow**), [`docs/protocol.md`](docs/protocol.md) (wire format), [`docs/roadmap.md`](docs/roadmap.md)
(**forward strategy**: persistent chunked block-store — fog of war, remembered zones, freeze/unfreeze,
Z-height, cross-zone distance, future block-editing fork). Read the relevant page before
changing a subsystem.

`README.md` explains the project and the data model. **This file is the local
environment**: the exact paths and commands, so no session has to rediscover
them after a compaction. If a path here is wrong, fix it here.

## Branches & platform (parallel dev on Mac + PC)

Two working branches off `main`: **`dd/mac`** (the Mac) and **`dd/pc`** (the second computer,
Windows). `main` is the shared, cross-platform base. To keep merges clean:

- **All OS-specific tooling is behind a seam** — `tools/capture/plat.py` dispatches by OS to
  `plat_mac.py` / `plat_win.py`. Cross-platform code (bridge, Godot, mod logic) is shared.
  **PC work = implement `plat_win.py`** (mirror `plat_mac.py`'s function names; guidance is in its
  docstring). Do NOT edit the other OS's backend — that's exactly what would cause merge conflicts.
- The **"Local paths" table below is macOS / this machine**; the PC branch keeps its own values
  there. Expect that section to differ per branch — that's fine, not a conflict to resolve.
- Everything else (`godot/`, `mod/`, cross-platform `tools/`) should merge cleanly; coordinate on
  shared feature files as usual.

## Local paths (this machine — macOS)

| what | where |
|---|---|
| repo | `/Users/homefolder/personal-git/raves-of-qud` |
| Godot 4.7 binary | `/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot` |
| Qud install | `~/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app` |
| Qud managed DLLs | `<Qud>/Contents/Resources/Data/Managed` |
| Qud game data (XML) | `<Qud>/Contents/Resources/Data/StreamingAssets/Base` |
| mod deploy target | `~/Library/Application Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/` |
| exported tiles | `~/Library/Application Support/RavesOfQud/tiles` |
| standing overrides | `~/Library/Application Support/RavesOfQud/overrides.json` (seed copy committed at repo `overrides.seed.json`) |
| inspector output | `~/Library/Application Support/RavesOfQud/selection.txt` (latest), `selections.log` (history) |
| Qud crash log | `~/Library/Logs/Freehold Games/CavesOfQud/Player.log` |
| bridge socket | `127.0.0.1:48710` |

## The commands that actually get used

```bash
# type-check the mod against the REAL Qud API (catches API drift before a restart)
dotnet build mod/RavesOfQudBridge.csproj

# deploy the mod  — REQUIRES A FULL QUD RESTART (mods compile at startup)
cp mod/*.cs mod/manifest.json ~/Library/Application\ Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/

# validate the Godot scripts parse + _ready runs, without a window.
# "Raves bridge: connected" and no errors == clean. .gd changes need NO restart.
# NB: after ADDING a `class_name`, the headless parse fails ("Could not find type X") until an
# editor rescan (the class cache lives in the gitignored .godot/): run `--editor --quit` once first.
/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot --headless --path godot/ --quit-after 120

# build a CRISP (HiDPI) macOS .app — dev-run windows are soft on Retina (see "Display" below).
# Exports + re-signs ad-hoc; output is build/RavesOfQud.app (gitignored). Needs the 4.7 export
# templates installed (one-time, ~1.3GB, Editor > Manage Export Templates).
tools/build_macos.sh   &&   open build/RavesOfQud.app

# read live state off the bridge (BLOCKS until the player takes a turn)
python3 tools/capture/snap.py summary
python3 tools/capture/snap.py cell 66 6
python3 tools/capture/snap.py water
python3 tools/capture/snap.py find glowfish

# inspect an exported tile's pixels / opaque band / transparency
python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp
python3 tools/capture/tile.py --list water

# DRIVE the game headlessly — works with Qud UNFOCUSED (build 2026-07-24k+; see docs/tools.md).
# move -> Qud, cam/shot/fph -> Godot via the godot_cmd file. Godot screenshots work unfocused.
python3 tools/capture/control.py move N 5
python3 tools/capture/control.py cam 1
python3 tools/capture/control.py shot     # -> shot.png (read it)

# Drive the onboarding UI with NO Qud needed (only the Godot window running):
python3 tools/capture/control.py onboard devices   # devices/ktype/layout/function/numpad/mouse/close
python3 tools/capture/control.py shot              # -> shot.png; read it to verify the screen
```

## Display & fonts

- **Dev-run windows are PIXELATED on Retina — a Godot limitation, not our bug. Don't chase it
  in-code.** Measured at the render target: a floating `--path`/editor window gets a NON-HiDPI
  backing (framebuffer = logical size, e.g. 1600x900), which macOS upscales 2x on a 2x display, so
  ALL text is soft. `allow_hidpi`, `content_scale_factor`, fullscreen and maximize were all ignored
  or rejected from dev-run (only exclusive fullscreen/maximize even reach native res, and macOS
  refused to switch modes). The fix is to EXPORT (`tools/build_macos.sh`): an exported .app sets
  `NSHighResolutionCapable` and renders native = crisp. So: dev-run for fast iteration (soft),
  exported .app when you need it crisp (reading UI, demos, tuning fonts). ~1 session was burned
  re-discovering this — check the render-target size before theorizing.
- **All UI font sizes come from ONE source of truth: `godot/UiFont.gd`** (`FRAC` = body px ÷ window
  height, `MIN` = absolute floor, role multipliers). Change `FRAC`/`MIN` → the whole app re-sizes.
  Press **L** in-app for the font ruler (Lorem Ipsum at each px).
- **It's AUTOMATIC via a project-wide default theme** — `UiFont.make_theme()` builds a Theme (body
  size + Atkinson font); Main assigns it to `get_tree().root.theme` and refreshes it on resize. So
  **any Control that doesn't override inherits the right size/font for free — including future UI.**
  That's how a whole imported file (CharacterCreator, zero overrides) was fixed without touching it.
  For a non-body size, prefer `theme_type_variation = "Title"/"Big"/"Caption"` (registered on the
  theme) over hardcoding; `UiFont.px(vp, role)` explicit overrides also work and win over the theme.
  **Do NOT hardcode a font_size number in new UI** — it escapes the source of truth.
- **A panel that sizes its font only at build time stays TINY** — the window is still small at
  `_ready`, and the panel never grows. Re-apply `UiFont.px(...)` on every SHOW/repaint (that was the
  bug on the selection log and report form), or hook `get_viewport().size_changed` like the mode label.

The `onboard` command jumps the wizard straight to a named screen so Claude can
photograph and verify each one. `shot` no longer depends on `renderer.tiles_dir()`
(it falls back to `InputModel.support_dir()`), so screenshots work before Qud connects.

## The feedback loop

Claude **cannot see the Godot viewport**. Don't ask the user to describe what
they see in words — that round-trip has been the main source of wasted effort.

1. User points at a cell in Godot: **Ctrl/Cmd+click**, or hover and press **I**.
2. `CellInspector` writes `selection.txt`, copies to the clipboard, and shows a panel.
3. Claude reads `selection.txt` directly — no transcription.

The report pairs **WIRE** (what Qud sent) with **RENDERED** (what `ZoneRenderer`
actually did, and at what Y). Every rendering bug so far has lived in the gap
between those two, so always read both halves.

## Screenshots — F12 in the Godot window

Claude **cannot** capture the screen: macOS `screencapture` fails without Screen Recording
permission (`could not create image from display`). So both apps capture themselves.

**Ctrl/Cmd + right-click a tile in the Raves window** is the one to use: it inspects that tile
*and* photographs both apps. One gesture produces everything needed to discuss it —

| file | what |
|---|---|
| `RavesOfQud/selection.txt` | the report: blueprint, tile, colours, flags, and what the renderer DID |
| `RavesOfQud/shot.png` | the Raves viewport, with the 3D marker on the picked tile |
| `RavesOfQud/qud_shot.png` | Qud's own window, for side-by-side comparison |

The text report is hidden from the shot (the marker stays), so the picture shows the scene
rather than the panel.

**F12** does the screenshots alone, without inspecting:

| file | what |
|---|---|
| `~/Library/Application Support/RavesOfQud/shot.png` | the Godot viewport |
| `~/Library/Application Support/RavesOfQud/qud_shot.png` | Qud's own window |

Godot saves its viewport directly; it also sends a `shot` command so the mod calls
`UnityEngine.ScreenCapture.CaptureScreenshot` — marshalled to the main thread via `uiQueue`,
same rule as tile export. Qud's file appears at end-of-frame, so allow a moment.

Claude reads both with the Read tool. This replaces the user manually screenshotting and
pasting, which is how most of this project's visual debugging has worked so far.

## Tile reports — two kinds, two places

Some things aren't in Qud's data: a water wheel runs east–west, but `sw_waterwheel_1` doesn't
say so. Inspect a tile (Ctrl/Cmd+click, or hover + I) and use the form (lower right). Cancel or Esc clears the selection. Destructive actions (Clear rules) are in the form's ☰ hamburger, not beside Submit. Submissions split by type:

**Standing rules** (shape, fill) → `~/Library/Application Support/RavesOfQud/overrides.json`,
keyed by tile family, one entry per tile:

```json
{ "tiles": { "sw_waterwheel": { "shape": "…E–W…", "fill": "…fill the holes…" } } }
```

`ZoneRenderer._load_overrides()` reads this **live** every frame. It is **config** — it persists
until changed. The form's **Clear rules** button removes a tile's entry; that is the undo. Never
hand-delete an entry to "resolve" a tile unless you mean to revert its render. Hand-editing the
JSON is fine (read-modify-write preserves it).

The tile→family reduction has **one** GDScript source, `ZoneRenderer.tile_family()`; the form
calls it rather than duplicating it, so a written key and a looked-up key can't drift. The
inspector prints `OVERRIDE shape=… fill=…` for any tile that has an entry, so a rule that
doesn't take (typo'd family, wrong tile) is visible, not silent. The C# `TileFamily()` in the
mod is a separate copy on purpose — it's server-side, used only for ground-dedup within a
snapshot, and never touches override keying.

**One-off notes** (colour, position, free text) → dated `.md` files under `reports/`, each with
the full inspector capture attached. These are **tickets**: read the directory for what's
outstanding, delete a file once addressed. Deleting a note never changes the render.

## Lighting is FAKED (the world is unshaded)

Day/night is a full-screen **MULTIPLY** ColorRect (`Main._grade`) tinting the whole viewport by
time of day — the only way to grade an unshaded scene. It sits on CanvasLayer 0, below the UI
(layer 1), so the world dims but panels/text stay bright. The mod sends `time` (hour, dawn/dusk
boundaries, `isDay`, label) from `The.Game.Turns` + the static `Calendar` fields. Night is a cool
moonlit blue, dawn/dusk warm, midday neutral. **Qud has no moon phase** — the only "moon" is the
Moonstair location — so none is sent or faked.

**Darkness is PER CELL, not from the grade** (caverns + the surface at night). A single MULTIPLY
can't do "black + bright light pools" — in LDR it dims the additive glows too — so the mod sends
each cell's `light` (`(int)Cell.GetLight()`) and `ZoneRenderer._build_darkness` lays a MIX-black
overlay that falls off to black around sources, matching Qud's own map. Consequence: underground and
at night the grade stays **bright** (`CAVE_TINT`/`NIGHT_TINT` are near-neutral, NOT dim) or it would
double-dark and kill the pools; the overlay does all the dimming. Full writeup + the frozen-zone /
sight-disc subtleties: **[`docs/rendering.md`](docs/rendering.md) §5a** — read it before touching lighting.


Every material in `ZoneRenderer` is `SHADING_MODE_UNSHADED` so tiles show their exact colours.
A real `OmniLight3D`/`DirectionalLight3D` therefore does **nothing** to the scene. Any "light"
must be **additive geometry**: `_place_light()` draws a warm radial ground-glow quad plus a
flickering flame billboard, both `BLEND_MODE_ADD`, which brighten whatever's behind them without
scene lighting. The mod sends `lightRadius` (from `LightSource.Radius` where `Lit`); Qud's flame
itself is procedural (particles + `AnimatedMaterialFire`), so there's no tile to extract.

## Prototype geometry algorithms in Python first

I cannot see the Godot viewport, so voxel/relief algorithms were being written straight into
GDScript and verified only by the user's screenshots — slow, and it hid an off depth order. Do the
algorithm in Python where its output is inspectable, THEN port. `tools/capture/voxel.py` is the
record of that discipline: it prototyped a luminance height-ranking rule and, in doing so, *measured*
the fact that governs the subsystem — Qud tiles are 2-bit masks, ≤3 colours ⇒ ≤3 heights, so no
ranking rule can add relief. That is why the walls shipped as **binary flush-and-carve** (non-bg
flush, bg carved) rather than any ranking — the renderer no longer ranks height at all (see
`docs/rendering.md` §4). Still the right habit for any NEW geometry/pixel algorithm: prototype and
inspect in Python before porting. (Lighting/shadow *appearance* still needs a screenshot; the
*algorithm* does not.)

## Debugging rules, learned expensively

- **A cell is not just its objects.** Qud paints a ground layer (dirt, grass) onto cells with
  no `GameObject` at all — 1103 of 2000 in a Joppa zone. `Cell.Render()` composites it. Missing
  this cost six wrong hypotheses and four shipped-but-inert fixes.
- **Measure before hypothesising.** When a search keeps coming up empty, verify the dataset is
  complete instead of refining the search. Emitting `nHeld`/`nRendered`/`nSent` per cell proved
  in one turn that nothing was being dropped, which eliminated the entire object path — after
  six rounds of guessing had not.
- **Know which build is running.** Mod `.cs` only compiles at Qud startup. `Protocol.Build`
  ships in every snapshot and the inspector prints it. Several rounds here were spent reasoning
  over a build that did not contain the fix being tested.
- **Verify a fix did something.** `RenderTile` was deployed and reasoned about for several
  rounds before `fg=` being empty on every object revealed it had never once fired.
- **The mod runs INSIDE Qud, so it can slow the GAME, not just Raves.** "Overworld sluggish" cost
  many rounds guessing at Godot before measuring the bridge: the mod built a full snapshot on every
  turn even with Raves closed (gate on `ClientCount`), and world-map travel auto-advances a BURST of
  turns — publishing ~60–100 snapshots/sec, pinning Qud AND starving Godot's frame loop (the
  "lighting eases slowly" tell). Measure `serverUs`, `renderBaseUs`, and the **publish RATE** (10ms
  gaps = a flood) before touching the client. See protocol.md "publish cadence".
- **A continuous visual glitch with NO new data is a client-side per-frame animation.** The world
  map's "oscillating light" persisted while idle (throttle → zero snapshots), which pinned it to
  `_process` (the torch flicker), not the data.
- **`--headless` cannot catch GPU/driver bugs — it renders with a dummy driver.** A `MultiMesh`
  with a `billboard_mode` material `SIGBUS`-crashed the Metal driver (`memmove` on the instance
  buffer); the headless parse-check rendered it "fine" because it never touches Metal. A crash in
  `AGXMetal*` / `IOGPUMetalResource` / a `memmove` under the RenderingServer flush is a GPU
  resource fault, NOT a GDScript error — suspect the newest instanced/material path, and prefer the
  proven `Sprite3D` billboard over per-instance `MultiMesh` billboards. Only a real windowed run
  proves a render path; headless only proves it parses and `_ready` runs.
- **A single-frame GPU-resource spike can overflow the Metal allocator — spread big builds across
  frames.** The world-map crash was NOT raw volume (the surface is the same cell count and never
  crashed); it was the number of *distinct* resources created in ONE frame (the world map has a
  different terrain texture/material per cell). The fix was the incremental build (`_ib_step`, a
  chunk per frame), not any single "bad node". When a deterministic same-stack GPU crash resists
  reasoning, STOP guessing and bisect *with the user* on a real machine: a couple of cheap toggles
  (does it crash on the surface? with the feature off?) localized it in two rounds after several
  wrong hypotheses. Trust the bisection over the theory.
- **No crash report means a HANG, not a crash — and a hang is usually fillrate/overdraw.** A `SIGBUS`
  always writes `~/Library/Logs/DiagnosticReports/Godot-*.ips`; when several "crashes" wrote none, the
  app was being GPU-timeout-killed, a different failure entirely. The cause was giant **additive**
  glow quads (10 × parasang-scale, 240×360, overlapping) — a fillrate bomb. Two lessons: (1) FIRST
  check for a fresh `.ips` to tell crash from hang before theorizing; (2) big per-object additive
  quads hang the GPU — but so does environment **bloom** on this setup (a full-screen multi-pass
  post-process, on top of DOF + fog, at the ~4K external-display window size, tips the M1 Pro past
  the GPU timeout). The only fill-free "brighter" is an **HDR modulate on an alpha-scissored sprite**
  (clamps toward white, no halo, no extra pass); a real glow *halo* needs a smaller window or fewer
  post-passes. Budget GPU fill/post-process for the WORST display (4K), not the laptop panel. Also:
  a mid-bisect "still crashes" can be a stale build — confirm a `⟳ Reset`/relaunch actually took.
- **Prefer accessors to fields.** `Render.getTile()` / `getRenderString()` resolve what is
  actually drawn; the `Tile`/`RenderString` fields are static blueprint values, empty for
  anything runtime-chosen.
- **Verify a value, don't trust a field name.** `ColorUtility.CAMERA_BACKGROUND` sounds like the
  world's background colour. It is the alias `"camera background"` → `#40a4b9`, plain cyan.
  Trusting it turned the entire world turquoise.
- **Vertex-colour albedo needs `vertex_color_is_srgb = true`.** Godot defaults it to `false` and
  treats per-vertex colours as *linear*, so sRGB palette values (from `_qud_color`) render pale and
  desaturated — the wall reds came out muddy tan (#805840, sat 0.50) instead of brick (#993326,
  sat 0.75). Tiles that use an albedo *texture* are unaffected (textures carry an sRGB flag); only
  colour baked into vertices needs this. Diagnosed by *sampling the rendered pixel* and comparing
  saturation to the palette — the measure-don't-guess rule applied to colour.
- **Python: `0` is falsy.** `(obj.get("layer") or 99)` silently excluded every layer-0 object —
  the most common layer in Qud data — and printed an empty result that read like a real finding.
- **Don't truncate the output you are searching.** Three separate `head`/`tail`/`[:30]` caps in
  this project cut off exactly the rows being looked for.
- **Ask the user to click, don't infer from screenshots.** The inspector exists for this. Five
  hypotheses were formed from pixels; one selection would have beaten all of them.
- **Unfocused Godot doesn't DRAW.** Godot's `_process` runs unfocused (file polling works) but it
  doesn't render, so a screenshot that `await`s `frame_post_draw` hangs — use `RenderingServer.force_draw()`.
- **Driving an unfocused Qud is SOLVED** (build 2026-07-24k+), but the how matters. Qud parks its turn
  thread on `while (!GameManager.focused) Thread.Sleep(200)` when the window backgrounds, and applies
  injected commands only through render/turn-tied hooks. Fix = two coupled pieces: inject moves via
  `Keyboard.PushCommand` (wakes the turn thread from any thread, no render needed) + a watchdog that
  holds `GameManager.focused = true` while a client is connected. `runInBackground` is a red herring
  (it's the render loop, not the turn thread). Decompile the game to confirm engine behaviour before
  theorising; see docs/tools.md "Remote control".

## Ground rules learned the hard way

- **Reflect, don't grep.** String-grepping `Assembly-CSharp.dll` once "proved"
  `Render` fields were lowercase; they're capitalized. Use a
  `MetadataLoadContext` probe for exact signatures. See README's toolkit section.
- **Prefer Qud's own predicates** to inferring from tile names — `Cell.HasBridge()`,
  `HasWadingDepthLiquid()`, `GameObject.HasIntProperty("Bridge")`, `IsCreature`.
  Tile families are a *symptom* of game state, not the source of truth.
- **Never call Unity from the turn thread.** It crashes the game natively.
  Marshal through `GameManager.Instance.uiQueue`. Harmony patching is blocked on
  Apple Silicon (`mprotect EACCES`).
- **Tile paths mix separators** — creature tiles use `\`, most others `/`.
  Normalize both.
- A snapshot is only published **on a turn**. Capture scripts must block, and
  must reconnect on EOF (restarting Qud drops the socket).
- Commit and push after each round of work once it builds.

# Working notes for Claude (and future humans)

**This file is the operating manual** — the local environment (paths, commands) plus the non-negotiable
rules to work safely here. Subsystem facts live in the linked docs; the deep debugging history is in
[`docs/decisions/`](docs/decisions/). If a path here is wrong, fix it here.

## Docs map — read the relevant page before changing a subsystem

| page | what |
|---|---|
| [`README.md`](README.md) | product overview + quickstart + the engineering reference |
| [`docs/architecture.md`](docs/architecture.md) | Holodeck boot chain, components, panels, the bridge cadence |
| [`docs/rendering.md`](docs/rendering.md) | the 3D pipeline — classification, voxel walls, lighting, water |
| [`docs/cameras.md`](docs/cameras.md) | camera modes + viewer controls (**canonical** for controls) |
| [`docs/protocol.md`](docs/protocol.md) | the bridge wire format |
| [`docs/qud-api.md`](docs/qud-api.md) | verified Qud namespaces + signatures (reflection-confirmed) |
| [`docs/tools.md`](docs/tools.md) | the Python tools, the in-viewer inspector, the Python-first workflow |
| [`docs/gotchas.md`](docs/gotchas.md) | non-obvious invariants + "adding X → verify Y" checklists |
| [`docs/roadmap.md`](docs/roadmap.md) | forward strategy (the world-store pivot) |
| [`docs/decisions/`](docs/decisions/) | the war-story debugging record — the *why* behind the rules below |

**Before adding a feature, skim [`docs/gotchas.md`](docs/gotchas.md)** — most entries cost a debugging
round-trip to learn. Add a one-liner there when a new quirk bites.

## Terminology: the "Holodeck"

The **Holodeck** is the player-facing Raves view — the Godot 3D/2.5D window (camera modes, the 3D⇄2D toggle,
the selection inspector). One component; menus/inventory are separate. It's the product name, not the Godot
API — `get_viewport()`, `SubViewport`, "the Godot viewport" stay as-is in code.

## Architecture in one paragraph

Runtime order: **MainMenu → MainFrame → Main (the Holodeck)**. `Main.gd` is decomposed into delegate files
(SkyGrade / CameraRig / Multiview / RemoteControl / DebugMenu / DirectionPicker). `MainFrame.gd` is the
5-row gameplay chrome; the Holodeck renders **full-window into the root viewport** (no `SubViewport` — that
was the Metal crash source) with a transparent hole in row 3. **ONE bridge:** `Main` emits `snapshot(data)`;
`MainFrame._apply_stats` fills the panels. Full detail — components, panels, the direction picker, the
snapshot cadence — in [`docs/architecture.md`](docs/architecture.md). **The rule that bites: any clickable
UI over the Holodeck must be `FOCUS_NONE`** or it swallows the movement arrows.

## Branches & platform (parallel dev on Mac + PC)

Mac and PC (Windows) develop in parallel off a shared base; feature work happens on its own branch (check
`git branch` — don't assume a fixed name). To keep merges clean:

- **All OS-specific tooling is behind a seam** — `tools/capture/plat.py` dispatches by OS to `plat_mac.py` /
  `plat_win.py`. Cross-platform code (bridge, Godot, mod logic) is shared. **PC work = implement
  `plat_win.py`** (mirror `plat_mac.py`'s function names). **Do NOT edit the other OS's backend** — that's
  exactly what causes merge conflicts.
- The **"Local paths" table below is macOS / this machine**; the PC branch keeps its own values there.
  Expect that section to differ per branch — fine, not a conflict.

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
| standing overrides | `~/Library/Application Support/RavesOfQud/overrides.json` (seed committed at `overrides.seed.json`) |
| inspector output | `~/Library/Application Support/RavesOfQud/selection.txt` (latest), `selections.log` (history) |
| Qud crash log | `~/Library/Logs/Freehold Games/CavesOfQud/Player.log` |
| bridge socket | `127.0.0.1:48710` |

## The commands that actually get used

```bash
# type-check the mod against the REAL Qud API (catches API drift before a restart)
dotnet build mod/RavesOfQudBridge.csproj

# look up an EXACT Qud API signature — decompile the shipped assembly (don't guess; reflect, don't grep)
DOTNET_ROOT=/opt/homebrew/Cellar/dotnet/<ver>/libexec ~/.dotnet/tools/ilspycmd \
  "<Managed>/Assembly-CSharp.dll" -t <FullTypeName>

# deploy the mod — REQUIRES A FULL QUD RESTART (mods compile at startup)
cp mod/*.cs mod/manifest.json ~/Library/Application\ Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/

# validate the Godot scripts parse + _ready runs, without a window ("connected" + no errors == clean).
# .gd changes need NO restart for a dev-run; the EXPORTED app freezes scripts at build time (rebuild to ship).
# After ADDING a `class_name`, the headless parse fails until an editor rescan: run `--editor --quit` once.
/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot --headless --path godot/ --quit-after 120
# ^ only deep-analyses scripts it LOADS. Main.gd is instanced on "Connect", so force-check it:
/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot --headless --path godot/ --check-only --script res://Main.gd

# build a CRISP (HiDPI) macOS .app (dev-run windows are soft on Retina). Needs the 4.7 export templates.
tools/build_macos.sh && open build/RavesOfQud.app

# read live state off the bridge (BLOCKS until the player takes a turn)
python3 tools/capture/snap.py summary        # also: cell 66 6 · water · find glowfish

# inspect an exported tile's pixels / opaque band / transparency
python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp   # also: --list water

# DRIVE the game headlessly — works with Qud UNFOCUSED (see docs/tools.md).
python3 tools/capture/control.py move N 5    # cam <1-7> · shot -> shot.png · export (re-export data)
python3 tools/capture/control.py onboard devices   # drive the onboarding UI with NO Qud running

# Option PRESETS — save/load a whole options set for deterministic test state (see docs/tools.md)
python3 tools/capture/presets.py list        # · load compass-fullinfo
```

## Fonts & display — the rules

- **Dev-run windows are soft on Retina** (a Godot limit, not our bug — the floating window gets a non-HiDPI
  backing). Don't chase it in-code; **EXPORT** (`tools/build_macos.sh`) when you need it crisp.
- **All UI font sizes come from ONE source: `godot/UiFont.gd`.** Do **NOT** hardcode a `font_size` — use
  `theme_type_variation` (`"Title"/"Big"/"Caption"`) or `UiFont.px(vp, role)`. Press **L** in-app for the ruler.
- **CanvasLayer theme trap:** a Control whose direct parent is neither a Control nor a Window becomes its own
  theme root and won't inherit the app theme → tiny built-in font. Fix: keep it in the tree (covered by
  `Main._stamp_theme_roots()`), or set `theme = UiFont.make_theme(get_viewport())` on your subtree's root.
- A panel that sizes its font only at build time stays tiny — re-apply on every show/resize.

## The feedback loop (Claude cannot see the Holodeck)

Don't ask the user to describe what they see — that round-trip is the main source of wasted effort.

1. User points at a cell in Godot: **Ctrl/Cmd+click**, or hover and press **I**.
2. `CellInspector` writes `selection.txt` (and copies to the clipboard).
3. Claude reads `selection.txt` directly.

The report pairs **WIRE** (what Qud sent) with **RENDERED** (what `ZoneRenderer` did, and at what Y). Every
rendering bug so far lived in the gap between those two — always read both halves.

## Screenshots

macOS `screencapture` needs Screen Recording permission (often unavailable), so the apps also capture
themselves. For outside-driven work, **highvisor captures a specific window** — `hv shot '<window>' out.png`.

- **Ctrl/Cmd + right-click a Holodeck tile** = inspect that tile **and** photograph both apps in one gesture:
  `RavesOfQud/selection.txt` (the report), `shot.png` (the Holodeck, marker on the tile), `qud_shot.png`
  (Qud's window). The text report is hidden from the shot.
- **F12** does the screenshots alone (`shot.png` + `qud_shot.png`). Qud's file appears at end-of-frame, so
  allow a moment. Godot's `shot` marshals `UnityEngine.ScreenCapture` to the main thread via `uiQueue`.

## Tile reports — overrides + notes

Some things aren't in Qud's data (a water wheel runs E–W but the tile doesn't say so). Inspect a tile and use
the form (lower right); Esc clears the selection.

- **Standing rules** (shape, fill) → `overrides.json`, keyed by tile family. `ZoneRenderer._load_overrides()`
  reads it **live** every frame — it's config that persists until changed. The form's **Clear rules** button
  is the undo; the inspector prints `OVERRIDE …` for any tile with an entry. The tile→family reduction has
  ONE GDScript source (`ZoneRenderer.tile_family()`); the C# `TileFamily()` is a separate server-side copy.
- **One-off notes** (colour, position, free text) → dated `.md` tickets under `reports/`; delete once addressed.

## Lighting & geometry

- **Lighting is faked**: a day/night MULTIPLY grade + a per-cell darkness overlay + additive glows. The world
  honors `ZoneRenderer.SHADED_WORLD` (**currently `true`** → per-pixel). Full writeup:
  [`docs/rendering.md`](docs/rendering.md) §5.
- **Prototype geometry/pixel algorithms in Python first** — I can't see the viewport, so verify the
  *algorithm* in Python (`tools/capture/voxel.py`, `fill.py` mirror the GDScript), then port. Appearance
  still needs a screenshot; the algorithm doesn't. See [`docs/tools.md`](docs/tools.md).

## Hard-won rules (one-liners; full stories in [`docs/decisions/debugging-lessons.md`](docs/decisions/debugging-lessons.md))

- **Never call Unity from the turn thread** — it crashes the game natively. Marshal through
  `GameManager.Instance.uiQueue`. (Harmony patching is blocked on Apple Silicon.)
- **Look up Qud APIs against the real assembly** (`dotnet build`), don't guess. **Reflect, don't grep.**
  Prefer accessors (`getTile()`) and Qud predicates (`Cell.HasBridge()`) over field names / tile-name inference.
- **Know which build is running** (`Protocol.Build` ships in every snapshot) and **verify a fix fired**
  before reasoning over it — mod `.cs` compiles only at Qud startup.
- **Measure before hypothesising.** A cell is not just its objects (Qud paints a ground layer).
- **`--headless` can't catch GPU bugs** (dummy driver) — only a real windowed run proves a render path. No
  crash report = a **HANG** (fillrate/overdraw), not a crash; check for a fresh `Godot-*.ips` first. For a
  real GDScript backtrace / native stack, run under the dev editor: `Godot --path godot` (it flushes errors;
  the exported app writes none).
- **Vertex-colour meshes need `vertex_color_is_srgb = true`** or palette colours desaturate.
- **Driving an unfocused Qud is solved** (`Keyboard.PushCommand` + a focus watchdog) — see the decisions doc.
- **Commit + push after each round once it builds** — but first run the **author guard**:
  `git log HEAD --format='%ae' | grep -i allspice` must be **empty** before every push.

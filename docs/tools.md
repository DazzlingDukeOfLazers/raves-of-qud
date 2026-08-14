# Tools & workflow — inspecting and driving Raves of Qud

Two kinds of tooling: **Python** (inspection & verification, in `tools/capture/`) and the
**in-viewer** Godot tools (the human's feedback channel). GDScript is the product; Python exists
to check it.

## What are you trying to do?

| Goal | Command / tool | Needs Qud in-game? |
|---|---|---|
| Inspect the wire snapshot | `snap.py summary` / `cell X Y` / `find <name>` | yes |
| Inspect a tile's pixels | `tile.py <name>` | no |
| Capture both apps | Ctrl/Cmd-click a Holodeck tile, or **F12**; `control.py qudshot` for Qud alone | yes (Qud shot) |
| Move the player / drive a turn | `control.py move N 5` (or `go N 3 qudshot`) | yes |
| Re-export Qud's data files | `control.py export` | yes |
| Jump to a known options config | `presets.py load <name>` ([presets](#option-presets--deterministic-test-fixtures-presetspy)) — Raves settings need a relaunch | yes (for the Qud half) |
| Reach a Qud menu the bridge can't | `desktop.py`, or drive via **highvisor** | any |
| Regression / parity vs Qud | **highvisor** `hv scene …` (see its parity kit) | both |
| Verify elements one at a time | `checker.py sweep <cat>` ([Object Checker](#the-object-checker--per-element-verification-checkerpy)) | yes |

Detailed reference for each follows.

---

## The Python-first rule (read this)

Claude cannot see the Holodeck (the Godot viewport). Historically that meant render/geometry code was written
straight into GDScript and verified only by the human's screenshots — slow, and it hid bugs (an
off voxel depth order survived a full round-trip). So:

> **Prototype and verify any geometry or pixel algorithm in Python first, then port to GDScript.**

The Python mirrors the GDScript algorithm exactly and renders inspectable output (ASCII maps,
oblique PNGs, tables). What Python **can** verify: which pixel gets which height, which gaps fill,
colour rankings, tile geometry, wire contents. What it **cannot**: lighting, shadow, and final
appearance — those still need a screenshot (F12 in the viewer, read from disk). The rule is not
optional; it is how the depth-order bug was caught before it hit the renderer.

Everything Python here is pure-stdlib (a hand-rolled PNG decoder in `tile.py`, no Pillow).

---

## Python: wire inspection — `snap.py`

Reads one snapshot off the bridge (`127.0.0.1:48710`) and reports. **Blocks until the player
takes a turn** (a frame is only published on a turn) and reconnects on EOF (a Qud restart drops
the socket).

| command | shows |
|---|---|
| `snap.py summary` | object counts, layers, flags, cells with no tile |
| `snap.py cell X Y` | full object stack of one cell |
| `snap.py ident X Y` / `ident <name>` | blueprint + display + colours, by coord or name |
| `snap.py families` | tile family × layer × flags |
| `snap.py classify` | what the renderer will DO with each object (mirrors its rules) |
| `snap.py water` | depth flags vs water tile families; bridge stacks; submerged actors |
| `snap.py time` | the parsed day/night clock |
| `snap.py find <substr>` | locate objects by tile/glyph (matches the meaningful name tail) |
| `snap.py raw` | the whole snapshot as JSON |

Gotcha baked in: match the **meaningful name tail**, never the raw path — nearly every tile is
under `Assets_Content_Textures_`, so "tent" would hit "Content".

## Python: tile inspection — `tile.py`

Decodes an exported tile PNG (pure-stdlib) and prints its pixels, opaque-row band, and
transparency %.

```
python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp
python3 tools/capture/tile.py --list water
```

Legend: `#` opaque-dark → main · `o` opaque-light → detail · `.` transparent → bg. Flags line-art
(mostly transparent → needs fill) and the 16×24 wall/floor split.

## Python: algorithm prototyping — `fill.py`, `voxwall.py`, `voxel.py`

These mirror GDScript algorithms so they can be verified without a screenshot.

### The wall VOXEL editor (in-app)
Select a wall, report form -> **Voxel edit**: roof + face canvases editing the tile art's two
bands per autotile variant. The prev/next hopper walks DISTINCT DRAWINGS, not names — Qud names
wall art by the raw 8-bit neighbourhood byte, so the export cache holds many pixel-identical
files (measured: 108 wall_metal names, 37 images; a diagonal only changes the art when both
flanking cardinals are walls) — and Save/Revert covers every equivalent name in the group, so
identical-looking cells can never disagree over an invisible diagonal. Corners are variants;
hop to them. The FACE canvas is FAMILY-WIDE: every face of every cell renders from just the
four horizontal-run variants, which differ only in end-frame pixels — so the editor edits one
face surface (the mid-run band) and Save writes it into all four, each keeping its own frame
pixels (frame = where its stock band differs from stock mid-run). Paint one pixel, save once,
every wall face in the game wears it. The art WRAPS the block: S reads W->E, E continues S->N
MIRRORED, N reads E->W, W continues N->S mirrored — every corner column is shared by both its
faces, so patterns run continuously around corners (verified with marker art; the fence/tent
mirroring lesson). Corners where two exposed faces meet keep their SOLID edge — the wrap aligns
gap columns at corners, and letting both faces carve there deleted the whole corner column (the
missing-chunk report); relief starts one shell in from the edge. Also: a rotatable dimetric
preview drawn from the renderer's OWN volume rules (`wall_preview_arrangement`) with
single/run/corner/block arrangements, and a **core colour** row writing
`overrides.json tiles[<family>].core`. Save writes `tiles_custom/<variant>`; wall custom art
renders AS-AUTHORED (transparent = carve) and hot-reloads (the custom watch clears the wall
caches). The 2D `Edit art` button remains for sprites.

### `voxwall.py` (LIVE — the wall-volume proof harness)
Mirrors `ZoneRenderer._wall_cell_mesh` (the watertight per-cell voxel wall). Builds real
arrangements (isolated / run / corner / 2x2 / mixed-family) from the actual exported art and
asserts: watertight interior, flush wall-to-wall boundaries, faces emitted once-only, and a
random-ray sweep. `--previews` writes top/south elevation PNGs (Qud-art derivatives — they land
in CWD; do not commit them). Run it after ANY change to the wall builder, and keep the Python
and GDScript in step.

### `fill.py`
A/B's the interior-fill rules (`column AND row`, `row only`, `AND + narrow slots`) side-by-side as
ASCII, with filled-pixel counts. This is how the chest/dromad/basket fill rule was chosen — and
how to check any change to `Fill.SPAN`/`INTERIOR` before touching `_interior`/`_fill_holes`.

### `voxel.py` (historical — the tool that killed its own rule)
Recolours a tile and maps each pixel to a voxel height, with two rules: `--rule luma` (height ∝
Rec.601 luminance, `--gamma <1` spikes detail) and `--rule count` (frequency-rank). `--smooth N`
box-blurs the field. Prints a colour→level table, an ASCII height map, and an oblique preview PNG
(`/tmp/voxel_preview.png`).

```
python3 tools/capture/voxel.py wall_metal-00000000 --rule luma
python3 tools/capture/voxel.py wall_metal-00000000 --rule count
```

**The renderer no longer ranks height at all.** This tool's value was proving the fact that decides
the subsystem: every sampled tile is a **2-bit mask** (≤3 colours ⇒ ≤3 heights), so no ranking rule
can add relief. That measurement is *why* the walls shipped as **binary flush-and-carve** (non-bg
flush, bg carved) instead of any luminance/count ranking — see
[rendering.md §4](rendering.md#4-voxel-walls--flush-surface--carved-gaps). Kept as the record of that
investigation; it does **not** mirror current renderer code.

---

## In-viewer: the cell inspector

The human's primary feedback channel. **Ctrl/Cmd+click a tile, or hover + `I`.** Writes a report
to `~/Library/Application Support/RavesOfQud/selection.txt` (+ `selections.log` history), copies it
to the clipboard, and shows a panel. Claude reads the file — no transcription.

The report pairs **WIRE** (what Qud sent) with **RENDERED** (what `ZoneRenderer` actually did, and
at what Y — recorded by the renderer itself via `_note`/`placements_at`, so it can't drift). It
also shows the tile's exported PNG dimensions/opaque band, any active `OVERRIDE`, and the running
**mod build** (mod `.cs` only compiles at Qud startup — this line tells you whether your fix is
live). An empty pick lists the nearest occupied tiles. A sprite preview (upper right) shows the
real billboard texture turning over a checkerboard, since transparency is invisible against the
dark ground.

Keys: `I` inspect · `-`/`=` resize text · `Esc` dismiss.

## In-viewer: the report form

Lower-right panel, opens on inspect. For things **not derivable from Qud's data**. Pick a subject
(which object), a verdict, add notes, submit. Routes by verdict type into two lifecycles:

- **Standing rules** (shape / fill / position) → `overrides.json`, keyed by tile family. **Config
  — persists until changed.** The `☰` hamburger's *Clear rules* removes a tile's entry (the undo).
- **One-off notes** (colour / position / free text) → dated `.md` under `reports/`, with the full
  inspector capture attached. **Tickets — safe to delete.**

Splitting them fixed the trap where deleting a "resolved" ticket reverted the render, because the
ticket *was* the override. See [rendering.md §7](rendering.md#7-user-overrides).

## In-viewer: screenshots

macOS `screencapture` needs Screen Recording permission (often unavailable), so both apps also
capture themselves. (Note: **highvisor can now capture a specific window directly** — `hv shot
'<window>' out.png` — which is the usual path when driving from outside; the self-capture below is the
in-app/no-highvisor route.)

- **F12** → `RavesOfQud/shot.png` (Godot viewport) + asks the mod for `qud_shot.png` (Qud's own
  window, via `UnityEngine.ScreenCapture` marshalled to the main thread).
- **Ctrl/Cmd+right-click** → inspect a tile **and** photograph both, with the report hidden and the
  3D marker kept. One gesture → coordinates + wire data + picture.

Claude reads both PNGs from disk. This replaces manual screenshot-and-paste.

---

## Remote control — driving Qud + the Holodeck headlessly (`control.py`)

`tools/capture/control.py` drives the game from OUTSIDE, so a loop can run without a human at the
keyboard. Two channels:

- **Qud** — framed commands to the mod bridge (same protocol as the Godot client):
  `move <dir> [n]` (dirs N/S/E/W/NE/NW/SE/SW), then reads the resulting snapshot (player cell/zone).
  The mod's `BridgeServer` broadcasts to every client and shares one command queue, so this coexists
  with the running viewer.
- **Godot** — `control.py` drives Godot through a **cooperative command file** for deterministic,
  focus-independent control: `Main` polls `<RavesOfQud>/godot_cmd` (~10 Hz) and executes `cam <1-7>`
  (camera mode), `shot` (save shot.png), `fph <h>` (first-person height), and `inspect <CX> <CY>` —
  run the cell inspector at a zone cell (writes selection.txt like a Ctrl+click; no focus or mouse
  needed, e.g. `echo "inspect 6 7" > "$SUPPORT/godot_cmd"` then read selection.txt for the RENDERED
  lines). (Highvisor is the OS-level alternative when a test needs real window input to Godot.)

```
python3 tools/capture/control.py pos          # player cell + zone
python3 tools/capture/control.py move N 5      # five steps north
python3 tools/capture/control.py cam 1         # compass camera
python3 tools/capture/control.py shot          # Godot viewer screenshot -> shot.png (read it)
python3 tools/capture/control.py qudshot       # QUD's own rendered map -> qud_shot.png (read it)
python3 tools/capture/control.py go N 3 qudshot  # drive + read Qud's map in one call (the dev loop)
```

**The automated dev/debug/test loop.** Claude drives blind and reads back the result — no live
window or focus needed. `qudshot` sends `shot` straight over the bridge; the mod's `ScreenCapture`
forces a render of the current buffer (which `RenderBase` keeps current every turn), so `qud_shot.png`
shows Qud's TRUE current map even while the window is unfocused/backgrounded — verified: driving through
a marsh, the capture's message log read back "You pass by a watervine". So a loop is:
`go <dirs> qudshot` → read `qud_shot.png` (Qud's render) + `shot.png` (the Godot viewer) + the snapshot
JSON (position/cells) → decide the next move. The live-window macOS present limit (above) does NOT affect
this — captures are on-demand.

**Driving an UNFOCUSED Qud works** (build `2026-07-24k+`). Movement can be issued whether or not
Qud is the foremost window, so you can press arrows in the Godot window (or run control.py) with Qud
in the background. Godot screenshots also work unfocused (`_screenshot(forced=true)` →
`RenderingServer.force_draw()`; the interactive F12 path `await`s `frame_post_draw`, which hangs
unfocused). This took two coupled fixes — see below.

**How the mod applies commands (hard-won by decompiling Qud — don't rediscover):**
- **Injection.** A move arrives on the background socket thread and is pushed straight into Qud's own
  input queue via `ConsoleLib.Console.Keyboard.PushCommand("CmdMove"+dir)` (see `Bridge.OnPayload`).
  That enqueues a `"Command:CmdMoveN"` mouse event under `lock(MouseEventQueue)` and calls
  `KeyEvent.Set()`. XRLCore's player loop pops it and dispatches the command exactly like a keypress.
  Doing this off the socket thread is safe (locked queue, no game-state access) and *doesn't* need a
  rendered frame — unlike the old `CommandEvent.Send` path, which was drained from render/turn hooks
  (`BeforeRenderEvent`/`EndTurnEvent`) that don't fire while unfocused.
- **The freeze.** XRLCore's turn thread gates on `while (!GameManager.focused) Thread.Sleep(200)`;
  `OnApplicationFocus(false)` flips that flag, so a backgrounded window parks the whole turn thread and
  injected commands sit unprocessed until it regains focus (symptom: moves flush in a burst the instant
  you click Qud). Fix: a watchdog thread (`Bridge.StartFocusKeeper`) holds `GameManager.focused = true`
  while a bridge client is connected. Harmony (the clean way to patch `OnApplicationFocus`) is blocked
  on macOS, hence the watchdog.
- **The render gate (second, independent).** The turn thread processing a move is only *half* — Qud's
  own map won't repaint unless Unity keeps its MAIN-THREAD render loop running, which it pauses for a
  backgrounded window unless `Application.runInBackground` is set. Symptom of missing this: messages
  fire but Qud's map freezes until you focus it (the Godot viewer still updates — it just consumes the
  snapshot). Gotcha: `Application.runInBackground` is **main-thread only**; the mod first set it from
  `Bridge.Tick` (turn thread), where it threw and a `catch {}` ate it. Fix: marshal it onto the main
  thread via `GameManager.uiQueue` (see `Bridge.Tick`). Also set `vSyncCount = 0` (else present is paced
  by the focused display's vsync and stalls) and `RenderBase` each turn (an injected `PushCommand` move
  doesn't hit the `CmdMove` RenderBase path — gated on `Options.DrawStepImmediately` — so the screen
  buffer stayed stale). With those, Qud renders ~4fps unfocused (measured via a since-removed heartbeat)
  and the buffer stays current.
- **What DOESN'T work, and why (don't re-chase).** Even with all the above, Qud's own **3D tile-map
  camera** does not present its updates to a backgrounded window on macOS — the message-log UI repaints
  live, and `ScreenCapture` forces a correct one-off frame, but there's no clean managed hook to force
  continuous live presentation of a background window's camera. This is a Unity/macOS compositor limit
  below mod reach. Practical answer: the **Godot viewer is the live surface** (fully live while Qud is
  backgrounded); to see Qud's OWN map, focus it (repaints instantly — the buffer is kept current every
  turn) then focus back to Godot to drive. So: **focus-keeper = commands process; runInBackground +
  vSync + RenderBase = state/buffer stay live and Qud repaints instantly ON focus; the unfocused live
  tile-map is a macOS limit.**
- The focus override is gated on `ClientCount > 0`, so solo play (no viewer attached) keeps Qud's normal
  pause-on-unfocus. While the viewer is connected + idle, Qud sits ~10% CPU (animation frames), not a spin.
- A blocked player (marsh/water/wall) applies the move but doesn't change cells — check the position,
  not just that the command returned. A blocked move may also not end a turn, so no snapshot comes back.

## The Object Checker — per-element verification (`checker.py`)

The deterministic rung below the zoo ([phase2-test-plan](phase2-test-plan.md) Workstream A): load Qud
elements **one at a time** onto a clean stage and verify each. The mod's `check` command clears a rect
at zone center, places the blueprint, and parks the player **adjacent** (distance ≤ 1 arms
proximity-gated effects: ConcealedHologramMaterial's flicker, puffers); `checklist` dumps the
category enumeration (`checker_catalog.json` — walls/plants/creatures/liquids/furniture/items/
weapons/food/implants, selection shared with `ZooBuilder.Select`).

```bash
python3 tools/capture/checker.py list                 # category -> element counts
python3 tools/capture/checker.py one Dresser          # stage + verify one element (exit 0/1)
python3 tools/capture/checker.py sweep walls          # whole category -> reports/checker/walls.{md,json}
python3 tools/capture/checker.py sweep creatures --start 100 --limit 50   # resumable slices
```

Each element is verified by diffing **ground truth** (`checker_stage.json` — what the mod staged:
blueprint, stage cell, static Render tile/colours) against **the wire** (the same-turn snapshot):
the stage cell arrived, the element carries art, colours parse as Qud codes; a wire-vs-blueprint
tile mismatch is a WARN (runtime tiles may legitimately differ — RandomTile). `--shots` also saves
the same-turn Qud/Raves screenshot pair under `reports/checker/shots/` for the pixel-congruence
pass (mean-diff + the strict checks) to consume. Reports are re-runnable — the regression suite for
every future change.

## Option presets — deterministic test fixtures (`presets.py`)

`tools/capture/presets.py` saves/loads a whole **options set** as one named file, so tests (and you) can
jump deterministically between known configurations instead of hand-toggling. A preset captures both
**raves** (Raves' own `settings.json`: camera, full_info, font_scale, …) and **qud** (every Qud option's
value, `id -> value`).

```bash
python3 tools/capture/presets.py list                        # working set + committed fixtures
python3 tools/capture/presets.py save my-case --desc "why" --repo   # snapshot current state (--repo = commit it)
python3 tools/capture/presets.py load compass-fullinfo        # apply it (deterministic jump)
python3 tools/capture/presets.py sync                         # committed fixtures -> support dir
```

- Files: working copies in `<support>/option_presets/`; **committed, documented fixtures** in
  `tools/regression/presets/` (that dir's `README.md` is the list + *why* each exists).
- `load` applies **qud** options over the bridge (Qud in-game) as one deferred batch — N `setoption
  defer=1` then a single `export`, not N re-exports — and writes **raves** settings into `settings.json`,
  which take effect on Raves' **next launch** (so a highvisor test does `presets.py load X` → `hv launch
  raves` → `hv scene …`). The Options screen's in-app **Load** button applies raves settings live instead.
- In a regression scene, a `{ "shell": ["python3","../capture/presets.py","load","<qud-preset>"] }` step
  sets live Qud state before capture (Raves-setting presets need the launch pattern above). Bless goldens
  as preset-driven tests are added. Full guidance: `tools/regression/presets/README.md`.

## OS-input harness — `desktop.py` (reach Qud UI the bridge can't)

The bridge only moves the player + a few commands. `tools/capture/desktop.py` is a legacy/general
OS-input helper that drives Qud (or Godot) with REAL synthetic input at the OS level (CoreGraphics
CGEvent). It has been **verified against selected in-game controls** (e.g. the Sprint button, below).
Clicking Qud also focuses it, refreshing its render (the map-sync fallback). All in-process via ctypes
(CGEvent for mouse/keys, CGWindowList for bounds); `activate` uses an osascript Apple Event.

> **Synthetic input is surface-specific — `desktop.py` posts one fixed event shape.** For Qud title
> menus, legacy console popups, and world cells, the reliable path is **highvisor's per-surface
> bare/`--hover` matrix** (highvisor `docs/05-driving-input.md`): plain Unity buttons + world cells take
> a bare click; legacy popups need `--hover`; the title menu is bare-then-`--hover`. `desktop.py` does
> not yet expose those per-surface event shapes, so don't treat it as a universal input tool.

```
python3 tools/capture/desktop.py check              # Accessibility granted for the host?
python3 tools/capture/desktop.py bounds Qud         # window rect {x,y,w,h} (no permission needed)
python3 tools/capture/desktop.py activate Qud       # focus it (also refreshes its render)
python3 tools/capture/desktop.py key Down           # OS keystroke (Return/Escape/arrows/F1../char)
python3 tools/capture/desktop.py clickin Qud 0.21 0.974   # click a FRACTION of the window
```

**The full loop (verified):** `control.py qudshot` (capture Qud's render) → find a UI element's fractional
position in the PNG → `desktop.py clickin Qud fx fy` → `qudshot` again → confirm the effect. Proven by
clicking the Sprint button: "You begin sprinting!", MS 100→200.

**`harness.py` — drive with BOTH windows live (side-by-side human demos).** On macOS only the focused
window renders live; Godot renders unfocused now (force_draw) but Qud can't — so `harness.py` keeps QUD
focused (Godot mirrors in the background) and drives from there. Both stay in sync. (Driving from Godot's
own keys is the one config that can't work — it leaves Qud unfocused/frozen.)
```
python3 tools/capture/harness.py drive N 3 E 2 S 3 W 2   # walk a square, both windows live
python3 tools/capture/harness.py drive N 5 --shot        # then capture both renders
python3 tools/capture/harness.py drive NE 4 --keys       # via real OS keystrokes (numpad) vs the bridge
python3 tools/capture/harness.py drive N 3 --pace 0.6    # slower, for an audience
```

**`qud.py` — app lifecycle (the recompile-and-resume loop in one command).** The mod only compiles at
app startup, so iterating on it means quit → (redeploy) → start → load. `qud.py` automates that:
```
python3 tools/capture/qud.py status     # running? window up? in-game(bridge)?
python3 tools/capture/qud.py quit        # graceful Apple-Event quit -> SIGTERM -> SIGKILL
python3 tools/capture/qud.py start        # launch via Steam (rungameid/333640), wait for the window
python3 tools/capture/qud.py load         # main menu: press C (Continue) -> Return (most-recent save)
python3 tools/capture/qud.py restart      # quit + start + load, all three
```
`load` is keyboard-based (the `C` Continue shortcut + `Return` on the pre-selected latest save, from
decompiling `Qud.UI.MainMenu`), driven by **focused OS-level CGEvent keystrokes on the pre-game main
menu** — a different surface from in-game input, which is why it can work where synthetic keyboard to the
live game does not. `quit`/`start`/`status` need no permissions; `load` needs Accessibility for the
keystrokes. **Re-verify `load`/`restart` against the current build before relying on them** — the
menu-key path is brittle across Qud updates; if it regresses, route pre-game navigation through
highvisor mouse scenes (highvisor `docs/05-driving-input.md`) instead.

**Gotchas (hard-won):**
- **Accessibility** is required for synthetic input (not for `bounds`/`activate`). The host process is the
  app running the commands — for Claude that's the **lowercase `claude`** helper in Privacy & Security >
  Accessibility (the claude-code bundle), NOT the main `Claude` and NOT the top-level "Accessibility" pane.
  Check with `AXIsProcessTrusted()` (`desktop.py check`). Took effect live, no restart.
- **App names differ per API:** Qud's window OWNER is `CavesOfQud`, its osascript app name is `CoQ` — the
  alias "Qud" resolves both. Qud + Godot may be on different monitors (global coords, negative y ok).
- **Mouse-event shape is surface-specific — don't assume a universal recipe.** `_post_mouse` posts a
  `CGEventMouseMoved` + `kCGMouseEventClickState`, which the Sprint control accepts; but Qud **world
  cells reject a pre-move** and Qud clicks **reject `clickState`**. Start minimal (warp + down/up), add
  a pre-move or click-state only when readback proves that surface needs it, and prefer highvisor's
  verified per-surface matrix (highvisor `docs/05-driving-input.md`) for Qud UI. Posting an event is not
  proof the app reacted — always capture/read back after.
- Coordinates are FRACTIONS of the window (robust to position). qud_shot is 2× Retina but fractions map
  1:1 to the logical window.

## Camera modes (viewer)

**Canonical reference: [`docs/cameras.md`](cameras.md)** — if this list disagrees with that page, that
page wins. Pick with the `` ` `` debug menu or number keys **1–7** (current mode + controls show on
screen): **1 COMPASS** (default, cardinal-LOCKED low-angle — never spins on movement; Q/E rotate 90°,
R/F zoom), **2 FOLLOW** (trails heading), **3 FIRST-PERSON** (hides the player; menu height slider),
**4 CINEMATIC** (frames player + selected tile; orbits only with nothing selected), **5 MOUSE** (orbit),
**6 KEYBOARD** (WASD fly), **7 TOP-FOLLOW** (top-down follow). **Esc keeps the current camera** (it does
NOT snap to COMPASS); it closes the ` menu / any selection. Zone crossings shift the live camera transform
in sync with the world re-anchor (Main._process runs before the client's, so the eye is also nudged that
frame to avoid a 1-frame flip). See the header comment in `godot/Main.gd`.

---

## Diagnostic (not part of the loop)

`tools/tiletool/` — an AssetsTools.NET C# inspector used once to reverse how tiles are packed in
the Unity atlases. Kept for reference; not needed for normal work.


## `tools/capture/parity.py` — region-scoped parity scoring

Whole-frame and per-band mean-diff cannot adjudicate small UI changes: the live playfield behind a
status screen's scrim differs every run and moves the average by ~0.7 between IDENTICAL builds, which
is larger than most real deltas. It also rewards blur (a soft tile regresses to the mean) and, if the
sampling window includes a cell's own border, "sprite ink" ends up measuring the box.

`parity.py` scores per LEAF instead — a named region plus a kind that says what to compare:

| kind | compares |
|---|---|
| `image` | sprite ink only; the chrome band is masked out |
| `frame` | chrome only; the interior is masked out |
| `composite` | the whole cell — what the eye sees |

```bash
python3 tools/capture/parity.py score reports/<date>/parity-equipment.json qud.png raves.png
python3 tools/capture/parity.py bounds reports/<date>/parity-equipment.json raves.png --leaf doll_image
python3 tools/capture/parity.py mask  reports/<date>/parity-equipment.json raves.png doll_image[0] /tmp/m.png
```

Each row reports the masked mean diff, the ink bbox in BOTH apps and the pixel counts, so a change is
judged on the thing it touched. Regions live in JSON (`reports/<date>/parity-<screen>.json`) with a
`grid` shorthand for repeated cells, so a new screen is a data edit. The leaf names match the
per-leaf nodes in highvisor's gametree (`equipment_doll_image`, `equipment_filter_frame`, …).

First run on the Equipment tab: **image 75.6, frame 15.9, composite 17.2** — i.e. the sprites, not the
chrome, are what still differs, which the whole-frame number (4.5) completely hid.

### parity.py: two metrics beyond mean-abs-diff (2026-08-05)

`ink_color` and `geometry` join `image` / `frame` / `composite`.

A single masked mean-abs-diff answers "is the text the right colour", "is the sprite the
right size" and "do these pixels match" all at once, and so answers none of them clearly.
The two new kinds split the question:

| kind | mask | number |
|---|---|---|
| `ink_color` | ink | mean channel distance between each app's OWN mean ink colour — position ignored |
| `geometry` | ink | mean of \|dx\|,\|dy\|,\|dw\|,\|dh\| between the ink boxes, in px — colour ignored |

So a leaf reading ~0 on `ink_color` and badly on `geometry` says *right paint, wrong place* —
which is the sentence you actually want out of a scoreboard. Both report
`"present in one app only"` rather than a flattering 0 when one side draws nothing.

**Gotcha fixed at the same time:** `ink_mask` with `inset: 0` sliced `cell[0:-0]`, i.e. NOTHING,
so any leaf written that way silently scored a perfect 0.00. Inset 0 now means the whole rect.

### fixture.py: never carry an id across a reload (2026-08-05)

`tools/capture/fixture.py` drives the parity fixture state. It exists because object ids are
**not stable across a save reload**, and every hand-rolled test snippet in this repo was reading
an id, reloading, and then acting on it. Demonstrated in one command pair: the cloth robe is id
554, reload, and the same robe is 550 — 554 now belongs to something else. That is how a run
asking for the robe's interaction menu raised the WRENCH's, and how several capture runs ended up
scoring two screens with no popup on them.

```bash
python3 tools/capture/fixture.py reload          # reload, then BLOCK for a fresh export
python3 tools/capture/fixture.py find robe       # id, name, and whether it is in the pack or worn
python3 tools/capture/fixture.py twiddle robe    # raise Qud's item menu for it, and verify it came up
python3 tools/capture/fixture.py state           # what both apps think they are showing
```

Three things it makes impossible rather than merely discouraged:

- **A stale read.** Every command re-exports and waits for `inventory.json`'s mtime to actually
  advance before resolving anything, so an id can only come from a file written after the last
  event that could have invalidated it.
- **Missing an item that moved.** Tests equip and drop things, so an item migrates between the
  pack and the body mid-session; a lookup that only walks `categories` starts throwing partway
  through. `find` walks both and says which one it found.
- **A silent wrong pick.** Two waterskins is a real case. Ambiguity is an ERROR listing the
  candidates, not a first-match guess.

#### `--stable`: a mask that turned out not to be needed here

`score --stable <second-qud-capture>` drops every pixel the reference did not hold still between
two captures, on the theory that the live playfield behind Qud's scrim was polluting the list
leaves. Measured: it finds **764 px, 0.0%** of the frame -- because the game is PAUSED while a
status screen is open, so nothing animates within a run. The list leaves' variation (the same
build scoring list_item 5.70 and 9.00) therefore comes from the game STATE differing between
runs, not from animation, and the cure is fixture discipline -- reload the same save, do not move
-- which `fixture.py` now makes routine. The flag is kept for screens that do animate; the
finding is recorded so nobody re-derives it.


## Custom tile art (the replacement loop)

Or skip the external editor entirely: the report form's **Edit art** button opens a
16x24 paint program (TileEditor.gd) — the Qud palette as swatches, an eraser,
right-click erases, and two live previews (one over the Qud background colour, one
over checker). **Save -> game** writes tiles_custom/ and the world updates at once;
**Revert to Qud art** deletes the custom file.


Cmd+click any tile: the inspector's `art` line exports its current source to
`<support>/RavesOfQud/tile_out.png` and names the replacement path. Edit the png
(any editor; keep 16x24) and drop it at
`<support>/RavesOfQud/tiles_custom/<flattened-name>` — the name from the report's
`png` line, e.g. `Creatures_npc-mehmet.bmp` (png bytes regardless of extension,
same as the export cache). The replacement renders AS-AUTHORED: full colour, no
main/detail recolouring; alpha drives seating and fills as usual. Edits hot-reload
(mtime-keyed caches + the overrides poll watches the directory). Ignored in 1:1 —
parity measures Qud's art. Custom files live in the support dir, NOT the repo:
they are derivatives of Qud's assets (same rule as the export cache).

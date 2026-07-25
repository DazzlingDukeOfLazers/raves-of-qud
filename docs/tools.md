# Tools & workflow

Two kinds of tooling: **Python** (inspection & verification, in `tools/capture/`) and the
**in-viewer** Godot tools (the human's feedback channel). GDScript is the product; Python exists
to check it.

---

## The Python-first rule (read this)

Claude cannot see the Godot viewport. Historically that meant render/geometry code was written
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

## Python: algorithm prototyping — `fill.py`, `voxel.py`

These mirror GDScript algorithms so they can be verified without a screenshot.

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

`screencapture` is blocked (no Screen Recording permission), so both apps capture themselves:

- **F12** → `RavesOfQud/shot.png` (Godot viewport) + asks the mod for `qud_shot.png` (Qud's own
  window, via `UnityEngine.ScreenCapture` marshalled to the main thread).
- **Ctrl/Cmd+right-click** → inspect a tile **and** photograph both, with the report hidden and the
  3D marker kept. One gesture → coordinates + wire data + picture.

Claude reads both PNGs from disk. This replaces manual screenshot-and-paste.

---

## Remote control — driving Qud + the viewer headlessly (`control.py`)

`tools/capture/control.py` drives the game from OUTSIDE, so a loop can run without a human at the
keyboard. Two channels:

- **Qud** — framed commands to the mod bridge (same protocol as the Godot client):
  `move <dir> [n]` (dirs N/S/E/W/NE/NW/SE/SW), then reads the resulting snapshot (player cell/zone).
  The mod's `BridgeServer` broadcasts to every client and shares one command queue, so this coexists
  with the running viewer.
- **Godot** — Claude can't send keys to Godot, only to Qud. So `Main` polls a command file
  (`<RavesOfQud>/godot_cmd`, ~10 Hz) and executes: `cam <1-6>` (camera mode), `shot` (save
  shot.png), `fph <h>` (first-person height).

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

## Camera modes (viewer)

Pick with the `` ` `` debug menu or number keys **1–6** (current mode + controls show on screen):
**1 COMPASS** (default, cardinal-LOCKED low-angle — never spins on movement; Q/E rotate 90°, R/F zoom),
**2 FOLLOW** (trails heading), **3 FIRST-PERSON** (hides the player; menu height slider),
**4 CINEMATIC** (frames player + selected tile; orbits only with nothing selected),
**5 ORBIT** (mouse), **6 FLY** (WASD). Esc → COMPASS. Zone crossings shift the live camera transform
in sync with the world re-anchor (Main._process runs before the client's, so the eye is also nudged
that frame to avoid a 1-frame flip). See the header comment in `godot/Main.gd`.

---

## Diagnostic (not part of the loop)

`tools/tiletool/` — an AssetsTools.NET C# inspector used once to reverse how tiles are packed in
the Unity atlases. Kept for reference; not needed for normal work.

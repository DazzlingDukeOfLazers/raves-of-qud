# Cameras, views & viewer controls

How Raves frames the world and what the keys/mouse do. The camera code is all in
`godot/Main.gd`; the selection marker is in `godot/CellInspector.gd`.

## Camera modes (keys 1–7, ` menu, or the multi-view grid)

`_update_camera(dt)` smooths (`FOLLOW_LERP`) toward the eye/look for the current mode.
The per-mode math is factored into **`_mode_eye_look(mode)`** so the multi-view grid can
drive one camera per mode off the same code.

| # | mode | what |
|---|---|---|
| 1 | **COMPASS** (default) | cardinal-**locked** low-angle view; follows the player but never rotates on movement (the disorientation fix). Q/E rotate the heading (45° or 90°, toggle in the menu), R/F zoom. **The zoom arcs:** from `COMPASS_CLOSE_DIST` out it holds the low ~35° dramatic angle; zoom inside that and the camera lifts up-and-over (smoothstepped) to ~2 tiles straight above at closest, looking **down at the head**. So close ≠ flat-and-low; close = overhead. |
| 2 | **FOLLOW** | trails behind your heading, looking ahead. |
| 3 | **FIRST_PERSON** | at the player, eye-level, along the locked heading. ←→ turn, **Ctrl/Cmd+Shift+←→ strafe**; height slider in the ` menu. |
| 4 | **CINEMATIC** | frames you + the selected tile, slow auto-orbit (combat-aware framing is future work). |
| 5 | **MOUSE** | drag to orbit / pan around the selected tile. |
| 6 | **KEYBOARD** | free flight — WASD move, arrows aim. |
| 7 | **TOP_FOLLOW** | Qud-classic overhead: **orthographic**, straight down, NORTH up, tracking the player. Wheel / R-F zoom. |

`Esc` closes the ` menu and any selection but **keeps the current camera** (it does not
snap to COMPASS). There was an 8th mode, `TOP_ZONE`, removed in favour of TOP_FOLLOW.

## Multi-view picker (`0`)

Press **`0`** (or the debug-menu button) for a 3×3 grid of **all seven views live at
once**, for differential testing. Implementation: one `SubViewport` per mode, each with
its own `Camera3D` but sharing the **main `World3D`** (`sv.world_3d = get_viewport().find_world_3d()`),
so they render the same scene. The sub-viewports only render while the grid is shown
(`render_target_update_mode` flips between `UPDATE_ALWAYS`/`UPDATE_DISABLED`) — it's ~7×
the render load, so it's opt-in.

- **Click a pane** → inspect the tile under the cursor with *that pane's* camera
  (`CellInspector.inspect_at(cam, pos)`). The 3D marker is a shared-world node, so the
  pick shows in **every pane at once**.
- **Number key** (1–7) → switch that mode full-screen (leaves the grid).
- Or just **stay in the grid**.

## Top-down aspect: the 16:24 stretch

Qud tiles are **16×24** (taller than wide), but the 3D world uses **1×1** square cells.
So a patch of map is 16N×24M in Qud but N×M here — the proportions differ by the tile's
2:3 ratio, obvious top-down.

Fix: in **full-screen TOP_FOLLOW only**, scale the renderer's **north-south (Z) axis by
24/16 = 1.5** (`_apply_zstretch()` sets `renderer.scale = (1,1,1.5)`). The flat tile quads
become 1×1.5 and show the 16×24 art undistorted, so cells read like Qud. Because the world
is scaled, three things compensate:

- **Camera** aims at `player.z * 1.5` (`_update_camera` multiplies the top-down target Z).
- **Inspection** divides the picked Z back to cell coords (`inspect_at(..., zscale)`).
- **Marker** is parented under the renderer, so it inherits the stretch and stays aligned.

Perspective modes stay at scale 1, and **multi-view forces scale 1** (the shared world
can't be stretched for one pane without distorting the others). `_current_zstretch()`
returns 1.5 only when `_mode == TOP_FOLLOW and not _multiview_on`.

## Wall cutaway (see through rock in the way)

Rock that hides a lit space from the camera fades so you can see the contents — vital in caverns at
a low angle. `ZoneRenderer.apply_cutaway(eye, _focus, dt, enabled)` runs every frame (from
`Main._process`): a **live-zone** wall cell (tracked in `_wall_cutaway` as it's built) fades when it
**hides a lit, open cell behind it** — a lit neighbour (8-way) that's *further from the camera* than
the wall (ground-plane XZ distance) means the wall is between the camera and that lit space. Eased
in/out (`CUTAWAY_LERP`) up to `CUTAWAY_MAX`. This targets the lit *area* (loot, a lit room, the
player standing in light), not a single point, so the thing you want to see isn't blocked by its own
front wall. **Bounded to `CUTAWAY_RADIUS` tiles around the player** — without that the all-lit
overworld would try to fade nearly every wall at once (a flood of transparent overdraw that tanks
the framerate), and only rock near you needs to move anyway.

The fade is **`GeometryInstance3D.transparency`** with the **live zone's** wall material in
**`ALPHA_DEPTH_PRE_PASS`** (`_voxel_material_live` / `_wall_core_material(fade)` via
`_wall_skin_material`): at `transparency 0` it renders like solid opaque geometry (the depth pre-pass
keeps sorting correct), and blends out smoothly as `transparency` rises. **Neighbour zones use the
plain opaque `_voxel_material`** — they never fade, and the overworld renders *many* of them, so
routing all those walls through the transparent pipeline is what made the surface crawl; only the one
live zone pays the fade-capable material. (An earlier `ALPHA_HASH` version faded too but screen-door dithered,
which read as grain.) Occlusion is tested on the **ground plane (XZ)** — walls are full-height
columns, so an elevated camera's 3D ray would pass over their tops and miss. Off in top-down,
first-person, free-fly, and the multi-view grid. Only live-zone walls are tracked — neighbours are
never between you and the camera.

**Only LIT occluders fade** (`_wall_lit`, `CUTAWAY_LIT_MIN`). A dark wall in the way is already
near-invisible under the darkness overlay, so it stays solid; only rock you can actually *see* gets
cut away. "Lit" = the max of the cell's own and its four neighbours' light (a wall is visible when
its face onto an adjacent open lit cell is lit). On the lit surface everything qualifies, so the
cutaway behaves as before; in a dark cavern only illuminated rock between you and the camera fades.

## Persistence & misc controls

- **Settings** (`user://raves_settings.json`) — camera mode, compass heading, zoom
  (`_dist` / `_top_zoom`), first-person height, deep-water depth, **level height (Z gap)**,
  **look target (head/waist)**, and window size are saved on window-close and by Reset,
  restored in `_ready` (so Raves doesn't reset to "looking south" every run).
- **Look target** — COMPASS/FOLLOW aim at the player's **head** or **waist**, toggled in the
  ` menu (`camera follows: head/waist`). Head frames a close overhead shot; waist centres the
  whole body. Feet-aim (the old default) buried the sprite low in frame.
- **⟳ Reset** (top-right) — relaunches the process at the current window size
  (`OS.set_restart_on_exit` + `--resolution`), so it also picks up code changes.
- **Movement** — arrows move the player relative to the camera ("up" = forward). **Shift+arrow**
  = the 45°-rotated **diagonal** (Up=NE, Right=SE, Down=SW, Left=NW). Numpad is absolute 8-way.
- **Camera dolly (move it like the player)** — **S/D** raise/lower and **W/X** step forward/back
  one tile along the camera's heading, so you can reposition the view over a tile (e.g. scan the
  stacked Z-levels). Both are offsets added to eye+look (`_cam_lift` vertical, held; `_cam_pan`
  horizontal, 1 tile per press), so the view slides while keeping its angle. Not in FLY (WASD
  drives the free camera there). Transient: not saved, and reset on any camera-mode switch.
- **Shift+Space** — wait a turn in Qud (see [protocol.md](protocol.md); passes a turn).
- Inspect: **Ctrl/Cmd-click** or **I**. **Ctrl/Cmd + right-click** = clean-plate shot then
  inspect. **F12** = screenshot. **`` ` ``** = debug menu.

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
- **S/D vertical pan** — raise (**S**) / lower (**D**) the camera at the current spot to see other
  heights at a tile — e.g. scan up and down the stacked Z-levels (`_cam_lift`, added to both eye
  and look so the view slides straight up/down keeping its angle). Not in FLY (WASD drives it
  there). Transient: not saved, and reset to 0 on any camera-mode switch.
- **Shift+Space** — wait a turn in Qud (see [protocol.md](protocol.md); passes a turn).
- Inspect: **Ctrl/Cmd-click** or **I**. **Ctrl/Cmd + right-click** = clean-plate shot then
  inspect. **F12** = screenshot. **`` ` ``** = debug menu.

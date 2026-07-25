# Playbook: driving a legacy game from Godot (and reading it back)

A portable guide for the class of project Raves of Qud belongs to: **a Godot front-end / viewer /
test-harness layered on top of a game you can't rewrite** — closed source, a different engine, its
own render loop and input model. Caves of Qud (Unity/.NET) is the worked example here, but the
*problems* below recur for any target: an emulator, a Unity/Unreal/Godot game, a terminal roguelike,
a Flash/Air port, a native app. The specifics differ every time; the failure modes don't.

Read this before starting a new target. It will save you the multi-day detours we already paid for.

---

## The mental model: three planes

Every "Godot ↔ legacy game" integration has three separable planes. Keep them separate; most pain
comes from conflating them.

1. **Data & command bridge** — a channel that carries state *out* of the game and commands *in*.
   The high-bandwidth, structured, reliable path. Build this first.
2. **Rendering & presentation** — two apps, two windows, one OS. Who renders when, and the fact that
   the OS only fully renders the *focused* window. This is where the surprising walls are.
3. **OS-input harness** — real synthetic mouse/keyboard at the desktop level. The *universal* fallback
   that reaches anything the bridge can't, and the thing that makes tests reproducible.

You will want all three. The bridge is fastest and cleanest but can't reach everything; the OS harness
reaches everything but is slower and coarser; rendering is what humans (and your captures) actually see.

---

## Plane 1 — the data & command bridge

**Prefer an in-game mod + a socket over screen-scraping.** If the game supports mods/plugins (Unity
games usually do), a small mod that opens a localhost TCP server is the cleanest channel. Frame
messages simply: `[4-byte big-endian length][UTF-8 JSON]`. One direction publishes per-turn/per-frame
snapshots; the other accepts commands.

**Threading is the trap.** The socket runs on a background thread; the game's API almost always must be
touched only on its **main/logic thread**. Get this wrong and you get silent no-ops, or crashes
("graphics device is null"), or heisenbugs.
- Receive on the background thread → hand work to the main thread via the game's own marshaling
  primitive (a task queue, an event hook). Never call engine APIs from the socket thread.
- Find out which calls are main-thread-only *the hard way costs a day* — see "main-thread-only APIs"
  under Plane 2.

**Inject commands through the game's own input path, not a reimplementation.** Don't try to
re-derive "move the player." Feed the game's existing command/input queue the same token a keypress
would produce. It resolves doors, combat, turn cost, everything, for free.
> *Qud:* `ConsoleLib.Console.Keyboard.PushCommand("CmdMoveN")` enqueues the exact event a keypress
> makes; the game loop dispatches it identically. Bonus: it's thread-safe and wakes a blocked input
> read (see focus, below).

**Stamp every message with a build id.** Mods often compile at game startup, so a redeploy is inert
until a restart, and you *cannot tell from the outside* whether your fix is live. Put a version string
in every snapshot and print it in your inspector. This single habit prevents hours of debugging code
that isn't running.

**Snapshot the state you need, structured.** Positions, inventory, tiles, flags — as JSON, not pixels.
Pixels are Plane 2; data is Plane 1. Keep them apart.

---

## Plane 2 — rendering, and the two-window focus wall

This is the plane that will surprise you, especially on macOS.

### The core fact: the OS only live-renders the focused window
A human can focus only one window. On macOS, a **non-focused (or occluded) window's render loop is
throttled or paused** — this hits *both* your Godot viewer *and* the legacy game. So "two windows
updating live, side by side" fights the OS directly. Whichever window isn't focused tends to freeze
its view. Internalize this before you promise anyone a live side-by-side.

### It's layered — diagnose which layer is stuck
"The window isn't updating" is at least three different bugs. Separate them:
1. **Logic/turn thread paused.** The game's simulation thread is gated on focus (e.g. a
   `while (!focused) sleep` loop). Commands queue but never process. *Symptom:* inputs "flush in a
   burst the instant you focus the window."
2. **Render loop paused.** The sim runs but the engine isn't drawing frames for the background window.
   *Symptom:* state advances (your bridge snapshot changes) but the window is frozen.
3. **Buffer/mesh not refreshed.** Frames draw, but the specific view (a tile grid, a camera) isn't
   recomposited from current state, so it redraws stale content. *Symptom:* part of the window updates
   (e.g. a message log) while another part (the map) doesn't.
4. **OS compositor won't present.** Even if you render, the window server may not composite an
   unfocused/occluded window's surface. *Symptom:* nothing you do in-process changes the on-screen pixels.

You cannot fix (4) from inside the app. You often *can* fix (1)–(3). Instrument to find which layer:
a frame/heartbeat counter that ticks only when the loop actually runs tells you 1 vs 2 immediately.

### Levers that help (know their limits)
- **"Run in background" flags** (`Application.runInBackground` in Unity) let the engine keep rendering
  unfocused — but they are frequently **main-thread-only**, so setting them from a background/logic
  thread silently throws. Marshal to the main thread. *This exact bug ate a day here:* the flag was set
  from the turn thread, threw, and a `catch {}` swallowed it, so it was never on.
- **Decouple present from vsync** (`vSyncCount = 0`): an unfocused window's present can stall waiting on
  the focused display's refresh; unlocking it lets it render (throttled — expect a low background fps).
- **Force redraws you own.** In *your* app (Godot) you control the loop: call `RenderingServer.force_draw()`
  on a throttle while `!get_window().has_focus()` to keep the viewer live when it's in the background.
- **Refresh the specific view each turn.** If frames draw but the map is stale, call the game's own
  "recomposite the screen buffer" routine after each command (from the correct thread) so the view
  reflects new state.

### The pragmatic answer when you hit wall (4)
Stop fighting the compositor. Instead:
- **Read back via on-demand capture** (next section) — this works regardless of focus.
- **For a human demo, use the OS-input harness** (Plane 3): clicking a window focuses it, which
  refreshes it. Or drive from a script and accept that the live surface is the *focused* window while
  the other is one click (or one capture) away.
> *Qud outcome:* the Godot viewer is the live surface; Qud's own map can't be made to present live while
> backgrounded on macOS, but its buffer is kept current so it repaints *instantly* on focus, and
> on-demand capture reads its true state any time.

---

## Reading state back: capture without being fooled

Two channels, use both:
- **Structured state** over the bridge (Plane 1) — cheap, exact, scriptable.
- **The rendered image** — because some things only exist as pixels (UI you don't have data for, "does
  it *look* right").

**Have the app screenshot itself.** OS screen-capture usually needs Screen-Recording permission you
won't have; both engines can capture their own framebuffer to a file (Unity `ScreenCapture`, Godot a
forced draw + viewport grab). Read the PNG from disk.

**The capture trap — this *will* mislead you.** `ScreenCapture`-style calls *force a render*, so the
saved image can look perfectly current **even when the live window is frozen.** We "verified" a fix
twice this way before the user's own eyes caught that the live window wasn't moving. Rule: **a forced
capture proves the buffer/state, not that the live window presents.** To judge the *live* window, either
look at it (or have the human look) or measure the render loop's actual frame rate.

---

## Plane 3 — the OS-input harness (the universal fallback)

When the bridge can't reach it — native menus, dialogs, inventory grids, an ability bar, a launcher —
drive the game like a human, with **real synthetic mouse/keyboard at the desktop level.** This reaches
*everything*, is deterministic, and (bonus) clicking a window focuses it, solving the demo-refresh
problem as a side effect. It's also the layer that makes runs reproducible across machines from a shared
seed.

Build it in-process (ctypes/FFI to the OS input APIs), not by shelling out — a spawned helper (e.g.
`osascript`) is a *separate process* with separate permissions and will fail where your host succeeds.

### macOS specifics (the ones that cost time)
- **Accessibility permission** is required to post synthetic input (not for reading window geometry or
  sending Apple-Event "activate"). Grant it to the **process that actually runs your code** — which may
  be a *helper bundle*, not the app you think. Here the responsible bundle was the lowercase `claude`
  claude-code helper, **not** the main `Claude.app`, and **not** the confusingly-named top-level
  "Accessibility" settings pane (that's assistive *features*; you want **Privacy & Security →
  Accessibility**). Check the real state with `AXIsProcessTrusted()`, not a proxy. It took effect live,
  no restart — but be ready to relaunch the host if it doesn't.
- **Synthetic clicks need more than down+up.** Post a `MouseMoved` to the target first, and set
  `kCGMouseEventClickState` on the down/up events — many apps (Unity included) **drop clicks without
  it.** Keyboard needed neither; the mouse did. If keys work but clicks don't, this is why.
- **App names differ per API.** The window-list *owner* name, the AppleScript *application* name, and
  the process name can all differ (Qud: owner `CavesOfQud`, app `CoQ`). Resolve an alias per call.
- **Target by fraction, not pixels.** Get the window rect, then click at `(x + fx*w, y + fy*h)`. This is
  robust to window position, resolution, and Retina scaling (a 2× capture maps 1:1 to the logical
  window in fractions). Multi-monitor coordinates are global and can be negative.

### The loop that ties it together
`capture the game's render → locate a UI element's fractional position in the image → click that
fraction of the live window → re-capture → confirm the effect.` That is your reproducible harness, and
the base for parallel/seeded runs. *(Verified here by clicking the Sprint button: "You begin sprinting!",
move-speed 100→200.)*

---

## Reverse-engineering the legacy target (don't guess — read the binary)

You will need to know internal names, gates, and hooks the game never documented. Decompile and reflect;
verify against the actual shipped binary.
- **.NET / Unity:** `ilspycmd` (decompile a type to C#) + `System.Reflection.MetadataLoadContext` over
  the game's `Managed/*.dll` (self-contained; core assembly = `mscorlib`). This is how we found the
  focus gate (`while(!GameManager.focused) Thread.Sleep`), the input queue (`Keyboard.PushCommand`), the
  render path (`RenderBase → DrawBuffer`), and the buffer→screen blit (`GameManager.OnUpdate`).
- **Other engines:** the analogue exists (Il2CppDumper/Ghidra for IL2CPP or native, `javap`/CFR for JVM,
  symbol tables for native). The principle is constant: **find the exact symbol and verify it against the
  running build**, rather than pattern-matching on a guessed name (`ColorUtility.CAMERA_BACKGROUND` was
  not the world background; `RenderTile` was reasoned about for rounds before a field proved it never fired).
- If the modding path supports it, patch libraries (Harmony) let you hook methods cleanly — but check
  platform support (**Harmony patching is blocked on macOS** for this target, which forced watchdog-thread
  workarounds instead of clean patches).

---

## A checklist for a new target

When you start a new Godot-on-legacy-game integration, work through these:

- [ ] **Modding hook?** Can you load code into the game? If yes → in-game bridge. If no → you live
      entirely in Plane 3 (OS input + screen capture) and read state from pixels.
- [ ] **Bridge up:** localhost socket, framed JSON, build-stamped snapshots, command injection through
      the game's own input path. Verify with a position round-trip.
- [ ] **Threading mapped:** which calls are main-thread-only? What's the marshaling primitive? Never
      touch engine state off the game thread.
- [ ] **Focus behavior probed:** does the game render/process while unfocused? Instrument a heartbeat.
      Identify which of the 4 layers stalls.
- [ ] **Viewer stays live unfocused:** force redraw in your Godot app when `!has_focus()`.
- [ ] **On-demand capture** for both apps; remember the forced-capture trap when verifying.
- [ ] **OS-input harness:** in-process synthetic input; Accessibility granted to the *right* process;
      clicks carry move+ClickState; fraction-based targeting; per-API app-name aliases.
- [ ] **Reverse-engineering toolchain** ready (decompiler + reflection) and a build-stamp habit so you
      always know what's running.
- [ ] **Verification discipline:** capture-and-confirm every fix; never trust "it should work"; watch for
      the capture that lies about the live window.

---

## The meta-lesson

The multi-day detour on this project was trying to force an unfocused macOS window to present its 3D
map — a wall the OS owns. The productive move was to **stop fighting rendering and build the OS-input
harness**, which made the original goal (drive + verify the game for development and human testing) not
just possible but *better*: deterministic, reproducible, and able to reach every corner of the game's UI.
When a plane fights you past the point of reason, check whether a different plane gets you the actual
outcome you wanted.

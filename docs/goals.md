# Raves — version goals

Milestone-level "north stars" for Raves, tagged **V*n***. Each is the thing a work cycle drives
toward (see the work-cycle doc). The foundational goals — the bridge/Holodeck spine and the world
store — live in [`README.md`](../README.md) and [`roadmap.md`](roadmap.md); **V3** is the first
explicitly tagged goal captured here.

---

## V3 — Full 1:1 parity across the game, driven by the state tree

**Goal.** Every screen of the game — the title, each menu, character creation, the in-game HUD, and
every sub-panel — renders in Raves' **1:1 (parity) mode** as a faithful reproduction of the real
Caves of Qud, indistinguishable at 1×. Progress is tracked to completion by a per-screen scoreboard,
not vibes.

**Why it's ONE goal, not N ad-hoc fixes.** Every screen is the *same shape of work*: find where
Raves diverges from Qud, and reproduce Qud behind the 1:1 switch. Once you see it that way, the whole
game is a single traversal problem with a single repeatable recipe — the reusable pattern below. That
also means the effort is *measurable* (a completion number per screen) and *parallelizable* (any
screen can be picked up independently).

### The map **and** the scoreboard = the state-machine tree

The canonical list of screens is the highvisor **game state-machine tree**
(`highvisor/gametree.json`, rendered in the cockpit above the log): `freehold → title →
{new_game/chargen, continue/load, records, options, mods} → in_game → {top_bar, ability_bar,
message_log, inventory, …}`. It is simultaneously:

- **the map** — which screens exist and how you reach them (drive there with the `gamestate` /
  future `gamego` ops); and
- **the scoreboard** — each node carries a per-app `done` (0–1). `done.raves` on a node is *how
  finished the 1:1 work is on that screen*. V3 is complete when every node's `done.raves` clears the
  bar.

Keeping the scoreboard honest is part of the loop: bump a node's `done.raves` in `gametree.json`
after each pass (it hot-reloads in the cockpit).

### Breadth-first, then circle back

Sweep the tree **breadth-first** — get every screen to a baseline 1:1 before polishing any one to
perfection — then circle back for depth. (We started at `title`; the top-bar `name`/`separator`
polish, see [`reports/1to1-topbar-name-separator.md`](../reports/1to1-topbar-name-separator.md), is a
deliberate *circle-back*.) The scoreboard makes the frontier obvious: work the lowest `done.raves`
nodes first.

### The per-screen recipe (reusable for every node)

1. **Locate + drive.** Use the state tree to confirm where Raves and Qud each are (`gamestate`),
   and drive both to the target screen.
2. **Capture at 1×.** `allow_hidpi=false`, so **capture px == Godot px == Qud px** — measure a pixel
   and set the Godot value 1:1, no scale factor. Capture via highvisor (`hv shot`).
3. **Diff / measure.** Use the cockpit **Congruence** tool (crossfade + similarity map) and/or a
   short PIL script to find and quantify each divergence (colour, size, position, presence).
   **Reproduce Qud's *layout model*, not its pixels**, and let the diff *pattern* tell you position vs
   structure — the discipline that got the top bar to ≤1px is in
   [`decisions/1to1-measurement-and-layout.md`](decisions/1to1-measurement-and-layout.md). Read it
   before starting a new row/screen; it's what turns nudge-thrash into one build per fix.
4. **Reproduce Qud — behind the 1:1 switch.** For each divergence, render Qud's version in Raves
   **gated on `Settings.one_to_one()`**. User mode keeps Raves' own QoL chrome; 1:1 mode is the
   faithful reproduction. This gating discipline is non-negotiable — it's what lets parity work
   proceed without ever regressing the user experience.
5. **Rebuild → relaunch → re-verify.** `tools/build_macos.sh` (the `raves` launcher runs the
   exported `.app`, which freezes scripts), then `hv launch raves`, re-capture, confirm the
   divergence is gone.
6. **Score it.** Update the node's `done.raves` in `gametree.json`.

### The gating discipline (the load-bearing invariant)

**1:1 is a MODE**, `Settings.one_to_one()` (persisted `mode: "user" | "1to1"`). *Every* parity change
sits behind it, at whatever layer is cleanest for that screen:

- in-game chrome → `MainFrame._apply_layout_mode` / `_apply_panel_sizing` and friends;
- the title → `MainMenu` reads `Settings.one_to_one()` per element, and clears the 1:1 title theme's
  Label background (`set_stylebox("normal", …, StyleBoxEmpty)`) to drop Raves' framed look;
- future menus (Options, Records, Mods, chargen) → the same per-element gate in their screens.

User mode must always revert clean. If a screen can't be made faithful without touching shared code,
branch on the mode there too — never regress user mode to reach 1:1.

### Exemplar — the title screen (the template for every other screen)

`title` was the first full pass (raves `72c9cbf`): drop the "Load a game…" hint; replace the "Raves
of Qud / build MIT" corner with Qud's own readable version; clear the Label background bands behind
the bottom-left list; swap the literal "↑↓" for a drawn arrow-keys icon — **all five gated on
`Settings.one_to_one()`**, verified by capture. Every other node in the tree is the same recipe with
different elements. Copy the shape, not the specifics.

### Definition of done

- Every node in the state tree has `done.raves` ≥ the parity bar (propose **0.9**), and
- a Congruence pass on each screen shows no structural divergence — only intentional, documented
  differences (e.g. where Qud's own text is illegibly dark and Raves deliberately lifts it), and
- everything is behind `Settings.one_to_one()`; toggling back to user mode reverts every screen
  cleanly.

### Related

- State tree + cockpit panel: [`highvisor-operational-quickref`] / `highvisor/gametree.json`.
- 1:1 mode architecture: [`raves-one-to-one-mode`] (memory) — master switch, panel/camera halves.
- Visual-style reference (fonts, palette, chrome, effects profile): `reference-qud-visual-style`
  (memory) and [`reports/`](../reports/).

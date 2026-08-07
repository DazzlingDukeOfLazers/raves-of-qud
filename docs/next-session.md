# Handoff — next session (written 2026-08-07, end of the feedback/parity run)

Branch `dd/main-ui-framing` (raves) + `dd/integrate` (highvisor). Everything below is committed and
pushed; the working tree is clean.

## Do these two FIRST — they blocked live verification three separate times today

1. **`raves_state.json` lies.** It reported `scene: in_game` with a one-second-old timestamp while
   the window was plainly showing the title screen. This is a DETECTION bug, not flakiness:
   `hv goto` and `hv assert` trust that file, so every recipe built on them can silently drive the
   wrong screen — and any screenshot taken afterwards is of the wrong thing. Suspect `UiState`
   not being re-set on the MainFrame → MainMenu lifecycle fallback (`_poll_game_lifecycle` changes
   scene to MainMenu; does it clear the scene report?). Fix this before any live-driving work.
2. **`hv goto raves in_game` frequently does not land**, then works on retry. Related to (1) or its
   own recipe problem. Until both are fixed, budget two or three retries per drive and ALWAYS
   confirm from a screenshot, never from the state file alone.

## Open feedback items (`~/Library/Application Support/RavesOfQud/feedback.jsonl`)

Read them with the snippet in "Tools" below. Closed today: nav icon, Continue save name, typing
guard, Sprint cooldown formatting. Still open:

- **CTRL / SHIFT need full yellow brightness** — command bar; almost certainly a constant in
  `CommandBar.gd` next to the keycap drawing. Cheapest of the three.
- **Stairs-up icon should grey out when the zone has no stairs** — needs the mod to ship a
  "zone has StairsUp/StairsDown" flag (Cell has `HasObjectWithPart("StairsUp")`; the minimap
  colour chain already tests exactly this, see `WriteMinimap`), then `MainFrame`'s nav cluster
  dims the cell.
- **Message log needs a scrollbar** — `MessageLog.gd`. Note 1:1 parity: check whether Qud's own
  log shows one before adding it in 1:1; if not, user mode only.

## One open colour question (one-line fix if wrong)

`CommandBar.CD` is `#6cb7c8`. Qud's ability bar also carries a saturated `(0,139,255)` and I could
not capture a COOLING ability in Qud to confirm which one the cooldown icon is. Daniel said "light
blue", which is why I chose this one. If it looks wrong on screen, change that constant only.

## State of the work

**Sidebar is done and measured** (same-moment captures, mean |RGB| unless noted):
message log **0.161** · minimap **0.61** (correlation 0.979) · nearby objects **4.69** (tiles 0.01;
the remainder is the glyph-antialiasing floor, not a layout error).

**Feedback tool** is fully built: Cmd+Right-click any element names it, thumbnails it with a
zoom/pan viewer (Fit / 1:1), and appends JSONL. Owner-drawn panes answer `feedback_element_at(p)`;
builders can stamp `feedback_label` / `feedback_action` metas for exact names.

**In-game Options and Control Mapping** now open Raves' own screens from the mirrored system menu.

## Testing (new — `docs/testing.md`)

Two tiers, and the rule that produced them: **if the defect is decidable from the source, decide it
statically.** Static checks run in milliseconds, need no window, and cannot go flaky the way every
live check did today.

- **SPOT, every commit, ~5s, nothing running:** `python3 tools/regression/typing_guard_audit.py`
  (dependency-free — this is the one that runs on another machine), plus the headless parse check,
  the `Main.gd --check-only` deep check, and `dotnet build mod/RavesOfQudBridge.csproj`.
- **FULL, pre-release or after input/chrome/bridge work:** drives both apps; includes the live
  typing-guard case, the parity sweep, the menu recipes, and the mod round-trip.

The typing-guard audit prints the whole text-field inventory (12 today) every run, so a NEW text
field shows up in the diff even when it passes. Registered on the `in_game` node of highvisor's
`gametree.json`.

## Hard-won this session — all written up in `docs/gotchas.md`

- **Our scanline sweep blanked Qud's own minimap.** It neutralises `_ColorOverlay`/`_OverlayTex` on
  every UI Graphic; the minimap draws through the same material. `_ColorOverlay` is the killer (the
  shader multiplies by it); `_OverlayTex` is safe AND removes the scanlines. `Bridge.MinimapMask`
  = 2, live-settable via the `mmmask` command.
- **A hidden `CanvasLayer` still delivers input to its children.** Cost Esc app-wide once. Screens
  built per open must be FREED on close, not hidden.
- **`PanelContainer` clamps `content_margin_top` at 0** — a negative margin silently does nothing.
- **Qud's `(24 - i)` row math is Unity's bottom-up texture origin**, not a flip to copy in Godot.
- **A stuck HID modifier** (daemon re-exec mid key-combo) makes every synthetic key arrive
  Cmd-modified and silently no-op, surviving app restarts. `_clear_stuck_mods` self-heals now.
- **A mod probe using `GetPixels32`/`GetWorldCorners` passed `dotnet build` but made Qud's Roslyn
  throw**, so the mod went MISSING and the bridge died. Keep diagnostics to APIs the mod already
  uses, and revert fast.
- **Redeploying mod files mid-session** triggers Qud's "Mod Configuration Differs" prompt on load —
  answer "Load keeping current mod configuration".
- **A graceful `osascript` quit of Raves kills Qud too** (QudLauncher).

## Tools worth remembering

```bash
# read the feedback queue
python3 - <<'EOF'
import json, os
p = os.path.expanduser('~/Library/Application Support/RavesOfQud/feedback.jsonl')
for l in open(p):
    d = json.loads(l)
    print(d['ts'], '|', d.get('element'), '|', d.get('text'))
EOF

python3 tools/regression/typing_guard_audit.py     # SPOT, no deps
```

Same-moment parity capture (Qud freezes unfocused — activate it FIRST, wait ~2.5s, then Raves):
`hv activate "Caves of Qud"; sleep 2.5; hv shot qud a.png; hv activate "Raves of Qud"; sleep 1.5;
hv shot raves b.png`

# Handoff — next session (written 2026-08-07, end of the feedback/parity run)

Branch `dd/main-ui-framing` (raves) + `dd/integrate` (highvisor). Everything below is committed and
pushed; the working tree is clean.

## ~~Do these two FIRST~~ — BOTH FIXED 2026-08-06 (one root cause, not two bugs)

`raves_state.json` was not lying and the goto recipe was not flaky: **three Raves processes were
alive**, all writing that one path on a 2s heartbeat, so reads cycled
`in_game → status_tinkering → title` and `_find_win` could hand a recipe a different window than
the one being read. Raves now stamps `pid` and writes `raves_state.<pid>.json`; highvisor reads the
sidecar for the window's owning pid, refuses a foreign-stamped shared file, shows `!! N INSTANCES`
in `hv state`, and `hv goto` refuses to drive while duplicates exist. Guarded by
`python3 tools/selftest_state_read.py` in the highvisor repo (stdlib only, no apps).
Full write-up in `docs/gotchas.md` ("One state file, many writers").

Still true and worth keeping: **confirm from a screenshot, never the state file alone.**
When a report and the screen disagree, `pgrep -f "Raves of Qud" | wc -l` FIRST.

## Open feedback items (`~/Library/Application Support/RavesOfQud/feedback.jsonl`)

Read them with the snippet in "Tools" below. Closed today: nav icon, Continue save name, typing
guard, Sprint cooldown formatting. Still open:

- **CTRL / SHIFT need full yellow brightness** — command bar; almost certainly a constant in
  `CommandBar.gd` next to the keycap drawing. Cheapest of the three.
- ~~Stairs-up icon greys when the zone has no stairs~~ **DONE** — `stats.stairsUp`/`stairsDown`
  (mod, cached per zone), `MainFrame._apply_stair_availability` dims the icon to alpha 0.4.
  Measured: no-stairs zone 45% brightness, stairs zone identical to the Down icon. **This is a
  deliberate divergence** — Qud has no disabled state for Up/Down at all (only WindowLock /
  Finder / Minimap carry an `ActiveButton`, and those say ON/OFF with hue, not brightness), and
  the cluster is 1:1-only chrome, so expect a small top-bar parity delta in stairless zones.
  Down is deliberately NOT dimmed (digging/falling descend without stairs; Joppa ships
  `stairsDown` true and `stairsUp` false, so they really are independent) — the flag is already
  on the wire if that changes.
- **Message log needs a scrollbar** — `MessageLog.gd`. Note 1:1 parity: check whether Qud's own
  log shows one before adding it in 1:1; if not, user mode only.

## ~~One open colour question~~ — ANSWERED by measurement (2026-08-06)

`CommandBar.CD` was `#6cb7c8`, a lone brighter blue. Drove Sprint through off / on / cooling over
the bridge and sampled Qud's own bar per glyph column: **Qud draws the whole `[81]` tag, brackets
included, in the SAME cyan as the ability name** ((95,159,173) vs the name's (96,161,176) in one
frame), so `CD` is now bound to `NAME_1TO1` and tracks it by construction. The toggle tags are
two-tone — dark brackets either way, `on` a saturated green, `off` Qud's text grey — which is what
Daniel reported and what a single per-tag colour could not express. Final: `[on]` matches Qud at
(2,123,6) exactly; brackets (21,51,51) vs (20,54,54); `off` within 3%.

**The rule that made it land** (also in `docs/gotchas.md`): pass q8 Qud's SCREEN value, never a
palette source. q8 pre-compensates *Raves'* canvas shader, so a palette source double-counts a
curve Qud already applied — the palette's `g` is (0,148,3), but Qud puts (3,123,6) on the glass.

The `<1>` quick slot is fixed too (same pass): chevrons bright grey, digit amber, built by
`_hotkey_cell_tag` from the plain `_hotkey_label` so they can't disagree about which key is shown.
Digit (126,110,77) vs Qud's (132,116,80); the chevrons sit at (174,175,175) vs (197,198,198) —
the **small-text rasteriser floor**, the same ~85% the ability NAME sits at in the accepted 4.0
bar score. Don't inflate a colour constant to fight it.

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

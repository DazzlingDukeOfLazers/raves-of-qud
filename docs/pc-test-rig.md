# The PC test rig — unit-testing tiles & NPCs (Workstream A, continued)

*Drafted 2026-08-04 on the PC branch. Companion to [`phase2-test-plan.md`](phase2-test-plan.md);
this is the PC's operational plan while the Mac drives V4 (status screens, options
write-back, equipment/inventory). Division of labor: **the Mac owns menus, the PC owns
per-element world verification** — tiles, NPCs, liquids, animations.*

## Where the rig stands (2026-08-03 live runs)

Wire-level verification is green: **2501/2502 elements PASS** across walls / plants /
liquids / furniture / food / implants / creatures (`reports/checker/*.md`). The stage is
hardened (whole-zone clear, pacified staging, popup self-heal, settled retry). The one
genuine FAIL is ticketed (`reports/2026-08-03-checker-chiliad-npe.md`). The live-drive
loop on this box: `hv restart qud` → `embark` over the bridge → godmode →
`checker.py sweep <cat>`.

## Merge hygiene (why this coexists with the Mac's V4 work)

PC work stays in: `mod/ObjectChecker.cs` (additive), `tools/capture/checker.py`,
`plat_win.py` + new plat-seam functions, `reports/checker/**`, this doc. `Bridge.cs`
gets **additive switch cases only**. Don't touch `godot/` menu screens or the V4
exporters mid-flight. (The 2026-08-04 merge proved this shape: 40 Mac commits merged
clean over the checker.)

## Rung 1 — wire sweeps as standing regression (green; keep running)

After any mod / Qud / renderer-adjacent change: full 7-category sweep (~15 min).
- **Add `checker.py diff <cat>`**: compare a fresh sweep against the committed baseline
  JSON — report new FAILs, healed FAILs, and warn drift. The committed
  `reports/checker/*.json` are the baseline; that's what makes the sweep a regression
  suite rather than a snapshot.

## Rung 2 — deterministic boot: golden save + `loadsave`

The Mac just landed the missing primitive: the mod's **`loadsave`** bridge command
(exact save GUID, title-screen only) + `hv loadsave <name>`. Combine with
`tools/capture/saves.py` goldens:
1. **Port `saves.py` behind the plat seam** — it hardcodes the Mac's
   `com.FreeholdGames.CavesOfQud` path, `pgrep`, and `rsync`; move
   `qud_data_dir()` / `qud_running()` / the copy into `plat_mac.py` / `plat_win.py`
   (Windows: `AppData/LocalLow/Freehold Games/CavesOfQud`, `tasklist`, `robocopy`
   or `shutil`).
2. **Create the PC's checker anchor save**: embark once, park in a cleared zone,
   save+quit, `saves.py golden checker` (per-platform binary, committed index only —
   the Workstream C convention).
3. Rig boot becomes restore → load → sweep: no chargen, no famished drift, same zone
   every run. **Verified on the PC 2026-08-04** (golden `checker`, char `Tygashwuraq`):

   ```bash
   python tools/capture/saves.py restore checker   # Qud must be down
   hv loadsave Tygashwuraq                          # restarts to title if needed, exact-ID load
   # then over the bridge: popup cancel ×N (load popup), wish godmode (resets per boot)
   python tools/capture/checker.py sweep <cat>
   ```

   Gotcha (cost a debugging loop): `loadsave` needs the MERGED mod deployed —
   an old deployed mod ignores the command silently. `Player.log` shows
   `[loadsave] …` lines when the right build is running.

## Rung 3 — pixel congruence: the missing half of A (tiles & NPC sprites)

The wire pass proves data; the point is RENDER parity. The Mac's parity kit set the
bar and the method (mean |Δ| + %px>32; playfield reference ≈ 2 / 0%).
1. **Bring the Raves viewer up on this PC** — Godot 4.7 is installed; use the new
   `--one-to-one` flag (chromeless, self-placing, 1:1 locked), add a `raves_solo`
   launcher + a PC layout in highvisor (this display ≠ the Mac's 4K stack).
2. Per element: same-turn `qudshot` + Godot `shot` (already wired as
   `checker.py --shots`), **crop the stage-cell region** from both (stage cell is
   fixed at zone center; Qud cell geometry is knowable from the window size),
   score mean-diff / %px>32 per element.
3. **Strict checks** that caught real bugs: dominant-rendered-colour vs wire colour
   (snapshot `color`/`detail` → expected palette RGB), pure-white pixel parity.
4. Output: PASS/WARN/FAIL per element + contact sheets under
   `reports/checker/shots/<cat>/`; failures become tickets like the Chiliad one.
   Pure-stdlib PNG decode already exists (`tile.py`) — reuse it.

NPC-specific checks ride this rung: billboard sprite congruence, the **H-flip
sprite-facing rule** (see the picker's tile work), submerged/stained variants.

### Rung 3 status (2026-08-04 evening, PC) — WORKING END TO END

The full loop runs and scores: stage → focus-managed staleness-guarded capture
pair → calibrated stage-cell crop → mean-diff verdict. First scored sample:
Dresser 6.94/0% PASS; walls ×10 all wire+pixel PASS (means 3.8–8.1).
Calibration reproduces identically run-over-run on both apps.

What the earlier "blockers" actually were (all resolved):
- The "Raves DPI doubling" was a MEASUREMENT artifact: a restarted highvisor
  daemon lost DPI awareness (ctypes doesn't raise on a FALSE Win32 return, so
  the awareness call could fail silently) and reported virtualized rects. Fixed
  in highvisor (checked returns + `ping` now reports `dpi_status`); the window
  itself was stable all along.
- "Qud resized/zoomed": the capture size was the same DPI artifact; the real
  Qud render is its 2301×1213 client area throughout.
- The "night dimming" was two things: dawn-hour light ramp (turns advanced the
  clock) AND a frozen map buffer — on Windows, Qud's tile-map camera only
  recomposites while FOCUSED (the mac unfocused-render fixes don't hold here).
  `shots_for` now focuses Qud for its capture; the golden save is re-archived
  at High Salt Sun (midday) so every boot starts in good light.

**2026-08-04 night: the first FULL scored sweep is done — 2492 elements
pixel-scored, 93.7% PASS**, failures collapsed into four families + 9 creature
singles (`reports/2026-08-04-checker-pixel-findings.md`; evidence crops
committed per flagged element). Along the way: `checker.py zoom` (uiQueue only
drains focused — same root as the frozen buffer; run it, then `calibrate`),
pixel-exact calibration rects (grid-quantized rects poisoned sparse sprites —
furniture went 301 FAILs → 22), reconnect/truncated-capture/periodic-flush
hardening in the sweep loop.

Still open (quality, not correctness):
- `wire_delta` (dominant-vs-palette) needs ambient-tint awareness before it's
  a real check — raw palette RGB vs the tinted render reads ~136 on a PASS.
- Per-app calibration clip fracs (0.58 Qud / 0.48 Raves) are layout constants —
  re-measure if either window layout changes.
- Multi-cell blueprints (Marble Dais, TauSoft) need a staging rule before their
  scores mean anything; the mod-server reset under connection churn deserves a
  server-side fix (the sweep's reconnect lane papers over it).

## Rung 4 — animation fixtures (the decoded-program list)

Per `phase2-test-plan.md`: every decoded animation gets a named fixture — gas swirl,
fire layers, smear flash (per liquid), hologram clamp, concealed-hologram flicker
(the stage's adjacent seat arms it), sludge blink/cycle, engulfed pair, target blink,
sparkles, Mimic camouflage, stains, mix compounds.
- Method (the measured playbook): burst captures at **jittered** cadence (never ~0.5s
  — phase-lock), distinct-state counts, duty-cycle bands vs the decoded constants.
- `checker.py anim <fixture>`: stage the element(s), N jittered `qudshot`s, count
  distinct stage-cell crops, compare against the fixture's expected state count/duty.

## Rung 5 — known tickets & rule refresh

- **Chiliad NRE** (`reports/2026-08-03-checker-chiliad-npe.md`): skip-list vs history
  seeding — revisit when the Proving Grounds save exists.
- **Category rules on Qud 1.0.5**: `HasPart("MeleeWeapon")` now matches every wieldable
  item → `weapons` = 4044, `items` = 0. Refresh `ZooBuilder.Select`'s weapon/item
  split (small shared-file change; coordinate with the Mac before touching).
- Sweep telemetry: count retries per run in the report header (turn-flow-race rate).

## Rung 6 — zones & zone-specific artwork → `pc-zone-plan.md`

Rungs 1-5 certify elements **in isolation** (2483/2483 wire, 0 pixel FAIL — findings
§13). Everything that only exists when elements are **composed** is still unverified:
zone-painted ground (the grass in every Joppa capture is `[painted ground]`, never
staged), wall autotiling (the sweep hit **4 of 256** bitmasks; 225 of 229 walls were
the isolated `-00000000`), per-zone background/tint, the whole lighting cycle we pin
bright for determinism, liquid depth, remembered neighbours, and the world map.

Full plan — method (structural census / masked whole-playfield congruence / warp
stations), station list, determinism budget — in **`pc-zone-plan.md`**.

## Sequencing

Rung 2 first (it makes every later run deterministic and cheap), then 3 (the payoff:
actual tile/NPC render verification), 4 as renderer animation work continues, 1
continuously, 5 opportunistically. Rung 6 opens once 3/4 are certified — they are.

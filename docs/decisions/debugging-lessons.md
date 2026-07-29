# Debugging lessons, learned expensively

The war-story record — each of these cost a debugging round-trip (often several) to learn. Moved out of
`CLAUDE.md` so that file stays a lean operating manual; kept here in full because the *reasoning* is the
value. The one-line **rules** these distill into live in `CLAUDE.md` ("Hard-won rules"); this is the *why*.

New lesson? Add it here (full story) and, if it changes how an agent should act, add its one-liner to
`CLAUDE.md`.

## Crashes, hangs & the GPU

- **The EXPORTED app writes NO crash reports** (ad-hoc signed → macOS suppresses `~/Library/Logs/
  DiagnosticReports/*.ips`), and its stdout is block-buffered when redirected to a file, so a crash
  loses the tail. To get a real GDScript backtrace or native stack, run the project under the **dev
  editor** instead: `Godot --path godot` (writes `Godot-*.ips`, flushes errors). `godot.log` under
  `app_userdata/Raves of Qud/logs/` flushes script errors too. Don't trust an empty redirected log
  as "no error" — it's probably just unflushed.
- **`--headless` cannot catch GPU/driver bugs — it renders with a dummy driver.** A `MultiMesh`
  with a `billboard_mode` material `SIGBUS`-crashed the Metal driver (`memmove` on the instance
  buffer); the headless parse-check rendered it "fine" because it never touches Metal. A crash in
  `AGXMetal*` / `IOGPUMetalResource` / a `memmove` under the RenderingServer flush is a GPU
  resource fault, NOT a GDScript error — suspect the newest instanced/material path, and prefer the
  proven `Sprite3D` billboard over per-instance `MultiMesh` billboards. Only a real windowed run
  proves a render path; headless only proves it parses and `_ready` runs.
- **A single-frame GPU-resource spike can overflow the Metal allocator — spread big builds across
  frames.** The world-map crash was NOT raw volume (the surface is the same cell count and never
  crashed); it was the number of *distinct* resources created in ONE frame (the world map has a
  different terrain texture/material per cell). The fix was the incremental build (`_ib_step`, a
  chunk per frame), not any single "bad node". When a deterministic same-stack GPU crash resists
  reasoning, STOP guessing and bisect *with the user* on a real machine: a couple of cheap toggles
  (does it crash on the surface? with the feature off?) localized it in two rounds after several
  wrong hypotheses. Trust the bisection over the theory.
- **No crash report means a HANG, not a crash — and a hang is usually fillrate/overdraw.** A `SIGBUS`
  always writes `~/Library/Logs/DiagnosticReports/Godot-*.ips`; when several "crashes" wrote none, the
  app was being GPU-timeout-killed, a different failure entirely. The cause was giant **additive**
  glow quads (10 × parasang-scale, 240×360, overlapping) — a fillrate bomb. Two lessons: (1) FIRST
  check for a fresh `.ips` to tell crash from hang before theorizing; (2) big per-object additive
  quads hang the GPU — but so does environment **bloom** on this setup (a full-screen multi-pass
  post-process, on top of DOF + fog, at the ~4K external-display window size, tips the M1 Pro past
  the GPU timeout). The only fill-free "brighter" is an **HDR modulate on an alpha-scissored sprite**
  (clamps toward white, no halo, no extra pass); a real glow *halo* needs a smaller window or fewer
  post-passes. Budget GPU fill/post-process for the WORST display (4K), not the laptop panel. Also:
  a mid-bisect "still crashes" can be a stale build — confirm a `⟳ Reset`/relaunch actually took.
- **Unfocused Godot doesn't DRAW.** Godot's `_process` runs unfocused (file polling works) but it
  doesn't render, so a screenshot that `await`s `frame_post_draw` hangs — use `RenderingServer.force_draw()`.

## Qud APIs & data

- **Look up Qud APIs against the real assembly, don't guess.** `dotnet build mod/…csproj` compiles
  against the game's `Assembly-CSharp.dll`, so a wrong method/stat name is a compile error you catch
  *before* the user runs. For exact signatures, decompile: `DOTNET_ROOT=/opt/homebrew/Cellar/dotnet/
  <ver>/libexec ~/.dotnet/tools/ilspycmd "<Managed>/Assembly-CSharp.dll" -t <FullTypeName>`. This is
  how the status-bar stat APIs were nailed (AV via GetStatValue matched by luck; DV/MA needed
  `Stats.GetCombatDV/MA`). `GetStatValue(name)` compiles for ANY string and returns 0 for a bad name,
  so a field reading 0 at runtime = wrong key, not a crash.
- **Reflect, don't grep.** String-grepping `Assembly-CSharp.dll` once "proved" `Render` fields were
  lowercase; they're capitalized. Use a `MetadataLoadContext` probe for exact signatures.
- **Prefer accessors to fields.** `Render.getTile()` / `getRenderString()` resolve what is actually
  drawn; the `Tile`/`RenderString` fields are static blueprint values, empty for anything runtime-chosen.
- **Prefer Qud's own predicates** to inferring from tile names — `Cell.HasBridge()`,
  `HasWadingDepthLiquid()`, `GameObject.HasIntProperty("Bridge")`, `IsCreature`. Tile families are a
  *symptom* of game state, not the source of truth.
- **Verify a value, don't trust a field name.** `ColorUtility.CAMERA_BACKGROUND` sounds like the
  world's background colour. It is the alias `"camera background"` → `#40a4b9`, plain cyan. Trusting it
  turned the entire world turquoise.
- **A cell is not just its objects.** Qud paints a ground layer (dirt, grass) onto cells with no
  `GameObject` at all — 1103 of 2000 in a Joppa zone. `Cell.Render()` composites it. Missing this cost
  six wrong hypotheses and four shipped-but-inert fixes.
- **Never call Unity from the turn thread.** It crashes the game natively. Marshal through
  `GameManager.Instance.uiQueue`. Harmony patching is blocked on Apple Silicon (`mprotect EACCES`).
- **Tile paths mix separators** — creature tiles use `\`, most others `/`. Normalize both.

## Method (measure, don't guess)

- **Measure before hypothesising.** When a search keeps coming up empty, verify the dataset is complete
  instead of refining the search. Emitting `nHeld`/`nRendered`/`nSent` per cell proved in one turn that
  nothing was being dropped, which eliminated the entire object path — after six rounds of guessing had not.
- **Know which build is running.** Mod `.cs` only compiles at Qud startup. `Protocol.Build` ships in every
  snapshot and the inspector prints it. Several rounds were spent reasoning over a build that did not
  contain the fix being tested.
- **Verify a fix did something.** `RenderTile` was deployed and reasoned about for several rounds before
  `fg=` being empty on every object revealed it had never once fired.
- **The mod runs INSIDE Qud, so it can slow the GAME, not just Raves.** "Overworld sluggish" cost many
  rounds guessing at Godot before measuring the bridge: the mod built a full snapshot on every turn even
  with Raves closed (gate on `ClientCount`), and world-map travel auto-advances a BURST of turns —
  publishing ~60–100 snapshots/sec, pinning Qud AND starving Godot's frame loop (the "lighting eases
  slowly" tell). Measure `serverUs`, `renderBaseUs`, and the **publish RATE** (10ms gaps = a flood)
  before touching the client. See protocol.md "publish cadence".
- **A continuous visual glitch with NO new data is a client-side per-frame animation.** The world map's
  "oscillating light" persisted while idle (throttle → zero snapshots), which pinned it to `_process`
  (the torch flicker), not the data.
- **Ask the user to click, don't infer from screenshots.** The inspector exists for this. Five hypotheses
  were formed from pixels; one selection would have beaten all of them.
- **A snapshot is only published on a turn.** Capture scripts must block, and must reconnect on EOF
  (restarting Qud drops the socket).

## Rendering colour

- **Vertex-colour albedo needs `vertex_color_is_srgb = true`.** Godot defaults it to `false` and treats
  per-vertex colours as *linear*, so sRGB palette values (from `_qud_color`) render pale and desaturated —
  the wall reds came out muddy tan (#805840, sat 0.50) instead of brick (#993326, sat 0.75). Tiles that use
  an albedo *texture* are unaffected (textures carry an sRGB flag); only colour baked into vertices needs
  this. Diagnosed by *sampling the rendered pixel* and comparing saturation to the palette.

## Python gotchas (in the tooling)

- **`0` is falsy.** `(obj.get("layer") or 99)` silently excluded every layer-0 object — the most common
  layer in Qud data — and printed an empty result that read like a real finding.
- **Don't truncate the output you are searching.** Three separate `head`/`tail`/`[:30]` caps in this
  project cut off exactly the rows being looked for.

## Driving an unfocused Qud (SOLVED, build 2026-07-24k+)

The *how* matters. Qud parks its turn thread on `while (!GameManager.focused) Thread.Sleep(200)` when the
window backgrounds, and applies injected commands only through render/turn-tied hooks. Fix = two coupled
pieces: inject moves via `Keyboard.PushCommand` (wakes the turn thread from any thread, no render needed) +
a watchdog that holds `GameManager.focused = true` while a client is connected. `runInBackground` is a red
herring (it's the render loop, not the turn thread). Decompile the game to confirm engine behaviour before
theorising; see [`../tools.md`](../tools.md) "Remote control".

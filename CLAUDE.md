# Working notes for Claude (and future humans)

`README.md` explains the project and the data model. **This file is the local
environment**: the exact paths and commands, so no session has to rediscover
them after a compaction. If a path here is wrong, fix it here.

## Local paths (this machine)

| what | where |
|---|---|
| repo | `/Users/homefolder/personal-git/raves-of-qud` |
| Godot 4.7 binary | `/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot` |
| Qud install | `~/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app` |
| Qud managed DLLs | `<Qud>/Contents/Resources/Data/Managed` |
| Qud game data (XML) | `<Qud>/Contents/Resources/Data/StreamingAssets/Base` |
| mod deploy target | `~/Library/Application Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/` |
| exported tiles | `~/Library/Application Support/RavesOfQud/tiles` |
| inspector output | `~/Library/Application Support/RavesOfQud/selection.txt` (latest), `selections.log` (history) |
| Qud crash log | `~/Library/Logs/Freehold Games/CavesOfQud/Player.log` |
| bridge socket | `127.0.0.1:48710` |

## The commands that actually get used

```bash
# type-check the mod against the REAL Qud API (catches API drift before a restart)
dotnet build mod/RavesOfQudBridge.csproj

# deploy the mod  — REQUIRES A FULL QUD RESTART (mods compile at startup)
cp mod/*.cs mod/manifest.json ~/Library/Application\ Support/com.FreeholdGames.CavesOfQud/Mods/RavesOfQudBridge/

# validate the Godot scripts parse + _ready runs, without a window.
# "Raves bridge: connected" and no errors == clean. .gd changes need NO restart.
/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot --headless --path godot/ --quit-after 120

# read live state off the bridge (BLOCKS until the player takes a turn)
python3 tools/capture/snap.py summary
python3 tools/capture/snap.py cell 66 6
python3 tools/capture/snap.py water
python3 tools/capture/snap.py find glowfish

# inspect an exported tile's pixels / opaque band / transparency
python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp
python3 tools/capture/tile.py --list water
```

## The feedback loop

Claude **cannot see the Godot viewport**. Don't ask the user to describe what
they see in words — that round-trip has been the main source of wasted effort.

1. User points at a cell in Godot: **Ctrl/Cmd+click**, or hover and press **I**.
2. `CellInspector` writes `selection.txt`, copies to the clipboard, and shows a panel.
3. Claude reads `selection.txt` directly — no transcription.

The report pairs **WIRE** (what Qud sent) with **RENDERED** (what `ZoneRenderer`
actually did, and at what Y). Every rendering bug so far has lived in the gap
between those two, so always read both halves.

## Screenshots — F12 in the Godot window

Claude **cannot** capture the screen: macOS `screencapture` fails without Screen Recording
permission (`could not create image from display`). So both apps capture themselves.

**Ctrl/Cmd + right-click a tile in the Raves window** is the one to use: it inspects that tile
*and* photographs both apps. One gesture produces everything needed to discuss it —

| file | what |
|---|---|
| `RavesOfQud/selection.txt` | the report: blueprint, tile, colours, flags, and what the renderer DID |
| `RavesOfQud/shot.png` | the Raves viewport, with the 3D marker on the picked tile |
| `RavesOfQud/qud_shot.png` | Qud's own window, for side-by-side comparison |

The text report is hidden from the shot (the marker stays), so the picture shows the scene
rather than the panel.

**F12** does the screenshots alone, without inspecting:

| file | what |
|---|---|
| `~/Library/Application Support/RavesOfQud/shot.png` | the Godot viewport |
| `~/Library/Application Support/RavesOfQud/qud_shot.png` | Qud's own window |

Godot saves its viewport directly; it also sends a `shot` command so the mod calls
`UnityEngine.ScreenCapture.CaptureScreenshot` — marshalled to the main thread via `uiQueue`,
same rule as tile export. Qud's file appears at end-of-frame, so allow a moment.

Claude reads both with the Read tool. This replaces the user manually screenshotting and
pasting, which is how most of this project's visual debugging has worked so far.

## Tile reports — the user tells us what can't be derived

Some things are simply not in Qud's data. A water wheel faces north–south, but its tile is
`sw_waterwheel_1` — no `_ns` suffix, no blueprint flag, nothing to infer from. Guessing at these
is how this project has burned the most time.

**Inspect a tile, then use the form in the lower right.** Pick a verdict (wall / oriented panel
N–S / billboard / flat / deck / not drawn / wrong colour / wrong height / duplicated / other),
add notes, submit. It writes one markdown file per tile+verdict to:

```
~/Library/Application Support/RavesOfQud/reports/
```

Each file carries the verdict, the notes, and **the full inspector report at time of filing** —
so the evidence travels with the complaint. Read the whole directory to see what's outstanding.

⚠️ **Shape and fill reports are STANDING RULES, not tickets.** `ZoneRenderer._load_overrides()`
re-reads this directory every frame, so a `panel E–W` or `fill the holes` verdict applies *only
while its file exists*. **Never delete one to mark it "resolved"** — deleting reverts the render.
Files that say `> STANDING RULE` at the top are config; leave them. Only informational notes
(colour, position, "looks wrong") are one-off tickets safe to remove once addressed.

## Debugging rules, learned expensively

- **A cell is not just its objects.** Qud paints a ground layer (dirt, grass) onto cells with
  no `GameObject` at all — 1103 of 2000 in a Joppa zone. `Cell.Render()` composites it. Missing
  this cost six wrong hypotheses and four shipped-but-inert fixes.
- **Measure before hypothesising.** When a search keeps coming up empty, verify the dataset is
  complete instead of refining the search. Emitting `nHeld`/`nRendered`/`nSent` per cell proved
  in one turn that nothing was being dropped, which eliminated the entire object path — after
  six rounds of guessing had not.
- **Know which build is running.** Mod `.cs` only compiles at Qud startup. `Protocol.Build`
  ships in every snapshot and the inspector prints it. Several rounds here were spent reasoning
  over a build that did not contain the fix being tested.
- **Verify a fix did something.** `RenderTile` was deployed and reasoned about for several
  rounds before `fg=` being empty on every object revealed it had never once fired.
- **Prefer accessors to fields.** `Render.getTile()` / `getRenderString()` resolve what is
  actually drawn; the `Tile`/`RenderString` fields are static blueprint values, empty for
  anything runtime-chosen.
- **Verify a value, don't trust a field name.** `ColorUtility.CAMERA_BACKGROUND` sounds like the
  world's background colour. It is the alias `"camera background"` → `#40a4b9`, plain cyan.
  Trusting it turned the entire world turquoise.
- **Python: `0` is falsy.** `(obj.get("layer") or 99)` silently excluded every layer-0 object —
  the most common layer in Qud data — and printed an empty result that read like a real finding.
- **Don't truncate the output you are searching.** Three separate `head`/`tail`/`[:30]` caps in
  this project cut off exactly the rows being looked for.
- **Ask the user to click, don't infer from screenshots.** The inspector exists for this. Five
  hypotheses were formed from pixels; one selection would have beaten all of them.

## Ground rules learned the hard way

- **Reflect, don't grep.** String-grepping `Assembly-CSharp.dll` once "proved"
  `Render` fields were lowercase; they're capitalized. Use a
  `MetadataLoadContext` probe for exact signatures. See README's toolkit section.
- **Prefer Qud's own predicates** to inferring from tile names — `Cell.HasBridge()`,
  `HasWadingDepthLiquid()`, `GameObject.HasIntProperty("Bridge")`, `IsCreature`.
  Tile families are a *symptom* of game state, not the source of truth.
- **Never call Unity from the turn thread.** It crashes the game natively.
  Marshal through `GameManager.Instance.uiQueue`. Harmony patching is blocked on
  Apple Silicon (`mprotect EACCES`).
- **Tile paths mix separators** — creature tiles use `\`, most others `/`.
  Normalize both.
- A snapshot is only published **on a turn**. Capture scripts must block, and
  must reconnect on EOF (restarting Qud drops the socket).
- Commit and push after each round of work once it builds.

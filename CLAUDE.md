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

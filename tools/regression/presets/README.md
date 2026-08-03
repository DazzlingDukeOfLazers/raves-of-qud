# Option presets — the documented test fixtures

## Pick a fixture

| preset | scenario | changes Qud live? | Raves relaunch? | for |
|---|---|---|---|---|
| `baseline` | Raves defaults (compass, perceived) + full snapshot of every Qud option | yes (194 options) | to apply raves settings | reset Qud's option state before/after a test |
| `compass-fullinfo` | compass camera + **full-info** panels on | no (`qud` empty) | yes | panel/HUD parity shots with exact stats |
| `firstperson-perceived` | first-person camera + **perceived** info | no (`qud` empty) | yes | FP Holodeck + perceived-descriptor panels |

**Quickstart:** `presets.py list` → inspect the JSON → `presets.py load <name>` → relaunch Raves if the
preset changes `raves` settings → run the named scene. **Loading mutates your local game/viewer options** —
`presets.py save before-my-test` first if you want to restore your working set.

---

A **preset** is a whole options set saved as one file, so tests (and you) can jump
**deterministically** between known configurations instead of hand-toggling settings. Each captures:

- **`raves`** — Raves' own settings (`settings.json`: `camera`, `full_info`, `font_scale`,
  `fullscreen`, `bridge_host`, `bridge_port`). These change how Raves renders/looks.
- **`qud`** — Qud option values as `{ id: value }`. Empty `{}` means "leave Qud's options as they
  are" (the render fixtures below don't touch Qud); a full snapshot (like `baseline`) carries all
  ~194 so it can reset Qud's option state.

## Why these files exist (the list)

| preset | why it exists |
|---|---|
| `baseline` | Return-to-neutral. Raves defaults (compass cam, perceived info) + a full snapshot of every Qud option's current value. Load before/after a test to reset Qud's option state to a known point. |
| `compass-fullinfo` | Compass camera + **full-info** panels on (exact stats, the debug view). Deterministic setup for panel/HUD parity shots that need full info visible. |
| `firstperson-perceived` | First-person camera + **perceived** info (Qud's default player-facing view). Deterministic setup for FP Holodeck + perceived-descriptor panels. |

Add a preset when a test needs a **specific, repeatable** starting configuration. Give it a clear
`description` (it shows up in `presets.py list`) — that description IS the "why".

## How they're used

These are the **committed** fixtures. The app and the tool read/write the *working* copies in
`~/Library/Application Support/RavesOfQud/option_presets/`; `sync` copies these into that dir.

```bash
# tooling (deterministic, scriptable — this is what highvisor tests call)
python3 tools/capture/presets.py list
python3 tools/capture/presets.py sync                       # committed fixtures -> support dir
python3 tools/capture/presets.py load compass-fullinfo      # apply it (raves -> settings.json, qud -> bridge)
python3 tools/capture/presets.py save my-case --repo --desc "why"   # snapshot current state to a new fixture
```

- `load` writes the `raves` settings into `settings.json` (Raves picks them up on its **next launch** —
  exactly what a highvisor test does: `presets.py load X` then `hv launch raves`) and applies the `qud`
  options over the bridge (Qud must be in-game). The Options screen's in-app **Load** button applies a
  preset live instead.

## In a highvisor regression scene

There are two ways to make a scene deterministic, and which one you need depends on **what the preset
changes** — because the two halves of a preset apply differently:

- **`qud` options apply LIVE** over the bridge (no relaunch). A scene can load such a preset right
  before it captures, via a `shell` step (runs a command, then the scene continues). `shell` steps run
  with the config file's directory as the working dir, so `../capture/presets.py` resolves from
  `tools/regression/`:

  ```json
  "options-loud": {
    "window": "Raves of Qud",
    "reset": [
      { "shell": ["python3", "../capture/presets.py", "load", "some-qud-preset"] },
      { "click": [140, 952] }, { "wait": 0.6 }
    ],
    "steps": [ { "click": [907, 649] }, { "wait": 1.2 } ],
    "golden": "golden/options-loud.png"
  }
  ```

- **`raves` settings apply on the NEXT Raves LAUNCH** (they're written to `settings.json`; a running
  Raves doesn't re-read it). So a preset that changes camera / full_info / font_scale can't take effect
  from an in-scene `shell` step — relaunch Raves at the **script** level, then run the scene:

  ```bash
  python3 tools/capture/presets.py load compass-fullinfo   # writes settings.json (+ any qud over bridge)
  hv launch raves                                           # Raves boots WITH the preset's settings
  hv scene options --config tools/regression/scenes.json    # add --bless to (re)establish the golden
  ```

(The Options screen's in-app **Load** button sidesteps this — it applies `raves` settings live because
it can call into the running app directly.)

**As tests are added, bless their goldens** (`hv scene <name> --bless`) once the preset-driven capture
looks right.

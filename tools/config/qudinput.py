#!/usr/bin/env python3
"""Read Caves of Qud's own settings + keybinds and normalize them for Raves.

This is the Python side of the input SEAM (`godot/InputModel.gd` is the Godot side):
Raves wants to replicate Qud's settings menus and, eventually, its keybinds. Qud writes
both as plain JSON in its Unity persistent-data folder, so we can read them directly —
no game hook needed. This tool locates those files, parses them, and can export a
normalized bundle Raves can consume.

Two source files (Unity `Application.persistentDataPath`):
  Local/PlayerOptions.json    flat {Option*: "value"} — the settings-menu options.
  Synced/<user>.Keymap2.json  {CommandToSerializedInputBindings: {cmd: [parts...]}}.

IMPORTANT LIMITATION: the keymap file stores only the user's OVERRIDES. Unbound
commands fall through to Qud's DEFAULT keymap, which ships inside the game's data
(StreamingAssets, packed) and is NOT read here. So `keybinds` reflects what the player
changed, not the full default map. Getting the defaults is a separate, harder step
(unpacking game bundles); this tool deliberately parses only what's on disk as JSON.

stdlib only (matches the repo's zero-dep tools discipline).

Usage:
  python3 tools/config/qudinput.py locate
  python3 tools/config/qudinput.py options
  python3 tools/config/qudinput.py keybinds
  python3 tools/config/qudinput.py export [--out <path>]
  # override discovery on any command:
  python3 tools/config/qudinput.py options --config-dir "<Qud persistentDataPath>"
"""
import argparse
import glob
import json
import os
import sys

SCHEMA_VERSION = 1
COMPANY = "Freehold Games"
PRODUCT = "CavesOfQud"


def qud_config_dir() -> str:
    """Qud's Unity persistent-data folder, per OS. Override with --config-dir.

    Windows: %USERPROFILE%\\AppData\\LocalLow\\<company>\\<product>
    macOS:   ~/Library/Application Support/<company>/<product>
    Linux:   ~/.config/unity3d/<company>/<product>
    """
    home = os.path.expanduser("~")
    if sys.platform.startswith("win"):
        return os.path.join(home, "AppData", "LocalLow", COMPANY, PRODUCT)
    if sys.platform == "darwin":
        return os.path.join(home, "Library", "Application Support", COMPANY, PRODUCT)
    return os.path.join(home, ".config", "unity3d", COMPANY, PRODUCT)


def _raves_support_dir() -> str:
    """The RavesOfQud data dir — same folder as overrides.json, on both OSes.

    Mirrors the mod's SpecialFolder.UserProfile + /Library/Application Support/RavesOfQud
    (yes, "Library/Application Support" on Windows too — that's what the mod writes).
    """
    home = os.path.expanduser("~")
    return os.path.join(home, "Library", "Application Support", "RavesOfQud")


def _read_json(path: str):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_files(config_dir: str) -> dict:
    """Locate the option + keymap files under a config dir. Missing ones -> ''."""
    options = os.path.join(config_dir, "Local", "PlayerOptions.json")
    keymaps = sorted(glob.glob(os.path.join(config_dir, "Synced", "*.Keymap2.json")))
    return {
        "config_dir": config_dir,
        "options": options if os.path.isfile(options) else "",
        # a save is per-character-name-prefixed; take the first if several
        "keymap": keymaps[0] if keymaps else "",
        "keymaps_all": keymaps,
    }


def parse_options(path: str) -> dict:
    """PlayerOptions.json is a flat {key: str}. Return it as-is (sorted)."""
    if not path:
        return {}
    data = _read_json(path)
    if not isinstance(data, dict):
        return {}
    return {k: data[k] for k in sorted(data)}


def _parse_binding_part(part: str) -> dict:
    """One serialized Unity InputSystem token.

    A control path looks like "<Keyboard>/numpad0" -> {device:Keyboard, control:numpad0}.
    Non-path tokens ("Composite", "OneModifier", "GamepadAlt", ...) are modifier/compositor
    hints; we keep them verbatim rather than guess their exact grouping semantics.
    """
    if part.startswith("<") and ">" in part:
        device = part[1:part.index(">")]
        control = part[part.index(">") + 1:].lstrip("/")
        return {"kind": "control", "device": device, "control": control, "raw": part}
    return {"kind": "modifier", "raw": part}


def parse_keybinds(path: str) -> dict:
    """command -> {controls:[...], modifiers:[...], raw:[...]} from the override map.

    The serialized list interleaves control paths and modifier tokens (composite
    bindings). We split them into controls vs modifiers; the flat `raw` list preserves
    the original order for anyone who needs the exact composite structure later.
    """
    if not path:
        return {}
    data = _read_json(path)
    if not isinstance(data, dict):
        return {}
    raw_map = data.get("CommandToSerializedInputBindings") or {}
    out = {}
    for cmd in sorted(raw_map):
        parts = raw_map[cmd] or []
        parsed = [_parse_binding_part(str(p)) for p in parts]
        out[cmd] = {
            "controls": [p for p in parsed if p["kind"] == "control"],
            "modifiers": [p["raw"] for p in parsed if p["kind"] == "modifier"],
            "raw": list(parts),
        }
    return out


def build_bundle(config_dir: str) -> dict:
    found = find_files(config_dir)
    return {
        "version": SCHEMA_VERSION,
        "source": {
            "config_dir": found["config_dir"],
            "options_file": found["options"],
            "keymap_file": found["keymap"],
        },
        "options": parse_options(found["options"]),
        "keybinds": parse_keybinds(found["keymap"]),
        "note": "keybinds are user OVERRIDES only; Qud defaults live in packed game data.",
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Parse Caves of Qud settings + keybinds.")
    ap.add_argument("cmd", choices=["locate", "options", "keybinds", "export"])
    ap.add_argument("--config-dir", default="", help="override Qud's persistent-data folder")
    ap.add_argument("--out", default="", help="export target (default: <RavesOfQud>/qud_input.json)")
    args = ap.parse_args(argv)

    config_dir = args.config_dir or qud_config_dir()

    if args.cmd == "locate":
        found = find_files(config_dir)
        if not os.path.isdir(config_dir):
            print("config dir NOT FOUND: %s" % config_dir)
            return 1
        print("config dir : %s" % found["config_dir"])
        print("options    : %s" % (found["options"] or "(missing)"))
        print("keymap     : %s" % (found["keymap"] or "(missing)"))
        if len(found["keymaps_all"]) > 1:
            print("  (%d keymaps found; using the first)" % len(found["keymaps_all"]))
        return 0

    if args.cmd == "options":
        opts = parse_options(find_files(config_dir)["options"])
        print(json.dumps(opts, indent=2))
        return 0

    if args.cmd == "keybinds":
        kb = parse_keybinds(find_files(config_dir)["keymap"])
        print(json.dumps(kb, indent=2))
        return 0

    if args.cmd == "export":
        bundle = build_bundle(config_dir)
        out = args.out or os.path.join(_raves_support_dir(), "qud_input.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            f.write(json.dumps(bundle, indent=2) + "\n")
        print("wrote %s (%d options, %d rebound commands)"
              % (out, len(bundle["options"]), len(bundle["keybinds"])))
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())

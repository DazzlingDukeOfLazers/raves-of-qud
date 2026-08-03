#!/usr/bin/env python3
"""Option PRESETS — save/load a whole options set as one named file, so tests (and you) can jump
deterministically between known configurations.

A preset is a full snapshot of two things:
  • raves — Raves' own settings (settings.json: camera, full_info, font_scale, fullscreen, bridge…)
  • qud   — every Qud option's current value (id -> value), mirrored from options.json

Files live in two places, mirroring the project's overrides.seed.json pattern:
  • <support>/option_presets/*.json   — the working set the app (and this tool) read/write
  • tools/regression/presets/*.json    — the COMMITTED, documented fixtures (see that dir's README);
                                         `presets.py sync` copies them into the support dir.

Loading applies:
  • raves settings by merging into settings.json (Raves picks them up on its next launch — which is
    exactly what a highvisor test does: `presets.py load X` then `hv launch raves`). The Options
    screen's in-app Load button applies them live instead.
  • qud options over the bridge (Qud must be in-game): one `setoption defer=1` per option, then a
    single `export`, so it's one re-export, not one per option. Restart-required options store their
    value but only show after a Qud restart.

Examples:
    python3 tools/capture/presets.py list
    python3 tools/capture/presets.py save compass-fullinfo --desc "Compass cam + full-info panels"
    python3 tools/capture/presets.py save baseline --repo         # also write the committed fixture
    python3 tools/capture/presets.py load firstperson-perceived   # jump to that config (deterministic)
    python3 tools/capture/presets.py sync                          # committed fixtures -> support dir
"""
import argparse
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat
import control  # reuse the bridge client (127.0.0.1:48710, framed JSON)

# Mirror Settings.gd DEFAULTS so a preset captures the full raves set even before Raves has written
# settings.json (it runs on in-code defaults until the user changes something). Keep in sync with Settings.gd.
RAVES_DEFAULTS = {
    "font_scale": 1.0,
    "fullscreen": False,
    "full_info": False,
    "camera": 0,
    "mode": "user",         # "user" | "1to1" (parity mode overrides camera + panels)
    "bridge_host": "127.0.0.1",
    "bridge_port": 48710,
}

SUPPORT = plat.support_dir()
PRESET_DIR = os.path.join(SUPPORT, "option_presets")        # working set (app + tool)
REPO_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "regression", "presets"))
SETTINGS = os.path.join(SUPPORT, "settings.json")
OPTIONS = os.path.join(SUPPORT, "options.json")


def _read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _preset_path(name, repo=False):
    d = REPO_DIR if repo else PRESET_DIR
    return os.path.join(d, name + ".json")


def _find_preset(name):
    """Working set first, then the committed fixtures (so repo presets load without a `sync`)."""
    for path in (_preset_path(name), _preset_path(name, repo=True)):
        if os.path.exists(path):
            return path
    return None


def _qud_values():
    """id -> current value for every mirrored Qud option (from options.json)."""
    data = _read_json(OPTIONS, {})
    out = {}
    for cat in data.get("categories", []):
        for o in cat.get("options", []):
            if o.get("id"):
                out[o["id"]] = o.get("value")
    return out


def _restart_ids():
    data = _read_json(OPTIONS, {})
    return {o["id"] for cat in data.get("categories", []) for o in cat.get("options", [])
            if o.get("id") and o.get("restart")}


def cmd_save(name, desc, repo):
    raves = dict(RAVES_DEFAULTS)
    raves.update(_read_json(SETTINGS, {}))   # captured file wins over defaults; defaults fill the gaps
    qud = _qud_values()
    preset = {
        "name": name,
        "description": desc or "",
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "raves": raves,
        "qud": qud,
    }
    targets = [_preset_path(name)]
    if repo:
        targets.append(_preset_path(name, repo=True))
    for path in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(preset, f, indent=2)
        os.replace(tmp, path)
        print("saved %s  (%d raves keys, %d qud options)%s"
              % (path, len(raves), len(qud), "  [committed fixture]" if path == targets[-1] and repo else ""))
    if not desc:
        print("  tip: pass --desc \"why this preset exists\" so the list explains itself")


def cmd_load(name):
    path = _find_preset(name)
    if not path:
        sys.exit("no preset '%s' (looked in %s and %s) — try `presets.py list`" % (name, PRESET_DIR, REPO_DIR))
    preset = _read_json(path, {})
    raves = preset.get("raves", {})
    qud = preset.get("qud", {})
    print("loading %s — %s" % (name, preset.get("description", "") or "(no description)"))

    # 1) Raves settings: merge into settings.json (effective on Raves' next launch; the app's Load
    #    button applies them live instead).
    if raves:
        cur = _read_json(SETTINGS, {})
        cur.update(raves)
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
        tmp = SETTINGS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cur, f, indent=2)
        os.replace(tmp, SETTINGS)
        print("  raves: wrote %d settings -> settings.json (live on next Raves launch)" % len(raves))

    # 2) Qud options over the bridge: defer the re-export, then fire one `export`.
    if qud:
        try:
            b = control.Bridge()
        except OSError:
            print("  qud: SKIPPED — Qud isn't in-game (bridge %d closed). Launch a save first." % control.PORT)
            return
        restart = _restart_ids()
        n_restart = 0
        for oid, val in qud.items():
            b.send("setoption", id=oid, value="" if val is None else str(val), defer="1")
            if oid in restart:
                n_restart += 1
        b.send("export")
        # hold the socket briefly so FocusKeeper keeps Qud rendering and the main thread drains it
        b.sock.settimeout(0.3)
        deadline = time.time() + 1.2
        while time.time() < deadline:
            try:
                if not b.sock.recv(65536):
                    break
            except OSError:
                pass
        b.close()
        msg = "  qud: applied %d options (one re-export)" % len(qud)
        if n_restart:
            msg += "; %d need a Qud restart to take visual effect" % n_restart
        print(msg)


def cmd_list():
    seen = set()
    rows = []
    for label, d in (("working", PRESET_DIR), ("committed", REPO_DIR)):
        for path in sorted(glob.glob(os.path.join(d, "*.json"))):
            nm = os.path.splitext(os.path.basename(path))[0]
            key = nm
            tag = label if key not in seen else label + ", dup"
            seen.add(key)
            p = _read_json(path, {})
            rows.append((nm, p.get("description", ""), tag, len(p.get("qud", {}))))
    if not rows:
        print("no presets yet. Create one:  presets.py save <name> --desc \"…\" --repo")
        return
    w = max(len(r[0]) for r in rows)
    for nm, desc, tag, nq in rows:
        print("  %-*s  %-9s  %3d opts   %s" % (w, nm, tag, nq, desc or "(no description)"))


def cmd_sync():
    os.makedirs(PRESET_DIR, exist_ok=True)
    n = 0
    for path in sorted(glob.glob(os.path.join(REPO_DIR, "*.json"))):
        dst = os.path.join(PRESET_DIR, os.path.basename(path))
        with open(path) as s, open(dst, "w") as d:
            d.write(s.read())
        n += 1
    print("synced %d committed preset(s) -> %s" % (n, PRESET_DIR))


def main(argv):
    p = argparse.ArgumentParser(prog="presets.py", description="save/load Raves+Qud option presets")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list available presets (working set + committed fixtures)")
    s = sub.add_parser("save", help="snapshot the current options set to a named preset")
    s.add_argument("name")
    s.add_argument("--desc", default="", help="why this preset exists (shown by `list`)")
    s.add_argument("--repo", action="store_true", help="also write the committed fixture in tools/regression/presets")
    l = sub.add_parser("load", help="apply a preset (deterministic jump)")
    l.add_argument("name")
    sub.add_parser("sync", help="copy committed fixtures into the support dir")
    a = p.parse_args(argv)
    if a.cmd == "list":
        cmd_list()
    elif a.cmd == "save":
        cmd_save(a.name, a.desc, a.repo)
    elif a.cmd == "load":
        cmd_load(a.name)
    elif a.cmd == "sync":
        cmd_sync()


if __name__ == "__main__":
    main(sys.argv[1:])

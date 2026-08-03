#!/usr/bin/env python3
"""Qud save-file management: list saves FROM DISK (no game launch), archive goldens,
restore them byte-identical. The startup-stability primitive (phase 2, workstream A/B).

Qud keeps each save in <QudData>/Synced/Saves/<GUID>/ with Primary.json carrying the
picker metadata AT SAVE TIME (Name, Location, GameMode, SaveTime) — so the save list,
and the Load Game picker's ROW ORDER (SaveTime descending), are knowable without ever
loading into the game. Only an actual game-load needs the game.

Commands:
  list                    — every save: row order, name, guid, location, mode, saved-at
  golden <name>           — archive the named save as a golden (rsync copy)
  restore <name>          — copy the golden back over the live save (QUD MUST BE DOWN)
  goldens                 — list archived goldens
  row <name>              — the picker row index (0-based) the named save occupies NOW

Goldens live OUTSIDE the repo (binary, per-platform — see docs/phase2-test-plan.md):
  ~/Library/Application Support/RavesOfQud/goldens/<name>/
The committed index is fixtures/goldens.json (name -> description).
"""
import json
import os
import shutil
import subprocess
import sys

QUD_DATA = os.path.expanduser("~/Library/Application Support/com.FreeholdGames.CavesOfQud")
SAVES = os.path.join(QUD_DATA, "Synced", "Saves")
GOLDENS = os.path.expanduser("~/Library/Application Support/RavesOfQud/goldens")


def qud_running():
    """True if any Caves of Qud process is alive (restores must not race a live game)."""
    r = subprocess.run(["pgrep", "-f", "CoQ"], capture_output=True)
    return r.returncode == 0


def list_saves():
    """[{guid, name, location, mode, saved, mtime}] sorted like the picker (SaveTime desc,
    by dir mtime — Primary.json's SaveTime string is display-formatted, mtime is reliable)."""
    out = []
    if not os.path.isdir(SAVES):
        return out
    for guid in os.listdir(SAVES):
        pj = os.path.join(SAVES, guid, "Primary.json")
        if not os.path.isfile(pj):
            continue
        try:
            meta = json.load(open(pj))
        except Exception:
            meta = {}
        out.append({
            "guid": guid,
            "name": meta.get("Name", "?"),
            "location": meta.get("Location", "?"),
            "mode": meta.get("GameMode", "?"),
            "saved": meta.get("SaveTime", "?"),
            "mtime": os.path.getmtime(pj),
        })
    out.sort(key=lambda s: -s["mtime"])
    return out


def find_save(name):
    for s in list_saves():
        if s["name"] == name:
            return s
    return None


def cmd_list():
    for i, s in enumerate(list_saves()):
        print(f"row {i}: {s['name']!r:26} {s['mode']:8} {s['location']:24} saved {s['saved']}  {s['guid']}")


def cmd_row(name):
    for i, s in enumerate(list_saves()):
        if s["name"] == name:
            print(i)
            return 0
    print(f"no save named {name!r}", file=sys.stderr)
    return 1


def cmd_golden(name):
    s = find_save(name)
    if not s:
        sys.exit(f"no save named {name!r} — `saves.py list` to see them")
    dst = os.path.join(GOLDENS, name)
    os.makedirs(GOLDENS, exist_ok=True)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    src = os.path.join(SAVES, s["guid"])
    shutil.copytree(src, dst)
    # remember which guid the golden restores into
    json.dump({"guid": s["guid"], "name": name, "meta": {k: s[k] for k in ("location", "mode", "saved")}},
              open(os.path.join(dst, "GOLDEN.json"), "w"), indent=1)
    n = sum(len(f) for _, _, f in os.walk(dst))
    print(f"golden {name!r} archived from {s['guid']} ({n} files)")


def cmd_restore(name):
    src = os.path.join(GOLDENS, name)
    gj = os.path.join(src, "GOLDEN.json")
    if not os.path.isfile(gj):
        sys.exit(f"no golden named {name!r} — `saves.py goldens`")
    if qud_running():
        sys.exit("Caves of Qud is RUNNING — quit it first (a restore must not race a live game)")
    guid = json.load(open(gj))["guid"]
    dst = os.path.join(SAVES, guid)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    os.remove(os.path.join(dst, "GOLDEN.json"))
    # freshen mtime so the restored save sorts to the TOP row deterministically
    os.utime(os.path.join(dst, "Primary.json"), None)
    print(f"golden {name!r} restored into {guid} (top row on next launch)")


def cmd_goldens():
    if not os.path.isdir(GOLDENS):
        print("(none)")
        return
    for name in sorted(os.listdir(GOLDENS)):
        gj = os.path.join(GOLDENS, name, "GOLDEN.json")
        if os.path.isfile(gj):
            g = json.load(open(gj))
            m = g.get("meta", {})
            print(f"{name!r:28} -> {g['guid']}  {m.get('mode','?'):8} {m.get('location','?')}")


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    if cmd == "list":
        cmd_list()
    elif cmd == "row":
        sys.exit(cmd_row(argv[1]))
    elif cmd == "golden":
        cmd_golden(argv[1])
    elif cmd == "restore":
        cmd_restore(argv[1])
    elif cmd == "goldens":
        cmd_goldens()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

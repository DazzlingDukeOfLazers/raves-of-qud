#!/usr/bin/env python3
"""steam_cloud.py — toggle Steam Cloud saves for Caves of Qud (per-app), so the two dev
saves stay LOCAL per machine (Cloud off) while you keep Cloud for everything else — and
you can flip it back on to test.

HOW IT WORKS. The per-app toggle is `"cloudenabled" "0"` inside the app's block in Steam's
localconfig.vdf. Steam keeps config in memory and OVERWRITES that file on exit, so an edit
only takes effect after Steam RESTARTS. This tool therefore:
  * requires Steam to be QUIT before editing (or `--restart` to quit + relaunch it), and
  * backs up localconfig.vdf first.
A syntactically-valid edit is harmless even if ineffective (Steam ignores unknown keys), so
the worst case is "no change", never a corrupted config. Verify with `status` after Steam
comes back (and by re-checking the game's Properties > General cloud checkbox).

  steam_cloud.py status                 # current cloud state for Qud (reads localconfig.vdf)
  steam_cloud.py off  [--restart]       # disable cloud for Qud   (needs Steam quit to apply)
  steam_cloud.py on   [--restart]       # enable cloud for Qud

Quitting Steam also closes any Steam game (Qud). macOS only for now; the Windows path
(dd/pc) mirrors this against %LOCALAPPDATA%\\..\\Steam\\userdata\\...\\localconfig.vdf.
"""
import glob
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat

APPID = "333640"
STEAM_PROC = "steam_osx"   # macOS Steam client process


def _localconfig():
    if not plat.IS_MAC:
        sys.exit("steam_cloud.py: macOS only for now (Windows path is a dd/pc TODO).")
    base = os.path.expanduser("~/Library/Application Support/Steam/userdata")
    hits = glob.glob(os.path.join(base, "*", "config", "localconfig.vdf"))
    if not hits:
        sys.exit("localconfig.vdf not found under %s" % base)
    # newest account config if multiple
    return max(hits, key=os.path.getmtime)


def _find_app_block(lines):
    """Return (start_idx, open_brace_idx, end_idx, indent) of the app-settings block
    for APPID under Software/Valve/Steam/apps — the one that contains "LastPlayed"
    (disambiguates it from other "333640" occurrences elsewhere in the file)."""
    key = '"%s"' % APPID
    for i, ln in enumerate(lines):
        if ln.strip() != key:
            continue
        # next non-blank line must be an opening brace
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j >= len(lines) or lines[j].strip() != "{":
            continue
        # scan to the matching close brace, tracking depth
        depth, k = 1, j + 1
        body = []
        while k < len(lines) and depth > 0:
            s = lines[k].strip()
            depth += s.count("{") - s.count("}")
            if depth > 0:
                body.append(lines[k])
            k += 1
        if any('"LastPlayed"' in b for b in body):
            indent = lines[j + 1][:len(lines[j + 1]) - len(lines[j + 1].lstrip("\t"))] \
                if j + 1 < k else "\t"
            return i, j, k - 1, indent
    return None


def _cloudenabled_state(lines, block):
    """'off' if cloudenabled 0 present, 'on(0-absent-or-1)' otherwise, in the block."""
    _, ob, close, _ = block
    for idx in range(ob + 1, close):
        s = lines[idx].strip()
        if s.startswith('"cloudenabled"'):
            val = s.split('"cloudenabled"', 1)[1].strip().strip('"')
            return "off" if val == "0" else "on"
    return "on"   # absent == Cloud enabled (Steam default)


def status():
    path = _localconfig()
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    block = _find_app_block(lines)
    if not block:
        return {"config": path, "app_block": "NOT FOUND", "cloud": "unknown"}
    return {"config": path, "cloud": _cloudenabled_state(lines, block),
            "steam_running": _steam_running()}


def _steam_running():
    return bool(subprocess.run(["pgrep", "-x", STEAM_PROC], capture_output=True, text=True).stdout.strip())


def _quit_steam(wait=20):
    subprocess.run(["osascript", "-e", 'tell application "Steam" to quit'], capture_output=True)
    end = time.time() + wait
    while time.time() < end:
        if not _steam_running():
            return True
        time.sleep(1)
    # escalate
    for p in subprocess.run(["pgrep", "-x", STEAM_PROC], capture_output=True, text=True).stdout.split():
        try: os.kill(int(p), 15)
        except OSError: pass
    time.sleep(3)
    return not _steam_running()


def _launch_steam():
    subprocess.run(["open", "-a", "Steam"], capture_output=True)


def set_cloud(enable, restart=False):
    path = _localconfig()
    if _steam_running():
        if not restart:
            return ("Steam is running — the edit won't apply until Steam restarts.\n"
                    "  Quit Steam (this also closes Qud) and re-run, or pass --restart to do it for you.")
        if not _quit_steam():
            return "FAILED to quit Steam"

    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = raw.split("\n")
    block = _find_app_block(lines)
    if not block:
        return "FAILED: could not locate the %s app block in %s" % (APPID, path)
    _, ob, close, indent = block

    # remove any existing cloudenabled line in the block. Removals happen only at
    # indices > ob, so `ob` stays valid in `new` (nothing before it changes).
    new = [ln for i, ln in enumerate(lines)
           if not (ob < i < close and ln.strip().startswith('"cloudenabled"'))]
    if not enable:
        new.insert(ob + 1, '%s"cloudenabled"\t\t"0"' % indent)   # right after the opening brace

    backup = path + ".raves.bak"
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(new))
    msg = "cloud %s for Qud (backup: %s)" % ("ENABLED" if enable else "DISABLED", backup)

    if restart:
        _launch_steam()
        msg += " — relaunched Steam (give it ~15s, then `status` to confirm)"
    else:
        msg += " — restart Steam to apply, then `status` to confirm"
    return msg


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    restart = "--restart" in argv
    if cmd == "status":
        import json; print(json.dumps(status(), indent=0))
    elif cmd == "off":
        print(set_cloud(False, restart))
    elif cmd == "on":
        print(set_cloud(True, restart))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

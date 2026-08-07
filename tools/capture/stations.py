#!/usr/bin/env python3
"""Rung 6c — warp stations (docs/pc-zone-plan.md).

Drive the rig to a list of named zones and run the structural census (6a) at
each. The station index lives in `fixtures/checker_stations.json`.

    stations.py list                 # the index
    stations.py run                  # every station
    stations.py run joppa hut        # named stations only

TWO RULES, both learned by breaking the rig:

1. **Warps are paced by CONFIRMATION, never by a timer.** `goto:` triggers
   procedural zone generation, which can take far longer than any sleep you
   guess. Firing six warps on fixed 3.5s sleeps deadlocked Qud outright — a
   frozen frame with no UI, unrecoverable over the bridge, needing a process
   kill and a menu-driven reload. `warp()` polls for the zone id to actually
   change and gives generation a long ceiling.

2. **Warping mutates the golden save.** Qud autosaves on zone change, so the
   save the whole rig's determinism rests on ends up wherever you warped last.
   Restore it afterwards: `saves.py restore checker` with Qud down — and Qud's
   process is **CoQ.exe**, not CavesOfQud.exe (the window title lies), so a
   taskkill on the window name silently kills nothing and the restore refuses.

The wish field is `wish`, not `text` — `b.send("wish", wish=...)`. Sending
`text=` silently no-ops (it is how godmode was never actually applied).
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import census as census_mod
import control
import plat

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INDEX = os.path.join(REPO, "fixtures", "checker_stations.json")
REPORTS = os.path.join(REPO, "reports", "checker")


def load_index():
    with open(INDEX, encoding="utf-8") as f:
        return json.load(f)


def _snap(b, timeout=45):
    b.send("wait")
    return b.read_snapshot(timeout=timeout)


def warp(b, zone_id, settle=90.0):
    """goto: the zone, then WAIT FOR THE ZONE ID TO CHANGE. Returns the fresh
    bridge (the connection often drops while a zone generates) or raises."""
    try:
        cur = _snap(b).get("zone", {}).get("id", "")
    except Exception:
        cur = ""
    if cur == zone_id:
        return b
    b.send("wish", wish="goto:" + zone_id)
    deadline = time.time() + settle
    while time.time() < deadline:
        time.sleep(3.0)
        try:
            for _ in range(2):
                b.send("popup", action="cancel")
                time.sleep(0.4)
            got = _snap(b).get("zone", {}).get("id", "")
            if got == zone_id:
                return b
        except (OSError, ConnectionError):
            try:
                b.close()
            except OSError:
                pass
            time.sleep(2.0)
            try:
                b = control.Bridge()
            except OSError:
                continue
        except Exception:
            continue          # snapshot timeout: generation still running
    raise RuntimeError("warp to %s never confirmed in %.0fs (zone generation "
                       "wedged? — a process kill + menu reload recovers)" % (zone_id, settle))


def run_station(b, st):
    b = warp(b, st["zone"])
    # REVEAL before censusing: a zone you just warped into is almost entirely
    # unexplored (the underground station measured 8 of 2000 cells on its first
    # run), and the client correctly draws nothing for unexplored cells — so
    # there is nothing to verify. Revealing also creates the
    # explored-but-not-visible cells that exercise the memory-ghost path.
    b.send("reveal")
    time.sleep(1.2)
    snap = _snap(b)
    cen = census_mod.fetch_census()
    rows = census_mod.audit(snap, cen)
    tally = {}
    for r in rows:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    bad = [r for r in rows if r["verdict"] in ("DROPPED", "PHANTOM")]
    return b, {"station": st["name"], "zone": st["zone"], "exercises": st.get("exercises", ""),
               "tally": tally, "bad": bad[:40], "cells": len(rows)}


def main(argv):
    idx = load_index()
    if not argv or argv[0] == "list":
        for st in idx["stations"]:
            print("%-14s %-30s %s" % (st["name"], st["zone"], st.get("exercises", "")))
        return 0
    wanted = [a for a in argv[1:] if not a.startswith("--")]
    sts = [s for s in idx["stations"] if not wanted or s["name"] in wanted]
    b = control.Bridge()
    results = []
    for st in sts:
        print("=== %s (%s)" % (st["name"], st["zone"]), flush=True)
        try:
            b, res = run_station(b, st)
        except Exception as e:
            print("   FAILED: %s" % e, flush=True)
            results.append({"station": st["name"], "zone": st["zone"], "error": str(e)})
            try:
                b.close()
            except OSError:
                pass
            time.sleep(2)
            try:
                b = control.Bridge()
            except OSError:
                break
            continue
        t = res["tally"]
        print("   %d cells: %s" % (res["cells"],
              " / ".join("%d %s" % (t[k], k) for k in sorted(t))), flush=True)
        for r in res["bad"][:8]:
            names = ", ".join(str(o["name"]) for o in r["objs"]) or "(none)"
            print("     %-8s (%2d,%2d) %s" % (r["verdict"], r["x"], r["y"], names[:60]), flush=True)
        results.append(res)
    try:
        b.close()
    except OSError:
        pass
    os.makedirs(REPORTS, exist_ok=True)
    out = os.path.join(REPORTS, "stations.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=1)
    print("report:", out)
    print("\nNOTE: warping autosaved over the golden save. Restore it with Qud "
          "down:  python tools/capture/saves.py restore checker")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

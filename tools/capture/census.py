#!/usr/bin/env python3
"""Rung 6a — the structural zone census (docs/pc-zone-plan.md).

The Object Checker certifies elements IN ISOLATION. This asks a different
question about a whole zone, with no pixels involved:

    did the client draw everything the zone actually sent it?

Two sources, diffed:
  * the WIRE snapshot's cell list — every object Qud published, per cell.
  * census.json — the renderer's own per-cell placement verdicts
    (ZoneRenderer.placement_census(), the same data CellInspector shows for a
    single cell), fetched over the godot command channel.

Because it needs no geometry calibration, no window focus and no capture
phase, it is immune to every rig failure mode that plagued the pixel
certification — and it runs in seconds.

VERDICTS per cell
  ok        the winning object got a real placement
  DROPPED   the wire sent a drawable object, the client placed nothing
  skipped   placed as a deliberate skip (no tile AND no glyph — Qud draws
            nothing either; the documented rule, not a defect)
  empty     nothing on the wire, nothing placed (the common case)

USAGE
  census.py                 # the live zone
  census.py --json out.json # also write the full per-cell detail
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control
import plat

BASE = plat.support_dir()
CENSUS = os.path.join(BASE, "census.json")


def fetch_census(wait=8.0):
    """Ask the viewer to dump its placement map; block until the file lands."""
    before = os.path.getmtime(CENSUS) if os.path.exists(CENSUS) else 0
    control.godot("census")
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(CENSUS) and os.path.getmtime(CENSUS) > before:
            time.sleep(0.15)          # let the write settle
            with open(CENSUS, encoding="utf-8") as f:
                return json.load(f)
        time.sleep(0.1)
    raise RuntimeError("census.json never updated — is the viewer running the "
                       "current client build?")


def drawable(obj):
    """Qud draws it if it has art: a tile, or a glyph. Mirrors the mod's own
    export filter (ZoneSnapshot drops objects with neither)."""
    return bool(obj.get("tile")) or bool(obj.get("glyph"))


def eligible(cell, objs):
    """The objects Qud would actually DRAW in this cell, mirroring the client's
    1:1 contract exactly (ZoneRenderer._rebuild_dynamics):

      * an UNEXPLORED cell draws nothing at all — the field colour shows;
      * a visible+lit cell draws every object (highest RenderLayer wins);
      * otherwise only the RenderIfDark objects draw, as the memory ghost.

    Getting this wrong is the difference between a census that reports 1267
    defects and one that reports the truth: the first run flagged every
    unexplored cell in a pristine Joppa as DROPPED."""
    if not cell.get("explored", True):
        return []
    full = cell.get("visible", True) is not False and int(cell.get("light", 200)) > 1
    return objs if full else [o for o in objs if not o.get("hideDark")]


def audit(snap, census):
    """Per-cell verdicts. The 1:1 rule is ONE winner per cell (highest
    RenderLayer, first of ties), so a cell needs exactly one real placement —
    not one per object."""
    placed = census.get("cells", {})
    rows = []
    for cell in snap.get("cells", []):
        cx, cy = int(cell.get("x", -1)), int(cell.get("y", -1))
        objs = [o for o in cell.get("objs", []) if drawable(o)]
        want = eligible(cell, objs)
        notes = placed.get("%d,%d" % (cx, cy), [])
        real = [n for n in notes if not str(n.get("kind", "")).startswith("skipped")]
        skips = [n for n in notes if str(n.get("kind", "")).startswith("skipped")]
        if not cell.get("explored", True):
            verdict = "unexplored" if not real else "PHANTOM"
        elif not want:
            verdict = "empty" if not real else "PHANTOM"
        elif real:
            verdict = "ok"
        elif skips:
            verdict = "skipped"
        else:
            verdict = "DROPPED"
        rows.append({
            "x": cx, "y": cy, "verdict": verdict,
            "objs": [{"name": o.get("name"), "tile": o.get("tile"),
                      "glyph": o.get("glyph"), "layer": o.get("layer")} for o in objs],
            "notes": notes,
        })
    return rows


def main(argv):
    b = control.Bridge()
    b.send("wait")
    snap = b.read_snapshot(timeout=20)
    b.close()
    census = fetch_census()
    zone = snap.get("zone", {}).get("id", "?")
    if census.get("zone") and census["zone"] != zone:
        print("WARNING: census zone %r != wire zone %r (stale dump?)"
              % (census.get("zone"), zone))
    rows = audit(snap, census)
    tally = {}
    for r in rows:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    print("zone: %s   cells: %d" % (zone, len(rows)))
    print("  " + " / ".join("%d %s" % (tally[k], k) for k in sorted(tally)))
    bad = [r for r in rows if r["verdict"] in ("DROPPED", "PHANTOM")]
    for r in bad[:25]:
        names = ", ".join(str(o["name"]) for o in r["objs"]) or "(none)"
        print("  %-8s (%2d,%2d) %s" % (r["verdict"], r["x"], r["y"], names[:70]))
    if len(bad) > 25:
        print("  ... and %d more" % (len(bad) - 25))
    if "--json" in argv:
        out = argv[argv.index("--json") + 1]
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"zone": zone, "tally": tally, "cells": rows}, f, indent=1)
        print("detail:", out)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Rung 6b — masked whole-playfield congruence (docs/pc-zone-plan.md).

The Object Checker scores ONE cell: the stage. This scores every cell on
screen, turning a same-turn capture pair into a per-cell verdict grid.

WHY PER CELL, NOT A WHOLE-SCREEN MEAN
    A single divergent sprite is ~1/1650th of the playfield. Averaged over the
    whole screen it vanishes into the noise floor. So each cell is scored
    independently with the CERTIFIED thresholds and the report is a
    FAILING-CELL COUNT — the same units the object checker earned its
    confidence in.

THE GRID
    Calibration locates the stage cell, which is always zone cell (40,12).
    Every other cell follows by stride: rect(cx,cy) = stage + (cx-40, cy-12)
    scaled by the cell size. The two apps have different cell sizes and
    origins (Qud 26x38, Raves 37x56 at the sweep zoom) — the scorer resamples
    both to a common grid, so that is fine. Only cells fully inside BOTH
    images are addressable: the Qud view is player-centred and clips the zone's
    left edge, so ~1650 of 2000 cells score.

MASKING (what is deliberately not scored)
    * CREATURES — they move between the two captures. Their layer is already
      certified in isolation; scoring them here would measure capture latency.
    * ANIMATED elements — phase, not divergence. Same argument as the ANIM
      band; the fixtures already cover them.
    A masked cell is reported, never silently dropped.

    playfield.py                 # score the live zone
    playfield.py --json out.json # + per-cell detail
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import congruence
import control
import checker

STAGE_CX, STAGE_CY = 40, 12          # the checker's stage cell, the grid anchor


def cell_rect(base, cx, cy):
    """The pixel rect of zone cell (cx,cy) given the calibrated stage rect.

    STRIDE IS FRACTIONAL. Calibration measures one cell's bbox as integers, but
    the true grid pitch is not an integer at an arbitrary zoom — and the error
    compounds with distance from the anchor. With integer stride the failures
    were perfectly monotonic in |cx-40|: 0 FAIL at 28 cells out, 19 at 36 cells
    out, every one of them bare painted ground. `sx`/`sy` (fitted by --fit)
    override the integer w/h for POSITION only; the crop keeps the cell size."""
    sx = base.get("sx", base["w"])
    sy = base.get("sy", base["h"])
    return {"x": int(round(base["x"] + (cx - STAGE_CX) * sx)),
            "y": int(round(base["y"] + (cy - STAGE_CY) * sy)),
            "w": base["w"], "h": base["h"]}


def _coarse_diff(qget, rget, qr, rr, n=6):
    """Cheap mean |Δ| between two cell rects on an n×n subsample."""
    tot = 0
    for j in range(n):
        for i in range(n):
            qp = qget(qr["x"] + (i + 0.5) * qr["w"] / n, qr["y"] + (j + 0.5) * qr["h"] / n)
            rp = rget(rr["x"] + (i + 0.5) * rr["w"] / n, rr["y"] + (j + 0.5) * rr["h"] / n)
            tot += abs(qp[0] - rp[0]) + abs(qp[1] - rp[1]) + abs(qp[2] - rp[2])
    return tot / (3.0 * n * n)


def fit_stride(pair, geom, snap):
    """Fit Qud's fractional cell pitch by minimising cross-app difference over
    cells spread far from the anchor. Raves is held fixed: its 1:1 grid is
    generated programmatically, while Qud's comes from a zoom quantisation."""
    qw, qh, qget = congruence.load_rgb(pair["qud"])
    rw, rh, rget = congruence.load_rgb(pair["raves"])
    cells = [(int(c["x"]), int(c["y"])) for c in snap.get("cells", [])]
    best = {}
    for axis, key, base_v in (("x", "sx", geom["qud"]["w"]), ("y", "sy", geom["qud"]["h"])):
        # sample cells FAR from the anchor on this axis — that is where pitch
        # error shows; near the anchor every candidate scores the same
        far = [c for c in cells if abs(c[0] - STAGE_CX) > 20] if axis == "x" \
            else [c for c in cells if abs(c[1] - STAGE_CY) > 6]
        far = far[::max(1, len(far) // 60)][:60]
        scores = []
        for step in range(-12, 13):
            cand = base_v + step * 0.05
            trial = dict(geom["qud"]); trial[key] = cand
            tot, n = 0.0, 0
            for (cx, cy) in far:
                qr = cell_rect(trial, cx, cy)
                rr = cell_rect(geom["raves"], cx, cy)
                if not (inside(qr, qw, qh, QUD_MAP_FRAC) and inside(rr, rw, rh, RAVES_MAP_FRAC)):
                    continue
                tot += _coarse_diff(qget, rget, qr, rr)
                n += 1
            if n:
                scores.append((tot / n, cand))
        if scores:
            scores.sort()
            best[key] = round(scores[0][1], 3)
            print("  fit %s: %.3f px (from %d, mean |d| %.1f)"
                  % (key, best[key], base_v, scores[0][0]))
    return best


# Qud's MAP VIEWPORT is narrower than its window: the right edge is the
# sidebar (Nearby objects + message log). Calibration already knows this —
# it clips its cluster search to the same fraction. Scoring past it compares
# message-log TEXT against painted ground: the first run's 28 "FAIL"s were
# every one of them sidebar glyphs ("moc/ur", "10she") vs bare dirt, which is
# also what made the pitch fit chase noise.
# A PASS below this margin (see main) is evidence-free — reported `vacuous`.
MARGIN = 8.0
QUD_MAP_FRAC = 0.58
RAVES_MAP_FRAC = 0.48


def inside(rect, w, h, frac=1.0):
    return (rect["x"] >= 0 and rect["y"] >= 0
            and rect["x"] + rect["w"] <= w * frac and rect["y"] + rect["h"] <= h)


def masked_reason(cell, animated):
    for o in cell.get("objs", []):
        if o.get("creature"):
            return "creature"
        if o.get("name") in animated or o.get("bp") in animated:
            return "animated"
        for k in ("animSched", "animShimmer", "animHolo", "animCycle", "animGas", "onFire"):
            if o.get(k):
                return "animated"
    return None


def main(argv):
    from PIL import Image
    b = control.Bridge()
    b.send("wait")
    snap = b.read_snapshot(timeout=40)
    b.close()
    pair = checker.shots_for("playfield", "playfield")
    if "qud" not in pair or "raves" not in pair:
        sys.exit("playfield: capture pair failed")
    geom = congruence.load_geometry()
    if "--fit" in argv:
        print("fitting the Qud grid pitch...")
        fitted = fit_stride(pair, geom, snap)
        geom["qud"].update(fitted)
        congruence.save_geometry(geom["qud"], geom["raves"])
        print("  saved to the geometry fixture")
    qw, qh = Image.open(pair["qud"]).size
    rw, rh = Image.open(pair["raves"]).size
    animated = {bp for bp, ok in checker._anim_verified().items() if ok}

    rows, tally = [], {}
    for cell in snap.get("cells", []):
        cx, cy = int(cell["x"]), int(cell["y"])
        qr = cell_rect(geom["qud"], cx, cy)
        rr = cell_rect(geom["raves"], cx, cy)
        if not (inside(qr, qw, qh, QUD_MAP_FRAC) and inside(rr, rw, rh, RAVES_MAP_FRAC)):
            verdict = "offscreen"
            rows.append({"x": cx, "y": cy, "verdict": verdict})
            tally[verdict] = tally.get(verdict, 0) + 1
            continue
        why = masked_reason(cell, animated)
        if why:
            rows.append({"x": cx, "y": cy, "verdict": "masked:" + why})
            tally["masked:" + why] = tally.get("masked:" + why, 0) + 1
            continue
        res = congruence.score(pair["qud"], pair["raves"], {"qud": qr, "raves": rr})
        band = res["band"]
        # DISCRIMINATING POWER: a PASS only means something if this cell would
        # have scored WORSE against the wrong neighbour. On uniform painted
        # ground it does not — a deliberate one-cell offset over Joppa moved
        # the tally by 26 cells out of 775, because dirt matches dirt wherever
        # you sample it. Cells whose margin is below MARGIN are reported as
        # `vacuous`: covered, but carrying no evidence.
        off = cell_rect(geom["raves"], cx + 1, cy)
        margin = 0.0
        if inside(off, rw, rh, RAVES_MAP_FRAC):
            alt = congruence.score(pair["qud"], pair["raves"], {"qud": qr, "raves": off})
            margin = alt["mean_abs_diff"] - res["mean_abs_diff"]
        verdict = band if (band != "PASS" or margin >= MARGIN) else "vacuous"
        rows.append({"x": cx, "y": cy, "verdict": verdict, "band": band,
                     "mean": round(res["mean_abs_diff"], 1),
                     "margin": round(margin, 1),
                     "objs": [o.get("name") for o in cell.get("objs", [])][:4]})
        tally[verdict] = tally.get(verdict, 0) + 1

    zone = snap.get("zone", {}).get("id", "?")
    print("zone: %s" % zone)
    print("  " + " / ".join("%d %s" % (tally[k], k) for k in sorted(tally)))
    bad = sorted((r for r in rows if r["verdict"] == "FAIL"),
                 key=lambda r: -r.get("mean", 0))
    for r in bad[:20]:
        print("  FAIL (%2d,%2d) mean=%-6.1f %s" % (r["x"], r["y"], r["mean"],
                                                  ", ".join(str(o) for o in r["objs"])[:60]))
    if len(bad) > 20:
        print("  ... and %d more" % (len(bad) - 20))
    if "--json" in argv:
        out = argv[argv.index("--json") + 1]
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"zone": zone, "tally": tally, "cells": rows}, f, indent=1)
        print("detail:", out)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

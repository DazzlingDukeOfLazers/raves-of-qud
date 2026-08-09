#!/usr/bin/env python3
"""Measure the popup emblem's ink bbox above the top rule.

A plain brightness threshold does NOT work here: Qud dims the live playfield behind the
modal rather than blanking it, and grass/fire/wall pixels clear sum(rgb)>140 all over the
band, so the bbox comes back as the whole scan window (measured: x800..1119). The emblem
is a single FLAT tint, so match that tint with a tolerance instead -- the playfield's
dimmed pixels are nowhere near it.

Scan stops at y319: the top rule's caps live at y319-322 and would otherwise be folded in.
"""
import sys
import numpy as np
from PIL import Image

TINT = (68, 99, 111)     # Qud's rendered emblem tint, measured 2026-08-09
# tol 0..6 all give the same answer on Qud's capture (x940..978 / y276..318, 447 lit); at 8 a
# dimmed wall segment at x915 joins in. 4 sits in the middle of that plateau.
TOL = 4
X0, X1 = 880, 1040       # inside the popup box, clear of its edges
Y0, Y1 = 240, 319        # 319 exclusive -- the rule caps start there


def measure(path, tint=TINT, tol=TOL):
    a = np.array(Image.open(path).convert("RGB")).astype(int)
    sub = a[Y0:Y1, X0:X1]
    m = np.abs(sub - np.array(tint)).max(axis=2) <= tol
    ys, xs = np.nonzero(m)
    if len(ys) == 0:
        return None
    cols = sub[m]
    uniq, cnt = np.unique(cols.reshape(-1, 3), axis=0, return_counts=True)
    return {
        "x": (int(xs.min()) + X0, int(xs.max()) + X0),
        "y": (int(ys.min()) + Y0, int(ys.max()) + Y0),
        "w": int(xs.max() - xs.min() + 1),
        "h": int(ys.max() - ys.min() + 1),
        "lit": int(m.sum()),
        "dom": tuple(int(v) for v in uniq[cnt.argmax()]),
        "cx": (int(xs.min()) + int(xs.max())) / 2.0 + X0,
    }


if __name__ == "__main__":
    for p in sys.argv[1:]:
        r = measure(p)
        if r is None:
            print("%-40s NOTHING in x%d..%d y%d..%d" % (p.split("/")[-1], X0, X1, Y0, Y1))
        else:
            print("%-40s x%d..%d (w %d)  y%d..%d (h %d)  lit %d  dom %s  cx %.1f" % (
                p.split("/")[-1], r["x"][0], r["x"][1], r["w"],
                r["y"][0], r["y"][1], r["h"], r["lit"], r["dom"], r["cx"]))

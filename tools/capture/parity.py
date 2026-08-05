#!/usr/bin/env python3
"""Region-scoped parity scoring for capture-diff work.

WHY THIS EXISTS
---------------
Whole-frame (and even per-band) mean-diff is too noisy to adjudicate small UI
changes: the live playfield behind a status screen's scrim differs every run, and
that alone moved the Equipment tab's average by ~0.7 between identical builds —
larger than most deltas worth chasing. Worse, a naive "ink box" that includes a
cell's own border measures the BOX, not the sprite, and blur flatters a mean while
looking wrong.

So parity is scored per LEAF: a named region with a kind that says what to compare.

  image      only the sprite ink inside a cell — the frame is masked out
  frame      only the chrome lines — the sprite interior is masked out
  composite  the whole cell, both together (what the eye sees)
  ink_color  the MEAN COLOUR of the ink, position ignored — isolates palette
  geometry   the ink BBOX only, colour ignored — isolates size and placement

The last two exist because "is the text the right colour" and "is the sprite the
right size" are different questions from "do these pixels match", and a single
masked mean-abs-diff answers all three at once and so answers none of them
clearly. A leaf that scores 0 on ink_color and badly on geometry says "right
paint, wrong place" — which is the sentence you actually want.

Each leaf reports mean abs diff over the compared pixels, the ink bounding box in
both apps, and coverage, so a change can be judged on the thing it touched.

USAGE
  parity.py score  <spec.json> <qud.png> <raves.png> [--leaf NAME] [--json]
  parity.py bounds <spec.json> <img.png> [--leaf NAME]      # what a leaf sees
  parity.py mask   <spec.json> <img.png> <leaf> <out.png>   # eyeball the mask

The spec is data (reports/<date>/parity-<screen>.json) so new screens are a JSON
edit, not code. Leaf names are the same strings the highvisor gametree uses for
its per-leaf 1:1 scores.
"""
import json
import sys

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("needs pillow + numpy (the same deps the other capture tools use)")


# ---------------------------------------------------------------- spec loading

def load_spec(path):
    with open(path) as f:
        spec = json.load(f)
    leaves = []
    for leaf in spec["leaves"]:
        # a leaf may enumerate cells on a grid instead of one rect
        if "grid" in leaf:
            g = leaf["grid"]
            for i, (cx, cy) in enumerate(g["cells"]):
                leaves.append(dict(leaf, name="%s[%d]" % (leaf["name"], i),
                                   rect=[cx, cy, g["w"], g["h"]], grid=None))
        else:
            leaves.append(leaf)
    return spec, leaves


def crop(img, rect):
    x, y, w, h = rect
    return img[y:y + h, x:x + w]


# ------------------------------------------------------------------- masking

def frame_mask(cell, inset):
    """True where the CHROME is: a border band `inset` thick around the cell."""
    m = np.zeros(cell.shape[:2], bool)
    m[:inset, :] = True
    m[-inset:, :] = True
    m[:, :inset] = True
    m[:, -inset:] = True
    return m


def ink_mask(cell, inset, thr):
    """True where SPRITE ink is: bright pixels strictly inside the frame band.

    The frame is excluded by construction — measuring ink with the border
    included is how "Qud's ink is 47x48" ended up describing the box rather
    than the sprite.
    """
    m = np.zeros(cell.shape[:2], bool)
    if inset <= 0:
        # inset 0 means "the whole rect" -- cell[0:-0] slices to NOTHING, which silently
        # reported every such leaf as empty (and therefore as a perfect 0.00 score)
        return cell.mean(axis=2) > thr
    inner = cell[inset:-inset, inset:-inset].mean(axis=2) > thr
    m[inset:-inset, inset:-inset] = inner
    return m


def mean_ink_color(cell, mask):
    """Average colour of the masked pixels, or None when nothing is lit."""
    if not mask.any():
        return None
    return cell[mask].mean(axis=0)


def score_ink_color(qc, rc, qm, rm):
    """Colour only. Each side averages ITS OWN ink, so a sprite that sits a few
    pixels off still compares its paint rather than its position."""
    a, b = mean_ink_color(qc, qm), mean_ink_color(rc, rm)
    if a is None and b is None:
        return 0.0, "both empty"
    if a is None or b is None:
        return 255.0, "present in one app only"
    return float(np.abs(a - b).mean()), None


def score_geometry(qm, rm):
    """Size and placement only, in pixels: mean |dx|,|dy|,|dw|,|dh| of the ink boxes."""
    a, b = bbox(qm), bbox(rm)
    if a is None and b is None:
        return 0.0, "both empty"
    if a is None or b is None:
        present = a or b
        # absent entirely: penalise by the size of what the other app draws
        return float((present[2] + present[3]) / 2.0), "present in one app only"
    return float(np.mean([abs(x - y) for x, y in zip(a, b)])), None


def leaf_mask(cell, leaf, defaults):
    kind = leaf.get("kind", "composite")
    inset = leaf.get("inset", defaults.get("inset", 6))
    thr = leaf.get("threshold", defaults.get("threshold", 60))
    if kind == "frame":
        return frame_mask(cell, inset)
    if kind in ("image", "ink_color", "geometry"):
        return ink_mask(cell, inset, thr)
    return np.ones(cell.shape[:2], bool)          # composite: everything


def bbox(mask):
    ys, xs = np.where(mask)
    if not len(ys):
        return None
    return [int(xs.min()), int(ys.min()),
            int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)]


# ------------------------------------------------------------------- scoring

def score_leaf(q, r, leaf, defaults):
    qc = crop(q, leaf["rect"]).astype(float)
    rc = crop(r, leaf["rect"]).astype(float)
    # compare on the UNION of both masks: a sprite that is too small in one app
    # must still be penalised for the pixels the other app paints
    qm = leaf_mask(qc, leaf, defaults)
    rm = leaf_mask(rc, leaf, defaults)
    kind = leaf.get("kind", "composite")
    if kind in ("ink_color", "geometry"):
        diff, note = (score_ink_color(qc, rc, qm, rm) if kind == "ink_color"
                      else score_geometry(qm, rm))
        row = dict(name=leaf["name"], kind=kind, diff=round(diff, 2),
                   pixels=int(qm.sum() + rm.sum()),
                   qud_bbox=bbox(qm), raves_bbox=bbox(rm),
                   qud_px=int(qm.sum()), raves_px=int(rm.sum()))
        if note:
            row["note"] = note
        return row
    m = qm | rm
    if not m.any():
        return dict(name=leaf["name"], kind=leaf.get("kind", "composite"),
                    diff=0.0, pixels=0, note="empty")
    diff = float(np.abs(qc - rc).mean(axis=2)[m].mean())
    return dict(name=leaf["name"], kind=leaf.get("kind", "composite"),
                diff=round(diff, 2), pixels=int(m.sum()),
                qud_bbox=bbox(qm), raves_bbox=bbox(rm),
                qud_px=int(qm.sum()), raves_px=int(rm.sum()))


def cmd_score(spec_path, qud_path, raves_path, only=None, as_json=False):
    spec, leaves = load_spec(spec_path)
    q = np.asarray(Image.open(qud_path).convert("RGB"))
    r = np.asarray(Image.open(raves_path).convert("RGB"))
    defaults = spec.get("defaults", {})
    rows = [score_leaf(q, r, lf, defaults) for lf in leaves
            if only is None or lf["name"].startswith(only)]
    if as_json:
        print(json.dumps({"screen": spec.get("screen"), "leaves": rows}, indent=1))
        return
    print("%-26s %-9s %7s %8s  %-18s %-18s" %
          ("leaf", "kind", "diff", "px", "qud bbox", "raves bbox"))
    for row in rows:
        print("%-26s %-9s %7.2f %8d  %-18s %-18s" % (
            row["name"], row["kind"], row["diff"], row["pixels"],
            row.get("qud_bbox"), row.get("raves_bbox")))
    by_kind = {}
    for row in rows:
        by_kind.setdefault(row["kind"], []).append(row["diff"])
    print()
    for kind, ds in sorted(by_kind.items()):
        print("  %-9s mean %.2f over %d leaves" % (kind, sum(ds) / len(ds), len(ds)))


def cmd_bounds(spec_path, img_path, only=None):
    spec, leaves = load_spec(spec_path)
    a = np.asarray(Image.open(img_path).convert("RGB"))
    defaults = spec.get("defaults", {})
    for lf in leaves:
        if only and not lf["name"].startswith(only):
            continue
        cell = crop(a, lf["rect"]).astype(float)
        m = leaf_mask(cell, lf, defaults)
        print("%-26s %-9s bbox %s  px %d" %
              (lf["name"], lf.get("kind", "composite"), bbox(m), int(m.sum())))


def cmd_mask(spec_path, img_path, leaf_name, out_path):
    spec, leaves = load_spec(spec_path)
    a = np.asarray(Image.open(img_path).convert("RGB"))
    defaults = spec.get("defaults", {})
    for lf in leaves:
        if lf["name"] == leaf_name:
            cell = crop(a, lf["rect"]).astype(float)
            m = leaf_mask(cell, lf, defaults)
            out = cell.copy()
            out[~m] = [40, 0, 0]                  # masked-out pixels go dark red
            Image.fromarray(out.astype("uint8")).save(out_path)
            print("wrote", out_path)
            return
    sys.exit("no leaf named %r" % leaf_name)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    only = None
    if "--leaf" in argv:
        only = argv[argv.index("--leaf") + 1]
    if cmd == "score":
        cmd_score(argv[2], argv[3], argv[4], only, "--json" in argv)
    elif cmd == "bounds":
        cmd_bounds(argv[2], argv[3], only)
    elif cmd == "mask":
        cmd_mask(argv[2], argv[3], argv[4], argv[5])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

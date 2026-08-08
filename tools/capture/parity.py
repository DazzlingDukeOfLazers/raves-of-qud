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
  parity.py capture <node> <prefix> [--no-goto] [--no-fresh] [--stable-gap S]
  parity.py score  <spec.json> <qud.png> <raves.png> [--leaf NAME] [--json]
                   [--stable <qud2.png>]   ignore pixels the reference does not hold still
  parity.py bounds <spec.json> <img.png> [--leaf NAME]      # what a leaf sees
  parity.py mask   <spec.json> <img.png> <leaf> <out.png>   # eyeball the mask

The spec is data (reports/<date>/parity-<screen>.json) so new screens are a JSON
edit, not code. Leaf names are the same strings the highvisor gametree uses for
its per-leaf 1:1 scores.

--stable: Qud draws its status screens over the LIVE playfield, which shows through
the scrim and differs every run -- creatures move, tiles animate. That lands on the
list leaves as noise big enough to swamp the thing being measured (the same build
scored list_item 5.70 and 9.00 on consecutive captures with no code change between
them). Pass a SECOND Qud capture of the same screen and every pixel that differs
between the two is dropped from every leaf: what is left is the UI, which is what
these leaves are about. Cheaper and safer than blanking Qud's world, which has no
option for it and no obviously reversible lever in its render stack.
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


def anchor_row(img, spec):
    """First row in a band where `rgb` appears at least `min` times across `x`.

    Lets a leaf be quoted RELATIVE to a landmark each app draws for itself -- for a
    popup, its own top line. Without this, a leaf about the header's CONTENT also
    silently scores the popup's PLACEMENT, and a constant 16px offset makes a
    pixel-perfect header look broken.
    """
    rgb = np.array(spec["rgb"])
    x0, x1 = spec.get("x", [0, img.shape[1]])
    y0, y1 = spec.get("band", [0, img.shape[0]])
    need = spec.get("min", 100)
    m = (np.abs(img[:, x0:x1].astype(int) - rgb).max(axis=2) < spec.get("tol", 25))
    for y in range(y0, min(y1, img.shape[0])):
        if m[y].sum() >= need:
            return y
    return None


def resolve_rect(leaf, img, spec):
    """A leaf's rect, with y taken relative to the anchor row when one is declared."""
    rect = list(leaf["rect"])
    a = leaf.get("anchor") or spec.get("anchor")
    if a and leaf.get("anchored", True) and ("anchor" in leaf or "anchor" in spec):
        y = anchor_row(img, a)
        if y is not None:
            rect[1] = y + rect[1]
    return rect


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

def score_leaf(q, r, leaf, defaults, spec=None):
    spec = spec or {}
    qc = crop(q, resolve_rect(leaf, q, spec)).astype(float)
    rc = crop(r, resolve_rect(leaf, r, spec)).astype(float)
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


def cmd_score(spec_path, qud_path, raves_path, only=None, as_json=False, stable=None):
    spec, leaves = load_spec(spec_path)
    q = np.asarray(Image.open(qud_path).convert("RGB"))
    r = np.asarray(Image.open(raves_path).convert("RGB"))
    if q.shape[:2] != r.shape[:2]:
        # Every leaf rect is absolute pixels, so two differently sized windows make each
        # rect mean a different thing in each app. Say so, rather than let numpy raise a
        # boolean-index error twenty frames deeper.
        sys.exit("SIZE MISMATCH: qud is %dx%d, raves is %dx%d. The leaf rects are absolute "
                 "pixels, so these cannot be compared. Run `hv layout pair` and re-capture."
                 % (q.shape[1], q.shape[0], r.shape[1], r.shape[0]))
    if stable:
        q2 = np.asarray(Image.open(stable).convert("RGB"))
        if q2.shape == q.shape and not (q != q2).any():
            # A LIVE Qud never renders two identical frames -- the playfield behind the
            # scrim animates, so two captures normally differ on most pixels. Identical
            # means the app stopped rendering and the "capture" is a stale frame, which
            # scores as confident nonsense: an evening of reputation measurements were
            # taken against a frozen playfield while the bridge cheerfully reported the
            # right screen. --stable cannot catch this on its own; a frozen app holds
            # EVERY pixel still, so the filter passes everything and reports the
            # reference as rock solid. Refuse instead of measuring a corpse.
            sys.exit("FROZEN REFERENCE: %s and %s are pixel-identical, so the app was not\n"
                     "rendering. Restart it and re-capture -- any score from these is void.\n"
                     "(Qud stalls this way within ~10 min; focusing does NOT recover it.)"
                     % (qud_path, stable))
        if q2.shape == q.shape:
            # Where the reference did not hold still between two captures, it is the
            # world showing through -- not UI. Paint those pixels identical in both so
            # they contribute nothing, rather than dropping them (which would change
            # every leaf's pixel count and make the numbers incomparable).
            moved = (np.abs(q.astype(int) - q2.astype(int)).max(axis=2) > 6)
            q = q.copy(); r = r.copy()
            q[moved] = 0
            r[moved] = 0
            print("  [--stable] ignoring %d px the reference did not hold still (%.1f%%)"
                  % (int(moved.sum()), 100.0 * moved.mean()))
    defaults = spec.get("defaults", {})
    rows = [score_leaf(q, r, lf, defaults, spec) for lf in leaves
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
        cell = crop(a, resolve_rect(lf, a, spec)).astype(float)
        m = leaf_mask(cell, lf, defaults)
        print("%-26s %-9s bbox %s  px %d" %
              (lf["name"], lf.get("kind", "composite"), bbox(m), int(m.sum())))


def cmd_mask(spec_path, img_path, leaf_name, out_path):
    spec, leaves = load_spec(spec_path)
    a = np.asarray(Image.open(img_path).convert("RGB"))
    defaults = spec.get("defaults", {})
    for lf in leaves:
        if lf["name"] == leaf_name:
            cell = crop(a, resolve_rect(lf, a, spec)).astype(float)
            m = leaf_mask(cell, lf, defaults)
            out = cell.copy()
            out[~m] = [40, 0, 0]                  # masked-out pixels go dark red
            Image.fromarray(out.astype("uint8")).save(out_path)
            print("wrote", out_path)
            return
    sys.exit("no leaf named %r" % leaf_name)


def _hv():
    """Path to the hv CLI. Not on PATH on every box (Lumpy installs it user-scope)."""
    import os
    import shutil
    env = os.environ.get("HV")
    if env and os.path.exists(env):
        return env
    found = shutil.which("hv")
    if found:
        return found
    for c in (os.path.expanduser("~/bin/hv"),
              os.path.expandvars(r"%LOCALAPPDATA%\Programs\Python\Python312\Scripts\hv.exe")):
        if os.path.exists(c):
            return c
    sys.exit("cannot find the hv CLI; set HV=/path/to/hv")


def cmd_capture(node, prefix, goto=True, stable_gap=0.0, fresh=True):
    """Drive both apps to `node` and capture the q / q2 / raves triple that `score` wants.

    THE POINT OF THIS COMMAND is that every capture goes through `hv shot --live`, which
    blocks until the app is actually rendering. A Unity app that is not rendering still
    screenshots: it returns its last frame, and for Qud that frame is the playfield with
    no UI overlay, so a status-screen capture comes back looking like the plain map while
    the heartbeat correctly reports the status screen. An evening of reputation scores was
    measured against exactly that.

    This existed as ad-hoc shell in every session before now, which is precisely why the
    mistake kept coming back -- the liveness check was reinvented, or forgotten, each time.
    """
    import subprocess
    import time
    hv = _hv()

    def run(args, what):
        r = subprocess.run([hv] + args, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("%s failed (exit %d):\n%s%s" % (what, r.returncode, r.stdout, r.stderr))
        return r.stdout.strip()

    if goto:
        # PIN THE SCROLL by rebuilding the screen. Switching tabs inside an open status
        # screen preserves each list's scroll offset, so the same tab reached after a
        # different route comes up scrolled differently -- measured at ~28px on the
        # reputation list, which moved list_next from 5.14 to 9.25 with no code change.
        # A row-shaped leaf reads a scroll as a total mismatch, so a score is only
        # comparable across runs if the list starts in the same place.
        #
        # Closing to in_game and re-entering rebuilds the list at the top. Verified: the
        # tab reached directly and the tab reached after visiting quests and journal
        # differ by 0.05%, against 6.2% without this.
        if fresh and node.startswith("status_"):
            for app in ("raves", "qud"):
                run(["goto", app, "in_game"], "goto %s in_game (scroll pin)" % app)
        for app in ("raves", "qud"):
            run(["goto", app, node], "goto %s %s" % (app, node))

    shots = [("CavesOfQud", prefix + "_q.png"),
             ("CavesOfQud", prefix + "_q2.png"),   # the --stable reference
             ("Raves of Qud", prefix + "_r.png")]
    for i, (target, out) in enumerate(shots):
        # --stable-gap spaces the two Qud shots out. OFF by default, and the reason is
        # worth keeping: --stable masks 1,008 px on the reputation tab while the same
        # screen differs on 129,370 px between runs, so widening the window looked like
        # the obvious fix. It is not. Measured at 12s it masked 1,046 px -- no better --
        # because the run-to-run difference is not animation at all. Qud's list sits at a
        # DIFFERENT SCROLL OFFSET between runs (~28px, visible immediately in a stacked
        # crop), and no stability window can mask a scroll. Kept as an option for a screen
        # that genuinely does animate; not paid by default for one that does not.
        if i == 1 and stable_gap > 0:
            time.sleep(stable_gap)
        print("  " + run(["shot", target, out, "--live"], "shot %s" % target))

    # Both windows must be the same size or every leaf rect means something different in
    # each. A Raves dev-run relaunches at the display's default size, so this is not
    # hypothetical -- it silently produced a 2400-tall capture against a 1080-tall spec.
    sizes = {}
    for _t, out in shots:
        sizes[out] = Image.open(out).size
    uniq = set(sizes.values())
    if len(uniq) > 1:
        for k, v in sizes.items():
            print("    %s %s" % (k, v))
        sys.exit("SIZE MISMATCH: the windows are not the same size. Run `hv layout pair` "
                 "and re-capture; a raw `hv move` on a fixed sleep races the window.")

    print("\n  captured %s at %s" % (node, "x".join(str(n) for n in uniq.pop())))
    print("  score it:\n    parity.py score <spec.json> %s_q.png %s_r.png --stable %s_q2.png"
          % (prefix, prefix, prefix))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    only = None
    if "--leaf" in argv:
        only = argv[argv.index("--leaf") + 1]
    if cmd == "score":
        stable = argv[argv.index("--stable") + 1] if "--stable" in argv else None
        cmd_score(argv[2], argv[3], argv[4], only, "--json" in argv, stable)
    elif cmd == "capture":
        gap = float(argv[argv.index("--stable-gap") + 1]) if "--stable-gap" in argv else 0.0
        cmd_capture(argv[2], argv[3], goto="--no-goto" not in argv, stable_gap=gap,
                    fresh="--no-fresh" not in argv)
    elif cmd == "bounds":
        cmd_bounds(argv[2], argv[3], only)
    elif cmd == "mask":
        cmd_mask(argv[2], argv[3], argv[4], argv[5])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

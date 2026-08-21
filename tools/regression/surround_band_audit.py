#!/usr/bin/env python3
"""SPOT: the surround band's hand-over invariant, mirrored from ZoneRenderer.gd.

The band replaces the old penumbra "bib", which failed for a reason arithmetic can catch:
its first surround row did not equal the zone edge it abutted. It started at a CONSTANT
(FROZEN_EDGE_DIM) over a DIFFERENT BASE COLOUR, and the two rows meant to match measured
1.8/1.45/1.48 apart -- a different factor per channel, so no alpha could fix it.

The new band answers both halves per-cell: the base is the edge cell's own floor material
repeated outward, and the alpha starts at that same cell's tone. This asserts the alpha half
and the mapping that makes the base half true. Pure arithmetic -- no Godot, no apps.
"""
import sys

W, H = 80, 25
R = 3                      # penumbra_radius
BAND = R + 1
FOG_GROUND = None          # only used as the missing-tone fallback; not exercised here


def band_depth(wx, wy):
    dx = max(0, -wx, wx - (W - 1))
    dy = max(0, -wy, wy - (H - 1))
    return max(dx, dy)


def band_src(wx, wy):
    return (min(max(wx, 0), W - 1), min(max(wy, 0), H - 1))


def band_alpha(d, t0):
    f = min(max((d - 1) / float(max(1, R)), 0.0), 1.0)
    return min(max(t0 + (1.0 - t0) * f, 0.0), 1.0)


fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


# 1. CONTINUITY -- the whole point. The first surround row must carry EXACTLY the tone of the
#    edge cell it extends, for every tone a cell can have, so the seam cannot show.
for t0 in (0.0, 0.18, 0.37, 0.5, 0.82, 0.94, 1.0):
    a = band_alpha(1, t0)
    check(abs(a - t0) < 1e-9, "d=1 alpha %.6f != edge tone %.6f" % (a, t0))

# 2. The ramp reaches full darkness exactly at the band's outer row, never before.
for t0 in (0.0, 0.5, 0.94):
    check(abs(band_alpha(BAND, t0) - 1.0) < 1e-9,
          "d=%d not fully dark for t0=%.2f" % (BAND, t0))
    for d in range(1, BAND):
        check(band_alpha(d, t0) < 1.0 - 1e-9 or t0 >= 1.0,
              "d=%d already opaque for t0=%.2f" % (d, t0))

# 3. Monotonic outward -- a band that brightens as it leaves the zone reads as a halo.
for t0 in (0.0, 0.3, 0.7):
    prev = -1.0
    for d in range(1, BAND + 1):
        a = band_alpha(d, t0)
        check(a >= prev - 1e-9, "t0=%.2f not monotonic at d=%d" % (t0, d))
        prev = a

# 4. A DARK edge cell must never be brightened by the band. This is the failure the old ramp
#    had in the other direction: a constant start lit up an unlit edge.
for t0 in (0.94, 1.0):
    for d in range(1, BAND + 1):
        check(band_alpha(d, t0) >= t0 - 1e-9,
              "band lightened a dark edge: t0=%.2f d=%d -> %.3f" % (t0, d, band_alpha(d, t0)))

# 5. Every band cell clamps to a cell ON THE EDGE RING -- that is what makes _edge_floor a
#    complete lookup. A clamp landing in the interior would be a cache miss and a bare quad.
ring_misses = 0
covered = 0
for wy in range(-BAND, H + BAND):
    for wx in range(-BAND, W + BAND):
        d = band_depth(wx, wy)
        if d <= 0 or d > BAND:
            continue
        covered += 1
        sx, sy = band_src(wx, wy)
        on_ring = sx in (0, W - 1) or sy in (0, H - 1)
        if not on_ring:
            ring_misses += 1
check(ring_misses == 0, "%d band cells clamp to a non-edge cell" % ring_misses)

# 6. The band is the ring it claims to be: (W+2B)(H+2B) - WH cells, corners included once.
expect = (W + 2 * BAND) * (H + 2 * BAND) - W * H
check(covered == expect, "band covers %d cells, expected %d" % (covered, expect))

# 7. BORROWING IS LOCAL. A band cell whose source has no ground quad may take one from a
#    neighbour along the same edge, but only within BAND_BORROW_MAX -- past that there is no
#    ground here and the band goes solid instead. Unbounded, one distant patch of floor got
#    dragged around a whole cave boundary: measured rings held ground for as few as 4 of 206
#    cells, and 525 of 904 band cells were borrowing.
BAND_BORROW_MAX = 3


def borrow_targets(src_x, along_x, w, h):
    """The cells _edge_floor_for will consider, in order, for a source with no ground."""
    out = []
    lim = w if along_x else h
    for step in range(1, BAND_BORROW_MAX + 1):
        for sgn in (-1, 1):
            c = src_x + step * sgn
            if 0 <= c < lim:
                out.append(c)
    return out


for src_x in (0, 1, 40, 78, 79):
    t = borrow_targets(src_x, True, W, H)
    check(all(abs(c - src_x) <= BAND_BORROW_MAX for c in t),
          "borrow from %d reached beyond BAND_BORROW_MAX" % src_x)
    check(len(t) <= 2 * BAND_BORROW_MAX,
          "borrow from %d considered %d cells" % (src_x, len(t)))
    # nearest-first, so a gap is filled by the closest real ground and not an arbitrary one
    check(t == sorted(t, key=lambda c: (abs(c - src_x), c)),
          "borrow from %d is not nearest-first" % src_x)

# 8. Corners clamp to the four zone corners, which is the only honest answer with no data in
#    either direction -- and the case a per-EDGE (rather than per-cell) design gets wrong.
for (wx, wy), want in (((-1, -1), (0, 0)), ((W, -1), (W - 1, 0)),
                       ((-1, H), (0, H - 1)), ((W, H), (W - 1, H - 1))):
    check(band_src(wx, wy) == want,
          "corner %s clamped to %s, expected %s" % ((wx, wy), band_src(wx, wy), want))

# 9. THE FROZEN SIDE USES THE SAME RULE. A departed zone's tone is _band_alpha over the same
#    _band_src / _band_depth, so a boundary against a loaded neighbour hands over exactly as one
#    against unexplored ground does. This is the whole point of sharing the function: the two
#    sides cannot drift apart, and everything asserted above holds for both.
#
#    Before this, the frozen side was a flat 1 - MEMORY_GROUND = 0.16 while the live zone could
#    be at 0.0, so the north edge stepped twice -- zone, then neighbour, then black. Daniel: "the
#    eastern edge of the zone is correct. The northern edge is not." East was a band; north was a
#    loaded neighbour.
MEMORY_GROUND = 0.84
for t0 in (0.0, 0.16, 0.5, 0.94):
    check(abs(band_alpha(1, t0) - t0) < 1e-9,
          "frozen hand-over at d=1 is %.4f, not the live edge's %.4f" % (band_alpha(1, t0), t0))
    # ...and it must not stall at the memory tone, which is the step being removed
    if t0 < 1.0 - MEMORY_GROUND:
        check(band_alpha(1, t0) < 1.0 - MEMORY_GROUND + 1e-9,
              "frozen hand-over floored at the memory tone for a lighter edge (t0=%.2f)" % t0)

if fails:
    print("surround_band: FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("surround_band: hand-over is continuous at d=1 for every tone; %d band cells, all "
      "clamping to the edge ring; ramp monotonic to full dark at d=%d; borrowing bounded to "
      "%d cells, nearest first" % (covered, BAND, BAND_BORROW_MAX))

#!/usr/bin/env python3
"""Prototype the voxel stairs-down geometry BEFORE porting to GDScript.

I can't see the Godot viewport, so the geometry rule is worked out here where its
output is inspectable (a printed cross-section + a top view), then ported to
ZoneRenderer._place_stairs_down. See docs/rendering.md and CLAUDE.md
("Prototype geometry algorithms in Python first").

Conventions copied from ZoneRenderer:
  - a cell (cx,cy) is CENTRED at world (cx, y, cy), spanning +/-0.5 in X and Z.
  - +X = east, +Z = south, Y is up; floor at y=0; walls rise to WALL_H=1.2.
Canonical descent is toward +Z (south); other directions rotate the whole group
by yaw (0/90/180/270), exactly like _place_side does for wall faces.
"""

N_STEPS   = 6      # number of treads in the flight
DEPTH     = 1.0    # how far below the floor the bottom step sits (one cell)
FRAME_W   = 0.10   # width of the raised lip framing the opening
FRAME_H   = 0.05   # how far the lip stands proud of the floor
FLOOR_Y   = 0.0

HI   = 0.5 - FRAME_W          # half-width of the opening inside the frame
RUN  = (2 * HI) / N_STEPS     # along-descent length of one tread
RISE = DEPTH / N_STEPS        # vertical drop per step
PIT  = -DEPTH - 0.02          # solid floor every step column bottoms out on


def steps():
    """Each step is a SOLID column from the pit floor up to its tread top, so the
    flight reads as clean descending steps with no see-through underside. Column i
    (i=0 = back/north/shallow) tops out higher than i+1, so tops descend +Z."""
    out = []
    for i in range(N_STEPS):
        z0 = -HI + i * RUN
        z1 = -HI + (i + 1) * RUN
        top = -(i + 1) * RISE          # tread surface: -RISE (shallow) .. -DEPTH (deep)
        out.append(dict(x=(-HI, HI), z=(z0, z1), y=(PIT, top)))
    return out


def frame():
    """Four raised bars around the cell perimeter = the 'top of the stair' opening.
    Inner edge at +/-HI (flush with the flight), outer edge at the cell boundary."""
    o, hi = 0.5, HI
    bars = {
        "N": dict(x=(-o, o),   z=(-o, -hi)),
        "S": dict(x=(-o, o),   z=(hi, o)),
        "E": dict(x=(hi, o),   z=(-hi, hi)),
        "W": dict(x=(-o, -hi), z=(-hi, hi)),
    }
    for b in bars.values():
        b["y"] = (FLOOR_Y, FLOOR_Y + FRAME_H)
    return bars


def check():
    st = steps()
    # 1. descent is monotonic and bounded
    tops = [s["y"][1] for s in st]
    assert tops == sorted(tops, reverse=True), "steps must descend"
    assert abs(tops[0] - -RISE) < 1e-9 and abs(tops[-1] - -DEPTH) < 1e-9
    # 2. treads tile the opening with no gap/overlap along Z
    for a, b in zip(st, st[1:]):
        assert abs(a["z"][1] - b["z"][0]) < 1e-9, "treads must abut"
    assert abs(st[0]["z"][0] - -HI) < 1e-9 and abs(st[-1]["z"][1] - HI) < 1e-9
    # 3. everything stays inside the cell footprint
    for s in st:
        assert -0.5 <= s["x"][0] and s["x"][1] <= 0.5
        assert -0.5 <= s["z"][0] and s["z"][1] <= 0.5
    print("OK: %d steps, run=%.3f rise=%.3f, opening %.2f x %.2f, depth %.2f"
          % (N_STEPS, RUN, RISE, 2 * HI, 2 * HI, DEPTH))


def cross_section():
    """Side view along the descent (Z ->, Y down). One column per step, '#' = solid."""
    st = steps()
    rows = 12
    print("\ncross-section (north/back -> south/front, looking east):")
    for r in range(rows):
        y = FLOOR_Y - (r + 0.5) * (DEPTH / rows)
        line = []
        for s in st:
            line.append("##" if s["y"][0] <= y <= s["y"][1] else "  ")
        print("  y=%+.2f |%s|" % (y, "".join(line)))
    print("          floor is y=0.00 at the top; each column bottoms at %.2f" % PIT)


def top_view():
    print("\ntop view (frame '=' around the opening '.'), 12x12 samples:")
    fr = frame()
    for j in range(12):
        z = -0.5 + (j + 0.5) / 12.0
        row = []
        for i in range(12):
            x = -0.5 + (i + 0.5) / 12.0
            inbar = any(b["x"][0] <= x <= b["x"][1] and b["z"][0] <= z <= b["z"][1]
                        for b in fr.values())
            row.append("=" if inbar else ".")
        print("  " + "".join(row))


if __name__ == "__main__":
    check()
    cross_section()
    top_view()

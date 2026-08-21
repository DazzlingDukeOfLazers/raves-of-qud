#!/usr/bin/env python3
"""Derive a voxel DOOR — frame + hinged leaf — from a door tile's art.

Qud draws a door as one 16x24 sprite with the frame and the leaf both in it. Raves used to extrude
that whole sprite as a single slab, so the frame swung with the leaf and the two were the same
colour, leaving no outline. Daniel: "It's currently a slab. The slab includes the door frame and
the door ... Create a voxel door that opens by rotating in-frame. The door outline should be clear
and distinct."

The art already separates them, by the SAME main/detail split every Qud tile uses -- bright pixels
take the object's main colour, dark ones its detail colour, and `_recolor_rgb` lerps between them by
luminance. On Tiles_sw_door_basic that is exactly:

    frame (bright)  cols 1..14  rows 1..22   two 1px jambs + a stepped arch across rows 1..4
    leaf  (dark)    cols 3..12  rows 5..21
    columns 2 and 13 EMPTY                   the reveal -- the outline, already drawn in

so nothing needs hardcoding per door: classify, then build. What defeated the outline was not the
art but the colours -- this door is color='&y' detail='y', the same value twice, so frame and leaf
render identically. Geometry has to carry the distinction: the leaf is thinner and recessed inside
the frame's depth, which turns the reveal into a real shadow line instead of a colour change.

Run it on a tile to see the model it derives, before trusting the GDScript port:
    python3 tools/capture/door.py Tiles_sw_door_basic.bmp
"""
import os
import sys

TILES = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles")

# Depths in art pixels. The frame is deeper than the leaf, and the leaf is centred in it, so the
# reveal is a real recess on BOTH faces -- that is what makes the outline read without a colour
# difference to lean on.
FRAME_DEPTH_PX = 4.0
LEAF_DEPTH_PX = 2.0


def classify(path):
    """(frame_mask, leaf_mask) as sets of (x, y). Bright = main = frame, dark = detail = leaf."""
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    frame, leaf = set(), set()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 128:
                continue
            lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            (frame if lum >= 0.5 else leaf).add((x, y))
    return frame, leaf, w, h


def runs(mask, y):
    """Horizontal runs [x0, x1] of mask on row y — the frame extrudes as one box per run."""
    xs = sorted(x for (x, yy) in mask if yy == y)
    out = []
    for x in xs:
        if out and x == out[-1][1] + 1:
            out[-1][1] = x
        else:
            out.append([x, x])
    return out


def knob_hi(leaf, lx0, lx1, ly0, ly1):
    """True when the DOORKNOB is on the low-column side, i.e. the hinge goes high.

    The hinge is opposite the knob, and the knob is in the art -- Daniel: "the default art puts the
    doorknob on the right and the hinges on the left." It shows up as a NOTCH, pixels missing from
    the middle of the leaf. Two other kinds of hole share that rect and both must be excluded: the
    ARCH clips the leaf's top corners (holes on both sides, at the top), and the leaf's own edge
    texture gaps its outermost columns. Counting every hole gives centroid 7.14 against a centre of
    7.50 and answers LEFT, which is backwards. Strictly-inside columns, below the top quarter,
    leaves just the notch: cols 10, 11, 11, 11 -> 10.75, comfortably right.

    No knob in the art -> False, i.e. hinge on the left, the convention the art follows.
    """
    if lx1 - lx0 < 3:
        return False
    y_from = ly0 + int(round(0.25 * (ly1 - ly0)))
    holes = [x for y in range(y_from, ly1 + 1) for x in range(lx0 + 1, lx1)
             if (x, y) not in leaf]
    if not holes:
        return False
    return (sum(holes) / len(holes)) < (lx0 + lx1) / 2.0


def _try(frame, leaf, w, h):
    """Build the model for one assignment of the two colour classes, or (None, why)."""
    fx0 = min(x for x, _ in frame); fx1 = max(x for x, _ in frame)
    lx0 = min(x for x, _ in leaf);  lx1 = max(x for x, _ in leaf)
    ly0 = min(y for _, y in leaf);  ly1 = max(y for _, y in leaf)
    # THE LEAF MUST SIT STRICTLY INSIDE THE FRAME'S SPAN, or the classification is not
    # frame-vs-leaf at all and the caller should keep the old slab rather than build nonsense.
    if not (fx0 < lx0 and lx1 < fx1):
        return None, "leaf %d..%d not inside frame %d..%d" % (lx0, lx1, fx0, fx1)
    # A DOOR'S LEAF FILLS MOST OF ITS FRAME. Trying both class assignments (see model) makes
    # containment cheap to satisfy by accident: Creatures_sw_golem_door passes it with a 3x5 "leaf"
    # in the middle of a golem, because SOMETHING is always surrounded by something. A leaf that is
    # a quarter of its frame is a detail in a picture, not a door panel.
    fy0 = min(y for _, y in frame); fy1 = max(y for _, y in frame)
    fw = fx1 - fx0 + 1; fh = fy1 - fy0 + 1
    lw = lx1 - lx0 + 1; lh = ly1 - ly0 + 1
    if lw < 0.5 * fw or lh < 0.5 * fh:
        return None, "leaf %dx%d is too small for a %dx%d frame (%.0f%% x %.0f%%)" % (
            lw, lh, fw, fh, 100.0 * lw / fw, 100.0 * lh / fh)
    # THE FRAME IS THE SURROUND, NOT EVERY BRIGHT PIXEL. Door art highlights the leaf in the main
    # colour too -- a filigree panel is covered in bright detail -- and counting those as frame
    # geometry both litters the frame with floating boxes and trips the overlap check. Frame
    # geometry is the bright pixels OUTSIDE the leaf's rect; the bright pixels inside it are the
    # leaf's own texture and travel with it when it swings.
    inside = lambda x, y: lx0 <= x <= lx1 and ly0 <= y <= ly1
    surround = {(x, y) for (x, y) in frame if not inside(x, y)}
    boxes = [(y, r[0], r[1]) for y in range(h) for r in runs(surround, y)]
    rl = lx0 - fx0 - 1
    rr = fx1 - lx1 - 1
    # A reveal on one side only is not a defect -- a door is hung tight against one jamb and swings
    # clear of the other. Only a door with NO reveal at all has lost its outline.
    return {
        "size": (w, h),
        "frame_boxes": boxes,          # (row, x0, x1) each extruded FRAME_DEPTH_PX deep
        "frame_span": (fx0, fx1),
        "leaf_rect": (lx0, lx1, ly0, ly1),
        "hinge_x": lx1 if knob_hi(leaf, lx0, lx1, ly0, ly1) else lx0,
        "reveal_left": rl,             # empty columns between jamb and leaf
        "reveal_right": rr,
    }, ""


def model(path):
    """Derive the door, trying BOTH assignments of the tile's two colour classes.

    Bright = frame holds for most door art, but not all: terrain_sw_securitydoor draws the frame in
    the DETAIL colour and the leaf in the main one, so a fixed reading rejects it ("leaf 1..14 not
    inside frame 3..12" — the containment failing in the mirror direction is the tell). Which class
    is the frame is not a property of the palette, it is which one SURROUNDS the other, so ask that
    question instead of assuming an answer.
    """
    frame, leaf, w, h = classify(path)
    if not frame or not leaf:
        return None, "no frame/leaf split (single-class art)"
    m, why = _try(frame, leaf, w, h)
    if m is not None:
        return m, ""
    m2, why2 = _try(leaf, frame, w, h)          # inverted art: detail is the frame
    if m2 is not None:
        m2["inverted"] = True
        return m2, ""
    return None, why


def main(argv):
    name = argv[0] if argv else "Tiles_sw_door_basic.bmp"
    path = name if os.path.isabs(name) else os.path.join(TILES, name)
    if not os.path.exists(path):
        sys.exit("no such tile: " + path)
    m, why = model(path)
    print(name)
    if m is None:
        print("  NOT A FRAME+LEAF DOOR: %s  -> caller keeps the flat slab" % why)
        return 0
    w, h = m["size"]
    lx0, lx1, ly0, ly1 = m["leaf_rect"]
    print("  tile %dx%d" % (w, h))
    print("  frame span   cols %d..%d   depth %.0fpx" % (m["frame_span"] + (FRAME_DEPTH_PX,)))
    print("  leaf         cols %d..%d  rows %d..%d   depth %.0fpx (recessed, centred)"
          % (lx0, lx1, ly0, ly1, LEAF_DEPTH_PX))
    print("  reveal       %d px left, %d px right   <- the outline, as a recess not a colour"
          % (m["reveal_left"], m["reveal_right"]))
    print("  hinge        vertical axis at col %d (%s; knob is opposite)"
          % (m["hinge_x"], "right" if m["hinge_x"] == lx1 else "left"))
    print("  frame boxes  %d runs" % len(m["frame_boxes"]))
    # INVARIANTS. Each is a way the derived model could be wrong in a way that still renders.
    fails = []
    if max(m["reveal_left"], m["reveal_right"]) < 1:
        fails.append("no reveal on EITHER side — leaf fills the frame and the outline vanishes")
    if LEAF_DEPTH_PX >= FRAME_DEPTH_PX:
        fails.append("leaf is not thinner than the frame — nothing to recess it into")
    if ly1 - ly0 < 4 or lx1 - lx0 < 2:
        fails.append("leaf is too small to be a door panel")
    occupied = {(x, y) for (y, a, b) in m["frame_boxes"] for x in range(a, b + 1)}
    overlap = occupied & {(x, y) for x in range(lx0, lx1 + 1) for y in range(ly0, ly1 + 1)}
    if overlap:
        fails.append("frame and leaf overlap at %d px — the leaf would clip the frame when it swings"
                     % len(overlap))
    for f in fails:
        print("  FAIL: " + f)
    print("  OK" if not fails else "  -> not usable")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

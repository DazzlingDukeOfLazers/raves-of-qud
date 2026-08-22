#!/usr/bin/env python3
"""Generate a 1-voxel-thick .vox from a door tile, as a starting point for hand-editing.

Daniel, after one hand-authored door was stretched over every design: "generate vox files based on
the door pngs ... I'd rather try a mix of hand+voxel scripting", and "the vox design from the door
pngs would just be 1 voxel thick". So this writes the SHAPE and leaves the depth to the editor.

Output matches the hand-authored file's conventions exactly, so editing feels the same:
  * 16 x 16 x 24, z up, the tile's row r at z = 23 - r
  * two models named "door" (the swinging leaf) and "frame", in the scene graph
  * palette 246/245 frame and its arch, 244/243 leaf and its detail, 255 = Qud's k (#0f3b3a)
  * everything on ONE y layer (y = 8), the middle of the cell

    python3 tools/capture/png2doorvox.py                 # every door tile, skipping any that exist
    python3 tools/capture/png2doorvox.py Tiles_sw_door_basic.bmp
    python3 tools/capture/png2doorvox.py --force         # regenerate, DISCARDING hand edits

WHAT COUNTS AS THE LEAF IS NOT THE DARK COLOUR CLASS. door.py splits frame from leaf by the
main/detail classes, which is right for finding the two PARTS, but a striped door draws its stripes
in the frame's own colour INSIDE the leaf -- classing by colour alone drops them from both models
and punches the pattern out of the door. Here the rule is positional instead: inside the leaf's
box, every OPAQUE pixel is leaf whatever colour it is, and only the TRANSPARENT ones are in
question. Those split the way they always did -- reachable from the box's border means the arch's
curve, which is the frame's; enclosed means one of the door's own holes, like the knob.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import door as doorlib
from PIL import Image

TILES = doorlib.TILES
OUT = os.path.expanduser("~/Library/Application Support/RavesOfQud/vox")
# FOUR COLOURS, SO THE MODEL IS READABLE IN THE EDITOR. One grey for everything made frame and
# leaf indistinguishable the moment they were both on screen -- Daniel: "the doors appear to be
# black-on-black ... perhaps with color?" These are for AUTHORING only; in game a door takes its
# colour from Qud's own art per object (see _vox_model_mesh), so painting here changes nothing that
# ships and everything about whether the thing can be edited.
FRAME_MAIN = (198, 170, 130)     # the frame's own pixels — warm, so it reads against the leaf
FRAME_ARCH = (150, 126, 94)      # the arch curve, derived rather than drawn: darker, so it shows
LEAF_MAIN = (120, 146, 168)      # the panel — cool, the obvious counterpart to a warm frame
LEAF_DETAIL = (176, 199, 216)    # its bright pixels: stripes, mullions, window bars
FIELD = (15, 59, 58)             # Qud's k — "background", the convention the hand file uses
I_FRAME_MAIN, I_FRAME_ARCH, I_LEAF_MAIN, I_LEAF_DETAIL, I_FIELD = 246, 245, 244, 243, 255
Y_LAYER = 8
FORCE = False


def parts(path):
    """({frame_px: idx}, {leaf_px: idx}) keyed by palette index, or (None, why)."""
    m, why = doorlib.model(path)
    if m is None:
        return None, why
    lx0, lx1, ly0, ly1 = m["leaf_rect"]
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    opaque = {(x, y) for y in range(h) for x in range(w) if px[x, y][3] >= 128}
    inside = {(x, y) for y in range(ly0, ly1 + 1) for x in range(lx0, lx1 + 1)}
    # transparent pixels of the box, flood-filled from its border: reachable = arch, else hole
    free = {c for c in inside if c not in opaque}
    stack = [c for c in free if c[0] in (lx0, lx1) or c[1] in (ly0, ly1)]
    arch = set(stack)
    while stack:
        x, y = stack.pop()
        for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if n in free and n not in arch:
                arch.add(n)
                stack.append(n)
    bright = {(x, y) for (x, y) in opaque
              if (0.2126 * px[x, y][0] + 0.7152 * px[x, y][1] + 0.0722 * px[x, y][2]) / 255.0 >= 0.5}
    leaf = {c: (I_LEAF_DETAIL if c in bright else I_LEAF_MAIN) for c in (inside & opaque)}
    frame = {c: I_FRAME_MAIN for c in (opaque - inside)}
    for c in arch:
        frame[c] = I_FRAME_ARCH
    return (frame, leaf), ""


def write_vox(path, models, names):
    """MAIN{ SIZE/XYZI per model, RGBA, nTRN>nGRP>(nTRN>nSHP)* }, version 150.

    The scene graph is what carries the NAMES, and the names are the whole point -- a reader that
    only walks SIZE/XYZI cannot tell the leaf from the frame (see VoxFile.gd, which is what reads
    these back). MagicaVoxel wants a root nTRN over an nGRP, and each child a named nTRN over an
    nSHP; anything flatter opens with the parts unnamed.
    """
    def chunk(cid, content, children=b""):
        return cid + struct.pack("<ii", len(content), len(children)) + content + children

    def s(v):
        b = v.encode("utf-8")
        return struct.pack("<i", len(b)) + b

    def d(pairs):
        out = struct.pack("<i", len(pairs))
        for k, v in pairs:
            out += s(k) + s(v)
        return out

    body = b""
    for vox in models:
        body += chunk(b"SIZE", struct.pack("<iii", 16, 16, 24))
        body += chunk(b"XYZI", struct.pack("<i", len(vox))
                      + b"".join(struct.pack("<BBBB", *v) for v in vox))
    rgba = bytearray()
    for i in range(256):
        # NO OFF-BY-ONE. The spec describes palette index i as RGBA entry i-1, but MagicaVoxel
        # writes it straight: the hand-authored file holds (187,187,187) at array position 246 and
        # its voxels reference 246. Matching the editor beats matching the document, since the
        # editor is what has to reopen these.
        c = {I_FRAME_MAIN: FRAME_MAIN, I_FRAME_ARCH: FRAME_ARCH, I_LEAF_MAIN: LEAF_MAIN,
             I_LEAF_DETAIL: LEAF_DETAIL, I_FIELD: FIELD}.get(i, (0, 0, 0))
        rgba += bytes((c[0], c[1], c[2], 255))
    body += chunk(b"RGBA", bytes(rgba))
    # node ids: 0 root nTRN, 1 nGRP, then per model (2i+2) nTRN, (2i+3) nSHP
    kids = [2 + 2 * i for i in range(len(models))]
    body += chunk(b"nTRN", struct.pack("<i", 0) + d([]) + struct.pack("<iii", 1, -1, -1)
                  + struct.pack("<i", 1) + d([]))
    body += chunk(b"nGRP", struct.pack("<i", 1) + d([]) + struct.pack("<i", len(kids))
                  + b"".join(struct.pack("<i", k) for k in kids))
    for i, name in enumerate(names):
        tid, sid = 2 + 2 * i, 3 + 2 * i
        body += chunk(b"nTRN", struct.pack("<i", tid) + d([("_name", name)])
                      + struct.pack("<iii", sid, -1, -1)
                      + struct.pack("<i", 1) + d([("_t", "0 0 0")]))
        body += chunk(b"nSHP", struct.pack("<i", sid) + d([])
                      + struct.pack("<i", 1) + struct.pack("<i", i) + d([]))
    with open(path, "wb") as f:
        f.write(b"VOX " + struct.pack("<i", 150) + chunk(b"MAIN", b"", body))


def gen(name):
    path = os.path.join(TILES, name)
    got, why = parts(path)
    if got is None:
        return None, why
    frame, leaf = got
    h = Image.open(path).size[1]
    def vox(px_map):
        return [(x, Y_LAYER, h - 1 - y, i) for (x, y), i in sorted(px_map.items())]
    os.makedirs(OUT, exist_ok=True)
    stem = name.rsplit(".", 1)[0]
    for pre in ("Tiles_", "Items_", "terrain_", "Creatures_"):
        if stem.startswith(pre):
            stem = stem[len(pre):]
    out = os.path.join(OUT, "door-%s.vox" % stem)
    # NEVER CLOBBER A HAND-EDITED FILE. These are starting points -- the whole plan is "a mix of
    # hand+voxel scripting" -- so a rerun that quietly overwrote an afternoon's editing would be
    # the worst thing this tool could do. Pass --force when you actually want the shape back.
    if os.path.exists(out) and not FORCE:
        return None, "exists (pass --force to regenerate)"
    write_vox(out, [vox(leaf), vox(frame)], ["door", "frame"])
    return out, "%d leaf + %d frame voxels" % (len(leaf), len(frame))


def main(argv):
    global FORCE
    FORCE = "--force" in argv
    argv = [a for a in argv if a != "--force"]
    names = argv or sorted(n for n in os.listdir(TILES)
                           if "door" in n.lower() and "_open" not in n.lower())
    ok = 0
    for n in names:
        out, msg = gen(n)
        if out is None:
            print("  skip %-38s %s" % (n, msg))
        else:
            ok += 1
            print("  %-38s -> %s  (%s)" % (n, os.path.basename(out), msg))
    print("wrote %d of %d" % (ok, len(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

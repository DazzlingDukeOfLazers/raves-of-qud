#!/usr/bin/env python3
"""Isometric preview of a connector half-panel's VOXEL volume, straight from the art.

Why this exists: the in-game check for a connector family costs a build, a relaunch and
a walk across the zone to wherever that family happens to exist — and for pipes/wires it
may not exist in the save at all. This renders the same solid set `_fence_half_vox`
builds, so the shape can be judged before any of that. It is NOT a renderer: no colours
from the game's recolour path, no lighting. It answers one question — what does the
volume look like.

    python3 tools/capture/voxpreview.py fence_ew wire_ew --out /tmp/prev.png

Mirrors the GDScript rules exactly (see ZoneRenderer._fence_half_vox):
  · the half is 8 art columns, the band is the mask's opaque rows,
  · a block per opaque pixel, FENCE_VOX_D deep,
  · a face only where the neighbour block is absent.
"""
import os
import sys

from PIL import Image, ImageDraw

TILES = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles")
# ZoneRenderer.VOX_CONNECTORS — per family, because a wire is a cable and a fence is not
DEPTHS = {"fence": 2, "pipe": 2, "wire": 1}
DEPTH = 2
CELL = 14          # px per voxel edge in the preview
SHADE = {"top": 0.92, "left": 0.72, "right": 1.00}


def find_tile(stem):
    """Accept `fence_ew` or a full exported filename."""
    for name in os.listdir(TILES):
        if name == stem or name.endswith("_" + stem + ".bmp") or name.endswith("_" + stem + ".png"):
            return os.path.join(TILES, name)
    raise SystemExit("no exported tile matching %r in %s" % (stem, TILES))


def volume(path, right_half=True, depth=DEPTH):
    """The solid set {(a, row, dz): colour}, in the same axes the renderer uses."""
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    op = [[im.getpixel((x, y))[3] >= 128 for x in range(w)] for y in range(h)]
    rows = [y for y in range(h) if any(op[y])]
    if not rows:
        raise SystemExit("%s has no opaque pixels" % path)
    top, bot = rows[0], rows[-1]
    hw = w // 2
    u0 = hw if right_half else 0
    out = {}
    for j in range(top, bot + 1):
        for k in range(hw):
            if not op[j][u0 + k]:
                continue
            px = im.getpixel((u0 + k, j))[:3]
            for dz in range(depth):
                out[(k, j - top, dz)] = px
    return out, hw, bot - top + 1


def render(vol, nx, ny, nz=DEPTH):
    """Painter's-algorithm isometric: back-to-front, three faces per block."""
    ex, ey = CELL, CELL // 2                      # isometric basis
    pad = CELL * 3
    wpx = (nx + nz) * ex + pad * 2
    hpx = (nx + nz) * ey + ny * CELL + pad * 2
    img = Image.new("RGBA", (wpx, hpx), (18, 34, 33, 255))
    dr = ImageDraw.Draw(img)

    def project(a, row, dz):
        # +a to the right-down, +dz to the left-down, +row downward
        sx = pad + (a - dz) * ex + nz * ex
        sy = pad + (a + dz) * ey + row * CELL
        return sx, sy

    def face(pts, col, k):
        c = tuple(min(255, int(v * k)) for v in col)
        dr.polygon(pts, fill=c + (255,), outline=(0, 0, 0, 60))

    order = sorted(vol.keys(), key=lambda v: (v[0] + v[2], v[1], v[2]))
    for key in order:
        a, row, dz = key
        col = vol[key]
        x, y = project(a, row, dz)
        # top face (visible when nothing sits directly above, i.e. row-1 absent)
        if (a, row - 1, dz) not in vol:
            face([(x, y), (x + ex, y + ey), (x, y + 2 * ey), (x - ex, y + ey)], col, SHADE["top"])
        # right face (+a exposed)
        if (a + 1, row, dz) not in vol:
            face([(x + ex, y + ey), (x + ex, y + ey + CELL), (x, y + 2 * ey + CELL),
                  (x, y + 2 * ey)], col, SHADE["right"])
        # left face (+dz exposed, i.e. toward the viewer's left)
        if (a, row, dz + 1) not in vol:
            face([(x - ex, y + ey), (x - ex, y + ey + CELL), (x, y + 2 * ey + CELL),
                  (x, y + 2 * ey)], col, SHADE["left"])
    return img


def pieces(vol):
    """Face-connected components — a wire drawn as a dashed zigzag falls apart into many,
    which is the thing worth knowing BEFORE voxelizing a family."""
    cells = set(vol)
    seen, n = set(), 0
    for c in cells:
        if c in seen:
            continue
        n += 1
        stack = [c]
        while stack:
            p = stack.pop()
            if p in seen:
                continue
            seen.add(p)
            for d in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
                q = (p[0] + d[0], p[1] + d[1], p[2] + d[2])
                if q in cells and q not in seen:
                    stack.append(q)
    return n


def main(argv):
    out = "/tmp/voxpreview.png"
    if "--out" in argv:
        i = argv.index("--out")
        out = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    stems = argv or ["fence_ew"]
    panels = []
    for stem in stems:
        path = find_tile(stem)
        dep = next((v for k, v in DEPTHS.items() if k in stem), DEPTH)
        vol, nx, ny = volume(path, depth=dep)
        print("%-28s depth=%d  %3d voxels  %2d pieces (face-connected)"
              % (stem, dep, len(vol), pieces(vol)))
        panels.append((stem, render(vol, nx, ny, dep)))
    gap = 20
    W = sum(p.width for _, p in panels) + gap * (len(panels) + 1)
    H = max(p.height for _, p in panels) + gap * 2
    sheet = Image.new("RGBA", (W, H), (18, 34, 33, 255))
    x = gap
    for _, p in panels:
        sheet.paste(p, (x, gap), p)
        x += p.width + gap
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1:])

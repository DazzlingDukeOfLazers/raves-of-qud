#!/usr/bin/env python3
"""Prototype and verify the wall voxel height algorithm — in Python, so the
geometry can be checked WITHOUT a Godot screenshot round-trip.

This mirrors ZoneRenderer's `_rank_levels`: recolour a tile (mask black -> main,
white -> detail, transparent -> filled background), rank the resulting colours by
pixel count (commonest = level 0 = base, rarest = tallest), and that rank is each
pixel's voxel height. It then prints the colour->count->level table and an ASCII
height map, and renders a cheap oblique preview PNG so the relief is visible.

    python3 tools/capture/voxel.py wall_brinestalk-10000010
    python3 tools/capture/voxel.py sw_chest --main '#98875f' --detail '#b1c9c3'

The point: if the depth ORDER is wrong (bg not deepest, wrong colour proud), it
shows here, before any GDScript change.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tile import decode, resolve  # noqa: E402

# real Qud palette (measured; see README). k is a dark teal, not black.
PALETTE = {
    "w": (0x98, 0x87, 0x5f), "y": (0xb1, 0xc9, 0xc3), "k": (0x0f, 0x3b, 0x3a),
    "W": (0xcf, 0xc0, 0x41), "g": (0x00, 0x94, 0x03), "b": (0x00, 0x48, 0xbd),
    "r": (0x99, 0x33, 0x26), "K": (0x15, 0x53, 0x52), "Y": (0xff, 0xff, 0xff),
}


def hexrgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def recolour(rows, w, h, ch, main, detail, bg):
    """Match ZoneRenderer._recolor_rgb: black->main, white->detail (lerp by
    luminance), transparent-> filled bg. Returns a per-pixel RGB grid."""
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            px = rows[y][x * ch:x * ch + ch]
            if ch == 4 and px[3] < 128:
                row.append(bg)
            else:
                lum = sum(px[:3]) / 3 / 255.0
                row.append(tuple(round(main[i] + (detail[i] - main[i]) * lum) for i in range(3)))
        out.append(row)
    return out


def rank_levels(grid, w, h):
    counts = {}
    for y in range(h):
        for x in range(w):
            counts[grid[y][x]] = counts.get(grid[y][x], 0) + 1
    order = sorted(counts, key=lambda c: -counts[c])
    level = {c: i for i, c in enumerate(order)}
    lev = [[level[grid[y][x]] for x in range(w)] for y in range(h)]
    return lev, counts, order, level


def ascii_map(lev, w, h):
    print("\nheight map (0 = base/deepest, higher = taller):")
    for y in range(h):
        print("  " + "".join(str(min(lev[y][x], 9)) for x in range(w)))


def oblique_png(grid, lev, w, h, path, step=6, cell=14):
    """Cheap oblique projection: each pixel is a column of height lev*step, drawn
    as a top face + a shaded front face, back-to-front so occlusion is right."""
    pad = 40
    W = w * cell + h * (cell // 2) + pad * 2
    H = h * cell + max(l for r in lev for l in r) * step + cell + pad * 2
    img = [[(30, 32, 40) for _ in range(W)] for _ in range(H)]

    def put(px, py, c):
        if 0 <= px < W and 0 <= py < H:
            img[py][px] = c

    def shade(c, f):
        return tuple(max(0, min(255, round(v * f))) for v in c)

    for y in range(h):                       # back (small y) to front
        for x in range(w):
            c = grid[y][x]
            hgt = lev[y][x] * step
            ox = pad + x * cell + (h - 1 - y) * (cell // 2)
            oy = pad + y * cell - hgt
            for dy in range(cell):           # top face
                for dx in range(cell):
                    put(ox + dx, oy + dy, shade(c, 1.0))
            for dy in range(hgt):            # front face (darker)
                for dx in range(cell):
                    put(ox + dx, oy + cell + dy, shade(c, 0.55))

    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in img)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)
    print(f"\noblique preview -> {path}  ({W}x{H})")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {sys.argv[i][2:]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1)
            if sys.argv[i].startswith("--")}
    if not args:
        sys.exit(__doc__)
    main = hexrgb(opts["main"]) if "main" in opts else PALETTE["w"]
    detail = hexrgb(opts["detail"]) if "detail" in opts else PALETTE["y"]
    bg = hexrgb(opts["bg"]) if "bg" in opts else PALETTE["k"]

    w, h, ch, rows = decode(resolve(args[0]))
    grid = recolour(rows, w, h, ch, main, detail, bg)
    lev, counts, order, level = rank_levels(grid, w, h)

    print(f"{args[0]}  {w}x{h}   main={main} detail={detail} bg={bg}")
    print("\ncolour        count   level (0=base)")
    for c in order:
        tag = "  <- filled bg" if c == bg else ("  <- detail" if c == detail else
              ("  <- main" if c == main else ""))
        print(f"  {('#%02x%02x%02x' % c)}   {counts[c]:<6} {level[c]}{tag}")
    ascii_map(lev, w, h)
    oblique_png(grid, lev, w, h, "/tmp/voxel_preview.png")

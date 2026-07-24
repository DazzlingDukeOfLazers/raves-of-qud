#!/usr/bin/env python3
"""Prototype and verify the wall voxel height algorithm — in Python, so the
geometry can be checked WITHOUT a Godot screenshot round-trip.

This mirrors ZoneRenderer's `_rank_levels`: recolour a tile (mask black -> main,
white -> detail, transparent -> filled background), rank the resulting colours by
pixel count (commonest = level 0 = base, rarest = tallest), and that rank is each
pixel's voxel height, EXCEPT the transparent/background is forced deepest (level 0).
It then prints the colour->count->level table and an ASCII
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


def rank_levels(grid, w, h, bg=None):
    """Transparent/background is forced DEEPEST (level 0); the rest rank above it
    by pixel count. Background is scenery you look past, so it should recess, not
    stand proud just because it's common."""
    counts = {}
    for y in range(h):
        for x in range(w):
            counts[grid[y][x]] = counts.get(grid[y][x], 0) + 1
    rest = sorted((c for c in counts if c != bg), key=lambda c: -counts[c])
    level = {}
    nxt = 0
    if bg in counts:
        level[bg] = 0
        nxt = 1
    for i, c in enumerate(rest):
        level[c] = nxt + i
    order = ([bg] if bg in counts else []) + rest
    lev = [[level[grid[y][x]] for x in range(w)] for y in range(h)]
    return lev, counts, order, level


# Rec.601 relative luminance of an 8-bit RGB tuple, 0..1.
def luma(c):
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255.0


LUMA_FLOOR = 0.30   # non-bg pixels stand at least this proud of the recessed bg
LUMA_GAIN = 2.5     # luminance 1.0 -> this many levels (keeps ~current relief height)


def luma_levels(grid, w, h, bg=None, gamma=1.0):
    """Height follows the art's own light/dark: level = luminance, so highlights
    stand proud and shadows recess — the way the tile artist modelled form. The
    transparent/background is still forced DEEPEST (0). No count-order hack needed:
    bg is the darkest colour, so it recesses by construction, and a mid colour that
    happens to be the commonest no longer floats above the wall body.

    Non-bg pixels get a floor (LUMA_FLOOR) so even the darkest wall pixel stands
    above the recessed bg gaps, preserving the 'wall body over deep gaps' read.

    `gamma` shapes the profile: <1 pushes the bright DETAIL pixels (mortar lines,
    rivets, plant spines) up into sharp proud ridges that catch the sun — the only
    real depth dial 2-bit art allows. gamma=1 is straight luminance."""
    lev = [[0.0] * w for _ in range(h)]
    span = LUMA_GAIN - LUMA_FLOOR
    for y in range(h):
        for x in range(w):
            c = grid[y][x]
            if c == bg:
                lev[y][x] = 0.0
            else:
                lev[y][x] = LUMA_FLOOR + span * (luma(c) ** gamma)
    return lev


def smooth_levels(grid, lev, w, h, passes, bg=None):
    """Box-blur the height field to tame the 1px crosshatch (the dithered art read
    as an egg-crate of alternating pits). Background pixels stay PINNED to 0 — the
    gaps are real recesses, not noise to average away — so the blur only softens the
    relief of the solid wall body."""
    for _ in range(passes):
        nxt = [row[:] for row in lev]
        for y in range(h):
            for x in range(w):
                if grid[y][x] == bg:
                    continue                     # keep gaps at their floor
                s = 0.0
                n = 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and grid[ny][nx] != bg:
                            s += lev[ny][nx]
                            n += 1
                if n:
                    nxt[y][x] = s / n
        lev = nxt
    return lev


def ascii_map(lev, w, h):
    print("\nheight map (0 = base/deepest, digit = round(level)):")
    for y in range(h):
        print("  " + "".join(str(min(int(round(lev[y][x])), 9)) for x in range(w)))


def oblique_png(grid, lev, w, h, path, step=6, cell=14):
    """Cheap oblique projection: each pixel is a column of height lev*step, drawn
    as a top face + a shaded front face, back-to-front so occlusion is right."""
    pad = 40
    W = w * cell + h * (cell // 2) + pad * 2
    H = h * cell + int(round(max(l for r in lev for l in r) * step)) + cell + pad * 2
    img = [[(30, 32, 40) for _ in range(W)] for _ in range(H)]

    def put(px, py, c):
        if 0 <= px < W and 0 <= py < H:
            img[py][px] = c

    def shade(c, f):
        return tuple(max(0, min(255, round(v * f))) for v in c)

    for y in range(h):                       # back (small y) to front
        for x in range(w):
            c = grid[y][x]
            hgt = int(round(lev[y][x] * step))
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

    rule = opts.get("rule", "count")        # count (current) | luma
    passes = int(opts.get("smooth", 0))     # box-blur passes over the height field
    gamma = float(opts.get("gamma", 1.0))   # <1 spikes bright detail (luma rule)

    w, h, ch, rows = decode(resolve(args[0]))
    grid = recolour(rows, w, h, ch, main, detail, bg)

    print(f"{args[0]}  {w}x{h}   main={main} detail={detail} bg={bg}"
          f"   rule={rule} smooth={passes}")
    if rule == "luma":
        lev = luma_levels(grid, w, h, bg, gamma)
        # colour -> level table straight from the (unsmoothed) luminance map
        seen = {}
        for y in range(h):
            for x in range(w):
                seen[grid[y][x]] = lev[y][x]
        order = sorted(seen, key=lambda c: seen[c])
        print("\ncolour        luma    level (0=base)")
        for c in order:
            tag = "  <- filled bg" if c == bg else ("  <- detail" if c == detail else
                  ("  <- main" if c == main else ""))
            print(f"  {('#%02x%02x%02x' % c)}   {luma(c):.3f}   {seen[c]:.3f}{tag}")
    else:
        lev, counts, order, level = rank_levels(grid, w, h, bg)
        print("\ncolour        count   level (0=base)")
        for c in order:
            tag = "  <- filled bg" if c == bg else ("  <- detail" if c == detail else
                  ("  <- main" if c == main else ""))
            print(f"  {('#%02x%02x%02x' % c)}   {counts[c]:<6} {level[c]}{tag}")

    if passes:
        lev = smooth_levels(grid, lev, w, h, passes, bg)
    ascii_map(lev, w, h)
    oblique_png(grid, lev, w, h, "/tmp/voxel_preview.png")

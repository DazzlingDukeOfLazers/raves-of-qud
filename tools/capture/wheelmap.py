#!/usr/bin/env python3
"""Derive and PREVIEW the waterwheel's two UV maps — the tread (side) and the end (face).

Daniel: "The waterwheel is a cylinder with the faces going east-west ... rather than try and do
a pixel-perfect match, let's try and make the UV map for the sides and faces. Put them
side-by-side until we have them nailed."

Why a tool and not a build: the maps are pixel algorithms, and the repo rule is to settle those
in Python first (docs/tools.md). One run gives a sheet you can judge; a build gives a screenshot
of a wheel that may be edge-on to the camera anyway.

    python3 tools/capture/wheelmap.py                  # sheet for all three frames
    python3 tools/capture/wheelmap.py --paddles 12 --thick 8

WHAT THE ART ACTUALLY IS (measured, see the module doc in the sheet header):
The tile is the wheel seen EDGE-ON with its axis east-west, which is the orientation the mill
demands — the E-W axle run at (3,7)..(5,7) ends at the wheel's cell (6,7), and a wheel drives
the axle along its own axis. Reading the columns settles the split:

    cols 1..8    wood only, no detail pixels      -> the WHEEL, 8px = 0.5 cell thick
    cols 9..12   every detail (water) pixel       -> water falling off the east side
    cols 13..14  wood only                        -> the far frame/sluice edge

and the wood pattern in cols 1..8 TRANSLATES vertically between frames (period 5-6 rows by
autocorrelation) rather than rotating about a centre. Vertical translation is what an edge-on
wheel does; a face-on wheel would rotate. So the art gives us the TREAD directly and says
nothing at all about the END — which is why the face below is synthesized from the tread's own
colours and paddle count rather than resampled from the tile.
"""
import argparse
import math
import os
import sys

from PIL import Image

TILES = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles")
WHEEL_COLS = (1, 9)        # [lo, hi) — wood-only columns; the wheel itself
BG = (24, 26, 26)
WOOD = (150, 110, 60)      # preview stand-ins; the renderer recolours from the wire
WATER = (90, 190, 230)
DARK = (36, 30, 22)


def load(frame):
    p = os.path.join(TILES, "Items_sw_waterwheel_%d.bmp" % frame)
    if not os.path.exists(p):
        raise SystemExit("no exported tile at %s — run the tile export first" % p)
    return Image.open(p).convert("RGBA")


def band(im):
    """The opaque rows of the wheel columns: the diameter, in art rows."""
    rows = [y for y in range(im.size[1])
            if any(im.getpixel((x, y))[3] >= 128 for x in range(*WHEEL_COLS))]
    return rows[0], rows[-1]


def paddle_period(im, top, bot):
    """Vertical repeat of the tread pattern, by autocorrelation over the wheel columns."""
    w0, w1 = WHEEL_COLS
    rows = [tuple(1 if im.getpixel((x, y))[3] >= 128 else 0 for x in range(w0, w1))
            for y in range(im.size[1])]
    best, blag = -1.0, 6
    for lag in range(3, 12):
        n = bot - lag - top
        if n <= 4:
            break
        hit = sum(1 for y in range(top, top + n) for i in range(w1 - w0)
                  if rows[y][i] == rows[y + lag][i])
        s = hit / float(n * (w1 - w0))
        if s > best:
            best, blag = s, lag
    return blag, best


def tread_profile(im, top, period):
    """ONE paddle's cross-section, lifted from the art: period rows x thickness columns.

    Taken from the middle of the band, where the art draws the paddles most cleanly — the
    rounded ends of the silhouette clip them top and bot.
    """
    w0, w1 = WHEEL_COLS
    y0 = top + (im.size[1] - 2 * top) // 2 - period // 2
    out = []
    for dy in range(period):
        row = []
        for x in range(w0, w1):
            px = im.getpixel((x, y0 + dy))
            row.append(WOOD if px[3] >= 128 else DARK)
        out.append(row)
    return out


def side_map(profile, paddles, samples):
    """The TREAD, unwrapped: circumference across, thickness down. Tiles by construction —
    the paddle profile is repeated `paddles` times around, so the seam at 0/2pi is exact."""
    period = len(profile)
    thick = len(profile[0])
    im = Image.new("RGB", (samples, thick), BG)
    for u in range(samples):
        # which row of which paddle this angle lands on
        t = (u / float(samples)) * paddles * period
        src = profile[int(t) % period]
        for v in range(thick):
            im.putpixel((u, v), src[v])
    return im


def face_map(profile, paddles, size):
    """The END CAP. NOT in the art — the tile is edge-on — so it is built from what the tread
    does know: `paddles` spokes at the rim, the tread's own wood colour, a hub at the centre.
    This is the half of the pair that is a PROPOSAL, and the one to argue with first."""
    im = Image.new("RGB", (size, size), BG)
    c = (size - 1) / 2.0
    rim = size * 0.5
    hub = size * 0.16
    for y in range(size):
        for x in range(size):
            dx, dy = x - c, y - c
            d = math.hypot(dx, dy)
            if d > rim:
                continue
            a = (math.atan2(dy, dx) + math.pi) / (2 * math.pi)
            spoke = (a * paddles) % 1.0
            if d < hub:
                im.putpixel((x, y), WOOD)                      # hub
            elif d > rim * 0.86:
                im.putpixel((x, y), WOOD)                      # rim band
            elif spoke < 0.30:
                im.putpixel((x, y), WOOD)                      # spoke
            else:
                im.putpixel((x, y), DARK)                      # open between spokes
    return im


def art_preview(im, zoom):
    p = Image.new("RGB", im.size, BG)
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            px = im.getpixel((x, y))
            if px[3] < 128:
                continue
            p.putpixel((x, y), WOOD if px[0] < 128 else WATER)
    return p.resize((im.size[0] * zoom, im.size[1] * zoom), Image.NEAREST)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", default="1,2,3")
    ap.add_argument("--paddles", type=int, default=0, help="0 = derive from the art's period")
    ap.add_argument("--samples", type=int, default=96, help="circumference samples in the tread map")
    ap.add_argument("--face", type=int, default=48, help="face map size in px")
    ap.add_argument("--zoom", type=int, default=10)
    ap.add_argument("--out", default="/tmp/wheelmap.png")
    a = ap.parse_args(argv)

    frames = [int(f) for f in a.frames.split(",")]
    # ONE paddle count for the whole family. Per-frame autocorrelation disagrees (6/5/6 rows
    # here), and a wheel that changes its paddle count between frames would pop — the frames
    # are three ROTATIONAL PHASES of one wheel, not three different wheels. Consensus = the
    # most common period, ties broken by the best fit.
    reads = []
    for f in frames:
        im = load(f)
        top, bot = band(im)
        period, score = paddle_period(im, top, bot)
        reads.append((f, im, top, bot, period, score))
    votes = {}
    for _, _, _, _, period, score in reads:
        votes[period] = votes.get(period, (0, 0.0))
        votes[period] = (votes[period][0] + 1, votes[period][1] + score)
    canon_period = sorted(votes.items(), key=lambda kv: (kv[1][0], kv[1][1]))[-1][0]
    diameter = reads[0][3] - reads[0][2] + 1
    paddles = a.paddles or max(3, int(round(math.pi * diameter / float(canon_period))))
    for f, _, top, bot, period, score in reads:
        print("frame %d: band rows %d..%d (d=%d art px)  period %d rows (fit %.2f)"
              % (f, top, bot, bot - top + 1, period, score))
    print("consensus period %d rows -> %d paddles%s   (thickness %d art px = %.2f cell)"
          % (canon_period, paddles, "" if a.paddles else " derived", WHEEL_COLS[1] - WHEEL_COLS[0],
             (WHEEL_COLS[1] - WHEEL_COLS[0]) / 16.0))
    # ONE map pair, not three: the cylinder ROTATES, the way the shafts do, so the art's three
    # phases are something the geometry produces rather than something it needs textures for.
    canon = reads[0]
    prof = tread_profile(canon[1], canon[2], canon_period)
    side = side_map(prof, paddles, a.samples)
    face = face_map(prof, paddles, a.face)
    panels = [(art_preview(im, a.zoom), side if i == 0 else None, face if i == 0 else None)
              for i, (f, im, top, bot, period, score) in enumerate(reads)]

    zh = max(p[0].size[1] for p in panels)
    sw = a.samples * 4
    fw = a.face * 4
    pad = 16
    W = panels[0][0].size[0] + sw + fw + pad * 4
    H = (zh + pad) * len(panels) + pad
    sheet = Image.new("RGB", (W, H), (14, 16, 16))
    for i, (art, side, face) in enumerate(panels):
        y = pad + i * (zh + pad)
        sheet.paste(art, (pad, y))
        x = pad * 2 + art.size[0]
        if side is not None:
            sheet.paste(side.resize((sw, side.size[1] * 12), Image.NEAREST), (x, y + zh // 3))
            sheet.paste(face.resize((fw, fw), Image.NEAREST), (x + sw + pad, y))
    sheet.save(a.out)
    print("\nleft = art (edge-on, wood + water) | middle = TREAD unwrapped | right = END cap")
    print("wrote %s" % a.out)


if __name__ == "__main__":
    main(sys.argv[1:])

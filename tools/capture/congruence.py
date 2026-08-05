#!/usr/bin/env python3
"""Stage-cell pixel congruence — the scoring half of the Object Checker
(docs/pc-test-rig.md rung 3). Given the same-turn Qud/Raves capture pair for a
staged element, crop THE STAGE CELL from both and score them with the parity
metrics the menu work standardised (mean |Δ| per channel, % pixels with any
channel Δ>32; playfield reference ≈ 2 / 0%), plus the strict checks that caught
real bugs: dominant-colour-vs-wire and pure-white pixel parity.

GEOMETRY comes from fixtures/checker_geometry.json, CALIBRATED — never hand
measured: stage two different full-tile walls, capture each app twice, and the
densest cluster of changed pixels in an app's own A/B pair IS the stage cell
rect (walls fill their 16×24 tile; UI noise like the message log is sparse and
off-centre). `checker.py calibrate` drives that flow.

Decoding: Pillow when available (this box has it via highvisor), else the
repo's pure-stdlib decoder (tile.py) — slower (~15s/frame) but dependency-free,
per the repo rule. Sweeps with --diff are background-length either way.
"""
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GEOMETRY = os.path.join(REPO, "fixtures", "checker_geometry.json")

# Metric thresholds, from the menu-parity scoreboard's families: the converged
# screens live at mean 2-5; a busted cell (wrong art, missing element) lands
# way above. Generous to start — tighten as real sweep data accumulates.
PASS_MEAN = 12.0
WARN_MEAN = 25.0
SAMPLE_W, SAMPLE_H = 32, 48   # common grid both crops are resampled to (16x24 aspect)


# ---------------------------------------------------------------- image loading

def load_rgb(path):
    """(w, h, get(x,y)->(r,g,b)) — Pillow fast-path, tile.py fallback."""
    try:
        from PIL import Image
        im = Image.open(path).convert("RGB")
        px = im.load()
        return im.width, im.height, lambda x, y: px[x, y]
    except ImportError:
        import tile
        w, h, ch, rows = tile.decode(path)
        if ch < 3:
            raise ValueError("%s: need RGB(A), got %d channel(s)" % (path, ch))

        def get(x, y, _rows=rows, _ch=ch):
            o = x * _ch
            r = _rows[y]
            return (r[o], r[o + 1], r[o + 2])
        return w, h, get


# ---------------------------------------------------------------- geometry

def load_geometry():
    try:
        with open(GEOMETRY) as f:
            data = json.load(f)
    except OSError:
        sys.exit("no %s — run `checker.py calibrate` first (Qud+Raves up, in-game)" % GEOMETRY)
    g = data.get(sys.platform)
    if not g:
        sys.exit("no %r geometry in %s — run `checker.py calibrate` on this box" % (sys.platform, GEOMETRY))
    return g


def save_geometry(qud_rect, raves_rect):
    """Store the calibrated STAGE-CELL rects per platform (window geometry is
    fixed in the rig, so the one cell rect is all the crop needs)."""
    data = {}
    if os.path.exists(GEOMETRY):
        try:
            data = json.load(open(GEOMETRY))
        except ValueError:
            data = {}
    data[sys.platform] = {"qud": qud_rect, "raves": raves_rect}
    os.makedirs(os.path.dirname(GEOMETRY), exist_ok=True)
    json.dump(data, open(GEOMETRY, "w"), indent=1)
    return GEOMETRY


# ---------------------------------------------------------------- calibration

def diff_cluster(path_a, path_b, min_delta=40, search_frac=0.72):
    """The stage-cell rect from an A/B pair of one app's captures: bounding box
    of the DENSEST compact cluster of changed pixels. Grid-based: count changed
    pixels per 8x8 tile, pick the hottest tile, flood out while neighbours stay
    hot, return the cluster's pixel bbox.

    `search_frac` clips the search to the left fraction of the frame: BOTH apps
    keep element-reactive panels on the right (Nearby objects renders the staged
    element's sprite, bigger than the playfield cell — it won the first
    calibration run). Measured: Qud's player-centred viewport puts the stage
    cell ≈61% across with its sidebar from ≈73%; Raves' 1:1 playfield ends
    ≈49% with panels from ≈86%. 0.72 keeps both cells, excludes both panels."""
    wa, ha, ga = load_rgb(path_a)
    wb, hb, gb = load_rgb(path_b)
    w, h = min(wa, wb), min(ha, hb)
    w = int(w * search_frac)
    t = 8
    gw, gh = w // t, h // t
    heat = [[0] * gw for _ in range(gh)]
    for gy in range(gh):
        for gx in range(gw):
            n = 0
            for yy in range(gy * t, gy * t + t, 2):        # sample every 2px — enough
                for xx in range(gx * t, gx * t + t, 2):
                    a = ga(xx, yy)
                    b = gb(xx, yy)
                    if abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > min_delta:
                        n += 1
            heat[gy][gx] = n
    # hottest tile = seed; flood to 4-neighbours carrying ANY heat (>=1 changed
    # sample). Contiguity does the noise rejection — ambient sparkle isn't
    # attached to the element's cluster — and a stricter floor undershoots
    # small/dim cells (Qud's zoomed-out stage caught only the sprite's hottest
    # band, which then misaligned the resampled comparison).
    sy, sx = max(((y, x) for y in range(gh) for x in range(gw)), key=lambda p: heat[p[0]][p[1]])
    if heat[sy][sx] == 0:
        raise ValueError("no changed pixels between %s and %s" % (path_a, path_b))
    floor_heat = 1
    seen, stack = set(), [(sy, sx)]
    while stack:
        y, x = stack.pop()
        if (y, x) in seen or not (0 <= y < gh and 0 <= x < gw) or heat[y][x] < floor_heat:
            continue
        seen.add((y, x))
        stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
    xs = [x for _, x in seen]
    ys = [y for y, _ in seen]
    coarse = {"x": min(xs) * t, "y": min(ys) * t,
              "w": (max(xs) - min(xs) + 1) * t, "h": (max(ys) - min(ys) + 1) * t}

    # Refine to the EXACT changed-pixel bbox: the 8px grid quantizes each edge
    # by up to a tile, and a rect a few px off the true cell is invisible on
    # wall scores (wall overlaps wall) but poisons sparse sprites — furniture
    # scored 301 FAILs off a ~10px-left Raves rect before this pass existed.
    x0 = max(0, coarse["x"] - t)
    y0 = max(0, coarse["y"] - t)
    x1 = min(w - 1, coarse["x"] + coarse["w"] + t)
    y1 = min(h - 1, coarse["y"] + coarse["h"] + t)
    fx0, fy0, fx1, fy1 = x1, y1, x0, y0
    for yy in range(y0, y1 + 1):
        for xx in range(x0, x1 + 1):
            a = ga(xx, yy)
            b = gb(xx, yy)
            if abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > min_delta:
                if xx < fx0: fx0 = xx
                if xx > fx1: fx1 = xx
                if yy < fy0: fy0 = yy
                if yy > fy1: fy1 = yy
    if fx1 < fx0:
        return coarse
    return {"x": fx0, "y": fy0, "w": fx1 - fx0 + 1, "h": fy1 - fy0 + 1}


# ---------------------------------------------------------------- scoring

def _sample(path, rect):
    """The rect resampled (nearest) to the common grid, as a flat RGB list."""
    w, h, get = load_rgb(path)
    out = []
    for j in range(SAMPLE_H):
        y = min(h - 1, rect["y"] + int((j + 0.5) * rect["h"] / SAMPLE_H))
        for i in range(SAMPLE_W):
            x = min(w - 1, rect["x"] + int((i + 0.5) * rect["w"] / SAMPLE_W))
            out.append(get(x, y))
    return out


def _dominant(px):
    """Most common colour quantized to 32-steps, ignoring near-black floor."""
    from collections import Counter
    c = Counter((r // 32, g // 32, b // 32) for r, g, b in px if r + g + b > 60)
    if not c:
        return None
    q = c.most_common(1)[0][0]
    return (q[0] * 32 + 16, q[1] * 32 + 16, q[2] * 32 + 16)


def score(qud_png, raves_png, geom, wire_color_hex=None):
    """The congruence verdict for one element's pair. Returns a dict with the
    metrics + strict-check results; `band` is PASS/WARN/FAIL by mean |Δ|."""
    a = _sample(qud_png, geom["qud"])
    b = _sample(raves_png, geom["raves"])
    n = len(a)
    tot = 0
    hot = 0
    for (ar, ag, ab_), (br, bg, bb) in zip(a, b):
        d = abs(ar - br) + abs(ag - bg) + abs(ab_ - bb)
        tot += d
        if max(abs(ar - br), abs(ag - bg), abs(ab_ - bb)) > 32:
            hot += 1
    mean = tot / (3.0 * n)
    pct_hot = 100.0 * hot / n

    # strict: pure-white parity (glyph/detail pixels are exactly white in both)
    wa = sum(1 for p in a if p == (255, 255, 255))
    wb = sum(1 for p in b if p == (255, 255, 255))

    # strict: dominant colour vs each other (and vs the wire when given)
    da, db = _dominant(a), _dominant(b)
    dom_delta = None
    if da and db:
        dom_delta = max(abs(da[i] - db[i]) for i in range(3))
    wire_delta = None
    if wire_color_hex and db:
        try:
            wr, wg, wb_ = (int(wire_color_hex[i:i + 2], 16) for i in (0, 2, 4))
            wire_delta = max(abs(db[0] - wr), abs(db[1] - wg), abs(db[2] - wb_))
        except ValueError:
            pass

    band = "PASS" if mean <= PASS_MEAN else ("WARN" if mean <= WARN_MEAN else "FAIL")
    return {"mean_abs_diff": round(mean, 2), "pct_hot": round(pct_hot, 1), "band": band,
            "white_px": [wa, wb], "dominant_delta": dom_delta, "wire_delta": wire_delta}


# ---------------------------------------------------------------- animation states

def state_fingerprint(path, rect):
    """A stable fingerprint of the stage-cell crop for distinct-STATE counting
    (rung 4): resample to the common grid, quantize hard (//32) so AA/dither
    noise doesn't mint phantom states, hash. Animation frames differ by whole
    colour bands, which survives the quantize; single-pixel shimmer doesn't."""
    import hashlib
    px = _sample(path, rect)
    q = bytes(v // 32 for p in px for v in p)
    return hashlib.md5(q).hexdigest()[:12]

def save_crop(src_png, rect, out_png, scale=4):
    """Write the crop (nearest-upscaled) as a small PNG — the contact-sheet cell."""
    w, h, get = load_rgb(src_png)
    cw, chh = rect["w"] * scale, rect["h"] * scale
    raw = bytearray()
    for j in range(chh):
        raw.append(0)   # filter 0
        y = min(h - 1, rect["y"] + j // scale)
        for i in range(cw):
            x = min(w - 1, rect["x"] + i // scale)
            raw += bytes(get(x, y))

    def chunk(typ, payload):
        c = typ + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", cw, chh, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
           + chunk(b"IEND", b""))
    with open(out_png, "wb") as f:
        f.write(png)
    return out_png

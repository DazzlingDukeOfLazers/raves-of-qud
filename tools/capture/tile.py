#!/usr/bin/env python3
"""Inspect an exported Qud tile PNG without Pillow (pure-stdlib decoder).

Tile geometry has driven several rendering decisions — the 16x24 split, the
opaque-row band that seats fences on the ground, the discovery that bridge art
is line-work on a transparent field. This makes that inspectable in one command.

    python3 tools/capture/tile.py Tiles_sw_floor_brickb3.bmp
    python3 tools/capture/tile.py --list water
    python3 tools/capture/tile.py 'Liquids/Water/deep-11111111.png'   # path ok

Legend:  '#' opaque dark (-> TileColor)   'o' opaque light (-> DetailColor)
         '.' transparent (-> cell background, or fill colour for decks/walls)
"""
import os
import struct
import sys
import zlib

TILES = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles")


def decode(path):
    """Minimal PNG reader -> (w, h, channels, rows[bytes]). Handles filters 0-4."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG (Qud names some PNGs .bmp)")
    i, idat, w, h, ctype = 8, b"", 0, 0, 0
    while i < len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ, chunk = data[i + 4:i + 8], data[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            w, h, _bd, ctype = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw, stride, rows = zlib.decompress(idat), w * ch, []
    prev, k = bytearray(stride), 0
    for _ in range(h):
        f = raw[k]; k += 1
        line = bytearray(raw[k:k + stride]); k += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:   line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, ch, rows


def resolve(name):
    """Accept a tile path, an exported filename, or a bare name."""
    fname = name.replace("/", "_").replace("\\", "_").replace(":", "_")
    for cand in (os.path.join(TILES, fname), name):
        if os.path.isfile(cand):
            return cand
    matches = [f for f in os.listdir(TILES) if name.lower() in f.lower()]
    if len(matches) == 1:
        return os.path.join(TILES, matches[0])
    if matches:
        sys.exit("ambiguous — %d matches:\n  %s" % (len(matches), "\n  ".join(sorted(matches)[:20])))
    sys.exit(f"no exported tile matching {name!r} in {TILES}\n"
             "(tiles export on sight — walk past it in-game first)")


def show(path):
    w, h, ch, rows = decode(path)
    print(f"{os.path.basename(path)}   {w}x{h}  channels={ch}")
    opaque = []
    for y in range(h):
        r, line = rows[y], []
        solid = False
        for x in range(w):
            px = r[x * ch:x * ch + ch]
            if ch == 4 and px[3] < 128:
                line.append(".")
            else:
                solid = True
                line.append("#" if sum(px[:3]) / 3 < 128 else "o")
        if solid:
            opaque.append(y)
        print(f"  {y:>3} {''.join(line)}")
    total = w * h
    clear = sum(1 for y in range(h) for x in range(w)
                if ch == 4 and rows[y][x * ch + 3] < 128)
    print(f"\n  opaque rows {opaque[0]}..{opaque[-1]} of {h}" if opaque else "\n  fully transparent")
    print(f"  transparent pixels {clear}/{total} ({100 * clear // total}%)"
          f"{'  <- line-art: needs fill to hide what is beneath' if clear > total // 2 else ''}")
    if h == 24 and w == 16:
        print("  16x24 wall/floor geometry: rows 0..15 = top-down body, 16..23 = south front-face")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    if args[0] == "--list":
        pat = args[1].lower() if len(args) > 1 else ""
        all_names = os.listdir(TILES)
        # Match the meaningful tail, not the boilerplate path prefix — otherwise
        # "tent" matches every Assets_CONTENT_Textures_* tile in the directory.
        names = sorted(f for f in all_names
                       if pat in f.lower().replace("assets_content_textures_", ""))
        print(f"{len(names)} tile(s) matching {pat!r} of {len(all_names)} exported:")
        for n in names[:200]:
            print("  " + n)
    else:
        show(resolve(args[0]))

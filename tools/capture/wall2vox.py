#!/usr/bin/env python3
"""Export a wall variant's derived voxel volume as a MagicaVoxel .vox file.

The bridge from the game's band-driven walls to free voxel tooling: the
volume is built by voxwall.py's builder (the proof-harness mirror of
ZoneRenderer._wall_cell_mesh) from CUSTOM art first — as-authored polychrome,
canonical 14-cap/10-face split, `_cap_variant` cardinal fallback — so what
lands in the .vox is what the game carves. Open the file in MagicaVoxel or
vengi, or load it in the Godot editor via the vendored Voxel-Core plugin
(`VoxReader.read_file`).

    python3 tools/capture/wall2vox.py 00100010            # one variant
    python3 tools/capture/wall2vox.py --family wall_metal # all customs

Output: <support>/vox/<family>-<bits>.vox — a Qud-art derivative, NEVER
committed (same rule as tiles_custom). Colours: cap layer wears the cap art
(ring columns included), lower rows wear the nearest exposed face art,
interior falls back to the wall main red. One voxel per art pixel per band
row: the .vox is squatter than the in-game wall (rows are ~1.75x taller than
they are wide there); edit shape and colour, not proportions.

Round-trip note: pair with a future vox2wall importer; until then this is a
one-way export for sculpting reference and editing experiments.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import voxwall
from PIL import Image

CUSTOM = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles_custom")
OUT = os.path.expanduser("~/Library/Application Support/RavesOfQud/vox")
MAIN = (166, 74, 46)
WALL_FACE_ROWS = 10


def custom_art(family, bits):
    """voxwall art dict from a CUSTOM file (as-authored, canonical split),
    with the renderer's _cap_variant cardinal fallback; None if no custom."""
    base = {"wall_metal": "Assets_Content_Textures_Tiles_wall_metal"}[family]
    for cand in (bits, "".join(b if i % 2 == 0 else "0" for i, b in enumerate(bits))):
        p = f"{CUSTOM}/{base}-{cand}.bmp"
        if os.path.exists(p):
            im = Image.open(p).convert("RGBA")
            w, h = im.size
            split = max(1, h - WALL_FACE_ROWS)
            px = [[im.getpixel((x, y)) for x in range(w)] for y in range(h)]
            gap = lambda p: p[3] < 128
            col = lambda p: p[:3] if p[3] >= 128 else voxwall.WORLD_BG
            return {
                "w": w,
                "cap": [[gap(px[y][x]) for x in range(w)] for y in range(split)],
                "capcol": [[col(px[y][x]) for x in range(w)] for y in range(split)],
                "face": [[gap(px[y][x]) for x in range(w)] for y in range(split, h)],
                "facecol": [[col(px[y][x]) for x in range(w)] for y in range(split, h)],
            }
    return None


def variant_fn(family):
    stock = voxwall.family_tiles(family)

    def vt(bits):
        return custom_art(family, bits) or stock(bits)

    return vt


def cells_for_bits(bits):
    """Neighbour layout reproducing an exact 8-bit variant name."""
    cells = {(0, 0): "wall_metal"}
    for i, b in enumerate(bits):
        if b == "1":
            cells[voxwall.OFFS[i]] = "wall_metal"
    return cells


def voxel_colors(v, art, farts):
    """(x, z, r) -> rgb for every solid voxel."""
    W = v.W
    R = v.R
    caph = len(art["cap"])
    out = {}
    for r in range(R):
        for z in range(W):
            for x in range(W):
                if not v.solid[r][z][x]:
                    continue
                if r == 0:
                    out[(x, z, r)] = art["capcol"][voxwall.cap_az(z, caph, W)][x]
                    continue
                c = MAIN
                for d, fa in farts.items():
                    if fa is None:
                        continue
                    edge = {"s": z == W - 1, "n": z == 0,
                            "e": x == W - 1, "w": x == 0}[d]
                    if not edge:
                        continue
                    fr = min(len(fa["facecol"]) - 1, r - 1)
                    ax = x if d in ("s", "n") else z
                    c = fa["facecol"][fr][ax]
                    break
                out[(x, z, r)] = c
    return out


def write_vox(path, dims, colors):
    """Minimal MagicaVoxel writer: MAIN{SIZE, XYZI, RGBA}, version 150.
    z-up: our row 0 (the cap) becomes the TOP slab."""
    W, D, R = dims
    palette = []
    index = {}
    voxels = []
    for (x, z, r), rgb in sorted(colors.items()):
        if rgb not in index:
            palette.append(rgb)
            index[rgb] = len(palette)  # 1-based
            assert len(palette) <= 255, "palette overflow"
        voxels.append((x, z, R - 1 - r, index[rgb]))

    def chunk(cid, content, children=b""):
        return cid + struct.pack("<ii", len(content), len(children)) + content + children

    size = chunk(b"SIZE", struct.pack("<iii", W, D, R))
    xyzi = chunk(b"XYZI", struct.pack("<i", len(voxels)) +
                 b"".join(struct.pack("<BBBB", *v) for v in voxels))
    rgba = bytearray()
    for i in range(256):
        rgb = palette[i] if i < len(palette) else (0, 0, 0)
        rgba += bytes((rgb[0], rgb[1], rgb[2], 255))
    pal = chunk(b"RGBA", bytes(rgba))
    main = chunk(b"MAIN", b"", size + xyzi + pal)
    with open(path, "wb") as f:
        f.write(b"VOX " + struct.pack("<i", 150) + main)
    return len(voxels), len(palette)


def export(family, bits):
    vt = variant_fn(family)
    cells = cells_for_bits(bits)
    v, _expo, farts, cap_art = voxwall.build_cell(vt, cells, (0, 0), family)
    colors = voxel_colors(v, cap_art, farts)
    os.makedirs(OUT, exist_ok=True)
    path = f"{OUT}/{family}-{bits}.vox"
    n, pal = write_vox(path, (v.W, v.W, v.R), colors)
    print(f"{path}  {n} voxels, {pal} colours, {v.W}x{v.W}x{v.R}")
    return path


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--family" in sys.argv:
        fam = args[0] if args else "wall_metal"
        base = {"wall_metal": "Assets_Content_Textures_Tiles_wall_metal"}[fam]
        seen = set()
        for f in sorted(os.listdir(CUSTOM)):
            if f.startswith(base + "-") and f.endswith(".bmp"):
                bits = f[len(base) + 1:-4]
                if bits not in seen:
                    seen.add(bits)
                    export(fam, bits)
        return
    if not args:
        sys.exit("usage: wall2vox.py <bits> | --family wall_metal")
    export("wall_metal", args[0])


if __name__ == "__main__":
    main()

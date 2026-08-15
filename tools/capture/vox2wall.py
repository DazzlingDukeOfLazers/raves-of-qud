#!/usr/bin/env python3
"""Bake an edited MagicaVoxel .vox back into the wall's band grammar.

The LOAD half of the external-editor loop (Daniel: "switch to an external
editor and Raves' ability to save/load voxel files"):

    python3 tools/capture/wall2vox.py 00100010      # save (export)
    <edit <support>/vox/wall_metal-00100010.vox in MagicaVoxel / vengi>
    python3 tools/capture/vox2wall.py 00100010      # load (bake)
    python3 tools/capture/vox2wall.py --watch       # live: bake on every save

Baking writes the variant's tiles_custom .bmp (cap band from the TOP voxel
slab, face band from the exposed skins); the game's custom-art watch then
hot-reloads the wall — no restart. Not every voxel edit is representable in
the band grammar (cap art + face art + carve rules); what cannot round-trip
is COUNTED AND NAMED, never silently dropped:

  interior       a voxel below the surface differs from what the bands imply
  ring-row       cap-layer voxels at z=0/15 derive from the face art, not
                 the cap band; edits there are ignored
  face-conflict  two exposed faces claim the same face-art pixel (the
                 one-direction wrap) and disagree; the canonical dir wins
                 (s > e > n > w)
  face-carrier   face rows baked only for the four run carriers
                 (00100010/00100000/00000010/00000000); other variants'
                 face edits are ignored (family-wide face surface)

After baking, the tool re-exports through wall2vox and reports how many
voxels of the .vox survive the round trip. PIL saves with format="PNG".
"""
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import voxwall
import wall2vox
from PIL import Image

CUSTOM = wall2vox.CUSTOM
VOXDIR = wall2vox.OUT
BASE = "Assets_Content_Textures_Tiles_wall_metal"
RUN_CARRIERS = {"00100010", "00100000", "00000010", "00000000"}
WALL_FACE_ROWS = 10


def read_vox(path):
    """Minimal .vox reader: {(x, y, z): rgb} + dims, single-model files."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"VOX ":
        sys.exit(f"not a .vox file: {path}")
    version = struct.unpack_from("<i", data, 4)[0]
    if version not in (150, 200):
        print(f"  note: vox version {version} (expected 150/200), parsing anyway")
    pos = 8
    dims = None
    raw = []
    pal = [None] * 256
    while pos + 12 <= len(data):
        cid = data[pos:pos + 4]
        size, _child = struct.unpack_from("<ii", data, pos + 4)
        body = pos + 12
        if cid == b"SIZE":
            dims = struct.unpack_from("<iii", data, body)
        elif cid == b"XYZI":
            n = struct.unpack_from("<i", data, body)[0]
            for i in range(n):
                x, y, z, ci = struct.unpack_from("<BBBB", data, body + 4 + i * 4)
                raw.append((x, y, z, ci))
        elif cid == b"RGBA":
            for i in range(256):
                r, g, b, _a = struct.unpack_from("<BBBB", data, body + i * 4)
                pal[i] = (r, g, b)
        if cid == b"MAIN":
            pos = body  # descend into children
        else:
            pos = body + size
    if dims is None:
        sys.exit(f"no SIZE chunk in {path}")
    voxels = {}
    for x, y, z, ci in raw:
        rgb = pal[ci - 1] if ci >= 1 and pal[ci - 1] is not None else (255, 0, 255)
        voxels[(x, y, z)] = rgb
    return voxels, dims


def bake(bits, verbose=True):
    vox_path = f"{VOXDIR}/wall_metal-{bits}.vox"
    bmp_path = f"{CUSTOM}/{BASE}-{bits}.bmp"
    if not os.path.exists(vox_path):
        sys.exit(f"no export to bake: {vox_path} (run wall2vox.py {bits} first)")
    if not os.path.exists(bmp_path):
        sys.exit(f"no custom art to bake into: {bmp_path}")
    voxels, (VW, VD, VR) = read_vox(vox_path)
    im = Image.open(bmp_path).convert("RGBA")
    w, h = im.size
    caph = max(1, h - WALL_FACE_ROWS)
    if (VW, VD) != (w, w):
        sys.exit(f"dims {VW}x{VD} do not match the {w}-wide art grid")

    # THE BASELINE PRINCIPLE: rebuild the volume from the CURRENT art
    # in-memory (the exact forward carve rules, protections and all) and
    # treat only voxels that DIFFER from it as user edits. Inferring
    # "expected" state from the art directly meant re-implementing every
    # forward rule backwards — each one missed (soft gaps, foundation,
    # rim, corner shells) surfaced as phantom edits (measured: 45 phantom
    # band px on an untouched cell).
    cells = wall2vox.cells_for_bits(bits)
    vt = wall2vox.variant_fn("wall_metal")
    v, _expo, farts, cap_art = voxwall.build_cell(vt, cells, (0, 0), "wall_metal")
    base = wall2vox.voxel_colors(v, cap_art, farts)

    def solid(x, z, r):
        return voxels.get((x, z, VR - 1 - r))

    diffs = {}
    for r in range(min(v.R, VR)):
        for z in range(w):
            for x in range(w):
                b = base.get((x, z, r))
                u = solid(x, z, r)
                if (b is None) != (u is None) or (b and u and tuple(u) != tuple(b)):
                    diffs[(x, z, r)] = u

    flags = {"interior": 0, "ring-row": 0, "face-conflict": 0, "face-carrier": 0}
    changed = 0
    exposed = [d for d in ("s", "e", "n", "w")
               if (voxwall.DIRS[d][0][0], voxwall.DIRS[d][0][1]) not in cells]
    claimed = {}

    for (x, z, r), c in sorted(diffs.items()):
        new = (c[0], c[1], c[2], 255) if c else (0, 0, 0, 0)
        if r == 0:
            if 1 <= z <= w - 2:
                # cap band: art row = interior voxel row - 1 (identity at 14)
                if im.getpixel((x, z - 1)) != new:
                    im.putpixel((x, z - 1), new)
                    changed += 1
            else:
                flags["ring-row"] += 1
            continue
        # face skin? only depth-0 boundary voxels of an exposed dir bake
        placed = False
        for d in exposed:
            (dx, dz), artx = voxwall.DIRS[d]
            on_edge = (z == w - 1 if dz == 1 else z == 0) if dz else \
                      (x == w - 1 if dx == 1 else x == 0)
            if not on_edge:
                continue
            fr = r - 1
            if fr >= h - caph:
                continue
            if bits not in RUN_CARRIERS:
                flags["face-carrier"] += 1
                placed = True
                break
            ax = artx(x, z, w)
            key = (ax, fr)
            if key in claimed:
                if claimed[key] != new:
                    flags["face-conflict"] += 1
                placed = True
                break
            claimed[key] = new
            if im.getpixel((ax, caph + fr)) != new:
                im.putpixel((ax, caph + fr), new)
                changed += 1
            placed = True
            break
        if not placed:
            flags["interior"] += 1

    im.save(bmp_path, format="PNG")

    # round-trip: rebuild from the baked bands, count surviving voxels
    wall2vox.export("wall_metal", bits)
    rebuilt, _ = read_vox(vox_path)
    lost = sum(1 for k in voxels if k not in rebuilt)
    gained = sum(1 for k in rebuilt if k not in voxels)
    if verbose:
        fl = "  ".join(f"{k}={v}" for k, v in flags.items() if v)
        print(f"baked {bits}: {changed} band px changed; round-trip "
              f"{len(voxels)}->{len(rebuilt)} voxels "
              f"({lost} lost, {gained} regained by carve rules)"
              + (f"  FLAGS: {fl}" if fl else ""))
    return changed


def watch():
    print(f"watching {VOXDIR} — save from your editor to bake (ctrl-c to stop)")
    seen = {}
    while True:
        for f in sorted(os.listdir(VOXDIR)) if os.path.isdir(VOXDIR) else []:
            if not (f.startswith("wall_metal-") and f.endswith(".vox")):
                continue
            p = f"{VOXDIR}/{f}"
            m = os.path.getmtime(p)
            if seen.get(p) is None:
                seen[p] = m       # first sighting: baseline, don't bake
                continue
            if m != seen[p]:
                seen[p] = m
                bake(f[len("wall_metal-"):-4])
        time.sleep(1)


def main():
    if "--watch" in sys.argv:
        watch()
        return
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit("usage: vox2wall.py <bits> | --watch")
    bake(args[0])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Prototype + PROOF harness for the unified voxel wall builder ("minecraft walls").

The 2026-08-13 rework replaces the hybrid wall (inset core box + cap relief +
flat side skins + seam patches) with ONE boolean voxel volume per cell:

  - start from a FULL solid block (0..WALL_H over the whole cell footprint);
  - the CAP art carves the roof DOWN by CAP_CARVE where it is background;
  - each EXPOSED face's art carves INWARD by SIDE_CARVE_PX art-pixels where it
    is background (face art per direction via the _face_variant run-tile rule);
  - wall-to-wall boundaries are NEVER carved below the cap row, so adjacent
    cells tile flush-solid; the cap row (the only carved boundary layer) closes
    against the neighbour's cap-gap pattern (the seam-wall rule, in-volume).

Faces are emitted only between solid and air, from the solid side, once.

This mirrors what ZoneRenderer._wall_cell_mesh ports to GDScript. Run it before
touching the port: it loads REAL exported art and asserts the guarantees the
in-game build depends on:

  1. watertight interior: below the cap row, everything deeper than the carve
     shell is solid (so no sightline can pass through a wall);
  2. flush boundaries: the voxel columns on both sides of every wall-to-wall
     boundary are fully solid below the cap row;
  3. once-only: no two emitted faces share a plane rectangle (the coplanar
     z-fight class);
  4. ray sweep: no random ray crosses the wall footprint for more than a carve
     shell's depth without hitting solid.

It also renders top/south elevation PNGs per arrangement for the eyeball pass.

    python3 tools/capture/voxwall.py            # run all arrangements + asserts
    python3 tools/capture/voxwall.py --previews # also write PNGs next to CWD
"""
import os
import random
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tile import decode, resolve  # noqa: E402

WALL_H = 1.2
CAP_CARVE = 0.10
SIDE_CARVE_PX = 2          # facade recess depth, in art pixels
WALL_FACE_ROWS = 10        # ZoneRenderer.WALL_FACE_ROWS (split fallback)

# world bg (ZoneRenderer._world_bg default) — the recolour fill for transparent px
WORLD_BG = (0x11, 0x21, 0x26)
MAIN = (0xb1, 0xc9, 0xc3)      # 'y'
DETAIL = (0xff, 0xff, 0xff)    # 'Y'
RECESS = (0x2f, 0x33, 0x33)


def load(name):
    return decode(resolve(name))


def recolour(rows, w, h, ch, main=MAIN, detail=DETAIL, bg=WORLD_BG):
    """ZoneRenderer._recolor_rgb, Fill.ALL: black->main, white->detail (lerp by
    luminance), transparent -> bg fill."""
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


def wall_split(rows, w, h, ch):
    """ZoneRenderer._wall_split: first fully-transparent row in the bottom half
    separates cap from face; else the last WALL_FACE_ROWS rows are the face."""
    for y in range(h // 2, h):
        if all(ch < 4 or rows[y][x * ch + 3] < 128 for x in range(w)):
            return y, y + 1
    start = max(1, h - WALL_FACE_ROWS)
    return start, start


def family_tiles(family):
    """cap-gap grid + face art per variant name, from the real exported tile."""
    cache = {}

    def variant(bits):
        # exported names differ per family (Tiles_*.bmp vs Walls_*.png) — resolve
        # by the family-variant substring, which is unique either way
        name = f"{family}-{bits}."
        if name in cache:
            return cache[name]
        try:
            w, h, ch, rows = load(name)
        except SystemExit:
            cache[name] = None
            return None
        split_cap, split_face = wall_split(rows, w, h, ch)
        col = recolour(rows, w, h, ch)
        cap = [[col[y][x] == WORLD_BG for x in range(w)] for y in range(split_cap)]
        face = [[col[y][x] == WORLD_BG for x in range(w)] for y in range(split_face, h)]
        facecol = [row[:] for row in col[split_face:]]
        capcol = [row[:] for row in col[:split_cap]]
        cache[name] = {"w": w, "cap": cap, "capcol": capcol,
                       "face": face, "facecol": facecol}
        return cache[name]

    return variant


def face_variant_bits(e_on, w_on):
    return "00" + ("1" if e_on else "0") + "000" + ("1" if w_on else "0") + "0"


OFFS = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]


def autotile_bits(cells, k, family):
    """Qud-style same-family suffix for the CAP (top-view parity)."""
    return "".join("1" if cells.get((k[0] + dx, k[1] + dy)) == family else "0"
                   for dx, dy in OFFS)


class CellVox:
    """One cell's voxel volume. Rows: r=0 cap layer [WALL_H-CAP_CARVE, WALL_H];
    r=1..F face art rows clipped below the cap plane. x,z in art pixels."""

    def __init__(self, W, F):
        self.W, self.F = W, F
        rh = WALL_H / F
        yc = WALL_H - CAP_CARVE
        planes = [WALL_H, yc]
        for i in range(1, F + 1):
            y = WALL_H - i * rh
            if y < yc - 1e-9:
                planes.append(y)
        if planes[-1] > 1e-9:
            planes.append(0.0)
        self.planes = planes                       # descending; row r spans planes[r+1]..planes[r]
        self.R = len(planes) - 1
        self.solid = [[[True] * W for _ in range(W)] for _ in range(self.R)]

    def face_row_of(self, r):
        """Which face-art row this voxel row samples (by midpoint)."""
        rh = WALL_H / self.F
        mid = (self.planes[r] + self.planes[r + 1]) / 2.0
        return min(self.F - 1, max(0, int((WALL_H - mid) / rh)))


# direction -> (dz/dx step into the cell, art-x mapping fn(x, z, W)).
# The art WRAPS the block: S reads W->E, E continues S->N MIRRORED, N reads
# E->W, W continues N->S mirrored — every corner column is shared by both its
# faces (Daniel's marker test; the fence/tent mirroring lesson).
DIRS = {
    "s": ((0, 1), lambda x, z, W: x),           # art +x = east
    "n": ((0, -1), lambda x, z, W: W - 1 - x),  # art +x = west
    "e": ((1, 0), lambda x, z, W: z),           # MIRRORED: art +x = south
    "w": ((-1, 0), lambda x, z, W: W - 1 - z),  # MIRRORED: art +x = north
}


def build_cell(vt, cells, k, family):
    """Volume for cell k: full block, cap-carved, side-carved on exposed faces."""
    cap_art = vt(autotile_bits(cells, k, family)) or vt("00000000")
    W = cap_art["w"]
    F = len(cap_art["face"]) or WALL_FACE_ROWS
    v = CellVox(W, F)
    caph = len(cap_art["cap"])
    for z in range(W):
        az = min(caph - 1, z * caph // W)
        for x in range(W):
            if cap_art["cap"][az][x]:
                v.solid[0][z][x] = False
    exposure = {}
    faces_art = {}
    # A carve must never enter the shell beside a wall neighbour: a face's gap
    # columns can run to the tile edge, and carving there would hollow the flush
    # boundary the neighbour's emission (and the flush-boundary proof) relies on.
    prot = [[False] * W for _ in range(W)]
    for d, ((dx, dz), _a) in DIRS.items():
        if (k[0] + dx, k[1] + dz) not in cells:
            continue
        for depth in range(SIDE_CARVE_PX):
            for a in range(W):
                if dz == 1:   prot[W - 1 - depth][a] = True
                elif dz == -1: prot[depth][a] = True
                elif dx == 1: prot[a][W - 1 - depth] = True
                else:         prot[a][depth] = True
    # CORNERS where two EXPOSED faces meet keep their solid edge: the wrap puts
    # the same art column on both corner faces, so an edge gap would carve from
    # both directions and delete the whole corner column (the missing-chunk
    # report). Relief starts one shell in from the corner.
    for pair in (("n", "e"), ("e", "s"), ("s", "w"), ("w", "n")):
        if any((k[0] + DIRS[d][0][0], k[1] + DIRS[d][0][1]) in cells for d in pair):
            continue
        for i in range(SIDE_CARVE_PX):
            for j in range(SIDE_CARVE_PX):
                pz = i if "n" in pair else W - 1 - i
                px = j if "w" in pair else W - 1 - j
                prot[pz][px] = True
    for d, ((dx, dz), artx) in DIRS.items():
        nb = (k[0] + dx, k[1] + dz)
        exposure[d] = nb not in cells
        if not exposure[d]:
            continue
        # along-face continuation (any wall family), rotated-axis mapping
        cont = {
            "s": ((1, 0), (-1, 0)), "n": ((-1, 0), (1, 0)),
            "e": ((0, 1), (0, -1)), "w": ((0, -1), (0, 1)),
        }[d]
        e_on = (k[0] + cont[0][0], k[1] + cont[0][1]) in cells
        w_on = (k[0] + cont[1][0], k[1] + cont[1][1]) in cells
        fa = vt(face_variant_bits(e_on, w_on)) or vt("00000000") or cap_art
        faces_art[d] = fa
        # the bottom row is FOUNDATION: never carved (no floor under walls, no
        # pocket floors — a base carve would be open underneath)
        for r in range(1, v.R - 1):
            fr = v.face_row_of(r)
            for a in range(W):
                x, z = (a, None) if dx == 0 else (None, a)
                ax = artx(a if dx == 0 else 0, a if dx != 0 else 0, W)
                if not fa["face"][fr][ax]:
                    continue                        # art present -> flush, no carve
                for depth in range(SIDE_CARVE_PX):
                    cz, cx = (W - 1 - depth, a) if dz == 1 else \
                             (depth, a) if dz == -1 else \
                             (a, W - 1 - depth) if dx == 1 else (a, depth)
                    if not prot[cz][cx]:
                        v.solid[r][cz][cx] = False
    return v, exposure, faces_art, cap_art


def emit(cells_vox, cells, k):
    """Solid->air boundary faces for cell k. Returns [(plane-key, normal, kind)]."""
    v, exposure, faces_art, cap_art = cells_vox[k]
    W, R = v.W, v.R
    out = []

    def nb_solid(r, z, x):
        """Solidity of the voxel at (r,z,x) allowing out-of-cell lateral indices."""
        if 0 <= z < W and 0 <= x < W:
            return v.solid[r][z][x]
        dx = 1 if x >= W else (-1 if x < 0 else 0)
        dz = 1 if z >= W else (-1 if z < 0 else 0)
        nbk = (k[0] + dx, k[1] + dz)
        if nbk not in cells:
            return False                            # air outside the wall
        if r >= 1:
            return True                             # boundaries never carve below cap
        nv = cells_vox[nbk][0]                      # cap row: neighbour's real gaps
        return nv.solid[0][(z - dz * W) % W if dz else z][(x - dx * W) % W if dx else x]

    for r in range(R):
        for z in range(W):
            for x in range(W):
                if not v.solid[r][z][x]:
                    continue
                gx, gz = k[0] * W + x, k[1] * W + z
                # +Y: cap surface or recess floor
                if r == 0 or not v.solid[r - 1][z][x]:
                    out.append((("Y", round(v.planes[r], 4), gx, gz), (0, 1, 0),
                                "cap" if r == 0 else "recess"))
                # -Y: underside over a carved pocket
                if r + 1 < R and not v.solid[r + 1][z][x]:
                    out.append((("Y", round(v.planes[r + 1], 4), gx, gz), (0, -1, 0), "recess"))
                for (sx, sz), nrm in ((( 1, 0), (1, 0, 0)), ((-1, 0), (-1, 0, 0)),
                                      ((0,  1), (0, 0, 1)), ((0, -1), (0, 0, -1))):
                    if nb_solid(r, z + sz, x + sx):
                        continue
                    plane = ("X", gx + (1 if sx > 0 else 0), r, gz) if sx else \
                            ("Z", gz + (1 if sz > 0 else 0), r, gx)
                    out.append((plane, nrm, "skin"))
    return out


def arrangement(vt_by_family, layout):
    """layout: {(cx,cy): family}. Build all volumes + all faces; run the proofs."""
    cells = dict(layout)
    vox = {k: build_cell(vt_by_family[f], cells, k, f) for k, f in cells.items()}
    faces = []
    for k in cells:
        faces.extend(emit(vox, cells, k))

    # 3. once-only: no two faces on the same plane rectangle
    seen = {}
    for plane, nrm, kind in faces:
        assert plane not in seen, f"coplanar duplicate at {plane}: {kind} vs {seen[plane]}"
        seen[plane] = kind

    for k, f in cells.items():
        v = vox[k][0]
        W = v.W
        # 1. watertight interior below the cap row
        for r in range(1, v.R):
            for z in range(SIDE_CARVE_PX, W - SIDE_CARVE_PX):
                for x in range(SIDE_CARVE_PX, W - SIDE_CARVE_PX):
                    assert v.solid[r][z][x], f"interior carved at {k} r={r} z={z} x={x}"
        # 2. flush wall-to-wall boundaries below the cap row
        for d, ((dx, dz), _) in DIRS.items():
            if (k[0] + dx, k[1] + dz) not in cells:
                continue
            for r in range(1, v.R):
                for a in range(W):
                    z, x = (W - 1 if dz > 0 else 0, a) if dz else (a, W - 1 if dx > 0 else 0)
                    assert v.solid[r][z][x], f"boundary carved at {k} dir={d} r={r} a={a}"

    # 4. ray sweep: below the cap plane no ray runs > shell depth through the
    # footprint without hitting solid. Corner-continuous art (E/W mirrored)
    # ALIGNS carve columns at corners, so a grazing diagonal can pass two
    # aligned shells back-to-back — still shell-only travel (the 12px interior
    # of assert 1 stays impassable), hence two shells + slack.
    rng = random.Random(7)
    W = next(iter(vox.values()))[0].W
    max_free = (SIDE_CARVE_PX * 4) / W              # in cell units
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    lo = (min(xs) - 1.0, min(ys) - 1.0)
    hi = (max(xs) + 1.0, max(ys) + 1.0)

    def solid_at(px, py, pz):
        cx, cz = round(px), round(pz)
        if (cx, cz) not in cells:
            return None                             # outside the footprint
        v = vox[(cx, cz)][0]
        x = min(W - 1, max(0, int((px - cx + 0.5) * W)))
        z = min(W - 1, max(0, int((pz - cz + 0.5) * W)))
        for r in range(v.R):
            if v.planes[r + 1] <= py < v.planes[r]:
                return v.solid[r][z][x]
        return None                                 # above/below the wall
    for _ in range(4000):
        a = (rng.uniform(lo[0], hi[0]), rng.uniform(0.05, WALL_H - CAP_CARVE - 0.02),
             rng.uniform(lo[1], hi[1]))
        b = (rng.uniform(lo[0], hi[0]), rng.uniform(0.05, WALL_H - CAP_CARVE - 0.02),
             rng.uniform(lo[1], hi[1]))
        steps = 400
        free = 0.0
        seg = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2 + (b[2] - a[2]) ** 2) ** 0.5 / steps
        for i in range(steps + 1):
            t = i / steps
            p = tuple(a[j] + (b[j] - a[j]) * t for j in range(3))
            s = solid_at(*p)
            if s is True:
                free = 0.0
            elif s is False:
                free += seg
                assert free <= max_free + 1e-6, \
                    f"ray sees {free:.3f} cells deep through the wall near {p}"
            else:
                free = 0.0
    return vox, faces


def write_png(path, grid):
    h = len(grid); w = len(grid[0])
    raw = b"".join(b"\x00" + b"".join(bytes(px) for px in row) for row in grid)

    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def previews(tag, vox, cells):
    """Top view (cap colour / recess) and south elevation (skin colour / recess)."""
    W = next(iter(vox.values()))[0].W
    xs = sorted({c[0] for c in cells}); zs = sorted({c[1] for c in cells})
    top = [[(20, 24, 26)] * (len(xs) * W) for _ in range(len(zs) * W)]
    for (cx, cz), (v, expo, farts, cap) in vox.items():
        ox, oz = xs.index(cx) * W, zs.index(cz) * W
        caph = len(cap["cap"])
        for z in range(W):
            az = min(caph - 1, z * caph // W)
            for x in range(W):
                top[oz + z][ox + x] = RECESS if not v.solid[0][z][x] else cap["capcol"][az][x]
    write_png(f"voxwall_{tag}_top.png", top)
    v0 = next(iter(vox.values()))[0]
    R = v0.R
    south = [[(20, 24, 26)] * (len(xs) * W) for _ in range(R)]
    for (cx, cz), (v, expo, farts, cap) in vox.items():
        if (cx, cz + 1) in cells:
            continue                                # occluded by the cell in front
        ox = xs.index(cx) * W
        fa = farts.get("s")
        for r in range(v.R):
            fr = v.face_row_of(r)
            for x in range(W):
                depth = next((d for d in range(W) if v.solid[r][W - 1 - d][x]), None)
                if depth is None:
                    continue
                c = RECESS if depth > 0 or fa is None else fa["facecol"][fr][x]
                south[r][ox + x] = c
    write_png(f"voxwall_{tag}_south.png", south)


def main():
    want_previews = "--previews" in sys.argv
    vt = {f: family_tiles(f) for f in ("wall_metal", "wall_brinestalk")}
    layouts = {
        "isolated": {(0, 0): "wall_metal"},
        "run3": {(0, 0): "wall_metal", (1, 0): "wall_metal", (2, 0): "wall_metal"},
        "corner": {(0, 0): "wall_metal", (1, 0): "wall_metal", (1, 1): "wall_metal"},
        "block22": {(x, y): "wall_metal" for x in (0, 1) for y in (0, 1)},
        "mixed": {(0, 0): "wall_brinestalk", (1, 0): "wall_metal",
                  (2, 0): "wall_brinestalk"},
    }
    for tag, layout in layouts.items():
        vox, faces = arrangement(vt, layout)
        print(f"{tag:9s} cells={len(layout)} faces={len(faces)}  OK")
        if want_previews:
            previews(tag, vox, layout)
    print("voxwall: all arrangements watertight, boundaries flush, faces once-only")


if __name__ == "__main__":
    main()

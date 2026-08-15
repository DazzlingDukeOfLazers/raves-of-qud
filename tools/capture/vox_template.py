#!/usr/bin/env python3
"""Write a blank 16x16x24 .vox authoring template carrying the Qud palette.

For starting NEW voxel designs in vengi (the project's blessed external
editor) with Qud's canonical colours ready on the palette:

    python3 tools/capture/vox_template.py
    -> <support>/vox/template-16x16x24.vox

Palette slots 1..18 are Qud's 18 colours in code order
r R o O w W g G b B c C m M k K y Y (QudPalette.gd is the source of truth —
transcribed values asserted against it by tools/regression checks if they
ever drift). The only voxels in the file are a one-voxel-high perimeter
ring at the base, drawn in K (dark grey), so the canvas bounds are visible;
delete or build over it.

NOTE the geometry gap, deliberately unresolved: the WALL volume is
16x16x11 (cap layer + 10 face rows, uneven heights) — this 24-high canvas
is for freeform/V4-era authoring and does NOT bake through vox2wall's band
grammar. Wall editing starts from wall2vox.py exports instead.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wall2vox

OUT = wall2vox.OUT

# QudPalette.gd COLORS, code order r R o O w W g G b B c C m M k K y Y
QUD_PALETTE = [
    ("r", (0xA6, 0x4A, 0x2E)), ("R", (0xD7, 0x42, 0x00)),
    ("o", (0xF1, 0x5F, 0x22)), ("O", (0xE9, 0x9F, 0x10)),
    ("w", (0x98, 0x87, 0x5F)), ("W", (0xCF, 0xC0, 0x41)),
    ("g", (0x00, 0x94, 0x03)), ("G", (0x00, 0xC4, 0x20)),
    ("b", (0x00, 0x48, 0xBD)), ("B", (0x00, 0x96, 0xFF)),
    ("c", (0x40, 0xA4, 0xB9)), ("C", (0x77, 0xBF, 0xCF)),
    ("m", (0xB1, 0x54, 0xCF)), ("M", (0xDA, 0x5B, 0xD6)),
    ("k", (0x0F, 0x3B, 0x3A)), ("K", (0x15, 0x53, 0x52)),
    ("y", (0xB1, 0xC9, 0xC3)), ("Y", (0xFF, 0xFF, 0xFF)),
]
W, D, H = 16, 16, 24


def main():
    colors = {}
    K = QUD_PALETTE[15][1]
    for x in range(W):
        for z in (0, D - 1):
            colors[(x, z, H - 1)] = K       # (x, z, r) with r = H-1 -> vox z = 0
    for z in range(1, D - 1):
        for x in (0, W - 1):
            colors[(x, z, H - 1)] = K
    # write_vox assigns palette indices in first-seen order; seed the full
    # Qud palette by claiming slots 1..18 explicitly instead
    path = f"{OUT}/template-16x16x24.vox"
    os.makedirs(OUT, exist_ok=True)
    import struct

    def chunk(cid, content, children=b""):
        return cid + struct.pack("<ii", len(content), len(children)) + content + children

    kn = 16  # K's 1-based palette slot (r=1 ... K=16)
    voxels = [(x, z, 0, kn) for (x, z, _r) in colors]
    size = chunk(b"SIZE", struct.pack("<iii", W, D, H))
    xyzi = chunk(b"XYZI", struct.pack("<i", len(voxels)) +
                 b"".join(struct.pack("<BBBB", *v) for v in voxels))
    rgba = bytearray()
    for i in range(256):
        rgb = QUD_PALETTE[i][1] if i < len(QUD_PALETTE) else (0, 0, 0)
        rgba += bytes((rgb[0], rgb[1], rgb[2], 255))
    main_chunk = chunk(b"MAIN", b"", size + xyzi + chunk(b"RGBA", bytes(rgba)))
    with open(path, "wb") as f:
        f.write(b"VOX " + struct.pack("<i", 150) + main_chunk)
    print(f"{path}  {len(voxels)} guide voxels, Qud palette in slots 1..18 "
          f"(r R o O w W g G b B c C m M k K y Y), {W}x{D}x{H}")


if __name__ == "__main__":
    main()

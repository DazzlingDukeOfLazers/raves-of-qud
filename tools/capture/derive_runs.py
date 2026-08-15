#!/usr/bin/env python3
"""Derive the run-tile family from the PLATONIC run tile (Daniel's model):
the E/W run variant IS the design; every other run orientation is generated.

    E/W set (verbatim):   00100010 (the platonic) -> 00100000, 00000010
    N/S set (turned 90):  -> 10001000, 10000000, 00001000

The 90-degree turn is implemented as a TRANSPOSE of the cap's 14x14 interior
(mirror across the main diagonal): along-run features become along-run
features, exactly like a rotation — but unlike a true rotation on an
even-sized grid it PRESERVES the global seam phase, so a period-2 pattern
(the checker) stays continuous at every wall-to-wall join. If a future
design is chiral and needs the true rotation, set TRANSPOSE = False and
re-derive (and expect to revisit corner joins).

Ring columns (art cols 0/15) are written at the family's global checker
phase; the face band (bottom FACE_ROWS rows) is copied verbatim — faces are
vertical surfaces and do not turn with the roof. The isolated tile
(00000000) is NOT derived: it is the editor's fully-framed reference.

Writes into tiles_custom (never committed). Re-run after editing the
platonic tile. PIL must save with format="PNG" (the .bmp extension lies).
"""
import os
from PIL import Image

DIR = os.path.expanduser("~/Library/Application Support/RavesOfQud/tiles_custom")
BASE = "Assets_Content_Textures_Tiles_wall_metal"
PLATONIC = "00100010"
EW_SET = ["00100000", "00000010"]
NS_SET = ["10001000", "10000000", "00001000"]
FACE_ROWS = 10
TRANSPOSE = True   # False = true 90-degree rotation (chiral art; breaks checker phase)
RED = (166, 74, 46, 255)


def main():
    src = Image.open(f"{DIR}/{BASE}-{PLATONIC}.bmp").convert("RGBA")
    w, h = src.size
    caph = h - FACE_ROWS
    assert (w, caph) == (16, 14), f"unexpected layout {src.size}"

    def turned():
        out = src.copy()
        for r in range(caph):
            for c in range(14):
                px = src.getpixel((r + 1, c) if TRANSPOSE else (13 - c + 1, r))
                out.putpixel((c + 1, r), px)
            # ring columns: the family's global checker phase
            out.putpixel((0, r), RED if (0 + r) % 2 == 1 else (0, 0, 0, 0))
            out.putpixel((15, r), RED if (15 + r) % 2 == 1 else (0, 0, 0, 0))
        return out

    for bits in EW_SET:
        src.save(f"{DIR}/{BASE}-{bits}.bmp", format="PNG")
    ns = turned()
    for bits in NS_SET:
        ns.save(f"{DIR}/{BASE}-{bits}.bmp", format="PNG")
    print(f"derived from {PLATONIC}: {' '.join(EW_SET)} (verbatim), "
          f"{' '.join(NS_SET)} ({'transposed' if TRANSPOSE else 'rotated'})")


if __name__ == "__main__":
    main()

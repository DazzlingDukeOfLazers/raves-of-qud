#!/usr/bin/env python3
"""Compare candidate rules for "which transparent pixels are INTERIOR?"

Qud tiles are 2-colour masks over a transparent field. In Qud's 2D view every
transparent pixel shows the cell background, so the art carries no distinction.
In 3D we need one: interior gaps should read as the Qud background green, while
the pixels outside the silhouette must stay see-through or the sprite becomes a
rectangle.

Verified: the file itself cannot tell us. Alpha is strictly binary (0/255), and
the RGB under transparent pixels is ATLAS BLEED from neighbouring tiles, not a
channel — it shows up in rows entirely outside the sprite, and identical-looking
gaps carry different colours. So the rule has to be geometric.

    python3 tools/capture/fill.py sw_chest
    python3 tools/capture/fill.py sw_chest sw_basket sw_bed

Legend:  # opaque    · outside (stays transparent)    G interior (fill green)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tile import decode, resolve  # noqa: E402


def opacity(path):
    w, h, ch, rows = decode(path)
    solid = [[rows[y][x * ch + 3] >= 128 if ch == 4 else True
              for x in range(w)] for y in range(h)]
    return w, h, solid


def rule_floodfill(w, h, solid):
    """Transparent pixels reachable from the border (4-conn) are outside.

    The textbook approach. Fails on art with a gap in the silhouette: one
    channel to the edge and the whole interior drains to 'outside'.
    """
    outside = [[False] * w for _ in range(h)]
    stack = [(x, y) for x in range(w) for y in (0, h - 1) if not solid[y][x]]
    stack += [(x, y) for y in range(h) for x in (0, w - 1) if not solid[y][x]]
    while stack:
        x, y = stack.pop()
        if not (0 <= x < w and 0 <= y < h) or outside[y][x] or solid[y][x]:
            continue
        outside[y][x] = True
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return [[not solid[y][x] and not outside[y][x] for x in range(w)] for y in range(h)]


def rule_column(w, h, solid):
    """Interior = has an opaque pixel somewhere above AND below in its column.

    Tolerates leaks, because it never asks about connectivity. Catches the
    separator lines that flood fill drains away.
    """
    interior = [[False] * w for _ in range(h)]
    for x in range(w):
        col = [y for y in range(h) if solid[y][x]]
        if not col:
            continue
        for y in range(col[0] + 1, col[-1]):
            if not solid[y][x]:
                interior[y][x] = True
    return interior


def rule_column_and_row(w, h, solid):
    """Interior = spanned in its column AND its row. The conservative option."""
    col = rule_column(w, h, solid)
    row = [[False] * w for _ in range(h)]
    for y in range(h):
        line = [x for x in range(w) if solid[y][x]]
        if not line:
            continue
        for x in range(line[0] + 1, line[-1]):
            if not solid[y][x]:
                row[y][x] = True
    return [[col[y][x] and row[y][x] for x in range(w)] for y in range(h)]


RULES = [("flood fill", rule_floodfill),
         ("column span", rule_column),
         ("column AND row", rule_column_and_row)]


def render(w, h, solid, interior):
    return ["".join("#" if solid[y][x] else ("G" if interior[y][x] else "·")
                    for x in range(w)) for y in range(h)]


def compare(name):
    path = resolve(name)
    w, h, solid = opacity(path)
    panes, counts = [], []
    for label, fn in RULES:
        inner = fn(w, h, solid)
        panes.append(render(w, h, solid, inner))
        counts.append(sum(r.count(True) for r in inner))
    print(f"\n=== {os.path.basename(path)} ===")
    print("   " + "   ".join(f"{lbl:<{w}}" for lbl, _ in RULES))
    print("   " + "   ".join(f"{'(%d px filled)' % c:<{w}}" for c in counts))
    for y in range(h):
        print("   " + "   ".join(p[y] for p in panes))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for arg in sys.argv[1:]:
        compare(arg)

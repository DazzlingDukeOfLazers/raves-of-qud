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


def rule_column_or_row(w, h, solid):
    """Interior = spanned in its column OR its row.

    AND is too strict for art with a channel open at one end — the chest's side
    bands span only the top two rows, so the gap beside them has nothing opaque
    below and stays see-through for the sprite's full height. OR still protects
    the silhouette, because a pixel outside the shape fails both tests.
    """
    col = rule_column(w, h, solid)
    row = [[False] * w for _ in range(h)]
    for y in range(h):
        line = [x for x in range(w) if solid[y][x]]
        if not line:
            continue
        for x in range(line[0] + 1, line[-1]):
            if not solid[y][x]:
                row[y][x] = True
    return [[col[y][x] or row[y][x] for x in range(w)] for y in range(h)]


def rule_row(w, h, solid):
    """Interior = has an opaque pixel to the LEFT and RIGHT in its own row.

    Horizontal enclosure implies "inside the object"; vertical enclosure does
    not, because a sprite legitimately has open sky between its head and its
    feet (the space around a dromad's legs and neck is spanned vertically but
    is plainly outside). Asymmetric, but it matches how these tiles are drawn.
    """
    inner = [[False] * w for _ in range(h)]
    for y in range(h):
        line = [x for x in range(w) if solid[y][x]]
        if not line:
            continue
        for x in range(line[0] + 1, line[-1]):
            if not solid[y][x]:
                inner[y][x] = True
    return inner


MAX_SLOT = 2


def rule_and_plus_slots(w, h, solid):
    """column AND row, PLUS any narrow horizontal slot inside the row span.

    The chest's side bands are separated from its body by 1px channels that run
    the sprite's full height. They have nothing opaque below, so the column test
    rejects them and you see daylight through the chest. Widening the rule by
    row alone over-fills — it webs the gaps between a dromad's legs. Width is
    what separates the two: a 1px slot is a seam in the art, a 10px opening is
    the world showing through.
    """
    inner = rule_column_and_row(w, h, solid)
    for y in range(h):
        line = [x for x in range(w) if solid[y][x]]
        if not line:
            continue
        x = line[0] + 1
        while x < line[-1]:
            if solid[y][x]:
                x += 1
                continue
            run = x
            while run < line[-1] and not solid[y][run]:
                run += 1
            if run - x <= MAX_SLOT:
                for k in range(x, run):
                    inner[y][k] = True
            x = run
    return inner


RULES = [("column AND row", rule_column_and_row),
         ("row only", rule_row),
         ("AND + narrow slots", rule_and_plus_slots)]


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

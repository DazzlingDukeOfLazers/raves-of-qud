#!/usr/bin/env python3
"""SPOT: every door tile either derives a frame+leaf model or falls back to the flat slab.

The voxel door reads its own geometry out of the art (see tools/capture/door.py): bright and dark
pixel classes are frame and leaf, and which is which is decided by containment, not by palette.
That derivation is the whole feature -- if it silently stops matching a tile, that door reverts to
a slab and nobody notices, because a slab still renders.

This pins the outcome for every door tile on disk: how many derive, which ones do not, and WHY.
A tile moving between the two lists is the signal; the counts alone are not.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "capture"))
import door  # noqa: E402

TILES = door.TILES
# Known fallbacks, with the reason each is not a frame around a leaf. Not failures -- the slab is
# the correct answer for them -- but a NEW name appearing here means a door quietly lost its model.
EXPECT_FALLBACK = {
    "Creatures_sw_golem_door.png",      # a creature, not a door: its "leaf" is 3x5 of a golem
    "Tiles_sw_door2_metal_left.bmp",    # side view; the leaf runs to the tile edge, no frame past it
    "Tiles_sw_door2_metal_right.bmp",   # ditto, mirrored
}

if not os.path.isdir(TILES):
    print("door_model: SKIP (no exported tiles at %s)" % TILES)
    sys.exit(0)

# THE _open VARIANTS ARE NOT DERIVED FROM, so they are not audited. A door always wears its CLOSED
# art whichever way it is standing -- the _open sprite is a hole in a wall, i.e. the doorway with
# the leaf absent, and what the renderer needs is the leaf ITSELF (_place_door does the
# tile.replace("_open", "") to get there). Deriving from a hole yields exactly what you would
# expect: "leaf 1x16 is too small for a 14x22 frame", the hole's edge read as a panel. Auditing
# them would pin a dozen fallbacks that describe nothing the renderer ever does.
names = sorted(n for n in os.listdir(TILES)
               if "door" in n.lower() and "_open" not in n.lower())
if not names:
    print("door_model: SKIP (no door tiles exported)")
    sys.exit(0)

derived, fallback, bad = [], {}, []
for n in names:
    m, why = door.model(os.path.join(TILES, n))
    if m is None:
        fallback[n] = why
        continue
    derived.append(n)
    lx0, lx1, ly0, ly1 = m["leaf_rect"]
    fx0, fx1 = m["frame_span"]
    # The three properties the renderer depends on. Each can fail while still producing a mesh.
    if not (fx0 < lx0 and lx1 < fx1):
        bad.append("%s: leaf escapes its frame" % n)
    if max(m["reveal_left"], m["reveal_right"]) < 1:
        bad.append("%s: no reveal either side -- the outline would vanish" % n)
    if m["hinge_x"] not in (lx0, lx1):
        bad.append("%s: hinge %d is not a leaf edge" % (n, m["hinge_x"]))
    # THE HOUSE CONVENTION, pinned on the tile it was stated about. Daniel: "the default art puts
    # the doorknob on the right and the hinges on the left." Getting this backwards is invisible in
    # a still -- the door only looks wrong once it swings -- so assert it rather than eyeball it.
    if n == "Tiles_sw_door_basic.bmp" and m["hinge_x"] != lx0:
        bad.append("%s: hinges on the RIGHT; the basic door's knob is at cols 10..11, so the "
                   "hinge belongs on the left" % n)

now_fallback = set(fallback)
new_fb = now_fallback - EXPECT_FALLBACK
fixed_fb = EXPECT_FALLBACK - now_fallback
for n in sorted(new_fb):
    bad.append("%s NEWLY falls back to the slab: %s" % (n, fallback[n]))
for n in sorted(fixed_fb):
    bad.append("%s no longer falls back -- update EXPECT_FALLBACK if that is intended" % n)

if bad:
    print("door_model: FAIL")
    for b in bad:
        print("  -", b)
    sys.exit(1)
left = sum(1 for n in derived
           if door.model(os.path.join(TILES, n))[0]["hinge_x"]
           == door.model(os.path.join(TILES, n))[0]["leaf_rect"][0])
print("door_model: %d of %d door tiles derive a frame+leaf voxel model (%d hinge left, %d right, "
      "from each one's own knob); %d fall back to the slab, all expected"
      % (len(derived), len(names), left, len(derived) - left, len(fallback)))

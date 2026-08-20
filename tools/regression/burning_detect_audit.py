#!/usr/bin/env python3
"""burning_detect_audit — ZoneRenderer._is_burning, mirrored in Python.

Qud ships no "burning" flag. It does not need one: a Flaming object's RenderEvent flickers, and
the mod already sweeps 60 frames of it into `animSched` (ZoneSnapshot.AnimFrameSweep, which writes
tile + ColorString + BackgroundString + DetailColor per frame). Burning arrives as a COLOUR-ONLY
schedule -- no tile ever changes -- pairing a fire foreground with a flashing cell background.

Reading the animation instead of adding a flag means every burning thing Qud renders gets a flame,
not just the player, and no mod rebuild is needed -- which matters, because deploying one costs a
full Qud restart.

The risk is a FALSE POSITIVE putting fire on something that is merely tinted: Asleep floods `^c`
behind its art the same way. Hence both halves must be flame-coloured. Keep FIRE_FG/FIRE_BG in
step with ZoneRenderer.gd. Stdlib only; no daemon, no apps, no Qud.
"""
import sys

FIRE_BG_FLASH = "W"
FIRE_BG_BASE = "K"


def is_burning(spec):
    if not spec or "^" not in spec:
        return False
    parts = spec.split("|")
    seen = set()
    for i in range(1, len(parts)):
        kv = parts[i].split("=")
        if len(kv) != 2:
            continue
        axes = kv[1].split(";")
        if len(axes) != 3:
            continue
        if axes[0] != "":
            return False          # a tile swap: some other animation entirely
        col = axes[1]
        cut = col.find("^")
        if cut < 0:
            continue
        bg = col[cut + 1:]
        if len(bg) != 1:
            continue
        seen.add(bg.upper())
    # both halves of the flicker, or a steady tint would qualify
    return FIRE_BG_FLASH in seen and FIRE_BG_BASE in seen


CASES = [
    # captured off the wire while Daniel's character was alight in the salt desert
    ("player, BURNING (real wire capture)",
     "60|0=;&r^k;|1=;;|2=;&r^k;|3=;;|5=;&r^k;|6=;;|7=;&r^W;|9=;;|11=;&r^W;|12=;&r^k;"
     "|13=;;|15=;&r^k;|16=;;|17=;&r^k;|18=;;|20=;&r^W;|21=;&r^k;|22=;;|23=;&r^W;", True),
    # the dawnglider circling it, same snapshot: a status ICON, not fire
    ("dawnglider, FLYING (real wire capture)",
     "60|0=;;|5=Tiles2/status_flying.bmp;&y;y|15=;;", False),
    ("asleep floods ^c behind the art", "60|0=;&c^c;|10=;;|20=;&c^c;", False),
    ("a single steady flash is NOT fire", "60|0=;&r^W;", False),
    # the capture that exposed the bug: a level-44 character, green foreground, burning
    ("level-44 character, &G foreground (real capture)",
     "60|0=;;|2=;&G^W;|3=;;|5=;&G^k;|6=;;|7=;&G^k;|12=;&G^W;|14=;&G^k;|17=;&G^W;", True),
    ("&Y foreground (real capture)", "60|0=;;|2=;&Y^W;|4=;&Y^k;|20=;&Y^W;", True),
    ("tile-only cycle (waterwheel)", "60|0=frame1.bmp;;|30=frame2.bmp;;", False),
    ("no animation at all", "", False),
    # tolerance for junk entries, with BOTH halves of the flicker present so it is still fire
    ("malformed entries are ignored, not crashed on", "60|junk|0=;&r^W;|4=;&r^k;", True),
]

fails = 0
for label, spec, want in CASES:
    got = is_burning(spec)
    if got != want:
        fails += 1
        print("  FAIL %-44s -> %s (wanted %s)" % (label, got, want))
    else:
        print("  ok   %-44s -> %s" % (label, got))
print()
if fails:
    print("%d case(s) failed" % fails)
    sys.exit(1)
print("all good (0 checks failed)")

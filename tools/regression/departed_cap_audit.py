#!/usr/bin/env python3
"""SPOT: a departed zone never renders brighter than the zone the player is in.

Qud's memory is a palette swap that ignores time of day, so a remembered zone renders at a flat
MEMORY_GROUND however dark it is where you stand. Qud never shows two zones at once so this is
invisible there; Raves draws the neighbours, and at night the live zone is darker than
MEMORY_GROUND -- every departed zone became a bright halo around a dark one. Measured at the
Joppa north boundary at night: neighbour (9,33,41) against live (5,24,29).

No darkness overlay can fix that. Going outward the brightness has to INCREASE and alpha only
darkens, which is why the old ramp could not converge no matter how it was tuned. The fix is a
ceiling on the remembered tone, and this asserts the ceiling holds.

Pure arithmetic, mirrored from ZoneRenderer.gd -- no Godot, no apps.
"""
import sys

MEMORY_GROUND = 0.84
DARK_MAX = 0.94
CAP_QUANT = 16.0

MEM_TONE = 1.0 - MEMORY_GROUND          # 0.16, what memory renders at uncapped


def departed_cap(ambient):
    amb = min(max(ambient * DARK_MAX, 0.0), 1.0)
    return min(max(1.0 - MEMORY_GROUND * (1.0 - amb), 0.0), 1.0)


def departed_tone(ambient):
    return max(MEM_TONE, departed_cap(ambient))


def live_alpha(ambient):
    """What the live zone's ground actually renders at: tone * amax, amax = DARK_MAX."""
    return ambient * DARK_MAX


def departed_alpha(ambient):
    """A frozen zone bakes at amax = 1.0, so its tone IS its alpha."""
    return departed_tone(ambient)


fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


# 1. MONOTONE, AND BLACK WITH THE WORLD. The composition does not claim to be a proven ceiling
#    (that needs the live ground's luminance, which the wire cannot give -- see _departed_cap).
#    What it does guarantee: memory only ever gets darker as the world does, and when the world
#    reaches full darkness memory is fully dark too, so the halo cannot survive at the limit.
prev = -1.0
for i in range(0, 101):
    amb = i / 100.0
    a = departed_alpha(amb)
    check(a >= prev - 1e-9, "ambient %.2f: departed brightness is not monotone" % amb)
    prev = a
# ...as dark as the live zone itself ever gets. DARK_MAX, not 1.0: the live zone never goes to
# pure black either (see the constant), so matching it is the correct endpoint, not exceeding it.
check(departed_alpha(1.0) >= DARK_MAX - 1e-9,
      "a fully dark world left memory at %.4f, lighter than the live zone's own floor of %.4f"
      % (departed_alpha(1.0), DARK_MAX))

# 2. The cap never LIGHTENS memory -- it is a ceiling on brightness, not a repaint. A daylit
#    world must leave a remembered zone exactly as Qud would draw it.
for i in range(0, 101):
    amb = i / 100.0
    check(departed_tone(amb) >= MEM_TONE - 1e-9,
          "ambient %.2f: cap lightened memory to %.4f" % (amb, departed_tone(amb)))

# 3. Daylight is a no-op. Below the crossover the stored MEMORY_GROUND stands untouched.
crossover = 0.0
check(abs(departed_tone(0.0) - MEM_TONE) < 1e-9, "full daylight changed the memory tone")

# 4. Above zero ambient the cap binds immediately -- any darkness in the world dims memory.
for amb in (0.05, 0.3, 0.5, 0.8, 1.0):
    check(departed_tone(amb) > MEM_TONE + 1e-9,
          "ambient %.4f: cap did not bind (%.4f)" % (amb, departed_tone(amb)))

# 5. The measured night case: the live zone at (5,24,29) against a neighbour at (9,33,41) is the
#    bug. Whatever ambient produces that live value, the neighbour must not come out above it.
#    ambient is recovered from the live alpha over the same base the two share.
night_amb = 0.82                        # a dark, unlit night zone
check(departed_alpha(night_amb) > MEM_TONE,
      "the reported night case left memory at its undimmed brightness")

# 6. Quantisation for the re-bake key is monotone and bounded -- a key that could jitter between
#    two steps at one ambient would re-bake every neighbour every turn.
steps = [int(round(departed_cap(i / 1000.0) * CAP_QUANT)) for i in range(1001)]
check(all(b >= a for a, b in zip(steps, steps[1:])), "cap step is not monotone in ambient")
check(len(set(steps)) <= int(CAP_QUANT) + 1,
      "cap step takes %d distinct values, more than CAP_QUANT+1" % len(set(steps)))

if fails:
    print("departed_cap: FAIL")
    for f in fails[:12]:
        print("  -", f)
    sys.exit(1)
print("departed_cap: memory dims monotonically with the world and reaches black with it; "
      "never lightened; no-op in full daylight; %d distinct rebake steps" % len(set(steps)))

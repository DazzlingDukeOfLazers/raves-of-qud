#!/usr/bin/env python3
"""Darkness pipeline: prove the composed rule against the if-chain it replaced.

_build_darkness answers TWO questions per cell -- TONE (what the cell IS) and VEIL (how far past
the edge of the visible it sits) -- and composes them as max(TONE, VEIL) * amax. This mirrors both
that rule and the pre-2026-08-19 if-chain in Python, and compares them over the REAL 80x25 geometry
across every cell state x light level, for the live zone and all six neighbour offsets.

Exactly ONE divergence class is expected and asserted, because it is a FIX, not a regression:
live-zone unexplored cells with light < FOG_GROUND. The old chain wrote `min(light, FOG_GROUND)`,
a ceiling on LIGHT rather than a floor on brightness, so unexplored ground only looked right in
daylight and went to alpha 0.94 -- the near-black FOG_GROUND exists to remove -- at night.

Keep the constants in step with ZoneRenderer.gd. Run it before any change to the darkness pipeline;
it is exhaustive and takes about a second, which is a better first check than a build.
"""
DARK_MAX, MEM, FOG, EDGE, SOLID_A = 0.94, 0.84, 0.70, 0.18, 0.995
W, H, R = 80, 25, 3

def lerp(a,b,t): return a+(b-a)*t
def clamp(v,lo,hi): return max(lo,min(hi,v))

def frozen_light(kx,ky,ox,oy):
    wx,wy = kx+ox, ky+oy
    dx = max(0, max(-wx, wx-(W-1))); dy = max(0, max(-wy, wy-(H-1)))
    d = max(dx,dy)
    if d <= 0: return 1.0
    t = clamp((d-1)/max(1,R), 0.0, 1.0)
    return 1.0 - lerp(EDGE, 1.0, t)

def live_edge_light(kx,ky):
    din = min(min(kx, W-1-kx), min(ky, H-1-ky))
    if din >= R+1: return 1.0
    return 1.0 - lerp(EDGE, 0.0, clamp(din/max(1,R+1),0.0,1.0))

def OLD(explored, seen, light, frozen, kx, ky, ox, oy):
    f = light
    if not explored: f = min(f, FOG)
    elif not seen:   f = MEM
    fade = 0
    if frozen:
        f = frozen_light(kx,ky,ox,oy)
        if not explored: f = min(f, FOG)
        elif f < 1.0: fade = 1
    elif not seen:
        lf = live_edge_light(kx,ky)
        if lf < 1.0 and lf <= f: fade = 2
        f = min(f, lf)
    amax = 1.0 if frozen else DARK_MAX
    return (1.0-f)*amax, fade

def veil_step(frozen): return (1.0-EDGE)/max(1,R) if frozen else EDGE/max(1,R+1)

def NEW(explored, seen, light, frozen, kx, ky, ox, oy):
    if not explored:            t = 1.0-FOG
    elif frozen or not seen:    t = 1.0-MEM
    else:                       t = 1.0-light
    v = 0.0
    if frozen: v = 1.0-frozen_light(kx,ky,ox,oy)
    elif not seen: v = 1.0-live_edge_light(kx,ky)
    kind = (1 if frozen else 2) if (v > 0.0 and v+veil_step(frozen) >= t) else 0
    amax = 1.0 if frozen else DARK_MAX
    return max(t,v)*amax, kind

cases = [("live",False,0,0)] + [("frozen%+d%+d"%(ox,oy),True,ox,oy)
         for ox,oy in [(W,0),(-W,0),(0,H),(0,-H),(W,H),(-W,-H)]]
worst = 0.0; worst_desc = None; ndiff = 0; ntot = 0
sub_old = sub_new = 0
for name,frozen,ox,oy in cases:
    for kx in range(0,W,1):
        for ky in range(0,H,1):
            for explored,seen in [(False,False),(True,False),(True,True)]:
                for light in (0.0,0.25,0.5,0.75,1.0):
                    a_o,f_o = OLD(explored,seen,light,frozen,kx,ky,ox,oy)
                    a_n,k_n = NEW(explored,seen,light,frozen,kx,ky,ox,oy)
                    ntot += 1
                    if f_o: sub_old += 1
                    if k_n: sub_new += 1
                    d = abs(a_o-a_n)
                    if d > 1e-9:
                        ndiff += 1
                        if d > worst:
                            worst, worst_desc = d, (name,kx,ky,explored,seen,light,a_o,a_n)
print("samples            %d" % ntot)
print("flat-alpha diffs   %d  (%.4f%%)" % (ndiff, 100.0*ndiff/ntot))
print("max |old-new|      %.6f" % worst)
if worst_desc: print("worst              %s" % (worst_desc,))
print("subdivided cells   old=%d  new=%d" % (sub_old, sub_new))

print("\n=== the divergence, classified ===")
kinds = {}
for name,frozen,ox,oy in cases:
    for kx in range(W):
        for ky in range(H):
            for explored,seen in [(False,False),(True,False),(True,True)]:
                for light in (0.0,0.25,0.5,0.75,1.0):
                    a_o,_ = OLD(explored,seen,light,frozen,kx,ky,ox,oy)
                    a_n,_ = NEW(explored,seen,light,frozen,kx,ky,ox,oy)
                    if abs(a_o-a_n) > 1e-9:
                        key = ("frozen" if frozen else "live", "explored=%s seen=%s"%(explored,seen),
                               "light<FOG" if light < FOG else "light>=FOG")
                        kinds.setdefault(key, [0, 0.0])
                        kinds[key][0] += 1
                        kinds[key][1] = max(kinds[key][1], abs(a_o-a_n))
for k,(n,d) in sorted(kinds.items()):
    print("  %-6s %-24s %-10s  n=%-6d max|d|=%.3f" % (k[0],k[1],k[2],n,d))

print("\n=== quads at D=16 (the SIGBUS-sensitive number) ===")
D = 16
for name,frozen,ox,oy in cases[:2]:
    for tag, fn in (("old", OLD), ("new", NEW)):
        blended = solid = flat = 0
        for kx in range(W):
            for ky in range(H):
                explored, seen, light = True, False, 0.0   # the common dusk case
                if tag == "old":
                    a,mark = OLD(explored,seen,light,frozen,kx,ky,ox,oy)
                    t_floor = 0.0
                else:
                    a,mark = NEW(explored,seen,light,frozen,kx,ky,ox,oy)
                    t_floor = (1.0-MEM) if (frozen or not seen) else 0.0
                amax = 1.0 if frozen else DARK_MAX
                if not mark:
                    flat += 1; continue
                for iy in range(D):
                    for ix in range(D):
                        # centre sample of each sub-quad, mirroring _emit_fade_cell
                        x = kx-0.5+(ix+0.5)/D; y = ky-0.5+(iy+0.5)/D
                        if frozen:
                            wx,wy = x+ox, y+oy
                            dx = max(0.0, max(-wx, wx-(W-1))); dy = max(0.0, max(-wy, wy-(H-1)))
                            d = max(dx,dy)
                            lf = 1.0 if d<=0 else 1.0-lerp(EDGE,1.0,clamp((d-1)/max(1,R),0.0,1.0))
                        else:
                            din = min(min(x, W-1-x), min(y, H-1-y))
                            lf = 1.0 if din>=R+1 else 1.0-lerp(EDGE,0.0,clamp(din/max(1,R+1),0.0,1.0))
                        aa = max(t_floor, 1.0-lf)*amax
                        if aa >= SOLID_A: solid += 1
                        elif aa >= 0.02: blended += 1
        print("  %-14s %-4s  blended=%-7d solid=%-7d flat_cells=%d" % (name,tag,blended,solid,flat))


# --- the assertion this file exists for ---
bad = []
for name,frozen,ox,oy in cases:
    for kx in range(W):
        for ky in range(H):
            for explored,seen in [(False,False),(True,False),(True,True)]:
                for light in (0.0,0.25,0.5,0.75,1.0):
                    a_o,_ = OLD(explored,seen,light,frozen,kx,ky,ox,oy)
                    a_n,_ = NEW(explored,seen,light,frozen,kx,ky,ox,oy)
                    if abs(a_o-a_n) > 1e-9:
                        # the one sanctioned class: live, never seen, darker than the fog level
                        if not (not frozen and not explored and light < FOG):
                            bad.append((name,kx,ky,explored,seen,light,a_o,a_n))
if bad:
    print("\nFAIL: %d divergence(s) outside the sanctioned class" % len(bad))
    for b in bad[:10]: print("   ", b)
    raise SystemExit(1)
print("\nPASS: the only divergence is live + never-seen + light < FOG_GROUND (the fix)")


# --- uniform-cell collapse: same picture, far fewer quads (2026-08-19) ---
FLAT_ALPHA = 1.0/255.0
D = 16

def frozen_light_at(x, y):
    dx = max(0.0, -0.5 - x, x - (W - 0.5)); dy = max(0.0, -0.5 - y, y - (H - 0.5))
    d = max(dx, dy)
    if d <= 0.0: return 1.0
    return 1.0 - lerp(EDGE, 1.0, clamp((d - 1.0)/max(1, R), 0.0, 1.0))

def veil_bounds(kx, ky, ox, oy):
    lo, hi = 1.0, 0.0
    for dy in (-0.5, 0.5):
        for dx in (-0.5, 0.5):
            v = 1.0 - frozen_light_at(kx + dx + ox, ky + dy + oy)
            lo = min(lo, v); hi = max(hi, v)
    return lo, hi

print("\n=== uniform-cell collapse (frozen zone, D=%d) ===" % D)
for ox, oy, lbl in ((W, 0, "adjacent east"), (3*W, 0, "3 zones east"), (5*W, 2*H, "far diagonal")):
    old_q = new_q = 0; bad = 0; worst = 0.0
    for kx in range(W):
        for ky in range(H):
            t = 1.0 - MEM
            v = 1.0 - frozen_light(kx, ky, ox, oy)
            if not (v > 0.0 and v + veil_step(True) >= t):
                old_q += 1; new_q += 1; continue
            old_q += D*D
            lo, hi = veil_bounds(kx, ky, ox, oy)
            a_lo, a_hi = max(t, lo)*1.0, max(t, hi)*1.0
            if a_lo >= SOLID_A or (a_hi - a_lo) <= FLAT_ALPHA:
                new_q += 1
                # every sub-sample must agree with the one quad we emit instead
                for iy in range(D):
                    for ix in range(D):
                        x = kx - 0.5 + (ix+0.5)/D; y = ky - 0.5 + (iy+0.5)/D
                        a = max(t, 1.0 - frozen_light_at(x+ox, y+oy))
                        ref = 1.0 if a_lo >= SOLID_A else a_hi
                        if a_lo >= SOLID_A:
                            if a < SOLID_A: bad += 1
                        else:
                            worst = max(worst, abs(a - ref))
                            if abs(a - ref) > FLAT_ALPHA: bad += 1
            else:
                new_q += D*D
    print("  %-15s quads %7d -> %6d  (%.0fx)   mismatched sub-samples: %d  worst da %.5f"
          % (lbl, old_q, new_q, old_q/max(1,new_q), bad, worst))
    if bad:
        raise SystemExit("FAIL: collapse changed the picture in %d sub-samples" % bad)
print("\nPASS: every collapsed cell was uniform to within 1/255 -- same picture")


# --- remembered art vs remembered field: Qud's K:k ratio (2026-08-19) ---
#
# Qud draws a remembered cell as glyph K on field k. The 1.40 between them IS the look, and it
# only survives if the art is ONE flat colour: _recolor_rgb lerps main->detail by the source art's
# LUMINANCE, so a K->k ghost paints its own brightest pixels k -- which is _world_bg, the field --
# and a remembered plant disappears into the ground it stands on. Measured on the watervine at
# (3,15): brightest pixel 0.85 of its own ground, where Qud puts it at 1.40.
#
# Nor may the art carry extra dimming "to match the ground": the field already supplies the
# contrast. Both halves of that were got wrong in one session, in opposite directions, off a
# screenshot harness that could not tell a glyph pixel from a ground pixel.
K_RGB = (21, 83, 82)   # Qud '&K', the memory foreground -- keep in step with the wire palette
k_RGB = (15, 59, 58)   # Qud '&k', the memory field == ZoneRenderer._world_bg
GHOST_MAIN = K_RGB     # ZoneRenderer: _art_colors + the _build_zone ghost texture
GHOST_DETAIL = K_RGB   # ...both ends, so the lerp cannot reach the field colour
GHOST_ART_MUL = 1.0    # ...and no extra dimming on top

print("\n=== remembered art vs the field it stands on ===")
if GHOST_DETAIL == k_RGB:
    raise SystemExit("FAIL: ghost detail is the FIELD colour -- bright art pixels vanish into it")
ratio = tuple(GHOST_MAIN[i] * GHOST_ART_MUL / k_RGB[i] for i in range(3))
print("  ghost art / field: %.2f %.2f %.2f" % ratio)
print("  Qud K:k target:    %.2f %.2f %.2f" % tuple(K_RGB[i] / k_RGB[i] for i in range(3)))
for i in range(3):
    if abs(ratio[i] - K_RGB[i] / k_RGB[i]) > 0.01:
        raise SystemExit("FAIL: remembered art no longer sits at Qud's K:k above the field")
print("PASS: remembered art sits at Qud's K:k above the field")

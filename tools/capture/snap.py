#!/usr/bin/env python3
"""Read one zone snapshot off the Raves bridge and report on it.

This replaces the pile of one-off capture scripts. It lives in the repo (not a
temp dir) so its path is stable across sessions and can be permitted once.

A frame is only published when the player TAKES A TURN, so every command here
waits. It also reconnects on EOF, since restarting Qud (required after any mod
.cs change) drops the socket.

    python3 tools/capture/snap.py summary
    python3 tools/capture/snap.py cell 66 6
    python3 tools/capture/snap.py families        # tile family x layer/flags
    python3 tools/capture/snap.py water           # depth flags vs water tiles
    python3 tools/capture/snap.py find glowfish   # locate objects by tile/glyph
    python3 tools/capture/snap.py raw > snap.json
"""
import json
import re
import socket
import struct
import sys
import time
from collections import Counter, defaultdict

PORT = 48710


def _recv(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def grab(timeout=1800):
    """Block until Qud publishes a frame. Reconnects if the game restarts."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", PORT), timeout=2)
        except OSError:
            time.sleep(1)
            continue
        try:
            sock.settimeout(min(600, max(5, deadline - time.time())))
            head = _recv(sock, 4)
            if head is None:
                time.sleep(1)
                continue
            body = _recv(sock, struct.unpack(">I", head)[0])
            if body is None:
                time.sleep(1)
                continue
            return json.loads(body.decode())
        except (OSError, ValueError):
            time.sleep(1)
        finally:
            sock.close()
    sys.exit("no snapshot — is Qud running, and did you take a turn?")


def base(tile):
    """Filename of a tile path, tolerating BOTH separators (Qud mixes them)."""
    return tile.replace("\\", "/").split("/")[-1]


def family(tile):
    """Collapse an autotile bitmask so variants group: wall_rock-0110 -> -*"""
    return re.sub(r"[-_][01]{8}", "-*", base(tile))


def header(snap):
    z, p = snap.get("zone", {}), snap.get("player", {})
    print(f"zone {z.get('id')}  {z.get('width')}x{z.get('height')}   "
          f"player ({p.get('x')},{p.get('y')})   cells {len(snap.get('cells', []))}")


def cmd_summary(snap, _args):
    header(snap)
    cells = snap.get("cells", [])
    flags = Counter()
    for c in cells:
        for k in ("bridge", "wade", "swim"):
            if c.get(k):
                flags[k] += 1
    objs = [o for c in cells for o in c.get("objs", [])]
    print(f"objects {len(objs)}   cell flags: " +
          "  ".join(f"{k}={flags[k]}" for k in ("bridge", "wade", "swim")))
    print("\nby layer:")
    for layer, n in sorted(Counter(o.get("layer") for o in objs).items(),
                           key=lambda kv: (kv[0] is None, kv[0])):
        print(f"  layer {layer:<4} n={n}")
    print("\nobject flags:")
    for k in ("wall", "occluding", "solid", "bridge", "sinks"):
        print(f"  {k:<10} {sum(1 for o in objs if o.get(k))}")
    missing = sorted({o.get("tile", "") for o in objs if not o.get("tile")})
    if missing:
        print(f"\n{len(missing)} object(s) with no tile (render as glyphs)")


def cmd_cell(snap, args):
    if len(args) < 2:
        sys.exit("usage: snap.py cell X Y")
    cx, cy = int(args[0]), int(args[1])
    header(snap)
    for c in snap.get("cells", []):
        if c.get("x") == cx and c.get("y") == cy:
            print(f"\ncell ({cx},{cy})  bridge={c.get('bridge')} "
                  f"wade={c.get('wade')} swim={c.get('swim')}")
            for i, o in enumerate(c.get("objs", [])):
                print(f"\n [{i}] layer={o.get('layer')} glyph={o.get('glyph')!r}")
                print(f"     tile   {o.get('tile','')!r}")
                print(f"     png    {o.get('tile','').replace('/', '_').replace(chr(92), '_')}")
                print(f"     colour color={o.get('color','')!r} "
                      f"tilecolor={o.get('tilecolor','')!r} detail={o.get('detail','')!r}")
                print("     flags  " + " ".join(
                    f"{k}={int(bool(o.get(k)))}"
                    for k in ("wall", "occluding", "solid", "bridge", "sinks")))
            return
    print(f"\ncell ({cx},{cy}) is EMPTY — Qud only sends non-empty cells.")


def cmd_families(snap, _args):
    header(snap)
    agg = defaultdict(lambda: {"n": 0, "layers": Counter(), "flags": Counter(), "colors": Counter()})
    for c in snap.get("cells", []):
        for o in c.get("objs", []):
            a = agg[family(o.get("tile", "")) or "(no tile)"]
            a["n"] += 1
            a["layers"][o.get("layer")] += 1
            a["colors"][o.get("color", "")] += 1
            for k in ("wall", "occluding", "solid", "bridge", "sinks"):
                if o.get(k):
                    a["flags"][k] += 1
    print(f"\n{'family':<52} {'n':<5} layers      flags")
    for fam, a in sorted(agg.items(), key=lambda kv: -kv[1]["n"])[:40]:
        layers = ",".join(str(l) for l, _ in a["layers"].most_common(3))
        flags = ",".join(f"{k}:{v}" for k, v in a["flags"].most_common())
        print(f"  {fam[:50]:<52} {a['n']:<5} {layers:<11} {flags}")


def cmd_water(snap, _args):
    header(snap)
    by_depth = defaultdict(Counter)
    for c in snap.get("cells", []):
        depth = "swim" if c.get("swim") else ("wade" if c.get("wade") else "dry")
        for o in c.get("objs", []):
            t = o.get("tile", "")
            if "water" in t.lower() or "liquid" in t.lower():
                by_depth[depth][family(t)] += 1
    print("\nwater tile family x cell depth:")
    for depth in ("swim", "wade", "dry"):
        print(f"  {depth}:" + ("" if by_depth[depth] else " (none)"))
        for fam, n in by_depth[depth].most_common(8):
            print(f"      n={n:<4} {fam}")
    print("\nbridge cells (full stack — the deck must out-Y and cover the water):")
    for c in snap.get("cells", []):
        if c.get("bridge"):
            print(f"  ({c['x']},{c['y']}) wade={c.get('wade')} swim={c.get('swim')}")
            for i, o in enumerate(c.get("objs", [])):
                print(f"      idx={i} layer={o.get('layer')} bridge={int(bool(o.get('bridge')))} "
                      f"{o.get('tile','')!r} {o.get('color','')!r}")
    print("\nactors that render submerged:")
    any_sub = False
    for c in snap.get("cells", []):
        if c.get("bridge") or not (c.get("wade") or c.get("swim")):
            continue
        for o in c.get("objs", []):
            if o.get("sinks"):
                any_sub = True
                print(f"  ({c['x']},{c['y']}) {'swim' if c.get('swim') else 'wade'} "
                      f"{o.get('glyph')!r} {o.get('tile','')!r}")
    if not any_sub:
        print("  (none — walk into deep water)")


def cmd_find(snap, args):
    if not args:
        sys.exit("usage: snap.py find <substring>")
    needle = args[0].lower()
    header(snap)
    print(f"\nobjects matching {needle!r}:")
    hits = 0
    for c in snap.get("cells", []):
        for i, o in enumerate(c.get("objs", [])):
            if needle in o.get("tile", "").lower() or needle == o.get("glyph", "").lower():
                hits += 1
                print(f"  ({c['x']},{c['y']}) idx={i} layer={o.get('layer')} "
                      f"{o.get('tile','')!r} color={o.get('color','')!r} "
                      f"bridge={int(bool(o.get('bridge')))} sinks={int(bool(o.get('sinks')))}")
                if hits >= 60:
                    print("  … truncated at 60")
                    return
    if not hits:
        print("  (none)")


def cmd_raw(snap, _args):
    json.dump(snap, sys.stdout, indent=1)


COMMANDS = {
    "summary": cmd_summary, "cell": cmd_cell, "families": cmd_families,
    "water": cmd_water, "find": cmd_find, "raw": cmd_raw,
}

if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "summary"
    if name not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[name](grab(), sys.argv[2:])

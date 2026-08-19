#!/usr/bin/env python3
"""Walk a FOUR-ZONE CORNER and check every neighbour is wearing the right fade.

    python3 tools/capture/zonewalk.py            # walk the corner, assert, report
    python3 tools/capture/zonewalk.py --steps 6  # more crossings

WHAT IT IS FOR
--------------
A departed zone fades from the edge it SHARES with the zone you are standing in
(ZoneRenderer._frozen_light): an edge neighbour fades along a whole side, a diagonal one only
from its corner. Which of those a zone is owed depends on where it sits RELATIVE to the live
zone -- so it changes as you walk, and a zone that keeps an old orientation is wrong in a way
that is easy to miss by eye: a lit band down one edge and a corner fade look similar until you
know which you should be seeing.

That is exactly the bug this was written for. The bake was guarded by a bake-once meta, so
walking SE -> S -> N left the SE zone still wearing the ramp it earned as an EAST neighbour of
the S zone. Daniel: "the SE zone is showing a light all around the zone, when it should just be
the corner." A corner is the case a single crossing never exercises, which is why the walk goes
around a corner rather than back and forth.

HOW IT CHECKS
-------------
Not from pixels, and not from the wire either: NEIGHBOURS ARE NOT ON THE WIRE. They live in the
client's own WorldStore, accumulated from zones the player has visited, so a snapshot carries
only the LIVE zone. What the check uses instead is arithmetic the ids already encode --
`JoppaWorld.<pa>.<pb>.<zx>.<zy>.<z>`, one zone step being 80 cells in x and 25 in y:

    expected offset = ((zx - live_zx) * 80, (zy - live_zy) * 25)

ZoneRenderer prints `[zonefade] <zone id> off=(x,y)` once per zone per re-bake, so the assertion
is that every zone's LAST bake matches the offset its id says it should have from where the
player is standing now. That is a stronger check than reading a reported offset back: it
verifies the offset arithmetic as well as the freshness.
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

LOG = os.path.expanduser(
    "~/Library/Application Support/Godot/app_userdata/Raves of Qud/logs/raves.log")
HERE = os.path.dirname(os.path.abspath(__file__))
FADE = re.compile(r"\[zonefade\] (\S+) off=\((-?\d+),(-?\d+)\)")


ZID = re.compile(r"^(.*)\.(-?\d+)\.(-?\d+)\.(-?\d+)$")
ZONE_W, ZONE_H = 80, 25


def zone_xy(zid):
    """(world prefix, zx, zy, z) or None — the coordinates baked into a zone id."""
    m = ZID.match(zid)
    if not m:
        return None
    return m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))


def kick():
    """The bridge only publishes on a TURN, so take one before reading."""
    subprocess.run(["hv", "bridge", "wait"], capture_output=True, text=True, timeout=30)


def snapshot(timeout=25.0, kick_first=True):
    """One bridge frame — the LIVE zone. (Neighbours are client-side; see the module doc.)

    CONNECT, THEN take the turn. The mod BROADCASTS when a turn resolves and does not replay for a
    client that arrives afterwards, so kicking first and connecting second misses the frame.

    The wire is LENGTH-PREFIXED -- [4-byte big-endian length][JSON] -- the same framing
    tools/capture/snap.py reads. Treating it as newline-delimited JSON (which an earlier version of
    this file did) mostly returns nothing, because the length bytes sit in front of the object.
    """
    import struct
    s = socket.create_connection(("127.0.0.1", 48710), 10)
    s.settimeout(timeout)
    if kick_first:
        threading.Thread(target=kick, daemon=True).start()

    def recvn(n):
        buf = b""
        while len(buf) < n:
            try:
                chunk = s.recv(n - len(buf))
            except socket.timeout:
                return None
            if not chunk:
                return None
            buf += chunk
        return buf

    try:
        end = time.time() + timeout
        while time.time() < end:
            head = recvn(4)
            if head is None:
                return None
            body = recvn(struct.unpack(">I", head)[0])
            if body is None:
                return None
            try:
                j = json.loads(body.decode("utf8", "ignore"))
            except Exception:
                continue
            if isinstance(j, dict) and j.get("cells") is not None:
                return j
    finally:
        s.close()
    return None


def baked_offsets():
    """zone id -> the offset its darkness was LAST baked for."""
    out = {}
    if not os.path.exists(LOG):
        return out
    with open(LOG, errors="ignore") as fh:
        for line in fh:
            m = FADE.search(line)
            if m:
                out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out


def move(direction, n):
    subprocess.run([sys.executable, os.path.join(HERE, "control.py"), "move", direction, str(n)],
                   capture_output=True, text=True)


def kind(off):
    """What shape of fade an offset is owed — the distinction the bug blurred."""
    if off[0] and off[1]:
        return "corner"
    return "edge"


def check(_step, tries=3):
    """Every baked zone wears the ramp its id says it is owed from where we stand NOW.

    RETRIED, because the bridge publishes on a TURN and a read can arrive between them -- a
    single miss is a quiet no-snapshot that looks like the game is down when it is merely
    idle. Each attempt takes its own turn first.
    """
    snap = None
    for _ in range(max(1, tries)):
        snap = snapshot(timeout=12.0)
        if snap is not None:
            break
    if snap is None:
        # SAY WHY. The bridge publishes on a TURN, and the commonest reason turns stop is a POPUP
        # parking the turn thread -- a journal notice waiting on [Space] will sit there forever.
        # "is Qud in-game?" sent us both looking at the wrong thing; the state report knows.
        why = "no snapshot after %d turns" % tries
        try:
            st = subprocess.run(["hv", "state"], capture_output=True, text=True, timeout=20).stdout
            for line in st.splitlines():
                if line.startswith("qud"):
                    if "popup=" in line:
                        why += " — QUD IS ON A POPUP, which parks the turn thread: %s" % line.strip()
                    else:
                        why += " — qud: %s" % line.strip()
        except Exception:
            pass
        return None, None, [why]
    live = str(snap.get("zone", {}).get("id", "?"))
    lxy = zone_xy(live)
    if lxy is None:
        return live, None, ["cannot parse live zone id %r" % live]
    baked = baked_offsets()
    problems = []
    seen = 0
    for zid, got in sorted(baked.items()):
        nxy = zone_xy(zid)
        if nxy is None or nxy[0] != lxy[0] or nxy[3] != lxy[3]:
            continue                       # another world or another stratum: not our business
        if zid == live:
            continue                       # the live zone bakes no frozen ramp
        want = ((nxy[1] - lxy[1]) * ZONE_W, (nxy[2] - lxy[2]) * ZONE_H)
        if abs(nxy[1] - lxy[1]) > 1 or abs(nxy[2] - lxy[2]) > 1:
            continue                       # not adjacent; it may legitimately be unloaded
        seen += 1
        if got != want:
            problems.append("%s wears %s off=%s but is a %s at off=%s"
                            % (zid, kind(got), got, kind(want), want))
    return live, seen, problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--steps", type=int, default=4,
                    help="crossings to make (default 4 = once around the corner)")
    # PER AXIS, because a zone is 80 WIDE and 25 TALL. One distance for both meant the E/W legs
    # never crossed anything and the walk just bounced between two zones -- reporting PASS while
    # never once reaching the corner it exists to test.
    ap.add_argument("--dist-x", type=int, default=82, help="tiles per E/W crossing (zone is 80 wide)")
    ap.add_argument("--dist-y", type=int, default=27, help="tiles per N/S crossing (zone is 25 tall)")
    a = ap.parse_args(argv)

    # Around a corner, so a zone is an EDGE neighbour at one step and a DIAGONAL one at the next
    # -- the transition the bake-once bug got wrong and a there-and-back walk never reaches.
    route = ["S", "E", "N", "W"]
    failures = 0
    live, seen, problems = check(0)
    print("start: live=%s  adjacent zones baked=%s" % (live, seen))
    for problem in problems:
        print("   FAIL %s" % problem)
    failures += len(problems)

    for i in range(a.steps):
        d = route[i % len(route)]
        print("\nstep %d/%d: walking %s" % (i + 1, a.steps, d))
        move(d, a.dist_x if d in ("E", "W") else a.dist_y)
        time.sleep(4)                      # let the neighbour sync + re-bake land
        live, seen, problems = check(i + 1)
        if seen is None:
            print("   ENV  %s" % problems[0])
            continue
        print("   live=%s  adjacent zones baked=%d" % (live, seen))
        for problem in problems:
            print("   FAIL %s" % problem)
        if not problems:
            print("   ok   every adjacent zone wears the ramp for where it is now")
        failures += len(problems)

    print("\n%s (%d problem(s))" % ("PASS" if failures == 0 else "FAIL", failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Harness drive — move the character while BOTH windows stay live and in sync,
for side-by-side human demos.

THE TRICK (see docs/legacy-integration-playbook.md, Plane 2): on macOS only the
FOCUSED window renders live. Godot can now render while unfocused (its background
force_draw); Qud can NOT. So we keep QUD focused and let the Godot viewer mirror in
the background — and both stay live. Driving from Godot's own keys would do the
opposite (Qud unfocused -> frozen), which is the one config that can't work.

Two drive mechanisms, same live-sync result because Qud stays focused either way:
  * default: moves over the bridge (reliable 8-way, snapshot-confirmed each step).
  * --keys : real OS keystrokes (numpad) — the fully-human path through Qud's input.

USAGE
  harness.py drive N 3 E 2 S 3 W 2       # walk a square; both windows update live
  harness.py drive N 5 --shot            # 5 north, then capture both renders
  harness.py drive NE 4 --keys           # drive via OS keystrokes instead of the bridge
  harness.py drive N 3 --pace 0.6        # slower, for a human audience

Requires Qud running (+ the bridge mod). `--keys` needs Accessibility (see desktop.py).
The Godot viewer should be open and reloaded with the background-render fix.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import control
import desktop

DIRS = ["N", "S", "E", "W", "NE", "NW", "SE", "SW"]
# 8-way -> Qud's default numpad movement keys (for --keys mode)
DIR_KP = {"N": "KP8", "S": "KP2", "E": "KP6", "W": "KP4",
          "NE": "KP9", "NW": "KP7", "SE": "KP3", "SW": "KP1"}


def parse_moves(tokens):
    """['N','3','E','2'] -> [('N',3),('E',2)]."""
    out = []
    i = 0
    while i < len(tokens):
        d = tokens[i].upper()
        if d not in DIRS:
            raise SystemExit("bad direction %r (use %s)" % (tokens[i], "/".join(DIRS)))
        n = 1
        if i + 1 < len(tokens) and tokens[i + 1].isdigit():
            n = int(tokens[i + 1]); i += 1
        out.append((d, n))
        i += 1
    return out


def drive(moves, use_keys=False, pace=0.35, shot=False):
    # Focus Qud so its map renders live; the Godot viewer keeps rendering in the
    # background on its own (force_draw). Nothing below steals focus back.
    desktop.activate("Qud")
    time.sleep(0.5)
    if use_keys and not desktop.check():
        raise SystemExit("--keys needs Accessibility (run: desktop.py check)")

    b = control.Bridge()
    steps = 0
    for d, n in moves:
        for _ in range(n):
            if use_keys:
                desktop.key(DIR_KP[d])          # OS keystroke into focused Qud
                time.sleep(pace)
            else:
                b.move(d)                        # bridge move; Qud focused -> renders live
                time.sleep(max(0.0, pace - 0.05))
            steps += 1
    # report where we ended (a bridge read; also confirms game state)
    p = b.read_snapshot().get("player", {}) if not use_keys else None
    if p is not None:
        print("drove %d step(s) -> player (%s,%s)" % (steps, p.get("x"), p.get("y")))
    else:
        print("drove %d step(s) via OS keys (Qud focused, both windows live)" % steps)
    b.close()

    if shot:
        # capture both renders — Qud (focused, live) and the Godot viewer (background)
        print("qud_shot:", control.qud_shot())
        desktop.activate("Qud")   # re-focus after the godot shot poke, keep Qud live
        print("shot.png:", control.godot_shot())


def main(argv):
    if not argv or argv[0] != "drive":
        sys.exit(__doc__)
    args = argv[1:]
    use_keys = "--keys" in args
    shot = "--shot" in args
    pace = 0.35
    if "--pace" in args:
        pace = float(args[args.index("--pace") + 1])
    # strip flags (and --pace's value) to leave the move tokens
    skip = set()
    for f in ("--keys", "--shot"):
        while f in args:
            args.remove(f)
    if "--pace" in args:
        i = args.index("--pace"); del args[i:i + 2]
    moves = parse_moves(args)
    if not moves:
        sys.exit("no moves given.\n" + __doc__)
    drive(moves, use_keys=use_keys, pace=pace, shot=shot)


if __name__ == "__main__":
    main(sys.argv[1:])

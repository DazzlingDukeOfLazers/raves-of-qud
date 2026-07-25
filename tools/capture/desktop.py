#!/usr/bin/env python3
"""desktop.py — CLI front-end for the OS-input harness (drive Qud/Godot with real
mouse, keys, and window focus). The actual implementation is per-OS in plat_mac.py /
plat_win.py, dispatched by plat.py; this file is the stable command interface, and it
re-exports the API so `import desktop; desktop.click(...)` works on any OS.

  desktop.py check                 # is synthetic input permitted for this host?
  desktop.py bounds Qud            # window rect {x,y,w,h}
  desktop.py activate Qud          # focus Qud (or Godot) — also refreshes its render
  desktop.py move  X Y             # warp cursor
  desktop.py click X Y             # left click   (rclick / dclick also)
  desktop.py clickin Qud FX FY     # click at a FRACTION of the window (robust to position)
  desktop.py key Return            # one key (Return/Escape/arrows/KP1..9/F1../letter/digit)
  desktop.py type "text"           # type a string

macOS needs Accessibility for synthetic input (see `check`); geometry/activate don't.
Contract + per-OS backends: plat.py. Usage detail: docs/tools.md.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat
# re-export the input/window API so `import desktop` keeps working across the tools
from plat import (check, require, bounds, activate, clickin, move, click,   # noqa: F401
                  rclick, dclick, key, type_text, cursor)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    if cmd == "check":
        ok = check()
        print("input permitted: GRANTED" if ok else "input permitted: NO.\n  " + plat.PERM_HINT)
        sys.exit(0 if ok else 1)
    try:
        if cmd == "bounds":
            print(json.dumps(bounds(argv[1])))
        elif cmd == "activate":
            activate(argv[1]); print("activated", argv[1])
        elif cmd == "cursor":
            print(cursor())
        elif cmd in ("move", "click", "rclick", "dclick"):
            require()
            x, y = float(argv[1]), float(argv[2])
            {"move": move, "click": click, "rclick": rclick, "dclick": dclick}[cmd](x, y)
            print(cmd, int(x), int(y))
        elif cmd == "clickin":
            require()
            x, y = clickin(argv[1], float(argv[2]), float(argv[3]))
            print("clicked %s at screen (%.0f, %.0f)" % (argv[1], x, y))
        elif cmd == "key":
            require(); key(argv[1]); print("key", argv[1])
        elif cmd == "type":
            require(); type_text(argv[1]); print("typed")
        else:
            sys.exit(__doc__)
    except (RuntimeError, ValueError) as e:
        sys.exit("ERROR: " + str(e))


if __name__ == "__main__":
    main(sys.argv[1:])

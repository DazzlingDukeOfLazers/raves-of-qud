#!/usr/bin/env python3
"""OS-level desktop input for the Raves test harness — drive Qud (or the Godot viewer)
the way a human does: real mouse clicks, keystrokes, and window focus.

WHY THIS EXISTS. The bridge (control.py) can send movement + a few commands, but it
can NOT reach Qud's visual UI — menus, inventory, dialogs, ability bar, the character
sheet. Those are Unity UI, not part of the command API. This drives them at the OS
level, exactly like a human clicking. Two bonuses fall out of it:
  * Clicking the Qud window FOCUSES it, which refreshes its render — the fallback for
    "Qud's map doesn't repaint while unfocused" (a macOS limit; see docs/tools.md).
  * It's deterministic + scriptable, so harness runs reproduce across machines from a
    shared seed (parallel Claude instances, same inputs).

PERMISSION (one-time). Posting synthetic input requires ACCESSIBILITY permission for
whatever process runs this (System Settings > Privacy & Security > Accessibility).
Window bounds via System Events needs it too. Without it every command errors with
`-1719 not allowed assistive access` / the CGEvent silently no-ops. Grant it to the
host terminal/app once, then re-run.

USAGE
  desktop.py bounds CoQ              # window rect {x,y,w,h} in screen points (JSON)
  desktop.py activate CoQ            # focus Qud (or Godot) — also refreshes its render
  desktop.py move  X Y               # warp cursor to screen X,Y
  desktop.py click X Y               # left click at screen X,Y
  desktop.py rclick X Y              # right click
  desktop.py dclick X Y              # double click
  desktop.py clickin CoQ FX FY       # click at FRACTION (0..1,0..1) of CoQ's window
  desktop.py key Return              # one named key (Return, Escape, Space, Tab, F1, a..z, 0..9)
  desktop.py type "some text"        # type a literal string
  desktop.py check                   # report whether Accessibility is granted

`clickin` is the one to use with qud_shot: find an element's fractional position in the
capture, then click that fraction of the live window — robust to where the window sits.
"""
import ctypes
import ctypes.util
import json
import subprocess
import sys
import time

# --- CoreGraphics event posting via ctypes (no pyobjc/brew needed) ------------
_cg_path = (ctypes.util.find_library("CoreGraphics")
            or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_cg = ctypes.CDLL(_cg_path)

# AXIsProcessTrusted(): canonical "is this process allowed to post synthetic input"
_appsvc = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
_appsvc.AXIsProcessTrusted.restype = ctypes.c_bool


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
_cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_cg.CGEventSetType.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
_cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]

# CGEventType
_LDOWN, _LUP, _RDOWN, _RUP, _MOVED = 1, 2, 3, 4, 5
_HID_TAP = 0            # kCGHIDEventTap
_BTN_LEFT, _BTN_RIGHT = 0, 1


def _post_mouse(x, y, down, up, button, clicks=1):
    for _ in range(clicks):
        for t in (down, up):
            ev = _cg.CGEventCreateMouseEvent(None, t, CGPoint(x, y), button)
            _cg.CGEventPost(_HID_TAP, ev)
            time.sleep(0.02)
        time.sleep(0.03)


def move(x, y):
    _cg.CGWarpMouseCursorPosition(CGPoint(x, y))


def click(x, y):
    move(x, y)
    _post_mouse(x, y, _LDOWN, _LUP, _BTN_LEFT)


def rclick(x, y):
    move(x, y)
    _post_mouse(x, y, _RDOWN, _RUP, _BTN_RIGHT)


def dclick(x, y):
    move(x, y)
    _post_mouse(x, y, _LDOWN, _LUP, _BTN_LEFT, clicks=2)


# --- window geometry + focus + keys via System Events -------------------------
def _osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def bounds(app):
    """Front window rect of `app` (e.g. CoQ, Godot) as {x,y,w,h} in screen points."""
    out = _osa(
        'tell application "System Events" to tell (first process whose name is "%s") '
        'to get {position, size} of window 1' % app)
    nums = [int(n) for n in out.replace(" ", "").split(",")]
    return {"x": nums[0], "y": nums[1], "w": nums[2], "h": nums[3]}


def activate(app):
    _osa('tell application "%s" to activate' % app)


def clickin(app, fx, fy):
    b = bounds(app)
    x = b["x"] + fx * b["w"]
    y = b["y"] + fy * b["h"]
    click(x, y)
    return (x, y)


# key name -> System Events key code (the finicky ones); letters/digits go via keystroke
_KEYCODES = {
    "Return": 36, "Enter": 36, "Tab": 48, "Space": 49, "Escape": 53, "Esc": 53,
    "Delete": 51, "Backspace": 51, "Up": 126, "Down": 125, "Left": 123, "Right": 124,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
    "F9": 101, "F10": 109, "F11": 103, "F12": 111,
}


def key(name):
    if name in _KEYCODES:
        _osa('tell application "System Events" to key code %d' % _KEYCODES[name])
    elif len(name) == 1:
        _osa('tell application "System Events" to keystroke "%s"' % name.replace('"', '\\"'))
    else:
        raise ValueError("unknown key: %s (use a single char or %s)" % (name, sorted(_KEYCODES)))


def type_text(text):
    _osa('tell application "System Events" to keystroke "%s"' % text.replace('\\', '\\\\').replace('"', '\\"'))


def check():
    """True if THIS host process is trusted for Accessibility (may post input +
    read window geometry). Uses the canonical AXIsProcessTrusted() — not a proxy."""
    return bool(_appsvc.AXIsProcessTrusted())


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    try:
        if cmd == "check":
            ok = check()
            print("Accessibility: GRANTED" if ok else
                  "Accessibility: NOT granted.\n"
                  "  System Settings > Privacy & Security > Accessibility\n"
                  "  -> enable 'Claude' (/Applications/Claude.app), then retry.")
            sys.exit(0 if ok else 1)
        elif cmd == "bounds":
            print(json.dumps(bounds(argv[1])))
        elif cmd == "activate":
            activate(argv[1]); print("activated", argv[1])
        elif cmd == "move":
            move(float(argv[1]), float(argv[2])); print("moved")
        elif cmd == "click":
            click(float(argv[1]), float(argv[2])); print("clicked", argv[1], argv[2])
        elif cmd == "rclick":
            rclick(float(argv[1]), float(argv[2])); print("rclicked")
        elif cmd == "dclick":
            dclick(float(argv[1]), float(argv[2])); print("dclicked")
        elif cmd == "clickin":
            x, y = clickin(argv[1], float(argv[2]), float(argv[3]))
            print("clicked %s at screen (%.0f, %.0f)" % (argv[1], x, y))
        elif cmd == "key":
            key(argv[1]); print("key", argv[1])
        elif cmd == "type":
            type_text(argv[1]); print("typed")
        else:
            sys.exit(__doc__)
    except RuntimeError as e:
        msg = str(e)
        if "1719" in msg or "assistive access" in msg:
            sys.exit("ERROR: Accessibility not granted. System Settings > Privacy & "
                     "Security > Accessibility — add the host app, then retry.\n(%s)" % msg)
        sys.exit("ERROR: " + msg)


if __name__ == "__main__":
    main(sys.argv[1:])

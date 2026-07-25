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

PERMISSION (one-time). Posting synthetic input needs ACCESSIBILITY for the HOST process
(here /Applications/Claude.app). Grant: System Settings > Privacy & Security >
Accessibility > enable Claude. Everything below runs IN-PROCESS via ctypes so it uses
that grant directly — we deliberately avoid shelling to `osascript` for anything that
needs Accessibility, because a spawned osascript is a separate, untrusted process.
(`activate` is the one exception: it's an Apple Event, which osascript may do.)

USAGE
  desktop.py check                   # is Accessibility granted for this host?
  desktop.py bounds CoQ              # window rect {x,y,w,h} in screen points (JSON)
  desktop.py activate CoQ            # focus Qud (or Godot) — also refreshes its render
  desktop.py move  X Y               # warp cursor to screen X,Y
  desktop.py click X Y               # left click at screen X,Y
  desktop.py rclick X Y              # right click
  desktop.py dclick X Y              # double click
  desktop.py clickin CoQ FX FY       # click at FRACTION (0..1,0..1) of CoQ's window
  desktop.py key Return              # one named key (Return/Escape/Space/Tab/arrows/F1.. or a char)
  desktop.py type "some text"        # type a literal string

`clickin` is the one to use with qud_shot: find an element's fractional position in the
capture, then click that fraction of the live window — robust to where the window sits.
"""
import ctypes
import ctypes.util
import json
import subprocess
import sys
import time

_cg_path = (ctypes.util.find_library("CoreGraphics")
            or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_cg = ctypes.CDLL(_cg_path)
_cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_appsvc = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
_appsvc.AXIsProcessTrusted.restype = ctypes.c_bool


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGSize)]


# mouse
_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
_cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]
_cg.CGEventCreate.restype = ctypes.c_void_p
_cg.CGEventCreate.argtypes = [ctypes.c_void_p]
_cg.CGEventGetLocation.restype = CGPoint
_cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
# keyboard
_cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_cg.CGEventKeyboardSetUnicodeString.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
# window list
_cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
_cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
_cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
_cg.CGRectMakeWithDictionaryRepresentation.argtypes = [ctypes.c_void_p, ctypes.POINTER(CGRect)]
# CoreFoundation containers
_cf.CFArrayGetCount.restype = ctypes.c_long
_cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
_cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
_cf.CFDictionaryGetValue.restype = ctypes.c_void_p
_cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFNumberGetValue.restype = ctypes.c_bool
_cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
_cf.CFRelease.argtypes = [ctypes.c_void_p]

_LDOWN, _LUP, _RDOWN, _RUP = 1, 2, 3, 4
_HID_TAP = 0
_BTN_LEFT, _BTN_RIGHT = 0, 1
_ON_SCREEN, _NULL_WIN = 1, 0
_UTF8 = 0x08000100
_INT_TYPE = 9  # kCFNumberIntType
_kOwnerName = ctypes.c_void_p.in_dll(_cg, "kCGWindowOwnerName")
_kBounds = ctypes.c_void_p.in_dll(_cg, "kCGWindowBounds")
_kLayer = ctypes.c_void_p.in_dll(_cg, "kCGWindowLayer")


# App names differ per API: CGWindowList uses the window OWNER name, osascript uses the
# APPLICATION name. Qud: owner "CavesOfQud", app "CoQ". Accept a friendly alias for both.
_APPS = {
    "qud": ("CavesOfQud", "CoQ"),
    "coq": ("CavesOfQud", "CoQ"),
    "cavesofqud": ("CavesOfQud", "CoQ"),
    "godot": ("Godot", "Godot"),
}


def _resolve(app):
    """friendly/any name -> (windowlist-owner-name, osascript-app-name)."""
    return _APPS.get(app.lower(), (app, app))


# --- Accessibility --------------------------------------------------------------
def check():
    """True if this host process is trusted for Accessibility (canonical API)."""
    return bool(_appsvc.AXIsProcessTrusted())


def _require():
    if not check():
        sys.exit("ERROR: Accessibility not granted. System Settings > Privacy & Security > "
                 "Accessibility -> enable 'Claude' (/Applications/Claude.app), then retry.")


# --- mouse ----------------------------------------------------------------------
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
    move(x, y); time.sleep(0.02)
    _post_mouse(x, y, _LDOWN, _LUP, _BTN_LEFT)


def rclick(x, y):
    move(x, y); time.sleep(0.02)
    _post_mouse(x, y, _RDOWN, _RUP, _BTN_RIGHT)


def dclick(x, y):
    move(x, y); time.sleep(0.02)
    _post_mouse(x, y, _LDOWN, _LUP, _BTN_LEFT, clicks=2)


def cursor():
    e = _cg.CGEventCreate(None)
    p = _cg.CGEventGetLocation(e)
    return (round(p.x), round(p.y))


# --- keyboard -------------------------------------------------------------------
# AppleScript/Carbon virtual keycodes for the finicky keys; chars go via unicode string.
_KEYCODES = {
    "Return": 36, "Enter": 36, "Tab": 48, "Space": 49, "Escape": 53, "Esc": 53,
    "Delete": 51, "Backspace": 51, "Up": 126, "Down": 125, "Left": 123, "Right": 124,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
    "F9": 101, "F10": 109, "F11": 103, "F12": 111,
}


def _post_char(ch):
    buf = (ctypes.c_uint16 * len(ch))(*[ord(c) for c in ch])
    for down in (True, False):
        ev = _cg.CGEventCreateKeyboardEvent(None, 0, down)
        _cg.CGEventKeyboardSetUnicodeString(ev, len(ch), buf)
        _cg.CGEventPost(_HID_TAP, ev)
        time.sleep(0.008)


def _post_keycode(kc):
    for down in (True, False):
        ev = _cg.CGEventCreateKeyboardEvent(None, kc, down)
        _cg.CGEventPost(_HID_TAP, ev)
        time.sleep(0.01)


def key(name):
    if name in _KEYCODES:
        _post_keycode(_KEYCODES[name])
    elif len(name) == 1:
        _post_char(name)
    else:
        raise ValueError("unknown key %r (use a single char or one of %s)" % (name, sorted(_KEYCODES)))


def type_text(text):
    for ch in text:
        _post_char(ch)
        time.sleep(0.01)


# --- window geometry (in-process; no osascript) ---------------------------------
def _cfstr(ref):
    if not ref:
        return None
    buf = ctypes.create_string_buffer(512)
    if _cf.CFStringGetCString(ref, buf, 512, _UTF8):
        return buf.value.decode("utf-8")
    return None


def _cfint(ref):
    v = ctypes.c_long()
    _cf.CFNumberGetValue(ref, _INT_TYPE, ctypes.byref(v))
    return v.value


def bounds(app):
    """Largest on-screen normal (layer 0) window of `app`, as {x,y,w,h} screen points."""
    owner = _resolve(app)[0]
    arr = _cg.CGWindowListCopyWindowInfo(_ON_SCREEN, _NULL_WIN)
    if not arr:
        raise RuntimeError("CGWindowListCopyWindowInfo returned null")
    best = None
    try:
        for i in range(_cf.CFArrayGetCount(arr)):
            d = _cf.CFArrayGetValueAtIndex(arr, i)
            if _cfstr(_cf.CFDictionaryGetValue(d, _kOwnerName)) != owner:
                continue
            if _cfint(_cf.CFDictionaryGetValue(d, _kLayer)) != 0:
                continue  # skip menubar/overlay/status layers
            rect = CGRect()
            if not _cg.CGRectMakeWithDictionaryRepresentation(
                    _cf.CFDictionaryGetValue(d, _kBounds), ctypes.byref(rect)):
                continue
            area = rect.size.width * rect.size.height
            if best is None or area > best[0]:
                best = (area, {"x": int(rect.origin.x), "y": int(rect.origin.y),
                               "w": int(rect.size.width), "h": int(rect.size.height)})
    finally:
        _cf.CFRelease(arr)
    if best is None:
        raise RuntimeError("no on-screen window found for app %r "
                           "(is it running and not minimized?)" % app)
    return best[1]


def activate(app):
    """Focus an app (Apple Event via osascript — the one thing not needing Accessibility)."""
    name = _resolve(app)[1]
    subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % name],
                   capture_output=True, text=True)


def clickin(app, fx, fy):
    b = bounds(app)
    x = b["x"] + fx * b["w"]
    y = b["y"] + fy * b["h"]
    click(x, y)
    return (x, y)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    if cmd == "check":
        ok = check()
        print("Accessibility: GRANTED" if ok else
              "Accessibility: NOT granted.\n"
              "  System Settings > Privacy & Security > Accessibility\n"
              "  -> enable 'Claude' (/Applications/Claude.app), then retry.")
        sys.exit(0 if ok else 1)

    try:
        if cmd == "bounds":
            print(json.dumps(bounds(argv[1])))
        elif cmd == "activate":
            activate(argv[1]); print("activated", argv[1])
        elif cmd == "cursor":
            print(cursor())
        elif cmd in ("move", "click", "rclick", "dclick"):
            _require()
            x, y = float(argv[1]), float(argv[2])
            {"move": move, "click": click, "rclick": rclick, "dclick": dclick}[cmd](x, y)
            print(cmd, int(x), int(y))
        elif cmd == "clickin":
            _require()
            x, y = clickin(argv[1], float(argv[2]), float(argv[3]))
            print("clicked %s at screen (%.0f, %.0f)" % (argv[1], x, y))
        elif cmd == "key":
            _require(); key(argv[1]); print("key", argv[1])
        elif cmd == "type":
            _require(); type_text(argv[1]); print("typed")
        else:
            sys.exit(__doc__)
    except (RuntimeError, ValueError) as e:
        sys.exit("ERROR: " + str(e))


if __name__ == "__main__":
    main(sys.argv[1:])

"""Windows platform backend for the Raves harness (PC branch, dd/pc).

Implements the plat.py contract with the SAME function names as plat_mac.py, so plat.py
dispatches by OS and mac/pc work stays in separate files (clean merges). Pure ctypes
against user32/kernel32 — no third-party deps, mirroring plat_mac.py's in-process style.

  input   : SendInput (mouse + keyboard). No Accessibility gate on Windows, so check()
            is always True. Single letters/digits/named keys post virtual-key codes so
            Qud's keybinds fire; arbitrary text goes through the UNICODE path.
  window  : EnumWindows + GetWindowRect for bounds, matched by the owning process's exe
            name. SetForegroundWindow for activate. Coordinates are physical screen pixels
            (the process is set DPI-aware so GetWindowRect and SendInput agree).
  process : tasklist / taskkill (graceful WM_CLOSE, then /F force).
  launch  : os.startfile on the steam:// URL.
  paths   : the mod's TileExporter.Dir builds <UserProfile>\\Library\\Application Support\\
            RavesOfQud\\tiles from Environment.SpecialFolder.UserProfile — the SAME on
            Windows — so support_dir() mirrors that exact path rather than editing the
            shared mod file (keeps mac/pc merges clean). See CLAUDE.md "Local paths".
"""
import csv
import ctypes
import ctypes.wintypes as wt
import io
import os
import subprocess
import sys
import time

PERM_HINT = ("Windows: synthetic input needs no special permission. If input has no "
             "effect, make sure the target window is focused and NOT running elevated "
             "(admin) — UIPI blocks non-elevated input to elevated windows.")
STEAM_APPID = "333640"     # Caves of Qud
QUD_PROC_MATCH = "CoQ"     # the Windows executable is CoQ.exe


# --- ctypes plumbing ------------------------------------------------------------
_user32 = ctypes.WinDLL("user32", use_last_error=True)
_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_ULONG_PTR = ctypes.c_ulonglong if ctypes.sizeof(ctypes.c_void_p) == 8 else ctypes.c_ulong

# Coordinates in physical pixels regardless of display scaling, so GetWindowRect and
# SendInput's absolute mapping agree. Best-effort newest-API-first.
for _try in (
    lambda: _user32.SetProcessDpiAwarenessContext(wt.HANDLE(-4)),   # PER_MONITOR_AWARE_V2
    lambda: ctypes.WinDLL("shcore").SetProcessDpiAwareness(2),      # PER_MONITOR_AWARE
    lambda: _user32.SetProcessDPIAware(),
):
    try:
        _try()
        break
    except Exception:
        continue


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", _ULONG_PTR)]


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", _ULONG_PTR)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", _MOUSEINPUT), ("ki", _KEYBDINPUT)]


class _INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


_INPUT_MOUSE, _INPUT_KEYBOARD = 0, 1
_MOVE, _LDOWN, _LUP = 0x0001, 0x0002, 0x0004
_RDOWN, _RUP = 0x0008, 0x0010
_ABSOLUTE, _VIRTUALDESK = 0x8000, 0x4000
_KEYUP, _UNICODE, _EXTENDED = 0x0002, 0x0004, 0x0001
_SM_XVIRT, _SM_YVIRT, _SM_CXVIRT, _SM_CYVIRT = 76, 77, 78, 79
_PROCESS_QUERY_LIMITED = 0x1000
_SW_RESTORE = 9

_WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

_user32.SendInput.argtypes = [wt.UINT, ctypes.POINTER(_INPUT), ctypes.c_int]
_user32.SendInput.restype = wt.UINT
_user32.GetSystemMetrics.argtypes = [ctypes.c_int]
_user32.GetSystemMetrics.restype = ctypes.c_int
_user32.GetCursorPos.argtypes = [ctypes.POINTER(wt.POINT)]
_user32.EnumWindows.argtypes = [_WNDENUMPROC, wt.LPARAM]
_user32.IsWindowVisible.argtypes = [wt.HWND]
_user32.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
_user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
_user32.SetForegroundWindow.argtypes = [wt.HWND]
_user32.BringWindowToTop.argtypes = [wt.HWND]
_user32.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
_kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
_kernel32.OpenProcess.restype = wt.HANDLE
_kernel32.QueryFullProcessImageNameW.argtypes = [
    wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
_kernel32.CloseHandle.argtypes = [wt.HANDLE]


def _send(inp):
    _user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(_INPUT))


# --- input permission (no gate on Windows) --------------------------------------
def check():
    return True


def require():
    pass


# --- mouse ----------------------------------------------------------------------
def _to_absolute(x, y):
    vx = _user32.GetSystemMetrics(_SM_XVIRT)
    vy = _user32.GetSystemMetrics(_SM_YVIRT)
    vw = _user32.GetSystemMetrics(_SM_CXVIRT)
    vh = _user32.GetSystemMetrics(_SM_CYVIRT)
    nx = int(round((x - vx) * 65535.0 / max(1, vw - 1)))
    ny = int(round((y - vy) * 65535.0 / max(1, vh - 1)))
    return nx, ny


def _mouse_event(nx, ny, flags):
    mi = _MOUSEINPUT(nx, ny, 0, _ABSOLUTE | _VIRTUALDESK | flags, 0, 0)
    _send(_INPUT(_INPUT_MOUSE, _INPUTUNION(mi=mi)))


def _post_mouse(x, y, presses):
    nx, ny = _to_absolute(x, y)
    _mouse_event(nx, ny, _MOVE)     # move first, so the app sees the cursor over the target
    time.sleep(0.04)
    for down, up in presses:
        _mouse_event(nx, ny, down)
        time.sleep(0.03)
        _mouse_event(nx, ny, up)
        time.sleep(0.04)


def move(x, y):
    nx, ny = _to_absolute(x, y)
    _mouse_event(nx, ny, _MOVE)


def click(x, y):
    _post_mouse(x, y, [(_LDOWN, _LUP)])


def rclick(x, y):
    _post_mouse(x, y, [(_RDOWN, _RUP)])


def dclick(x, y):
    _post_mouse(x, y, [(_LDOWN, _LUP), (_LDOWN, _LUP)])


def cursor():
    pt = wt.POINT()
    _user32.GetCursorPos(ctypes.byref(pt))
    return (pt.x, pt.y)


# --- keyboard -------------------------------------------------------------------
# Named virtual-key codes for the finicky keys; single chars derive their VK below.
_VK = {
    "Return": 0x0D, "Enter": 0x0D, "Tab": 0x09, "Space": 0x20, "Escape": 0x1B, "Esc": 0x1B,
    "Delete": 0x2E, "Backspace": 0x08, "Up": 0x26, "Down": 0x28, "Left": 0x25, "Right": 0x27,
    "F1": 0x70, "F2": 0x71, "F3": 0x72, "F4": 0x73, "F5": 0x74, "F6": 0x75, "F7": 0x76,
    "F8": 0x77, "F9": 0x78, "F10": 0x79, "F11": 0x7A, "F12": 0x7B,
    # numpad — Qud's default 8-way movement (VK_NUMPAD*, independent of NumLock)
    "KP0": 0x60, "KP1": 0x61, "KP2": 0x62, "KP3": 0x63, "KP4": 0x64, "KP5": 0x65,
    "KP6": 0x66, "KP7": 0x67, "KP8": 0x68, "KP9": 0x69,
}
# The arrow / edit-cluster keys are "extended" — set the flag so they aren't read as numpad.
_EXTENDED_KEYS = {"Up", "Down", "Left", "Right", "Delete"}


def _post_vk(vk, extended=False):
    base = _EXTENDED if extended else 0
    for up in (0, _KEYUP):
        ki = _KEYBDINPUT(vk, 0, base | up, 0, 0)
        _send(_INPUT(_INPUT_KEYBOARD, _INPUTUNION(ki=ki)))
        time.sleep(0.01)


def _post_unicode(ch):
    code = ord(ch)
    for up in (0, _KEYUP):
        ki = _KEYBDINPUT(0, code, _UNICODE | up, 0, 0)
        _send(_INPUT(_INPUT_KEYBOARD, _INPUTUNION(ki=ki)))
        time.sleep(0.006)


def key(name):
    if name in _VK:
        _post_vk(_VK[name], name in _EXTENDED_KEYS)
    elif len(name) == 1 and name.isascii() and name.isalnum():
        _post_vk(ord(name.upper()))   # VK code, so keycode-matched keybinds/shortcuts fire
    elif len(name) == 1:
        _post_unicode(name)           # symbols: unicode injection
    else:
        raise ValueError("unknown key %r (use a single char or one of %s)"
                         % (name, sorted(_VK)))


def type_text(text):
    for ch in text:
        _post_unicode(ch)
        time.sleep(0.01)


# --- window geometry / focus ----------------------------------------------------
# Friendly alias -> a substring of the owning process's exe name (matched case-insensitively).
_APPS = {"qud": "CoQ", "coq": "CoQ", "cavesofqud": "CoQ", "godot": "Godot"}


def _match(app):
    return _APPS.get(app.lower(), app)


def _pid_exe(pid):
    h = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED, False, pid)
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wt.DWORD(len(buf))
        if _kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value)
        return ""
    finally:
        _kernel32.CloseHandle(h)


def _windows_for(app):
    """[(hwnd, RECT)] of visible, on-screen top-level windows owned by a process whose
    exe name contains the app token."""
    token = _match(app).lower()
    found = []

    def _cb(hwnd, _lparam):
        if not _user32.IsWindowVisible(hwnd):
            return True
        pid = wt.DWORD()
        _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if token not in _pid_exe(pid.value).lower():
            return True
        r = wt.RECT()
        if _user32.GetWindowRect(hwnd, ctypes.byref(r)) and r.left > -30000:  # skip minimized
            found.append((hwnd, r))
        return True

    _user32.EnumWindows(_WNDENUMPROC(_cb), 0)
    return found


def _largest(app):
    best = None
    for hwnd, r in _windows_for(app):
        w, h = r.right - r.left, r.bottom - r.top
        if w <= 0 or h <= 0:
            continue
        area = w * h
        if best is None or area > best[0]:
            best = (area, hwnd, {"x": r.left, "y": r.top, "w": w, "h": h})
    return best


def bounds(app):
    """Largest on-screen window of `app`, as {x,y,w,h} screen pixels."""
    best = _largest(app)
    if best is None:
        raise RuntimeError("no on-screen window found for app %r "
                           "(is it running and not minimized?)" % app)
    return best[2]


def activate(app):
    """Bring an app's main window to the foreground (also refreshes its render).
    SW_RESTORE only when MINIMIZED: on a normal window it re-applies the stale
    'restore size', which shrank the borderless 1:1 viewer from 3232x1878 to its
    tiny pre-size default the first time the anim burst focused it.

    SetForegroundWindow is foreground-locked for background processes; verify
    and retry, and REPORT the outcome — callers whose captures depend on focus
    must know. Do NOT 'unlock' with a synthetic ALT tap: keybd_event goes to
    the app and INJECTS INPUT (it toggled a Qud ability mid-burst — observed
    'You toggle Butcher Corpses off.' in the log). AttachThreadInput is the
    clean unlock if plain retries ever prove insufficient."""
    best = _largest(app)
    if best is None:
        return False
    hwnd = best[1]
    if _user32.IsIconic(hwnd):
        _user32.ShowWindow(hwnd, _SW_RESTORE)
    for _ in range(3):
        _user32.BringWindowToTop(hwnd)
        _user32.SetForegroundWindow(hwnd)
        time.sleep(0.15)
        if _user32.GetForegroundWindow() == hwnd:
            return True
    return _user32.GetForegroundWindow() == hwnd


def clickin(app, fx, fy):
    b = bounds(app)
    x = b["x"] + fx * b["w"]
    y = b["y"] + fy * b["h"]
    click(x, y)
    return (x, y)


# --- data paths -----------------------------------------------------------------
def support_dir():
    """The RavesOfQud data dir the mod writes to (tiles, shot.png, qud_shot.png, godot_cmd,
    world). The shared mod (TileExporter.Dir) builds it from SpecialFolder.UserProfile +
    Library/Application Support/RavesOfQud, which resolves identically on Windows — mirror
    it here so we don't have to edit the shared mod file."""
    return os.path.join(os.path.expanduser("~"), "Library", "Application Support", "RavesOfQud")


def qud_data_dir():
    """QUD'S OWN data dir (saves under Synced/Saves, mods, options) — not ours.
    Unity persistentDataPath on Windows: AppData/LocalLow/<company>/<product>."""
    return os.path.join(os.path.expanduser("~"), "AppData", "LocalLow",
                        "Freehold Games", "CavesOfQud")


def qud_install_dir():
    """<install>/CoQ_Data — the Unity ASSET files (fonts, textures) live here.

    Deliberately NOT qud_data_dir(): that name belongs to Qud's persistentDataPath (saves,
    mods, options), and both sides of the mac/PC merge had independently claimed it for these
    two different directories. Used by tools/capture/fonts.py to carve Qud's UI faces out of
    the player's own install.
    """
    return os.path.join("C:" + os.sep, "Program Files (x86)", "Steam", "steamapps",
                        "common", "Caves of Qud", "CoQ_Data")


# --- process / launch -----------------------------------------------------------
def list_pids(match=QUD_PROC_MATCH):
    r = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True)
    pids = []
    for row in csv.reader(io.StringIO(r.stdout)):
        if len(row) >= 2 and match.lower() in row[0].lower():
            try:
                pids.append(int(row[1]))
            except ValueError:
                pass
    return pids


def kill_pids(pids, force=False):
    for pid in pids:
        args = ["taskkill", "/PID", str(pid)] + (["/F"] if force else [])
        subprocess.run(args, capture_output=True)


def quit_graceful(app="Qud"):
    """Post WM_CLOSE to the app's windows (taskkill without /F) so Qud can autosave."""
    subprocess.run(["taskkill", "/IM", _match(app) + ".exe"], capture_output=True)


def launch_game():
    """Launch Qud via Steam's URL protocol."""
    os.startfile("steam://rungameid/%s" % STEAM_APPID)


# --- self-test (python plat_win.py [bounds Qud|cursor|...]) ----------------------
if __name__ == "__main__":
    if not sys.platform.startswith("win"):
        sys.exit("plat_win.py is the Windows backend; this is %s" % sys.platform)
    import json
    argv = sys.argv[1:]
    if not argv:
        print("backend OK. support_dir:", support_dir())
        print("cursor:", cursor())
        print("qud pids:", list_pids())
        sys.exit(0)
    cmd = argv[0]
    if cmd == "bounds":
        print(json.dumps(bounds(argv[1])))
    elif cmd == "cursor":
        print(cursor())
    elif cmd == "pids":
        print(list_pids(argv[1] if len(argv) > 1 else QUD_PROC_MATCH))
    else:
        sys.exit("usage: plat_win.py [bounds <app> | cursor | pids [match]]")

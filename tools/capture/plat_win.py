"""Windows platform backend — STUB for the PC branch (dd/pc).

Implement the plat.py contract here with the SAME function names as plat_mac.py, so
plat.py dispatches cleanly and mac/pc stay in separate files (clean merges).

Suggested Windows implementations:
  input   : ctypes SendInput (mouse + keyboard); no Accessibility gate exists, so
            check() returns True. Keys: map names/letters to virtual-key codes (VK_*).
  window  : EnumWindows + GetWindowRect for bounds; SetForegroundWindow for activate.
            Match Qud's window by process/title. Coordinates are already screen pixels.
  process : `tasklist` / `taskkill` (or ctypes CreateToolhelp32Snapshot / OpenProcess).
  launch  : os.startfile("steam://rungameid/333640") or `start` via cmd.
  paths   : %APPDATA%\\RavesOfQud (confirm it matches the mod's output dir on Windows).
"""
import os

PERM_HINT = "Windows: no Accessibility gate — synthetic input should work once implemented."
STEAM_APPID = "333640"
QUD_PROC_MATCH = "CoQ"     # TODO confirm the Windows process/executable name


def _todo(name):
    raise NotImplementedError(
        "plat_win.%s not implemented (PC branch dd/pc). Mirror plat_mac.py." % name)


def support_dir():
    # Qud/.NET on Windows -> %APPDATA%\RavesOfQud. Confirm against the mod's dir.
    return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "RavesOfQud")


# input
def check():
    return True            # no Accessibility permission model on Windows


def require():
    pass


def move(x, y): _todo("move")
def click(x, y): _todo("click")
def rclick(x, y): _todo("rclick")
def dclick(x, y): _todo("dclick")
def cursor(): _todo("cursor")
def key(name): _todo("key")
def type_text(s): _todo("type_text")

# window
def bounds(app): _todo("bounds")
def activate(app): _todo("activate")
def clickin(app, fx, fy): _todo("clickin")

# process / launch
def list_pids(match=QUD_PROC_MATCH): _todo("list_pids")
def kill_pids(pids, force=False): _todo("kill_pids")
def quit_graceful(app="Qud"): _todo("quit_graceful")
def launch_game(): _todo("launch_game")

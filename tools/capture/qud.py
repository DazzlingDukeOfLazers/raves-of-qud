#!/usr/bin/env python3
"""Qud lifecycle — quit / start / load, so the recompile-and-resume loop is one command.

The mod only compiles at app startup, so iterating on it means: quit Qud, (redeploy),
start Qud, load the save, keep testing. This automates that. Also handy for humans.

  qud.py status                 # running? window up? bridge (in-game)?
  qud.py quit                   # graceful Apple-Event quit -> SIGTERM -> SIGKILL
  qud.py start                  # launch via Steam, wait for the window
  qud.py load                   # from the main menu, resume the latest save (presses C, then Return)
  qud.py restart                # quit + start + load — the full loop

`quit`/`start`/`status` need no permissions. `load` clicks the menu, so it needs
Accessibility (see desktop.py). Detection: the mod's bridge server (port 48710) only
listens once a game is loaded, so bridge-up == in-game.
"""
import os
import socket
import subprocess
import sys
import time

APPID = "333640"          # Caves of Qud, Steam
APP = "CoQ"               # osascript application name
PROC = "Caves of Qud"     # pgrep -f match (path contains this)
PORT = 48710              # bridge; open only when in-game

# Main-menu load: press "C" (the Continue shortcut, from Qud.UI.MainMenu — position
# independent), which opens the save picker with the most-recent save PRE-SELECTED
# (SelectFirst=true), then "Return" to load it. Keyboard, so no menu-layout calibration.


def _pids():
    r = subprocess.run(["pgrep", "-f", PROC], capture_output=True, text=True)
    return [int(p) for p in r.stdout.split()]


def running():
    return bool(_pids())


def window_up():
    try:
        import desktop
        desktop.bounds("Qud")
        return True
    except Exception:
        return False


def bridge_up(timeout=0.5):
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=timeout).close()
        return True
    except OSError:
        return False


def _wait(cond, timeout, step=1.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(step)
    return False


def status():
    return {"running": running(), "window": window_up(), "in_game(bridge)": bridge_up()}


def quit_qud(grace=15):
    if not running():
        return "not running"
    subprocess.run(["osascript", "-e", 'tell application "%s" to quit' % APP], capture_output=True)
    if _wait(lambda: not running(), grace):
        return "quit (graceful)"
    for pid in _pids():
        try: os.kill(pid, 15)   # SIGTERM
        except OSError: pass
    if _wait(lambda: not running(), 6):
        return "quit (SIGTERM)"
    for pid in _pids():
        try: os.kill(pid, 9)    # SIGKILL
        except OSError: pass
    _wait(lambda: not running(), 4)
    return "quit (SIGKILL)" if not running() else "FAILED to quit"


def start(wait_window=120):
    if running():
        return "already running"
    subprocess.run(["open", "steam://rungameid/%s" % APPID], capture_output=True)
    if _wait(window_up, wait_window):
        time.sleep(6)   # let the main menu finish rendering
        return "started (window up, at menu)"
    return "FAILED: no window within %ds" % wait_window


def load(wait_ingame=150):
    import desktop
    if not desktop.check():
        return "FAILED: load needs Accessibility (desktop.py check)"
    if bridge_up():
        return "already in-game"
    desktop.activate("Qud"); time.sleep(1.5)
    desktop.key("c")            # main menu -> Continue (opens save picker, most-recent pre-selected)
    time.sleep(1.8)
    desktop.key("Return")       # load the pre-selected (most-recent) save
    if _wait(bridge_up, wait_ingame):
        time.sleep(2)
        return "loaded (in-game)"
    return "FAILED: not in-game within %ds (menu may have changed)" % wait_ingame


def restart():
    print("quit:", quit_qud()); time.sleep(2)
    print("start:", start()); time.sleep(2)
    print("load:", load())


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    if cmd == "status":
        import json; print(json.dumps(status()))
    elif cmd == "quit":
        print(quit_qud())
    elif cmd == "start":
        print(start())
    elif cmd == "load":
        print(load())
    elif cmd == "restart":
        restart()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    main(sys.argv[1:])

"""Platform dispatcher for the Raves harness.

Imports the OS backend (plat_mac.py / plat_win.py) and re-exports its API, so callers
do `import plat; plat.click(...)` on any OS. Each backend implements the SAME names, so
macOS and Windows work lives in separate files — clean parallel branches (dd/mac, dd/pc),
no shared-file merge conflicts on platform code.

CONTRACT every backend must provide:
  paths:    support_dir(), qud_data_dir()
  input:    check(), require(), move/click/rclick/dclick(x,y), cursor(), key(name), type_text(s)
  window:   bounds(app)->{x,y,w,h}, activate(app), clickin(app,fx,fy)
  process:  list_pids([match]), kill_pids(pids, force=False), quit_graceful([app]), launch_game()
  consts:   STEAM_APPID, QUD_PROC_MATCH, PERM_HINT
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if sys.platform == "darwin":
    from plat_mac import *          # noqa: F401,F403
    import plat_mac as _backend
elif sys.platform.startswith("win"):
    from plat_win import *          # noqa: F401,F403
    import plat_win as _backend
else:
    raise RuntimeError("unsupported platform %r — add a plat_<os>.py backend" % sys.platform)

IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform.startswith("win")
BACKEND = _backend.__name__

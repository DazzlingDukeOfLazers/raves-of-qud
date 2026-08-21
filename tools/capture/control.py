#!/usr/bin/env python3
"""Drive Caves of Qud + the Raves viewer from the outside, so a dev loop can run
WITHOUT a human at the keyboard. Two channels:

  1. Qud    — send commands to the mod bridge (127.0.0.1:48710), same framed
              protocol as the Godot client: [4-byte BE len][JSON].
              {"type":"command","name":"move","dir":"N"}  (dirs N/S/E/W/NE/NW/SE/SW)
              The mod's BridgeServer broadcasts to EVERY client, so this coexists
              with the running Godot viewer.
  2. Godot  — Claude can't send keys to Godot, only to Qud. So Godot polls a small
              command file (<RavesOfQud>/godot_cmd); we write lines it executes:
              `shot` (save shot.png), `cam <1-7>` (camera mode), `fph <h>` (fp height),
              `pane <i> rot <deg>` / `pane <i> zoom <m>` (ONE multiview pane),
              `onboard [screen]` (open/jump the onboarding UI: devices/ktype/layout/numpad/mouse/close).

Examples:
    python3 tools/capture/control.py pos                 # print player cell + zone
    python3 tools/capture/control.py move N              # one step north
    python3 tools/capture/control.py move N 5            # five steps
    python3 tools/capture/control.py cam 1               # compass camera
    python3 tools/capture/control.py shot                # Godot screenshot -> shot.png
    python3 tools/capture/control.py qudshot             # QUD's own screen -> qud_shot.png (no Godot needed)
    python3 tools/capture/control.py go N 3 qudshot      # 3 steps N, then read Qud's map (the dev loop)
    python3 tools/capture/control.py zoo creatures 0     # build a debug zoo (pens+signs) in the current zone
    python3 tools/capture/control.py zoo weapons         # dense labeled weapon cache
    python3 tools/capture/control.py catalog             # dump become_catalog.json (what `become` accepts)
    python3 tools/capture/control.py become Dresser      # turn the player INTO a dresser (any blueprint works)

Requires Qud running with the bridge mod, and (for `shot`/`cam`) the Raves viewer open.
"""
import json
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat

PORT = 48710
DIRS = {"N", "S", "E", "W", "NE", "NW", "SE", "SW"}
BASE = plat.support_dir()   # per-OS data dir the mod writes to (see plat.py)
GODOT_CMD = os.path.join(BASE, "godot_cmd")
SHOT = os.path.join(BASE, "shot.png")          # Godot viewer's own screenshot
QUD_SHOT = os.path.join(BASE, "qud_shot.png")  # Qud's own rendered screen (ScreenCapture)


class Bridge:
    def __init__(self, timeout=5):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = b""

    def send(self, name, **extra):
        msg = {"type": "command", "name": name}
        msg.update(extra)
        payload = json.dumps(msg).encode("utf-8")
        self.sock.sendall(struct.pack(">I", len(payload)) + payload)

    def read_frame(self, kind="snapshot", timeout=30, match=None):
        """Block until the next framed message of `kind` arrives; return it (or None on timeout).

        The generic form of `read_snapshot`. It exists because the MOD's frames are the
        first-party report about QUD -- the only channel that can answer "did Qud raise
        this?" without going through Raves. Reading Raves' `raves_state.json` instead is
        the mistake the popup work kept paying for: a Raves at the title, or with a broken
        overlay, publishes "no popup" just as faithfully as a Qud that never raised one.
        """
        deadline = time.time() + timeout
        while True:
            while len(self.buf) >= 4:
                n = struct.unpack(">I", self.buf[:4])[0]
                if len(self.buf) < 4 + n:
                    break
                body, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
                d = json.loads(body.decode("utf-8"))
                if d.get("type") == kind and (match is None or match(d)):
                    return d
            left = deadline - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(max(0.05, min(left, 1.0)))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError("bridge closed")
            self.buf += chunk

    def read_snapshot(self, timeout=30):
        """Block until the next framed snapshot arrives; return the parsed dict."""
        d = self.read_frame("snapshot", timeout)
        if d is None:
            raise TimeoutError("no snapshot within %ss" % timeout)
        return d

    def move(self, d, n=1):
        d = d.upper()
        if d not in DIRS:
            raise ValueError("dir must be one of %s" % sorted(DIRS))
        for _ in range(n):
            self.send("move", dir=d)
            snap = self.read_snapshot()      # wait for the turn to resolve
        return snap

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def player_line(snap):
    p = snap.get("player", {})
    z = snap.get("zone", {})
    return "player (%s,%s)  zone %s  mod %s" % (
        p.get("x"), p.get("y"), z.get("id", "?"), snap.get("mod", "?"))


def godot(cmd):
    """Queue a command for the Godot viewer to execute (it polls + deletes)."""
    tmp = GODOT_CMD + ".tmp"
    with open(tmp, "w") as f:
        f.write(cmd + "\n")
    os.replace(tmp, GODOT_CMD)   # atomic; no truncate race with Godot's poll


def godot_shot(wait=15.0):
    """Ask Godot to screenshot, then block until shot.png actually updates.
    (15s: a freshly-launched viewer warming shaders, or one mid zone-rebuild
    after a zoom, can miss a 6s window — reboot_rig's calibrate did, three
    cycles in a row, while later shots on the same instance answered fine.)"""
    before = os.path.getmtime(SHOT) if os.path.exists(SHOT) else 0
    godot("shot")
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(SHOT) and os.path.getmtime(SHOT) > before:
            return True
        time.sleep(0.15)
    return False


def qud_shot(wait=8.0):
    """Ask QUD to screenshot ITSELF (qud_shot.png) straight over the bridge — no Godot
    needed. Blocks until the file updates. Works while Qud is UNFOCUSED: ScreenCapture
    forces a render of the current buffer, so the image reflects true current state even
    though the live window doesn't repaint in the background (a macOS compositor limit).
    This is the map read-back for automated dev/debug/test loops."""
    before = os.path.getmtime(QUD_SHOT) if os.path.exists(QUD_SHOT) else 0
    b = Bridge()
    b.send("shot")
    b.close()
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(QUD_SHOT) and os.path.getmtime(QUD_SHOT) > before:
            return True
        time.sleep(0.15)
    return False


def qud_shot_window(wait=20.0):
    """Capture Qud's WINDOW through the highvisor daemon instead of asking Qud
    to screenshot itself.

    WHY THIS EXISTS: the bridge path (`qud_shot`) queues onto Qud's uiQueue,
    which on Windows only drains while Qud is FOCUSED. The Raves dev-run window
    holds the foreground hard enough that `hv activate` reports success while
    Qud stays behind — the queued screenshot then never lands, and calibration
    blames the *Raves* viewer. The daemon captures the window directly with no
    focus dependency, and kept working throughout that failure.

    NOT INTERCHANGEABLE WITH `qud_shot`: this is the WINDOW (chrome included,
    2327x1284 here), the bridge path is the CLIENT AREA (2301x1213). The origin
    differs by the border+titlebar, so switching REQUIRES a recalibration — the
    stage-cell geometry is in whichever space produced it."""
    import subprocess
    before = os.path.getmtime(QUD_SHOT) if os.path.exists(QUD_SHOT) else 0
    try:
        subprocess.run([sys.executable, "-m", "highvisor.cli", "shot",
                        "CavesOfQud", QUD_SHOT],
                       capture_output=True, text=True, timeout=wait)
    except Exception:
        return False
    return os.path.exists(QUD_SHOT) and os.path.getmtime(QUD_SHOT) > before


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]

    if cmd == "pos":
        b = Bridge()
        print(player_line(b.read_snapshot()))
        b.close()
    elif cmd == "move":
        d = argv[1]
        n = int(argv[2]) if len(argv) > 2 else 1
        b = Bridge()
        print(player_line(b.move(d, n)))
        b.close()
    elif cmd == "cam":
        godot("cam " + argv[1])
        print("godot: cam", argv[1])
    elif cmd == "fph":
        godot("fph " + argv[1])
        print("godot: fp height", argv[1])
    elif cmd == "screenpos":
        # where does a cell land on screen? printed to raves.log by the viewer
        godot("screenpos " + argv[1] + " " + argv[2])
        print("godot: screenpos", argv[1], argv[2])
    elif cmd == "mv":
        godot("mv")
        print("godot: multiview toggled")
    elif cmd == "pane":
        # `pane <i> rot <deg>` / `pane <i> zoom <mult>` — ONE multiview pane's own camera.
        # On the command channel so per-pane behaviour can be tested with no mouse: turning
        # one pane and diffing the grid is the only way to SHOW that the other six held still.
        godot("pane " + " ".join(argv[1:]))
        print("godot: pane", " ".join(argv[1:]))
    elif cmd == "onboard":
        # `onboard` opens the chooser; `onboard <screen>` jumps to a screen
        # (devices/ktype/layout/numpad/mouse); `onboard close` dismisses it.
        arg = (" " + argv[1]) if len(argv) > 1 else ""
        godot("onboard" + arg)
        print("godot: onboard" + arg)
    elif cmd == "shot":
        print("shot.png updated" if godot_shot() else "shot: TIMED OUT (is the viewer open?)")
    elif cmd == "wish":
        # Execute a Qud wish (godmode, item:<blueprint>, reveal, ...). The wish is drained
        # on the game thread between turns, so follow it with a wait to flush it even while
        # Qud is unfocused; the post-wait snapshot then reflects the wish.
        if len(argv) < 2:
            sys.exit("usage: control.py wish <text>   e.g. wish godmode · wish item:Torch")
        text = " ".join(argv[1:])
        b = Bridge()
        b.send("wish", wish=text)
        b.send("wait")
        print(player_line(b.read_snapshot()))
        b.close()
        print("wish sent:", text)
    elif cmd == "export":
        # Re-run Qud's DATA exporters (mods, options, …) NOW over the bridge — the clean
        # trigger for refreshing RavesOfQud/*.json without ticking a fake turn. Qud must be
        # in-game (bridge up); the mod's "export" command calls each exporter's ReExport().
        b = Bridge()
        b.send("export")
        b.close()
        print("export: requested (Qud re-exports its data files)")
    elif cmd == "zoo":
        # Build a debug showcase zone in-game. Sent to QUD over the bridge (not the
        # godot_cmd file): `zoo [category] [page]`. category = creatures (default) /
        # weapons / food / items / implants. Creatures paginate ~100 pens/zone.
        cat = argv[1] if len(argv) > 1 else "creatures"
        page = argv[2] if len(argv) > 2 else "0"
        b = Bridge()
        b.send("zoo", cat=cat, page=page)
        b.close()
        print("zoo: built %s page %s (move/wait once to refresh the snapshot)" % (cat, page))
    elif cmd == "become":
        # Turn the player INTO an arbitrary blueprint (creature/item/furniture).
        # `become <Blueprint>`  e.g. `become Dresser` — yes, you can be an immobile
        # dresser. Sent to QUD over the bridge (main-thread swap in the mod).
        if len(argv) < 2:
            sys.exit("usage: become <Blueprint>   (try `catalog` first for the list)")
        bp = " ".join(argv[1:])   # blueprint names can contain spaces (e.g. "Iron Gate")
        b = Bridge()
        b.send("become", bp=bp)
        b.close()
        print("become: swapped to '%s' (move/wait once to refresh the snapshot)" % bp)
    elif cmd == "catalog":
        # Dump the pickable-blueprint catalog to <support>/become_catalog.json so the
        # character-creator menu (and you) can see what `become` accepts.
        b = Bridge()
        b.send("catalog")
        b.close()
        print("catalog: wrote %s" % os.path.join(BASE, "become_catalog.json"))
    elif cmd == "qudshot":
        print("qud_shot.png updated" if qud_shot() else "qudshot: TIMED OUT (is Qud running?)")
    elif cmd == "go":
        # a mini script: `go N 3 shot`  -> move N 3, then screenshot
        b = Bridge()
        i = 1
        while i < len(argv):
            tok = argv[i]
            if tok.upper() in DIRS:
                n = int(argv[i + 1]) if i + 1 < len(argv) and argv[i + 1].isdigit() else 1
                print(player_line(b.move(tok, n)))
                i += 2 if n != 1 or (i + 1 < len(argv) and argv[i + 1].isdigit()) else 1
            elif tok == "shot":
                b.close()
                print("shot.png updated" if godot_shot() else "shot: TIMED OUT")
                b = Bridge()
                i += 1
            elif tok == "qudshot":
                b.close()
                print("qud_shot.png updated" if qud_shot() else "qudshot: TIMED OUT")
                b = Bridge()
                i += 1
            else:
                i += 1
        b.close()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

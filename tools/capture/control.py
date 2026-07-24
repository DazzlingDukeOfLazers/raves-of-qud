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
              `shot` (save shot.png), `cam <1-6>` (camera mode), `fph <h>` (fp height).

Examples:
    python3 tools/capture/control.py pos                 # print player cell + zone
    python3 tools/capture/control.py move N              # one step north
    python3 tools/capture/control.py move N 5            # five steps
    python3 tools/capture/control.py cam 1               # compass camera
    python3 tools/capture/control.py shot                # Godot screenshot -> shot.png
    python3 tools/capture/control.py go N 3 shot         # 3 steps N, then screenshot

Requires Qud running with the bridge mod, and (for `shot`/`cam`) the Raves viewer open.
"""
import json
import os
import socket
import struct
import sys
import time

PORT = 48710
DIRS = {"N", "S", "E", "W", "NE", "NW", "SE", "SW"}
BASE = os.path.expanduser("~/Library/Application Support/RavesOfQud")
GODOT_CMD = os.path.join(BASE, "godot_cmd")
SHOT = os.path.join(BASE, "shot.png")


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

    def read_snapshot(self, timeout=30):
        """Block until the next framed snapshot arrives; return the parsed dict."""
        self.sock.settimeout(timeout)
        while True:
            while len(self.buf) >= 4:
                n = struct.unpack(">I", self.buf[:4])[0]
                if len(self.buf) < 4 + n:
                    break
                body, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
                d = json.loads(body.decode("utf-8"))
                if d.get("type") == "snapshot":
                    return d
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("bridge closed")
            self.buf += chunk

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


def godot_shot(wait=6.0):
    """Ask Godot to screenshot, then block until shot.png actually updates."""
    before = os.path.getmtime(SHOT) if os.path.exists(SHOT) else 0
    godot("shot")
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(SHOT) and os.path.getmtime(SHOT) > before:
            return True
        time.sleep(0.15)
    return False


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
    elif cmd == "shot":
        print("shot.png updated" if godot_shot() else "shot: TIMED OUT (is the viewer open?)")
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
            else:
                i += 1
        b.close()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

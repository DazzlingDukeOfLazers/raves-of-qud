#!/usr/bin/env python3
"""Drive the parity FIXTURE state safely: reload a save, then resolve objects by NAME.

WHY THIS EXISTS
---------------
Object ids are not stable across a save reload. Reading an id out of
`inventory.json`, reloading the fixture, and then acting on that id resolves to
whatever object now holds it -- which is how a run that asked for the cloth robe's
interaction menu got the WRENCH's, and how several capture runs ended up scoring
two screens that had no popup on them at all.

The rule this enforces: never carry an id across a reload, and never read one out
of an export you have not just refreshed. Every command here re-exports first and
BLOCKS until the file on disk is actually newer, so a stale read is not expressible.

The second trap it closes: an item moves between the PACK and the BODY as tests
equip and drop things, and a lookup that only walks `categories` starts throwing
IndexError halfway through a session. `find` walks both.

Commands
  reload [<save>]        reload the fixture save, then wait for a fresh export
  find <substr>          resolve one object by name -> id, kind, where it lives
  twiddle <substr>       raise Qud's item interaction popup for it, and verify
  state                  what both apps think they are showing

Examples
  fixture.py reload
  fixture.py find robe
  fixture.py twiddle robe
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plat                                   # noqa: E402  (per-OS support dir)
from control import Bridge                    # noqa: E402  (framed bridge client)

SUPPORT = plat.support_dir()
INVENTORY = os.path.join(SUPPORT, "inventory.json")
RAVES_STATE = os.path.join(SUPPORT, "raves_state.json")
DEFAULT_SAVE = "sync-raves-and-qud"

# Qud markup: {{colour|text}}, and bare control bytes used for the badge glyphs
_MARKUP = re.compile(r"\{\{[^|{}]*\|")


def strip(s):
    """Qud's display name without markup, for human matching."""
    out = _MARKUP.sub("", s or "").replace("}}", "").replace("{{", "")
    # the AV/DV badges are raw CP437 control bytes in the display name; drop them
    # so a human-readable match string comes out
    return "".join(c for c in out if c >= " ").strip()


def hv(*args, timeout=180):
    return subprocess.run(["hv", *args], capture_output=True, text=True,
                          timeout=timeout).stdout


def fresh_inventory(timeout=25.0):
    """Force an export and BLOCK until inventory.json is genuinely newer.

    The whole point of this module: every id handed out has to come from a file
    written after the last thing that could have invalidated it.
    """
    before = os.path.getmtime(INVENTORY) if os.path.exists(INVENTORY) else 0.0
    Bridge().send("export")
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.4)
        if os.path.exists(INVENTORY) and os.path.getmtime(INVENTORY) > before:
            # the mod writes the file whole, but give the write a beat to land
            time.sleep(0.2)
            return json.load(open(INVENTORY))
    raise SystemExit("STOP: the export never refreshed -- is Qud running and in a game?")


def resolve(inv, substr):
    """Find one object by name substring, in the PACK or on the BODY.

    Returns (id, display, where). Ambiguity is an error rather than a guess: two
    waterskins are a real case, and silently picking the first is how a test ends
    up acting on something the author did not mean.
    """
    want = substr.lower()
    hits = []
    for cat in inv.get("categories", []):
        for it in cat.get("items", []):
            if want in strip(it.get("name", "")).lower() and it.get("id"):
                hits.append((it["id"], strip(it["name"]), "pack/" + cat.get("name", "?")))
    for sl in inv.get("slots", []):
        if sl.get("item") and sl.get("id") and want in strip(sl["item"]).lower():
            hits.append((sl["id"], strip(sl["item"]), "body/" + sl.get("name", "?")))
    if not hits:
        raise SystemExit(f"STOP: nothing matching {substr!r} in the pack or on the body")
    if len(hits) > 1:
        lines = "\n".join(f"    {h[0]:>6}  {h[1]}  ({h[2]})" for h in hits)
        raise SystemExit(f"STOP: {substr!r} is ambiguous:\n{lines}")
    return hits[0]


def raves_popup():
    try:
        return json.load(open(RAVES_STATE)).get("popup", "")
    except Exception:
        return ""


def cmd_reload(save=DEFAULT_SAVE):
    print(f"reloading {save}")
    if '"ok": true' not in hv("loadsave", save):
        raise SystemExit("STOP: loadsave did not report ok")
    # The save is in, but the ids it just minted are only knowable from a NEW export.
    time.sleep(12)
    inv = fresh_inventory()
    n = sum(len(c.get("items", [])) for c in inv.get("categories", []))
    print(f"reloaded; export refreshed with {n} pack items")


def cmd_find(substr):
    oid, name, where = resolve(fresh_inventory(), substr)
    print(f"{oid}\t{name}\t{where}")


def cmd_twiddle(substr):
    oid, name, where = resolve(fresh_inventory(), substr)
    print(f"twiddling {name} (id {oid}, {where})")
    Bridge().send("invaction", id=oid)
    for _ in range(12):
        time.sleep(0.5)
        if raves_popup():
            print(f"popup up: {raves_popup()}")
            return
    raise SystemExit("STOP: no popup appeared -- check that Qud still has a screen open")


def cmd_state():
    print(hv("state").rstrip())


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, rest = argv[1], argv[2:]
    if cmd == "reload":
        cmd_reload(*rest)
    elif cmd == "find":
        cmd_find(*rest)
    elif cmd == "twiddle":
        cmd_twiddle(*rest)
    elif cmd == "state":
        cmd_state()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

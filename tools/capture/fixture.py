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
  quests                 reload + grant the standard quest fixture (2 real quests)
  journal                reload + add map notes across 3 categories (Journal grouping)
  tinker                 reload + learn build/mod recipes and stock bits (Tinkering)
  find <substr>          resolve one object by name -> id, kind, where it lives
  twiddle <substr>       raise Qud's item interaction popup for it, and verify
  state                  what both apps think they are showing

Examples
  fixture.py reload
  fixture.py quests
  fixture.py journal
  fixture.py tinker
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



# The standard quest fixture: two REAL quests from Quests.xml, with their real givers.
# One is fresh (four incomplete steps), the other already has a completed step -- so the
# renderer gets both step states without anyone having to play to them.
QUEST_FIXTURE = [
    ("What's Eating the Watervine?", "Mehmet"),
    ("Fetch Argyve a Knickknack", "Argyve"),
]


def cmd_quests(save=DEFAULT_SAVE):
    """Reload the golden save and grant the quest fixture.

    WHY THIS IS A SCRIPT AND NOT A SAVE FILE: Qud's SaveGame(name) names a FILE inside the
    current game's folder -- same ID, same Name -- so the picker never shows it as a separate
    entry and `hv loadsave` can't reach it. Qud has no "save as a new game" API. Granting the
    quests on top of the golden save each time is reproducible, adds no state to the user's
    save directory, and can't drift from the golden save the way a copy would.
    """
    cmd_reload(save)
    for quest, giver in QUEST_FIXTURE:
        print(f"granting {quest!r} (giver {giver})")
        Bridge().send("startquest", quest=quest, giver=giver)
        time.sleep(2.5)
    # DISMISS THE POPUPS. Starting a quest raises "You have received a new quest" (and a step
    # completion) as blocking modals, and Qud swallows EVERY subsequent input while one is up --
    # so the next `hv goto` silently no-ops and reads exactly like a broken recipe. It cost a
    # detour here: the status-screen opener looked broken when it was merely blocked.
    for _ in range(6):
        Bridge().send("popup", **{"do": "button", "command": "Accept"})
        time.sleep(0.8)
    Bridge().send("export")
    time.sleep(4)
    path = os.path.join(SUPPORT, "quests.json")
    n = json.load(open(path)).get("count", 0) if os.path.exists(path) else 0
    if n != len(QUEST_FIXTURE):
        raise SystemExit(f"STOP: expected {len(QUEST_FIXTURE)} quests, export says {n}")
    print(f"quest fixture ready: {n} active quests")


def cmd_journal(save=DEFAULT_SAVE):
    """Reload and seed the Journal's Locations tab with map notes across several categories.

    Every golden save has an empty Journal apart from Chronology, and Chronology is the one tab
    that does NOT group -- so the category rendering had nothing to exercise it. These go in
    through Qud's own JournalAPI.AddMapNote, so they are real entries with a real Category.
    """
    cmd_reload(save)
    Bridge().send("journalfixture")
    time.sleep(3)
    Bridge().send("export")
    time.sleep(4)
    path = os.path.join(SUPPORT, "journal.json")
    tabs = json.load(open(path)).get("tabs", []) if os.path.exists(path) else []
    loc = next((t for t in tabs if t.get("id") == "Locations"), {})
    n = loc.get("count", 0)
    if not n:
        raise SystemExit("STOP: Locations still empty -- the fixture did not take")
    cats = sorted({e.get("category", "?") for e in loc.get("entries", [])})
    print(f"journal fixture ready: {n} location notes in {len(cats)} categories ({', '.join(cats)})")



def cmd_tinker(save=DEFAULT_SAVE):
    """Reload and give the character schematics + bits, so both Tinkering views have content.

    Every golden save knows zero recipes and holds zero bits, which left the build list on its
    empty state and the modifications view with nothing at all. The recipes come from Qud's own
    master list, so their costs are real.
    """
    cmd_reload(save)
    Bridge().send("tinkerfixture")
    time.sleep(3)
    Bridge().send("export")
    time.sleep(4)
    path = os.path.join(SUPPORT, "tinkering.json")
    d = json.load(open(path)) if os.path.exists(path) else {}
    builds = d.get("recipeCount", 0)
    mods = len(d.get("mods", []))
    bits = sum(b.get("count", 0) for b in d.get("bits", []))
    if not builds and not mods:
        raise SystemExit("STOP: no recipes learned -- the fixture did not take")
    print(f"tinker fixture ready: {builds} build recipes, {mods} mods, {bits} bits")


def cmd_find(substr):
    oid, name, where = resolve(fresh_inventory(), substr)
    print(f"{oid}\t{name}\t{where}")


def cmd_twiddle(substr):
    """Raise Qud's item menu and verify it FROM QUD'S SIDE.

    This used to poll `raves_state.json`, i.e. it asked RAVES whether QUD had raised a
    popup. That is the failure mode this repo has now paid for twice (see the highvisor
    CLAUDE.md note and `docs/gotchas.md`): a Raves sitting at the title, or one whose
    overlay builder threw, publishes "no popup" exactly as convincingly as a Qud that
    never raised one -- and the tool then blames Qud. The mod's own `popup` frame on the
    bridge is Qud's report about Qud, so that is what decides PASS/FAIL; Raves' mirror is
    reported afterwards as extra information, not as the verdict.
    """
    oid, name, where = resolve(fresh_inventory(), substr)
    print(f"twiddling {name} (id {oid}, {where})")
    b = Bridge(timeout=2)
    b.send("invaction", id=oid)
    frame = b.read_frame("popup", timeout=8, match=lambda d: d.get("active"))
    b.close()
    if frame is None:
        raise SystemExit("STOP: Qud announced no popup -- the bridge saw no active `popup` frame "
                         "within 8s (is a game live? did the menu answer itself?)")
    opts = frame.get("options") or []
    print(f"qud popup up: id {frame.get('id')}, kind {frame.get('kind')}, {len(opts)} options")
    mirror = raves_popup()
    print(f"raves mirror: {mirror or '(not mirroring -- check Raves, not Qud)'}")


def cmd_state():
    print(hv("state").rstrip())


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, rest = argv[1], argv[2:]
    if cmd == "reload":
        cmd_reload(*rest)
    elif cmd == "quests":
        cmd_quests(*rest)
    elif cmd == "journal":
        cmd_journal(*rest)
    elif cmd == "tinker":
        cmd_tinker(*rest)
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

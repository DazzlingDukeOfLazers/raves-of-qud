#!/usr/bin/env python3
"""The Object Checker sweep driver (phase2-test-plan Workstream A).

Loads Qud elements ONE AT A TIME onto a clean stage (the mod's "check" command:
clear a rect at zone center, place the blueprint, park the player adjacent) and
verifies each — the deterministic rung below the zoo's chaos. Two data sources
per element, diffed against each other:

  * checker_stage.json — GROUND TRUTH: what the mod believes it staged
    (blueprint, stage cell, static Render tile/colours).
  * the wire snapshot   — what Qud actually published for that cell.

Wire-level checks (this file, no screenshots needed): the stage cell arrived,
the element carries art (tile or glyph), colours look like Qud colour codes,
and the wire tile agrees with the blueprint's static tile (loose — runtime
tiles may legitimately differ, so a mismatch is a WARN, not a FAIL).
Pixel-level congruence (same-turn Qud/Raves screenshot pair) hangs off
--shots: both captures are saved per element for the contact sheet /
mean-diff pass to consume.

USAGE (Qud running + bridge mod, in-game)
  checker.py list                     # category -> element counts (refreshes the catalog)
  checker.py one Dresser              # stage + verify one element
  checker.py one "Iron Gate" --shots  # ... and capture the Qud/Raves screenshot pair
  checker.py sweep walls              # verify a whole category -> reports/checker/
  checker.py sweep creatures --start 100 --limit 50   # resumable slices

Output: reports/checker/<cat>.md (human) + <cat>.json (machine, re-runnable
diff base). Pure stdlib, per the repo rule.
"""
import json
import os
import re
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control
import plat

BASE = plat.support_dir()
CATALOG = os.path.join(BASE, "checker_catalog.json")
STAGE = os.path.join(BASE, "checker_stage.json")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPORTS = os.path.join(REPO, "reports", "checker")

# Qud colour codes: &X (foreground), ^X (background), X in the 16-colour set.
COLOR_RE = re.compile(r"^(?:[&^][a-zA-Z])+$")


def _wait_file(path, before, wait=6.0):
    """Block until `path`'s mtime passes `before` (mirrors control.godot_shot)."""
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(path) and os.path.getmtime(path) > before:
            return True
        time.sleep(0.1)
    return False


def _tail(tile):
    """The meaningful tile-name tail (never match the raw path — snap.py's rule)."""
    t = (tile or "").replace("\\", "/").rsplit("/", 1)[-1]
    return t.rsplit(".", 1)[0].lower()


def refresh_catalog(b=None):
    """Ask the mod to (re)dump checker_catalog.json; return the parsed dict."""
    before = os.path.getmtime(CATALOG) if os.path.exists(CATALOG) else 0
    own = b is None
    if own:
        b = control.Bridge()
    b.send("checklist")
    if own:
        b.close()
    if not _wait_file(CATALOG, before):
        sys.exit("checker_catalog.json never appeared — is Qud in-game with the current mod build?")
    with open(CATALOG) as f:
        return json.load(f)


def check_one(b, bp):
    """Stage `bp`, wait a turn, diff ground truth vs the wire. Returns a verdict dict."""
    before = os.path.getmtime(STAGE) if os.path.exists(STAGE) else 0
    b.send("check", bp=bp)
    b.send("wait")                      # tick a turn: drains the command, publishes the snapshot
    snap = b.read_snapshot()
    if not _wait_file(STAGE, before, wait=3.0):
        return {"bp": bp, "pass": False, "reasons": ["checker_stage.json never updated (old mod build?)"]}
    with open(STAGE) as f:
        stage = json.load(f)

    reasons, warns = [], []
    if stage.get("bp") != bp:
        reasons.append("stage ground truth is for %r, not %r" % (stage.get("bp"), bp))
    if not stage.get("ok"):
        reasons.append("mod could not stage it: " + (stage.get("error") or "?"))

    cell = None
    for c in snap.get("cells", []):
        if c.get("x") == stage.get("x") and c.get("y") == stage.get("y"):
            cell = c
            break
    objs = (cell or {}).get("objs", [])

    if stage.get("ok"):
        if cell is None or not objs:
            # Qud only sends non-empty cells — a staged element that never reaches
            # the wire is exactly the class of bug the checker exists to catch.
            reasons.append("stage cell (%s,%s) missing from the wire" % (stage.get("x"), stage.get("y")))
        else:
            if not any(o.get("tile") or o.get("glyph") for o in objs):
                reasons.append("no art on the wire (no tile, no glyph)")
            for o in objs:
                for k in ("color", "tilecolor", "detail"):
                    v = o.get(k)
                    if v and not COLOR_RE.match(v):
                        warns.append("odd %s %r" % (k, v))
            st = _tail(stage.get("tile"))
            if st and not any(st == _tail(o.get("tile")) for o in objs):
                # Runtime art can differ from the static blueprint tile
                # (RandomTile and friends) — flag it, don't fail it.
                warns.append("wire tile != blueprint tile %r" % st)

    return {"bp": bp, "pass": not reasons, "reasons": reasons, "warns": warns,
            "stage": stage, "wire_objs": len(objs)}


def _safe(bp):
    return re.sub(r"[^A-Za-z0-9_-]+", "_", bp)


def shots_for(bp, cat="single"):
    """Capture the same-turn Qud/Raves pair for the congruence pass."""
    outdir = os.path.join(REPORTS, "shots", cat)
    os.makedirs(outdir, exist_ok=True)
    pair = {}
    if control.qud_shot():
        pair["qud"] = os.path.join(outdir, _safe(bp) + "_qud.png")
        shutil.copyfile(control.QUD_SHOT, pair["qud"])
    if control.godot_shot():
        pair["raves"] = os.path.join(outdir, _safe(bp) + "_raves.png")
        shutil.copyfile(control.SHOT, pair["raves"])
    return pair


def write_report(cat, results):
    os.makedirs(REPORTS, exist_ok=True)
    with open(os.path.join(REPORTS, cat + ".json"), "w") as f:
        json.dump(results, f, indent=1)

    passed = sum(1 for r in results if r["pass"])
    lines = ["# Object Checker — %s" % cat, "",
             "%d/%d PASS  (%s)" % (passed, len(results), time.strftime("%Y-%m-%d %H:%M")), "",
             "| element | verdict | notes |", "|---|---|---|"]
    for r in results:
        notes = "; ".join(r.get("reasons", []) + r.get("warns", []))
        lines.append("| %s | %s | %s |" % (r["bp"], "PASS" if r["pass"] else "**FAIL**", notes))
    path = os.path.join(REPORTS, cat + ".md")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]

    if cmd == "list":
        cat = refresh_catalog()
        for k in cat:
            print("%-10s %d" % (k, len(cat[k])))
    elif cmd == "one":
        args = [a for a in argv[1:] if a != "--shots"]
        if not args:
            sys.exit("usage: checker.py one <Blueprint> [--shots]")
        bp = " ".join(args)
        b = control.Bridge()
        r = check_one(b, bp)
        b.close()
        if "--shots" in argv:
            r["shots"] = shots_for(bp)
        print(json.dumps(r, indent=1))
        sys.exit(0 if r["pass"] else 1)
    elif cmd == "sweep":
        if len(argv) < 2:
            sys.exit("usage: checker.py sweep <category> [--start N] [--limit N] [--shots]")
        cat = argv[1]
        start = int(argv[argv.index("--start") + 1]) if "--start" in argv else 0
        limit = int(argv[argv.index("--limit") + 1]) if "--limit" in argv else None
        b = control.Bridge()
        names = refresh_catalog(b).get(cat)
        if names is None:
            sys.exit("unknown category %r (try: checker.py list)" % cat)
        names = names[start:start + limit if limit else None]
        results = []
        for i, bp in enumerate(names):
            r = check_one(b, bp)
            if "--shots" in argv:
                r["shots"] = shots_for(bp, cat)
            results.append(r)
            print("[%d/%d] %-40s %s" % (start + i + 1, start + len(names), bp,
                                        "PASS" if r["pass"] else "FAIL " + "; ".join(r["reasons"])))
        b.close()
        print("report:", write_report(cat, results))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

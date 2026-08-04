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
  checker.py calibrate                # locate the stage cell in BOTH apps' captures
                                      # (needs the 1:1 viewer attached; writes
                                      # fixtures/checker_geometry.json — rerun after
                                      # any window-size/layout change)
  checker.py one Dresser --diff       # + crop the stage cell and pixel-score the pair
  checker.py sweep walls --diff       # pixel-scored category sweep (slow: ~2 frames/element)
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
import congruence
import control
import plat

BASE = plat.support_dir()
CATALOG = os.path.join(BASE, "checker_catalog.json")
STAGE = os.path.join(BASE, "checker_stage.json")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPORTS = os.path.join(REPO, "reports", "checker")

# Qud colour codes: &X (foreground), ^X (background), X in the 16-colour set.
# DetailColor is a BARE palette char (e.g. "w"), no & prefix — different shape.
COLOR_RE = re.compile(r"^(?:[&^][a-zA-Z])+$")
DETAIL_RE = re.compile(r"^[a-zA-Z]$")


def _wait_file(path, before, wait=6.0):
    """Block until `path`'s mtime passes `before` (mirrors control.godot_shot)."""
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(path) and os.path.getmtime(path) > before:
            return True
        time.sleep(0.1)
    return False


def _tail(tile):
    """Normalized tile name for tail-matching. Static Render.Tile and the wire
    spell the same asset differently (underscore-flattened vs slashed paths), so
    flatten separators and compare with endswith — never the raw path (snap.py's
    rule: 'tent' must not hit 'Content')."""
    t = (tile or "").lower().replace("\\", "_").replace("/", "_")
    return t.rsplit(".", 1)[0]


def _tile_match(a, b):
    a, b = _tail(a), _tail(b)
    return bool(a) and bool(b) and (a.endswith(b) or b.endswith(a))


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


def _snapshot_unstick(b):
    """A snapshot that never comes usually means a BLOCKING POPUP parked the turn
    loop (ambient events fire mid-sweep: 'You spot a dromad caravan'). Dismiss
    over the bridge — popups can stack, so cancel several — and re-tick."""
    for _ in range(6):
        b.send("popup", action="cancel")
        time.sleep(0.5)
    b.send("wait")
    return b.read_snapshot(timeout=15)


def check_one(b, bp, _retry=True):
    """Stage `bp`, wait a turn, diff ground truth vs the wire. Returns a verdict dict.

    One retry on the never-updated signature: elements that alter TURN FLOW
    (sleep gas auto-passes the player's turns) can race the ground-truth wait —
    a ~0.2%% flake that moves between elements run-to-run. A retried pass keeps
    the retry visible as a warn; a repeat failure is real and stays a FAIL."""
    before = os.path.getmtime(STAGE) if os.path.exists(STAGE) else 0
    b.send("check", bp=bp)
    b.send("wait")                      # tick a turn: drains the command, publishes the snapshot
    try:
        snap = b.read_snapshot(timeout=15)
    except (OSError, ConnectionError):
        snap = _snapshot_unstick(b)
    if not _wait_file(STAGE, before, wait=3.0):
        if _retry:
            # Settle before retrying: an instant retry inherits the same
            # disturbed turn window (verified — a double-fail probed clean).
            time.sleep(2.0)
            b.send("wait")
            try:
                b.read_snapshot(timeout=10)
            except (OSError, ConnectionError):
                pass
            r = check_one(b, bp, _retry=False)
            r.setdefault("warns", []).append("passed on retry (turn-flow race)" if r.get("pass")
                                             else "retried once")
            return r
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
                for k, rx in (("color", COLOR_RE), ("tilecolor", COLOR_RE), ("detail", DETAIL_RE)):
                    v = o.get(k)
                    if v and not rx.match(v):
                        warns.append("odd %s %r" % (k, v))
            st = stage.get("tile")
            if _tail(st) and not any(_tile_match(st, o.get("tile")) for o in objs):
                # Runtime art can differ from the static blueprint tile
                # (RandomTile and friends) — flag it, don't fail it.
                warns.append("wire tile != blueprint tile %r" % _tail(st))

    # The wire's RGB for the blueprint's foreground colour, via the snapshot's
    # REAL palette (the mod exports ConsoleLib's table) — the strict
    # dominant-colour-vs-wire check compares the rendered crop against this.
    wire_hex = None
    pal = snap.get("palette") or {}
    color = (stage.get("color") or "").lstrip("&")
    if color:
        wire_hex = (pal.get(color[:1]) or "").lstrip("#") or None

    return {"bp": bp, "pass": not reasons, "reasons": reasons, "warns": warns,
            "stage": stage, "wire_objs": len(objs), "wire_hex": wire_hex}


def _safe(bp):
    return re.sub(r"[^A-Za-z0-9_-]+", "_", bp)


_last_md5 = {"qud": None, "raves": None}


def _fresh_capture(kind, capture_fn, src):
    """Run capture_fn until src's content differs from the previous element's
    capture (or two attempts pass). Both apps can serve a stale frame: the Raves
    viewer races its snapshot apply; Qud's ScreenCapture can fire before
    RenderBase recomposites the turn."""
    import hashlib
    for attempt in range(2):
        if not capture_fn():
            return False
        md5 = hashlib.md5(open(src, "rb").read()).hexdigest()
        if md5 != _last_md5[kind] or attempt == 1:
            _last_md5[kind] = md5
            return True
        time.sleep(1.2)
    return True


def shots_for(bp, cat="single"):
    """Capture the same-turn Qud/Raves pair for the congruence pass.

    Both halves can race the turn (see _fresh_capture); the Raves side also
    gets a settle first — read_snapshot() returns the moment the frame is
    broadcast, but the viewer needs a beat to apply + render it (caught in
    calibration: the 'Black Marble' capture showed the wax block)."""
    outdir = os.path.join(REPORTS, "shots", cat)
    os.makedirs(outdir, exist_ok=True)
    pair = {}
    # Focus Qud for its capture: on Windows its tile-map camera only
    # recomposites while FOCUSED (the mac unfocused-render fixes don't hold
    # here — a frozen buffer served identical map crops across 240 turns).
    # Raves' capture is focus-independent (force_draw), so focus can stay put.
    if plat.IS_WIN:
        try:
            plat.activate("CavesOfQud")
            time.sleep(0.5)
        except Exception:
            pass
    if _fresh_capture("qud", control.qud_shot, control.QUD_SHOT):
        pair["qud"] = os.path.join(outdir, _safe(bp) + "_qud.png")
        shutil.copyfile(control.QUD_SHOT, pair["qud"])
    time.sleep(0.8)   # let the viewer apply the snapshot it just received
    if _fresh_capture("raves", control.godot_shot, control.SHOT):
        pair["raves"] = os.path.join(outdir, _safe(bp) + "_raves.png")
        shutil.copyfile(control.SHOT, pair["raves"])
    return pair


def score_pair(r, pair):
    """Attach the stage-cell congruence verdict (congruence.py) to a result."""
    if "qud" not in pair or "raves" not in pair:
        r.setdefault("warns", []).append("no capture pair — congruence skipped")
        return r
    geom = congruence.load_geometry()
    r["congruence"] = congruence.score(pair["qud"], pair["raves"], geom, r.get("wire_hex"))
    return r


def calibrate():
    """Two-frame differential calibration (congruence.py docstring): a full-tile
    wall frame vs an EMPTY-stage frame — the diff is the whole sprite, i.e. the
    cell. (Wall-vs-wall failed: different walls share most of their pattern
    under the zone tint, so only the differing band clustered.) The empty frame
    stages a bogus blueprint: the zone clears, nothing lands, the verdict FAILS
    by design. Writes fixtures/checker_geometry.json + crop previews to eyeball."""
    b = control.Bridge()
    caps = {}
    for tag, bp, must_pass in (("a", "Wax Block", True), ("c", "__calib_empty__", False)):
        r = check_one(b, bp)
        if must_pass and not r["pass"]:
            b.close()
            sys.exit("calibrate: staging %r failed: %s" % (bp, r["reasons"]))
        pair = shots_for(bp, "calib")
        if "qud" not in pair or "raves" not in pair:
            b.close()
            sys.exit("calibrate: capture failed (is the Raves viewer open?)")
        caps[tag] = pair
    b.close()
    # Wall-vs-EMPTY for both apps: the diff is the whole sprite = the cell.
    # (At the sweep zoom — `checker.py zoom` first — Qud's cluster comes back
    # a perfect 16:24 cell with no LOS-shadow contamination; wall-vs-wall
    # instead caught only the two sprites' differing band.)
    #
    # Search fracs are PER APP, measured on the pinned PC layout against the
    # apps' SELF-captures (client-area px): Qud's sidebar starts ≈60% of its
    # 2301-wide render (its Nearby-objects icon is a pixel-perfect copy of the
    # staged sprite — it won twice before the clip excluded it); Raves' 1:1
    # panels start ≈48.6% of 3232. Re-measure if either layout changes.
    qrect = congruence.diff_cluster(caps["a"]["qud"], caps["c"]["qud"], search_frac=0.58)
    rrect = congruence.diff_cluster(caps["a"]["raves"], caps["c"]["raves"], search_frac=0.48)
    path = congruence.save_geometry(qrect, rrect)
    outdir = os.path.join(REPORTS, "shots", "calib")
    congruence.save_crop(caps["a"]["qud"], qrect, os.path.join(outdir, "cell_qud.png"))
    congruence.save_crop(caps["a"]["raves"], rrect, os.path.join(outdir, "cell_raves.png"))
    print("qud   stage cell:", qrect)
    print("raves stage cell:", rrect)
    print("geometry:", path)
    print("previews:", outdir, "(eyeball cell_qud/cell_raves — both should be the Wax Block)")


def write_report(cat, results):
    """Write <cat>.md + .json, MERGING with the existing json by blueprint —
    so --start/--limit slices aggregate into one report instead of clobbering
    it (chunked long sweeps; resumed runs)."""
    os.makedirs(REPORTS, exist_ok=True)
    jpath = os.path.join(REPORTS, cat + ".json")
    merged = {}
    if os.path.exists(jpath):
        try:
            for r in json.load(open(jpath)):
                merged[r["bp"]] = r
        except ValueError:
            pass
    for r in results:
        merged[r["bp"]] = r
    results = list(merged.values())
    with open(jpath, "w") as f:
        json.dump(results, f, indent=1)

    passed = sum(1 for r in results if r["pass"])
    scored = [r for r in results if r.get("congruence")]
    px_line = ""
    if scored:
        bands = {"PASS": 0, "WARN": 0, "FAIL": 0}
        for r in scored:
            bands[r["congruence"]["band"]] += 1
        px_line = "pixel: %(PASS)d PASS / %(WARN)d WARN / %(FAIL)d FAIL" % bands
    lines = ["# Object Checker — %s" % cat, "",
             "%d/%d PASS  (%s)  %s" % (passed, len(results), time.strftime("%Y-%m-%d %H:%M"), px_line), "",
             "| element | verdict | px | notes |", "|---|---|---|---|"]
    for r in results:
        notes = "; ".join(r.get("reasons", []) + r.get("warns", []))
        px = r.get("congruence")
        pxs = ""
        if px:
            pxs = "%s %.1f/%.0f%%" % (px["band"], px["mean_abs_diff"], px["pct_hot"])
        lines.append("| %s | %s | %s | %s |" % (r["bp"], "PASS" if r["pass"] else "**FAIL**", pxs, notes))
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
    elif cmd == "zoom":
        # Deterministic stage zoom for the pixel pass: clamp to max-in, back off
        # 2 quarter-steps. Qud must be FOCUSED — its uiQueue (which ZoomIn/Out
        # marshal through) never drains unfocused on Windows, the same root as
        # the frozen-map-buffer capture fix. Rerun `calibrate` after this.
        if plat.IS_WIN:
            plat.activate("CavesOfQud")
            time.sleep(0.8)
        b = control.Bridge()
        for _ in range(14):
            b.send("zoom", dir="in")
            time.sleep(0.35)
        for _ in range(2):
            b.send("zoom", dir="out")
            time.sleep(0.35)
        b.send("wait")
        b.read_snapshot(timeout=15)
        b.close()
        print("zoom: clamped to max-in minus 2 (rerun `checker.py calibrate` now)")
    elif cmd == "calibrate":
        calibrate()
    elif cmd == "one":
        args = [a for a in argv[1:] if a not in ("--shots", "--diff")]
        if not args:
            sys.exit("usage: checker.py one <Blueprint> [--shots] [--diff]")
        bp = " ".join(args)
        b = control.Bridge()
        r = check_one(b, bp)
        b.close()
        if "--shots" in argv or "--diff" in argv:
            r["shots"] = shots_for(bp)
        if "--diff" in argv:
            score_pair(r, r.get("shots", {}))
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
            if "--shots" in argv or "--diff" in argv:
                r["shots"] = shots_for(bp, cat)
            if "--diff" in argv:
                score_pair(r, r.get("shots", {}))
            results.append(r)
            px = r.get("congruence")
            print("[%d/%d] %-40s %s%s" % (start + i + 1, start + len(names), bp,
                                          "PASS" if r["pass"] else "FAIL " + "; ".join(r["reasons"]),
                                          "  px:%s mean=%s" % (px["band"], px["mean_abs_diff"]) if px else ""))
        b.close()
        print("report:", write_report(cat, results))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

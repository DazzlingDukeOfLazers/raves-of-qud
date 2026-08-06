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

# Elements the harness can't meaningfully verify yet, with why — their verdicts
# report as KNOWN, not FAIL, so real regressions stay visible in the tallies.
try:
    with open(os.path.join(REPO, "fixtures", "checker_known.json")) as _f:
        KNOWN = json.load(_f)
except (OSError, ValueError):
    KNOWN = {}

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
    # The mod's WriteAllText truncates then writes — the mtime bumps on the
    # truncate, so a read can land on an EMPTY file (fired once at furniture
    # 317/748 and killed the category). Retry briefly; the write is millisecond.
    stage = None
    for _ in range(20):
        try:
            with open(STAGE) as f:
                stage = json.load(f)
            break
        except (ValueError, OSError):
            time.sleep(0.1)
    if stage is None:
        return {"bp": bp, "pass": False, "reasons": ["checker_stage.json unreadable (write race)"]}

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
    # POPUP GUARD: Raves mirrors Qud popups as overlays COVERING the playfield —
    # a creature-triggered message (dromad caravan et al.) that nobody dismissed
    # sat over the stage cell for most of a creatures leg and 474 crops scored
    # against popup text. The viewer reports its popup state; clear before capture.
    try:
        st = json.load(open(os.path.join(BASE, "raves_state.json")))
        if st.get("popup"):
            pb = control.Bridge()
            for _ in range(3):
                pb.send("popup", action="cancel")
                time.sleep(0.6)
            pb.close()
            time.sleep(0.8)
    except (OSError, ValueError):
        pass
    if _fresh_capture("raves", control.godot_shot, control.SHOT):
        pair["raves"] = os.path.join(outdir, _safe(bp) + "_raves.png")
        shutil.copyfile(control.SHOT, pair["raves"])
    return pair


def score_pair(r, pair):
    """Attach the stage-cell congruence verdict (congruence.py) to a result.
    A capture copy can race the writer and land truncated (killed the 908-
    creature run at 786) — retry once, then skip scoring with a warn rather
    than crash the sweep."""
    if "qud" not in pair or "raves" not in pair:
        r.setdefault("warns", []).append("no capture pair — congruence skipped")
        return r
    geom = congruence.load_geometry()
    for attempt in range(2):
        try:
            r["congruence"] = congruence.score(pair["qud"], pair["raves"], geom, r.get("wire_hex"))
            return r
        except Exception as e:
            if attempt == 0:
                time.sleep(0.5)
                continue
            r.setdefault("warns", []).append("congruence skipped: %s" % e)
    return r


def ensure_daylight(b):
    """Advance the clock into full day before pixel work. Sweeps themselves
    advance time (~1 turn per element), so long scored runs drift into dusk
    and the two apps' dimming inflates every diff (a night rerun of furniture
    read 653/40/28 vs 703/20/11 in daylight). Day: segments 3250-10000; aim
    for the middle so a category can't cross dusk mid-run."""
    for _ in range(1500):               # ≤ ~1.5 game-hours of waits per pass
        b.send("wait")
        try:
            snap = b.read_snapshot(timeout=15)
        except (OSError, ConnectionError):
            return                       # reconnect lane will pick it up
        t = snap.get("time") or {}
        seg = t.get("segment")
        if seg is None or 5000 <= seg <= 8800:
            return
    return


# Deterministic JITTER (seconds between burst frames): primes-ish, never ~0.5s
# multiples — a fixed cadence phase-locks against the animation clock and reads
# a two-state blinker as one state (the measured playbook's first rule).
ANIM_JITTER = [0.37, 0.61, 0.83, 0.47, 0.73, 0.97, 0.41, 0.67, 0.91, 0.59, 0.79, 0.43]


def anim_measure(b, bp, frames=12):
    """Stage `bp`, then burst-capture EACH app at jittered cadence and count
    distinct stage-cell states + duty. Bursts are per-app (Qud needs focus to
    recomposite on Windows; Raves' capture is focus-free) and not frame-synced —
    the comparison is STATISTICS: state count and dominant-state duty."""
    r = check_one(b, bp)
    if not r["pass"]:
        return {"bp": bp, "ok": False, "reasons": r["reasons"]}
    geom = congruence.load_geometry()
    out = {"bp": bp, "ok": True}
    for app, capture, src, rect in (
            ("qud", control.qud_shot, control.QUD_SHOT, geom["qud"]),
            ("raves", control.godot_shot, control.SHOT, geom["raves"])):
        if plat.IS_WIN:
            # Each app gets FOCUS for its own burst: Qud's map only recomposites
            # focused, and Godot's animation clock freezes unfocused (first
            # campfire run: qud 9 states, raves 1 — the fire was frozen).
            try:
                plat.activate("CavesOfQud" if app == "qud" else "Raves of Qud")
                time.sleep(0.6)
            except Exception:
                pass
        reps = []            # [{sample, count}] — clustered states (noise-floor rule)
        outdir = os.path.join(REPORTS, "anim", _safe(bp))
        os.makedirs(outdir, exist_ok=True)
        for i in range(frames):
            if not capture():
                continue
            sample = congruence.state_sample(src, rect)
            hit = None
            for rep in reps:
                if congruence.state_match(sample, rep["sample"]):
                    hit = rep
                    break
            if hit is not None:
                hit["count"] += 1
            else:
                p = os.path.join(outdir, "%s_state%d.png" % (app, len(reps)))
                try:
                    congruence.save_crop(src, rect, p, scale=2 if app == "raves" else 1)
                except Exception:
                    p = ""
                reps.append({"sample": sample, "count": 1})
            time.sleep(ANIM_JITTER[i % len(ANIM_JITTER)])
        n = sum(rep["count"] for rep in reps)
        states = {i: rep["count"] for i, rep in enumerate(reps)}
        duty = sorted((round(c / float(n), 2) for c in states.values()), reverse=True) if n else []
        out[app] = {"frames": n, "states": len(states), "duty": duty,
                    "class": _anim_class(len(states), n)}
    a, b_ = out.get("qud", {}), out.get("raves", {})
    # Agreement is by BEHAVIOUR CLASS, not exact counts: continuous animations
    # (fire) make nearly every jittered frame unique, so 11-vs-12 states is the
    # same behaviour; discrete blinkers must also land within one state of each
    # other so a two-state blink can't pass against a four-state cycle.
    out["agree"] = (a.get("class") == b_.get("class")
                    and (a.get("class") != "discrete"
                         or abs(a.get("states", 0) - b_.get("states", 0)) <= 1))
    return out


def _anim_class(states, frames):
    if frames == 0:
        return "none"
    if states <= 1:
        return "static"
    if states >= max(4, int(frames * 0.75)):
        return "continuous"
    return "discrete"


def anim_fixture(name, frames=12):
    """Run a named fixture (fixtures/checker_anim.json) or a bare blueprint."""
    try:
        with open(os.path.join(REPO, "fixtures", "checker_anim.json")) as f:
            fixtures = json.load(f)
    except (OSError, ValueError):
        fixtures = {}
    fx = fixtures.get(name)
    bps = fx["blueprints"] if fx else [name]
    expect = (fx or {}).get("expect_states")
    b = control.Bridge()
    ensure_daylight(b)   # a dark cell renders the GHOST path — no anim registry
    results = []
    for bp in bps:
        # Each burst idles the bridge ~40s and the server's churn-reset drops
        # it (same class as the sweep's reconnect lane) — retry with a fresh
        # connection once per blueprint.
        try:
            m = anim_measure(b, bp, frames)
        except (ConnectionError, OSError):
            try:
                b.close()
            except OSError:
                pass
            time.sleep(1.0)
            b = control.Bridge()
            m = anim_measure(b, bp, frames)
        results.append(m)
        if m.get("ok"):
            q, rv = m["qud"], m["raves"]
            verdict = "AGREE" if m["agree"] else "DISAGREE"
            if expect:
                inband = expect[0] <= q["states"] <= expect[1] and expect[0] <= rv["states"] <= expect[1]
                verdict += " in-band" if inband else " OUT-OF-BAND"
            print("%-28s qud %d(%s) | raves %d(%s) -> %s"
                  % (bp, q["states"], q["class"], rv["states"], rv["class"], verdict))
        else:
            print("%-28s STAGE FAILED: %s" % (bp, m.get("reasons")))
    b.close()
    outdir = os.path.join(REPORTS, "anim")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, _safe(name) + ".json")
    with open(path, "w") as f:
        json.dump({"fixture": name, "frames": frames, "expect_states": expect,
                   "measured": results, "when": time.strftime("%Y-%m-%d %H:%M")}, f, indent=1)
    print("report:", path)


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


def _anim_verified():
    """bp -> agree?  from the LATEST rung-4 measurements (reports/checker/anim).
    An element whose burst measurement AGREEs (same behaviour class both apps)
    is verified by STATE AGREEMENT — its single-frame pixel diff is capture
    phase, banded ANIM rather than FAIL. A measured DISAGREE stays FAIL."""
    import glob as _glob
    out = {}
    for p in _glob.glob(os.path.join(REPORTS, "anim", "*.json")):
        try:
            d = json.load(open(p))
        except (OSError, ValueError):
            continue
        for m in d.get("measured", []):
            if not m.get("ok"):
                continue
            # ANIM banding needs BOTH: agreement AND actual animation — a
            # static-AGREE element that still pixel-fails (HangarWall at 47)
            # is a genuine STATIC divergence, not phase noise.
            animated = (m.get("qud", {}).get("class") not in (None, "static")
                        or m.get("raves", {}).get("class") not in (None, "static"))
            out[m["bp"]] = bool(m.get("agree")) and animated
    return out


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
        # A wire-only pass must never DELETE pixel data: keep the previous
        # entry's congruence when the fresh result carries none (a stray
        # wire-only rerun once wiped a category's 745 scores this way).
        old = merged.get(r["bp"])
        if old and old.get("congruence") and not r.get("congruence"):
            r = dict(r, congruence=old["congruence"])
        merged[r["bp"]] = r
    results = list(merged.values())
    for r in results:
        if r["bp"] in KNOWN:
            r["known"] = KNOWN[r["bp"]]
    with open(jpath, "w") as f:
        json.dump(results, f, indent=1)

    passed = sum(1 for r in results if r["pass"] or "known" in r)
    scored = [r for r in results if r.get("congruence")]
    anim = _anim_verified()

    def _band(r):
        if "known" in r:
            return "KNOWN"
        b = r["congruence"]["band"]
        if b != "PASS" and anim.get(r["bp"]) is True:
            return "ANIM"
        return b
    px_line = ""
    if scored:
        bands = {"PASS": 0, "WARN": 0, "FAIL": 0, "KNOWN": 0, "ANIM": 0}
        for r in scored:
            bands[_band(r)] += 1
        px_line = "pixel: %(PASS)d PASS / %(WARN)d WARN / %(FAIL)d FAIL" % bands
        if bands["KNOWN"]:
            px_line += " / %(KNOWN)d KNOWN" % bands
        if bands["ANIM"]:
            px_line += " / %(ANIM)d ANIM" % bands
    lines = ["# Object Checker — %s" % cat, "",
             "%d/%d PASS  (%s)  %s" % (passed, len(results), time.strftime("%Y-%m-%d %H:%M"), px_line), "",
             "| element | verdict | px | notes |", "|---|---|---|---|"]
    for r in results:
        notes = "; ".join(r.get("reasons", []) + r.get("warns", []))
        if "known" in r:
            notes = "KNOWN: " + r["known"]
        px = r.get("congruence")
        pxs = ""
        if px:
            eb = _band(r)
            if eb == "ANIM":
                notes = (notes + "; " if notes else "") + "anim-verified (state agreement); single-frame diff is phase"
            pxs = "%s %.1f/%.0f%%" % (eb, px["mean_abs_diff"], px["pct_hot"])
        verdict = "KNOWN" if "known" in r else ("PASS" if r["pass"] else "**FAIL**")
        lines.append("| %s | %s | %s | %s |" % (r["bp"], verdict, pxs, notes))
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
    elif cmd == "anim":
        # anim <fixture-or-blueprint> [--frames N] — rung 4's measured playbook
        if len(argv) < 2:
            sys.exit("usage: checker.py anim <fixture|Blueprint> [--frames N]")
        fr = int(argv[argv.index("--frames") + 1]) if "--frames" in argv else 12
        name = " ".join(a for a in argv[1:] if not a.startswith("--") and not a.isdigit())
        anim_fixture(name, fr)
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
        if "--diff" in argv:
            ensure_daylight(b)
        results = []
        for i, bp in enumerate(names):
            # The mod's server intermittently RESETS the long-lived sweep
            # connection during scored runs (the per-element qud_shot bridges
            # add ~2 connect/disconnect cycles each; after ~25 elements the
            # broadcast path drops everyone). Reconnect and retry the element
            # once — the server itself recovers instantly.
            try:
                r = check_one(b, bp)
            except (ConnectionError, OSError):
                try:
                    b.close()
                except OSError:
                    pass
                time.sleep(1.0)
                b = control.Bridge()
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
            if (i + 1) % 50 == 0:
                write_report(cat, results)   # crash insurance: merge-flush every 50
            if "--diff" in argv and (i + 1) % 100 == 0:
                ensure_daylight(b)           # big categories cross dusk mid-run
        b.close()
        print("report:", write_report(cat, results))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

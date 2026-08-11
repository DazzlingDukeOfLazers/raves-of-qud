#!/usr/bin/env python3
"""Read the feedback outbox — the triage side of docs/decisions/feedback-pipeline.md.

Reports arrive as one JSON object per line in <support>/feedback.jsonl (the client writes it; see
godot/FeedbackTool.gd). This is the reader: newest first, or grouped by element_key so the thing
several people hit rises to the top.

TEST REPORTS ARE SKIPPED BY DEFAULT. Verifying the feature means filing through it, so a note
containing "[deleteme]" is marked `test: true` at write time and dropped here. `--all` shows them.
The substring is checked as well as the flag, because records written before the flag existed only
carry the text.

  python3 tools/feedback.py                 # newest first
  python3 tools/feedback.py groups          # by element_key, most-reported first
  python3 tools/feedback.py --all           # include [deleteme] reports
  python3 tools/feedback.py --json          # the records themselves, for piping
"""
import argparse
import collections
import json
import os
import sys

SUPPORT = os.path.expanduser("~/Library/Application Support/RavesOfQud")


def is_test(rec):
    """A report filed to exercise the feature, not to say something."""
    if rec.get("test"):
        return True
    return "[deleteme]" in str(rec.get("text", "")).lower()


def load(path, include_test=False):
    if not os.path.exists(path):
        sys.exit("no outbox at %s" % path)
    out = []
    for n, line in enumerate(open(path), 1):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as e:
            # A malformed line is worth naming, not swallowing: it means something wrote to the
            # outbox that should not have, and silently skipping it hides that.
            print("  ! line %d is not JSON (%s)" % (n, e), file=sys.stderr)
            continue
        if not include_test and is_test(rec):
            continue
        out.append(rec)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", nargs="?", default="list", choices=["list", "groups"])
    ap.add_argument("--all", action="store_true", help="include [deleteme] test reports")
    ap.add_argument("--json", action="store_true", help="emit the records instead of a table")
    ap.add_argument("--file", default=os.path.join(SUPPORT, "feedback.jsonl"))
    a = ap.parse_args()

    recs = load(a.file, a.all)
    if a.json:
        for r in recs:
            print(json.dumps(r))
        return

    if a.mode == "groups":
        by = collections.defaultdict(list)
        for r in recs:
            by[r.get("element_key") or r.get("scene") or "?"].append(r)
        print("%-40s %5s  %s" % ("element_key", "n", "most recent"))
        for key, rs in sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            newest = max(rs, key=lambda r: str(r.get("ts", "")))
            print("%-40s %5d  %s" % (key[:40], len(rs), str(newest.get("text", ""))[:60]))
        print("\n%d report(s) in %d group(s)" % (len(recs), len(by)))
        return

    for r in sorted(recs, key=lambda r: str(r.get("ts", "")), reverse=True):
        ver = r.get("app_version", "?")
        shot = "" if r.get("shot") else "   (no image)"
        print("%s  %s %s" % (str(r.get("ts", "?")), ver, shot))
        print("    %s" % (r.get("element_key") or r.get("element") or "?"))
        print("    %s" % str(r.get("text", "")).replace("\n", "\n    "))
        print()
    print("%d report(s)%s" % (len(recs), "" if a.all else "  (test reports hidden; --all shows them)"))


if __name__ == "__main__":
    main()

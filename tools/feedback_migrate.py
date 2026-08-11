#!/usr/bin/env python3
"""Bring PRE-ENVELOPE feedback records up to envelope v1 so they can be submitted.

Reports filed before 2026-08-10 carry no `v`, `app`, `app_version`, `platform` or `install_id`,
so the server refuses them (400) and the client parks them in `feedback.jsonl.rejected` — which is
the outbox behaving correctly: a report the server will never accept must not be retried forever,
and must not be silently dropped either. This is the other half of that contract, the part that
gets them un-stuck.

WHAT IT WILL NOT DO IS GUESS. `app_version` is genuinely unknown for these — they predate the
field, and stamping them with today's version would put a lie in the one column whose whole job is
to pin a report to a build. They go out as "pre-0.8", which is true and sorts sensibly.

    python3 tools/feedback_migrate.py            # report what would move
    python3 tools/feedback_migrate.py --apply    # move it back into the outbox
"""
import argparse
import json
import os
import sys

SUPPORT = os.path.expanduser("~/Library/Application Support/RavesOfQud")
REQUIRED = ("v", "app", "app_version", "platform", "install_id", "ts")


def install_id():
    p = os.path.join(SUPPORT, "install_id.txt")
    if os.path.exists(p):
        got = open(p).read().strip()
        if got:
            return got
    return "unknown"


def upgrade(rec, iid):
    out = dict(rec)
    out.setdefault("v", 1)
    out.setdefault("app", "Raves of Qud")
    # Not today's version. See the module docstring.
    out.setdefault("app_version", "pre-0.8")
    out.setdefault("platform", "macOS")
    out.setdefault("install_id", iid)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--rejected", default=os.path.join(SUPPORT, "feedback.jsonl.rejected"))
    ap.add_argument("--outbox", default=os.path.join(SUPPORT, "feedback.jsonl"))
    a = ap.parse_args()

    if not os.path.exists(a.rejected):
        sys.exit("nothing to migrate: %s" % a.rejected)

    recs, bad = [], 0
    for line in open(a.rejected):
        line = line.strip()
        if not line:
            continue
        try:
            recs.append(json.loads(line))
        except json.JSONDecodeError:
            bad += 1

    iid = install_id()
    up = [upgrade(r, iid) for r in recs]
    # A record with a note the server would still refuse is worth NAMING, not quietly re-queuing
    # into a loop: it would come straight back to .rejected and look like the migration failed.
    empty = [r for r in up if not str(r.get("text", "")).strip()]
    ready = [r for r in up if str(r.get("text", "")).strip()]

    print("%d record(s) in %s" % (len(recs), os.path.basename(a.rejected)))
    if bad:
        print("  %d unparseable line(s) left alone" % bad)
    if empty:
        print("  %d with an empty note -- the server requires one; left in place" % len(empty))
    print("  %d ready to re-queue as app_version='pre-0.8'" % len(ready))

    if not a.apply:
        print("\n(dry run -- pass --apply to move them into the outbox)")
        return

    with open(a.outbox, "a") as f:
        for r in ready:
            f.write(json.dumps(r) + "\n")
    keep = empty
    with open(a.rejected, "w") as f:
        for r in keep:
            f.write(json.dumps(r) + "\n")
    print("\nmoved %d into the outbox; %d left in .rejected" % (len(ready), len(keep)))
    print("Raves flushes on start and after each new report.")


if __name__ == "__main__":
    main()

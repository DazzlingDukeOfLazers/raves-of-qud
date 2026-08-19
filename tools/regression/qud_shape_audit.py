#!/usr/bin/env python3
"""A bare `Settings.qud_shape()` must not guard a user-mode branch.

THE SEAM THIS CLOSES
--------------------
`qud_shape(feature)` answers "should this surface take Qud's shape?", and in USER mode it answers
TRUE unless a QoL feature has been loaded back (Settings.QOL_FEATURES). That is the design -- user
mode starts as a 1:1 clone and features return one at a time.

The trap is what a BARE `qud_shape()` means. With no feature name it can never be false in user
mode, so any `else` hanging off it is unreachable in both modes: dead in 1:1 because the gate is
true, dead in user mode because the gate is *still* true. The user-mode half of that branch is
written, shipped, and can never run.

That is not hypothetical. Three features were lost to exactly this and had to be dug back out:
  - the message log's group-identical-messages toggle
  - Nearby objects' larger icons
  - row 4's user-mode panel heights (90/90/104), still dead at the time of writing

Each looked like a deleted feature and was really an unreachable one, which is the expensive kind:
the code reads as if it works.

THE RULE
--------
A bare `qud_shape()` ASSERTS "both modes render this identically -- there is no user-mode
alternative." So it may not have an else. If a call site has one, it must either name a feature:

    if Settings.qud_shape("msglog"):        # Qud's shape unless the QoL feature is back

or say why it is exempt, on the gate line or the line above:

    # QUD-SHAPE-OK: <reason>

An exemption without a reason is a bug in waiting -- the same rule the typing-guard audit uses.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "godot")
BARE = re.compile(r"Settings\.qud_shape\(\s*\)")
OK = "QUD-SHAPE-OK"


def indent_of(line):
    return len(line) - len(line.lstrip("\t "))


def scan(path):
    """Bare gates whose branch has a reachable user-mode half."""
    out = []
    with open(path, encoding="utf8") as fh:
        lines = fh.read().split("\n")
    for i, line in enumerate(lines):
        if not BARE.search(line):
            continue
        stripped = line.strip()
        if stripped.startswith("#"):
            continue                      # prose about the gate, not a gate
        if OK in line or (i and OK in lines[i - 1]):
            continue                      # exempted, with its reason next to it
        # a one-line ternary: `X if <bare> else Y` -- the else is the user-mode half
        if " if " in stripped and " else " in stripped:
            out.append((i + 1, stripped, "ternary has an else branch"))
            continue
        # a block `if <bare>:` -- look for an `else:` at the same indent before the block ends
        if not re.match(r"(el)?if\b", stripped):
            continue
        base = indent_of(line)
        for j in range(i + 1, len(lines)):
            nxt = lines[j]
            if not nxt.strip() or nxt.strip().startswith("#"):
                continue
            ind = indent_of(nxt)
            if ind > base:
                continue                  # still inside the branch body
            if ind == base and re.match(r"(else\s*:|elif\b)", nxt.strip()):
                out.append((i + 1, stripped, "block has an %s at line %d"
                            % (nxt.strip().split(":")[0].split()[0], j + 1)))
            break                         # dedented: the branch is over either way
    return out


def main():
    if not os.path.isdir(ROOT):
        sys.exit("no godot/ dir at %s" % ROOT)
    bad = {}
    n_files = 0
    for name in sorted(os.listdir(ROOT)):
        if not name.endswith(".gd"):
            continue
        n_files += 1
        hits = scan(os.path.join(ROOT, name))
        if hits:
            bad[name] = hits
    if not bad:
        print("qud_shape: no bare gate guards a user-mode branch (%d scripts)" % n_files)
        return 0
    print("BARE qud_shape() WITH AN UNREACHABLE USER-MODE BRANCH\n")
    total = 0
    for name in sorted(bad):
        for ln, src, why in bad[name]:
            total += 1
            print("  %s:%d  %s" % (name, ln, why))
            print("      %s" % src)
    print("\n%d site(s). Each must either name a QoL feature -- qud_shape(\"<feature>\") -- or"
          "\ncarry a `# %s: <reason>` on the gate line or the line above." % (total, OK))
    return 1


if __name__ == "__main__":
    sys.exit(main())

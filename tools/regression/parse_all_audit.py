#!/usr/bin/env python3
"""SPOT: --check-only every godot/*.gd and fail on REAL parse errors.

The per-commit headless run (`--quit-after 120`) only deep-checks scripts it LOADS —
and half the app (SkyGrade, ZoneRenderer, everything the Holodeck pulls in on Connect)
loads only when a player connects, so a parse error there ships silently and the
exported app comes up with an empty playfield (measured 2026-08-12: one double quote
inside a shader-string comment).

Godot's --check-only output has three distinct classes (docs/testing.md):
  "Parse Error"                            -> REAL, always a failure
  "Compile Error: Identifier not found"    -> autoload false positive, ignore
  "Failed to compile depended scripts"     -> cascade of the above, ignore
We fail ONLY on the first. Exit 0 clean / 1 with the offending lines.
"""
import pathlib
import subprocess
import sys

GODOT = "/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot"
ROOT = pathlib.Path(__file__).resolve().parents[2]

fails = []
for gd in sorted((ROOT / "godot").glob("*.gd")):
    r = subprocess.run(
        [GODOT, "--headless", "--path", str(ROOT / "godot"),
         "--check-only", "--script", "res://" + gd.name],
        capture_output=True, text=True, timeout=120)
    for line in (r.stdout + r.stderr).splitlines():
        if "Parse Error" in line:
            fails.append(f"{gd.name}: {line.strip()}")

if fails:
    print("PARSE FAILURES:")
    print("\n".join(fails))
    sys.exit(1)
print("parse_all: every godot/*.gd parses")

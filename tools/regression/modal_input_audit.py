#!/usr/bin/env python3
"""Modal-input audit — SPOT test (static, ~0.1s, no apps required).

Daniel, 2026-08-10: "While you're scrolling Skills, the background playfield receives the
scroll wheel messages and zooms."

WHAT IT CHECKS, and why static. This is the typing guard's defect class one input device
over: an event a modal did not CONSUME reaches the handler underneath it. The mouse version
has its own trap, and it is not obvious from reading either file alone —

    MOUSE_FILTER_STOP is not enough for the WHEEL.

Godot propagates a wheel event UP the Control chain and marks it handled only when some
control calls `accept_event()`. A full-rect STOP root therefore swallows clicks while
letting every wheel tick through to `_unhandled_input`. Measured on the skills screen: the
playfield tiles behind the modal grew visibly, against a 0.00 ambient diff.

Both halves of the fix are structural, so both are decidable by reading the source:

  1. every overlay's `gui_input` handler ends in an `accept_event()` for mouse events, so
     the event stops at the modal;
  2. Main's `_unhandled_input` mouse branch asks `_modal_owns_input()` before it drives the
     camera — the backstop for any overlay that forgets (1).

Checking only (1) would pass the day someone adds a fifth overlay; checking only (2) would
pass while the wheel still reached other listeners. An audit that checks one pass of a
two-pass rule is the audit that let this bug ship.

    python3 tools/regression/modal_input_audit.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "godot")

# The overlays that own the whole screen while visible.
#
# The rule below applies to the ones that HANDLE mouse input on a full-rect modal root
# (`gui_input.connect`): those must consume it. PopupOverlay and PickerOverlay have such a
# root but hang no handler on it — they rely on MOUSE_FILTER_STOP to "eat clicks headed for
# the Holodeck", which is true for clicks and false for the wheel. They are covered by
# Main's `_modal_owns_input()` backstop instead (both are named in it), so the camera is
# safe; a wheel over them still travels to other unhandled-input listeners, which is worth
# knowing and is why they are REPORTED rather than skipped silently.
MODALS = ["StatusScreens.gd", "ControlMappingScreen.gd", "PopupOverlay.gd", "PickerOverlay.gd"]

failures = []
notes = []


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as f:
        return f.read()


def body_of(src, header):
    """Source of the func starting at `header` up to the next top-level `func`."""
    i = src.find(header)
    if i < 0:
        return None
    rest = src[i + len(header):]
    m = re.search(r"\nfunc ", rest)
    return rest[: m.start()] if m else rest


# ---- (1) each modal consumes mouse events in its gui_input handler ---------------------
for name in MODALS:
    try:
        src = read(name)
    except FileNotFoundError:
        notes.append("%s: not present, skipped" % name)
        continue
    # Only a handler hung on the MODAL ROOT is in scope. Per-widget gui_input (an option
    # row, a LineEdit) is a different thing, and demanding accept_event() there would be a
    # rule about the wrong node.
    if "_root.gui_input.connect" not in src:
        notes.append("%s: no handler on the modal root — its wheel is covered by Main's "
                     "_modal_owns_input() backstop, not by consumption here" % name)
        continue
    if "_root.accept_event()" not in src:
        failures.append(
            "%s handles mouse on its modal root but never calls _root.accept_event() — a "
            "wheel tick over this modal propagates past it (MOUSE_FILTER_STOP does not "
            "stop the wheel)" % name)

# ---- (2) Main's camera branch defers to the modal --------------------------------------
main = read("Main.gd")
if "func _modal_owns_input()" not in main:
    failures.append("Main.gd has no _modal_owns_input() — the one definition four call "
                    "sites share; without it the copies drift, which is how the mouse "
                    "branch ended up with none")
body = body_of(main, "func _unhandled_input(")
if body is None:
    failures.append("Main.gd has no _unhandled_input to audit")
else:
    i = body.find("elif event is InputEventMouseButton:")
    if i < 0:
        failures.append("Main.gd _unhandled_input has no InputEventMouseButton branch — "
                        "this audit is pinned to a shape that no longer exists; re-point it")
    else:
        # the guard must come BEFORE the first camera mutation in that branch
        tail = body[i:]
        guard = tail.find("_modal_owns_input()")
        first_cam = min([p for p in (tail.find("_cam_rig._orbiting"),
                                     tail.find("_cam_rig._panning"),
                                     tail.find("zoom_1to1_step"),
                                     tail.find("_cam_rig._top_zoom"),
                                     tail.find("_cam_rig._dist")) if p >= 0] or [-1])
        if guard < 0:
            failures.append("Main.gd's mouse branch never calls _modal_owns_input() — a "
                            "wheel/drag over an open modal drives the camera underneath it")
        elif first_cam >= 0 and guard > first_cam:
            failures.append("Main.gd's mouse branch touches the camera BEFORE asking "
                            "_modal_owns_input() — the guard has to come first")

for n in notes:
    print("  note %s" % n)
if failures:
    for f in failures:
        print("  FAIL %s" % f)
    print("\nFAILED (%d)" % len(failures))
    sys.exit(1)
print("  ok   every modal consumes mouse events in gui_input")
print("  ok   Main's camera branch defers to _modal_owns_input() first")
print("\nall good (0 checks failed)")

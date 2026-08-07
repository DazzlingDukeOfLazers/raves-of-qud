#!/usr/bin/env python3
"""Typing-guard audit — SPOT test (static, ~0.2s, no apps required).

Daniel, 2026-08-07: "Add a typing guard in all text fields so typed characters don't trigger other
menus … make sure all text fields are updated."

WHAT IT CHECKS, and why it is a static audit rather than a live one. The defect class is structural,
not visual: a keyboard hotkey dispatched from `_input` fires BEFORE Godot's GUI pass, so a focused
LineEdit/TextEdit has not yet consumed the key and `is_input_handled()` is still false. Any `_input`
handler that reads `keycode` is therefore a latent "typing opens a menu" bug. That is decidable by
reading the source, so it runs in milliseconds and needs no game, no Qud, and no window — which
also means it cannot go flaky.

It reports two things:
  1. every `_input` handler that dispatches keys WITHOUT consulting TypingGuard   -> FAIL
  2. an inventory of every text field, so a new one is visible in the diff        -> INFO

Exit 0 = clean. Exit 1 = at least one unguarded dispatcher.

The live counterpart (does typing in a real field actually leave the menus alone?) is the FULL
regression case documented in docs/testing.md — this audit is what you run on every commit.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "godot")

# `_input` handlers that legitimately act WHILE typing, with the reason. Anything else that reads a
# keycode from `_input` must call TypingGuard.typing().
EXEMPT = {
    "FeedbackTool.gd": "owns the note field; its Esc/Cmd+Enter must work WHILE typing",
    "PopupOverlay.gd": "mirrors Qud's own text-input popup; Esc/Enter submit while typing",
}


def scan():
    unguarded, fields, checked = [], [], []
    for name in sorted(os.listdir(ROOT)):
        if not name.endswith(".gd"):
            continue
        src = open(os.path.join(ROOT, name), encoding="utf-8").read()

        for m in re.finditer(r"\b(LineEdit|TextEdit|CodeEdit)\.new\(\)", src):
            fields.append((name, m.group(1)))

        # body of `func _input(...)` up to the next top-level `func`
        m = re.search(r"\nfunc _input\(", src)
        if not m:
            continue
        body = src[m.start():]
        nxt = re.search(r"\nfunc (?!_input\()", body[1:])
        if nxt:
            body = body[: nxt.start() + 1]
        if not re.search(r"keycode|is_action_pressed", body):
            continue
        checked.append(name)
        if "TypingGuard.typing" not in body and name not in EXEMPT:
            unguarded.append(name)
    return unguarded, fields, checked


def main():
    unguarded, fields, checked = scan()
    print(f"text fields found : {len(fields)}")
    for f, kind in fields:
        print(f"    {f:26s} {kind}")
    print(f"\n_input key dispatchers checked : {len(checked)}")
    for f in checked:
        why = EXEMPT.get(f)
        state = f"EXEMPT ({why})" if why else ("guarded" if f not in unguarded else "UNGUARDED")
        print(f"    {f:26s} {state}")
    if unguarded:
        print("\nFAIL: these dispatch keys from _input without TypingGuard.typing():")
        for f in unguarded:
            print(f"    {f}  -> add `if TypingGuard.typing(get_viewport()): return` at the top,")
            print("       or add it to EXEMPT here with the reason it must act while typing.")
        return 1
    print("\nOK: every _input key dispatcher is guarded or explicitly exempt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

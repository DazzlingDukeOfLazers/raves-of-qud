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

THE UNHANDLED PASS IS AUDITED TOO, as of 2026-08-09, and its absence is why this audit passed
while the bug was live. `_unhandled_input` / `_unhandled_key_input` see only what the GUI did not
consume, and that was written down here and in TypingGuard as "guarded for free". It is not: a
field consumes the keys it has a USE for and ignores the rest, and modifier combos are the rest.
Measured with the feedback note focused — plain letters landed in the box, `Ctrl+Shift+X` ran
Qud's xp wish (0 -> 150 Exp) through Main's unhandled handler. An audit that checks the pass where
the bug cannot be is not a check.

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

# Handlers that legitimately act WHILE typing, with the reason. Anything else that reads a keycode
# from an input callback must call TypingGuard.typing().
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

        for hook in ("_input", "_unhandled_input", "_unhandled_key_input"):
            # body of `func <hook>(...)` up to the next top-level `func`
            m = re.search(r"\nfunc %s\(" % hook, src)
            if not m:
                continue
            body = src[m.start() + 1:]
            nxt = re.search(r"\nfunc ", body)
            if nxt:
                body = body[: nxt.start()]
            if not re.search(r"keycode|is_action_pressed", body):
                continue
            # THE TWO PASSES NEED DIFFERENT RULES, because they see different keys.
            #
            # `_input` runs BEFORE the GUI, so it sees everything and any keycode it acts on can
            # fire under a typist's fingers. Flag it all.
            #
            # The unhandled passes see only what the focused field did NOT consume, so most of what
            # they act on is already unreachable while typing: text, digits, arrows, backspace. What
            # a field does NOT eat is modifier combos and function keys — and Escape, which those
            # screens use to back out and SHOULD still work with a search box focused. So flag the
            # unhandled pass on the reachable class only: modifiers, F-keys, or anything that
            # dispatches to Qud. Flagging the rest would mean either ten blanket guards that break
            # Esc, or a ten-entry exemption list, and both hide the next real one.
            if hook != "_input" and not re.search(
                    r"ctrl_pressed|meta_pressed|alt_pressed|KEY_F\d|send_command|request_command", body):
                continue
            where = "%s:%s" % (name, hook)
            checked.append(where)
            if "TypingGuard.typing" not in body and name not in EXEMPT:
                unguarded.append(where)
    return unguarded, fields, checked


def main():
    unguarded, fields, checked = scan()
    print(f"text fields found : {len(fields)}")
    for f, kind in fields:
        print(f"    {f:26s} {kind}")
    print(f"\nkey dispatchers checked : {len(checked)}")
    for f in checked:
        why = EXEMPT.get(f.split(":")[0])
        state = f"EXEMPT ({why})" if why else ("guarded" if f not in unguarded else "UNGUARDED")
        print(f"    {f:34s} {state}")
    if unguarded:
        print("\nFAIL: these dispatch keys without TypingGuard.typing():")
        for f in unguarded:
            print(f"    {f}  -> add `if TypingGuard.typing(get_viewport()): return` at the top,")
            print("       or add it to EXEMPT here with the reason it must act while typing.")
        return 1
    print("\nOK: every key dispatcher is guarded or explicitly exempt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

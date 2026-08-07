# State-tree panel in Raves (Ctrl+scroll) — design, before any code

Daniel: "add the state tree/test tree into Raves, Ctrl+scrollwheel to bring it up, click a state
and the game navigates there, something something work graph A*."

Answering the three questions with what the code already says, because two of them are cheaper
than they look and the third is a different feature than it sounds.

## 1. Ctrl+scroll is free — but it must be CLAIMED, not just bound

`Main.gd`'s wheel branch lives in `_unhandled_input` and does not test modifiers, so Ctrl+wheel
currently zooms the camera like a plain wheel. The panel therefore has to intercept it in `_input`
and call `set_input_as_handled()` — exactly the split Ctrl+click and Cmd+right-click already use
(inspect and the feedback form live in `_input`; orbit/pan/zoom stay in `_unhandled_input`).
Without that, the tree would open AND the camera would zoom underneath it.

Suggested gesture: Ctrl+wheel-up opens/expands the panel, Ctrl+wheel-down collapses/closes it —
a continuous "pull it in" rather than a toggle, which is what the wheel is good at.

## 2. The transport already exists on both ends

highvisor's daemon RPC (port **48720**) is 4-byte-length-prefixed JSON over TCP — **the identical
frame format Raves already speaks to the mod's bridge on 48710**. `QudSync.send_bridge` is ~90% of
the client already; it needs a read path (the mod is fire-and-forget, this is request/response).

Two ops cover the whole panel:

| op | gives |
|---|---|
| `gamestate` | every node's live status for both apps — `{node, label, path, off, running, via}` |
| `gamego` | drive an app to a node via its `goto` recipe; idempotent, returns per-step trace |

So the panel is: fetch `gametree.json` (or have the daemon serve it), render it, poll `gamestate`
for the "you are here" highlight, and send `gamego` on click. No new protocol, no new mod work.

## 3. A* is not needed for this, and that is a finding, not a shortcut

The obvious read is "states are a graph, so pathfind between them." But every node in
`gametree.json` already carries a `goto[app]` step list that is a COMPLETE route from a known base
(its title screen), and `engine._gamego` already resolves `{"goto": node}` chains recursively and
returns early when the app is already there. **The recipes are the edges, pre-solved.** Running A*
over a tree where each node stores its own full route would compute an answer we already have.

A* becomes worth it only under a different data model — replace per-node recipes with a set of
TRANSITIONS (from-state, to-state, action, cost, precondition) and derive routes. That is a real
improvement, and it earns its keep on things the current model does badly:

- routes **from anywhere**, not just from a known base (today an unexpected start = recipe failure)
- no duplicated prefixes across sibling recipes
- costs could encode what we have learned the hard way — a Qud restart is expensive, `uiback` is
  cheap, anything needing OCR is flaky-expensive — so the planner prefers first-party moves
- an unreachable target is a *planning* failure with a reason, instead of a step that fails midway

That is a gametree redesign living in **highvisor**, not a Raves panel. Ship the panel on the
recipes we have; revisit the graph when "the recipe assumed the wrong starting screen" actually
starts costing us. Do not build both at once — the panel is the thing that gets used daily.

## Slices (each independently useful, each verifiable)

1. **Read-only tree.** Ctrl+wheel opens a panel; fetch the tree + `gamestate`; render both apps'
   current node highlighted. No navigation. This alone replaces "alt-tab to the cockpit to see
   where we are."
2. **Click to navigate.** Click a node → `gamego` → show the returned step trace live, including
   failures (the trace is already structured; do not reduce it to ok/fail).
3. **Test tree.** The same nodes carry `done` scores and the SPOT/FULL tests; show them, and let a
   node run its check.

## Gate it

highvisor is a dev tool on localhost and Raves is meant to become distributable (Phase 2). The
panel must be dev-only — hidden unless the daemon answers on 48720, and it must fail SILENTLY when
it does not, so a shipped build never shows a player a dead debug panel or a connection error.

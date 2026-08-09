# PC → Mac merge, 2026-08-08 — raves side (pointer)

**The plan lives in the highvisor repo: [`highvisor/docs/merge-plan-2026-08-08.md`](../../highvisor/docs/merge-plan-2026-08-08.md).**
It covers both repos, because the decisive file is highvisor's `gametree.json` and the two merges
have to be staged together. Read it there. This page exists so a session that starts in *this* repo
does not merge blind.

Not to be confused with [`pc-to-mac-merge-instructions.md`](../pc-to-mac-merge-instructions.md) at
the repo root — that is the historical 2026-07-25 runbook about the allspice re-authoring, and it
does not apply here.

## The three things worth knowing before you touch this repo

**1. `origin/dd/pc-lumpy-merge` merges CLEAN, and that is the hazard, not the reassurance.** Lumpy
has been continuously merging `origin/main` (five times on the raves branch), so the merge-base is
`main~1` and git will not stop and ask about anything. All Mac work survives — `UiState.popup_n` /
`ensure_popup` coexist with the PC's new `ui_age`, `StartupHook`'s `tab` sampler is untouched, the
two-flag focus keeper in `Bridge.cs` is untouched, `MapEditorDriver.cs` is not in the changed set,
and `PopupOverlay.gd` (the box-model port) is not touched at all. Verified by grep, not assumed.

**2. The parity baselines survive the merge — this was checked, not hoped.** The merged
`tools/capture/parity.py` produces byte-identical `--json` output to `main`'s on the committed
captures, and reproduces both committed scoreboards at `max|delta| = 0.0000`
(`reports/2026-08-08-parity-baseline/` 33 leaves, `reports/2026-08-05-item-popup/` 7 leaves). Its
new FROZEN REFERENCE guard does not trip on either — the qud/qud2 pairs differ on 380k and 1.09M
pixels. **So B1 and B2 remain valid measuring instruments and are the "before" every gate compares
to.**

**3. Deploy order in Stage E is not optional.** Restart Qud fully *before* measuring anything (mods
compile at startup), rebuild Raves *before* using `hv shot --live` (the `ui_age` field the gate reads
does not exist in the currently-running build), and delete
`~/Library/Application Support/RavesOfQud/title_bg.json` — that machine-local override is polled live
and will fight `MainMenu`'s new baked-in 1.010 backdrop scale.

## SPOT status on the merged tree, measured 2026-08-08

Run against a throwaway clone, both working trees untouched:

| check | result |
|---|---|
| `tools/regression/typing_guard_audit.py` | **PASS** — field inventory 14 → 15, the new one being `MapEditorScreen.gd LineEdit`. A different delta means an unpredicted text field. |
| `Godot --check-only --script res://Main.gd` | clean (all eight changed `.gd` files check clean individually too) |
| `dotnet build mod/RavesOfQudBridge.csproj` | **0 errors**, 18 pre-existing `CS0618` warnings — clears `PlayerBridgeLoadAttach.cs` against this Mac's Qud assembly |
| state-graph render test · `--quit-after 120` | **not run** — both instantiate autoloads and `UiState._ready` writes the shared state files, and both apps were live. Run them with the apps down (Stage D). |

## The one prediction to check at FULL 2

`StatusPaneInventory.gd` now centres the filter strip on the live category count instead of using
baked constants. At `FILT_MAX_CELLS` (12 = ALL + 11 categories) the new arithmetic reproduces the old
constants exactly — `_filt_left(12) = 590`, ALL at 618, Q badge 590, E badge 1310 — so **on an
11-category fixture this is a no-op and `filter_*` must reproduce the 2026-08-08 baseline within
noise. If those leaves move, stop and measure** rather than re-baselining: it would mean
`sync-raves-and-qud` is not 11-category and the change has real geometry consequences here.

Controls for that comparison are `doll_frame[0..4]`, `filter_frame[1..4]`, `outer_frame` only.
`list_cat`/`list_item` are **not** chrome — `docs/testing.md` records getting that wrong once.

# PC → Mac merge instructions

Read this on the Mac **before** fetching, testing, or merging the PC branches.

## What changed on the PC (and why this matters)

The PC box's local git identity was accidentally set to the AllSpice work email
(`daniel+altium@allspice.io`), so four commits were authored under it. They've been
**rebuilt with the personal identity** (`Daniel D Lindmark <daniel.dee@gmail.com>`),
which gives them **new SHAs**. The four remote branches were deleted and re-pushed
with the re-authored commits (no force-push; fresh refs).

Re-authored commits (content identical, only author/committer changed):

| branch | commit (message) |
|---|---|
| `dd/pc` | "Add Windows capture backend (plat_win) + PC dev harness" |
| `dd/pc-selection` | + "Add dashed-wireframe selection marker + clean-plate capture" |
| `dd/pc-camera-top-down-qud-classic` | + "Add Qud-classic top-down camera modes" |
| `dd/object-configurator` | + "Add object-configurator store (objconf.py)" |

`main` and `dd/mac` were **never touched** — they had no allspice commits.

The **risk** on the Mac: any stale local copy of these branches still holds the OLD
allspice commits. Merging or pushing one of those would drag the unwanted author
back into history. The steps below neutralize that.

## Steps (run on the Mac)

### 1. Prune and re-sync remote refs
```
git fetch --all --prune
```
`--prune` drops the deleted remote-tracking branches and pulls the re-authored ones.

### 2. Repoint (or delete) any stale local PC branches
For each PC branch you happen to have checked out locally on the Mac, force it to
match the re-authored remote so it can't carry old commits:
```
git checkout <branch>
git reset --hard origin/<branch>
```
If you don't develop the PC branches on the Mac, just delete the stale locals instead:
```
git branch -D dd/pc dd/pc-selection dd/pc-camera-top-down-qud-classic dd/object-configurator 2>/dev/null
```
(They'll come back clean from `origin/*` whenever you check them out.)

### 3. Confirm the Mac's identity is personal (one-time)
```
git config user.email
```
Should be `daniel.dee@gmail.com`. Some older Mac commits used the machine default
`homefolder@Daniels-MacBook-Pro.local` — not the allspice handle, but you may want to
standardize it:
```
git config user.name  "Daniel D Lindmark"
git config user.email "daniel.dee@gmail.com"
```

### 4. Merge the PRs
Merge only from the re-authored remote branches (never from a stale Mac-local branch):
- **GitHub merge button:** the merge/squash commit takes *your GitHub account's*
  identity, not allspice — clean.
- **Local merge:** with the personal `user.email` above and a branch based on the new
  commits, the result stays clean.

## Verify (after step 1) — should print nothing
```
git log --all --format='%ae' | grep -i allspice
```
The dangling old allspice commits live only on the remote until GitHub garbage-collects
them (~2 weeks) and won't come down with a pruned fetch.

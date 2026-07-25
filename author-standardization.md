# Whole-repo author standardization → daniel.dee@gmail.com

Rewrites **every commit on every branch** so author *and* committer are
`Daniel D Lindmark <daniel.dee@gmail.com>`. This is the follow-up to the partial
cleanup already done (the 36 commits unique to `dd/mac`/`dd/mac-waterdeep` are already
gmail; this pass catches the **169 machine-default commits in `main`'s shared base**).

## ⚠️ Run this LAST, once, from ONE machine

It rewrites the **shared base**, so it changes the SHA of *every* commit on *every*
branch. That's only safe if done in a single pass over all refs and then force-pushed
together — otherwise branches diverge and merges break.

**Preconditions:**
1. All PC→Mac PRs are **merged** (or you've decided not to merge them). Don't run this
   mid-merge — do it after the history is settled, so no old-identity commits land after.
2. No one is about to push. Tell the PC to hold.
3. Working tree clean; you're on this repo; you have all branches locally or as
   `origin/*` remote-tracking refs.

## Steps

```bash
# 1. Get every branch current and local
git fetch --all --prune
for b in main dd/mac dd/mac-waterdeep dd/pc dd/pc-selection \
         dd/pc-camera-top-down-qud-classic dd/object-configurator; do
  git branch -f "$b" "origin/$b" 2>/dev/null || true
done

# 2. Safety backup (so you can undo before pushing)
git bundle create ../raves-preauthor-backup.bundle --all

# 3. Rewrite author + committer on ALL commits, ALL branches
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '
export GIT_AUTHOR_NAME="Daniel D Lindmark"
export GIT_AUTHOR_EMAIL="daniel.dee@gmail.com"
export GIT_COMMITTER_NAME="Daniel D Lindmark"
export GIT_COMMITTER_EMAIL="daniel.dee@gmail.com"
' --tag-name-filter cat -- --all

# 4. VERIFY — must print exactly one line: daniel.dee@gmail.com daniel.dee@gmail.com
git log --all --format='%ae %ce' | sort -u

# 5. Drop filter-branch's backup refs once verified
git for-each-ref --format='%(refname)' refs/original/ \
  | xargs -n1 --no-run-if-empty git update-ref -d

# 6. Push everything (deliberate — this is the irreversible step)
git push --force origin --all
git push --force origin --tags   # (no tags today, harmless)
```

## Cross-machine re-sync (REQUIRED on the PC afterward)

Every other clone still holds the OLD SHAs. Each must **discard and re-adopt** the new
history — never merge/push its old copy back, or it re-introduces the old identities:

```bash
git fetch --all --prune
for b in main dd/pc dd/pc-selection dd/pc-camera-top-down-qud-classic dd/object-configurator; do
  git checkout "$b" && git reset --hard "origin/$b"
done
```

## Notes
- The old commits dangle on GitHub until it garbage-collects them (~2 weeks); a pruned
  fetch won't bring them back.
- If a PR merge added a `GitHub <noreply@github.com>` committer, step 3 rewrites that too.
- To undo before step 6: `git fetch ../raves-preauthor-backup.bundle 'refs/*:refs/*'`.

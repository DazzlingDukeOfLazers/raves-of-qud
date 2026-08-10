#!/usr/bin/env bash
# Qud API BASELINE — a diffable record of the installed assembly's public surface.
#
# WHY. Steam patches Assembly-CSharp.dll IN PLACE, so the moment an update lands the previous
# version is gone from this machine and "what changed?" becomes unanswerable. That happened
# with the 2026-08-08 maintenance patch: we compile against the live install, so we picked it
# up silently and correctly, and could not produce a diff for it afterwards because there was
# nothing left to diff against.
#
# This writes a snapshot of the surface the mod actually depends on. Commit it. When the next
# patch lands, re-run and `git diff` — the change set is right there, in review.
#
# NOT a decompile of the whole assembly (~100MB of C#, useless in review and a redistribution
# question we do not want). Just names: types, and the members of the types we touch.
#
#   tools/qud_api_snapshot.sh            # refresh docs/qud-api/*.txt
#   git diff docs/qud-api                # what the patch changed
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/docs/qud-api"
MANAGED="${CoQManaged:-/Users/homefolder/Library/Application Support/Steam/steamapps/common/Caves of Qud/CoQ.app/Contents/Resources/Data/Managed}"
DLL="$MANAGED/Assembly-CSharp.dll"
APP="$(cd "$MANAGED/../../../.." && pwd)"
ILSPY="$HOME/.dotnet/tools/ilspycmd"
export DOTNET_ROOT="${DOTNET_ROOT:-$(ls -d /opt/homebrew/Cellar/dotnet/*/libexec 2>/dev/null | tail -1)}"

[ -f "$DLL" ] || { echo "no Assembly-CSharp.dll at $DLL" >&2; exit 2; }
[ -x "$ILSPY" ] || { echo "ilspycmd not installed (dotnet tool install -g ilspycmd)" >&2; exit 2; }
mkdir -p "$OUT"

# 1. WHICH BUILD. The version + the Steam buildid + the DLL's own mtime, so a diff always says
#    which patch it belongs to even when the API surface happens not to move.
{
  echo "# Caves of Qud build identity — regenerate with tools/qud_api_snapshot.sh"
  printf 'CFBundleShortVersionString  %s\n' \
    "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
  printf 'Assembly-CSharp.dll mtime   %s\n' "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$DLL")"
  printf 'Assembly-CSharp.dll bytes   %s\n' "$(stat -f '%z' "$DLL")"
  printf 'Assembly-CSharp.dll sha256  %s\n' "$(shasum -a 256 "$DLL" | cut -d' ' -f1)"
  ACF="/Users/homefolder/Library/Application Support/Steam/steamapps/appmanifest_333640.acf"
  if [ -f "$ACF" ]; then
    printf 'steam buildid               %s\n' "$(grep -m1 '"buildid"' "$ACF" | awk -F'"' '{print $4}')"   # tabs, not spaces: awk -F'"' or the field vanishes
    printf 'steam LastUpdated           %s\n' "$(grep -m1 '"LastUpdated"' "$ACF" | awk -F'"' '{print $4}')"   # tabs, not spaces: awk -F'"' or the field vanishes
  fi
} > "$OUT/build.txt"

# 2. EVERY TYPE. Cheap (metadata only) and catches a renamed/removed class immediately — the
#    failure mode that costs the most, because the mod stops compiling with no clue what moved.
# NB: one -l per entity kind. `-l c,i,s,d,e` is accepted and prints NOTHING — a silent empty
# baseline, which is the worst possible outcome for a file whose whole job is to diff.
# Compiler-generated noise (<>f__AnonymousType, <PrivateImplementationDetails>, display
# classes) is dropped: it churns between builds without meaning anything.
: > "$OUT/types.txt"
for KIND in c i s d e; do
  "$ILSPY" "$DLL" -l "$KIND" 2>/dev/null >> "$OUT/types.txt"
done
grep -v '<' "$OUT/types.txt" | sort -u > "$OUT/types.tmp" && mv "$OUT/types.tmp" "$OUT/types.txt"
[ -s "$OUT/types.txt" ] || { echo "types.txt came out EMPTY — refusing to write a baseline that cannot diff" >&2; exit 3; }

# 3. THE TYPES WE ACTUALLY BIND TO, member by member. A signature change here is the one that
#    breaks us silently at RUNTIME (reflection) rather than loudly at build time. Grepped
#    signature lines only — no bodies, so the file stays reviewable and is not a source dump.
: > "$OUT/members.txt"
while read -r T; do
  [ -z "$T" ] && continue
  echo "=== $T ===" >> "$OUT/members.txt"
  "$ILSPY" "$DLL" -t "$T" 2>/dev/null \
    | grep -E '^\s*(public|protected internal|protected)\s' \
    | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*/  /' \
    | grep -v '^\s*//' | sort -u >> "$OUT/members.txt" || echo "  (type not found)" >> "$OUT/members.txt"
done < "$REPO/tools/qud_api_types.txt"

echo "wrote $OUT/{build,types,members}.txt"
wc -l "$OUT/build.txt" "$OUT/types.txt" "$OUT/members.txt"

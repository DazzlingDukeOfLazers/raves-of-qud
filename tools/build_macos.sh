#!/usr/bin/env bash
#
# Build a crisp (HiDPI) macOS .app of Raves.
#
# Why this exists: Godot's editor/dev-run (`--path`) gives a floating window a NON-HiDPI backing
# on Retina, so macOS upscales it 2x and all text looks pixelated. An EXPORTED .app sets
# NSHighResolutionCapable and renders at native resolution — crisp. But Godot's built-in ad-hoc
# signature gets SIGKILL'd at launch on Apple Silicon ("Launchd job spawn failed / 163"), so we
# re-sign ad-hoc afterward, which the kernel accepts.
#
# Prereqs (one-time): export templates for the matching Godot version installed under
#   ~/Library/Application Support/Godot/export_templates/<version>/   (Editor > Manage Export Templates).
#
# Usage:  tools/build_macos.sh   then   open build/RavesOfQud.app
set -euo pipefail

GODOT="${GODOT:-/Users/homefolder/Downloads/Godot.app/Contents/MacOS/Godot}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/RavesOfQud.app"

echo "› exporting macOS build…"
rm -rf "$OUT"
"$GODOT" --headless --path "$REPO/godot/" --export-debug "macOS" "../build/RavesOfQud.app"

echo "› re-signing ad-hoc (Apple Silicon launch fix)…"
codesign --force --deep --sign - "$OUT"
codesign --verify --verbose=1 "$OUT"

echo "✓ built + signed: $OUT"
echo "  open it:  open '$OUT'   (start Caves of Qud first — same localhost bridge)"

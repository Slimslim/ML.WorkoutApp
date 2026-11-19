#!/bin/bash
# Xcode Cloud runs this right after it clones the repo (ci_scripts sits next to the project).
# The Xcode project is generated from BarPath/project.yml and is not committed, so generate it here.
set -euo pipefail

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"

if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

cd "$REPO/BarPath"
xcodegen

# Xcode Cloud doesn't resolve packages itself: it needs the pinned versions (Supabase and its
# dependencies). The project folder is generated and git-ignored, so the pins are committed as
# BarPath/Package.resolved and copied into the workspace here. Refresh it from a local Xcode build
# whenever a package version changes (docs/RELEASES.md, CI).
PINS="Package.resolved"
DEST="BarPath.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [ ! -f "$PINS" ]; then
    echo "error: BarPath/Package.resolved is missing. Commit it from a local Xcode build (see docs/RELEASES.md, CI)." >&2
    exit 1
fi
mkdir -p "$DEST"
cp "$PINS" "$DEST/Package.resolved"

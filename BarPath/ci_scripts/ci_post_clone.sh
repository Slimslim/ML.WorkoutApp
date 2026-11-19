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

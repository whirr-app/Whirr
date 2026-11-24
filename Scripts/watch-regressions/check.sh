#!/usr/bin/env bash
# Build Core's Watch targets and run the Watch host regressions, as the CI App job does.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"
export CLANG_MODULE_CACHE_PATH="$repository_root/Packages/Core/.build/mcache"
export XDG_CACHE_HOME="$repository_root/Packages/Core/.build/xdg"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
swift build --package-path Packages/Core --target WatchPlayback
python3 Scripts/watch-regressions/run.py

#!/usr/bin/env bash
# Prints the repository's own Swift sources, NUL-separated, for format.sh and check-format.sh.
#
# Xcode writes generated sources (asset symbols, string catalogs) and SwiftPM's package checkouts
# into build directories under App/. Neither is ours to format: rewriting a checkout in place
# breaks the next build that reads it (a collapsed multi-line `#if` in GRDB no longer compiles).
# So the list is gathered explicitly with build output pruned rather than handed to --recursive,
# and both scripts share it so the formatter cannot reach further than the lint.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
swift_directories=()

for directory in "$repository_root/Packages" "$repository_root/App"; do
  if [[ -d "$directory" ]]; then
    swift_directories+=("$directory")
  fi
done

if ((${#swift_directories[@]} > 0)); then
  find "${swift_directories[@]}" \
    \( -type d \( -name Build -o -name DerivedData -o -name '.build' -o -name '*.noindex' \) -prune \) \
    -o \( -type f -name '*.swift' -print0 \)
fi

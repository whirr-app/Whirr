#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"

swift_files=()
while IFS= read -r -d '' file; do
  swift_files+=("$file")
done < <("$script_directory/swift-sources.sh")

if ((${#swift_files[@]} > 0)); then
  swift format format \
    --configuration "$repository_root/.swift-format" \
    --in-place \
    --parallel \
    "${swift_files[@]}"
fi

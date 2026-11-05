#!/bin/bash
# Engine bench: the working-tree engine against the frozen Classic engine (Sfera 1.0) and
# Sfera 0.9, both extracted from git; limiter checks; CPU. Exits non-zero on any failure,
# including a failed build. Arguments are passed to the bench (see Sources/Bench/main.swift).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

LEGACY_COMMIT="2b61cdd"   # Sfera 0.9
CLASSIC_COMMIT="d18a518"  # Sfera 1.0: the Classic sound (Dry/Near/Mid/Far) that must not drift

# Extracts <path> at <commit> into <dir>, re-extracting if the directory came from another commit.
extract() {
  local commit="$1" path="$2" dir="$3"
  local full; full="$(git -C .. rev-parse --verify "$commit^{commit}")"
  if [ "$(cat "$dir/.commit" 2>/dev/null || true)" != "$full" ]; then
    echo "▸ extracting $path from $commit into Bench/$dir"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C .. archive "$full" "$path" | tar -x -C "$dir"
    echo "$full" > "$dir/.commit"
  fi
}
extract "$LEGACY_COMMIT" Sources/SpatialCore .legacy
extract "$CLASSIC_COMMIT" Sources/SferaCore .classic

if ! log="$(swift build -c release --product Bench 2>&1)"; then
  echo "$log" | sed "s/\x1b\[[0-9;]*m//g" | grep -E "error|warning" || echo "$log"
  echo "✗ Bench build failed"
  exit 1
fi
echo "$log" | sed "s/\x1b\[[0-9;]*m//g" | grep -E "warning|Build complete" || true
"$(swift build -c release --show-bin-path)/Bench" "$@"

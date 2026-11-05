#!/bin/bash
# Compares the rewritten engine (SferaCore) against Sfera 0.9's engine, built from git,
# on identical input: output difference and CPU time.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
LEGACY_COMMIT="2b61cdd"
if [ ! -d .legacy/Sources/SpatialCore ]; then
  echo "▸ extracting Sfera 0.9 engine from $LEGACY_COMMIT"
  mkdir -p .legacy
  git -C .. archive "$LEGACY_COMMIT" Sources/SpatialCore | tar -x -C .legacy
fi
swift build -c release --product Bench 2>&1 | grep -E "error|warning: unre|Compiling|Build" | grep -v "^\[" | sed "s/\x1b\[[0-9;]*m//g" || true
"$(swift build -c release --show-bin-path)/Bench" "$@"

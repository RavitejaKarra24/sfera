#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▸ build (debug + release)"
swift build
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Sfera"

echo "▸ engine equivalence + CPU vs the previous engine (Bench/)"
Bench/run.sh

echo "▸ BlackHole surround round trip (needs BlackHole + microphone permission; output at −90 dB)"
if "$BIN" --surround-probe; then :; else
  echo "  (not fatal: run '$BIN --surround-probe' from Terminal to check the BlackHole route)"
fi

echo "▸ app routing: start → pick your output → pick BlackHole → stop (Sfera at −90 dB)"
if "$BIN" --route-probe; then :; else
  echo "  (not fatal: see ~/Library/Logs/Sfera.log)"
fi

echo "▸ system tap (no BlackHole route; output at −90 dB)"
if "$BIN" --tap-probe; then :; else
  echo "  (not fatal: run '$BIN --tap-probe' from Terminal; restricted shells get no tap callbacks)"
fi

echo "▸ snapshots"
mkdir -p docs/screenshots
for page in atmos stereo stereo-tap original off settings; do
  "$BIN" --snapshot "docs/screenshots/$page.png" --page "$page" >/dev/null
done

echo "▸ shell syntax"
bash -n Scripts/package_app.sh

echo
echo "✓ all checks finished"

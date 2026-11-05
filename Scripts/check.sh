#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

echo "▸ build (debug + release)"
swift build
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Sfera"

echo "▸ engine tests"
if [ -f "$PLUGIN" ]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"
else
  echo "  swift-testing macro plugin not found; skipping framework tests"
fi

echo "▸ headless self-check (upmix, binaural room, adaptive surround switch, movies)"
mkdir -p docs/screenshots
"$BIN" --self-check docs/self-check.json

echo "▸ movie playback sync (real audio device, output at −90 dB)"
"$BIN" --movie-probe | tail -1

echo "▸ BlackHole surround round trip (needs BlackHole + microphone permission)"
if "$BIN" --surround-probe; then :; else
  echo "  (not fatal: run '$BIN --surround-probe' from Terminal to check the BlackHole route)"
fi

echo "▸ app routing: BlackHole → your output → BlackHole → stop (Sfera at −90 dB)"
if "$BIN" --route-probe; then :; else
  echo "  (not fatal: see ~/Library/Logs/Sfera.log)"
fi

echo "▸ snapshots"
for page in listen listen-tip listen-files listen-movie; do
  "$BIN" --snapshot "docs/screenshots/$page.png" --page "$page" >/dev/null
done

echo "▸ shell syntax"
bash -n Scripts/package_app.sh

echo
echo "✓ all checks finished"

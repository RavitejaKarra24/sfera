#!/bin/bash
# Builds, runs the engine bench (fatal), then the hardware probes. Probes that don't pass are
# reported as "not passed" at the end instead of being hidden; STRICT=1 makes them fatal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▸ build (debug + release)"
swift build
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Sfera"

echo "▸ engine equivalence + CPU vs the previous engine (Bench/)"
Bench/run.sh

# Hardware probes need BlackHole, microphone permission and a normal (unrestricted) session.
not_passed=()
probe() {
  local name="$1" hint="$2"; shift 2
  if "$@"; then
    echo "  ✓ $name"
  else
    echo "  ⚠ $name did not pass ($hint)"
    not_passed+=("$name")
  fi
}

echo "▸ BlackHole surround round trip (needs BlackHole + microphone permission; output at −90 dB)"
probe "surround probe" "run '$BIN --surround-probe' from Terminal" "$BIN" --surround-probe

echo "▸ app routing: start → pick your output → pick BlackHole → stop (Sfera at −90 dB)"
probe "route probe" "see ~/Library/Logs/Sfera.log" "$BIN" --route-probe

echo "▸ system tap (no BlackHole route; output at −90 dB)"
probe "tap probe" "run '$BIN --tap-probe' from Terminal; restricted shells get no tap callbacks" "$BIN" --tap-probe

echo "▸ snapshots"
mkdir -p docs/screenshots
for page in atmos stereo stereo-tap original off settings; do
  "$BIN" --snapshot "docs/screenshots/$page.png" --page "$page" >/dev/null
done

echo "▸ shell syntax"
bash -n Scripts/package_app.sh

echo
if [ ${#not_passed[@]} -eq 0 ]; then
  echo "✓ all checks passed"
else
  echo "✓ build and engine bench passed"
  echo "⚠ hardware probes not passed: ${not_passed[*]}"
  if [ "${STRICT:-0}" = "1" ]; then exit 1; fi
fi

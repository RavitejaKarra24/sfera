#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/Sfera.app"
BUNDLE_ID="dev.sfera.renderer"
VERSION="1.0.0"

echo "▸ building ($CONFIG)"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sfera" "$APP/Contents/MacOS/Sfera"

if [ ! -f "$ROOT/Icon.icns" ]; then
  echo "▸ generating icon"
  swift "$ROOT/Scripts/make_icon.swift" "$ROOT/Icon.png" >/dev/null
  ICONSET="$(mktemp -d)/Icon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$ROOT/Icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ROOT/Icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ROOT/Icon.icns"
fi
cp "$ROOT/Icon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sfera</string>
  <key>CFBundleDisplayName</key><string>Sfera</string>
  <key>CFBundleExecutable</key><string>Sfera</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Spatial audio for headphones. Not affiliated with Dolby Laboratories.</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Sfera listens to Apple Music (or other apps) so it can spatialise them live for your headphones. Audio never leaves your Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>macOS counts BlackHole as a microphone. Sfera reads it only to spatialise the surround and Atmos audio your apps play into it. Nothing is recorded and audio never leaves your Mac.</string>
</dict>
</plist>
PLIST

echo "▸ signing (ad hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ built $APP"
du -sh "$APP"

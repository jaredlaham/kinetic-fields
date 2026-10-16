#!/usr/bin/env bash
# Builds T-8 Pattern Studio.app (release) from the Swift package. macOS only.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product T8PatternStudio
BIN="$(swift build -c "$CONFIG" --show-bin-path)/T8PatternStudio"

APP="build/T-8 Pattern Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/T8PatternStudio"
cp Sources/T8PatternStudio/Info.plist "$APP/Contents/Info.plist"

# App icon from the 1024px master.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Keychain access and Gatekeeper behave for local builds.
codesign --force --deep --sign - "$APP"
echo "Built: $APP"

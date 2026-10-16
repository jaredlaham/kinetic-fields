#!/usr/bin/env bash
# Builds "Kinetic Stem Studio.app" (release) from the Swift package. macOS only.
# The app bundle carries the engine's Python sources, models and installer;
# the Python environment itself is installed on first run (Engine Setup).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product KineticStemStudio
BIN="$(swift build -c "$CONFIG" --show-bin-path)/KineticStemStudio"

APP="build/Kinetic Stem Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KineticStemStudio"
cp Sources/KineticStemStudio/Info.plist "$APP/Contents/Info.plist"

# Engine sources (no caches, no eval fixtures) and the installer.
mkdir -p "$APP/Contents/Resources/engine" "$APP/Contents/Resources/scripts"
rsync -a --exclude '__pycache__' --exclude '*.pyc' engine/kstem "$APP/Contents/Resources/engine/"
cp engine/requirements*.txt "$APP/Contents/Resources/engine/"
cp scripts/install-engine.sh "$APP/Contents/Resources/scripts/"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature for local builds (Gatekeeper still asks once: Privacy & Security > Open Anyway).
codesign --force --deep --sign - "$APP"
echo "Built: $APP"

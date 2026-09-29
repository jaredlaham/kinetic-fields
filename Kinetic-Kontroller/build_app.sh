#!/usr/bin/env bash
# Build "Kinetic Kontroller.app" into dist/.
#
#   ./build_app.sh                 build, test, then ask about /Applications
#   ./build_app.sh --install       ...and copy to /Applications without asking
#   ./build_app.sh --no-install    never copy to /Applications (CI)
#   ./build_app.sh --skip-tests    skip the unit tests
#   TARGET_ARCH=universal2 ./build_app.sh   (needs a universal2 Python)
#
# The resulting app bundles its own Python and Qt; it does not need this
# virtual environment, Homebrew, or anything on your $PATH to run.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="Kinetic Kontroller"
APP_PATH="dist/${APP_NAME}.app"
VENV="${VENV:-.venv}"
INSTALL="ask"
RUN_TESTS=1

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL="yes" ;;
    --no-install) INSTALL="no" ;;
    --skip-tests) RUN_TESTS=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- python ----
find_python() {
  if [[ -n "${PYTHON:-}" ]]; then echo "$PYTHON"; return; fi
  for c in python3.12 python3.13 python3.11 python3.10 python3; do
    if command -v "$c" >/dev/null 2>&1; then
      if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
        command -v "$c"; return
      fi
    fi
  done
  return 1
}

if [[ ! -x "$VENV/bin/python" ]]; then
  PY="$(find_python)" || die "Python 3.9+ not found. Install it (e.g. 'brew install python@3.12') and re-run."
  say "Creating virtual environment ($VENV) with $PY"
  "$PY" -m venv "$VENV"
fi
VPY="$PROJECT_DIR/$VENV/bin/python"
"$VPY" --version

say "Installing dependencies"
"$VPY" -m pip install --quiet --upgrade pip
"$VPY" -m pip install --quiet -r requirements-dev.txt

# ----------------------------------------------------------------- tests ----
if [[ "$RUN_TESTS" == 1 ]]; then
  say "Running tests"
  QT_QPA_PLATFORM=offscreen "$VPY" -m pytest -q tests
fi

# ------------------------------------------------------------------ icon ----
mkdir -p build
ICON_PNG="build/icon_1024.png"
QT_QPA_PLATFORM=offscreen "$VPY" tools/make_icon.py "$ICON_PNG" >/dev/null
export APC_ICON=""
if [[ "$(uname)" == "Darwin" ]]; then
  say "Creating app icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  export APC_ICON="$PROJECT_DIR/build/AppIcon.icns"
fi

# ----------------------------------------------------------------- build ----
say "Building with PyInstaller"
rm -rf "dist/${APP_NAME}" "$APP_PATH"
"$VPY" -m PyInstaller --noconfirm --clean \
  --distpath dist --workpath build/pyinstaller \
  packaging/kinetic_kontroller.spec

if [[ "$(uname)" == "Darwin" ]]; then
  [[ -d "$APP_PATH" ]] || die "Build finished but $APP_PATH is missing"
  BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
  # The onedir folder next to the .app is an intermediate; the .app is complete.
  rm -rf "dist/${APP_NAME}"

  say "Signing (ad-hoc) and verifying"
  codesign --force --deep --sign - "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH" && echo "signature OK"

  ARCHS="$(lipo -archs "$BIN" 2>/dev/null || file "$BIN")"
  echo "Architecture: $ARCHS"

  say "Self-test of the packaged app (clean environment, simulated APC)"
  # env -i: no venv, no Homebrew, minimal PATH -> proves the bundle is standalone.
  if env -i HOME="$HOME" PATH="/usr/bin:/bin" "$BIN" --fake-midi --self-test 4 > build/self-test.log 2>&1; then
    grep '^SELF-TEST' build/self-test.log | cut -c1-300
    echo "Self-test PASSED"
  else
    cat build/self-test.log | tail -40
    die "Packaged app self-test failed (log: build/self-test.log)"
  fi
  du -sh "$APP_PATH" | awk '{print "Size: " $1}'
else
  BIN="dist/${APP_NAME}/${APP_NAME}"
  say "Not macOS: built a $(uname -m) onedir folder instead of a .app (dist/${APP_NAME}/)"
  if env -i HOME="$HOME" PATH="/usr/bin:/bin" QT_QPA_PLATFORM=offscreen "$BIN" --fake-midi --self-test 3 > build/self-test.log 2>&1; then
    grep '^SELF-TEST' build/self-test.log | cut -c1-300
    echo "Self-test PASSED"
  else
    tail -40 build/self-test.log
    die "Packaged self-test failed"
  fi
  exit 0
fi

# --------------------------------------------------------------- install ----
say "Built: $PROJECT_DIR/$APP_PATH"
if [[ "$INSTALL" == "ask" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Copy to /Applications now? [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]] && INSTALL="yes" || INSTALL="no"
  else
    INSTALL="no"
  fi
fi
if [[ "$INSTALL" == "yes" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  if pgrep -f "${DEST}/Contents/MacOS" >/dev/null 2>&1; then
    echo "Quitting the running copy first…"
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 2
  fi
  rm -rf "$DEST"
  ditto "$APP_PATH" "$DEST"
  echo "Installed: $DEST"
  echo "Launch it from Launchpad/Spotlight, or: open \"$DEST\""
else
  echo "Drag \"$APP_PATH\" into /Applications, or re-run with --install."
fi

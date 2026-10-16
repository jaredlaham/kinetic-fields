#!/usr/bin/env bash
# Download the workspace topo pattern into apc_light/assets/topo_custom.svg
# (bundled into the app; git-ignored). Falls back silently to the built-in
# topo.svg if offline. Usage: tools/fetch_topo.sh [--force]
set -uo pipefail
cd "$(dirname "$0")/.."
TOPO_URL="${TOPO_URL:-https://framerusercontent.com/images/uaUxwlMansPbn02p3mr8zn5jqL8.svg}"
DEST="apc_light/assets/topo_custom.svg"
if [[ -s "$DEST" && "${1:-}" != "--force" ]]; then
  echo "Topo pattern: $DEST (cached)"; exit 0
fi
TMP="$(mktemp)"
if curl -fsSL --max-time 30 "$TOPO_URL" -o "$TMP" && grep -q "<svg" "$TMP"; then
  mv "$TMP" "$DEST"
  echo "Topo pattern: downloaded $(wc -c < "$DEST" | tr -d ' ') bytes -> $DEST"
else
  rm -f "$TMP"
  echo "Topo pattern: download failed; using the built-in pattern"
fi
exit 0

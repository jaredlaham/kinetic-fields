#!/usr/bin/env bash
# Installs the Kinetic Stem Studio analysis engine into its own Python environment.
#
#   ./scripts/install-engine.sh [--high] [--dev] [--venv DIR]
#
#   --high   also install CREPE (PyTorch, about 1 GB) for High Accuracy leads/vocals
#   --dev    also install test/evaluation tools (pytest, mir_eval)
#   --bootstrap-uv  install uv (https://astral.sh/uv) first when neither uv nor
#            Python 3.10/3.11 is available; uv then fetches Python 3.11
#   --venv   where to create the environment
#            (default: ~/Library/Application Support/KineticStemStudio/engine-venv)
#
# Uses uv when available (it can fetch Python 3.11 itself); otherwise needs
# python3.11 or python3.10 on PATH. Nothing outside the environment is changed.
set -euo pipefail
cd "$(dirname "$0")/../engine"

HIGH=0; DEV=0; BOOTSTRAP=0
VENV="${HOME}/Library/Application Support/KineticStemStudio/engine-venv"
[[ "$(uname)" == "Darwin" ]] || VENV="${HOME}/.local/share/kinetic-stem-studio/engine-venv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --high) HIGH=1 ;;
    --dev) DEV=1 ;;
    --bootstrap-uv) BOOTSTRAP=1 ;;
    --venv) VENV="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

have_python() { command -v python3.11 >/dev/null 2>&1 || command -v python3.10 >/dev/null 2>&1; }
if ! command -v uv >/dev/null 2>&1 && ! have_python && [[ $BOOTSTRAP == 1 ]]; then
  echo "Installing uv (it fetches Python 3.11 for the engine)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi

if command -v uv >/dev/null 2>&1; then
  uv venv --python 3.11 "$VENV"
  PIP=(uv pip install --python "$VENV/bin/python")
else
  PY=""
  for candidate in python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
  done
  if [[ -z "$PY" ]]; then
    echo "Need Python 3.10 or 3.11 (Basic Pitch does not support newer versions yet)." >&2
    echo "Install uv (https://docs.astral.sh/uv/) and run this script again; uv fetches Python 3.11 for you." >&2
    exit 1
  fi
  "$PY" -m venv "$VENV"
  "$VENV/bin/python" -m pip install --upgrade pip >/dev/null
  PIP=("$VENV/bin/python" -m pip install)
fi

"${PIP[@]}" -r requirements.txt
# Basic Pitch without its dependency list: that list pulls TensorFlow on some
# platforms. The engine runs Basic Pitch's bundled ONNX model with onnxruntime.
"${PIP[@]}" --no-deps -r requirements-nodeps.txt
if [[ $HIGH == 1 ]]; then "${PIP[@]}" -r requirements-high.txt; fi
if [[ $DEV == 1 ]]; then "${PIP[@]}" -r requirements-dev.txt; fi

echo '{}' | PYTHONPATH="$PWD" "$VENV/bin/python" -m kstem doctor | tail -1
echo
echo "Engine environment: $VENV"

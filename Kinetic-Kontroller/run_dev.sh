#!/usr/bin/env bash
# Run from source (development). Extra args are passed through, e.g.:
#   ./run_dev.sh --debug          verbose logging in this terminal
#   ./run_dev.sh --fake-midi      simulated APC, no hardware needed
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements-dev.txt
fi
exec .venv/bin/python main.py "$@"

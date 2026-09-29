"""Standard per-user locations.

macOS:  ~/Library/Application Support/APC Light Controller/settings.json
        ~/Library/Application Support/APC Light Controller/effects/  (user effects)
        ~/Library/Logs/APC Light Controller/apc-light-controller.log
Linux:  ~/.config/apc-light-controller/ and ~/.cache/apc-light-controller/logs
Override everything with the APC_LIGHT_HOME environment variable (tests).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from .. import APP_NAME


def _override() -> Path | None:
    v = os.environ.get("APC_LIGHT_HOME")
    return Path(v) if v else None


def support_dir() -> Path:
    base = _override()
    if base is None:
        if sys.platform == "darwin":
            base = Path.home() / "Library" / "Application Support" / APP_NAME
        elif sys.platform.startswith("win"):
            base = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME
        else:
            base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "apc-light-controller"
    base.mkdir(parents=True, exist_ok=True)
    return base


def log_dir() -> Path:
    base = _override()
    if base is not None:
        d = base / "logs"
    elif sys.platform == "darwin":
        d = Path.home() / "Library" / "Logs" / APP_NAME
    else:
        d = support_dir() / "logs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def settings_file() -> Path:
    return support_dir() / "settings.json"


def user_effects_dir() -> Path:
    d = support_dir() / "effects"
    d.mkdir(parents=True, exist_ok=True)
    return d

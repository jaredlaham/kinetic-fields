"""JSON settings with defaults, validation and atomic saves."""

from __future__ import annotations

import copy
import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional

from . import paths

log = logging.getLogger("apc.settings")

DEFAULTS: Dict[str, Any] = {
    "version": 2,
    "last_effect": None,          # id of the last effect that was started
    "restore_on_launch": False,   # start last_effect automatically at launch
    "speed": 50,                  # 0..100, 50 = 1x
    "brightness": 100,            # percent, snapped to the APC's 7 levels
    "output_mode": "palette",     # "palette" (Note On) or "rgb" (SysEx)
    "favorites": ["kinetic_sweep", "rainbow", "mosaic", "creeper", "heart", "kinetic_marquee"],
    "midi_port": "",              # "" = auto-detect the APC mini mk2 Control port
    "shortcuts": {},              # key -> effect id overrides ("1": "rainbow")
    "effect_params": {},          # effect id -> {param: value}
    "scene_buttons": True,        # APC scene launch buttons switch favourites
    "blackout_on_quit": True,
    "show_diagnostics": False,
    "hardware_preview": True,     # visualizer shows what the APC can actually display
    "window_geometry": None,
    "patterns": {},               # saved Custom Pattern snapshots: name -> 64 colours
    "notes": "",                  # free-text notes (Browser > Notes)
    "ui_state": {},               # tabs, collapsed sections
    "topo_opacity": 25,           # workspace topo pattern opacity, percent (0 = hidden)
    "topo_svg": "",               # custom topo SVG path ("" = bundled pattern)
}


class Settings:
    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = Path(path) if path else paths.settings_file()
        self.data: Dict[str, Any] = copy.deepcopy(DEFAULTS)
        self.load()

    def load(self) -> None:
        try:
            raw = json.loads(self.path.read_text("utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("settings root is not an object")
        except FileNotFoundError:
            log.info("No settings yet; using defaults (%s)", self.path)
            return
        except Exception as exc:
            backup = self.path.with_suffix(".corrupt.json")
            log.error("Settings unreadable (%s); backing up to %s and using defaults", exc, backup)
            try:
                os.replace(self.path, backup)
            except OSError:
                pass
            return
        for key, default in DEFAULTS.items():
            if key in raw and (default is None or isinstance(raw[key], type(default))
                               or (isinstance(default, int) and isinstance(raw[key], (int, float)))):
                self.data[key] = raw[key]
        self._migrate(int(raw.get("version", 1)))
        self.data["speed"] = max(0, min(100, int(self.data["speed"])))
        self.data["brightness"] = max(0, min(100, int(self.data["brightness"])))
        if self.data["output_mode"] not in ("palette", "rgb"):
            self.data["output_mode"] = "palette"
        log.info("Settings loaded from %s", self.path)

    def _migrate(self, version: int) -> None:
        if version < 2:
            # v2: Kinetic Sweep is favourite #1 (= APC scene button 1, key 1).
            favs = [f for f in self.data["favorites"] if f != "kinetic_sweep"]
            self.data["favorites"] = ["kinetic_sweep"] + favs
            log.info("Settings migrated to v2: Kinetic Sweep is favorite #1")
        self.data["version"] = DEFAULTS["version"]

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".settings-", suffix=".json", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(self.data, fh, indent=2, sort_keys=True)
            os.replace(tmp, self.path)
        except Exception:
            log.exception("Could not save settings")
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def __getitem__(self, key: str) -> Any:
        return self.data[key]

    def __setitem__(self, key: str, value: Any) -> None:
        self.data[key] = value

    def get(self, key: str, default: Any = None) -> Any:
        return self.data.get(key, default)

"""Render the main window offscreen for visual QA against the design mockup.

    QT_QPA_PLATFORM=offscreen python tools/screenshot_ui.py out_dir [W H]
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
out = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
W, H = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (1586, 992)
out.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("APC_LIGHT_HOME", str(out / "home"))

from PySide6.QtCore import QTimer  # noqa: E402

import apc_light.app.application as A  # noqa: E402

Y, B, K = "#ffe600", "#0070ff", "#000000"
MOCK = [
    "YY....YB", "YBY...YY", ".YYY....", "..YBY...", "...YYY..", "....YBY.", "YY...YYY", "BY....YB",
]
PATTERN = [{"Y": Y, "B": B}.get(ch, K) for row in MOCK for ch in row]


def script(ctl):
    b = ctl.device.backend
    return [
        (0, lambda: (ctl.window.resize(W, H), ctl.set_output_mode("rgb"), ctl.window.inspector.brightness.setValue(3), ctl.window.inspector.speed.setValue(26),
                     ctl.engine.set_params("custom_pattern", {"pattern": PATTERN, "brush": "#0070ff"}),
                     ctl.start_effect("custom_pattern"), ctl.window.refresh_params())),
        (900, lambda: ctl.window.grab().save(str(out / "ui_custom_pattern.png"))),
        (0, lambda: (ctl.start_effect("kinetic_sweep"), ctl.pattern_action("kinetic_sweep", "preset:RETRO"))),
        (1200, lambda: (b.press(27), b.press(45))),
        (180, lambda: ctl.window.grab().save(str(out / "ui_kinetic_sweep.png"))),
        (0, lambda: (b.release(27), b.release(45), ctl.window.inspector.set_tab("Colors"), ctl.start_effect("heart"))),
        (400, lambda: ctl.window.grab().save(str(out / "ui_colors.png"))),
        (0, lambda: (ctl.window.inspector.set_tab("MIDI"),)),
        (400, lambda: ctl.window.grab().save(str(out / "ui_midi.png"))),
        (0, lambda: (ctl.window.inspector.set_tab("Behavior"), ctl.blackout())),
        (400, lambda: ctl.window.grab().save(str(out / "ui_behavior_blackout.png"))),
        (0, lambda: ctl.window.resize(1440, 900)),
        (500, lambda: ctl.window.grab().save(str(out / "ui_1440.png"))),
        (100, lambda: A.QApplication.instance().quit()),
    ]


_orig = A.Controller.__init__


def _init(self, *a, **kw):
    _orig(self, *a, **kw)
    steps = script(self)

    def run(i=0):
        if i < len(steps):
            delay, fn = steps[i]
            QTimer.singleShot(delay, lambda: (fn(), run(i + 1)))
    QTimer.singleShot(500, run)


A.Controller.__init__ = _init
sys.exit(A.main(["--fake-midi"]))

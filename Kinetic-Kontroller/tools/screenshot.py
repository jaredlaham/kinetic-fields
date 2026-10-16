"""Render the UI offscreen with a simulated APC and save PNG screenshots.

    QT_QPA_PLATFORM=offscreen python tools/screenshot.py out_dir
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
out = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
out.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("APC_LIGHT_HOME", str(out / "home"))

from PySide6.QtCore import QTimer  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

import apc_light.app.application as A  # noqa: E402

shots = [("rainbow_wave", None), ("heart", None), ("kinetic_marquee", None), ("custom_pattern", "paint"), (None, "blackout")]


def run(ctl):
    app = QApplication.instance()
    ctl.window.resize(1240, 800)
    ctl.set_output_mode("rgb")

    def step(i=0):
        if i >= len(shots):
            app.quit()
            return
        eid, extra = shots[i]
        if extra == "blackout":
            ctl.blackout()
        else:
            ctl.start_effect(eid)
        if extra == "paint":
            for (x, y) in [(1, 1), (2, 1), (5, 1), (6, 1), (1, 5), (6, 5), (2, 6), (3, 6), (4, 6), (5, 6)]:
                ctl.engine.pad_pressed(x, y)
        if i == 0:
            ctl.window.toggle_diagnostics()
        if i == 1:
            ctl.window.toggle_diagnostics()
        QTimer.singleShot(900, lambda: (ctl.window.grab().save(str(out / f"{i}_{eid or extra}.png")), step(i + 1)))

    step()


_orig_init = A.Controller.__init__


def _init(self, *a, **kw):
    _orig_init(self, *a, **kw)
    QTimer.singleShot(500, lambda: run(self))


A.Controller.__init__ = _init
sys.exit(A.main(["--fake-midi"]))

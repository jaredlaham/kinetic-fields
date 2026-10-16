"""Screenshots of Kinetic Sweep with simulated pad presses (offscreen).

    QT_QPA_PLATFORM=offscreen python tools/screenshot_sweep.py out_dir
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
out = Path(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
out.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("APC_LIGHT_HOME", str(out / "home"))

from PySide6.QtCore import QTimer  # noqa: E402

import apc_light.app.application as A  # noqa: E402
from apc_light.midi.protocol import xy_to_note  # noqa: E402

# (delay ms, action)
def script(ctl):
    b = ctl.device.backend
    return [
        (0, lambda: (ctl.window.resize(1240, 860), ctl.set_output_mode("rgb"), ctl.start_effect("kinetic_sweep"),
                     ctl.pattern_action("kinetic_sweep", "preset:RETRO"))),
        (1500, lambda: ctl.window.grab().save(str(out / "sweep_ambient.png"))),
        (0, lambda: b.press(xy_to_note(2, 3))),
        (160, lambda: b.press(xy_to_note(6, 5))),
        (160, lambda: ctl.window.grab().save(str(out / "sweep_ripples.png"))),
        (0, lambda: (b.release(xy_to_note(2, 3)), ctl.set_param("kinetic_sweep", "reaction", "Horizontal Pulse"))),
        (0, lambda: b.press(xy_to_note(4, 1))),
        (140, lambda: ctl.window.grab().save(str(out / "sweep_hpulse.png"))),
        (0, lambda: (b.release(xy_to_note(4, 1)), b.release(xy_to_note(6, 5)),
                     ctl.pattern_action("kinetic_sweep", "preset:NEON"))),
        (0, lambda: b.press(xy_to_note(5, 4))),
        (220, lambda: ctl.window.grab().save(str(out / "sweep_neon_hold.png"))),
        (0, lambda: (b.release(xy_to_note(5, 4)), ctl.set_hardware_preview(False),
                     ctl.set_output_mode("palette"))),
        (400, lambda: ctl.window.grab().save(str(out / "sweep_palette_ideal.png"))),
        (0, lambda: ctl.set_hardware_preview(True)),
        (300, lambda: ctl.window.grab().save(str(out / "sweep_palette_hardware.png"))),
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
    QTimer.singleShot(600, run)


A.Controller.__init__ = _init
sys.exit(A.main(["--fake-midi"]))

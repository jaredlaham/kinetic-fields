"""App-level tests: run the real Controller/UI offscreen with a simulated APC."""

import json
import subprocess
import sys
import threading
from argparse import Namespace
from pathlib import Path

import pytest

pytest.importorskip("PySide6.QtWidgets")
from PySide6.QtCore import QEvent, Qt  # noqa: E402
from PySide6.QtGui import QKeyEvent  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance() or QApplication([])
    yield app


def make_controller():
    from apc_light.app.application import Controller
    from apc_light.ui.diagnostics import QtLogHandler

    return Controller(Namespace(fake_midi=True, self_test=0, debug=False), QtLogHandler())


def test_settings_persist_across_launches(qapp):
    ctl = make_controller()
    assert ctl.device.connected
    ctl.set_speed(80)
    ctl.set_brightness(50)
    ctl.set_favorites(["heart", "mosaic"])
    ctl.set_param("heart", "color", "#00ff00")
    ctl.set_output_mode("rgb")
    ctl.assign_shortcut("7", "creeper")
    ctl.start_effect("heart")
    ctl.shutdown()
    assert ctl.device.backend.apc.is_dark()  # blackout on quit
    ctl.window.deleteLater()

    ctl2 = make_controller()
    s = ctl2.settings
    assert s["speed"] == 80 and s["brightness"] == 50 and s["output_mode"] == "rgb"
    assert s["favorites"] == ["heart", "mosaic"]
    assert s["last_effect"] == "heart"
    assert ctl2.engine.params_for("heart")["color"] == "#00ff00"
    assert ctl2.shortcuts()["7"] == "creeper"
    assert "4" not in ctl2.shortcuts()  # creeper's default key moved to 7
    # LEDs are NOT turned on at launch unless restore_on_launch is set
    assert ctl2.engine.active_id is None
    assert ctl2.device.backend.apc.lit == 0
    ctl2.shutdown()
    ctl2.window.deleteLater()


def test_restore_on_launch(qapp):
    ctl = make_controller()
    ctl.start_effect("all_on")
    ctl.set_option("restore_on_launch", True)
    ctl.shutdown()
    ctl.window.deleteLater()
    ctl2 = make_controller()
    assert ctl2.engine.active_id == "all_on"
    assert ctl2.device.backend.apc.lit == 64
    ctl2.shutdown()
    ctl2.window.deleteLater()


def test_keyboard_shortcuts_and_hardware_buttons(qapp):
    from apc_light.app.application import ShortcutFilter

    ctl = make_controller()
    ctl.window.show()
    ctl.window.activateWindow()
    f = ShortcutFilter(ctl)
    ev = QKeyEvent(QEvent.KeyPress, Qt.Key_1, Qt.NoModifier, "1")
    assert f.eventFilter(ctl.window, ev) or QApplication.activeWindow() is not ctl.window
    if QApplication.activeWindow() is ctl.window:
        assert ctl.engine.active_id == "kinetic_sweep"
        # modifiers are left to macOS / Qt
        ev = QKeyEvent(QEvent.KeyPress, Qt.Key_2, Qt.ControlModifier, "2")
        assert not f.eventFilter(ctl.window, ev)
    assert ctl.handle_key("3") and ctl.engine.active_id == "mosaic"
    assert ctl.handle_key("0") and ctl.engine.active_id is None

    # APC scene launch button 1 -> first favorite; its green LED lights
    backend = ctl.device.backend
    backend.press(0x70)
    assert ctl.engine.active_id == ctl.favorite_ids()[0]
    assert backend.apc.buttons.get(0x70) == 1
    # Shift + scene button -> blackout
    backend.press(0x7A)
    backend.press(0x71)
    assert ctl.engine.active_id is None and backend.apc.is_dark()
    ctl.shutdown()
    ctl.window.deleteLater()


def test_close_while_animating_leaves_no_threads(qapp):
    ctl = make_controller()
    ctl.engine.set_speed(100)
    ctl.start_effect("rainbow_wave")
    ctl.window.close()  # closeEvent -> shutdown
    assert not ctl.engine.running
    assert not [t for t in threading.enumerate() if t.name == "apc-render" and t.is_alive()]
    assert ctl.device.backend.apc.is_dark()


def test_self_test_subprocess(tmp_path):
    env = {**__import__("os").environ, "QT_QPA_PLATFORM": "offscreen", "APC_LIGHT_HOME": str(tmp_path)}
    r = subprocess.run([sys.executable, str(ROOT / "main.py"), "--fake-midi", "--self-test", "2"],
                       capture_output=True, text=True, timeout=60, env=env, cwd=str(ROOT))
    line = next(l for l in r.stdout.splitlines() if l.startswith("SELF-TEST "))
    report = json.loads(line[len("SELF-TEST "):])
    assert r.returncode == 0, r.stderr[-2000:]
    assert report["ok"] and report["fake_apc_dark_after_quit"] and not report["render_thread_alive"]


def test_kinetic_sweep_in_app(qapp):
    import time as _t

    ctl = make_controller()
    backend = ctl.device.backend
    ctl.start_effect("kinetic_sweep")
    assert ctl.window.view._paint_mode          # on-screen pads are touchable
    assert ctl.window.params.effect_id == "kinetic_sweep"
    # preset -> params + persisted; reset -> defaults
    ctl.pattern_action("kinetic_sweep", "preset:ZEN")
    p = ctl.engine.params_for("kinetic_sweep")
    assert p["sweep_speed"] == 5 and ctl.settings["effect_params"]["kinetic_sweep"]["trails"] == 95
    ctl.pattern_action("kinetic_sweep", "reset")
    assert ctl.engine.params_for("kinetic_sweep")["sweep_speed"] == 40
    # on-screen touch goes through the same input path as hardware
    ctl.screen_pad(2, 2, True)
    deadline = _t.time() + 1
    while not ctl.engine.interaction.is_held(2, 2) and _t.time() < deadline:
        _t.sleep(0.01)
    assert ctl.engine.interaction.is_held(2, 2)
    ctl.screen_pad(2, 2, False)
    # hardware press + unplug -> held pads are released
    backend.press(0)
    _t.sleep(0.05)
    backend.connected = False
    ctl.poll_midi()
    deadline = _t.time() + 1
    while ctl.engine.interaction.held and _t.time() < deadline:
        _t.sleep(0.01)
    assert not ctl.engine.interaction.held
    backend.connected = True
    ctl.poll_midi()
    assert ctl.device.connected
    ctl.set_hardware_preview(False)
    assert ctl.settings["hardware_preview"] is False and ctl.engine.preview_hardware is False
    ctl.shutdown()
    assert backend.input_callback is None and not ctl.engine.running
    assert backend.apc.is_dark()
    ctl.window.deleteLater()

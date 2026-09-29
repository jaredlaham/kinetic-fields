"""Redesigned UI: transport, browser, inspector tools — driven like a user."""

import time
from argparse import Namespace

import pytest

pytest.importorskip("PySide6.QtWidgets")
from PySide6.QtWidgets import QApplication  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def ctl(qapp):
    from apc_light.app.application import Controller
    from apc_light.ui.diagnostics import QtLogHandler

    c = Controller(Namespace(fake_midi=True, self_test=0, debug=False), QtLogHandler())
    yield c
    c.shutdown()
    c.window.deleteLater()


def settle(t=0.08):
    end = time.time() + t
    while time.time() < end:
        QApplication.processEvents()
        time.sleep(0.005)


def test_layout_zones_and_sizes(ctl):
    from apc_light.ui.design import H

    w = ctl.window
    w.resize(1520, 940)
    w.show()
    settle()
    assert w.toolbar.height() == H.TOOLBAR
    assert w.statusbar.height() == H.STATUS
    assert H.BROWSER_MIN <= w.library.width() <= H.BROWSER_MAX
    assert H.INSPECTOR_MIN <= w.inspector.width() <= H.INSPECTOR_MAX
    assert w.inspector.blackout_btn.text() == "BLACKOUT"
    assert "Blackout" == w.inspector.blackout_btn.objectName()   # neutral style, not red


def test_pause_freezes_leds_and_play_resumes(ctl):
    b = ctl.device.backend
    ctl.start_effect("rainbow")
    settle(0.2)
    ctl.set_paused(True)
    assert ctl.window.toolbar.pause.isChecked()
    settle(0.1)
    n = len(b.apc.messages)
    settle(0.3)
    assert len(b.apc.messages) == n          # frozen: no LED traffic
    ctl.play()
    assert not ctl.engine.paused
    settle(0.3)
    assert len(b.apc.messages) > n


def test_prev_next_walk_the_browser(ctl):
    ctl.start_effect("kinetic_sweep")
    ctl.step_effect(1)
    assert ctl.engine.active_id == "rainbow"      # favourites order: sweep, rainbow, ...
    ctl.step_effect(-1)
    assert ctl.engine.active_id == "kinetic_sweep"
    ctl.blackout()
    ctl.play()                                    # play restarts the selected scene
    assert ctl.engine.active_id == "kinetic_sweep"


def test_browser_selection_search_and_favorite(ctl):
    lib = ctl.window.library
    ctl.start_effect("heart")
    assert lib.list._selected == "heart" and lib.list._active == "heart"
    lib.search.setText("rain")
    assert set(lib.list.visible_effects()) <= {"rainbow", "rainbow_wave", "rainbow_diagonal"}
    lib.search.setText("")
    ctl.toggle_favorite("all_on")
    assert "all_on" in ctl.settings["favorites"] and lib.list.is_favorite("all_on")
    ctl.toggle_favorite("all_on")
    assert "all_on" not in ctl.settings["favorites"]


def test_paint_tools_and_pattern_library(ctl, monkeypatch):
    import apc_light.ui.browser as browser

    ins = ctl.window.inspector
    ctl.start_effect("custom_pattern")
    ctl.pattern_action("custom_pattern", "clear")
    ctl.set_param("custom_pattern", "brush", "#00ff00")
    # brush
    ctl.screen_pad(0, 0, True)
    ctl.screen_pad(0, 0, False)
    settle()
    pat = ctl.engine.params_for("custom_pattern")["pattern"]
    assert pat[0] == "#00ff00"
    # bucket fill floods the black area
    ins.set_paint_tool("bucket")
    ctl.set_param("custom_pattern", "brush", "#0000ff")
    ctl.screen_pad(5, 5, True)
    ctl.screen_pad(5, 5, False)
    settle()
    pat = ctl.engine.params_for("custom_pattern")["pattern"]
    assert pat[0] == "#00ff00" and pat.count("#0000ff") == 63
    # eyedropper picks the green back up and returns to the brush
    ins.set_paint_tool("eyedropper")
    ctl.screen_pad(0, 0, True)
    ctl.screen_pad(0, 0, False)
    assert ctl.engine.params_for("custom_pattern")["brush"] == "#00ff00"
    assert ins.paint_tool == "brush"
    # eraser
    ins.set_paint_tool("eraser")
    ctl.screen_pad(3, 3, True)
    ctl.screen_pad(3, 3, False)
    settle()
    assert ctl.engine.params_for("custom_pattern")["pattern"][27] == "#000000"
    # save -> list -> load -> delete
    monkeypatch.setattr(browser, "pattern_name_dialog", lambda parent, default: "Test Grid")
    ctl.save_pattern()
    assert "Test Grid" in ctl.settings["patterns"]
    saved = list(ctl.settings["patterns"]["Test Grid"])
    ctl.pattern_action("custom_pattern", "clear")
    ctl.load_pattern("Test Grid")
    assert ctl.engine.params_for("custom_pattern")["pattern"] == saved
    ctl.delete_pattern("Test Grid")
    assert "Test Grid" not in ctl.settings["patterns"]


def test_notes_ui_state_and_shortcut_editor(ctl):
    ctl.window.library.notes.setPlainText("Drop at 1:32 -> Kinetic Sweep")
    assert ctl.settings["notes"].startswith("Drop at")
    ctl.window.inspector.set_tab("MIDI")
    ctl.window.inspector.tabs.set_current("Colors", emit=True)
    assert ctl.settings["ui_state"]["inspector_tab"] == "Colors"
    ctl.clear_shortcut("6")
    assert "6" not in ctl.shortcuts()
    ctl.assign_shortcut("7", "kinetic_marquee")
    assert ctl.shortcuts()["7"] == "kinetic_marquee"
    assert ctl.window.inspector._shortcut_rows["7"].combo.currentText() == "Kinetic Marquee"


def test_preview_toggles_stay_in_sync(ctl):
    ctl.set_hardware_preview(False)
    assert ctl.window.workbar.view.current() == "icon:sparkle"
    assert not ctl.window.inspector.opt_preview.isChecked()
    ctl.set_hardware_preview(True)
    assert ctl.window.workbar.view.current() == "icon:chip"
    assert ctl.engine.preview_hardware


def test_scene_buttons_and_digit_keys_still_work(ctl):
    b = ctl.device.backend
    b.press(0x70)                 # APC scene button 1
    assert ctl.engine.active_id == "kinetic_sweep"
    assert ctl.handle_key("3") and ctl.engine.active_id == "mosaic"
    assert ctl.handle_key("0") and ctl.engine.active_id is None

"""Application bootstrap and the controller that ties UI, engine and settings."""

from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import signal
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from PySide6.QtCore import QLockFile, QObject, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QPalette
from PySide6.QtWidgets import QApplication, QMessageBox

from .. import APP_NAME, BUNDLE_ID, __version__, audio
from ..engine.frame import Pad
from ..engine.manager import Engine
from ..engine.registry import EffectRegistry
from ..midi.device import MidiDevice
from ..midi.input import ButtonEvent, FaderEvent, MidiInputHub, PadEvent
from ..midi.output import LedOutput
from ..settings import paths
from ..settings.store import Settings

log = logging.getLogger("apc.app")


def clamp01(v: float) -> float:
    return 0.0 if v < 0 else 1.0 if v > 1 else float(v)
ASSETS = Path(__file__).resolve().parents[1] / "assets"


# ----------------------------------------------------------------------------
# logging
# ----------------------------------------------------------------------------
def setup_logging(debug: bool):
    from ..ui.diagnostics import QtLogHandler

    root = logging.getLogger("apc")
    root.setLevel(logging.DEBUG if debug else logging.INFO)
    root.propagate = False
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s [%(threadName)s] %(name)s: %(message)s")
    try:
        fh = logging.handlers.RotatingFileHandler(paths.log_dir() / "kinetic-kontroller.log",
                                                  maxBytes=1_000_000, backupCount=3, encoding="utf-8")
        fh.setFormatter(fmt)
        root.addHandler(fh)
    except OSError as exc:
        print(f"log file unavailable: {exc}", file=sys.stderr)
    if debug or not getattr(sys, "frozen", False):
        sh = logging.StreamHandler(sys.stderr)
        sh.setFormatter(fmt)
        root.addHandler(sh)
    qt_handler = QtLogHandler()
    root.addHandler(qt_handler)
    return qt_handler


class _Bridge(QObject):
    """Marshals engine/MIDI-thread callbacks onto the GUI thread."""

    frame = Signal(object, object, object)
    effect_changed = Signal(object)
    params_changed = Signal(str, object)
    error = Signal(str)
    input_event = Signal(object)


# ----------------------------------------------------------------------------
# controller
# ----------------------------------------------------------------------------
class Controller(QObject):
    def __init__(self, args: argparse.Namespace, log_handler) -> None:
        super().__init__()
        self.args = args
        self.settings = Settings()
        s = self.settings

        self.registry = EffectRegistry().discover(extra_dirs=[paths.user_effects_dir()])
        backend = None
        if args.fake_midi:
            from ..midi.fake import FakeBackend

            backend = FakeBackend()
            log.info("Using simulated APC (--fake-midi)")
        self.device = MidiDevice(backend, preferred=s["midi_port"])
        self.output = LedOutput(self.device, mode=s["output_mode"], brightness=s["brightness"])
        self.engine = Engine(self.registry, self.output)
        self.engine.load_params(s["effect_params"])
        self.engine.set_speed(s["speed"])
        self.engine.preview_hardware = bool(s["hardware_preview"])

        self._bridge = _Bridge()
        self._bridge.frame.connect(self._on_frame)
        self._bridge.effect_changed.connect(self._on_effect_changed)
        self._bridge.params_changed.connect(self._on_params_changed)
        self._bridge.error.connect(self._on_error)
        self._bridge.input_event.connect(self._on_input)
        self.engine.on_frame = self._bridge.frame.emit
        self.engine.on_effect_changed = self._bridge.effect_changed.emit
        self.engine.on_params_changed = self._bridge.params_changed.emit
        self.engine.on_error = self._bridge.error.emit
        # MIDI IN: APC -> hub -> (engine: pad events, render thread)
        #                      -> (GUI: button events, Qt thread)
        self.midi_input = MidiInputHub()
        self.device.input_callback = self.midi_input.feed
        self.midi_input.subscribe(self.engine.post_input)
        self.midi_input.subscribe(
            lambda ev: None if isinstance(ev, PadEvent) else self._bridge.input_event.emit(ev))
        self.device.on_connection_changed = self._on_connection_changed

        self._thumbs: Dict[str, Any] = {}
        self._shown_id: Optional[str] = s["last_effect"] if s["last_effect"] in self.registry else None
        self._shift = False
        self._frame_seq = 0
        self._was_connected = False
        self._port_names: List[str] = []
        self._shut_down = False
        self.errors: List[str] = []

        self._save_timer = QTimer(self)
        self._save_timer.setSingleShot(True)
        self._save_timer.setInterval(400)
        self._save_timer.timeout.connect(self.settings.save)
        self._thumb_timer = QTimer(self)
        self._thumb_timer.setSingleShot(True)
        self._thumb_timer.setInterval(250)
        self._thumb_timer.timeout.connect(self._refresh_shown_thumb)

        from ..ui.main_window import MainWindow

        self.window = MainWindow(self, log_handler)
        self.window.closing.connect(self.shutdown)
        self.library_state()

        # Start
        self.engine.start()
        self.window.set_connection(False, None, self.device.backend.available)
        self.poll_midi()
        self._poll_timer = QTimer(self)
        self._poll_timer.setInterval(1500)
        self._poll_timer.timeout.connect(self.poll_midi)
        self._poll_timer.start()

        self.apply_topo()
        self.window.show_effect(None, self._shown_id)
        if s["restore_on_launch"] and self._shown_id:
            log.info("Restoring last scene: %s", self._shown_id)
            self.start_effect(self._shown_id)

    # -- helpers ---------------------------------------------------------------
    def save_soon(self) -> None:
        self._save_timer.start()

    def thumbnail(self, effect_id: str):
        from ..ui.apc_view import frame_thumbnail

        if effect_id not in self._thumbs:
            self._thumbs[effect_id] = frame_thumbnail(self.engine.render_preview(effect_id).pads)
        return self._thumbs[effect_id]

    def _refresh_shown_thumb(self) -> None:
        if self._shown_id:
            self._thumbs.pop(self._shown_id, None)
            self.window.library.refresh_thumbnail(self._shown_id)

    def shortcuts(self) -> Dict[str, str]:
        """Effective key -> effect id map (defaults + user overrides)."""
        eff: Dict[str, str] = {}
        for cls in self.registry.all():
            if cls.shortcut and cls.shortcut not in eff:
                eff[cls.shortcut] = cls.id
        for k, v in self.settings["shortcuts"].items():
            if v and v in self.registry:
                eff[k] = v
            else:
                eff.pop(k, None)
        eff.pop("0", None)  # 0 is always Blackout
        return eff

    @property
    def shown_id(self) -> Optional[str]:
        return self._shown_id

    def library_state(self) -> None:
        ui = self.settings["ui_state"]
        self.window.library.set_state(self.settings["favorites"], self.shortcuts(), self.engine.active_id,
                                      ui.get("collapsed", []))
        self.window.inspector.set_shortcuts(self.shortcuts())
        self.window.inspector.set_scene_slots(self.scene_slots())
        self.window.library.set_scene_slots(self.scene_slots())

    def favorite_ids(self) -> List[str]:
        return [f for f in self.settings["favorites"] if f in self.registry]

    def scene_slots(self) -> List[str]:
        """Scene for each APC scene button 1-8 (top = 1); "" = unassigned."""
        return [v if v in self.registry else "" for v in self.settings["scene_slots"]]

    def assign_scene_button(self, index: int, effect_id: str) -> None:
        """Put a scene on scene button ``index`` (0-7), or clear it with "".
        A scene sits on one button at a time, and assigning makes it a favourite."""
        if not 0 <= index < 8:
            return
        slots = self.scene_slots()
        if effect_id and effect_id not in self.registry:
            return
        if effect_id:
            slots = ["" if v == effect_id else v for v in slots]
        slots[index] = effect_id
        self.settings["scene_slots"] = slots
        favs = list(self.settings["favorites"])
        if effect_id and effect_id not in favs:
            favs.append(effect_id)
        name = self.registry.get(effect_id).name if effect_id else "(empty)"
        log.info("Scene button %d -> %s", index + 1, name)
        self.set_favorites(favs)          # saves, refreshes LEDs, browser and inspector

    def _update_scene_led(self) -> None:
        active = self.engine.active_id
        slots = self.scene_slots()
        idx = slots.index(active) if (active and active in slots and self.settings["scene_buttons"]) else None
        self.engine.set_scene_led(idx)
        self.window.view.set_scene_led(idx)
        self.window.view.set_scene_names([self.registry.get(v).name if v else "" for v in slots])

    # -- actions (GUI thread) --------------------------------------------------
    def start_effect(self, effect_id: str) -> None:
        if self.engine.paused:
            self.set_paused(False)
        if self.engine.set_effect(effect_id):
            self._shown_id = effect_id
            self.settings["last_effect"] = effect_id
            self.save_soon()

    def blackout(self) -> None:
        if self.engine.paused:
            self.set_paused(False)
        self.engine.blackout()

    # -- transport ---------------------------------------------------------------
    def play(self) -> None:
        """Resume if paused, otherwise (re)start the selected scene."""
        if self.engine.paused:
            self.set_paused(False)
        elif self._shown_id and self.engine.active_id != self._shown_id:
            self.start_effect(self._shown_id)
        elif self.engine.active_id is None and self._shown_id:
            self.start_effect(self._shown_id)

    def set_paused(self, paused: bool) -> None:
        if paused and self.engine.active_id is None:
            paused = False
        self.engine.set_paused(paused)
        log.info("Animation %s", "paused" if paused else "resumed")
        self.window.set_paused(paused)

    def step_effect(self, delta: int) -> None:
        """Previous / next scene in browser order."""
        ids = self.window.library.list.visible_effects() or self.registry.ids()
        seen = []
        for i in ids:  # favourites appear twice in the browser; step through unique scenes
            if i not in seen:
                seen.append(i)
        cur = self._shown_id if self._shown_id in seen else None
        idx = (seen.index(cur) + delta) % len(seen) if cur else (0 if delta > 0 else len(seen) - 1)
        self.start_effect(seen[idx])

    def toggle_favorite(self, effect_id: Optional[str]) -> None:
        if not effect_id:
            return
        favs = list(self.settings["favorites"])
        if effect_id in favs:
            favs.remove(effect_id)
        else:
            favs.append(effect_id)
            slots = self.scene_slots()
            if effect_id not in slots and "" in slots:     # new favourites fill a free scene button
                slots[slots.index("")] = effect_id
                self.settings["scene_slots"] = slots
        self.set_favorites(favs)

    # -- patterns library / notes / UI state ------------------------------------
    def save_pattern(self) -> None:
        from ..ui.browser import pattern_name_dialog

        params = self.engine.params_for("custom_pattern")
        pattern = params.get("pattern")
        if not pattern:
            return
        n = len(self.settings["patterns"]) + 1
        name = pattern_name_dialog(self.window, f"Pattern {n}")
        if not name:
            return
        self.settings["patterns"] = {**self.settings["patterns"], name: list(pattern)}
        self.save_soon()
        self.window.library.patterns.set_patterns(self.settings["patterns"])
        self.window.library.set_tab("Patterns")
        log.info("Saved pattern: %s", name)

    def load_pattern(self, name: str) -> None:
        pattern = self.settings["patterns"].get(name)
        if not pattern:
            return
        self.engine.set_params("custom_pattern", {"pattern": pattern})
        self._store_params("custom_pattern")
        self.start_effect("custom_pattern")
        self.window.refresh_params()
        log.info("Loaded pattern: %s", name)

    def delete_pattern(self, name: str) -> None:
        pats = dict(self.settings["patterns"])
        if pats.pop(name, None) is not None:
            self.settings["patterns"] = pats
            self.save_soon()
            self.window.library.patterns.set_patterns(pats)

    def set_notes(self, text: str) -> None:
        self.settings["notes"] = text
        self.save_soon()

    def set_ui_state(self, key: str, value) -> None:
        self.settings["ui_state"] = {**self.settings["ui_state"], key: value}
        self.save_soon()

    def add_effect(self) -> None:
        """Create a new effect file from the template in the user effects folder."""

        src = Path(__file__).resolve().parents[1] / "effects" / "_template.py"
        folder = paths.user_effects_dir()
        n = 1
        while (folder / f"my_effect_{n}.py").exists():
            n += 1
        dest = folder / f"my_effect_{n}.py"
        try:
            text = src.read_text("utf-8") if src.exists() else ""
            dest.write_text(text.replace('name = "My Effect"', f'name = "My Effect {n}"'), "utf-8")
        except OSError as exc:
            log.error("Could not create %s: %s", dest, exc)
            return
        log.info("Created %s — edit it, then restart Kinetic Kontroller to load it", dest)
        QMessageBox.information(self.window, "Add Effect",
                                f"Created {dest.name} in your effects folder.\n\n"
                                "Edit it in any text editor, then restart Kinetic Kontroller to load it.")
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))

    # -- workspace topo background ------------------------------------------------
    def topo_path(self) -> str:
        """Custom SVG if set and present, else the downloaded pattern bundled at
        build time (assets/topo_custom.svg), else the built-in fallback."""
        custom = self.settings["topo_svg"]
        if custom and Path(custom).is_file():
            return custom
        for name in ("topo_custom.svg", "topo.svg"):
            p = ASSETS / name
            if p.is_file():
                return str(p)
        return ""

    def apply_topo(self) -> None:
        path = self.topo_path()
        ok = self.window.view.set_background(path or None, self.settings["topo_opacity"] / 100.0)
        if not ok:
            log.warning("Topo SVG could not be loaded: %s", path)
        label = "Custom: " + Path(path).name if self.settings["topo_svg"] and path == self.settings["topo_svg"] \
            else ("Default pattern" if path else "No pattern available")
        self.window.inspector.topo_source.setText(label if ok else f"Could not load {Path(path).name}")

    def set_topo_opacity(self, percent: int) -> None:
        self.settings["topo_opacity"] = int(percent)
        self.save_soon()
        self.window.view.set_background(self.topo_path() or None, percent / 100.0)

    def set_topo_svg(self, path: str) -> None:
        if path:
            # keep a private copy so moving/deleting the original doesn't break it
            import shutil

            dest = paths.support_dir() / "topo.svg"
            try:
                shutil.copyfile(path, dest)
                path = str(dest)
            except OSError as exc:
                log.warning("Could not copy topo SVG (%s); using it in place", exc)
        self.settings["topo_svg"] = path
        self.save_soon()
        self.window.view._topo_path = object()  # force a reload even if the path is unchanged
        self.apply_topo()
        log.info("Topo pattern: %s", path or "default")

    def choose_topo(self) -> None:
        from PySide6.QtWidgets import QFileDialog

        path, _ = QFileDialog.getOpenFileName(self.window, "Choose Topo Pattern", str(Path.home()),
                                              "SVG images (*.svg)")
        if path:
            self.set_topo_svg(path)

    def set_speed(self, value: int) -> None:
        self.engine.set_speed(value)
        self.settings["speed"] = int(value)
        self.save_soon()

    def set_brightness(self, percent: int) -> None:
        self.engine.set_brightness(percent)
        self.settings["brightness"] = int(percent)
        self.save_soon()

    def set_output_mode(self, mode: str) -> None:
        log.info("LED output mode: %s", mode)
        self.engine.set_output_mode(mode)
        self.window.set_output_mode(mode)
        self.settings["output_mode"] = mode
        self.save_soon()

    def set_param(self, effect_id: str, key: str, value: Any) -> None:
        self.engine.set_param(effect_id, key, value)
        self._store_params(effect_id)

    def _store_params(self, effect_id: str) -> None:
        self.settings["effect_params"][effect_id] = self.engine.params_for(effect_id)
        self.save_soon()
        self._thumb_timer.start()

    def pattern_action(self, effect_id: str, action: str) -> None:
        """Buttons in the settings panel: presets, reset, pattern tools."""
        cls = self.registry.get(effect_id)
        if cls is None:
            return
        if action.startswith("preset:"):
            name = action.split(":", 1)[1]
            if name in cls.presets:
                log.info("%s preset: %s", cls.name, name)
                self.engine.set_params(effect_id, cls.presets[name])
        elif action == "reset":
            log.info("%s: reset to defaults", cls.name)
            keep = {k: v for k, v in self.engine.params_for(effect_id).items() if k in ("pattern", "steps")}
            self.engine.set_params(effect_id, {**cls.default_params(), **keep})
        elif action in ("clear", "fill"):
            params = self.engine.params_for(effect_id)
            fill = params.get("brush", "#ffffff") if action == "fill" else "#000000"
            self.engine.set_params(effect_id, {"pattern": [fill] * 64})
        else:
            return
        self._store_params(effect_id)
        self.window.refresh_params()

    def screen_fader(self, index: int, value: float) -> None:
        """An on-screen fader was dragged (0..1): behaves like the hardware fader."""
        self.engine.post_input(FaderEvent(index, int(round(clamp01(value) * 127))))

    def screen_pad(self, x: int, y: int, pressed: bool, button: str = "left") -> None:
        """A pad clicked on the on-screen APC: treated like a hardware press.
        With a paintable effect the inspector's paint tool decides what it does."""
        cls = self.registry.get(self.engine.active_id) if self.engine.active_id else None
        if cls is not None and any(p.key == "pattern" for p in cls.params) and button != "right":
            tool = self.window.inspector.paint_tool
            if tool == "eyedropper":
                if pressed:
                    color = self.engine.params_for(cls.id)["pattern"][y * 8 + x]
                    if color != "#000000":
                        self.set_param(cls.id, "brush", color)
                        self.window.inspector.set_brush(color)
                    self.window.inspector.set_paint_tool("brush")
                return
            button = {"eraser": "right", "bucket": "fill"}.get(tool, "left")
        self.engine.post_input(PadEvent(x, y, pressed, 100 if pressed else 0, source="screen", button=button))

    def set_hardware_preview(self, enabled: bool) -> None:
        if bool(enabled) == self.engine.preview_hardware and self.settings["hardware_preview"] == bool(enabled):
            self.window.set_preview(bool(enabled))
            return
        self.engine.set_preview_hardware(enabled)
        self.set_option("hardware_preview", bool(enabled))
        self.window.set_preview(bool(enabled))

    def set_option(self, key: str, value: Any) -> None:
        self.settings[key] = value
        self.save_soon()
        if key == "scene_buttons":
            self._update_scene_led()

    def set_favorites(self, favorites: List[str]) -> None:
        self.settings["favorites"] = favorites
        # a scene that is no longer a favourite leaves its scene button
        self.settings["scene_slots"] = [v if v in favorites else "" for v in self.scene_slots()]
        self.save_soon()
        self._update_scene_led()
        self.library_state()
        self.window.show_effect(self.engine.active_id, self._shown_id)

    def clear_shortcut(self, key: str) -> None:
        overrides = dict(self.settings["shortcuts"])
        overrides[key] = ""
        self.settings["shortcuts"] = overrides
        self.save_soon()
        self.library_state()

    def assign_shortcut(self, key: str, effect_id: str) -> None:
        overrides = dict(self.settings["shortcuts"])
        for k, v in self.shortcuts().items():
            if v == effect_id and k != key:
                overrides[k] = ""
        if key:
            overrides[key] = effect_id
        self.settings["shortcuts"] = overrides
        self.save_soon()
        self.library_state()
        log.info("Shortcut %s -> %s", key or "(none)", effect_id)

    def trigger_scene_button(self, index: int) -> None:
        """APC scene button or its on-screen twin: start the scene assigned to it."""
        slots = self.scene_slots()
        if 0 <= index < 8 and slots[index]:
            self.start_effect(slots[index])

    def handle_key(self, text: str) -> bool:
        if text == "0":
            self.blackout()
            return True
        eid = self.shortcuts().get(text)
        if eid:
            self.start_effect(eid)
            return True
        return False

    # -- MIDI --------------------------------------------------------------------
    def poll_midi(self) -> None:
        names = self.device.output_names()
        if names != self._port_names:
            self._port_names = names
            self.window.set_ports(names, self.settings["midi_port"])
            log.debug("MIDI outputs: %s", names)
        self.device.poll()

    def refresh_midi(self) -> None:
        log.info("Refresh MIDI")
        self._port_names = []
        self.device.reconnect()
        self.poll_midi()
        if not self.device.connected:
            log.info("No APC mini mk2 found. Outputs: %s", ", ".join(self._port_names) or "(none)")

    def set_midi_port(self, name: str) -> None:
        log.info("MIDI port selection: %s", name or "auto")
        self.settings["midi_port"] = name
        self.device.preferred = name
        self.save_soon()
        self.refresh_midi()

    def _on_connection_changed(self, connected: bool, port: Optional[str]) -> None:
        # Called from poll() on the GUI thread.
        if connected:
            if self._was_connected:
                log.info("APC reconnected")
            self._was_connected = True
            self.engine.resync()
            self._update_scene_led()
        else:
            log.info("APC disconnected")
            self._shift = False
            self.engine.release_all()  # no pad stays "held" after an unplug
        self.window.set_connection(connected, port, self.device.backend.available)

    def _on_input(self, ev) -> None:
        """Non-pad input (GUI thread). Pads go straight to the engine."""
        if isinstance(ev, FaderEvent):
            self.window.view.set_fader(ev.index, ev.value / 127.0)
            return
        if not isinstance(ev, ButtonEvent):
            return
        if ev.kind == "shift":
            self._shift = ev.pressed
            return
        if not ev.pressed or ev.kind != "scene":
            return
        if self._shift:
            self.blackout()
        elif self.settings["scene_buttons"]:
            self.trigger_scene_button(ev.index)

    # -- engine signals (GUI thread) --------------------------------------------
    def _on_frame(self, seq: int, pads: List[Pad], scene=None) -> None:
        if seq <= self._frame_seq:
            return  # stale frame from before a switch
        self._frame_seq = seq
        self.window.view.set_pads(pads)
        if scene is not None:
            self.window.view.set_scene_leds(scene)

    def _on_effect_changed(self, effect_id: Optional[str]) -> None:
        if effect_id:
            self._shown_id = effect_id
        self.window.show_effect(effect_id, self._shown_id)
        self._update_scene_led()

    def _on_params_changed(self, effect_id: str, _params) -> None:
        self._store_params(effect_id)

    def _on_error(self, message: str) -> None:
        self.errors.append(message)
        if not self.args.self_test:
            QMessageBox.warning(self.window, "Scene error", message)

    # -- folders -----------------------------------------------------------------
    def open_settings_folder(self) -> None:
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(paths.support_dir())))

    def open_effects_folder(self) -> None:
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(paths.user_effects_dir())))

    def open_log_folder(self) -> None:
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(paths.log_dir())))

    # -- shutdown ----------------------------------------------------------------
    def shutdown(self) -> None:
        if self._shut_down:
            return
        self._shut_down = True
        log.info("Shutting down")
        self._poll_timer.stop()
        self._save_timer.stop()
        self.settings.save()
        self.engine.shutdown(blackout=bool(self.settings["blackout_on_quit"]))
        self.device.close()          # closes MIDI in + out; no more callbacks
        self.midi_input.clear()
        audio.shutdown_all()         # mic / synth / virtual MIDI, if any effect opened them
        log.info("Shutdown complete")


# ----------------------------------------------------------------------------
# keyboard shortcuts
# ----------------------------------------------------------------------------
class ShortcutFilter(QObject):
    """Plain digit keys trigger scenes, but only when the main window is active
    and focus is not in a text field. Anything with a modifier (⌘, ⌥, ⌃) is
    left alone so normal macOS shortcuts keep working."""

    def __init__(self, ctl: Controller) -> None:
        super().__init__()
        self.ctl = ctl

    def eventFilter(self, obj, event) -> bool:
        from PySide6.QtCore import QEvent, Qt
        from PySide6.QtWidgets import QAbstractSpinBox, QComboBox, QLineEdit, QPlainTextEdit, QTextEdit

        if event.type() != QEvent.KeyPress or event.isAutoRepeat():
            return False
        mods = event.modifiers() & ~Qt.KeypadModifier
        if mods != Qt.NoModifier:
            return False
        win = self.ctl.window
        if QApplication.activeWindow() is not win:
            return False
        focus = QApplication.focusWidget()
        if isinstance(focus, (QLineEdit, QTextEdit, QPlainTextEdit, QAbstractSpinBox)) or \
                (isinstance(focus, QComboBox) and focus.view().isVisible()):
            return False
        text = event.text()
        if len(text) == 1 and text.isdigit():
            return self.ctl.handle_key(text)
        return False


# ----------------------------------------------------------------------------
# self test (used by build_app.sh and CI to prove the bundle runs)
# ----------------------------------------------------------------------------
def run_self_test(app: QApplication, ctl: Controller, seconds: float) -> None:
    ids = ctl.registry.ids()
    report: Dict[str, Any] = {"version": __version__, "effects": ids, "midi_available": ctl.device.backend.available,
                              "outputs": ctl.device.output_names(), "connected": ctl.device.connected}
    from ..midi.device import RtMidiBackend

    real = RtMidiBackend() if ctl.args.fake_midi else ctl.device.backend
    report["rtmidi_available"] = real.available
    report["rtmidi_outputs"] = real.output_names() if real.available else []
    steps: List = []
    for i in range(3):
        for eid in ids:
            steps.append(lambda e=eid: ctl.start_effect(e))
    steps += [lambda: ctl.set_speed(100), lambda: ctl.start_effect("rainbow_wave"), lambda: ctl.set_brightness(25),
              lambda: ctl.set_output_mode("rgb"), lambda: ctl.start_effect("mosaic"),
              lambda m=ctl.settings["output_mode"]: ctl.set_output_mode(m), lambda: ctl.blackout(),
              lambda: ctl.start_effect("kinetic_sweep")]
    # Pad presses through the real MIDI-in path (hub -> engine), overlapping.
    for i, note in enumerate((27, 36, 0, 63, 7, 56, 20, 43)):
        steps.append(lambda n=note: ctl.midi_input.feed([0x90, n, 110]))
        if i % 2:
            steps.append(lambda n=note: ctl.midi_input.feed([0x80, n, 0]))
    steps += [lambda: ctl.pattern_action("kinetic_sweep", "preset:PERFORMANCE"),
              lambda: ctl.midi_input.feed([0x90, 28, 127]),
              lambda: ctl.start_effect("kinetic_marquee")]  # left running: quit must clean it up
    started = time.monotonic()
    delay = max(10, int(seconds * 1000 * 0.7 / max(1, len(steps))))

    def tick() -> None:
        if steps:
            steps.pop(0)()
            QTimer.singleShot(delay, tick)
        else:
            elapsed = time.monotonic() - started
            report["frames_rendered"] = ctl.engine.frames_rendered
            report["active_before_quit"] = ctl.engine.active_id
            report["errors"] = ctl.errors
            report["midi_in_events"] = ctl.midi_input.events_received
            report["max_touch_latency_ms"] = round(ctl.engine.max_input_latency_ms, 2)
            report["held_after_switch"] = len(ctl.engine.interaction.held)
            report["elapsed"] = round(elapsed, 2)
            QTimer.singleShot(300, app.quit)
            app.aboutToQuit.connect(lambda: _finish_report(ctl, report))

    QTimer.singleShot(300, tick)


def _finish_report(ctl: Controller, report: Dict[str, Any]) -> None:
    ctl.shutdown()
    import threading

    report["render_thread_alive"] = ctl.engine.running
    report["threads_after_shutdown"] = sorted(t.name for t in threading.enumerate() if t.name == "apc-render")
    fake = getattr(ctl.device.backend, "apc", None)
    if fake is not None:
        report["fake_apc_dark_after_quit"] = fake.is_dark()
        report["fake_apc_messages"] = len(fake.messages)
    ok = not report["errors"] and not report["render_thread_alive"] and len(report["effects"]) >= 10
    if sys.platform == "darwin":
        ok = ok and report["rtmidi_available"]  # CoreMIDI must work in the bundle
    if fake is not None:
        ok = ok and report["fake_apc_dark_after_quit"]
    report["ok"] = ok
    print("SELF-TEST " + json.dumps(report), flush=True)
    log.info("Self-test %s", "PASSED" if ok else "FAILED")
    _exit_code[0] = 0 if ok else 1


_exit_code = [0]


# ----------------------------------------------------------------------------
# entry point
# ----------------------------------------------------------------------------
def _dark_palette() -> QPalette:
    from ..ui.design import C

    pal = QPalette()
    for role, color in (
        (QPalette.Window, C.WORKSPACE), (QPalette.WindowText, C.TEXT), (QPalette.Base, C.FIELD),
        (QPalette.AlternateBase, C.INSPECTOR), (QPalette.Text, C.TEXT), (QPalette.Button, C.CONTROL),
        (QPalette.ButtonText, C.TEXT), (QPalette.Highlight, C.SELECT), (QPalette.HighlightedText, "#FFFFFF"),
        (QPalette.ToolTipBase, C.CONTROL), (QPalette.ToolTipText, C.TEXT), (QPalette.PlaceholderText, C.TEXT_3),
        (QPalette.Link, C.FOCUS),
    ):
        pal.setColor(role, QColor(color))
    return pal


def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="kinetic-kontroller", description=APP_NAME)
    p.add_argument("--debug", action="store_true", help="verbose logging to the terminal")
    p.add_argument("--fake-midi", action="store_true", help="simulate an APC mini mk2 (no hardware needed)")
    p.add_argument("--self-test", type=float, metavar="SECONDS", default=0,
                   help="cycle through every effect, quit and print a report (exit code 0 = pass)")
    # macOS may pass -psn_… when launched from Finder on old systems; ignore unknowns.
    args, _unknown = p.parse_known_args(argv)
    return args


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        # Separate settings so a test run never touches the user's settings,
        # and never trigger the microphone permission prompt.
        os.environ.setdefault("KK_NO_MIC", "1")
        os.environ.setdefault("APC_LIGHT_HOME", str(paths.support_dir() / "self-test"))
    QApplication.setApplicationName(APP_NAME)
    QApplication.setOrganizationName("Jared Laham")
    QApplication.setOrganizationDomain(BUNDLE_ID)
    QApplication.setApplicationVersion(__version__)
    app = QApplication(sys.argv[:1])
    app.setStyle("Fusion")
    icon_path = ASSETS / "AppIcon-256.png"
    if icon_path.exists():
        app.setWindowIcon(QIcon(str(icon_path)))  # Dock icon when run from source
    app.setPalette(_dark_palette())
    from ..ui import theme

    app.setStyleSheet(theme.STYLESHEET)

    log_handler = setup_logging(args.debug)
    log.info("%s %s starting (Python %s, %s)", APP_NAME, __version__, sys.version.split()[0], sys.platform)

    lock = QLockFile(str(paths.support_dir() / "instance.lock"))
    lock.setStaleLockTime(0)
    if not lock.tryLock(100):
        log.warning("Another instance is already running")
        if not args.self_test:
            QMessageBox.information(None, APP_NAME, "Kinetic Kontroller is already running.")
        return 1

    ctl = Controller(args, log_handler)
    app.installEventFilter(sf := ShortcutFilter(ctl))
    app.aboutToQuit.connect(ctl.shutdown)

    # Ctrl-C / kill in development: quit cleanly (and blackout).
    def _sig(*_):
        log.info("Signal received, quitting")
        app.quit()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)
    heartbeat = QTimer()  # lets Python run signal handlers while Qt's loop runs
    heartbeat.start(250)
    heartbeat.timeout.connect(lambda: None)

    ctl.window.show()
    if args.self_test:
        run_self_test(app, ctl, args.self_test)
    rc = app.exec()
    ctl.shutdown()
    lock.unlock()
    del sf
    return _exit_code[0] if args.self_test else rc

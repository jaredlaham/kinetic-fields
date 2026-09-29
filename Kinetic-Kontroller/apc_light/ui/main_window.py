"""Main window: toolbar / browser · workspace · inspector / status bar."""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QByteArray, QPoint, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import QMainWindow, QMenu, QSplitter, QVBoxLayout, QWidget

from .. import __version__
from .apc_view import ApcView
from .browser import BrowserPanel
from .chrome import GlobalToolbar, StatusBar, WorkspaceBar
from .design import C, H
from .inspector import Inspector


class MainWindow(QMainWindow):
    closing = Signal()

    def __init__(self, ctl, log_handler) -> None:
        super().__init__()
        self.ctl = ctl
        s = ctl.settings
        self.setWindowTitle("Kinetic Kontroller")
        self.setMinimumSize(1180, 740)
        self.resize(1520, 940)

        root = QWidget()
        rl = QVBoxLayout(root)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.setSpacing(0)
        self.setCentralWidget(root)

        self.toolbar = GlobalToolbar()
        rl.addWidget(self.toolbar)

        split = QSplitter(Qt.Horizontal)
        split.setHandleWidth(1)
        split.setChildrenCollapsible(False)

        self.library = BrowserPanel(ctl.registry.all(), ctl.thumbnail)
        self.library.setMinimumWidth(H.BROWSER_MIN)
        self.library.setMaximumWidth(H.BROWSER_MAX)
        split.addWidget(self.library)

        work = QWidget()
        work.setObjectName("Workspace")
        work.setAttribute(Qt.WA_StyledBackground, True)
        wl = QVBoxLayout(work)
        wl.setContentsMargins(0, 0, 0, 0)
        wl.setSpacing(0)
        self.workbar = WorkspaceBar(bool(s["hardware_preview"]))
        wl.addWidget(self.workbar)
        self.view = ApcView()
        wl.addWidget(self.view, 1)
        split.addWidget(work)

        self.inspector = Inspector(s, ctl.registry.all(), log_handler)
        self.inspector.setMinimumWidth(H.INSPECTOR_MIN)
        self.inspector.setMaximumWidth(H.INSPECTOR_MAX)
        split.addWidget(self.inspector)
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 1)
        split.setStretchFactor(2, 0)
        split.setSizes([H.BROWSER, 1520 - H.BROWSER - H.INSPECTOR, H.INSPECTOR])
        rl.addWidget(split, 1)

        self.statusbar = StatusBar()
        rl.addWidget(self.statusbar)

        ui = s.get("ui_state", {})
        self.library.set_tab(ui.get("browser_tab", "Effects"))
        self.library.set_notes(s.get("notes", ""))
        self.library.patterns.set_patterns(s.get("patterns", {}))

        self._build_menus()
        self._wire()

        geo = s.get("window_geometry")
        if isinstance(geo, str):
            try:
                self.restoreGeometry(QByteArray.fromBase64(geo.encode()))
            except Exception:
                pass

        self._last_frames = 0
        self._last_out = 0
        self._last_in = 0
        self._stats_timer = QTimer(self)
        self._stats_timer.setInterval(1000)
        self._stats_timer.timeout.connect(self._update_stats)
        self._stats_timer.start()
        self._meter_timer = QTimer(self)
        self._meter_timer.setInterval(50)
        self._meter_timer.timeout.connect(self._update_meters)
        self._meter_timer.start()

    # compatibility aliases used by the controller/tests
    @property
    def params(self) -> Inspector:
        return self.inspector

    # ------------------------------------------------------------------ menus
    def _build_menus(self) -> None:
        mb = self.menuBar()
        m = mb.addMenu("Controls")
        for text, key, fn in (("Blackout", "Ctrl+B", self.ctl.blackout), ("Refresh MIDI", "Ctrl+R", self.ctl.refresh_midi),
                              ("Play / Resume", "Ctrl+Return", self.ctl.play),
                              ("Pause Animation", "Ctrl+.", lambda: self.ctl.set_paused(not self.ctl.engine.paused)),
                              ("Previous Scene", "Ctrl+Left", lambda: self.ctl.step_effect(-1)),
                              ("Next Scene", "Ctrl+Right", lambda: self.ctl.step_effect(1))):
            a = QAction(text, self)
            a.setShortcut(QKeySequence(key))
            a.triggered.connect(fn)
            m.addAction(a)
        m.addSeparator()
        a = QAction("Show Diagnostics", self)
        a.setShortcut(QKeySequence("Ctrl+Shift+D"))
        a.triggered.connect(self.toggle_diagnostics)
        m.addAction(a)
        f = mb.addMenu("Folders")
        self._folder_actions(f)

    def _folder_actions(self, menu: QMenu) -> None:
        menu.addAction("Open Settings Folder").triggered.connect(self.ctl.open_settings_folder)
        menu.addAction("Open User Effects Folder").triggered.connect(self.ctl.open_effects_folder)
        menu.addAction("Open Log Folder").triggered.connect(self.ctl.open_log_folder)

    def _popup(self, anchor, build) -> None:
        menu = QMenu(self)
        build(menu)
        menu.exec(anchor.mapToGlobal(QPoint(0, anchor.height() + 2)))

    def _settings_menu(self, menu: QMenu) -> None:
        menu.addAction("Refresh MIDI").triggered.connect(self.ctl.refresh_midi)
        menu.addAction("MIDI & Diagnostics…").triggered.connect(self.toggle_diagnostics)
        menu.addSeparator()
        self._folder_actions(menu)
        menu.addSeparator()
        a = menu.addAction(f"Kinetic Kontroller {__version__}")
        a.setEnabled(False)

    def _scene_menu(self, menu: QMenu) -> None:
        eid = self.ctl.shown_id
        cls = self.ctl.registry.get(eid) if eid else None
        if cls is None:
            menu.addAction("No scene selected").setEnabled(False)
            return
        menu.addAction(f"Restart {cls.name}").triggered.connect(lambda: self.ctl.start_effect(eid))
        fav = eid in self.ctl.settings["favorites"]
        menu.addAction("Remove from Favorites" if fav else "Add to Favorites").triggered.connect(
            lambda: self.ctl.toggle_favorite(eid))
        sub = menu.addMenu("Keyboard Shortcut")
        for key in "123456789":
            sub.addAction(key).triggered.connect(lambda _=False, k=key: self.ctl.assign_shortcut(k, eid))
        sub.addSeparator()
        sub.addAction("None").triggered.connect(lambda: self.ctl.assign_shortcut("", eid))
        if cls.presets:
            menu.addAction("Reset Settings to Defaults").triggered.connect(lambda: self.ctl.pattern_action(eid, "reset"))
        menu.addSeparator()
        menu.addAction("Add Effect…").triggered.connect(self.ctl.add_effect)

    # ------------------------------------------------------------------ wiring
    def _wire(self) -> None:
        c = self.ctl
        tb, wb, ins, lib = self.toolbar, self.workbar, self.inspector, self.library
        tb.prev_clicked.connect(lambda: c.step_effect(-1))
        tb.next_clicked.connect(lambda: c.step_effect(1))
        tb.play_clicked.connect(c.play)
        tb.pause_clicked.connect(lambda: c.set_paused(tb.pause.isChecked()))
        tb.stop_clicked.connect(c.blackout)
        tb.refresh_clicked.connect(c.refresh_midi)
        tb.settings_clicked.connect(lambda b: self._popup(b, self._settings_menu))
        wb.view_changed.connect(c.set_hardware_preview)
        wb.save_pattern.connect(c.save_pattern)
        wb.favorite_clicked.connect(lambda: c.toggle_favorite(c.shown_id) if c.shown_id else None)
        wb.more_clicked.connect(lambda b: self._popup(b, self._scene_menu))
        wb.play_clicked.connect(lambda: c.start_effect(c.shown_id) if c.shown_id else c.play())
        wb.stop_clicked.connect(c.blackout)
        lib.effect_clicked.connect(c.start_effect)
        lib.favorites_changed.connect(c.set_favorites)
        lib.shortcut_assigned.connect(c.assign_shortcut)
        lib.add_effect.connect(c.add_effect)
        lib.save_pattern.connect(c.save_pattern)
        lib.load_pattern.connect(c.load_pattern)
        lib.delete_pattern.connect(c.delete_pattern)
        lib.notes_changed.connect(c.set_notes)
        lib.ui_changed.connect(c.set_ui_state)
        self.view.pad_pressed.connect(lambda x, y, b: c.screen_pad(x, y, True, b))
        self.view.pad_released.connect(lambda x, y: c.screen_pad(x, y, False))
        ins.param_changed.connect(c.set_param)
        ins.action.connect(c.pattern_action)
        ins.speed_changed.connect(c.set_speed)
        ins.brightness_changed.connect(c.set_brightness)
        ins.output_mode_changed.connect(c.set_output_mode)
        ins.option_changed.connect(c.set_option)
        ins.preview_changed.connect(c.set_hardware_preview)
        ins.port_chosen.connect(c.set_midi_port)
        ins.refresh_midi.connect(c.refresh_midi)
        ins.shortcut_assigned.connect(c.assign_shortcut)
        ins.shortcut_cleared.connect(c.clear_shortcut)
        ins.blackout.connect(c.blackout)
        ins.ui_changed.connect(c.set_ui_state)
        ins.open_logs.connect(c.open_log_folder)
        ins.topo_opacity_changed.connect(c.set_topo_opacity)
        ins.choose_topo.connect(c.choose_topo)
        ins.reset_topo.connect(lambda: c.set_topo_svg(""))
        self.statusbar.menu_clicked.connect(lambda b: self._popup(b, self._settings_menu))

    # ------------------------------------------------------------------ updates from the controller
    def set_ports(self, names, preferred: str) -> None:
        self.inspector.set_ports(names, preferred)

    def set_connection(self, connected: bool, port: Optional[str], midi_ok: bool = True) -> None:
        self.toolbar.set_connection(connected, midi_ok)
        self.view.set_connected(connected)
        if connected:
            self.statusbar.set_status("Ready", C.GOOD)
            self.inspector.set_port_status(f"Connected: {port}")
        elif not midi_ok:
            self.statusbar.set_status("MIDI unavailable", C.BAD)
            self.inspector.set_port_status("MIDI system unavailable")
        else:
            self.statusbar.set_status("APC not connected — plug it in to resume", C.TEXT_3)
            self.inspector.set_port_status("Waiting for the APC mini mk2…")

    def set_output_mode(self, mode: str) -> None:
        self.inspector.set_output_mode(mode)

    def set_preview(self, hardware: bool) -> None:
        self.workbar.view.set_current("icon:chip" if hardware else "icon:sparkle")
        self.inspector.opt_preview.setChecked(hardware)

    def set_paused(self, paused: bool) -> None:
        self.toolbar.pause.setChecked(paused)
        self._update_scene_header()

    def show_effect(self, effect_id: Optional[str], shown_id: Optional[str]) -> None:
        """``effect_id`` = running effect (None after blackout); ``shown_id`` =
        effect whose settings the inspector shows (the selected row)."""
        reg = self.ctl.registry
        cls = reg.get(effect_id) if effect_id else None
        shown = reg.get(shown_id) if shown_id else None
        self.library.set_selection(shown_id, effect_id)
        if shown is None or self.inspector.effect_id != shown.id:
            self.inspector.show_effect(shown, self.ctl.engine.params_for(shown.id) if shown else {})
        self.view.set_touch_mode(bool(cls and cls.accepts_touch))
        self._update_scene_header()

    def _update_scene_header(self) -> None:
        c = self.ctl
        shown = c.registry.get(c.shown_id) if c.shown_id else None
        running = c.engine.active_id
        if shown is None:
            self.workbar.set_scene("No scene", "Blackout", False, False)
            return
        if running == shown.id:
            state = "Paused" if c.engine.paused else ("Animated" if shown().is_animated(
                c.engine.params_for(shown.id)) else "Static")
        else:
            state = "Stopped"
        self.workbar.set_scene(shown.name, state, shown.id in c.settings["favorites"],
                               any(p.key == "pattern" for p in shown.params))

    def refresh_params(self) -> None:
        eid = self.inspector.effect_id
        cls = self.ctl.registry.get(eid) if eid else None
        self.inspector.show_effect(cls, self.ctl.engine.params_for(eid) if cls else {})
        self._update_scene_header()

    def toggle_diagnostics(self) -> None:
        self.inspector.set_tab("MIDI")

    # ------------------------------------------------------------------ telemetry
    def _update_meters(self) -> None:
        dev, hub = self.ctl.device, self.ctl.midi_input
        out, inn = dev.messages_sent, hub.events_received
        d_out, d_in = out - self._last_out, inn - self._last_in
        self._last_out, self._last_in = out, inn
        if d_out:
            self.toolbar.meter_out.hit(min(1.0, 0.35 + d_out / 40.0))
        if d_in:
            self.toolbar.meter_in.hit(min(1.0, 0.55 + d_in / 6.0))

    def _update_stats(self) -> None:
        e, dev, hub = self.ctl.engine, self.ctl.device, self.ctl.midi_input
        fps = e.frames_rendered - self._last_frames
        self._last_frames = e.frames_rendered
        mode = "RGB" if self.ctl.output.mode == "rgb" else "Palette"
        self.statusbar.telemetry.setText(
            f"{fps} fps  •  {dev.messages_sent:,} MIDI msgs  •  {mode}  •  {self.ctl.output.brightness}%  •  v{__version__}")
        lat = e.last_input_latency_ms
        self.inspector.set_stats({
            "out": f"{dev.messages_sent:,} messages",
            "in": f"{hub.events_received:,} events",
            "lat": f"{lat:.1f} ms (max {e.max_input_latency_ms:.1f})" if lat is not None else "—",
            "held": str(len(e.interaction.held)),
            "vel": "velocity-sensitive" if hub.velocity_sensitive else "fixed (127)",
            "thread": ("paused" if e.paused else "running") if e.running else "stopped",
        })

    def closeEvent(self, e) -> None:
        self.ctl.settings["window_geometry"] = bytes(self.saveGeometry().toBase64()).decode()
        self.closing.emit()
        super().closeEvent(e)

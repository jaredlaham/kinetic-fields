"""Main window: header, scene library, APC visualizer, inspector, diagnostics."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from PySide6.QtCore import QByteArray, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence, QPixmap
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QFrame, QHBoxLayout, QLabel, QMainWindow, QPushButton, QScrollArea, QSplitter,
    QVBoxLayout, QWidget,
)

from .. import __version__
from ..midi.protocol import BRIGHTNESS_LEVELS
from ..engine.manager import speed_factor
from . import theme
from .apc_view import ApcView
from .controls import LabeledSlider, ParamsPanel, Segmented, ctl_label
from .diagnostics import DiagnosticsPanel
from .scene_library import SceneLibrary

AUTO_PORT = "Auto-detect APC mini mk2"


class MainWindow(QMainWindow):
    closing = Signal()

    def __init__(self, ctl, log_handler) -> None:
        super().__init__()
        self.ctl = ctl
        s = ctl.settings
        self.setWindowTitle("Kinetic Kontroller")
        self.setMinimumSize(1000, 640)
        self.resize(1180, 760)

        root = QWidget()
        root_lay = QVBoxLayout(root)
        root_lay.setContentsMargins(0, 0, 0, 0)
        root_lay.setSpacing(0)
        self.setCentralWidget(root)

        root_lay.addWidget(self._build_header())

        body = QSplitter(Qt.Horizontal)
        body.setHandleWidth(1)
        body.setChildrenCollapsible(False)

        # -- sidebar --------------------------------------------------------
        side = QWidget()
        side.setObjectName("Sidebar")
        side_lay = QVBoxLayout(side)
        side_lay.setContentsMargins(0, 0, 0, 0)
        self.library = SceneLibrary(ctl.registry.all(), ctl.thumbnail)
        side_lay.addWidget(self.library)
        side.setMinimumWidth(230)
        side.setMaximumWidth(320)
        body.addWidget(side)

        # -- stage ----------------------------------------------------------
        stage = QWidget()
        stage.setObjectName("Stage")
        st = QVBoxLayout(stage)
        st.setContentsMargins(28, 22, 28, 18)
        st.setSpacing(4)
        self.now_title = QLabel("—")
        self.now_title.setObjectName("NowTitle")
        self.now_sub = QLabel("")
        self.now_sub.setObjectName("NowSub")
        st.addWidget(self.now_title)
        st.addWidget(self.now_sub)
        self.view = ApcView()
        st.addWidget(self.view, 1)
        body.addWidget(stage)

        # -- inspector ------------------------------------------------------
        body.addWidget(self._build_inspector())
        body.setStretchFactor(0, 0)
        body.setStretchFactor(1, 1)
        body.setStretchFactor(2, 0)
        body.setSizes([260, 620, 320])
        root_lay.addWidget(body, 1)

        # -- diagnostics + footer --------------------------------------------
        self.diagnostics = DiagnosticsPanel(log_handler, ctl.open_log_folder)
        self.diagnostics.setVisible(bool(s["show_diagnostics"]))
        root_lay.addWidget(self.diagnostics)
        root_lay.addWidget(self._build_footer())

        self._build_menus()
        self._wire()

        geo = s.get("window_geometry")
        if isinstance(geo, str):
            try:
                self.restoreGeometry(QByteArray.fromBase64(geo.encode()))
            except Exception:
                pass

        self._stats_timer = QTimer(self)
        self._stats_timer.setInterval(1000)
        self._stats_timer.timeout.connect(self._update_stats)
        self._stats_timer.start()
        self._last_frames = 0

    # ------------------------------------------------------------------ build
    def _build_header(self) -> QWidget:
        w = QFrame()
        w.setObjectName("Header")
        w.setFixedHeight(58)
        lay = QHBoxLayout(w)
        lay.setContentsMargins(18, 0, 14, 0)
        lay.setSpacing(10)
        logo = QLabel()
        logo.setFixedSize(30, 30)
        icon = Path(__file__).resolve().parents[1] / "assets" / "AppIcon-256.png"
        pm = QPixmap(str(icon))
        if not pm.isNull():
            dpr = self.devicePixelRatioF()
            pm = pm.scaled(int(30 * dpr), int(30 * dpr), Qt.KeepAspectRatio, Qt.SmoothTransformation)
            pm.setDevicePixelRatio(dpr)
            logo.setPixmap(pm)
        lay.addWidget(logo)
        titles = QVBoxLayout()
        titles.setSpacing(0)
        t = QLabel("KINETIC KONTROLLER")
        t.setObjectName("AppTitle")
        sub = QLabel("LED console for Akai APC mini mk2")
        sub.setObjectName("AppSub")
        titles.addStretch(1)
        titles.addWidget(t)
        titles.addWidget(sub)
        titles.addStretch(1)
        lay.addLayout(titles)
        lay.addStretch(1)

        self.status = QLabel()
        self.status.setTextFormat(Qt.RichText)
        lay.addWidget(self.status)
        lay.addSpacing(8)
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(220)
        self.port_combo.setToolTip("MIDI output used for the LEDs")
        lay.addWidget(self.port_combo)
        self.refresh_btn = QPushButton("Refresh MIDI")
        self.refresh_btn.setToolTip("Rescan MIDI devices and reconnect (⌘R)")
        lay.addWidget(self.refresh_btn)
        return w

    def _build_inspector(self) -> QWidget:
        s = self.ctl.settings
        outer = QWidget()
        outer.setObjectName("Inspector")
        outer.setMinimumWidth(290)
        outer.setMaximumWidth(360)
        ol = QVBoxLayout(outer)
        ol.setContentsMargins(0, 0, 0, 0)
        ol.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        inner = QWidget()
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(18, 18, 18, 18)
        lay.setSpacing(18)

        self.speed = LabeledSlider("Speed", 0, 100, int(s["speed"]),
                                   fmt=lambda v: f"{speed_factor(v):.2f}×", left="Slow", right="Fast")
        lay.addWidget(self.speed)

        levels = BRIGHTNESS_LEVELS
        idx = min(range(len(levels)), key=lambda i: abs(levels[i] - int(s["brightness"])))
        self.brightness = LabeledSlider("Brightness", 0, len(levels) - 1, idx,
                                        fmt=lambda v: f"{levels[v]}%", left="10%", right="100%")
        self.brightness.slider.setPageStep(1)
        self.brightness.slider.setTickPosition(self.brightness.slider.TickPosition.NoTicks)
        self.brightness.setToolTip("Uses the APC's seven official LED brightness levels")
        lay.addWidget(self.brightness)

        sep = QFrame()
        sep.setFixedHeight(1)
        sep.setStyleSheet(f"background:{theme.BORDER};")
        lay.addWidget(sep)

        self.params_title = ctl_label("Scene settings")
        lay.addWidget(self.params_title)
        self.params = ParamsPanel()
        lay.addWidget(self.params)

        sep2 = QFrame()
        sep2.setFixedHeight(1)
        sep2.setStyleSheet(f"background:{theme.BORDER};")
        lay.addWidget(sep2)

        lay.addWidget(ctl_label("LED output"))
        self.mode = Segmented(["Palette", "RGB"], "RGB" if s["output_mode"] == "rgb" else "Palette")
        self.mode.setToolTip("Palette: classic Note On colours (most compatible).\n"
                             "RGB: true 24-bit colour via SysEx (smoother gradients).")
        lay.addWidget(self.mode)

        self.opt_restore = QCheckBox("Start last scene at launch")
        self.opt_restore.setChecked(bool(s["restore_on_launch"]))
        self.opt_buttons = QCheckBox("APC scene buttons pick favorites")
        self.opt_buttons.setChecked(bool(s["scene_buttons"]))
        self.opt_buttons.setToolTip("The 8 green scene-launch buttons start favorites 1–8.\n"
                                    "Shift + any scene button = Blackout.")
        self.opt_quit = QCheckBox("Blackout when quitting")
        self.opt_quit.setChecked(bool(s["blackout_on_quit"]))
        for cb in (self.opt_restore, self.opt_buttons, self.opt_quit):
            lay.addWidget(cb)
        lay.addStretch(1)
        scroll.setWidget(inner)
        ol.addWidget(scroll, 1)

        bw = QWidget()
        bl = QVBoxLayout(bw)
        bl.setContentsMargins(18, 10, 18, 18)
        self.blackout_btn = QPushButton("BLACKOUT")
        self.blackout_btn.setObjectName("Blackout")
        self.blackout_btn.setCursor(Qt.PointingHandCursor)
        self.blackout_btn.setToolTip("Stop everything and turn every LED off  (0)")
        bl.addWidget(self.blackout_btn)
        ol.addWidget(bw)
        return outer

    def _build_footer(self) -> QWidget:
        w = QFrame()
        w.setObjectName("Footer")
        w.setFixedHeight(28)
        lay = QHBoxLayout(w)
        lay.setContentsMargins(12, 0, 12, 0)
        self.diag_btn = QPushButton()
        self.diag_btn.setObjectName("Link")
        self.diag_btn.setCursor(Qt.PointingHandCursor)
        lay.addWidget(self.diag_btn)
        self._update_diag_btn()
        lay.addStretch(1)
        self.footer_info = QLabel()
        self.footer_info.setObjectName("Mono")
        lay.addWidget(self.footer_info)
        v = QLabel(f"v{__version__}")
        v.setObjectName("Mono")
        lay.addWidget(v)
        return w

    def _build_menus(self) -> None:
        mb = self.menuBar()
        m = mb.addMenu("Controls")
        a = QAction("Blackout", self)
        a.setShortcut(QKeySequence("Ctrl+B"))  # ⌘B on macOS; plain 0 also works
        a.triggered.connect(self.ctl.blackout)
        m.addAction(a)
        a = QAction("Refresh MIDI", self)
        a.setShortcut(QKeySequence("Ctrl+R"))
        a.triggered.connect(self.ctl.refresh_midi)
        m.addAction(a)
        m.addSeparator()
        a = QAction("Show Diagnostics", self)
        a.setShortcut(QKeySequence("Ctrl+Shift+D"))
        a.triggered.connect(self.toggle_diagnostics)
        m.addAction(a)
        f = mb.addMenu("Folders")
        a = QAction("Open Settings Folder", self)
        a.triggered.connect(self.ctl.open_settings_folder)
        f.addAction(a)
        a = QAction("Open User Effects Folder", self)
        a.triggered.connect(self.ctl.open_effects_folder)
        f.addAction(a)
        a = QAction("Open Log Folder", self)
        a.triggered.connect(self.ctl.open_log_folder)
        f.addAction(a)

    # ------------------------------------------------------------------ wiring
    def _wire(self) -> None:
        c = self.ctl
        self.library.effect_clicked.connect(c.start_effect)
        self.library.favorites_changed.connect(c.set_favorites)
        self.library.shortcut_assigned.connect(c.assign_shortcut)
        self.view.pad_clicked.connect(lambda x, y, b: c.engine.pad_pressed(x, y, b))
        self.refresh_btn.clicked.connect(c.refresh_midi)
        self.port_combo.activated.connect(self._port_chosen)
        self.speed.valueChanged.connect(c.set_speed)
        self.brightness.valueChanged.connect(lambda i: c.set_brightness(BRIGHTNESS_LEVELS[i]))
        self.params.param_changed.connect(c.set_param)
        self.params.action.connect(c.pattern_action)
        self.mode.changed.connect(lambda v: c.set_output_mode("rgb" if v == "RGB" else "palette"))
        self.opt_restore.toggled.connect(lambda v: c.set_option("restore_on_launch", v))
        self.opt_buttons.toggled.connect(lambda v: c.set_option("scene_buttons", v))
        self.opt_quit.toggled.connect(lambda v: c.set_option("blackout_on_quit", v))
        self.blackout_btn.clicked.connect(c.blackout)
        self.diag_btn.clicked.connect(self.toggle_diagnostics)

    def _port_chosen(self, _index: int) -> None:
        text = self.port_combo.currentText()
        self.ctl.set_midi_port("" if text == AUTO_PORT else text)

    # ------------------------------------------------------------------ updates
    def set_ports(self, names, preferred: str) -> None:
        self.port_combo.blockSignals(True)
        self.port_combo.clear()
        self.port_combo.addItem(AUTO_PORT)
        for n in names:
            self.port_combo.addItem(n)
        if preferred and preferred not in names:
            self.port_combo.addItem(preferred)
        self.port_combo.setCurrentText(preferred or AUTO_PORT)
        self.port_combo.blockSignals(False)

    def set_connection(self, connected: bool, port: Optional[str], midi_ok: bool = True) -> None:
        if connected:
            html = (f"<span style='color:{theme.GOOD}; font-size:15px'>●</span>"
                    f"&nbsp; <b>APC Mini MK2 Connected</b>")
            self.status.setToolTip(port or "")
        elif not midi_ok:
            html = (f"<span style='color:{theme.BAD}; font-size:15px'>○</span>"
                    f"&nbsp; <span style='color:{theme.TEXT_DIM}'>MIDI unavailable</span>")
        else:
            html = (f"<span style='color:{theme.TEXT_FAINT}; font-size:15px'>○</span>"
                    f"&nbsp; <span style='color:{theme.TEXT_DIM}'>APC Mini MK2 Not Connected</span>")
            self.status.setToolTip("Plug in the APC mini mk2 — it will be picked up automatically.")
        self.status.setText(html)
        self.view.set_connected(connected)

    def show_effect(self, effect_id: Optional[str], shown_id: Optional[str]) -> None:
        """``effect_id`` = running effect (None after blackout); ``shown_id`` =
        effect whose settings the inspector shows."""
        reg = self.ctl.registry
        cls = reg.get(effect_id) if effect_id else None
        shown = reg.get(shown_id) if shown_id else None
        self.library.set_active(effect_id)
        if cls:
            self.now_title.setText(cls.name.upper())
            kind = "Animated" if cls().is_animated(self.ctl.engine.params_for(cls.id)) else "Static"
            self.now_sub.setText(f"{kind} · {cls.description}")
        else:
            self.now_title.setText("BLACKOUT")
            self.now_sub.setText("All LEDs off. Pick a scene to start.")
        if shown is None or self.params.effect_id != shown.id:
            self.params.show_effect(shown, self.ctl.engine.params_for(shown.id) if shown else {})
        self.params_title.setText(f"{shown.name.upper()} SETTINGS" if shown else "SCENE SETTINGS")
        self.view.set_paint_mode(bool(cls and any(p.key == "pattern" for p in cls.params)))

    def refresh_params(self) -> None:
        eid = self.params.effect_id
        cls = self.ctl.registry.get(eid) if eid else None
        self.params.show_effect(cls, self.ctl.engine.params_for(eid) if cls else {})

    def toggle_diagnostics(self) -> None:
        vis = not self.diagnostics.isVisible()
        self.diagnostics.setVisible(vis)
        self.ctl.set_option("show_diagnostics", vis)
        self._update_diag_btn()

    def _update_diag_btn(self) -> None:
        vis = self.ctl.settings["show_diagnostics"]
        self.diag_btn.setText(("▾" if vis else "▸") + "  Diagnostics")

    def _update_stats(self) -> None:
        e = self.ctl.engine
        fps = e.frames_rendered - self._last_frames
        self._last_frames = e.frames_rendered
        dev = self.ctl.device
        text = f"{fps} fps · {dev.messages_sent} MIDI msgs · {self.ctl.output.mode} · {self.ctl.output.brightness}%"
        self.footer_info.setText(text)
        if self.diagnostics.isVisible():
            self.diagnostics.set_stats(f"port: {dev.port_name or '—'}   render thread: "
                                       f"{'running' if e.running else 'stopped'}")

    def closeEvent(self, e) -> None:
        self.ctl.settings["window_geometry"] = bytes(self.saveGeometry().toBase64()).decode()
        self.closing.emit()
        super().closeEvent(e)

"""Window chrome: global toolbar, workspace toolbar and status bar."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QHBoxLayout, QLabel, QVBoxLayout, QWidget

from .components import IconButton, MidiActivityMeter, SegmentedControl, StatusIndicator, ToolbarGroup, vline
from .design import C, H, S

ASSETS = Path(__file__).resolve().parents[1] / "assets"


class GlobalToolbar(QWidget):
    """App identity · transport · connection · MIDI activity · settings."""

    prev_clicked = Signal()
    next_clicked = Signal()
    play_clicked = Signal()
    pause_clicked = Signal()
    stop_clicked = Signal()
    refresh_clicked = Signal()
    settings_clicked = Signal(object)  # the button (menu anchor)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Toolbar")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setFixedHeight(H.TOOLBAR)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(S.LG, 0, S.MD, 0)
        lay.setSpacing(S.MD)

        logo = QLabel()
        pm = QPixmap(str(ASSETS / "AppIcon-256.png"))
        if not pm.isNull():
            pm = pm.scaled(int(34 * 2), int(34 * 2), Qt.KeepAspectRatio, Qt.SmoothTransformation)
            pm.setDevicePixelRatio(2.0)
            logo.setPixmap(pm)
        logo.setFixedSize(34, 34)
        lay.addWidget(logo)
        titles = QVBoxLayout()
        titles.setSpacing(0)
        titles.addStretch(1)
        t = QLabel("Kinetic Kontroller")
        t.setObjectName("AppTitle")
        sub = QLabel("LED console for Akai APC mini mk2")
        sub.setObjectName("AppSub")
        titles.addWidget(t)
        titles.addWidget(sub)
        titles.addStretch(1)
        lay.addLayout(titles)
        lay.addSpacing(S.XL)

        tb = dict(size=32, icon_size=15)
        self.prev = IconButton("prev", tooltip="Previous scene  (⌘←)", **tb)
        self.stop = IconButton("stop", tooltip="Stop — blackout all LEDs  (0)", **tb)
        self.play = IconButton("play", tooltip="Play the selected scene / resume  (⌘↩)", accent=C.PLAY, **tb)
        self.pause = IconButton("pause", tooltip="Pause animation — LEDs hold their state  (⌘.)",
                                checkable=True, **tb)
        self.next = IconButton("next", tooltip="Next scene  (⌘→)", **tb)
        lay.addWidget(vline(32))
        lay.addWidget(ToolbarGroup([self.prev, self.stop, self.play, self.pause, self.next]))
        lay.addWidget(vline(32))
        lay.addStretch(1)

        self.refresh = IconButton("refresh", tooltip="Refresh MIDI  (⌘R)", size=32, icon_size=15)
        lay.addWidget(self.refresh)
        lay.addSpacing(S.SM)
        self.connection = StatusIndicator("APC Mini MK2 Not Connected", C.TEXT_3)
        lay.addWidget(self.connection)
        lay.addSpacing(S.LG)

        meters = QVBoxLayout()
        meters.setSpacing(5)
        meters.addStretch(1)
        self.meter_in = MidiActivityMeter()
        self.meter_out = MidiActivityMeter()
        for label, m in (("MIDI IN", self.meter_in), ("MIDI OUT", self.meter_out)):
            row = QHBoxLayout()
            row.setSpacing(S.MD)
            lab = QLabel(label)
            lab.setObjectName("MeterLabel")
            lab.setFixedWidth(52)
            row.addWidget(lab)
            row.addWidget(m)
            meters.addLayout(row)
        meters.addStretch(1)
        lay.addLayout(meters)
        lay.addSpacing(S.MD)
        lay.addWidget(vline(34))
        self.settings = IconButton("gear", tooltip="Settings & folders", size=34, icon_size=17)
        lay.addWidget(self.settings)

        self.prev.clicked.connect(self.prev_clicked)
        self.next.clicked.connect(self.next_clicked)
        self.play.clicked.connect(self.play_clicked)
        self.pause.clicked.connect(self.pause_clicked)
        self.stop.clicked.connect(self.stop_clicked)
        self.refresh.clicked.connect(self.refresh_clicked)
        self.settings.clicked.connect(lambda: self.settings_clicked.emit(self.settings))

        self._meter_timer = QTimer(self)
        self._meter_timer.setInterval(33)
        self._meter_timer.timeout.connect(self._tick)
        self._meter_timer.start()

    def _tick(self) -> None:
        self.meter_in.tick()
        self.meter_out.tick()

    def set_connection(self, connected: bool, midi_ok: bool) -> None:
        if connected:
            self.connection.set_state("APC Mini MK2 Connected", C.GOOD)
        elif not midi_ok:
            self.connection.set_state("MIDI Unavailable", C.BAD)
        else:
            self.connection.set_state("APC Mini MK2 Not Connected", C.TEXT_3)


class WorkspaceBar(QWidget):
    """Visualizer view · scene name · scene actions · play/stop."""

    view_changed = Signal(bool)       # True = hardware-accurate
    save_pattern = Signal()
    favorite_clicked = Signal()
    more_clicked = Signal(object)
    play_clicked = Signal()
    stop_clicked = Signal()

    def __init__(self, hardware_preview: bool, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("WorkspaceBar")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setFixedHeight(H.WORKSPACE_BAR)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(S.MD, 0, S.MD, 0)
        lay.setSpacing(S.SM)
        self.view = SegmentedControl([("icon:chip", "Hardware-accurate preview (what the APC can display)"),
                                      ("icon:sparkle", "Ideal colours (renderer output)")],
                                     "icon:chip" if hardware_preview else "icon:sparkle",
                                     height=H.ICON_BUTTON, min_segment=36, stretch=False)
        lay.addWidget(self.view)
        lay.addSpacing(S.SM)

        name_box = QWidget()
        name_box.setObjectName("NameBox")
        name_box.setAttribute(Qt.WA_StyledBackground, True)
        name_box.setStyleSheet(f"#NameBox {{ background: {C.FIELD}; border: 1px solid {C.BORDER};"
                               f" border-radius: 4px; }}")
        name_box.setFixedHeight(H.ICON_BUTTON)
        name_box.setMinimumWidth(220)
        nl = QHBoxLayout(name_box)
        nl.setContentsMargins(S.MD + 2, 0, 2, 0)
        self.name = QLabel("—")
        self.name.setObjectName("EffectName")
        nl.addWidget(self.name, 1)
        self.save = IconButton("pencil", tooltip="Save this pattern to the Patterns library", size=24,
                               flat=True, icon_size=13)
        nl.addWidget(self.save)
        lay.addWidget(name_box, 2)
        self.state = QLabel("")
        self.state.setObjectName("Caption")
        lay.addWidget(self.state)
        lay.addStretch(1)

        self.fav = IconButton("star", tooltip="Add to Favorites")
        self.more = IconButton("more", tooltip="Scene options")
        lay.addWidget(self.fav)
        lay.addWidget(self.more)
        lay.addSpacing(S.SM)
        self.play = IconButton("play", tooltip="Play / restart this scene", accent=C.PLAY)
        self.stop = IconButton("stop", tooltip="Stop — blackout")
        lay.addWidget(self.play)
        lay.addWidget(self.stop)

        self.view.changed.connect(lambda k: self.view_changed.emit(k == "icon:chip"))
        self.save.clicked.connect(self.save_pattern)
        self.fav.clicked.connect(self.favorite_clicked)
        self.more.clicked.connect(lambda: self.more_clicked.emit(self.more))
        self.play.clicked.connect(self.play_clicked)
        self.stop.clicked.connect(self.stop_clicked)

    def set_scene(self, name: str, state: str, favorite: bool, can_save: bool) -> None:
        self.name.setText(name)
        self.state.setText(state)
        self.fav._accent = C.STAR if favorite else None
        self.fav.set_icon("star_filled" if favorite else "star")
        self.fav.setToolTip("Remove from Favorites" if favorite else "Add to Favorites")
        self.save.setVisible(can_save)


class StatusBar(QWidget):
    menu_clicked = Signal(object)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("StatusBar")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setFixedHeight(H.STATUS)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(S.LG, 0, S.XS, 0)
        lay.setSpacing(S.MD)
        self.status = StatusIndicator("Ready", C.GOOD, font_px=11)
        lay.addWidget(self.status)
        lay.addStretch(1)
        self.telemetry = QLabel("")
        self.telemetry.setObjectName("Telemetry")
        lay.addWidget(self.telemetry)
        self.menu = IconButton("menu", tooltip="Diagnostics & folders", size=22, flat=True, icon_size=14)
        lay.addWidget(self.menu)
        self.menu.clicked.connect(lambda: self.menu_clicked.emit(self.menu))

    def set_status(self, text: str, color: str) -> None:
        self.status.set_state(text, color)

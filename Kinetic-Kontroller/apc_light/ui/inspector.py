"""Right inspector: Pattern | Colors | Behavior | MIDI.

Flat, collapsible property sections (no cards). Effect-specific sections are
generated from the active effect's parameter declarations, so every effect
(including future ones) gets consistent controls.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Type

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import (
    QGridLayout, QHBoxLayout, QLabel, QLineEdit, QPlainTextEdit, QPushButton, QScrollArea, QStackedWidget,
    QVBoxLayout, QWidget,
)

from ..engine.effect import Effect, Param
from ..engine.manager import speed_factor
from ..midi.protocol import BRIGHTNESS_LEVELS
from .components import (
    ChoiceRow, IconButton, InspectorSection, ParameterSlider, SegmentedControl, SwatchRow, ToggleRow,
)
from .design import H, S

AUTO_PORT = "Auto-detect APC mini mk2"
PAINT_TOOLS = [("brush", "Brush — paint with the colour"), ("eraser", "Eraser — turn pads off"),
               ("eyedropper", "Eyedropper — pick a pad's colour"), ("bucket", "Fill — flood a same-colour area")]


def _page() -> tuple:
    scroll = QScrollArea()
    scroll.setWidgetResizable(True)
    scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
    body = QWidget()
    lay = QVBoxLayout(body)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.setSpacing(0)
    scroll.setWidget(body)
    return scroll, lay


def _clear(layout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        w = item.widget()
        if w is not None:
            w.deleteLater()
        elif item.layout() is not None:
            _clear(item.layout())


class Inspector(QWidget):
    TABS = ["Pattern", "Colors", "Behavior", "MIDI"]

    param_changed = Signal(str, str, object)
    action = Signal(str, str)
    speed_changed = Signal(int)
    brightness_changed = Signal(int)
    output_mode_changed = Signal(str)
    option_changed = Signal(str, bool)
    preview_changed = Signal(bool)
    port_chosen = Signal(str)
    refresh_midi = Signal()
    shortcut_assigned = Signal(str, str)
    shortcut_cleared = Signal(str)
    scene_button_assigned = Signal(int, str)   # button 0..7, effect id ("" = clear)
    blackout = Signal()
    ui_changed = Signal(str, object)
    copy_log = Signal()
    topo_opacity_changed = Signal(int)
    choose_topo = Signal()
    reset_topo = Signal()
    open_logs = Signal()

    def __init__(self, settings, effects: List[Type[Effect]], log_handler, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Inspector")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self._effects = effects
        self._effect_id: Optional[str] = None
        self._cls: Optional[Type[Effect]] = None
        self._swatches: List[SwatchRow] = []
        self.paint_tool = "brush"
        self._tool_buttons: Dict[str, IconButton] = {}
        self._brush_row: Optional[SwatchRow] = None
        self._collapsed = set(settings.get("ui_state", {}).get("collapsed_inspector", []))
        s = settings

        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        top = QWidget()
        top.setObjectName("InspectorTop")
        top.setAttribute(Qt.WA_StyledBackground, True)
        tl = QHBoxLayout(top)
        tl.setContentsMargins(S.MD, S.MD, S.MD, S.MD)
        self.tabs = SegmentedControl(self.TABS)
        tl.addWidget(self.tabs)
        lay.addWidget(top)
        self.stack = QStackedWidget()
        lay.addWidget(self.stack, 1)

        # ---------------- Pattern ----------------
        page, pl = _page()
        self.stack.addWidget(page)
        sec = self._section("Playback")
        self.speed = ParameterSlider("Speed", 0, 100, int(s["speed"]), fmt=lambda v: f"{speed_factor(v):.2f}×",
                                     left="Slow", right="Fast")
        sec.add(self.speed)
        levels = BRIGHTNESS_LEVELS
        idx = min(range(len(levels)), key=lambda i: abs(levels[i] - int(s["brightness"])))
        self.brightness = ParameterSlider("Brightness", 0, len(levels) - 1, idx, fmt=lambda v: f"{levels[v]}%",
                                          left="10%", right="100%")
        self.brightness.slider.setPageStep(1)
        self.brightness.setToolTip("The APC's seven official LED brightness levels")
        sec.add(self.brightness)
        pl.addWidget(sec)
        self.dynamic = QWidget()
        self.dynamic_layout = QVBoxLayout(self.dynamic)
        self.dynamic_layout.setContentsMargins(0, 0, 0, 0)
        self.dynamic_layout.setSpacing(0)
        pl.addWidget(self.dynamic)
        sec = self._section("LED Output")
        self.mode = ChoiceRow("LED mode", ["Palette", "RGB"], "RGB" if s["output_mode"] == "rgb" else "Palette")
        self.mode.setToolTip("Palette: classic Note On colours with per-pad brightness.\n"
                             "RGB: true 24-bit colour via SysEx (smoothest fades).")
        sec.add(self.mode)
        self.opt_restore = ToggleRow("Start last scene at launch", bool(s["restore_on_launch"]))
        self.opt_buttons = ToggleRow("APC scene buttons start scenes", bool(s["scene_buttons"]),
                                     "Each scene button starts the scene assigned to it in Behavior ▸ Scene "
                                     "Buttons. Shift + scene button = Blackout.")
        self.opt_quit = ToggleRow("Blackout when quitting", bool(s["blackout_on_quit"]))
        for t in (self.opt_restore, self.opt_buttons, self.opt_quit):
            sec.add(t)
        pl.addWidget(sec)
        pl.addStretch(1)

        # ---------------- Colors ----------------
        page, cl = _page()
        self.stack.addWidget(page)
        self.colors_dynamic = QWidget()
        self.colors_layout = QVBoxLayout(self.colors_dynamic)
        self.colors_layout.setContentsMargins(0, 0, 0, 0)
        self.colors_layout.setSpacing(0)
        cl.addWidget(self.colors_dynamic)
        sec = self._section("Preview")
        self.opt_preview = ToggleRow("Hardware-accurate preview", bool(s["hardware_preview"]),
                                     "On: the on-screen pads show what the APC can physically display.\n"
                                     "Off: the renderer's ideal colours.")
        sec.add(self.opt_preview)
        hint = QLabel("The APC shows 127 palette colours × 7 brightness levels per pad in Palette mode, "
                      "or any colour in RGB mode.")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        sec.add(hint)
        cl.addWidget(sec)
        sec = self._section("Workspace Background")
        self.topo = ParameterSlider("Topo pattern opacity", 0, 100, int(s.get("topo_opacity", 25)),
                                    fmt=lambda v: f"{v}%" if v else "Off", left="Off", right="100%")
        self.topo.setToolTip("Opacity of the topographic pattern behind the on-screen APC")
        sec.add(self.topo)
        row = QHBoxLayout()
        row.setSpacing(S.SM)
        self.topo_choose = QPushButton("Choose SVG…")
        self.topo_reset = QPushButton("Use Default")
        row.addWidget(self.topo_choose)
        row.addWidget(self.topo_reset)
        sec.add_layout(row)
        self.topo_source = QLabel("")
        self.topo_source.setObjectName("Hint")
        self.topo_source.setWordWrap(True)
        sec.add(self.topo_source)
        cl.addWidget(sec)
        cl.addStretch(1)

        # ---------------- Behavior ----------------
        page, bl = _page()
        self.stack.addWidget(page)
        sec = self._section("Scene Buttons")
        self._scene_rows: List[ChoiceRow] = []
        for i in range(8):
            row = ChoiceRow(f"Button {i + 1}", ["—"] + [c.name for c in effects], "—")
            row.changed.connect(lambda name, k=i: self._scene_button_changed(k, name))
            sec.add(row)
            self._scene_rows.append(row)
        hint = QLabel("The green buttons on the right of the APC, top = 1. Assigned scenes become favorites. "
                      "You can also right-click a scene button on the on-screen APC, or a scene in the browser.")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        sec.add(hint)
        bl.addWidget(sec)

        sec = self._section("Keyboard Shortcuts")
        self._shortcut_rows: Dict[str, ChoiceRow] = {}
        names = ["—"] + [c.name for c in effects]
        for key in "123456789":
            row = ChoiceRow(f"Key {key}", names, "—")
            row.changed.connect(lambda name, k=key: self._shortcut_changed(k, name))
            sec.add(row)
            self._shortcut_rows[key] = row
        hint = QLabel("0 = Blackout   ·   ⌘R Refresh MIDI   ·   ⌘B Blackout\n"
                      "Digit keys work when the window is focused and no text field is being edited.")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        sec.add(hint)
        bl.addWidget(sec)
        bl.addStretch(1)

        # ---------------- MIDI ----------------
        page, ml = _page()
        self.stack.addWidget(page)
        sec = self._section("Device")
        self.port = ChoiceRow("Output", [AUTO_PORT], AUTO_PORT)
        sec.add(self.port)
        row = QHBoxLayout()
        self.port_status = QLabel("—")
        self.port_status.setObjectName("Hint")
        row.addWidget(self.port_status, 1)
        rb = QPushButton("Refresh MIDI")
        rb.clicked.connect(self.refresh_midi)
        row.addWidget(rb)
        sec.add_layout(row)
        ml.addWidget(sec)
        sec = self._section("Monitor")
        grid = QGridLayout()
        grid.setHorizontalSpacing(S.LG)
        grid.setVerticalSpacing(S.XS)
        self._stats: Dict[str, QLabel] = {}
        for i, (k, label) in enumerate([("out", "MIDI out"), ("in", "MIDI in"), ("lat", "Touch → LED"),
                                        ("held", "Pads held"), ("vel", "Pad velocity"), ("thread", "Render thread")]):
            a = QLabel(label)
            a.setObjectName("Hint")
            b = QLabel("—")
            b.setObjectName("Mono")
            grid.addWidget(a, i, 0)
            grid.addWidget(b, i, 1)
            self._stats[k] = b
        grid.setColumnStretch(1, 1)
        sec.add_layout(grid)
        ml.addWidget(sec)
        sec = self._section("Log")
        self.log = QPlainTextEdit()
        self.log.setObjectName("Log")
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(1000)
        self.log.setMinimumHeight(220)
        for line in log_handler.backlog:
            self.log.appendPlainText(line)
        log_handler.emitter.line.connect(self.log.appendPlainText)
        sec.add(self.log)
        row = QHBoxLayout()
        cb = QPushButton("Copy Log")
        cb.clicked.connect(lambda: QGuiApplication.clipboard().setText(self.log.toPlainText()))
        ob = QPushButton("Open Log Folder")
        ob.clicked.connect(self.open_logs)
        row.addWidget(cb)
        row.addWidget(ob)
        row.addStretch(1)
        sec.add_layout(row)
        ml.addWidget(sec)
        ml.addStretch(1)

        # ---------------- footer ----------------
        foot = QWidget()
        foot.setObjectName("InspectorFoot")
        foot.setAttribute(Qt.WA_StyledBackground, True)
        fl = QVBoxLayout(foot)
        fl.setContentsMargins(S.LG, S.MD + 2, S.LG, S.MD + 2)
        self.blackout_btn = QPushButton("BLACKOUT")
        self.blackout_btn.setObjectName("Blackout")
        self.blackout_btn.setCursor(Qt.PointingHandCursor)
        self.blackout_btn.setToolTip("Stop everything and turn every LED off  (0)")
        fl.addWidget(self.blackout_btn)
        lay.addWidget(foot)

        # wiring
        self.tabs.changed.connect(self._tab)
        self.speed.valueChanged.connect(self.speed_changed)
        self.brightness.valueChanged.connect(lambda i: self.brightness_changed.emit(BRIGHTNESS_LEVELS[i]))
        self.mode.changed.connect(lambda v: self.output_mode_changed.emit("rgb" if v == "RGB" else "palette"))
        self.opt_restore.toggled.connect(lambda v: self.option_changed.emit("restore_on_launch", v))
        self.opt_buttons.toggled.connect(lambda v: self.option_changed.emit("scene_buttons", v))
        self.opt_quit.toggled.connect(lambda v: self.option_changed.emit("blackout_on_quit", v))
        self.opt_preview.toggled.connect(self.preview_changed)
        self.port.changed.connect(lambda t: self.port_chosen.emit("" if t == AUTO_PORT else t))
        self.blackout_btn.clicked.connect(self.blackout)
        self.topo.valueChanged.connect(self.topo_opacity_changed)
        self.topo_choose.clicked.connect(self.choose_topo)
        self.topo_reset.clicked.connect(self.reset_topo)
        tab = s.get("ui_state", {}).get("inspector_tab")
        if tab in self.TABS:
            self.set_tab(tab)

    # ----------------------------------------------------------------- helpers
    def _section(self, title: str) -> InspectorSection:
        sec = InspectorSection(title, expanded=title.upper() not in self._collapsed)
        sec.toggled.connect(self._section_toggled)
        return sec

    def _section_toggled(self, key: str, expanded: bool) -> None:
        k = key.upper()
        if expanded:
            self._collapsed.discard(k)
        else:
            self._collapsed.add(k)
        self.ui_changed.emit("collapsed_inspector", sorted(self._collapsed))

    def _tab(self, name: str) -> None:
        self.stack.setCurrentIndex(self.TABS.index(name))
        self.ui_changed.emit("inspector_tab", name)

    def set_tab(self, name: str) -> None:
        self.tabs.set_current(name)
        self.stack.setCurrentIndex(self.TABS.index(name))

    @property
    def effect_id(self) -> Optional[str]:
        return self._effect_id

    # ----------------------------------------------------------------- effect sections
    def show_effect(self, cls: Optional[Type[Effect]], values: Dict[str, Any]) -> None:
        for sw in self._swatches:
            sw.close_dialog()
        self._swatches = []
        self._brush_row = None
        self._tool_buttons = {}
        _clear(self.dynamic_layout)
        _clear(self.colors_layout)
        self._effect_id = cls.id if cls else None
        self._cls = cls
        if cls is None:
            return
        eid = cls.id
        has_pattern = any(p.key == "pattern" for p in cls.params)
        visible = [p for p in cls.params if not p.hidden]
        colors = [p for p in visible if p.kind == "color" and not (has_pattern and p.key == "brush")]
        others = [p for p in visible if p.kind != "color"]

        if cls.presets:
            sec = self._section("Presets")
            grid = QGridLayout()
            grid.setSpacing(S.XS)
            for i, name in enumerate(cls.presets):
                b = QPushButton(name)
                b.setObjectName("Preset")
                b.setCursor(Qt.PointingHandCursor)
                b.clicked.connect(lambda _=False, n=name: self.action.emit(eid, f"preset:{n}"))
                grid.addWidget(b, i // 3, i % 3)
            sec.add_layout(grid)
            self.dynamic_layout.addWidget(sec)

        groups: Dict[str, List[Param]] = {}
        for p in others:
            groups.setdefault(p.group or cls.name, []).append(p)
        for title, params in groups.items():
            sec = self._section(title)
            for p in params:
                sec.add(self._editor(eid, p, values.get(p.key, p.default)))
            self.dynamic_layout.addWidget(sec)

        if has_pattern:
            self.dynamic_layout.addWidget(self._paint_tools(eid, values))

        if cls.presets or cls.hint:
            sec = self._section("Scene")
            if cls.hint:
                h = QLabel(cls.hint)
                h.setObjectName("Hint")
                h.setWordWrap(True)
                sec.add(h)
            if cls.presets:
                reset = QPushButton("Reset to Defaults")
                reset.clicked.connect(lambda: self.action.emit(eid, "reset"))
                sec.add(reset)
            self.dynamic_layout.addWidget(sec)

        sec = self._section("Colors")
        if colors:
            for p in colors:
                sec.add(self._color_row(eid, p, values.get(p.key, p.default)))
        else:
            h = QLabel(f"{cls.name} has no colour settings." if not has_pattern
                       else "Pick paint colours under Pattern ▸ Paint Tools.")
            h.setObjectName("Hint")
            sec.add(h)
        self.colors_layout.addWidget(sec)

    def refresh_values(self, values: Dict[str, Any]) -> None:
        cls = self._cls
        self.show_effect(cls, values)

    def _emit(self, eid: str, key: str):
        return lambda v: self.param_changed.emit(eid, key, v)

    def _editor(self, eid: str, p: Param, value: Any) -> QWidget:
        if p.kind == "choice":
            row = ChoiceRow(p.label, p.options, value)
            row.changed.connect(self._emit(eid, p.key))
            return row
        if p.kind == "bool":
            row = ToggleRow(p.label, bool(value))
            row.toggled.connect(self._emit(eid, p.key))
            return row
        if p.kind in ("int", "float"):
            scale = 100 if p.kind == "float" else 1
            left, right = (list(p.ends) + ["", ""])[:2]
            w = ParameterSlider(p.label, int(p.minimum * scale), int(p.maximum * scale), int(value * scale),
                                fmt=(lambda v, s=scale: f"{v / s:.2f}" if s != 1 else str(v)), left=left, right=right)
            w.valueChanged.connect(lambda v, s=scale, k=p.key, kind=p.kind:
                                   self.param_changed.emit(eid, k, v / s if kind == "float" else v))
            return w
        if p.kind == "text":
            box = QWidget()
            l = QHBoxLayout(box)
            l.setContentsMargins(0, 0, 0, 0)
            l.setSpacing(S.MD)
            lab = QLabel(p.label)
            lab.setObjectName("Param")
            l.addWidget(lab)
            e = QLineEdit(str(value))
            e.setMaxLength(200)
            e.setFixedHeight(H.CONTROL)
            e.textChanged.connect(self._emit(eid, p.key))
            l.addWidget(e, 2)
            return box
        if p.kind == "color":
            return self._color_row(eid, p, value)
        return QWidget()

    def _color_row(self, eid: str, p: Param, value: str) -> QWidget:
        box = QWidget()
        l = QVBoxLayout(box)
        l.setContentsMargins(0, 0, 0, 0)
        l.setSpacing(S.XS)
        lab = QLabel(p.label)
        lab.setObjectName("Param")
        l.addWidget(lab)
        row = SwatchRow(value)
        row.changed.connect(self._emit(eid, p.key))
        self._swatches.append(row)
        l.addWidget(row)
        return box

    def _paint_tools(self, eid: str, values: Dict[str, Any]) -> QWidget:
        sec = self._section("Paint Tools")
        self._brush_row = SwatchRow(values.get("brush", "#ff00ff"))
        self._brush_row.changed.connect(self._emit(eid, "brush"))
        self._swatches.append(self._brush_row)
        sec.add(self._brush_row)
        row = QHBoxLayout()
        row.setSpacing(S.XS)
        for name, tip in PAINT_TOOLS:
            b = IconButton(name, tooltip=tip, checkable=True, size=30, icon_size=15)
            b.setChecked(name == self.paint_tool)
            b.clicked.connect(lambda _=False, n=name: self.set_paint_tool(n))
            self._tool_buttons[name] = b
            row.addWidget(b)
        row.addStretch(1)
        sec.add_layout(row)
        hint = QLabel("Click or drag on the pads to paint. Right-click to erase. Hardware pads toggle.")
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        sec.add(hint)
        row = QHBoxLayout()
        row.setSpacing(S.SM)
        for label, act in (("Clear", "clear"), ("Fill", "fill")):
            b = QPushButton(label)
            b.clicked.connect(lambda _=False, a=act: self.action.emit(eid, a))
            row.addWidget(b)
        sec.add_layout(row)
        return sec

    def set_paint_tool(self, name: str) -> None:
        self.paint_tool = name
        for n, b in self._tool_buttons.items():
            b.setChecked(n == name)

    def set_brush(self, color: str) -> None:
        if self._brush_row is not None:
            self._brush_row.set_value(color)

    # ----------------------------------------------------------------- global state
    def set_output_mode(self, mode: str) -> None:
        self.mode.set_value("RGB" if mode == "rgb" else "Palette")

    def set_ports(self, names, preferred: str) -> None:
        c = self.port.combo
        c.blockSignals(True)
        c.clear()
        c.addItem(AUTO_PORT)
        c.addItems(list(names))
        if preferred and preferred not in names:
            c.addItem(preferred)
        c.setCurrentText(preferred or AUTO_PORT)
        c.blockSignals(False)

    def set_port_status(self, text: str) -> None:
        self.port_status.setText(text)

    def set_shortcuts(self, shortcuts: Dict[str, str]) -> None:
        names = {c.id: c.name for c in self._effects}
        for key, row in self._shortcut_rows.items():
            row.set_value(names.get(shortcuts.get(key, ""), "—"))

    def set_scene_slots(self, slots: List[str]) -> None:
        names = {c.id: c.name for c in self._effects}
        for row, eid in zip(self._scene_rows, slots):
            row.set_value(names.get(eid, "—"))

    def _scene_button_changed(self, index: int, name: str) -> None:
        eid = next((c.id for c in self._effects if c.name == name), "")
        self.scene_button_assigned.emit(index, eid)

    def _shortcut_changed(self, key: str, name: str) -> None:
        eid = next((c.id for c in self._effects if c.name == name), "")
        if eid:
            self.shortcut_assigned.emit(key, eid)
        else:
            self.shortcut_cleared.emit(key)

    def set_stats(self, stats: Dict[str, str]) -> None:
        for k, v in stats.items():
            if k in self._stats:
                self._stats[k].setText(v)

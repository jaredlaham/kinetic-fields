"""Reusable controls and the auto-generated effect parameter panel."""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Sequence, Type

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QButtonGroup, QCheckBox, QColorDialog, QComboBox, QGridLayout, QHBoxLayout, QLabel, QLineEdit,
    QPushButton, QSlider, QToolButton, QVBoxLayout, QWidget,
)

from ..engine.effect import Effect, Param

QUICK_COLORS = ["#ff0000", "#ff5400", "#ffff00", "#00ff00", "#00ffff", "#0055ff", "#8000ff", "#ff00ff", "#ffffff"]


def ctl_label(text: str) -> QLabel:
    lbl = QLabel(text.upper())
    lbl.setObjectName("CtlLabel")
    return lbl


class LabeledSlider(QWidget):
    """``LABEL ........ value`` over a horizontal slider, with end captions."""

    valueChanged = Signal(int)

    def __init__(self, label: str, minimum: int, maximum: int, value: int,
                 fmt: Callable[[int], str] = str, left: str = "", right: str = "", parent=None) -> None:
        super().__init__(parent)
        self._fmt = fmt
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        top = QHBoxLayout()
        top.addWidget(ctl_label(label))
        top.addStretch(1)
        self.value_label = QLabel()
        self.value_label.setObjectName("CtlValue")
        top.addWidget(self.value_label)
        lay.addLayout(top)
        self.slider = QSlider(Qt.Horizontal)
        self.slider.setRange(minimum, maximum)
        self.slider.setValue(value)
        self.slider.valueChanged.connect(self._changed)
        lay.addWidget(self.slider)
        if left or right:
            ends = QHBoxLayout()
            a, b = QLabel(left), QLabel(right)
            a.setObjectName("Hint")
            b.setObjectName("Hint")
            ends.addWidget(a)
            ends.addStretch(1)
            ends.addWidget(b)
            lay.addLayout(ends)
        self._changed(value, emit=False)

    def _changed(self, v: int, emit: bool = True) -> None:
        self.value_label.setText(self._fmt(v))
        if emit:
            self.valueChanged.emit(v)

    def value(self) -> int:
        return self.slider.value()

    def setValue(self, v: int) -> None:
        self.slider.setValue(v)


class Segmented(QWidget):
    changed = Signal(str)

    def __init__(self, options: Sequence[str], current: str, parent=None) -> None:
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.group = QButtonGroup(self)
        self.group.setExclusive(True)
        self._buttons: Dict[str, QPushButton] = {}
        for i, opt in enumerate(options):
            b = QPushButton(opt)
            b.setCheckable(True)
            b.setCursor(Qt.PointingHandCursor)
            b.setObjectName("SegFirst" if i == 0 else "SegLast" if i == len(options) - 1 else "Seg")
            b.setChecked(opt == current)
            b.clicked.connect(lambda _=False, o=opt: self.changed.emit(o))
            self.group.addButton(b)
            self._buttons[opt] = b
            lay.addWidget(b, 1)

    def set_value(self, value: str) -> None:
        if value in self._buttons:
            self._buttons[value].setChecked(True)


class ColorControl(QWidget):
    """Swatch that opens the macOS colour panel, plus quick colour chips."""

    changed = Signal(str)

    def __init__(self, value: str, parent=None) -> None:
        super().__init__(parent)
        self._value = value
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        row = QHBoxLayout()
        row.setSpacing(8)
        self.swatch = QToolButton()
        self.swatch.setObjectName("Swatch")
        self.swatch.setFixedSize(44, 26)
        self.swatch.setCursor(Qt.PointingHandCursor)
        self.swatch.setToolTip("Choose colour…")
        self.swatch.clicked.connect(self._pick)
        row.addWidget(self.swatch)
        self.hex = QLabel()
        self.hex.setObjectName("Mono")
        row.addWidget(self.hex)
        row.addStretch(1)
        lay.addLayout(row)
        chips = QHBoxLayout()
        chips.setSpacing(4)
        for c in QUICK_COLORS:
            b = QToolButton()
            b.setObjectName("Swatch")
            b.setFixedSize(18, 18)
            b.setCursor(Qt.PointingHandCursor)
            b.setStyleSheet(f"background:{c};")
            b.setToolTip(c)
            b.clicked.connect(lambda _=False, col=c: self._set(col))
            chips.addWidget(b)
        chips.addStretch(1)
        lay.addLayout(chips)
        self._dialog: Optional[QColorDialog] = None
        self._paint()

    def _paint(self) -> None:
        self.swatch.setStyleSheet(f"background:{self._value};")
        self.hex.setText(self._value.upper())

    def _set(self, value: str) -> None:
        value = value.lower()
        if value != self._value:
            self._value = value
            self._paint()
            self.changed.emit(value)

    def _pick(self) -> None:
        if self._dialog is None:
            self._dialog = QColorDialog(QColor(self._value), self.window())
            self._dialog.setWindowTitle("Choose Colour")
            self._dialog.currentColorChanged.connect(lambda c: self._set(c.name()))
            self._dialog.colorSelected.connect(lambda c: self._set(c.name()))
        else:
            self._dialog.setCurrentColor(QColor(self._value))
        self._dialog.show()
        self._dialog.raise_()

    def close_dialog(self) -> None:
        if self._dialog is not None:
            self._dialog.close()


class ParamsPanel(QWidget):
    """Builds controls from an effect's ``params`` declarations."""

    param_changed = Signal(str, str, object)  # effect id, key, value
    action = Signal(str, str)                 # effect id, action name

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._lay = QVBoxLayout(self)
        self._lay.setContentsMargins(0, 0, 0, 0)
        self._lay.setSpacing(14)
        self._effect_id: Optional[str] = None
        self._colors: List[ColorControl] = []

    @property
    def effect_id(self) -> Optional[str]:
        return self._effect_id

    def show_effect(self, cls: Optional[Type[Effect]], values: Dict[str, Any]) -> None:
        for c in self._colors:
            c.close_dialog()
        self._colors = []
        while self._lay.count():
            item = self._lay.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()
            elif item.layout():
                _clear_layout(item.layout())
        self._effect_id = cls.id if cls else None
        if cls is None:
            return
        visible = [p for p in cls.params if not p.hidden]
        for p in visible:
            self._lay.addWidget(self._build(cls.id, p, values.get(p.key, p.default)))
        if any(p.key == "pattern" for p in cls.params):
            self._lay.addWidget(self._pattern_tools(cls.id))
        if not visible and not any(p.key == "pattern" for p in cls.params):
            hint = QLabel("This scene has no adjustable settings.")
            hint.setObjectName("Hint")
            self._lay.addWidget(hint)

    def _emit(self, eid: str, key: str):
        return lambda v: self.param_changed.emit(eid, key, v)

    def _build(self, eid: str, p: Param, value: Any) -> QWidget:
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        if p.kind == "color":
            lay.addWidget(ctl_label(p.label))
            w = ColorControl(value)
            w.changed.connect(self._emit(eid, p.key))
            self._colors.append(w)
            lay.addWidget(w)
        elif p.kind == "choice":
            lay.addWidget(ctl_label(p.label))
            if len(p.options) <= 4 and sum(len(o) for o in p.options) <= 30:
                w = Segmented(p.options, value)
                w.changed.connect(self._emit(eid, p.key))
            else:
                w = QComboBox()
                w.addItems(list(p.options))
                w.setCurrentText(value)
                w.currentTextChanged.connect(self._emit(eid, p.key))
            lay.addWidget(w)
        elif p.kind == "bool":
            w = QCheckBox(p.label)
            w.setChecked(bool(value))
            w.toggled.connect(self._emit(eid, p.key))
            lay.addWidget(w)
        elif p.kind in ("int", "float"):
            scale = 100 if p.kind == "float" else 1
            w = LabeledSlider(p.label, int(p.minimum * scale), int(p.maximum * scale), int(value * scale),
                              fmt=(lambda v, s=scale: f"{v / s:.2f}" if s != 1 else str(v)))
            w.valueChanged.connect(lambda v, s=scale, k=p.key, kind=p.kind:
                                   self.param_changed.emit(eid, k, v / s if kind == "float" else v))
            lay.addWidget(w)
        elif p.kind == "text":
            lay.addWidget(ctl_label(p.label))
            w = QLineEdit(str(value))
            w.setMaxLength(200)
            w.textChanged.connect(self._emit(eid, p.key))
            lay.addWidget(w)
        return box

    def _pattern_tools(self, eid: str) -> QWidget:
        box = QWidget()
        lay = QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(8)
        hint = QLabel("Click or drag on the pads to paint.\nRight-click to erase. Hardware pads toggle.")
        hint.setObjectName("Hint")
        lay.addWidget(hint)
        row = QHBoxLayout()
        for label, act in (("Clear", "clear"), ("Fill", "fill")):
            b = QPushButton(label)
            b.clicked.connect(lambda _=False, a=act: self.action.emit(eid, a))
            row.addWidget(b)
        lay.addLayout(row)
        return box


def _clear_layout(layout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        if item.widget():
            item.widget().deleteLater()
        elif item.layout():
            _clear_layout(item.layout())

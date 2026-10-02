"""Reusable, token-driven UI components.

Everything here paints itself (or is styled by theme.py) from design.py, so
the whole application shares one set of colours, sizes and states:
default / hover / pressed / selected (blue) / disabled / keyboard focus.
"""

from __future__ import annotations

import time
from typing import Callable, List, Optional, Sequence

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QAbstractButton, QColorDialog, QComboBox, QHBoxLayout, QLabel, QLineEdit, QSizePolicy, QSlider,
    QVBoxLayout, QWidget,
)

from . import icons
from .design import C, F, H, R, S


def _font(px: int, weight: int = QFont.Normal) -> QFont:
    f = QFont()
    f.setPixelSize(px)
    f.setWeight(QFont.Weight(weight))
    return f


def _state_bg(btn: QAbstractButton, base: str = C.CONTROL, checked: str = C.SELECT) -> QColor:
    if not btn.isEnabled():
        return C.q(C.FIELD)
    if btn.isCheckable() and btn.isChecked():
        return C.q(C.SELECT_HOVER if btn.underMouse() else checked)
    if btn.isDown():
        return C.q(C.CONTROL_PRESSED)
    if btn.underMouse():
        return C.q(C.CONTROL_HOVER)
    return C.q(base)


def _focus_ring(p: QPainter, w: QWidget, rect: QRectF, radius: float) -> None:
    if w.hasFocus() and w.focusPolicy() != Qt.NoFocus and getattr(w, "_kbd_focus", False):
        p.setPen(QPen(C.q(C.FOCUS), 1.5))
        p.setBrush(Qt.NoBrush)
        p.drawRoundedRect(rect.adjusted(0.75, 0.75, -0.75, -0.75), radius, radius)


class _FocusMixin:
    """Show the focus ring only for keyboard focus (like macOS)."""

    def focusInEvent(self, e):  # noqa: N802
        self._kbd_focus = e.reason() in (Qt.TabFocusReason, Qt.BacktabFocusReason)
        super().focusInEvent(e)
        self.update()

    def focusOutEvent(self, e):  # noqa: N802
        self._kbd_focus = False
        super().focusOutEvent(e)
        self.update()


# ----------------------------------------------------------------------------
# Buttons
# ----------------------------------------------------------------------------
class IconButton(_FocusMixin, QAbstractButton):
    """Small square toolbar button with a vector icon (or short text).

    ``accent`` colours the icon (e.g. green Play) instead of the default grey.
    ``flat`` draws no background until hovered (for in-row buttons).
    """

    def __init__(self, icon: str = "", text: str = "", tooltip: str = "", size: int = H.ICON_BUTTON,
                 accent: Optional[str] = None, checkable: bool = False, flat: bool = False,
                 icon_size: float = 14, parent=None) -> None:
        super().__init__(parent)
        self._icon, self._accent, self._flat, self._icon_size = icon, accent, flat, icon_size
        self._kbd_focus = False
        self.setText(text)
        self.setToolTip(tooltip)
        self.setCheckable(checkable)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.TabFocus)
        w = size if not text else max(size, 16 + len(text) * 7)
        self.setFixedSize(w, size)
        self.setAttribute(Qt.WA_Hover)

    def set_icon(self, name: str) -> None:
        self._icon = name
        self.update()

    def enterEvent(self, e):  # noqa: N802
        self.update(); super().enterEvent(e)

    def leaveEvent(self, e):  # noqa: N802
        self.update(); super().leaveEvent(e)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        checked = self.isCheckable() and self.isChecked()
        if not self._flat or self.underMouse() or checked or self.isDown():
            p.setPen(QPen(C.q(C.SELECT if checked else C.BORDER_STRONG), 1))
            p.setBrush(_state_bg(self))
            p.drawRoundedRect(r, R.CONTROL, R.CONTROL)
        if not self.isEnabled():
            color = C.q(C.TEXT_DISABLED)
        elif checked:
            color = QColor("white")
        elif self._accent:
            color = C.q(self._accent)
        else:
            color = C.q(C.TEXT if self.underMouse() else "#C3C7CC")
        if self._icon:
            icons.draw(p, self._icon, r, color, self._icon_size)
        elif self.text():
            p.setFont(_font(F.TOOLBAR, QFont.Medium))
            p.setPen(color)
            p.drawText(r, Qt.AlignCenter, self.text())
        _focus_ring(p, self, r, R.CONTROL)


class ToolbarGroup(QWidget):
    """Buttons joined into one bordered strip (transport style)."""

    def __init__(self, buttons: Sequence[QWidget], parent=None) -> None:
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        for b in buttons:
            lay.addWidget(b)


# ----------------------------------------------------------------------------
# Segmented control / tabs
# ----------------------------------------------------------------------------
class SegmentedControl(_FocusMixin, QWidget):
    """Joined exclusive segments; the selected one is macOS blue.

    ``items`` are labels, or ``("icon:name", tooltip)`` tuples for icon segments.
    """

    changed = Signal(str)

    def __init__(self, items: Sequence, current: Optional[str] = None, height: int = H.TABS,
                 min_segment: int = 0, stretch: bool = True, parent=None) -> None:
        super().__init__(parent)
        self._items: List[tuple] = [(i, "") if isinstance(i, str) else tuple(i) for i in items]
        self._keys = [k for k, _ in self._items]
        self._current = current if current in self._keys else self._keys[0]
        self._hover = -1
        self._kbd_focus = False
        self._min = min_segment
        self.setFixedHeight(height)
        self.setMouseTracking(True)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.TabFocus)
        if stretch:
            self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        else:
            self.setFixedWidth(max(min_segment, 30) * len(self._items))

    def current(self) -> str:
        return self._current

    def set_current(self, key: str, emit: bool = False) -> None:
        if key in self._keys and key != self._current:
            self._current = key
            self.update()
            if emit:
                self.changed.emit(key)

    def sizeHint(self) -> QSize:  # noqa: N802
        return QSize(max(self._min, 64) * len(self._items), self.height())

    def _seg(self, i: int) -> QRectF:
        w = self.width() / len(self._items)
        return QRectF(i * w, 0, w, self.height())

    def _index_at(self, x: float) -> int:
        return max(0, min(len(self._items) - 1, int(x / (self.width() / len(self._items)))))

    def mouseMoveEvent(self, e):  # noqa: N802
        i = self._index_at(e.position().x())
        if i != self._hover:
            self._hover = i
            self.update()
        key, tip = self._items[i]
        self.setToolTip(tip)

    def leaveEvent(self, _e):  # noqa: N802
        self._hover = -1
        self.update()

    def mousePressEvent(self, e):  # noqa: N802
        self.set_current(self._keys[self._index_at(e.position().x())], emit=True)

    def keyPressEvent(self, e):  # noqa: N802
        i = self._keys.index(self._current)
        if e.key() in (Qt.Key_Left, Qt.Key_Up):
            self.set_current(self._keys[max(0, i - 1)], emit=True)
        elif e.key() in (Qt.Key_Right, Qt.Key_Down):
            self.set_current(self._keys[min(len(self._keys) - 1, i + 1)], emit=True)
        else:
            super().keyPressEvent(e)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        outer = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(C.q(C.BORDER_STRONG), 1))
        p.setBrush(C.q(C.CONTROL))
        p.drawRoundedRect(outer, R.CONTROL, R.CONTROL)
        p.setFont(_font(F.LABEL))
        for i, (key, _tip) in enumerate(self._items):
            r = self._seg(i).adjusted(0.5, 0.5, -0.5, -0.5)
            sel = key == self._current
            if sel or i == self._hover:
                p.setPen(Qt.NoPen)
                p.setBrush(C.q(C.SELECT if sel else C.CONTROL_HOVER))
                p.drawRoundedRect(r, R.CONTROL, R.CONTROL)
            if i > 0 and not sel and self._keys[i - 1] != self._current:
                p.setPen(QPen(C.q(C.BORDER_STRONG), 1))
                p.drawLine(QPointF(r.left(), r.top() + 6), QPointF(r.left(), r.bottom() - 6))
            color = QColor("white") if sel else C.q(C.TEXT_2 if i != self._hover else C.TEXT)
            if key.startswith("icon:"):
                icons.draw(p, key[5:], r, color, 14)
            else:
                p.setPen(color)
                p.drawText(r, Qt.AlignCenter, key)
        _focus_ring(p, self, outer, R.CONTROL)


# ----------------------------------------------------------------------------
# Inspector sections
# ----------------------------------------------------------------------------
class _SectionHeader(QWidget):
    clicked = Signal()

    def __init__(self, title: str, parent=None) -> None:
        super().__init__(parent)
        self.title = title.upper()
        self.expanded = True
        self.setFixedHeight(H.SECTION)
        self.setCursor(Qt.PointingHandCursor)

    def mousePressEvent(self, _e):  # noqa: N802
        self.clicked.emit()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), C.q(C.SECTION))
        p.setPen(C.q(C.SEPARATOR))
        p.drawLine(0, 0, self.width(), 0)
        p.drawLine(0, self.height() - 1, self.width(), self.height() - 1)
        icons.draw(p, "tri_down" if self.expanded else "tri_right", QRectF(8, 0, 14, self.height()),
                   C.q(C.TEXT_2), 11)
        f = _font(F.SECTION, QFont.Medium)
        f.setLetterSpacing(QFont.AbsoluteSpacing, 1.0)
        p.setFont(f)
        p.setPen(C.q(C.TEXT_2))
        p.drawText(QRectF(28, 0, self.width() - 36, self.height()), Qt.AlignVCenter | Qt.AlignLeft, self.title)


class InspectorSection(QWidget):
    """Collapsible property section: ▾ TITLE header + flat body (no cards)."""

    toggled = Signal(str, bool)

    def __init__(self, title: str, expanded: bool = True, parent=None) -> None:
        super().__init__(parent)
        self.key = title
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.header = _SectionHeader(title)
        self.header.clicked.connect(self.toggle)
        lay.addWidget(self.header)
        self.body = QWidget()
        self.body_layout = QVBoxLayout(self.body)
        self.body_layout.setContentsMargins(S.LG, S.MD + 2, S.LG, S.LG)
        self.body_layout.setSpacing(S.MD + 2)
        lay.addWidget(self.body)
        self.set_expanded(expanded)

    def add(self, w: QWidget) -> QWidget:
        self.body_layout.addWidget(w)
        return w

    def add_layout(self, l) -> None:
        self.body_layout.addLayout(l)

    def set_expanded(self, on: bool) -> None:
        self.header.expanded = on
        self.body.setVisible(on)
        self.header.update()

    def toggle(self) -> None:
        self.set_expanded(not self.header.expanded)
        self.toggled.emit(self.key, self.header.expanded)


# ----------------------------------------------------------------------------
# Parameter controls
# ----------------------------------------------------------------------------
class ParameterSlider(QWidget):
    """Label ............ value / thin slider / optional end captions."""

    valueChanged = Signal(int)

    def __init__(self, label: str, minimum: int, maximum: int, value: int,
                 fmt: Callable[[int], str] = str, left: str = "", right: str = "", parent=None) -> None:
        super().__init__(parent)
        self._fmt = fmt
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(3)
        top = QHBoxLayout()
        top.setSpacing(S.SM)
        self.label = QLabel(label)
        self.label.setObjectName("Param")
        top.addWidget(self.label)
        top.addStretch(1)
        self.value_label = QLabel()
        self.value_label.setObjectName("Value")
        top.addWidget(self.value_label)
        lay.addLayout(top)
        self.slider = QSlider(Qt.Horizontal)
        self.slider.setRange(minimum, maximum)
        self.slider.setValue(value)
        self.slider.setFocusPolicy(Qt.TabFocus)
        self.slider.valueChanged.connect(self._changed)
        lay.addWidget(self.slider)
        if left or right:
            ends = QHBoxLayout()
            a, b = QLabel(left), QLabel(right)
            a.setObjectName("Caption")
            b.setObjectName("Caption")
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

    def setValue(self, v: int) -> None:  # noqa: N802
        self.slider.setValue(v)


class ToggleSwitch(_FocusMixin, QAbstractButton):
    """macOS-scale switch (30 x 17)."""

    def __init__(self, checked: bool = False, parent=None) -> None:
        super().__init__(parent)
        self._kbd_focus = False
        self.setCheckable(True)
        self.setChecked(checked)
        self.setFixedSize(30, 17)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.TabFocus)

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        on = self.isChecked()
        track = C.q(C.SELECT if on else "#1F2225")
        if not self.isEnabled():
            track.setAlpha(110)
        p.setPen(QPen(C.q(C.SELECT if on else C.BORDER_STRONG), 1))
        p.setBrush(track)
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        d = r.height() - 3
        x = r.right() - d - 1.5 if on else r.left() + 1.5
        p.setPen(Qt.NoPen)
        p.setBrush(QColor("#FFFFFF") if on else QColor("#C9CDD2"))
        p.drawEllipse(QRectF(x, r.top() + 1.5, d, d))
        _focus_ring(p, self, r, r.height() / 2)


class ToggleRow(QWidget):
    """[switch] Label — the whole row is clickable."""

    toggled = Signal(bool)

    def __init__(self, text: str, checked: bool = False, tooltip: str = "", parent=None) -> None:
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(S.MD + 2)
        self.switch = ToggleSwitch(checked)
        self.switch.toggled.connect(self.toggled)
        lay.addWidget(self.switch)
        self.label = QLabel(text)
        self.label.setObjectName("Param")
        lay.addWidget(self.label, 1)
        self.setToolTip(tooltip)
        self.setFixedHeight(22)
        self.setCursor(Qt.PointingHandCursor)

    def mousePressEvent(self, _e):  # noqa: N802
        self.switch.toggle()

    def isChecked(self) -> bool:  # noqa: N802
        return self.switch.isChecked()

    def setChecked(self, v: bool) -> None:  # noqa: N802
        self.switch.setChecked(v)


class ChoiceRow(QWidget):
    """Label on the left, compact popup on the right."""

    changed = Signal(str)

    def __init__(self, label: str, options: Sequence[str], current: str, parent=None) -> None:
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(S.MD)
        lbl = QLabel(label)
        lbl.setObjectName("Param")
        lay.addWidget(lbl)
        lay.addStretch(1)
        self.combo = ChevronCombo()
        self.combo.addItems(list(options))
        self.combo.setCurrentText(current)
        self.combo.setMinimumWidth(150)
        self.combo.currentTextChanged.connect(self.changed)
        lay.addWidget(self.combo, 2)

    def set_value(self, v: str) -> None:
        self.combo.blockSignals(True)
        self.combo.setCurrentText(v)
        self.combo.blockSignals(False)


class ChevronCombo(QComboBox):
    """QComboBox with a crisp vector chevron (no default arrow)."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setFocusPolicy(Qt.TabFocus)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedHeight(H.CONTROL)

    def paintEvent(self, e) -> None:
        super().paintEvent(e)
        p = QPainter(self)
        icons.draw(p, "chevron_down", QRectF(self.width() - 20, 0, 14, self.height()), C.q(C.TEXT_2), 12)


class ColorSwatch(_FocusMixin, QAbstractButton):
    """Colour chip; selected = thin white ring + blue outline."""

    def __init__(self, color: str, size: int = H.SWATCH, picker: bool = False, parent=None) -> None:
        super().__init__(parent)
        self.color = color
        self.picker = picker
        self._kbd_focus = False
        self.setCheckable(True)
        self.setFixedSize(size, size)
        self.setCursor(Qt.PointingHandCursor)
        self.setFocusPolicy(Qt.TabFocus)
        self.setToolTip("Custom colour…" if picker else color.upper())

    def set_color(self, c: str) -> None:
        self.color = c
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(2, 2, -2, -2)
        p.setPen(QPen(QColor(0, 0, 0, 120), 1))
        p.setBrush(QColor(self.color))
        p.drawRoundedRect(r, R.SWATCH, R.SWATCH)
        if self.picker:
            icons.draw(p, "eyedropper" if False else "plus", r, QColor(255, 255, 255, 200)
                       if QColor(self.color).lightness() < 150 else QColor(0, 0, 0, 170), 11)
        if self.isChecked():
            p.setBrush(Qt.NoBrush)
            p.setPen(QPen(QColor("white"), 1.2))
            p.drawRoundedRect(r.adjusted(0.6, 0.6, -0.6, -0.6), R.SWATCH, R.SWATCH)
            p.setPen(QPen(C.q(C.SELECT_HOVER), 1.6))
            p.drawRoundedRect(QRectF(self.rect()).adjusted(0.8, 0.8, -0.8, -0.8), R.SWATCH + 1, R.SWATCH + 1)
        elif self.underMouse():
            p.setBrush(Qt.NoBrush)
            p.setPen(QPen(QColor(255, 255, 255, 120), 1))
            p.drawRoundedRect(r, R.SWATCH, R.SWATCH)
        _focus_ring(p, self, QRectF(self.rect()), R.SWATCH + 1)


QUICK_COLORS = ["#ff0000", "#ff7a00", "#ffe600", "#00d23c", "#00aaff", "#3a2cff", "#c000ff", "#ffffff", "#1f1f1f"]


class SwatchRow(QWidget):
    """[custom] + preset colour chips; emits the chosen colour."""

    changed = Signal(str)

    def __init__(self, value: str, colors: Sequence[str] = QUICK_COLORS, parent=None) -> None:
        super().__init__(parent)
        self._value = value.lower()
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(2)
        self.custom = ColorSwatch(self._value, picker=True)
        self.custom.clicked.connect(self._pick)
        lay.addWidget(self.custom)
        self.chips: List[ColorSwatch] = []
        for c in colors:
            sw = ColorSwatch(c)
            sw.clicked.connect(lambda _=False, col=c: self._set(col))
            lay.addWidget(sw)
            self.chips.append(sw)
        lay.addStretch(1)
        self._dialog: Optional[QColorDialog] = None
        self._sync()

    def value(self) -> str:
        return self._value

    def _sync(self) -> None:
        match = False
        for sw in self.chips:
            on = sw.color.lower() == self._value
            match = match or on
            sw.setChecked(on)
        self.custom.set_color(self._value)
        self.custom.setChecked(not match)

    def set_value(self, value: str, emit: bool = False) -> None:
        value = value.lower()
        if value != self._value:
            self._value = value
            self._sync()
            if emit:
                self.changed.emit(value)
        else:
            self._sync()

    def _set(self, value: str) -> None:
        self.set_value(value, emit=True)

    def _pick(self) -> None:
        self._sync()
        if self._dialog is None:
            self._dialog = QColorDialog(QColor(self._value), self.window())
            self._dialog.setWindowTitle("Choose Colour")
            self._dialog.currentColorChanged.connect(lambda c: self._set(c.name()))
        else:
            self._dialog.setCurrentColor(QColor(self._value))
        self._dialog.show()
        self._dialog.raise_()

    def close_dialog(self) -> None:
        if self._dialog is not None:
            self._dialog.close()


# ----------------------------------------------------------------------------
# Status & telemetry
# ----------------------------------------------------------------------------
class StatusIndicator(QWidget):
    """● Text — small coloured dot + label."""

    def __init__(self, text: str = "", color: str = C.TEXT_3, font_px: int = F.TOOLBAR, parent=None) -> None:
        super().__init__(parent)
        self._text, self._color, self._px = text, color, font_px
        self.setMinimumHeight(18)

    def set_state(self, text: str, color: str) -> None:
        self._text, self._color = text, color
        self.updateGeometry()
        self.update()

    def sizeHint(self) -> QSize:  # noqa: N802
        from PySide6.QtGui import QFontMetrics
        return QSize(18 + QFontMetrics(_font(self._px)).horizontalAdvance(self._text) + 4, 18)

    minimumSizeHint = sizeHint

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        cy = self.height() / 2
        c = C.q(self._color)
        halo = QColor(c)
        halo.setAlpha(60)
        p.setPen(Qt.NoPen)
        p.setBrush(halo)
        p.drawEllipse(QPointF(6, cy), 5, 5)
        p.setBrush(c)
        p.drawEllipse(QPointF(6, cy), 3.5, 3.5)
        p.setFont(_font(self._px))
        p.setPen(C.q(C.TEXT if self._color != C.TEXT_3 else C.TEXT_2))
        p.drawText(QRectF(18, 0, self.width() - 18, self.height()), Qt.AlignVCenter | Qt.AlignLeft, self._text)


class MidiActivityMeter(QWidget):
    """Horizontal activity bar that jumps on traffic and decays smoothly."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.level = 0.0
        self._last = time.monotonic()
        self.setFixedSize(130, 7)

    def hit(self, amount: float) -> None:
        self.level = min(1.0, max(self.level, amount))

    def tick(self) -> None:
        now = time.monotonic()
        dt, self._last = now - self._last, now
        if self.level > 0:
            self.level = max(0.0, self.level - dt * 1.8)
            self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(QColor(0, 0, 0, 120), 1))
        p.setBrush(QColor("#1D2023"))
        p.drawRoundedRect(r, 2, 2)
        if self.level > 0.01:
            w = (r.width() - 2) * self.level
            p.setPen(Qt.NoPen)
            p.setBrush(C.q(C.METER if self.level < 0.85 else C.METER_HOT))
            p.drawRoundedRect(QRectF(r.left() + 1, r.top() + 1, w, r.height() - 2), 1.5, 1.5)


class SearchField(QLineEdit):
    def __init__(self, placeholder: str, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Search")
        self.setPlaceholderText(placeholder)
        self.setClearButtonEnabled(True)
        self.setFixedHeight(H.SEARCH)

    def paintEvent(self, e) -> None:
        super().paintEvent(e)
        p = QPainter(self)
        icons.draw(p, "search", QRectF(6, 0, 14, self.height()), C.q(C.TEXT_3), 13)


def hline() -> QWidget:
    w = QWidget()
    w.setFixedHeight(1)
    w.setStyleSheet(f"background: {C.SEPARATOR};")
    return w


def vline(height: int = 24) -> QWidget:
    w = QWidget()
    w.setFixedSize(1, height)
    w.setStyleSheet(f"background: {C.BORDER_STRONG};")
    return w

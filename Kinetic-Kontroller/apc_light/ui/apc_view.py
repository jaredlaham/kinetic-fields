"""On-screen APC mini mk2: mirrors what the hardware LEDs show."""

from __future__ import annotations

import math
import time
from typing import List, Optional

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen, QPixmap, QRadialGradient
from PySide6.QtWidgets import QSizePolicy, QWidget

from ..engine.frame import OFF, Pad

# Seconds per cycle for the hardware pulse/blink rates, assuming the APC's
# internal 120 BPM clock (1/4 = one beat). Only used for the on-screen mirror.
_RATE_SECONDS = {"1/2": 1.0, "1/4": 0.5, "1/8": 0.25, "1/16": 0.125, "1/24": 0.0833}

PAD_OFF = QColor("#23252a")
PAD_OFF_EDGE = QColor("#2e3137")
BODY = QColor("#18191c")
BODY_EDGE = QColor("#2a2c31")


def pad_color(pad: Pad, now: float) -> Optional[QColor]:
    if pad.is_off:
        return None
    r, g, b = pad.rgb
    if pad.mode == "pulse":
        period = _RATE_SECONDS.get(pad.rate, 0.5)
        k = 0.2 + 0.8 * (0.5 + 0.5 * math.cos(2 * math.pi * now / period))
        return QColor(int(r * k), int(g * k), int(b * k))
    if pad.mode == "blink":
        period = _RATE_SECONDS.get(pad.rate, 0.5)
        if (now / period) % 1.0 >= 0.5:
            return None
    return QColor(r, g, b)


class ApcView(QWidget):
    pad_pressed = Signal(int, int, str)  # x, y, "left"/"right"
    pad_released = Signal(int, int)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(360, 380)
        self.setMouseTracking(True)
        self._pads: List[Pad] = [OFF] * 64
        self._scene_led: Optional[int] = None
        self._connected = False
        self._paint_mode = False
        self._hover: Optional[tuple] = None
        self._drag_button: Optional[str] = None
        self._last_drag: Optional[tuple] = None
        self._anim = QTimer(self)
        self._anim.setInterval(33)
        self._anim.timeout.connect(self.update)

    # -- data ------------------------------------------------------------
    def set_pads(self, pads: List[Pad]) -> None:
        self._pads = pads
        needs_anim = any(p.mode != "solid" and not p.is_off for p in pads)
        if needs_anim and not self._anim.isActive():
            self._anim.start()
        elif not needs_anim and self._anim.isActive():
            self._anim.stop()
        self.update()

    def set_scene_led(self, index: Optional[int]) -> None:
        self._scene_led = index
        self.update()

    def set_connected(self, connected: bool) -> None:
        self._connected = connected
        self.update()

    def set_touch_mode(self, enabled: bool) -> None:
        """Pads are clickable (paint / touch reactions) for the active effect."""
        if not enabled:
            self._release_drag()
        self._paint_mode = enabled
        self.setCursor(Qt.PointingHandCursor if enabled else Qt.ArrowCursor)
        self.update()

    set_paint_mode = set_touch_mode

    # -- geometry ----------------------------------------------------------
    def _layout(self):
        """Device body rect and pad pitch, keeping the real APC proportions."""
        w, h = self.width(), self.height()
        # 8 pads + scene column (~0.8 pitch) wide; 8 pads + track row + faders tall.
        units_w, units_h = 8 + 1.1 + 0.9, 8 + 0.9 + 2.2 + 0.9
        pitch = min((w - 24) / units_w, (h - 24) / units_h)
        bw, bh = pitch * units_w, pitch * units_h
        body = QRectF((w - bw) / 2, (h - bh) / 2, bw, bh)
        origin = QPointF(body.left() + pitch * 0.45, body.top() + pitch * 0.9)
        return body, origin, pitch

    def _pad_rect(self, x: int, y: int, origin: QPointF, pitch: float) -> QRectF:
        gap = pitch * 0.14
        return QRectF(origin.x() + x * pitch + gap / 2, origin.y() + y * pitch + gap / 2, pitch - gap, pitch - gap)

    def _hit(self, pos) -> Optional[tuple]:
        _, origin, pitch = self._layout()
        x = int((pos.x() - origin.x()) // pitch)
        y = int((pos.y() - origin.y()) // pitch)
        if 0 <= x < 8 and 0 <= y < 8:
            return x, y
        return None

    # -- painting ------------------------------------------------------------
    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        body, origin, pitch = self._layout()
        now = time.monotonic()

        # device body
        p.setPen(QPen(BODY_EDGE, 1.2))
        p.setBrush(BODY)
        p.drawRoundedRect(body, pitch * 0.35, pitch * 0.35)

        # label + connection LED
        f = QFont(self.font())
        f.setPixelSize(max(9, int(pitch * 0.22)))
        f.setBold(True)
        f.setLetterSpacing(QFont.AbsoluteSpacing, 1.5)
        p.setFont(f)
        p.setPen(QColor("#9aa0a8"))
        p.drawText(QRectF(origin.x(), body.top() + pitch * 0.2, pitch * 6, pitch * 0.5),
                   Qt.AlignLeft | Qt.AlignVCenter, "AKAI  APC mini mk2")
        led_c = QColor("#39d98a") if self._connected else QColor("#4a2020")
        p.setPen(Qt.NoPen)
        p.setBrush(led_c)
        p.drawEllipse(QPointF(origin.x() + pitch * 7.7, body.top() + pitch * 0.45), pitch * 0.07, pitch * 0.07)

        # glow pass (under pads)
        lit = []
        for i, pad in enumerate(self._pads):
            c = pad_color(pad, now)
            if c is not None:
                lit.append((i, c))
                rect = self._pad_rect(i % 8, i // 8, origin, pitch)
                g = QRadialGradient(rect.center(), pitch * 0.95)
                glow = QColor(c)
                glow.setAlpha(80)
                g.setColorAt(0.0, glow)
                glow.setAlpha(0)
                g.setColorAt(1.0, glow)
                p.setBrush(g)
                p.drawEllipse(rect.center(), pitch * 0.95, pitch * 0.95)

        # pads
        radius = pitch * 0.12
        lit_map = dict(lit)
        for i in range(64):
            x, y = i % 8, i // 8
            rect = self._pad_rect(x, y, origin, pitch)
            c = lit_map.get(i)
            if c is None:
                p.setPen(QPen(PAD_OFF_EDGE, 1))
                p.setBrush(PAD_OFF)
                p.drawRoundedRect(rect, radius, radius)
            else:
                p.setPen(QPen(c.lighter(130), 1))
                p.setBrush(c)
                p.drawRoundedRect(rect, radius, radius)
                # soft specular
                hl = QColor(255, 255, 255, 38)
                p.setPen(Qt.NoPen)
                p.setBrush(hl)
                p.drawRoundedRect(QRectF(rect.left() + 2, rect.top() + 2, rect.width() - 4, rect.height() * 0.35),
                                  radius, radius)
            if self._paint_mode and self._hover == (x, y):
                p.setPen(QPen(QColor("#ffffff"), 1.5, Qt.DashLine))
                p.setBrush(Qt.NoBrush)
                p.drawRoundedRect(rect.adjusted(-2, -2, 2, 2), radius, radius)

        # scene launch column (green LEDs)
        for i in range(8):
            rect = self._pad_rect(8, i, origin, pitch)
            cx = rect.center().x() + pitch * 0.15
            r = pitch * 0.2
            on = self._scene_led == i
            p.setPen(QPen(QColor("#2e3137"), 1))
            p.setBrush(QColor("#39d98a") if on else QColor("#1e2a22"))
            p.drawRoundedRect(QRectF(cx - r * 1.3, rect.center().y() - r * 0.6, r * 2.6, r * 1.2), r * 0.3, r * 0.3)

        # track button row (red LEDs) + shift
        ty = origin.y() + pitch * 8 + pitch * 0.25
        for i in range(8):
            rect = QRectF(origin.x() + i * pitch + pitch * 0.18, ty, pitch * 0.64, pitch * 0.26)
            p.setPen(QPen(QColor("#2e3137"), 1))
            p.setBrush(QColor("#2a1a1a"))
            p.drawRoundedRect(rect, 3, 3)
        p.setBrush(QColor("#26282c"))
        p.drawRoundedRect(QRectF(origin.x() + 8 * pitch + pitch * 0.05, ty, pitch * 0.64, pitch * 0.26), 3, 3)

        # 9 faders
        fy = ty + pitch * 0.6
        fh = pitch * 2.0
        for i in range(9):
            cx = origin.x() + i * pitch + pitch * 0.5
            p.setPen(QPen(QColor("#0b0c0d"), max(2.0, pitch * 0.07), Qt.SolidLine, Qt.RoundCap))
            p.drawLine(QPointF(cx, fy), QPointF(cx, fy + fh))
            p.setPen(QPen(QColor("#3a3d44"), 1))
            p.setBrush(QColor("#2c2f35"))
            p.drawRoundedRect(QRectF(cx - pitch * 0.2, fy + fh * 0.55, pitch * 0.4, pitch * 0.22), 2, 2)
        p.end()

    # -- interaction ---------------------------------------------------------
    def mousePressEvent(self, e) -> None:
        if not self._paint_mode:
            return
        hit = self._hit(e.position())
        if hit:
            self._drag_button = "right" if e.button() == Qt.RightButton else "left"
            self._last_drag = hit
            self.pad_pressed.emit(hit[0], hit[1], self._drag_button)

    def mouseMoveEvent(self, e) -> None:
        hit = self._hit(e.position())
        if hit != self._hover:
            self._hover = hit
            if self._paint_mode:
                self.update()
        if self._drag_button and hit and hit != self._last_drag:
            # Dragging = release the previous pad, press the new one.
            if self._last_drag:
                self.pad_released.emit(*self._last_drag)
            self._last_drag = hit
            self.pad_pressed.emit(hit[0], hit[1], self._drag_button)

    def mouseReleaseEvent(self, _e) -> None:
        self._release_drag()

    def _release_drag(self) -> None:
        if self._last_drag:
            self.pad_released.emit(*self._last_drag)
        self._drag_button = None
        self._last_drag = None

    def leaveEvent(self, _e) -> None:
        self._hover = None
        self.update()


def frame_thumbnail(pads: List[Pad], size: int = 30) -> QPixmap:
    """Small 8x8 preview used in the scene library."""
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, size, size), 5, 5)
    p.fillPath(path, QColor("#0b0c0e"))
    cell = (size - 4) / 8
    for i, pad in enumerate(pads):
        x, y = i % 8, i // 8
        c = QColor(*pad.rgb) if not pad.is_off else QColor("#1f2125")
        p.fillRect(QRectF(2 + x * cell + 0.4, 2 + y * cell + 0.4, cell - 0.8, cell - 0.8), c)
    p.end()
    return pm

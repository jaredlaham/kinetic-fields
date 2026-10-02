"""On-screen APC mini mk2: the tactile hero object in the workspace.

The surrounding UI is flat; the hardware is physical: walnut side panels,
charcoal faceplate, recessed pad well, softly lit pads, grey scene buttons,
red track buttons and metallic faders, floating over the dark workspace.

The static body is rendered once per size into a cached pixmap; only the
pads (and scene LEDs) are painted per frame, so 50 fps LED updates are cheap.
"""

from __future__ import annotations

import math
import random
import time
from typing import List, Optional

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import (
    QColor, QFont, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap, QRadialGradient,
)
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtWidgets import QSizePolicy, QWidget

from ..engine.frame import OFF, Pad

# Seconds per cycle for the hardware pulse/blink rates (APC internal 120 BPM).
_RATE_SECONDS = {"1/2": 1.0, "1/4": 0.5, "1/8": 0.25, "1/16": 0.125, "1/24": 0.0833}

# Pad geometry. Proportions below are in units of the column pitch
# (pad width + gutter). Pads are 5:4 (1.25:1, wider than tall) and the gutter
# between pads is the same horizontally and vertically.
PAD_ASPECT = 1.25
_GUTTER = 0.13                     # gap between pads (both directions)
_PAD_W = 1.0 - _GUTTER             # pad width
_PAD_H = _PAD_W / PAD_ASPECT       # pad height
_ROW = _PAD_H + _GUTTER            # row pitch
_GRID_W = 8 - _GUTTER              # outer size of the 8x8 grid
_GRID_H = 8 * _ROW - _GUTTER

# Device proportions.
_WOOD = 0.78          # side panel width
_PLATE_PAD_X = 0.55   # faceplate margin left of the grid
_TOP = 1.05           # logo band above the grid
_SCENE = 1.25         # scene-button column
_TRACK = 0.95         # track-button row
_FADERS = 2.55        # fader area
_BOTTOM = 0.45
_UNITS_W = _WOOD * 2 + _PLATE_PAD_X + 8 + _SCENE + 0.2
_UNITS_H = _TOP + _GRID_H + _TRACK + _FADERS + _BOTTOM
_HEIGHT_SHARE = 0.72  # of the canvas height (generous negative space)


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
    fader_moved = Signal(int, float)     # index 0..8, value 0..1 (on-screen drag)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(360, 420)
        self.setMouseTracking(True)
        self._pads: List[Pad] = [OFF] * 64
        self._scene_states: List[int] = [0] * 8   # 0 off, 1 on, 2 blink
        self._faders: List[float] = [0.5] * 9
        self._fader_drag: Optional[int] = None
        self._connected = False
        self._paint_mode = False
        self._hover: Optional[tuple] = None
        self._drag_button: Optional[str] = None
        self._last_drag: Optional[tuple] = None
        self._body: Optional[QPixmap] = None
        self._body_key = None
        self._topo: Optional[QSvgRenderer] = None
        self._topo_opacity = 0.0
        self._topo_pm: Optional[QPixmap] = None
        self._topo_key = None
        self._anim = QTimer(self)
        self._anim.setInterval(33)
        self._anim.timeout.connect(self.update)

    # -- data ----------------------------------------------------------------------
    def set_pads(self, pads: List[Pad]) -> None:
        self._pads = pads
        needs_anim = any(p.mode != "solid" and not p.is_off for p in pads) or 2 in self._scene_states
        if needs_anim and not self._anim.isActive():
            self._anim.start()
        elif not needs_anim and self._anim.isActive():
            self._anim.stop()
        self.update()

    def set_scene_led(self, index: Optional[int]) -> None:
        self.set_scene_leds([1 if i == index else 0 for i in range(8)])

    def set_scene_leds(self, states) -> None:
        states = list(states)[:8]
        if states != self._scene_states:
            self._scene_states = states
            if 2 in states and not self._anim.isActive():
                self._anim.start()
            self.update()

    def set_fader(self, index: int, value: float) -> None:
        if 0 <= index < 9 and self._fader_drag != index:
            self._faders[index] = max(0.0, min(1.0, value))
            self.update()

    def _fader_geometry(self, i: int, grid: QPointF, pitch: float):
        """(centre x, top y, height) of fader ``i``."""
        ty = grid.y() + _GRID_H * pitch + pitch * 0.34
        fy = ty + pitch * _TRACK * 0.72
        fh = pitch * (_FADERS - 0.35)
        return grid.x() + i * pitch + _PAD_W * pitch / 2, fy, fh

    def _fader_hit(self, pos) -> Optional[int]:
        _, grid, pitch = self._geometry()
        for i in range(9):
            cx, fy, fh = self._fader_geometry(i, grid, pitch)
            if abs(pos.x() - cx) <= pitch * 0.4 and fy - pitch * 0.2 <= pos.y() <= fy + fh + pitch * 0.2:
                return i
        return None

    def _fader_value_at(self, i: int, y: float) -> float:
        _, grid, pitch = self._geometry()
        _, fy, fh = self._fader_geometry(i, grid, pitch)
        top, travel = fy + fh * 0.08, fh * 0.84
        return max(0.0, min(1.0, 1.0 - (y - top) / travel))

    def set_connected(self, connected: bool) -> None:
        self._connected = connected
        self.update()

    def set_background(self, svg_path: Optional[str], opacity: float) -> bool:
        """Topographic pattern filling the workspace behind the APC.
        ``opacity`` 0..1. Returns False if the SVG could not be loaded."""
        ok = True
        if svg_path != getattr(self, "_topo_path", None):
            self._topo_path = svg_path
            self._topo = None
            if svg_path:
                r = QSvgRenderer(svg_path)
                if r.isValid():
                    r.setAspectRatioMode(Qt.KeepAspectRatioByExpanding)
                    self._topo = r
                else:
                    ok = False
            self._topo_pm = None
        self._topo_opacity = max(0.0, min(1.0, opacity))
        self.update()
        return ok

    def _render_topo(self) -> Optional[QPixmap]:
        if self._topo is None:
            return None
        dpr = self.devicePixelRatioF()
        key = (self.width(), self.height(), dpr)
        if self._topo_pm is not None and self._topo_key == key:
            return self._topo_pm
        pm = QPixmap(int(self.width() * dpr), int(self.height() * dpr))
        pm.setDevicePixelRatio(dpr)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        # "cover": fill the whole area, cropping the SVG's overflow, centred
        vb = self._topo.viewBoxF()
        if vb.isEmpty():
            vb = QRectF(0, 0, self._topo.defaultSize().width(), self._topo.defaultSize().height())
        s = max(self.width() / max(vb.width(), 1), self.height() / max(vb.height(), 1))
        w, h = vb.width() * s, vb.height() * s
        self._topo.render(p, QRectF((self.width() - w) / 2, (self.height() - h) / 2, w, h))
        p.end()
        self._topo_pm, self._topo_key = pm, key
        return pm

    def set_touch_mode(self, enabled: bool) -> None:
        """Pads are clickable (paint / touch reactions) for the active effect."""
        if not enabled:
            self._release_drag()
        self._paint_mode = enabled
        self.setCursor(Qt.PointingHandCursor if enabled else Qt.ArrowCursor)
        self.update()

    set_paint_mode = set_touch_mode

    # -- geometry -------------------------------------------------------------------
    def _geometry(self):
        w, h = self.width(), self.height()
        pitch = min(h * _HEIGHT_SHARE / _UNITS_H, (w * 0.9) / _UNITS_W)
        bw, bh = pitch * _UNITS_W, pitch * _UNITS_H
        body = QRectF((w - bw) / 2, (h - bh) / 2 - pitch * 0.15, bw, bh)
        grid = QPointF(body.left() + pitch * (_WOOD + _PLATE_PAD_X), body.top() + pitch * _TOP)
        return body, grid, pitch

    def _pad_rect(self, x: int, y: int, grid: QPointF, pitch: float) -> QRectF:
        """Pad (x, y); ``grid`` is the top-left corner of pad (0, 0)."""
        return QRectF(grid.x() + x * pitch, grid.y() + y * _ROW * pitch, _PAD_W * pitch, _PAD_H * pitch)

    def _hit(self, pos) -> Optional[tuple]:
        _, grid, pitch = self._geometry()
        g = _GUTTER * pitch / 2  # split each gutter between its neighbours
        x = int((pos.x() - grid.x() + g) // pitch)
        y = int((pos.y() - grid.y() + g) // (_ROW * pitch))
        return (x, y) if 0 <= x < 8 and 0 <= y < 8 else None

    # -- static body (cached) -----------------------------------------------------------
    def _render_body(self) -> QPixmap:
        dpr = self.devicePixelRatioF()
        key = (self.width(), self.height(), dpr)
        if self._body is not None and self._body_key == key:
            return self._body
        pm = QPixmap(int(self.width() * dpr), int(self.height() * dpr))
        pm.setDevicePixelRatio(dpr)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        body, grid, pitch = self._geometry()
        rad = pitch * 0.42

        # soft floating shadow
        for i in range(14, 0, -1):
            a = int(9 + (14 - i) * 1.2)
            spread = i * pitch * 0.07
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(0, 0, 0, a))
            p.drawRoundedRect(body.adjusted(-spread, -spread * 0.4 + pitch * 0.25, spread, spread + pitch * 0.35),
                              rad + spread, rad + spread)

        # walnut body
        wood = QLinearGradient(body.topLeft(), body.topRight())
        wood.setColorAt(0.0, QColor("#5B311A"))
        wood.setColorAt(0.08, QColor("#8B5431"))
        wood.setColorAt(0.5, QColor("#7A4526"))
        wood.setColorAt(0.92, QColor("#8B5431"))
        wood.setColorAt(1.0, QColor("#5B311A"))
        p.setBrush(wood)
        p.setPen(QPen(QColor("#2E190D"), 1))
        p.drawRoundedRect(body, rad, rad)
        # grain on the side panels
        rng = random.Random(3)
        for side in (0, 1):
            x0 = body.left() + (0 if side == 0 else body.width() - pitch * _WOOD)
            panel = QRectF(x0, body.top(), pitch * _WOOD, body.height())
            p.save()
            clip = QPainterPath()
            clip.addRoundedRect(body, rad, rad)
            p.setClipPath(clip)
            p.setClipRect(panel, Qt.IntersectClip)
            for k in range(22):
                gx = panel.left() + rng.random() * panel.width()
                amp = pitch * (0.03 + rng.random() * 0.08)
                freq = 1.5 + rng.random() * 3
                phase = rng.random() * 6.28
                path = QPainterPath(QPointF(gx, panel.top()))
                steps = 40
                for s in range(1, steps + 1):
                    yy = panel.top() + panel.height() * s / steps
                    path.lineTo(QPointF(gx + amp * math.sin(phase + freq * s / steps * 6.28), yy))
                shade = QColor(40, 18, 6, 40 + int(rng.random() * 50)) if k % 3 else QColor(190, 120, 70, 35)
                p.setPen(QPen(shade, 0.6 + rng.random() * 1.1))
                p.setBrush(Qt.NoBrush)
                p.drawPath(path)
            # lacquer highlight
            hl = QLinearGradient(panel.topLeft(), panel.topRight())
            hl.setColorAt(0.0, QColor(255, 255, 255, 0))
            hl.setColorAt(0.35, QColor(255, 220, 180, 34))
            hl.setColorAt(1.0, QColor(255, 255, 255, 0))
            p.fillRect(panel, hl)
            p.restore()

        # charcoal faceplate
        plate = QRectF(body.left() + pitch * _WOOD, body.top() + pitch * 0.12,
                       body.width() - 2 * pitch * _WOOD, body.height() - pitch * 0.24)
        g = QLinearGradient(plate.topLeft(), plate.bottomLeft())
        g.setColorAt(0.0, QColor("#2D2F32"))
        g.setColorAt(1.0, QColor("#1D1E20"))
        p.setBrush(g)
        p.setPen(QPen(QColor("#0C0D0E"), 1.2))
        p.drawRoundedRect(plate, pitch * 0.22, pitch * 0.22)
        p.setPen(QPen(QColor(255, 255, 255, 22), 1))
        p.drawLine(QPointF(plate.left() + pitch * 0.25, plate.top() + 1.5),
                   QPointF(plate.right() - pitch * 0.25, plate.top() + 1.5))

        # logo
        f = QFont()
        f.setPixelSize(max(9, int(pitch * 0.34)))
        f.setBold(True)
        f.setItalic(True)
        p.setFont(f)
        p.setPen(QColor("#D6D8DB"))
        lx, ly = grid.x() + pitch * 0.05, body.top() + pitch * 0.2
        p.drawText(QRectF(lx, ly, pitch * 2, pitch * 0.6), Qt.AlignLeft | Qt.AlignVCenter, "AKAI")
        f2 = QFont()
        f2.setPixelSize(max(9, int(pitch * 0.3)))
        p.setFont(f2)
        p.setPen(QColor("#B9BCC0"))
        p.drawText(QRectF(lx + pitch * 1.05, ly, pitch * 4, pitch * 0.6), Qt.AlignLeft | Qt.AlignVCenter,
                   "APC mini mk2")

        # recessed pad well
        # the well's inner margin equals the pad gutter
        m = _GUTTER * pitch
        well = QRectF(grid.x() - m, grid.y() - m, _GRID_W * pitch + 2 * m, _GRID_H * pitch + 2 * m)
        p.setBrush(QColor("#121315"))
        p.setPen(QPen(QColor(0, 0, 0, 200), 1))
        p.drawRoundedRect(well, pitch * 0.14, pitch * 0.14)
        p.setPen(QPen(QColor(255, 255, 255, 14), 1))
        p.drawLine(QPointF(well.left() + 3, well.bottom() + 0.5), QPointF(well.right() - 3, well.bottom() + 0.5))

        # track buttons (red) + shift
        ty = grid.y() + _GRID_H * pitch + pitch * 0.34
        for i in range(9):
            r = QRectF(grid.x() + i * pitch + _PAD_W * pitch * 0.08, ty, _PAD_W * pitch * 0.84, pitch * 0.36)
            red = i < 8
            gg = QLinearGradient(r.topLeft(), r.bottomLeft())
            gg.setColorAt(0, QColor("#E2463C" if red else "#8E9196"))
            gg.setColorAt(1, QColor("#A82A23" if red else "#606368"))
            p.setBrush(gg)
            p.setPen(QPen(QColor(0, 0, 0, 170), 1))
            p.drawRoundedRect(r, pitch * 0.07, pitch * 0.07)
            p.setPen(QPen(QColor(255, 255, 255, 55), 1))
            p.drawLine(QPointF(r.left() + 3, r.top() + 1.5), QPointF(r.right() - 3, r.top() + 1.5))

        # fader wells (caps are drawn live in paintEvent)
        for i in range(9):
            cx, fy, fh = self._fader_geometry(i, grid, pitch)
            well_r = QRectF(cx - pitch * 0.34, fy, pitch * 0.68, fh)
            p.setBrush(QColor("#161719"))
            p.setPen(QPen(QColor(0, 0, 0, 180), 1))
            p.drawRoundedRect(well_r, pitch * 0.08, pitch * 0.08)
            p.setPen(QPen(QColor(255, 255, 255, 30), 1))
            for k in range(7):
                yy = fy + fh * (0.12 + 0.76 * k / 6)
                p.drawLine(QPointF(cx - pitch * 0.26, yy), QPointF(cx - pitch * 0.14, yy))
                p.drawLine(QPointF(cx + pitch * 0.14, yy), QPointF(cx + pitch * 0.26, yy))
            p.setPen(QPen(QColor("#050505"), max(2.0, pitch * 0.07), Qt.SolidLine, Qt.RoundCap))
            p.drawLine(QPointF(cx, fy + fh * 0.08), QPointF(cx, fy + fh * 0.92))
        p.end()
        self._body, self._body_key = pm, key
        return pm

    def resizeEvent(self, e) -> None:
        self._body = None
        self._topo_pm = None
        super().resizeEvent(e)

    # -- painting -------------------------------------------------------------------------
    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        # layer order: workspace grey (widget bg) < topo pattern < APC (+ shadow)
        if self._topo_opacity > 0:
            topo = self._render_topo()
            if topo is not None:
                p.setOpacity(self._topo_opacity)
                p.drawPixmap(0, 0, topo)
                p.setOpacity(1.0)
        p.drawPixmap(0, 0, self._render_body())
        body, grid, pitch = self._geometry()
        now = time.monotonic()

        # connection LED on the faceplate
        led = QPointF(grid.x() + pitch * (8 + _PAD_W / 2), body.top() + pitch * 0.5)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor("#3CC261") if self._connected else QColor("#3A1E1E"))
        p.drawEllipse(led, pitch * 0.055, pitch * 0.055)

        radius = pitch * 0.1
        lit = []
        for i, pad in enumerate(self._pads):
            c = pad_color(pad, now)
            if c is not None:
                lit.append((i, c))
        # controlled bloom (under the pads)
        for i, c in lit:
            rect = self._pad_rect(i % 8, i // 8, grid, pitch)
            gl = QRadialGradient(rect.center(), pitch * 0.78)
            k = max(c.red(), c.green(), c.blue()) / 255.0
            glow = QColor(c)
            glow.setAlpha(int(70 * k))
            gl.setColorAt(0.0, glow)
            glow.setAlpha(0)
            gl.setColorAt(1.0, glow)
            p.setPen(Qt.NoPen)
            p.setBrush(gl)
            p.drawEllipse(rect.center(), pitch * 0.78, pitch * 0.78)
        lit_map = dict(lit)
        for i in range(64):
            x, y = i % 8, i // 8
            rect = self._pad_rect(x, y, grid, pitch)
            c = lit_map.get(i)
            if c is None:
                g = QLinearGradient(rect.topLeft(), rect.bottomLeft())
                g.setColorAt(0.0, QColor("#303235"))
                g.setColorAt(1.0, QColor("#26282A"))
                p.setBrush(g)
                p.setPen(QPen(QColor("#0B0C0D"), 1))
                p.drawRoundedRect(rect, radius, radius)
                p.setPen(QPen(QColor(255, 255, 255, 16), 1))
                p.drawLine(QPointF(rect.left() + 3, rect.top() + 1.5), QPointF(rect.right() - 3, rect.top() + 1.5))
            else:
                g = QLinearGradient(rect.topLeft(), rect.bottomLeft())
                g.setColorAt(0.0, c.lighter(118))
                g.setColorAt(1.0, c)
                p.setBrush(g)
                p.setPen(QPen(c.darker(160), 1))
                p.drawRoundedRect(rect, radius, radius)
                p.setPen(Qt.NoPen)
                p.setBrush(QColor(255, 255, 255, 30))
                p.drawRoundedRect(QRectF(rect.left() + 2, rect.top() + 2, rect.width() - 4, rect.height() * 0.3),
                                  radius, radius)
            if self._paint_mode and self._hover == (x, y):
                p.setPen(QPen(QColor(255, 255, 255, 200), 1.4, Qt.DashLine))
                p.setBrush(Qt.NoBrush)
                p.drawRoundedRect(rect.adjusted(-2, -2, 2, 2), radius + 1, radius + 1)

        # fader caps at their live positions
        for i in range(9):
            cx, fy, fh = self._fader_geometry(i, grid, pitch)
            cy = fy + fh * 0.08 + fh * 0.84 * (1.0 - self._faders[i])
            cap = QRectF(cx - pitch * 0.3, cy - pitch * 0.17, pitch * 0.6, pitch * 0.34)
            cg = QLinearGradient(cap.topLeft(), cap.bottomLeft())
            cg.setColorAt(0.0, QColor("#F1F2F4"))
            cg.setColorAt(0.45, QColor("#B9BCC1"))
            cg.setColorAt(0.55, QColor("#8F9398"))
            cg.setColorAt(1.0, QColor("#C4C7CB"))
            p.setBrush(cg)
            p.setPen(QPen(QColor(0, 0, 0, 180), 1))
            p.drawRoundedRect(cap, pitch * 0.05, pitch * 0.05)
            p.setPen(QPen(QColor(40, 40, 40, 200), 1))
            p.drawLine(QPointF(cap.left() + 2, cap.center().y()), QPointF(cap.right() - 2, cap.center().y()))

        # scene launch buttons (grey caps, green LED when lit / blinking)
        blink_on = (now * 2.0) % 1.0 < 0.5
        for i in range(8):
            pr = self._pad_rect(8, i, grid, pitch)
            r = QRectF(pr.left() + pitch * 0.14, pr.top() + pitch * 0.08, pr.width() - pitch * 0.28,
                       pr.height() - pitch * 0.16)
            state = self._scene_states[i] if i < len(self._scene_states) else 0
            on = state == 1 or (state == 2 and blink_on)
            g = QLinearGradient(r.topLeft(), r.bottomLeft())
            if on:
                g.setColorAt(0, QColor("#8EF0A6"))
                g.setColorAt(1, QColor("#3CC261"))
            else:
                g.setColorAt(0, QColor("#9A9DA2"))
                g.setColorAt(1, QColor("#6B6E73"))
            if on:
                gl = QRadialGradient(r.center(), pitch * 0.6)
                gl.setColorAt(0, QColor(60, 194, 97, 90))
                gl.setColorAt(1, QColor(60, 194, 97, 0))
                p.setPen(Qt.NoPen)
                p.setBrush(gl)
                p.drawEllipse(r.center(), pitch * 0.6, pitch * 0.6)
            p.setBrush(g)
            p.setPen(QPen(QColor(0, 0, 0, 190), 1))
            p.drawRoundedRect(r, pitch * 0.08, pitch * 0.08)
            p.setPen(QPen(QColor(255, 255, 255, 60), 1))
            p.drawLine(QPointF(r.left() + 3, r.top() + 1.5), QPointF(r.right() - 3, r.top() + 1.5))
        p.end()

    # -- interaction ---------------------------------------------------------------------------
    def mousePressEvent(self, e) -> None:
        f = self._fader_hit(e.position())
        if f is not None:
            self._fader_drag = f
            self._drag_fader(e.position().y())
            return
        if not self._paint_mode:
            return
        hit = self._hit(e.position())
        if hit:
            self._drag_button = "right" if e.button() == Qt.RightButton else "left"
            self._last_drag = hit
            self.pad_pressed.emit(hit[0], hit[1], self._drag_button)

    def _drag_fader(self, y: float) -> None:
        i = self._fader_drag
        v = self._fader_value_at(i, y)
        if abs(v - self._faders[i]) > 1e-3:
            self._faders[i] = v
            self.fader_moved.emit(i, v)
            self.update()

    def mouseMoveEvent(self, e) -> None:
        if self._fader_drag is not None:
            self._drag_fader(e.position().y())
            return
        if self._fader_hit(e.position()) is not None:
            self.setCursor(Qt.SizeVerCursor)
        else:
            self.setCursor(Qt.PointingHandCursor if self._paint_mode else Qt.ArrowCursor)
        hit = self._hit(e.position())
        if hit != self._hover:
            self._hover = hit
            if self._paint_mode:
                self.update()
        if self._drag_button and hit and hit != self._last_drag:
            if self._last_drag:
                self.pad_released.emit(*self._last_drag)
            self._last_drag = hit
            self.pad_pressed.emit(hit[0], hit[1], self._drag_button)

    def mouseReleaseEvent(self, _e) -> None:
        self._fader_drag = None
        self._release_drag()

    def _release_drag(self) -> None:
        if self._last_drag:
            self.pad_released.emit(*self._last_drag)
        self._drag_button = None
        self._last_drag = None

    def leaveEvent(self, _e) -> None:
        self._hover = None
        self.update()


def frame_thumbnail(pads: List[Pad], size: int = 24) -> QPixmap:
    """Small 8x8 preview used in the browser (HiDPI-sharp)."""
    dpr = 2.0
    pm = QPixmap(int(size * dpr), int(size * dpr))
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, size, size), 3, 3)
    p.fillPath(path, QColor("#141517"))
    cell = (size - 2) / 8
    for i, pad in enumerate(pads):
        x, y = i % 8, i // 8
        c = QColor(*pad.rgb) if not pad.is_off else QColor("#2A2C2F")
        p.fillRect(QRectF(1 + x * cell + 0.25, 1 + y * cell + 0.25, cell - 0.5, cell - 0.5), c)
    p.end()
    return pm

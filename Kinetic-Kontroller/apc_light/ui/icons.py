"""Vector utility icons drawn with QPainter (crisp at any Retina scale).

``draw(painter, name, rect, color)`` renders a monochrome, geometric icon
centred in ``rect`` (designed on a 16x16 grid).
"""

from __future__ import annotations

import math
from typing import Callable, Dict

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen, QPolygonF


def _pen(p: QPainter, color: QColor, w: float = 1.5) -> None:
    pen = QPen(color, w)
    pen.setCapStyle(Qt.RoundCap)
    pen.setJoinStyle(Qt.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.NoBrush)


def _fill(p: QPainter, color: QColor) -> None:
    p.setPen(Qt.NoPen)
    p.setBrush(color)


def _poly(*pts) -> QPolygonF:
    return QPolygonF([QPointF(x, y) for x, y in pts])


def play(p, c):
    _fill(p, c); p.drawPolygon(_poly((4.5, 2.5), (13, 8), (4.5, 13.5)))


def stop(p, c):
    _fill(p, c); p.drawRoundedRect(QRectF(3.5, 3.5, 9, 9), 1, 1)


def pause(p, c):
    _fill(p, c); p.drawRoundedRect(QRectF(4, 3, 3, 10), 0.8, 0.8); p.drawRoundedRect(QRectF(9, 3, 3, 10), 0.8, 0.8)


def prev(p, c):
    _fill(p, c); p.drawRect(QRectF(3, 3.5, 1.8, 9)); p.drawPolygon(_poly((13, 3.5), (5.5, 8), (13, 12.5)))


def next(p, c):  # noqa: A001 - icon name
    _fill(p, c); p.drawRect(QRectF(11.2, 3.5, 1.8, 9)); p.drawPolygon(_poly((3, 3.5), (10.5, 8), (3, 12.5)))


def gear(p, c):
    _fill(p, c)
    path = QPainterPath()
    teeth = 8
    for i in range(teeth * 2):
        a = math.pi * i / teeth
        r = 7.0 if i % 2 == 0 else 5.6
        a0, a1 = a - math.pi / teeth / 2.2, a + math.pi / teeth / 2.2
        for aa in (a0, a1):
            pt = QPointF(8 + r * math.cos(aa), 8 + r * math.sin(aa))
            path.moveTo(pt) if path.elementCount() == 0 else path.lineTo(pt)
    path.closeSubpath()
    hole = QPainterPath()
    hole.addEllipse(QPointF(8, 8), 2.3, 2.3)
    p.drawPath(path.subtracted(hole))


def search(p, c):
    _pen(p, c, 1.4); p.drawEllipse(QPointF(7, 7), 4, 4); p.drawLine(QPointF(10, 10), QPointF(13.5, 13.5))


def star(p, c, filled=False):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = 6.6 if i % 2 == 0 else 2.8
        pts.append((8 + r * math.cos(a), 8.4 + r * math.sin(a)))
    if filled:
        _fill(p, c)
    else:
        _pen(p, c, 1.1)
    p.drawPolygon(_poly(*pts))


def star_filled(p, c):
    star(p, c, True)


def plus(p, c):
    _pen(p, c, 1.6); p.drawLine(QPointF(8, 3), QPointF(8, 13)); p.drawLine(QPointF(3, 8), QPointF(13, 8))


def more(p, c):
    _fill(p, c)
    for x in (3.5, 8, 12.5):
        p.drawEllipse(QPointF(x, 8), 1.4, 1.4)


def pencil(p, c):
    _pen(p, c, 1.3)
    p.drawPolygon(_poly((3, 13), (3.4, 10.4), (10.8, 3), (13, 5.2), (5.6, 12.6)))
    p.drawLine(QPointF(9.4, 4.4), QPointF(11.6, 6.6))


def brush(p, c):
    _pen(p, c, 1.3)
    p.drawLine(QPointF(13, 3), QPointF(7.5, 8.5))
    _fill(p, c)
    path = QPainterPath(QPointF(7.8, 8.2))
    path.cubicTo(QPointF(4, 8), QPointF(5, 12), QPointF(2.5, 13.5))
    path.cubicTo(QPointF(6.5, 14), QPointF(9, 12), QPointF(7.8, 8.2))
    p.drawPath(path)


def eraser(p, c):
    _pen(p, c, 1.3)
    p.drawPolygon(_poly((2.5, 10), (8.5, 4), (13.5, 9), (9.5, 13), (5.5, 13)))
    p.drawLine(QPointF(5.5, 7), QPointF(10.5, 12))
    p.drawLine(QPointF(9.5, 13), QPointF(14, 13))


def eyedropper(p, c):
    _pen(p, c, 1.3)
    p.drawLine(QPointF(3, 13), QPointF(9, 7))
    p.drawLine(QPointF(7.5, 5.5), QPointF(10.5, 8.5))
    _fill(p, c)
    p.drawEllipse(QPointF(11.3, 4.7), 2.3, 2.3)


def bucket(p, c):
    _pen(p, c, 1.3)
    p.drawPolygon(_poly((3, 8), (8, 3), (12.5, 7.5), (7.5, 12.5)))
    p.drawLine(QPointF(3, 8), QPointF(12.5, 7.5))
    _fill(p, c)
    p.drawEllipse(QPointF(13.3, 11.6), 1.4, 1.8)


def refresh(p, c):
    _pen(p, c, 1.4)
    p.drawArc(QRectF(3, 3, 10, 10), 40 * 16, 280 * 16)
    _fill(p, c)
    p.drawPolygon(_poly((10.2, 1.6), (13.6, 4.4), (9.6, 5.8)))


def menu(p, c):
    _pen(p, c, 1.4)
    for y in (4.5, 8, 11.5):
        p.drawLine(QPointF(3, y), QPointF(13, y))


def chip(p, c):
    """Hardware-accurate preview."""
    _pen(p, c, 1.2)
    p.drawRoundedRect(QRectF(4, 4, 8, 8), 1.2, 1.2)
    for v in (6, 8, 10):
        p.drawLine(QPointF(v, 2), QPointF(v, 4)); p.drawLine(QPointF(v, 12), QPointF(v, 14))
        p.drawLine(QPointF(2, v), QPointF(4, v)); p.drawLine(QPointF(12, v), QPointF(14, v))


def sparkle(p, c):
    """Ideal (unquantized) colours."""
    _fill(p, c)
    p.drawPolygon(_poly((6.5, 2.5), (7.7, 6.8), (12, 8), (7.7, 9.2), (6.5, 13.5), (5.3, 9.2), (1, 8), (5.3, 6.8)))
    p.drawPolygon(_poly((12.5, 1), (13.1, 3.1), (15.2, 3.7), (13.1, 4.3), (12.5, 6.4), (11.9, 4.3), (9.8, 3.7),
                        (11.9, 3.1)))


def folder(p, c):
    _pen(p, c, 1.2)
    p.drawPolygon(_poly((2.5, 4), (6.5, 4), (8, 5.5), (13.5, 5.5), (13.5, 12.5), (2.5, 12.5)))


def trash(p, c):
    _pen(p, c, 1.2)
    p.drawLine(QPointF(3, 4.5), QPointF(13, 4.5)); p.drawLine(QPointF(6.5, 4.5), QPointF(7, 2.5))
    p.drawLine(QPointF(7, 2.5), QPointF(9, 2.5)); p.drawLine(QPointF(9, 2.5), QPointF(9.5, 4.5))
    p.drawPolygon(_poly((4.3, 4.5), (5, 13.5), (11, 13.5), (11.7, 4.5)))


def save(p, c):
    _pen(p, c, 1.2)
    p.drawRoundedRect(QRectF(3, 3, 10, 10), 1.2, 1.2)
    p.drawRect(QRectF(5.5, 3, 5, 3.2))
    p.drawRect(QRectF(5, 8.5, 6, 4.5))


def blackout(p, c):
    _pen(p, c, 1.3)
    p.drawEllipse(QPointF(8, 8), 5.2, 5.2)
    p.drawLine(QPointF(4.3, 11.7), QPointF(11.7, 4.3))


def tri_down(p, c):
    _fill(p, c); p.drawPolygon(_poly((4, 5.5), (12, 5.5), (8, 10.5)))


def tri_right(p, c):
    _fill(p, c); p.drawPolygon(_poly((5.5, 4), (10.5, 8), (5.5, 12)))


def chevron_down(p, c):
    _pen(p, c, 1.5); p.drawPolyline(_poly((4.5, 6.5), (8, 10), (11.5, 6.5)))


ICONS: Dict[str, Callable] = {
    "play": play, "stop": stop, "pause": pause, "prev": prev, "next": next, "gear": gear,
    "search": search, "star": star, "star_filled": star_filled, "plus": plus, "more": more,
    "pencil": pencil, "brush": brush, "eraser": eraser, "eyedropper": eyedropper, "bucket": bucket,
    "refresh": refresh, "menu": menu, "chip": chip, "sparkle": sparkle, "folder": folder, "trash": trash,
    "save": save, "blackout": blackout, "tri_down": tri_down, "tri_right": tri_right,
    "chevron_down": chevron_down,
}


def draw(painter: QPainter, name: str, rect: QRectF, color: QColor, size: float = 16.0) -> None:
    fn = ICONS.get(name)
    if fn is None:
        return
    painter.save()
    painter.setRenderHint(QPainter.Antialiasing)
    s = min(size, rect.width(), rect.height())
    painter.translate(rect.center().x() - s / 2, rect.center().y() - s / 2)
    painter.scale(s / 16.0, s / 16.0)
    fn(painter, color)
    painter.restore()

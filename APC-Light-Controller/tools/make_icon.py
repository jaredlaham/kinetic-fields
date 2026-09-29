"""Render the app icon (a glowing 4x4 pad grid) to PNG with Qt.

    python tools/make_icon.py apc_light/assets/icon_1024.png
build_app.sh turns it into AppIcon.icns with sips + iconutil on macOS.
"""
import colorsys
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPointF, QRectF, Qt  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter, QRadialGradient  # noqa: E402

out = sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png"
app = QGuiApplication([])
S = 1024
img = QImage(S, S, QImage.Format_ARGB32)
img.fill(Qt.transparent)
p = QPainter(img)
p.setRenderHint(QPainter.Antialiasing)

# macOS icon grid: 824px rounded square centred in 1024.
body = QRectF(100, 100, 824, 824)
g = QLinearGradient(body.topLeft(), body.bottomLeft())
g.setColorAt(0, QColor("#24262b"))
g.setColorAt(1, QColor("#0e0f11"))
p.setPen(Qt.NoPen)
p.setBrush(g)
p.drawRoundedRect(body, 185, 185)

n, margin, gap = 4, 190, 34
cell = (S - 2 * margin - (n - 1) * gap) / n
for y in range(n):
    for x in range(n):
        h = ((x + (n - 1 - y)) / (2 * n - 1)) * 0.85
        r, gg, b = colorsys.hsv_to_rgb(h, 0.9, 1.0)
        c = QColor(int(r * 255), int(gg * 255), int(b * 255))
        rect = QRectF(margin + x * (cell + gap), margin + y * (cell + gap), cell, cell)
        glow = QRadialGradient(rect.center(), cell * 0.95)
        gc = QColor(c)
        gc.setAlpha(110)
        glow.setColorAt(0, gc)
        gc.setAlpha(0)
        glow.setColorAt(1, gc)
        p.setBrush(glow)
        p.drawEllipse(rect.center(), cell * 0.95, cell * 0.95)
for y in range(n):
    for x in range(n):
        h = ((x + (n - 1 - y)) / (2 * n - 1)) * 0.85
        r, gg, b = colorsys.hsv_to_rgb(h, 0.9, 1.0)
        c = QColor(int(r * 255), int(gg * 255), int(b * 255))
        rect = QRectF(margin + x * (cell + gap), margin + y * (cell + gap), cell, cell)
        p.setBrush(c)
        p.drawRoundedRect(rect, 22, 22)
        p.setBrush(QColor(255, 255, 255, 50))
        p.drawRoundedRect(QRectF(rect.left() + 8, rect.top() + 8, rect.width() - 16, rect.height() * 0.32), 16, 16)
p.end()
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
img.save(out)
print(out)

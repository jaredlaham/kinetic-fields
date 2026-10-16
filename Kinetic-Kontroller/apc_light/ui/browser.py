"""Left browser: Effects / Patterns / Notes.

The effects list is painted as one widget (not a stack of row widgets) so
rows, headers and selection are pixel-precise and cheap:

    ▾ FAVORITES                                  <- section header band
 ▶ [thumb] Kinetic Sweep                [1] ★    <- 34 px row; ▶ = running
   [thumb] Rainbow                      [2] ★    <- blue = selected
"""

from __future__ import annotations

from typing import Callable, Dict, List, Optional, Tuple, Type

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QAction, QColor, QFont, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (
    QHBoxLayout, QInputDialog, QMenu, QPlainTextEdit, QScrollArea, QStackedWidget, QVBoxLayout, QWidget,
)

from ..engine.effect import CATEGORIES, Effect
from ..engine.frame import Pad, to_rgb
from . import icons
from .apc_view import frame_thumbnail
from .components import IconButton, SearchField, SegmentedControl
from .design import C, F, H, R, S

SECTION_H = 26
ADD_H = 32
STAR_W = 26
GUTTER = 16


def _font(px: int, weight=QFont.Normal, spacing: float = 0.0) -> QFont:
    f = QFont()
    f.setPixelSize(px)
    f.setWeight(QFont.Weight(weight))
    if spacing:
        f.setLetterSpacing(QFont.AbsoluteSpacing, spacing)
    return f


class _Entry:
    __slots__ = ("kind", "key", "title", "section", "top", "height")

    def __init__(self, kind, key, title="", section="", top=0, height=0):
        self.kind, self.key, self.title, self.section, self.top, self.height = kind, key, title, section, top, height


class BrowserList(QWidget):
    """Painted list with section headers and effect rows."""

    effect_clicked = Signal(str)
    favorite_toggled = Signal(str, bool)
    context_requested = Signal(str, object)
    add_clicked = Signal()
    section_toggled = Signal(str, bool)

    def __init__(self, effects: List[Type[Effect]], thumbnail: Callable[[str], QPixmap], parent=None) -> None:
        super().__init__(parent)
        self._effects = effects
        self._by_id = {c.id: c for c in effects}
        self._thumb = thumbnail
        self._favorites: List[str] = []
        self._keys: Dict[str, str] = {}
        self._slots: Dict[str, int] = {}      # effect id -> scene button 0..7
        self._selected: Optional[str] = None
        self._active: Optional[str] = None
        self._collapsed: set = set()
        self._filter = ""
        self._entries: List[_Entry] = []
        self._hover: Optional[_Entry] = None
        self._hover_star = False
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setAttribute(Qt.WA_OpaquePaintEvent)

    # -- state -------------------------------------------------------------------
    def set_state(self, favorites, shortcuts: Dict[str, str], collapsed=()) -> None:
        self._favorites = [f for f in favorites if f in self._by_id]
        self._keys = {eid: k for k, eid in shortcuts.items()}
        self._collapsed = set(collapsed)
        self._rebuild()

    def set_selection(self, selected: Optional[str], active: Optional[str]) -> None:
        self._selected, self._active = selected, active
        self.update()

    def set_filter(self, text: str) -> None:
        self._filter = text.strip().lower()
        self._rebuild()

    def visible_effects(self) -> List[str]:
        return [e.key for e in self._entries if e.kind == "row"]

    def set_scene_slots(self, slots) -> None:
        self._slots = {eid: i for i, eid in enumerate(slots) if eid}
        self.update()

    def scene_button_of(self, eid: str) -> Optional[int]:
        return self._slots.get(eid)

    def is_favorite(self, eid: str) -> bool:
        return eid in self._favorites

    # -- layout --------------------------------------------------------------------
    def _rebuild(self) -> None:
        entries: List[_Entry] = []
        y = 0
        groups = [("FAVORITES", self._favorites)]
        groups += [(cat.upper(), [c.id for c in self._effects if c.category == cat]) for cat in CATEGORIES]
        for title, ids in groups:
            ids = [i for i in ids if not self._filter or self._filter in self._by_id[i].name.lower()]
            if not ids:
                continue
            entries.append(_Entry("section", title, title, top=y, height=SECTION_H))
            y += SECTION_H
            if title in self._collapsed and not self._filter:
                continue
            for eid in ids:
                entries.append(_Entry("row", eid, self._by_id[eid].name, section=title, top=y, height=H.ROW))
                y += H.ROW
        entries.append(_Entry("add", "add", "Add Effect…", top=y, height=ADD_H))
        y += ADD_H
        self._entries = entries
        self.setFixedHeight(y + 4)
        self.update()

    def sizeHint(self) -> QSize:  # noqa: N802
        return QSize(H.BROWSER, self.height())

    def _entry_at(self, y: float) -> Optional[_Entry]:
        for e in self._entries:
            if e.top <= y < e.top + e.height:
                return e
        return None

    # -- painting --------------------------------------------------------------------
    def paintEvent(self, ev) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(ev.rect(), C.q(C.BROWSER))
        w = self.width()
        clip_top, clip_bottom = ev.rect().top(), ev.rect().bottom()
        for e in self._entries:
            if e.top + e.height < clip_top or e.top > clip_bottom:
                continue
            r = QRectF(0, e.top, w, e.height)
            if e.kind == "section":
                self._paint_section(p, e, r)
            elif e.kind == "row":
                self._paint_row(p, e, r)
            else:
                hover = self._hover is e
                p.setPen(C.q(C.TEXT if hover else C.TEXT_3))
                icons.draw(p, "plus", QRectF(GUTTER + 4, e.top, 20, e.height), C.q(C.TEXT_2 if hover else C.TEXT_3), 13)
                p.setFont(_font(F.ROW))
                p.drawText(QRectF(GUTTER + 36, e.top, w, e.height), Qt.AlignVCenter, e.title)

    def _paint_section(self, p: QPainter, e: _Entry, r: QRectF) -> None:
        p.fillRect(r, C.q(C.BROWSER_HEADER))
        p.setPen(C.q(C.SEPARATOR))
        p.drawLine(QPointF(0, r.top()), QPointF(r.right(), r.top()))
        p.drawLine(QPointF(0, r.bottom() - 0.5), QPointF(r.right(), r.bottom() - 0.5))
        collapsed = e.key in self._collapsed and not self._filter
        icons.draw(p, "tri_right" if collapsed else "tri_down", QRectF(8, r.top(), 14, r.height()),
                   C.q(C.TEXT_2), 10)
        p.setFont(_font(F.SECTION, QFont.Medium, 1.2))
        p.setPen(C.q(C.TEXT_2))
        p.drawText(QRectF(28, r.top(), r.width(), r.height()), Qt.AlignVCenter, e.title)

    def _paint_row(self, p: QPainter, e: _Entry, r: QRectF) -> None:
        eid = e.key
        selected = eid == self._selected
        hover = self._hover is e
        if selected:
            p.fillRect(r, C.q(C.SELECT))
        elif hover:
            p.fillRect(r, C.q(C.ROW_HOVER))
        # hairline between rows
        p.setPen(QPen(QColor(0, 0, 0, 40), 1))
        p.drawLine(QPointF(GUTTER + 4, r.bottom() - 0.5), QPointF(r.right(), r.bottom() - 0.5))
        text = QColor("white") if selected else C.q(C.TEXT)
        # ▶ running indicator in the gutter
        if eid == self._active:
            icons.draw(p, "tri_right", QRectF(3, r.top(), 12, r.height()),
                       QColor("white") if selected else C.q(C.PLAY), 10)
        # thumbnail
        t = H.THUMB
        pm = self._thumb(eid)
        ty = r.top() + (r.height() - t) / 2
        p.drawPixmap(QRectF(GUTTER + 4, ty, t, t).toRect(), pm)
        # name
        star_x = r.right() - STAR_W - 4
        badge_w = 20
        key = self._keys.get(eid)
        slot = self._slots.get(eid)
        name_right = star_x - 8 - (badge_w + 4) * ((1 if key else 0) + (1 if slot is not None else 0))
        p.setFont(_font(F.ROW))
        p.setPen(text)
        p.drawText(QRectF(GUTTER + 4 + t + 10, r.top(), name_right - (GUTTER + t + 14), r.height()),
                   Qt.AlignVCenter | Qt.AlignLeft, e.title)
        # scene-button badge (green, like the APC's scene LEDs)
        if slot is not None:
            bx = star_x - badge_w - 4 - ((badge_w + 4) if key else 0)
            b = QRectF(bx, r.top() + (r.height() - 18) / 2, badge_w, 18)
            p.setPen(QPen(QColor(60, 194, 97, 200), 1))
            p.setBrush(QColor(60, 194, 97, 50))
            p.drawRoundedRect(b.adjusted(0.5, 0.5, -0.5, -0.5), R.SMALL, R.SMALL)
            p.setFont(_font(F.BADGE, QFont.Medium))
            p.setPen(QColor("#8EF0A6"))
            p.drawText(b, Qt.AlignCenter, str(slot + 1))
        # shortcut badge
        if key:
            b = QRectF(star_x - badge_w - 4, r.top() + (r.height() - 18) / 2, badge_w, 18)
            p.setPen(QPen(QColor(255, 255, 255, 40 if not selected else 90), 1))
            p.setBrush(QColor(0, 0, 0, 70) if not selected else QColor(255, 255, 255, 40))
            p.drawRoundedRect(b.adjusted(0.5, 0.5, -0.5, -0.5), R.SMALL, R.SMALL)
            p.setFont(_font(F.BADGE, QFont.Medium))
            p.setPen(QColor("white") if selected else C.q(C.TEXT_2))
            p.drawText(b, Qt.AlignCenter, key)
        # favourite star
        fav = eid in self._favorites
        sr = QRectF(star_x, r.top(), STAR_W, r.height())
        if fav:
            color = C.q(C.STAR)
        elif hover and self._hover_star:
            color = QColor("white")
        else:
            color = QColor(255, 255, 255, 150) if selected else C.q(C.TEXT_3)
        icons.draw(p, "star_filled" if fav else "star", sr, color, 15)

    # -- interaction ------------------------------------------------------------------
    def mouseMoveEvent(self, e) -> None:
        pos = e.position()
        entry = self._entry_at(pos.y())
        star = bool(entry and entry.kind == "row" and pos.x() >= self.width() - STAR_W - 6)
        if entry is not self._hover or star != self._hover_star:
            self._hover, self._hover_star = entry, star
            self.setCursor(Qt.PointingHandCursor if entry else Qt.ArrowCursor)
            self.setToolTip(self._by_id[entry.key].description if entry and entry.kind == "row" else "")
            self.update()

    def leaveEvent(self, _e) -> None:
        self._hover = None
        self.update()

    def mousePressEvent(self, e) -> None:
        entry = self._entry_at(e.position().y())
        if entry is None:
            return
        if e.button() == Qt.RightButton:
            if entry.kind == "row":
                self.context_requested.emit(entry.key, e.globalPosition().toPoint())
            return
        if entry.kind == "section":
            if entry.key in self._collapsed:
                self._collapsed.discard(entry.key)
            else:
                self._collapsed.add(entry.key)
            self.section_toggled.emit(entry.key, entry.key not in self._collapsed)
            self._rebuild()
        elif entry.kind == "add":
            self.add_clicked.emit()
        elif e.position().x() >= self.width() - STAR_W - 6:
            self.favorite_toggled.emit(entry.key, entry.key not in self._favorites)
        else:
            self.effect_clicked.emit(entry.key)

    def keyPressEvent(self, e) -> None:
        rows = self.visible_effects()
        if not rows or e.modifiers() & ~Qt.KeypadModifier:
            return super().keyPressEvent(e)
        i = rows.index(self._selected) if self._selected in rows else -1
        if e.key() == Qt.Key_Down:
            self.effect_clicked.emit(rows[min(len(rows) - 1, i + 1)])
        elif e.key() == Qt.Key_Up:
            self.effect_clicked.emit(rows[max(0, i - 1)])
        else:
            super().keyPressEvent(e)

    def row_rect(self, eid: str) -> Optional[QRectF]:
        for e in self._entries:
            if e.kind == "row" and e.key == eid:
                return QRectF(0, e.top, self.width(), e.height)
        return None


class PatternList(QWidget):
    """Saved Custom Pattern snapshots: thumbnail + name; click to load."""

    load = Signal(str)
    delete = Signal(str)

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._items: List[Tuple[str, QPixmap]] = []
        self._hover = -1
        self.setMouseTracking(True)

    def set_patterns(self, patterns: Dict[str, List[str]]) -> None:
        self._items = []
        for name in sorted(patterns, key=str.lower):
            pads = [Pad(to_rgb(c)) if c != "#000000" else Pad() for c in patterns[name]]
            self._items.append((name, frame_thumbnail(pads, H.THUMB)))
        self.setFixedHeight(max(1, len(self._items)) * H.ROW + 60)
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), C.q(C.BROWSER))
        if not self._items:
            p.setPen(C.q(C.TEXT_3))
            p.setFont(_font(F.SMALL))
            p.drawText(QRectF(12, 8, self.width() - 24, 60), Qt.TextWordWrap,
                       "No saved patterns yet.\nPaint with Custom Pattern, then press + to save it here.")
            return
        for i, (name, pm) in enumerate(self._items):
            r = QRectF(0, i * H.ROW, self.width(), H.ROW)
            if i == self._hover:
                p.fillRect(r, C.q(C.ROW_HOVER))
            p.setPen(QPen(QColor(0, 0, 0, 40), 1))
            p.drawLine(QPointF(GUTTER + 4, r.bottom() - 0.5), QPointF(r.right(), r.bottom() - 0.5))
            p.drawPixmap(int(GUTTER + 4), int(r.top() + (H.ROW - H.THUMB) / 2), pm)
            p.setPen(C.q(C.TEXT))
            p.setFont(_font(F.ROW))
            p.drawText(QRectF(GUTTER + 38, r.top(), r.width() - 90, r.height()), Qt.AlignVCenter, name)
            if i == self._hover:
                icons.draw(p, "trash", QRectF(r.right() - 30, r.top(), 24, r.height()), C.q(C.TEXT_2), 14)

    def _index(self, y: float) -> int:
        i = int(y // H.ROW)
        return i if 0 <= i < len(self._items) else -1

    def mouseMoveEvent(self, e) -> None:
        i = self._index(e.position().y())
        if i != self._hover:
            self._hover = i
            self.setCursor(Qt.PointingHandCursor if i >= 0 else Qt.ArrowCursor)
            self.update()

    def leaveEvent(self, _e) -> None:
        self._hover = -1
        self.update()

    def mousePressEvent(self, e) -> None:
        i = self._index(e.position().y())
        if i < 0:
            return
        name = self._items[i][0]
        if e.position().x() >= self.width() - 34:
            self.delete.emit(name)
        else:
            self.load.emit(name)


class BrowserPanel(QWidget):
    effect_clicked = Signal(str)
    favorites_changed = Signal(list)
    shortcut_assigned = Signal(str, str)
    scene_button_assigned = Signal(int, str)   # button 0..7, effect id ("" = clear)
    add_effect = Signal()
    save_pattern = Signal()
    load_pattern = Signal(str)
    delete_pattern = Signal(str)
    notes_changed = Signal(str)
    ui_changed = Signal(str, object)  # (key, value) for persisted UI state

    TABS = ["Effects", "Patterns", "Notes"]

    def __init__(self, effects, thumbnail, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Browser")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self._by_id = {c.id: c for c in effects}
        self._favorites: List[str] = []
        self._shortcuts: Dict[str, str] = {}
        self._slots: List[str] = [""] * 8
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        top = QWidget()
        top.setObjectName("BrowserTop")
        top.setAttribute(Qt.WA_StyledBackground, True)
        tl = QHBoxLayout(top)
        tl.setContentsMargins(S.MD, S.MD, S.MD, S.MD)
        tl.setSpacing(S.SM)
        self.tabs = SegmentedControl(self.TABS)
        tl.addWidget(self.tabs, 1)
        self.plus = IconButton("plus", tooltip="Add Effect…", size=H.TABS)
        tl.addWidget(self.plus)
        lay.addWidget(top)

        self.stack = QStackedWidget()
        lay.addWidget(self.stack, 1)

        # Effects page
        page = QWidget()
        pl = QVBoxLayout(page)
        pl.setContentsMargins(0, 0, 0, 0)
        pl.setSpacing(0)
        sbox = QWidget()
        sl = QHBoxLayout(sbox)
        sl.setContentsMargins(S.MD, S.SM, S.MD, S.SM)
        self.search = SearchField("Search Effects…")
        sl.addWidget(self.search)
        pl.addWidget(sbox)
        self.list = BrowserList(effects, thumbnail)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        scroll.setWidget(self.list)
        self._scroll = scroll
        pl.addWidget(scroll, 1)
        self.stack.addWidget(page)

        # Patterns page
        ppage = QScrollArea()
        ppage.setWidgetResizable(True)
        self.patterns = PatternList()
        ppage.setWidget(self.patterns)
        self.stack.addWidget(ppage)

        # Notes page
        self.notes = QPlainTextEdit()
        self.notes.setObjectName("Notes")
        self.notes.setPlaceholderText("Set notes, cues, which scene goes with which track…")
        self.stack.addWidget(self.notes)

        # wiring
        self.tabs.changed.connect(self._tab_changed)
        self.search.textChanged.connect(self.list.set_filter)
        self.list.effect_clicked.connect(self.effect_clicked)
        self.list.favorite_toggled.connect(self._toggle_favorite)
        self.list.context_requested.connect(self._context_menu)
        self.list.add_clicked.connect(self.add_effect)
        self.list.section_toggled.connect(
            lambda *_: self.ui_changed.emit("collapsed", sorted(self.list._collapsed)))
        self.patterns.load.connect(self.load_pattern)
        self.patterns.delete.connect(self.delete_pattern)
        self.notes.textChanged.connect(lambda: self.notes_changed.emit(self.notes.toPlainText()))
        self.plus.clicked.connect(self._plus)
        self._tab_changed(self.tabs.current(), persist=False)

    # -- API used by the main window ----------------------------------------------------
    def set_state(self, favorites, shortcuts, active=None, collapsed=()) -> None:
        self._favorites = [f for f in favorites if f in self._by_id]
        self._shortcuts = dict(shortcuts)
        self.list.set_state(self._favorites, self._shortcuts, collapsed)

    def set_scene_slots(self, slots) -> None:
        self._slots = list(slots)
        self.list.set_scene_slots(self._slots)

    def set_selection(self, selected, active) -> None:
        self.list.set_selection(selected, active)
        if selected:
            r = self.list.row_rect(selected)
            if r is not None:
                self._scroll.ensureVisible(0, int(r.center().y()), 0, int(r.height()))

    def refresh_thumbnail(self, _effect_id: str) -> None:
        self.list.update()

    def set_tab(self, name: str) -> None:
        if name in self.TABS:
            self.tabs.set_current(name)
            self._tab_changed(name, persist=False)

    def set_notes(self, text: str) -> None:
        self.notes.blockSignals(True)
        self.notes.setPlainText(text)
        self.notes.blockSignals(False)

    # -- internals ----------------------------------------------------------------------
    def _tab_changed(self, name: str, persist: bool = True) -> None:
        self.stack.setCurrentIndex(self.TABS.index(name))
        tips = {"Effects": "Add Effect… (creates a new effect file you can edit)",
                "Patterns": "Save the current Custom Pattern", "Notes": ""}
        self.plus.setToolTip(tips[name])
        self.plus.setEnabled(name != "Notes")
        if persist:
            self.ui_changed.emit("browser_tab", name)

    def _plus(self) -> None:
        if self.tabs.current() == "Effects":
            self.add_effect.emit()
        elif self.tabs.current() == "Patterns":
            self.save_pattern.emit()

    def _toggle_favorite(self, effect_id: str, on: bool) -> None:
        favs = [f for f in self._favorites if f != effect_id]
        if on:
            favs.append(effect_id)
        self._favorites = favs
        self.favorites_changed.emit(list(favs))

    def _move_favorite(self, effect_id: str, delta: int) -> None:
        favs = list(self._favorites)
        i = favs.index(effect_id)
        j = max(0, min(len(favs) - 1, i + delta))
        favs.insert(j, favs.pop(i))
        self._favorites = favs
        self.favorites_changed.emit(favs)

    def _context_menu(self, effect_id: str, pos) -> None:
        menu = QMenu(self)
        fav = effect_id in self._favorites
        act = QAction("Remove from Favorites" if fav else "Add to Favorites", menu)
        act.triggered.connect(lambda: self._toggle_favorite(effect_id, not fav))
        menu.addAction(act)
        if fav:
            menu.addAction("Move Up in Favorites").triggered.connect(lambda: self._move_favorite(effect_id, -1))
            menu.addAction("Move Down in Favorites").triggered.connect(lambda: self._move_favorite(effect_id, 1))
        menu.addSeparator()
        sub = menu.addMenu("APC Scene Button")
        for i in range(8):
            owner = self._slots[i] if i < len(self._slots) else ""
            label = f"Button {i + 1}" + ("  (top)" if i == 0 else "")
            if owner and owner != effect_id and owner in self._by_id:
                label += f"   (now {self._by_id[owner].name})"
            a = sub.addAction(label)
            a.setCheckable(True)
            a.setChecked(owner == effect_id)
            a.triggered.connect(lambda _=False, k=i: self.scene_button_assigned.emit(k, effect_id))
        if effect_id in self._slots:
            sub.addSeparator()
            sub.addAction("None").triggered.connect(
                lambda: self.scene_button_assigned.emit(self._slots.index(effect_id), ""))
        sub = menu.addMenu("Keyboard Shortcut")
        current = next((k for k, v in self._shortcuts.items() if v == effect_id), None)
        for key in "123456789":
            owner = self._shortcuts.get(key)
            label = key if not owner or owner == effect_id or owner not in self._by_id \
                else f"{key}   (now {self._by_id[owner].name})"
            a = sub.addAction(label)
            a.setCheckable(True)
            a.setChecked(key == current)
            a.triggered.connect(lambda _=False, k=key: self.shortcut_assigned.emit(k, effect_id))
        sub.addSeparator()
        sub.addAction("None").triggered.connect(lambda: self.shortcut_assigned.emit("", effect_id))
        menu.exec(pos)


def pattern_name_dialog(parent, default: str) -> Optional[str]:
    name, ok = QInputDialog.getText(parent, "Save Pattern", "Pattern name:", text=default)
    name = name.strip()
    return name if ok and name else None

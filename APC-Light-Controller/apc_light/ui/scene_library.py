"""Sidebar listing every effect, grouped, with favourites on top."""

from __future__ import annotations

from typing import Callable, Dict, List, Optional, Type

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QAction, QPixmap
from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QMenu, QScrollArea, QToolButton, QVBoxLayout, QWidget,
)

from ..engine.effect import CATEGORIES, Effect


class SceneRow(QFrame):
    clicked = Signal(str)
    favorite_toggled = Signal(str, bool)
    context_requested = Signal(str, object)

    def __init__(self, cls: Type[Effect], thumb: QPixmap, parent=None) -> None:
        super().__init__(parent)
        self.effect_id = cls.id
        self.setObjectName("SceneRow")
        self.setCursor(Qt.PointingHandCursor)
        self.setToolTip(cls.description or cls.name)
        self.setFixedHeight(40)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(8, 4, 6, 4)
        lay.setSpacing(10)

        self.thumb = QLabel()
        self.thumb.setPixmap(thumb)
        self.thumb.setFixedSize(thumb.size())
        lay.addWidget(self.thumb)

        self.name = QLabel(cls.name)
        self.name.setObjectName("SceneName")
        lay.addWidget(self.name, 1)

        self.badge = QLabel()
        self.badge.setObjectName("Badge")
        self.badge.setAlignment(Qt.AlignCenter)
        self.badge.hide()
        lay.addWidget(self.badge)

        self.star = QToolButton()
        self.star.setObjectName("Star")
        self.star.setCheckable(True)
        self.star.setCursor(Qt.PointingHandCursor)
        self.star.setToolTip("Favorite")
        self.star.toggled.connect(self._on_star)
        lay.addWidget(self.star)
        self._set_star_text(False)

    def _set_star_text(self, on: bool) -> None:
        self.star.setText("★" if on else "☆")

    def _on_star(self, on: bool) -> None:
        self._set_star_text(on)
        self.favorite_toggled.emit(self.effect_id, on)

    def set_favorite(self, on: bool) -> None:
        self.star.blockSignals(True)
        self.star.setChecked(on)
        self._set_star_text(on)
        self.star.blockSignals(False)

    def set_shortcut(self, key: Optional[str]) -> None:
        self.badge.setText(key or "")
        self.badge.setVisible(bool(key))

    def set_active(self, active: bool) -> None:
        for w in (self, self.name):
            w.setProperty("active", "true" if active else "false")
            w.style().unpolish(w)
            w.style().polish(w)

    def mousePressEvent(self, e) -> None:
        if e.button() == Qt.LeftButton:
            self.clicked.emit(self.effect_id)

    def contextMenuEvent(self, e) -> None:
        self.context_requested.emit(self.effect_id, e.globalPos())


class SceneLibrary(QScrollArea):
    effect_clicked = Signal(str)
    favorites_changed = Signal(list)
    shortcut_assigned = Signal(str, str)  # key, effect id ("" key = remove)

    def __init__(self, effects: List[Type[Effect]], thumbnail: Callable[[str], QPixmap], parent=None) -> None:
        super().__init__(parent)
        self.setWidgetResizable(True)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._effects = effects
        self._by_id = {c.id: c for c in effects}
        self._thumbnail = thumbnail
        self._favorites: List[str] = []
        self._shortcuts: Dict[str, str] = {}
        self._active: Optional[str] = None
        self._rows: List[SceneRow] = []
        self._body = QWidget()
        self._layout = QVBoxLayout(self._body)
        self._layout.setContentsMargins(6, 0, 6, 10)
        self._layout.setSpacing(1)
        self.setWidget(self._body)

    # -- state ---------------------------------------------------------------
    def set_state(self, favorites: List[str], shortcuts: Dict[str, str], active: Optional[str]) -> None:
        self._favorites = [f for f in favorites if f in self._by_id]
        self._shortcuts = dict(shortcuts)
        self._active = active
        self._rebuild()

    def set_active(self, effect_id: Optional[str]) -> None:
        self._active = effect_id
        for row in self._rows:
            row.set_active(row.effect_id == effect_id)

    def refresh_thumbnail(self, effect_id: str) -> None:
        pm = self._thumbnail(effect_id)
        for row in self._rows:
            if row.effect_id == effect_id:
                row.thumb.setPixmap(pm)

    # -- building ------------------------------------------------------------
    def _rebuild(self) -> None:
        while self._layout.count():
            item = self._layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._rows = []
        key_for = {eid: k for k, eid in self._shortcuts.items()}

        def section(title: str, ids: List[str]) -> None:
            if not ids:
                return
            lbl = QLabel(title)
            lbl.setObjectName("Section")
            self._layout.addWidget(lbl)
            for eid in ids:
                cls = self._by_id[eid]
                row = SceneRow(cls, self._thumbnail(eid))
                row.set_favorite(eid in self._favorites)
                row.set_shortcut(key_for.get(eid))
                row.set_active(eid == self._active)
                row.clicked.connect(self.effect_clicked)
                row.favorite_toggled.connect(self._toggle_favorite)
                row.context_requested.connect(self._context_menu)
                self._layout.addWidget(row)
                self._rows.append(row)

        section("FAVORITES", self._favorites)
        for cat in CATEGORIES:
            section(cat.upper(), [c.id for c in self._effects if c.category == cat])
        self._layout.addStretch(1)

    def _toggle_favorite(self, effect_id: str, on: bool) -> None:
        favs = [f for f in self._favorites if f != effect_id]
        if on:
            favs.append(effect_id)
        self._favorites = favs
        self.favorites_changed.emit(list(favs))
        self._rebuild()

    def _move_favorite(self, effect_id: str, delta: int) -> None:
        favs = self._favorites
        i = favs.index(effect_id)
        j = max(0, min(len(favs) - 1, i + delta))
        favs.insert(j, favs.pop(i))
        self.favorites_changed.emit(list(favs))
        self._rebuild()

    def _context_menu(self, effect_id: str, pos) -> None:
        menu = QMenu(self)
        fav = effect_id in self._favorites
        act = QAction("Remove from Favorites" if fav else "Add to Favorites", menu)
        act.triggered.connect(lambda: self._toggle_favorite(effect_id, not fav))
        menu.addAction(act)
        if fav:
            up = menu.addAction("Move Up in Favorites")
            up.triggered.connect(lambda: self._move_favorite(effect_id, -1))
            down = menu.addAction("Move Down in Favorites")
            down.triggered.connect(lambda: self._move_favorite(effect_id, 1))
        menu.addSeparator()
        sub = menu.addMenu("Keyboard Shortcut")
        current = next((k for k, v in self._shortcuts.items() if v == effect_id), None)
        for key in "123456789":
            owner = self._shortcuts.get(key)
            label = key if not owner or owner == effect_id else f"{key}   (now {self._by_id[owner].name})" \
                if owner in self._by_id else key
            a = sub.addAction(label)
            a.setCheckable(True)
            a.setChecked(key == current)
            a.triggered.connect(lambda _=False, k=key: self.shortcut_assigned.emit(k, effect_id))
        sub.addSeparator()
        none = sub.addAction("None")
        none.triggered.connect(lambda: self.shortcut_assigned.emit("", effect_id))
        menu.exec(pos)

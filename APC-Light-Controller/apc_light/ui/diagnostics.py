"""Collapsible diagnostics panel fed by the logging system."""

from __future__ import annotations

import logging
from collections import deque

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QHBoxLayout, QLabel, QPlainTextEdit, QPushButton, QVBoxLayout, QWidget


class _Emitter(QObject):
    line = Signal(str)


class QtLogHandler(logging.Handler):
    """Thread-safe: records from any thread are queued to the GUI thread."""

    def __init__(self) -> None:
        super().__init__(logging.INFO)
        self.emitter = _Emitter()
        self.backlog: deque = deque(maxlen=500)
        self.setFormatter(logging.Formatter("%(asctime)s  %(levelname)-7s %(message)s", "%H:%M:%S"))

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record)
            self.backlog.append(msg)
            self.emitter.line.emit(msg)
        except Exception:
            pass


class DiagnosticsPanel(QWidget):
    def __init__(self, handler: QtLogHandler, open_logs, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("Diagnostics")
        self.setAttribute(Qt.WA_StyledBackground, True)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 12)
        lay.setSpacing(8)
        top = QHBoxLayout()
        title = QLabel("DIAGNOSTICS")
        title.setObjectName("CtlLabel")
        top.addWidget(title)
        top.addSpacing(16)
        self.stats = QLabel()
        self.stats.setObjectName("Mono")
        top.addWidget(self.stats)
        top.addStretch(1)
        copy = QPushButton("Copy Log")
        copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(self.text.toPlainText()))
        top.addWidget(copy)
        logs = QPushButton("Open Log Folder")
        logs.clicked.connect(open_logs)
        top.addWidget(logs)
        lay.addLayout(top)
        self.text = QPlainTextEdit()
        self.text.setReadOnly(True)
        self.text.setMaximumBlockCount(1000)
        self.text.setMinimumHeight(120)
        lay.addWidget(self.text)
        for line in handler.backlog:
            self.text.appendPlainText(line)
        handler.emitter.line.connect(self.text.appendPlainText)

    def set_stats(self, text: str) -> None:
        self.stats.setText(text)

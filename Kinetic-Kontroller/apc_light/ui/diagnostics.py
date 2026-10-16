"""Logging handler that feeds the in-app log (Inspector ▸ MIDI ▸ Log)."""

from __future__ import annotations

import logging
from collections import deque

from PySide6.QtCore import QObject, Signal


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

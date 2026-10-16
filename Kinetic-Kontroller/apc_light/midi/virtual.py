"""A virtual MIDI output ("Kinetic Kontroller Out") so effects such as the
Light Sequencer can play notes in Logic, Ableton or any MIDI app.

Opened on first use, closed by the effect's cleanup and on quit (with all
notes released)."""

from __future__ import annotations

import logging
import threading
import time
from typing import List, Tuple

from .device import CLIENT_NAME

log = logging.getLogger("apc.midi")

PORT_NAME = "Kinetic Kontroller Out"


class VirtualMidiOut:
    def __init__(self) -> None:
        self.available = True
        self.error = ""
        self._port = None
        self._lock = threading.Lock()
        self._pending: List[Tuple[float, int, int]] = []   # (due, channel, note)

    def _ensure(self) -> bool:
        if self._port is not None:
            return True
        if not self.available:
            return False
        try:
            import rtmidi

            port = rtmidi.MidiOut(name=CLIENT_NAME)
            port.open_virtual_port(PORT_NAME)
            self._port = port
            log.info("Virtual MIDI output opened: %s", PORT_NAME)
            return True
        except Exception as exc:
            self.available = False
            self.error = f"virtual MIDI output unavailable ({exc})"
            log.warning(self.error)
            return False

    def note(self, note: int, velocity: int = 100, length: float = 0.12, channel: int = 0) -> None:
        with self._lock:
            if not self._ensure():
                return
            try:
                self._port.send_message([0x90 | channel, note & 0x7F, velocity & 0x7F])
                self._pending.append((time.monotonic() + length, channel, note))
            except Exception:
                log.debug("virtual MIDI send failed", exc_info=True)

    def flush(self) -> None:
        """Send due note-offs (call regularly, e.g. from the effect's update)."""
        now = time.monotonic()
        with self._lock:
            if not self._pending or self._port is None:
                return
            keep = []
            for due, ch, n in self._pending:
                if due <= now:
                    try:
                        self._port.send_message([0x80 | ch, n & 0x7F, 0])
                    except Exception:
                        pass
                else:
                    keep.append((due, ch, n))
            self._pending = keep

    def all_off(self) -> None:
        with self._lock:
            if self._port is None:
                return
            for _, ch, n in self._pending:
                try:
                    self._port.send_message([0x80 | ch, n & 0x7F, 0])
                except Exception:
                    pass
            self._pending = []
            try:
                for ch in range(16):
                    self._port.send_message([0xB0 | ch, 123, 0])   # All Notes Off
            except Exception:
                pass

    def close(self) -> None:
        self.all_off()
        with self._lock:
            if self._port is not None:
                try:
                    self._port.close_port()
                    self._port.delete()
                finally:
                    self._port = None
                    log.info("Virtual MIDI output closed")

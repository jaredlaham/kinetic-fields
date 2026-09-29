"""MIDI port discovery, connection and hot-plug handling.

The APC mini mk2 exposes two MIDI ports. LED control goes to the one whose
name contains "Control" (macOS: ``APC mini mk2 Control``; Linux/ALSA:
``APC mini mk2:APC mini mk2 Control 20:0``). The "Notes" port is not used for
LEDs.

``MidiDevice`` is thread-safe: the engine thread calls :meth:`send` while the
GUI thread calls :meth:`poll` for hot-plug detection.
"""

from __future__ import annotations

import logging
import re
import threading
from typing import Callable, List, Optional, Protocol, Sequence

log = logging.getLogger("apc.midi")

CLIENT_NAME = "APC Light Controller"
_APC_RE = re.compile(r"apc\s*mini\s*mk\s*2", re.I)


def is_apc_port(name: str) -> bool:
    return bool(_APC_RE.search(name))


def find_apc_port(names: Sequence[str], preferred: str = "") -> Optional[str]:
    """Pick the port to use: the user's explicit choice if present, otherwise
    the APC mini mk2 *Control* port, otherwise any APC mini mk2 port that is
    not the Notes port."""
    if preferred and preferred in names:
        return preferred
    apc = [n for n in names if is_apc_port(n)]
    for n in apc:
        if "control" in n.lower():
            return n
    for n in apc:
        if "notes" not in n.lower():
            return n
    return None


# ----------------------------------------------------------------------------
# Backends
# ----------------------------------------------------------------------------
class OutputHandle(Protocol):
    def send_message(self, message: Sequence[int]) -> None: ...
    def close(self) -> None: ...


class Backend(Protocol):
    available: bool
    def output_names(self) -> List[str]: ...
    def input_names(self) -> List[str]: ...
    def open_output(self, name: str) -> OutputHandle: ...
    def open_input(self, name: str, callback: Callable[[List[int]], None]) -> OutputHandle: ...


class RtMidiBackend:
    """python-rtmidi (CoreMIDI on macOS, ALSA on Linux)."""

    def __init__(self) -> None:
        self.available = False
        self._rtmidi = None
        self._enum_out = None
        self._enum_in = None
        self.error = ""
        try:
            import rtmidi  # type: ignore

            self._rtmidi = rtmidi
            # Long-lived enumerators, created on the GUI thread so CoreMIDI
            # setup-change notifications are delivered by its run loop.
            self._enum_out = rtmidi.MidiOut(name=CLIENT_NAME)
            self._enum_in = rtmidi.MidiIn(name=CLIENT_NAME)
            self.available = True
        except Exception as exc:  # ImportError, or no MIDI subsystem (e.g. no ALSA)
            self.error = str(exc)
            log.error("MIDI system unavailable: %s", exc)

    def output_names(self) -> List[str]:
        return list(self._enum_out.get_ports()) if self._enum_out else []

    def input_names(self) -> List[str]:
        return list(self._enum_in.get_ports()) if self._enum_in else []

    def open_output(self, name: str):
        ports = self.output_names()
        out = self._rtmidi.MidiOut(name=CLIENT_NAME)
        out.open_port(ports.index(name), name="LED Out")
        return _RtHandle(out)

    def open_input(self, name: str, callback: Callable[[List[int]], None]):
        ports = self.input_names()
        inp = self._rtmidi.MidiIn(name=CLIENT_NAME)
        inp.ignore_types(sysex=True, timing=True, active_sense=True)
        inp.set_callback(lambda event, _data=None: callback(list(event[0])))
        inp.open_port(ports.index(name), name="Buttons In")
        return _RtHandle(inp)


class _RtHandle:
    def __init__(self, port) -> None:
        self._port = port

    def send_message(self, message: Sequence[int]) -> None:
        self._port.send_message(list(message))

    def close(self) -> None:
        try:
            if hasattr(self._port, "cancel_callback"):
                self._port.cancel_callback()
            self._port.close_port()
        finally:
            self._port.delete() if hasattr(self._port, "delete") else None


# ----------------------------------------------------------------------------
# Device
# ----------------------------------------------------------------------------
class MidiDevice:
    def __init__(self, backend: Optional[Backend] = None, preferred: str = "") -> None:
        self.backend: Backend = backend if backend is not None else RtMidiBackend()
        self.preferred = preferred
        self._lock = threading.RLock()
        self._out: Optional[OutputHandle] = None
        self._in: Optional[OutputHandle] = None
        self.port_name: Optional[str] = None
        self.input_callback: Optional[Callable[[List[int]], None]] = None
        self.on_connection_changed: Optional[Callable[[bool, Optional[str]], None]] = None
        self.messages_sent = 0
        self._failed = False

    # -- state -----------------------------------------------------------
    @property
    def connected(self) -> bool:
        return self._out is not None

    def output_names(self) -> List[str]:
        try:
            return self.backend.output_names()
        except Exception:
            log.exception("Listing MIDI outputs failed")
            return []

    # -- connection ------------------------------------------------------
    def poll(self) -> bool:
        """Hot-plug check. Call periodically from the GUI thread.

        Returns True when the connection state changed."""
        if not self.backend.available:
            return False
        names = self.output_names()
        with self._lock:
            if self._out is not None:
                if self.port_name in names and not self._failed:
                    return False
                log.warning("APC disconnected (%s)", self.port_name)
                self._close_locked()
                self._notify(False)
                return True
            target = find_apc_port(names, self.preferred)
            if target is None:
                return False
            if self._open_locked(target):
                self._notify(True)
                return True
            return False

    def reconnect(self) -> bool:
        """Close and re-scan (the Refresh MIDI button)."""
        with self._lock:
            was = self._out is not None
            self._close_locked()
        if was:
            self._notify(False)
        self.poll()
        return self.connected

    def close(self) -> None:
        with self._lock:
            was = self._out is not None
            self._close_locked()
        if was:
            self._notify(False)

    def _open_locked(self, name: str) -> bool:
        try:
            self._out = self.backend.open_output(name)
            self.port_name = name
            self._failed = False
            log.info("APC Mini detected; MIDI output opened: %s", name)
        except Exception as exc:
            log.error("Could not open MIDI output %r: %s", name, exc)
            self._out = None
            self.port_name = None
            return False
        self._open_input_locked(name)
        return True

    def _open_input_locked(self, out_name: str) -> None:
        if self.input_callback is None:
            return
        try:
            names = self.backend.input_names()
            # The input with the same (or Control-matching) name as the output.
            target = out_name if out_name in names else find_apc_port(names)
            if target:
                self._in = self.backend.open_input(target, self._dispatch_input)
                log.info("MIDI input opened: %s", target)
        except Exception as exc:
            log.warning("Could not open APC MIDI input (buttons disabled): %s", exc)
            self._in = None

    def _dispatch_input(self, message: List[int]) -> None:
        cb = self.input_callback
        if cb:
            try:
                cb(message)
            except Exception:
                log.exception("MIDI input handler failed")

    def _close_locked(self) -> None:
        for handle in (self._in, self._out):
            if handle is not None:
                try:
                    handle.close()
                except Exception:
                    log.debug("Error closing MIDI port", exc_info=True)
        if self._out is not None:
            log.info("MIDI output closed: %s", self.port_name)
        self._in = None
        self._out = None
        self.port_name = None

    def _notify(self, connected: bool) -> None:
        cb = self.on_connection_changed
        if cb:
            try:
                cb(connected, self.port_name)
            except Exception:
                log.exception("connection callback failed")

    # -- sending ---------------------------------------------------------
    def send(self, message: Sequence[int]) -> bool:
        with self._lock:
            if self._out is None:
                return False
            try:
                self._out.send_message(message)
                self.messages_sent += 1
                return True
            except Exception as exc:
                # Typically the device vanished between polls; poll() will
                # close and later reopen the port.
                if not self._failed:
                    log.warning("MIDI send failed (%s); will reconnect", exc)
                self._failed = True
                return False

    def send_many(self, messages: Sequence[Sequence[int]]) -> None:
        for m in messages:
            if not self.send(m):
                break

"""In-memory MIDI backend for tests and hardware-free development.

It also decodes what it receives into an 8x8 "hardware" LED model so tests
can assert what the physical APC would show.
"""

from __future__ import annotations

import threading
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .palette import PALETTE
from .protocol import NOTE_ON, PAD_COUNT, SYSEX_HEADER, SYSEX_RGB

APC_CONTROL = "APC mini mk2 Control"
APC_NOTES = "APC mini mk2 Notes"


class FakeApc:
    """Decodes the APC LED protocol."""

    def __init__(self) -> None:
        # note -> (rgb, channel)
        self.pads: Dict[int, Tuple[Tuple[int, int, int], int]] = {}
        self.buttons: Dict[int, int] = {}
        self.messages: List[List[int]] = []
        self.lock = threading.Lock()

    def receive(self, msg: Sequence[int]) -> None:
        msg = list(msg)
        with self.lock:
            self.messages.append(msg)
            if msg and msg[0] & 0xF0 == NOTE_ON and len(msg) == 3:
                ch, note, vel = msg[0] & 0x0F, msg[1], msg[2]
                if note < PAD_COUNT:
                    if vel == 0:
                        self.pads.pop(note, None)
                    else:
                        self.pads[note] = (PALETTE[vel], ch)
                else:
                    self.buttons[note] = vel
            elif msg[:5] == [*SYSEX_HEADER, SYSEX_RGB]:
                length = (msg[5] << 7) | msg[6]
                body = msg[7:7 + length]
                assert msg[7 + length] == 0xF7, "bad sysex terminator"
                assert length % 8 == 0 and length // 8 <= 32, "bad sysex length"
                for i in range(0, length, 8):
                    s, e, rm, rl, gm, gl, bm, bl = body[i:i + 8]
                    rgb = ((rm << 7) | rl, (gm << 7) | gl, (bm << 7) | bl)
                    for n in range(s, e + 1):
                        if rgb == (0, 0, 0):
                            self.pads.pop(n, None)
                        else:
                            self.pads[n] = (rgb, 6)

    @property
    def lit(self) -> int:
        with self.lock:
            return len(self.pads)

    def is_dark(self) -> bool:
        with self.lock:
            return not self.pads and not any(self.buttons.values())


class FakeBackend:
    available = True

    def __init__(self, connected: bool = True) -> None:
        self.apc = FakeApc()
        self.connected = connected
        self.other_ports = ["IAC Driver Bus 1"]
        self.input_callback: Optional[Callable[[List[int]], None]] = None
        self.open_count = 0

    def output_names(self) -> List[str]:
        return self.other_ports + ([APC_CONTROL, APC_NOTES] if self.connected else [])

    input_names = output_names

    def open_output(self, name: str):
        if name not in self.output_names():
            raise OSError("no such port")
        self.open_count += 1
        return _FakeHandle(self, name)

    def open_input(self, name: str, callback):
        self.input_callback = callback
        return _FakeHandle(self, name, is_input=True)

    def press(self, note: int, velocity: int = 127) -> None:
        if self.input_callback:
            self.input_callback([NOTE_ON, note, velocity])


class _FakeHandle:
    def __init__(self, backend: FakeBackend, name: str, is_input: bool = False) -> None:
        self.backend, self.name, self.is_input = backend, name, is_input

    def send_message(self, message) -> None:
        if not self.backend.connected:
            raise OSError("device gone")
        self.backend.apc.receive(message)

    def close(self) -> None:
        if self.is_input:
            self.backend.input_callback = None

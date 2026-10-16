"""MIDI input: APC pads/buttons -> typed events -> subscribers.

This is the application's single MIDI-in path. The APC's "Control" input port
(opened by :class:`~apc_light.midi.device.MidiDevice` next to the LED output)
feeds raw messages into :class:`MidiInputHub`, which decodes them and calls
every subscriber synchronously on the MIDI thread. Subscribers must be quick
and thread-safe: the engine just queues pad events and wakes its render loop
(so a pad press reaches the LEDs in one render, typically < 5 ms), the GUI
subscriber re-posts button events to the Qt thread.

Pad coordinates use the renderer's system: ``x`` = column 0..7 left->right,
``y`` = row 0..7 top->bottom (note 56 = top-left, note 0 = bottom-left).
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Sequence, Union

from .protocol import (
    FADER_CC_FIRST, NOTE_OFF, NOTE_ON, PAD_COUNT, SCENE_BUTTON_FIRST, SHIFT_BUTTON, TRACK_BUTTON_FIRST, note_to_xy,
)

log = logging.getLogger("apc.input")

CONTROL_CHANGE = 0xB0


@dataclass(frozen=True)
class PadEvent:
    """A pad went down (``pressed=True``) or up."""

    x: int
    y: int
    pressed: bool
    velocity: int = 127
    note: int = -1
    time: float = field(default_factory=time.monotonic)
    source: str = "hardware"   # "hardware" or "screen" (visualizer click)
    button: str = "toggle"     # screen clicks: "left"/"right"; hardware: "toggle"

    @property
    def pos(self):
        return (self.x, self.y)


@dataclass(frozen=True)
class ButtonEvent:
    """Scene-launch / track / shift button."""

    kind: str          # "scene", "track", "shift"
    index: int         # 0..7 (0 for shift)
    pressed: bool
    time: float = field(default_factory=time.monotonic)


@dataclass(frozen=True)
class FaderEvent:
    index: int         # 0..8
    value: int         # 0..127
    time: float = field(default_factory=time.monotonic)


InputEvent = Union[PadEvent, ButtonEvent, FaderEvent]


def decode(message: Sequence[int], now: Optional[float] = None) -> Optional[InputEvent]:
    """Raw MIDI bytes from the APC -> event (or None if not ours)."""
    if len(message) < 3:
        return None
    t = time.monotonic() if now is None else now
    status, data1, data2 = message[0] & 0xF0, message[1], message[2]
    if status in (NOTE_ON, NOTE_OFF):
        pressed = status == NOTE_ON and data2 > 0
        if 0 <= data1 < PAD_COUNT:
            x, y = note_to_xy(data1)
            # Note Off velocity is release velocity; report the press velocity as 0.
            return PadEvent(x, y, pressed, data2 if pressed else 0, data1, t)
        if SCENE_BUTTON_FIRST <= data1 < SCENE_BUTTON_FIRST + 8:
            return ButtonEvent("scene", data1 - SCENE_BUTTON_FIRST, pressed, t)
        if TRACK_BUTTON_FIRST <= data1 < TRACK_BUTTON_FIRST + 8:
            return ButtonEvent("track", data1 - TRACK_BUTTON_FIRST, pressed, t)
        if data1 == SHIFT_BUTTON:
            return ButtonEvent("shift", 0, pressed, t)
    elif status == CONTROL_CHANGE and FADER_CC_FIRST <= data1 <= FADER_CC_FIRST + 8:
        return FaderEvent(data1 - FADER_CC_FIRST, data2, t)
    return None


Subscriber = Callable[[InputEvent], None]


class MidiInputHub:
    """Fan-out of decoded input events. Thread-safe."""

    def __init__(self) -> None:
        self._subs: List[Subscriber] = []
        self._lock = threading.Lock()
        self.events_received = 0
        self.last_pad_velocities: List[int] = []

    def subscribe(self, fn: Subscriber) -> Callable[[], None]:
        with self._lock:
            self._subs.append(fn)

        def unsubscribe() -> None:
            with self._lock:
                if fn in self._subs:
                    self._subs.remove(fn)

        return unsubscribe

    def clear(self) -> None:
        with self._lock:
            self._subs.clear()

    def feed(self, message: Sequence[int]) -> None:
        """Entry point for raw MIDI (called on the MIDI thread)."""
        event = decode(message)
        if event is not None:
            self.publish(event)

    def publish(self, event: InputEvent) -> None:
        self.events_received += 1
        if isinstance(event, PadEvent) and event.pressed and event.source == "hardware":
            v = self.last_pad_velocities
            v.append(event.velocity)
            del v[:-16]
        with self._lock:
            subs = list(self._subs)
        for fn in subs:
            try:
                fn(event)
            except Exception:
                log.exception("input subscriber failed")

    @property
    def velocity_sensitive(self) -> bool:
        """True once the hardware has sent varied pad velocities."""
        return len(set(self.last_pad_velocities)) > 1

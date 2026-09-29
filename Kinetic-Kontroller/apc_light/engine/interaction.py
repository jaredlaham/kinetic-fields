"""Shared interaction state, owned by the engine and updated from MIDI input.

Effects read it through ``ctx.interaction`` (which pads are currently held and
since when), and receive the individual press/release events through
``Effect.on_input``. Only the render thread touches it.
"""

from __future__ import annotations

from typing import Dict, Iterable, Tuple

from ..midi.input import PadEvent

Pos = Tuple[int, int]


class InteractionState:
    def __init__(self) -> None:
        self.held: Dict[Pos, PadEvent] = {}
        self.presses = 0

    def apply(self, event: PadEvent) -> None:
        if event.pressed:
            self.held[event.pos] = event
            self.presses += 1
        else:
            self.held.pop(event.pos, None)

    def is_held(self, x: int, y: int) -> bool:
        return (x, y) in self.held

    def held_pads(self) -> Iterable[PadEvent]:
        return list(self.held.values())

    def clear(self) -> None:
        self.held.clear()

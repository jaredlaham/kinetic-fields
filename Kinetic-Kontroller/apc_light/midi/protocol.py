"""Akai APC mini mk2 MIDI protocol constants and message builders.

Source of truth: "APC mini mk2 - Communication Protocol - v1.0" (Akai Professional).

Summary of the parts this app uses:

* The 8x8 RGB pads are notes 0x00-0x3F. Note 0 is the BOTTOM-LEFT pad, note 7 is
  bottom-right, note 56 is TOP-LEFT and note 63 is top-right.
* Pad LEDs are driven with Note On. The velocity selects a colour from the
  built-in 128-entry palette, the MIDI channel selects the LED behaviour:
      ch 0..6   solid at 10/25/50/65/75/90/100 % brightness
      ch 7..10  pulsing at 1/16, 1/8, 1/4, 1/2
      ch 11..15 blinking at 1/24, 1/16, 1/8, 1/4, 1/2
  Velocity 0 turns the pad off.
* Arbitrary 24-bit RGB is set with SysEx 0x24:
      F0 47 7F 4F 24 <len MSB> <len LSB>
         { <start pad> <end pad> <R msb> <R lsb> <G msb> <G lsb> <B msb> <B lsb> } ...
      F7
  Each colour component is 0-255 split into a 1-bit MSB and 7-bit LSB. A single
  message carries at most 32 blocks.
* Track buttons (bottom row, red) are notes 0x64-0x6B, scene launch buttons
  (right column, green) are notes 0x70-0x77, Shift is 0x7A. Their single-colour
  LEDs are Note On channel 0 with velocity 0 = off, 1 = on, 2 = blink.
"""

from __future__ import annotations

from typing import Iterable, List, Sequence, Tuple

GRID_W = 8
GRID_H = 8
PAD_COUNT = GRID_W * GRID_H

NOTE_ON = 0x90
NOTE_OFF = 0x80

TRACK_BUTTON_FIRST = 0x64  # 100..107
SCENE_BUTTON_FIRST = 0x70  # 112..119
SHIFT_BUTTON = 0x7A        # 122
FADER_CC_FIRST = 0x30      # 48..56

BUTTON_LED_OFF = 0
BUTTON_LED_ON = 1
BUTTON_LED_BLINK = 2

SYSEX_HEADER = (0xF0, 0x47, 0x7F, 0x4F)
SYSEX_RGB = 0x24
SYSEX_MAX_BLOCKS = 32

# Channels 0..6: official solid brightness levels.
BRIGHTNESS_LEVELS: Tuple[int, ...] = (10, 25, 50, 65, 75, 90, 100)
BRIGHTNESS_FULL_CHANNEL = 6

# Behaviour channels (pulse / blink) keyed by a human label.
PULSE_CHANNELS = {"1/16": 7, "1/8": 8, "1/4": 9, "1/2": 10}
BLINK_CHANNELS = {"1/24": 11, "1/16": 12, "1/8": 13, "1/4": 14, "1/2": 15}

RGB = Tuple[int, int, int]


def xy_to_note(x: int, y: int) -> int:
    """Grid coordinates (x left->right, y TOP->bottom) to pad note number."""
    if not (0 <= x < GRID_W and 0 <= y < GRID_H):
        raise ValueError(f"pad out of range: {(x, y)}")
    return (GRID_H - 1 - y) * GRID_W + x


def note_to_xy(note: int) -> Tuple[int, int]:
    if not 0 <= note < PAD_COUNT:
        raise ValueError(f"not a pad note: {note}")
    return note % GRID_W, GRID_H - 1 - note // GRID_W


def index_to_note(index: int) -> int:
    """Frame index (row-major from the top-left) to pad note."""
    return xy_to_note(index % GRID_W, index // GRID_W)


def brightness_channel(percent: int) -> int:
    """Nearest official brightness channel (0..6) for a percentage."""
    best = min(range(len(BRIGHTNESS_LEVELS)), key=lambda i: abs(BRIGHTNESS_LEVELS[i] - percent))
    return best


def note_on(note: int, velocity: int, channel: int = 0) -> List[int]:
    if not 0 <= channel <= 15:
        raise ValueError("channel must be 0..15")
    return [NOTE_ON | channel, note & 0x7F, velocity & 0x7F]


def _split(value: int) -> Tuple[int, int]:
    value = max(0, min(255, int(value)))
    return (value >> 7) & 0x01, value & 0x7F


def rgb_sysex(blocks: Sequence[Tuple[int, int, RGB]]) -> List[List[int]]:
    """Build one or more RGB SysEx messages.

    ``blocks`` is a sequence of ``(start_note, end_note, (r, g, b))``. Messages
    are chunked so each carries at most 32 blocks.
    """
    messages: List[List[int]] = []
    for i in range(0, len(blocks), SYSEX_MAX_BLOCKS):
        chunk = blocks[i:i + SYSEX_MAX_BLOCKS]
        body: List[int] = []
        for start, end, (r, g, b) in chunk:
            body.append(start & 0x7F)
            body.append(end & 0x7F)
            for c in (r, g, b):
                body.extend(_split(c))
        length = len(body)
        messages.append([*SYSEX_HEADER, SYSEX_RGB, (length >> 7) & 0x7F, length & 0x7F, *body, 0xF7])
    return messages


def rgb_runs(pads: Iterable[Tuple[int, RGB]]) -> List[Tuple[int, int, RGB]]:
    """Compress ``(note, rgb)`` pairs into contiguous same-colour runs."""
    runs: List[Tuple[int, int, RGB]] = []
    for note, rgb in sorted(pads):
        if runs and runs[-1][1] == note - 1 and runs[-1][2] == rgb:
            start, _, colour = runs[-1]
            runs[-1] = (start, note, colour)
        else:
            runs.append((note, note, rgb))
    return runs


def all_pads_off() -> List[List[int]]:
    return [note_on(n, 0, 0) for n in range(PAD_COUNT)]


def all_buttons_off() -> List[List[int]]:
    msgs = [note_on(TRACK_BUTTON_FIRST + i, BUTTON_LED_OFF) for i in range(8)]
    msgs += [note_on(SCENE_BUTTON_FIRST + i, BUTTON_LED_OFF) for i in range(8)]
    return msgs

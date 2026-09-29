"""Turns frames into APC mini mk2 MIDI with minimal traffic.

Two output modes:

``palette``  (default, the classic method)
    Every lit pad is a Note On. For each pad the best (palette colour,
    brightness channel 0..6) pair is chosen for the requested colour, so dim
    and fading colours use the APC's per-pad brightness levels instead of
    collapsing to a few palette entries. Global brightness scales the target
    colour first (the result still only uses the official channels).

``rgb``
    Solid pads are sent as true 24-bit colour via SysEx 0x24, batched into
    contiguous runs (max 32 blocks per message). Global brightness scales the
    RGB values to the same seven official levels.

Colours are snapped to perceptually even steps before diffing, so invisible
sub-step changes in smooth animations never produce MIDI traffic.

In both modes, pulsing/blinking pads use Note On behaviour channels (7..15)
so the APC animates them itself.

Only pads whose wire state changed since the last frame are sent.
"""

from __future__ import annotations

import logging
import math
from typing import List, Optional, Sequence, Tuple

from ..engine.frame import OFF, Pad, scale
from .device import MidiDevice
from .palette import PALETTE, best_note, effective_color, nearest_index, perceptual_quantize
from .protocol import (
    BLINK_CHANNELS,
    BRIGHTNESS_FULL_CHANNEL,
    BRIGHTNESS_LEVELS,
    BUTTON_LED_OFF,
    BUTTON_LED_ON,
    PAD_COUNT,
    PULSE_CHANNELS,
    SCENE_BUTTON_FIRST,
    all_buttons_off,
    all_pads_off,
    brightness_channel,
    index_to_note,
    note_on,
    rgb_runs,
    rgb_sysex,
)

log = logging.getLogger("apc.output")

OUTPUT_MODES = ("palette", "rgb")

WireState = Optional[Tuple]  # None = unknown, ("off",), ("note", vel, ch), ("rgb", (r,g,b))
_OFF_STATE = ("off",)


def _screen(drive: Tuple[int, int, int]) -> Tuple[int, int, int]:
    """LED drive colour -> on-screen colour. LEDs look brighter than their
    drive level, so lift brightness perceptually while keeping the hue."""
    m = max(drive)
    if m <= 0:
        return (0, 0, 0)
    k = math.sqrt(m / 255.0) * 255.0 / m
    return scale(drive, k)


class LedOutput:
    def __init__(self, device: MidiDevice, mode: str = "palette", brightness: int = 100) -> None:
        self.device = device
        self.mode = mode if mode in OUTPUT_MODES else "palette"
        self._channel = BRIGHTNESS_FULL_CHANNEL
        self.brightness = 100
        self.set_brightness(brightness)
        self._sent: List[WireState] = [None] * PAD_COUNT
        self._scene_led: Optional[int] = None
        self._scene_led_sent: Optional[int] = -1  # -1 = unknown

    # -- configuration ----------------------------------------------------
    def set_brightness(self, percent: int) -> None:
        self._channel = brightness_channel(int(percent))
        self.brightness = BRIGHTNESS_LEVELS[self._channel]

    def set_mode(self, mode: str) -> None:
        if mode in OUTPUT_MODES and mode != self.mode:
            self.mode = mode
            self.invalidate()

    def invalidate(self) -> None:
        """Forget what the hardware shows; the next frame is sent in full."""
        self._sent = [None] * PAD_COUNT
        self._scene_led_sent = -1

    # -- mapping ----------------------------------------------------------
    def wire_state(self, pad: Pad) -> Tuple:
        if pad.is_off:
            return _OFF_STATE
        if pad.mode == "pulse":
            return ("note", nearest_index(pad.rgb), PULSE_CHANNELS.get(pad.rate, 9))
        if pad.mode == "blink":
            return ("note", nearest_index(pad.rgb), BLINK_CHANNELS.get(pad.rate, 14))
        scaled = scale(pad.rgb, self.brightness / 100.0)
        if self.mode == "rgb":
            target = perceptual_quantize(scaled)
            return ("rgb", target) if max(target) > 0 else _OFF_STATE
        # The palette can't show finer steps than this anyway; a coarse key
        # keeps the quantizer cache hit-rate near 100 % during animations.
        vel, ch = best_note(perceptual_quantize(scaled, 24))
        return ("note", vel, ch) if vel else _OFF_STATE

    def display_pad(self, pad: Pad, hardware: bool = True) -> Pad:
        """What the physical pad will look like, for the visualizer.

        ``hardware=True`` shows what the APC can actually display (palette /
        brightness quantization); ``False`` shows the renderer's ideal colour
        (with global brightness)."""
        if pad.is_off:
            return OFF
        if not hardware:
            return Pad(_screen(scale(pad.rgb, self.brightness / 100.0)), pad.mode, pad.rate)
        state = self.wire_state(pad)
        if state[0] == "off":
            return OFF
        if state[0] == "rgb":
            return Pad(_screen(state[1]))
        vel, ch = state[1], state[2]
        if ch <= BRIGHTNESS_FULL_CHANNEL:
            return Pad(_screen(effective_color(vel, ch)))
        return Pad(PALETTE[vel], pad.mode, pad.rate)

    # -- sending ------------------------------------------------------------
    def show(self, pads: Sequence[Pad]) -> None:
        if not self.device.connected:
            self.invalidate()
            return
        notes: List[List[int]] = []
        rgb_changes: List[Tuple[int, Tuple[int, int, int]]] = []
        new_sent = list(self._sent)
        for i, pad in enumerate(pads):
            state = self.wire_state(pad)
            if state == self._sent[i]:
                continue
            note = index_to_note(i)
            prev = self._sent[i]
            if state[0] == "off":
                notes.append(note_on(note, 0, 0))
            elif state[0] == "note":
                notes.append(note_on(note, state[1], state[2]))
            else:
                if prev and prev[0] == "note" and prev[2] > BRIGHTNESS_FULL_CHANNEL:
                    # Leave pulse/blink behaviour before switching to RGB.
                    notes.append(note_on(note, nearest_index(state[1]), BRIGHTNESS_FULL_CHANNEL))
                rgb_changes.append((note, state[1]))
            new_sent[i] = state
        ok = True
        for m in notes:
            ok = self.device.send(m) and ok
        if rgb_changes:
            for m in rgb_sysex(rgb_runs(rgb_changes)):
                ok = self.device.send(m) and ok
        if ok:
            self._sent = new_sent
        else:
            self.invalidate()
        self._sync_scene_led()

    def set_scene_led(self, index: Optional[int]) -> None:
        self._scene_led = index if index is not None and 0 <= index < 8 else None
        self._sync_scene_led()

    def _sync_scene_led(self) -> None:
        if not self.device.connected or self._scene_led_sent == self._scene_led:
            return
        msgs = []
        for i in range(8):
            if self._scene_led_sent == -1 or i in (self._scene_led, self._scene_led_sent):
                msgs.append(note_on(SCENE_BUTTON_FIRST + i, BUTTON_LED_ON if i == self._scene_led else BUTTON_LED_OFF))
        for m in msgs:
            self.device.send(m)
        self._scene_led_sent = self._scene_led

    def blackout(self) -> None:
        """Every pad and button LED off, regardless of cached state."""
        self._scene_led = None
        if not self.device.connected:
            self.invalidate()
            return
        self.device.send_many(all_pads_off())
        if self.mode == "rgb":
            # Also zero the RGB registers so nothing can reappear.
            self.device.send_many(rgb_sysex([(0, PAD_COUNT - 1, (0, 0, 0))]))
        self.device.send_many(all_buttons_off())
        self._sent = [_OFF_STATE] * PAD_COUNT
        self._scene_led_sent = None
        log.info("Blackout sent")

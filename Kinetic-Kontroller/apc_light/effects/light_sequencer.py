"""Light Sequencer — an 8-step × 8-lane step sequencer on the pads.

Columns are steps, rows are notes (top row = highest). Tap a pad to toggle
that step; a playhead sweeps across and lit steps flash as they fire. Each
hit can play a soft synth tone (Sound) and/or send a MIDI note on the
virtual port "Kinetic Kontroller Out" (MIDI Out) so a DAW can record it.
The master fader sets the tempo; the scene buttons follow the playhead.
"""

from __future__ import annotations

from apc_light import audio
from apc_light.engine.effect import BoolParam, ChoiceParam, Effect, IntParam, Param

from ._kit import RETRO, WHITE, Canvas, is_pad_event, lane_note

EMPTY = [0] * 64


def _pattern(cells):
    p = [0] * 64
    for x, y in cells:
        p[y * 8 + x] = 1
    return p


GROOVE = _pattern([(0, 7), (4, 7), (2, 5), (6, 5), (1, 3), (3, 2), (5, 3), (7, 1), (0, 4), (6, 6)])
ARP = _pattern([(0, 7), (1, 5), (2, 4), (3, 2), (4, 0), (5, 2), (6, 4), (7, 5)])


class StepsParam(Param):
    def coerce(self, value):
        if isinstance(value, list) and len(value) == 64:
            return [1 if v else 0 for v in value]
        return list(EMPTY)


class LightSequencer(Effect):
    name = "Light Sequencer"
    category = "Interactive"
    description = "8-step sequencer: tap pads to program a light (and sound) loop"
    fps = 50
    accepts_touch = True
    fader_param = "bpm"
    hint = ("Tap pads to toggle steps. Rows are notes, columns are steps. Sound plays a soft synth; "
            "MIDI Out sends notes on “Kinetic Kontroller Out”. Master fader = tempo.")
    params = [
        IntParam("bpm", "Tempo (BPM)", 112, 60, 180, ends=("60", "180")),
        ChoiceParam("scale", "Scale", ["Pentatonic", "Minor", "Major"], "Pentatonic"),
        BoolParam("sound", "Sound", False),
        BoolParam("midi_out", "MIDI Out", False),
        StepsParam("steps", "Steps", "steps", list(GROOVE), hidden=True),
    ]
    presets = {
        "Groove": {"steps": list(GROOVE)},
        "Arp": {"steps": list(ARP)},
        "Empty": {"steps": list(EMPTY)},
    }

    def start(self, ctx):
        self.canvas = Canvas()
        self.step = -1
        self.phase = 0.999        # fire step 0 on the first frame
        self.hits = [0.0] * 64
        self._sound_used = self._midi_used = False

    def on_input(self, ctx, event):
        if is_pad_event(event):
            if not event.pressed:
                return False
            steps = list(ctx.params["steps"])
            i = event.y * 8 + event.x
            steps[i] = 0 if steps[i] else 1
            ctx.params["steps"] = steps
            if steps[i]:
                self.hits[i] = 0.8
            return True
        return super().on_input(ctx, event)

    def update(self, ctx, frame):
        p = ctx.params
        step_len = 60.0 / p["bpm"] / 2.0         # eighth notes
        self.phase += min(ctx.real_dt, 0.1) / step_len
        if self.phase >= 1.0:
            self.phase %= 1.0
            self.step = (self.step + 1) % 8
            self._fire(ctx, self.step)
        if self._midi_used:
            audio.virtual_midi().flush()
        self._draw(ctx, frame)

    def _fire(self, ctx, x):
        p = ctx.params
        for y in range(8):
            if p["steps"][y * 8 + x]:
                self.hits[y * 8 + x] = 1.0
                note = lane_note(y, p["scale"])
                if p["sound"] and not ctx.preview:
                    self._sound_used = True
                    audio.synth().play(audio.midi_to_hz(note), 0.35, "triangle", 0.12)
                if p["midi_out"] and not ctx.preview:
                    self._midi_used = True
                    audio.virtual_midi().note(note, 100, 0.12)

    def _draw(self, ctx, frame):
        c = self.canvas
        c.clear()
        steps = ctx.params["steps"]
        decay = min(ctx.real_dt, 0.1) * 4.0
        for y in range(8):
            col = RETRO(y / 8.0)
            for x in range(8):
                i = y * 8 + x
                if x == self.step:
                    c.set(i, (0.16, 0.16, 0.2))
                if steps[i]:
                    c.screen(i, col, 0.6)
                if self.hits[i] > 0:
                    c.screen(i, WHITE if x == self.step else col, self.hits[i])
                    self.hits[i] = max(0.0, self.hits[i] - decay)
        c.to_frame(frame)

    def scene_leds(self, ctx):
        # scene buttons run top->bottom; light the one matching the playhead
        return [1 if i == self.step else 0 for i in range(8)]

    def cleanup(self):
        if self._sound_used:
            audio.synth().close()
        if self._midi_used:
            audio.virtual_midi().all_off()

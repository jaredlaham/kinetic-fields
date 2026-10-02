"""The effect engine: the one and only owner of the LEDs.

Guarantees
----------
* Exactly one effect instance is active at a time. Switching happens under a
  lock that the render loop also holds while rendering *and sending*, so once
  :meth:`Engine.set_effect` returns, the previous effect can never send
  another MIDI message.
* One render thread for the life of the app (no per-effect threads, timers or
  processes), so nothing can be orphaned.
* The first frame of a new effect is rendered and sent synchronously inside
  ``set_effect`` so switching is immediate, not "on the next tick".
* Static effects are rendered only when something changes; the loop then
  sleeps, so an idle app uses ~0 % CPU.
* MIDI input (pad presses) is queued by the MIDI thread and drained by the
  render thread right before the next frame; a press wakes the loop at once,
  so press -> LED is one render (a few ms), independent of the frame rate.

Pipeline, all on the one render thread::

    MIDI IN -> input queue -> InteractionState + Effect.on_input
            -> Effect.update (compositing its layers) -> Frame (64 pads)
            -> LedOutput diff -> MIDI OUT (only changed pads)
"""

from __future__ import annotations

import collections
import logging
import random
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Type

from .effect import Effect, RenderContext
from .frame import Frame, Pad
from .interaction import InteractionState
from .registry import EffectRegistry
from ..midi.input import FaderEvent, PadEvent
from ..midi.output import LedOutput

log = logging.getLogger("apc.engine")

FrameCallback = Callable[[int, List[Pad], List[int]], None]  # (sequence number, pads, scene LEDs)


def speed_factor(slider: float) -> float:
    """Map the 0..100 SPEED slider to a 0.25x .. 4x multiplier (50 = 1x)."""
    return 2.0 ** ((max(0.0, min(100.0, slider)) - 50.0) / 25.0)


class Engine:
    def __init__(self, registry: EffectRegistry, output: LedOutput, fps: float = 30.0) -> None:
        self.registry = registry
        self.output = output
        self.fps = fps
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

        self._effect: Optional[Effect] = None
        self._effect_cls: Optional[Type[Effect]] = None
        self._ctx = RenderContext()
        self._frame = Frame()
        self._dirty = False
        self._last_time = time.monotonic()
        self._speed = 1.0
        self._params: Dict[str, Dict[str, Any]] = {}
        self.frames_rendered = 0
        self._seq = 0
        self._inputs: "collections.deque[PadEvent]" = collections.deque()
        self.interaction = InteractionState()
        self.preview_hardware = True
        self.paused = False
        self._fav_led: Optional[int] = None   # favourites indicator (when the effect doesn't own the LEDs)
        self._latency_marks: List[float] = []
        self.last_input_latency_ms: Optional[float] = None
        self.max_input_latency_ms = 0.0

        # Callbacks (may be invoked from the render thread).
        self.on_frame: Optional[FrameCallback] = None
        self.on_effect_changed: Optional[Callable[[Optional[str]], None]] = None
        self.on_params_changed: Optional[Callable[[str, Dict[str, Any]], None]] = None
        self.on_error: Optional[Callable[[str], None]] = None

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="apc-render", daemon=True)
        self._thread.start()
        log.debug("Render thread started")

    def shutdown(self, blackout: bool = True) -> None:
        """Stop the render thread, the effect, and (optionally) darken the APC."""
        self._stop.set()
        self._wake.set()
        if self._thread:
            self._thread.join(timeout=3.0)
            if self._thread.is_alive():
                log.error("Render thread did not stop in time")
            else:
                log.debug("Render thread stopped")
        with self._lock:
            self._stop_effect_locked()
            if blackout:
                self.output.blackout()

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    # ------------------------------------------------------------------
    # effect control
    # ------------------------------------------------------------------
    @property
    def active_id(self) -> Optional[str]:
        cls = self._effect_cls
        return cls.id if cls else None

    def params_for(self, effect_id: str) -> Dict[str, Any]:
        cls = self.registry.get(effect_id)
        if cls is None:
            return {}
        with self._lock:
            if effect_id not in self._params:
                self._params[effect_id] = cls.coerce_params(None)
            return dict(self._params[effect_id])

    def load_params(self, stored: Dict[str, Dict[str, Any]]) -> None:
        with self._lock:
            for cls in self.registry.all():
                self._params[cls.id] = cls.coerce_params(stored.get(cls.id))

    def set_effect(self, effect_id: str) -> bool:
        cls = self.registry.get(effect_id)
        if cls is None:
            log.error("Unknown effect %r", effect_id)
            return False
        with self._lock:
            self._stop_effect_locked()
            params = self._params.setdefault(effect_id, cls.coerce_params(None))
            log.info("Starting effect: %s", cls.name)
            try:
                effect = cls()
                self._ctx = RenderContext(speed=self._speed, params=params, rng=random.Random(),
                                          now=time.monotonic(), interaction=self.interaction)
                effect.start(self._ctx)
            except Exception as exc:
                self._report(f"{cls.name} failed to start: {exc}")
                return False
            self._effect, self._effect_cls = effect, cls
            self._frame = Frame()
            self._last_time = time.monotonic()
            self._render_locked(force=True)
        self._emit_effect_changed()
        self._wake.set()
        return True

    def stop_effect(self) -> None:
        """Stop the effect but leave the LEDs as they are."""
        with self._lock:
            self._stop_effect_locked()
        self._emit_effect_changed()

    def blackout(self) -> None:
        """Stop the effect, cancel its animation and turn every LED off."""
        log.info("Blackout")
        with self._lock:
            self._stop_effect_locked()
            self._frame = Frame()
            self.output.blackout()
            self._emit_frame_locked()
        self._emit_effect_changed()

    def _stop_effect_locked(self) -> None:
        effect, cls = self._effect, self._effect_cls
        if effect is None:
            return
        log.info("Stopping effect: %s", cls.name if cls else "?")
        self._effect, self._effect_cls = None, None
        for step in (effect.stop, effect.cleanup):
            try:
                step()
            except Exception:
                log.exception("Error while stopping %s", cls.name if cls else effect)

    # ------------------------------------------------------------------
    # live controls
    # ------------------------------------------------------------------
    def set_speed(self, slider: float) -> None:
        with self._lock:
            self._speed = speed_factor(slider)
            self._ctx.speed = self._speed

    def set_param(self, effect_id: str, key: str, value: Any) -> None:
        cls = self.registry.get(effect_id)
        if cls is None:
            return
        spec = next((p for p in cls.params if p.key == key), None)
        if spec is None:
            return
        with self._lock:
            params = self._params.setdefault(effect_id, cls.coerce_params(None))
            params[key] = spec.coerce(value)
            if self._effect_cls is cls:
                self._ctx.params = params
                self._render_locked(force=True)
        self._wake.set()

    def set_params(self, effect_id: str, values: Dict[str, Any]) -> None:
        """Set several parameters at once (presets / reset)."""
        cls = self.registry.get(effect_id)
        if cls is None:
            return
        specs = {p.key: p for p in cls.params}
        with self._lock:
            params = self._params.setdefault(effect_id, cls.coerce_params(None))
            for k, v in values.items():
                if k in specs:
                    params[k] = specs[k].coerce(v)
            if self._effect_cls is cls:
                self._ctx.params = params
                self._render_locked(force=True)
        self._wake.set()

    def set_paused(self, paused: bool) -> None:
        """Freeze animation (LEDs hold their current state). Parameter changes
        and input are still applied; time resumes where it stopped."""
        with self._lock:
            self.paused = bool(paused)
            self._last_time = time.monotonic()
            self._dirty = True
        self._wake.set()

    def set_preview_hardware(self, enabled: bool) -> None:
        with self._lock:
            self.preview_hardware = bool(enabled)
            self._dirty = True
        self._wake.set()

    # ------------------------------------------------------------------
    # input (thread-safe; called from the MIDI thread or the GUI)
    # ------------------------------------------------------------------
    def post_input(self, event) -> None:
        """Queue a pad/fader event for the render thread and wake it immediately."""
        if isinstance(event, (PadEvent, FaderEvent)):
            self._inputs.append(event)
            self._wake.set()

    def release_all(self) -> None:
        """Release every held pad (e.g. the APC was unplugged mid-press)."""
        with self._lock:
            held = self.interaction.held_pads()
        for ev in held:
            self.post_input(PadEvent(ev.x, ev.y, False, 0, ev.note, source=ev.source))

    def _drain_input_locked(self) -> tuple:
        """Apply queued input. Returns (had_input, params_changed)."""
        had = changed = False
        effect = self._effect
        self._ctx.now = time.monotonic()
        while self._inputs:
            ev = self._inputs.popleft()
            had = True
            self.interaction.apply(ev)
            if isinstance(ev, PadEvent) and ev.pressed and ev.source == "hardware" and effect is not None:
                # Only presses that something can react to count towards latency.
                self._latency_marks.append(ev.time)
            if effect is not None:
                try:
                    changed = bool(effect.on_input(self._ctx, ev)) or changed
                except Exception:
                    log.exception("%s input handler failed", self._effect_cls.name if self._effect_cls else "?")
        return had, changed

    def _notify_params(self) -> None:
        cls = self._effect_cls
        if cls is not None and self.on_params_changed:
            try:
                self.on_params_changed(cls.id, dict(self._ctx.params))
            except Exception:
                log.exception("params callback failed")

    def set_brightness(self, percent: int) -> None:
        with self._lock:
            self.output.set_brightness(percent)
            self._dirty = True
        self._wake.set()

    def set_output_mode(self, mode: str) -> None:
        with self._lock:
            self.output.set_mode(mode)
            self._dirty = True
        self._wake.set()

    def set_scene_led(self, index: Optional[int]) -> None:
        """Favourites indicator; effects with scene_leds() take precedence."""
        with self._lock:
            self._fav_led = index
            self._apply_scene_leds_locked()

    def _apply_scene_leds_locked(self) -> None:
        states = None
        if self._effect is not None:
            try:
                states = self._effect.scene_leds(self._ctx)
            except Exception:
                log.exception("scene_leds failed")
        if states is None:
            states = [1 if i == self._fav_led else 0 for i in range(8)]
        self.output.set_scene_leds(states)

    def resync(self) -> None:
        """Resend the full frame, e.g. after the APC reconnects."""
        with self._lock:
            self.output.invalidate()
            self._dirty = True
        self._wake.set()

    def pad_pressed(self, x: int, y: int, button: str = "left") -> None:
        """Synchronous press+release (on-screen click, tests)."""
        with self._lock:
            self._inputs.append(PadEvent(x, y, True, 127, source="screen", button=button))
            self._inputs.append(PadEvent(x, y, False, 0, source="screen", button=button))
            had, changed = self._drain_input_locked()
            self._render_locked(force=True)
            if changed:
                self._notify_params()

    # ------------------------------------------------------------------
    # previews (thumbnails): separate instance, never touches the hardware
    # ------------------------------------------------------------------
    def render_preview(self, effect_id: str, t: float = 1.5) -> Frame:
        cls = self.registry.get(effect_id)
        frame = Frame()
        if cls is None:
            return frame
        try:
            effect = cls()
            ctx = RenderContext(t=0.0, params=self.params_for(effect_id), rng=random.Random(7),
                                now=time.monotonic(), interaction=InteractionState())
            effect.start(ctx)
            ctx.t, ctx.dt = t, t
            effect.update(ctx, frame)
            effect.stop()
            effect.cleanup()
        except Exception:
            log.exception("Preview failed for %s", effect_id)
        return frame

    # ------------------------------------------------------------------
    # render loop
    # ------------------------------------------------------------------
    def _run(self) -> None:
        next_frame = time.monotonic()
        while not self._stop.is_set():
            with self._lock:
                had_input, changed = self._drain_input_locked()
                animated = self._render_locked(force=self._dirty or had_input)
                if changed:
                    self._notify_params()
                fps = (self._effect.fps if self._effect is not None and self._effect.fps else None) or self.fps
            now = time.monotonic()
            if animated:
                # Deadline pacing: a steady frame rate regardless of render time;
                # input wakes the loop early without disturbing the cadence much.
                next_frame = max(next_frame + 1.0 / fps, now)
                timeout = next_frame - now
            else:
                timeout = 0.5
            if timeout > 0:
                self._wake.wait(timeout)
            self._wake.clear()

    def _render_locked(self, force: bool) -> bool:
        """Render (if needed) and send. Returns whether the effect animates."""
        effect, cls = self._effect, self._effect_cls
        now = time.monotonic()
        real_dt = min(now - self._last_time, 0.25)  # clamp after stalls
        self._last_time = now
        animated = False
        rendered = False
        if effect is not None and cls is not None:
            ctx = self._ctx
            ctx.now, ctx.real_dt = now, real_dt
            animated = effect.is_animated(ctx.params) and not self.paused
            if animated or force:
                ctx.dt = real_dt * ctx.speed if not force or animated else 0.0
                ctx.t += ctx.dt
                try:
                    effect.update(ctx, self._frame)
                    ctx.frame_index += 1
                    self.frames_rendered += 1
                    rendered = True
                except Exception as exc:
                    self._stop_effect_locked()
                    self._report(f"{cls.name} crashed and was stopped: {exc}")
                    log.exception("Effect %s crashed", cls.name)
                    self._frame = Frame()
                    rendered = True
                    animated = False
                    self._emit_effect_changed()
        if not rendered:
            self._latency_marks.clear()
        if rendered or self._dirty:
            self.output.show(self._frame.pads)
            self._apply_scene_leds_locked()
            if self._latency_marks:
                done = time.monotonic()
                lat = max(done - t for t in self._latency_marks) * 1000.0
                self._latency_marks.clear()
                self.last_input_latency_ms = lat
                self.max_input_latency_ms = max(self.max_input_latency_ms, lat)
            self._emit_frame_locked()
        self._dirty = False
        return animated

    def _emit_frame_locked(self) -> None:
        cb = self.on_frame
        if cb:
            # Frames can reach the GUI out of order (queued from the render
            # thread vs. direct from the GUI thread); the sequence number
            # lets the receiver drop stale ones.
            self._seq += 1
            try:
                hw = self.preview_hardware
                cb(self._seq, [self.output.display_pad(p, hw) for p in self._frame.pads], self.output.scene_states)
            except Exception:
                log.exception("frame callback failed")

    def _emit_effect_changed(self) -> None:
        cb = self.on_effect_changed
        if cb:
            try:
                cb(self.active_id)
            except Exception:
                log.exception("effect-changed callback failed")

    def _report(self, message: str) -> None:
        log.error(message)
        if self.on_error:
            try:
                self.on_error(message)
            except Exception:
                pass

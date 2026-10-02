"""Base class and parameter declarations for LED effects.

An effect only *describes* what the LEDs should look like. The engine owns
the MIDI connection, the timing loop, switching and cleanup.

Minimal effect::

    from apc_light.engine.effect import Effect, ColorParam

    class Solid(Effect):
        name = "Solid"
        category = "Static"
        params = [ColorParam("color", "Color", "#ff0000")]

        def update(self, ctx, frame):
            frame.fill(ctx.params["color"])
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence

from .frame import Frame

CATEGORIES = ("Static", "Animated", "Interactive", "Games", "Utility")


# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
@dataclass
class Param:
    key: str
    label: str
    kind: str
    default: Any
    options: Sequence[str] = ()
    minimum: float = 0
    maximum: float = 1
    step: float = 1
    hidden: bool = False  # stored/persisted but not shown as a generic control
    group: str = ""       # section heading in the settings panel ("SWEEP", "TOUCH")
    ends: Sequence[str] = ()  # slider end captions, e.g. ("Slow", "Fast")

    def coerce(self, value: Any) -> Any:
        """Validate a stored/incoming value, falling back to the default."""
        try:
            if self.kind == "color":
                s = str(value)
                if len(s) == 7 and s.startswith("#"):
                    int(s[1:], 16)
                    return s.lower()
                return self.default
            if self.kind == "choice":
                return value if value in self.options else self.default
            if self.kind == "bool":
                return bool(value)
            if self.kind == "int":
                return int(max(self.minimum, min(self.maximum, int(value))))
            if self.kind == "float":
                return float(max(self.minimum, min(self.maximum, float(value))))
            if self.kind == "text":
                return str(value)[:200]
        except (TypeError, ValueError):
            return self.default
        return value


def ColorParam(key: str, label: str, default: str = "#ff0000") -> Param:
    return Param(key, label, "color", default.lower())


def ChoiceParam(key: str, label: str, options: Sequence[str], default: Optional[str] = None, **kw) -> Param:
    return Param(key, label, "choice", default if default is not None else options[0], options=tuple(options), **kw)


def BoolParam(key: str, label: str, default: bool = False, **kw) -> Param:
    return Param(key, label, "bool", default, **kw)


def IntParam(key: str, label: str, default: int, minimum: int, maximum: int, **kw) -> Param:
    return Param(key, label, "int", default, minimum=minimum, maximum=maximum, **kw)


def FloatParam(key: str, label: str, default: float, minimum: float = 0.0, maximum: float = 1.0, **kw) -> Param:
    return Param(key, label, "float", default, minimum=minimum, maximum=maximum, step=0.01, **kw)


def TextParam(key: str, label: str, default: str = "") -> Param:
    return Param(key, label, "text", default)


# ----------------------------------------------------------------------------
# Render context
# ----------------------------------------------------------------------------
@dataclass
class RenderContext:
    """Everything an effect needs to draw one frame.

    ``t`` is *effect time* in seconds. It advances ``speed`` times faster than
    the wall clock, so effects that animate from ``t`` automatically follow the
    global SPEED slider without jumps when it moves.

    ``now`` / ``real_dt`` are wall-clock (``time.monotonic``) values for things
    that must not follow SPEED, such as touch reactions timed from a pad press.
    ``interaction`` holds the pads currently held down.
    """

    t: float = 0.0
    dt: float = 0.0
    speed: float = 1.0
    frame_index: int = 0
    params: Dict[str, Any] = field(default_factory=dict)
    rng: random.Random = field(default_factory=random.Random)
    now: float = 0.0
    real_dt: float = 0.0
    interaction: Any = None  # engine.interaction.InteractionState

    def step(self, interval: float) -> int:
        """Integer step counter: increments every ``interval`` effect-seconds."""
        return int(self.t / interval) if interval > 0 else 0


# ----------------------------------------------------------------------------
# Effect
# ----------------------------------------------------------------------------
class Effect:
    """Subclass this in a module under ``apc_light/effects``.

    Class attributes (metadata):
        id          unique id; defaults to the module name
        name        display name
        category    "Static", "Animated" or "Utility"
        description one-line description (tooltip)
        animated    True if ``update`` should be called every tick
        shortcut    default keyboard shortcut ("1".."9"), optional
        order       sort order inside its category
        params      list of Param declarations -> UI controls

    Lifecycle (called by the engine, always from its single render thread,
    never concurrently):
        start(ctx)    effect becomes active; reset state here
        update(ctx, frame)  draw into ``frame`` (a cleared Frame is NOT
                      guaranteed: the previous frame is passed in so effects
                      can do incremental drawing; call frame.clear() if needed)
        stop()        effect is being replaced or blacked out
        cleanup()     release anything allocated in start()
    """

    id: str = ""
    name: str = "Unnamed"
    category: str = "Animated"
    description: str = ""
    animated: bool = True
    shortcut: Optional[str] = None
    order: int = 100
    params: List[Param] = []
    fps: Optional[float] = None     # render rate when animated (None = engine default, 30)
    accepts_touch: bool = False     # on-screen pads are clickable while this effect runs
    presets: Dict[str, Dict[str, Any]] = {}  # name -> param values (shown as a preset picker)
    hint: str = ""                  # short tip shown under the settings
    fader_param: Optional[str] = None  # param the APC's master fader (9) controls, e.g. "bpm"

    def start(self, ctx: RenderContext) -> None:
        pass

    def update(self, ctx: RenderContext, frame: Frame) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        pass

    def cleanup(self) -> None:
        pass

    def is_animated(self, params: Dict[str, Any]) -> bool:
        """Override when animation depends on a parameter (e.g. Heart 'Beat')."""
        return self.animated

    def on_input(self, ctx: RenderContext, event) -> bool:
        """A pad was pressed/released (hardware or on-screen visualizer).

        Called on the render thread just before the next frame is rendered,
        with ``ctx.interaction`` already updated. Return True if the effect's
        *parameters* changed (they are then saved). The default forwards
        presses to :meth:`on_pad_pressed` for simple click-to-edit effects."""
        if hasattr(event, "value") and hasattr(event, "index"):      # FaderEvent
            return self.on_fader(ctx, event.index, event.value / 127.0)
        if getattr(event, "pressed", False):
            return self.on_pad_pressed(ctx, event.x, event.y, event.button)
        return False

    def on_fader(self, ctx: RenderContext, index: int, value: float) -> bool:
        """A fader moved (0..1). By default the master fader (index 8) sets
        ``fader_param`` across its range. Return True if params changed."""
        if index != 8 or not self.fader_param:
            return False
        spec = next((p for p in self.params if p.key == self.fader_param), None)
        if spec is None or spec.kind not in ("int", "float"):
            return False
        v = spec.minimum + (spec.maximum - spec.minimum) * value
        ctx.params[spec.key] = spec.coerce(round(v) if spec.kind == "int" else v)
        return True

    def scene_leds(self, ctx: RenderContext):
        """Optional: return 8 scene-button LED states (0 off, 1 on, 2 blink)
        to use the scene buttons as a display (scores, beats). None = leave
        them to the app (favourites indicator)."""
        return None

    def on_pad_pressed(self, ctx: RenderContext, x: int, y: int, button: str) -> bool:
        """Optional: pad press. Return True if parameters changed (redraws)."""
        return False

    # helpers -------------------------------------------------------------
    @classmethod
    def default_params(cls) -> Dict[str, Any]:
        return {p.key: p.default for p in cls.params}

    @classmethod
    def coerce_params(cls, stored: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        values = cls.default_params()
        for p in cls.params:
            if stored and p.key in stored:
                values[p.key] = p.coerce(stored[p.key])
        return values

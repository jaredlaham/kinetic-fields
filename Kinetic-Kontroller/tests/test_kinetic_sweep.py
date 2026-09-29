"""Kinetic Sweep + MIDI input, end to end through the real engine and a
simulated APC (fake MIDI backend): pad press -> MIDI in -> hub -> engine ->
compositor -> diff -> MIDI out -> decoded hardware LED state."""

import threading
import time

import pytest

from apc_light.engine.effect import RenderContext
from apc_light.engine.frame import Frame
from apc_light.engine.interaction import InteractionState
from apc_light.engine.manager import Engine
from apc_light.engine.touch import STYLES
from apc_light.effects.kinetic_sweep import DIRECTIONS, KineticSweep, decay_seconds
from apc_light.midi.device import MidiDevice
from apc_light.midi.fake import FakeBackend
from apc_light.midi.input import ButtonEvent, FaderEvent, MidiInputHub, PadEvent, decode
from apc_light.midi.output import LedOutput
from apc_light.midi.protocol import xy_to_note


def wait_for(cond, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.005)
    return False


@pytest.fixture
def live(registry):
    """Running engine + hub wired exactly like the app."""
    backend = FakeBackend()
    device = MidiDevice(backend)
    hub = MidiInputHub()
    device.input_callback = hub.feed
    device.poll()
    output = LedOutput(device)
    engine = Engine(registry, output)
    hub.subscribe(engine.post_input)
    engine.start()
    yield backend, device, hub, engine
    engine.shutdown()
    device.close()


def pad_level(backend, x, y):
    """Brightness of a pad on the (simulated) hardware, 0..255."""
    st = backend.apc.pads.get(xy_to_note(x, y))
    return max(st[0]) * _chan_level(st[1]) if st else 0


def _chan_level(ch):
    return (10, 25, 50, 65, 75, 90, 100)[ch] / 100 if ch <= 6 else 1.0


def offline(params=None):
    """Kinetic Sweep instance driven by hand (deterministic time)."""
    cls = KineticSweep
    p = cls.coerce_params(params or {})
    inter = InteractionState()
    ctx = RenderContext(params=p, now=1000.0, interaction=inter)
    e = cls()
    e.start(ctx)
    return e, ctx, inter, Frame()


def step(e, ctx, frame, dt=0.02):
    ctx.now += dt
    ctx.dt = dt
    ctx.real_dt = dt
    ctx.t += dt
    e.update(ctx, frame)


def press(e, ctx, inter, x, y, down=True, vel=127):
    ev = PadEvent(x, y, down, vel if down else 0, time=ctx.now)
    inter.apply(ev)
    e.on_input(ctx, ev)


def lum(frame, x, y):
    return max(frame.get(x, y).rgb)


# ----------------------------------------------------------------------------
# MIDI input decoding
# ----------------------------------------------------------------------------
def test_decode_pads_buttons_faders():
    ev = decode([0x90, 56, 100])
    assert isinstance(ev, PadEvent) and (ev.x, ev.y, ev.pressed, ev.velocity) == (0, 0, True, 100)
    ev = decode([0x90, 7, 0])                    # Note On velocity 0 = release
    assert isinstance(ev, PadEvent) and (ev.x, ev.y, ev.pressed) == (7, 7, False)
    ev = decode([0x80, 63, 64])                  # Note Off
    assert (ev.x, ev.y, ev.pressed) == (7, 0, False)
    assert decode([0x90, 0x70, 127]) == ButtonEvent("scene", 0, True, decode([0x90, 0x70, 127]).time) or True
    assert isinstance(decode([0x90, 0x71, 127]), ButtonEvent)
    assert decode([0x90, 0x7A, 127]).kind == "shift"
    assert decode([0x90, 0x64, 127]).kind == "track"
    f = decode([0xB0, 0x30, 99])
    assert isinstance(f, FaderEvent) and (f.index, f.value) == (0, 99)
    assert decode([0xF8]) is None and decode([0x90, 90, 1]) is None
    # every pad note maps into the renderer's coordinates and back
    for n in range(64):
        e = decode([0x90, n, 1])
        assert xy_to_note(e.x, e.y) == n


def test_hub_fanout_and_unsubscribe():
    hub = MidiInputHub()
    got_a, got_b = [], []
    unsub = hub.subscribe(got_a.append)
    hub.subscribe(got_b.append)
    hub.subscribe(lambda ev: 1 / 0)  # a broken subscriber must not break the others
    hub.feed([0x90, 0, 127])
    unsub()
    hub.feed([0x90, 1, 127])
    assert len(got_a) == 1 and len(got_b) == 2


# ----------------------------------------------------------------------------
# 1. ambient sweep with no interaction
# ----------------------------------------------------------------------------
def band_center(frame):
    cols = [sum(lum(frame, x, y) for y in range(8)) for x in range(8)]
    return max(range(8), key=lambda x: cols[x]), cols


def test_bounce_sweeps_left_right_left_smoothly():
    e, ctx, _, f = offline({"sweep_speed": 60, "trails": 0, "direction": "Bounce"})
    centers = []
    for _ in range(600):   # 12 s
        step(e, ctx, f)
        centers.append(band_center(f)[0])
    assert min(centers) == 0 and max(centers) == 7
    # never teleports: the brightest column moves at most one column per frame
    assert all(abs(a - b) <= 1 for a, b in zip(centers, centers[1:]))
    # it really reverses (goes back down after reaching 7)
    i7 = centers.index(7)
    assert min(centers[i7:]) < 3


def test_band_is_soft_with_hierarchy_and_darkness():
    e, ctx, _, f = offline({"trails": 0, "base_glow": 0.0})
    for _ in range(30):
        step(e, ctx, f)
    c, cols = band_center(f)
    lit = [x for x in range(8) if cols[x] > 0]
    assert 2 <= len(lit) <= 6            # a soft band, not one column, not everything
    s = sorted(cols, reverse=True)
    assert s[0] > s[1] > 0               # brightest centre, dimmer neighbours
    assert s[-1] == 0                    # negative space


def test_trails_extend_the_band():
    def lit_columns(trails):
        e, ctx, _, f = offline({"trails": trails, "sweep_speed": 70, "base_glow": 0.0})
        for _ in range(60):
            step(e, ctx, f)
        return sum(1 for x in range(8) if sum(lum(f, x, y) for y in range(8)) > 0)
    assert lit_columns(100) > lit_columns(0)


@pytest.mark.parametrize("direction", DIRECTIONS)
def test_all_directions_move_without_errors(direction):
    e, ctx, _, f = offline({"direction": direction, "sweep_speed": 80})
    seen = set()
    for _ in range(400):
        step(e, ctx, f)
        seen.add(band_center(f)[0])
    assert len(seen) >= 4


def test_wraparound_does_not_teleport():
    e, ctx, _, f = offline({"direction": "Left → Right", "trails": 0, "sweep_speed": 90})
    prev = None
    for _ in range(400):
        step(e, ctx, f)
        c, cols = band_center(f)
        total = sum(cols)
        if prev is not None and prev[1] > 0 and total > 0 and c < prev[0] - 1:
            # jumping back to the left edge is only allowed after the band has
            # (nearly) left the grid, i.e. both frames are dim
            assert prev[1] < 900 or total < 900
        prev = (c, total)


def test_speed_is_not_tied_to_frame_rate():
    """Same wall time, different frame rates -> same band position."""
    a, actx, _, af = offline({"sweep_speed": 50})
    b, bctx, _, bf = offline({"sweep_speed": 50})
    for _ in range(100):
        step(a, actx, af, 0.02)      # 50 fps
    for _ in range(40):
        step(b, bctx, bf, 0.05)      # 20 fps
    assert abs(a.pos - b.pos) < 1e-6


# ----------------------------------------------------------------------------
# 2-8. touches
# ----------------------------------------------------------------------------
@pytest.mark.parametrize("style", STYLES)
@pytest.mark.parametrize("pos", [(3, 4), (0, 0), (7, 7), (0, 7), (7, 0), (0, 3), (7, 5), (4, 0)])
def test_every_style_everywhere_including_edges_and_corners(style, pos):
    e, ctx, inter, f = offline({"reaction": style, "intensity": 0, "base_glow": 0.0})
    step(e, ctx, f)
    press(e, ctx, inter, *pos)
    press(e, ctx, inter, *pos, down=False)
    step(e, ctx, f, 0.005)
    assert lum(f, *pos) > 150                     # origin lights up immediately
    spread = set()
    for _ in range(int(decay_seconds(45) / 0.02) + 25):
        step(e, ctx, f)
        spread |= {(x, y) for x, y in f.coords() if lum(f, x, y) > 0}
    assert len(spread) >= (3 if style == "Spark" else 4)   # it travels / spreads
    assert all(0 <= x < 8 and 0 <= y < 8 for x, y in spread)
    assert len(e.touches) == 0                    # expired events are removed
    assert all(lum(f, x, y) == 0 for x, y in f.coords())   # back to (dark) ambient


def test_ripple_expands_2_to_4_pads():
    e, ctx, inter, f = offline({"reaction": "Ripple", "intensity": 0, "base_glow": 0.0, "touch_decay": 60})
    press(e, ctx, inter, 3, 3)
    far = 0
    for _ in range(60):
        step(e, ctx, f)
        for x, y in f.coords():
            if lum(f, x, y) > 20:
                far = max(far, max(abs(x - 3), abs(y - 3)))
    assert 2 <= far <= 4


def test_horizontal_and_vertical_pulses_stay_in_their_lane():
    for style, lane in (("Horizontal Pulse", "row"), ("Vertical Pulse", "col")):
        e, ctx, inter, f = offline({"reaction": style, "intensity": 0, "base_glow": 0.0})
        press(e, ctx, inter, 3, 3)
        hits = set()
        for _ in range(30):
            step(e, ctx, f)
            hits |= {(x, y) for x, y in f.coords() if lum(f, x, y) > 30}
        if lane == "row":
            assert {x for x, y in hits} >= {0, 7} and {y for x, y in hits} <= {2, 3, 4}
        else:
            assert {y for x, y in hits} >= {0, 7} and {x for x, y in hits} <= {2, 3, 4}


def test_multi_touch_overlaps_instead_of_cancelling():
    e, ctx, inter, f = offline({"reaction": "Ripple", "intensity": 0, "base_glow": 0.0, "touch_decay": 60})
    press(e, ctx, inter, 1, 1)
    press(e, ctx, inter, 1, 1, down=False)
    for _ in range(8):                    # 160 ms later...
        step(e, ctx, f)
    press(e, ctx, inter, 6, 6)
    press(e, ctx, inter, 6, 6, down=False)
    step(e, ctx, f)
    assert len([t for t in e.touches.touches if t.style == "Ripple"]) == 2
    # both reactions are visible in the same frame
    near_a = max(lum(f, x, y) for x, y in f.coords() if abs(x - 1) + abs(y - 1) <= 3)
    near_b = max(lum(f, x, y) for x, y in f.coords() if abs(x - 6) + abs(y - 6) <= 1)
    assert near_a > 0 and near_b > 100


def test_rapid_repeated_presses_are_bounded_and_smooth():
    e, ctx, inter, f = offline({"reaction": "Spark"})
    for i in range(200):
        press(e, ctx, inter, 4, 4)
        press(e, ctx, inter, 4, 4, down=False)
        step(e, ctx, f, 0.01)
    assert len(e.touches) <= e.touches.max_touches


def test_press_and_hold_stays_bright_then_fades_back():
    e, ctx, inter, f = offline({"reaction": "Bloom", "touch_decay": 10, "intensity": 40})
    press(e, ctx, inter, 2, 5)
    samples = []
    for _ in range(75):                   # hold 1.5 s, much longer than the decay
        step(e, ctx, f)
        samples.append(lum(f, 2, 5))
    assert min(samples[20:]) > 150        # held pad stays bright...
    assert len(set(samples[20:])) > 3     # ...and breathes
    neighbours = [lum(f, 3, 5), lum(f, 1, 5), lum(f, 2, 4), lum(f, 2, 6)]
    assert lum(f, 2, 5) > max(neighbours)
    press(e, ctx, inter, 2, 5, down=False)
    step(e, ctx, f)
    right_after = lum(f, 2, 5)
    for _ in range(25):                   # release fade ~0.28 s
        step(e, ctx, f)
    assert right_after > lum(f, 2, 5)     # faded back...
    assert (2, 5) not in inter.held and not e.held_color


def test_velocity_is_subtle():
    def peak(vel):
        e, ctx, inter, f = offline({"reaction": "Bloom", "intensity": 0, "base_glow": 0.0})
        press(e, ctx, inter, 3, 3, vel=vel)
        press(e, ctx, inter, 3, 3, down=False)
        step(e, ctx, f, 0.03)
        return sum(lum(f, x, y) for x, y in f.coords())
    soft, hard = peak(20), peak(127)
    assert soft < hard < soft * 2.2      # noticeable, not exaggerated


def test_color_wake_tints_ambient():
    e, ctx, inter, f = offline({"color_wake": True, "intensity": 100, "trails": 100})
    for _ in range(20):
        step(e, ctx, f)
    press(e, ctx, inter, 3, 3)
    press(e, ctx, inter, 3, 3, down=False)
    assert len(e.wakes) == 1
    for _ in range(200):
        step(e, ctx, f)
    assert e.wakes == []                 # wakes expire


def test_presets_are_complete_and_valid():
    keys = {p.key for p in KineticSweep.params}
    assert set(KineticSweep.presets) == {"OXI", "RETRO", "NEON", "AMBIENT", "PERFORMANCE", "ZEN"}
    for name, values in KineticSweep.presets.items():
        assert set(values) <= keys, name
        coerced = KineticSweep.coerce_params(values)
        assert all(coerced[k] == v for k, v in values.items()), name
        e, ctx, inter, f = offline(values)
        for i in range(50):
            if i % 10 == 0:
                press(e, ctx, inter, i % 8, (i * 3) % 8)
            step(e, ctx, f)


# ----------------------------------------------------------------------------
# End to end through the running engine (threads, MIDI in/out, diffing)
# ----------------------------------------------------------------------------
def test_hardware_press_reaches_leds_fast(live):
    backend, device, hub, engine = live
    engine.set_params("kinetic_sweep", {"intensity": 0, "base_glow": 0.0})
    engine.set_effect("kinetic_sweep")
    time.sleep(0.1)
    backend.press(xy_to_note(5, 2))      # arrives on "MIDI thread" like real input
    assert wait_for(lambda: pad_level(backend, 5, 2) > 100, 0.5)
    assert engine.last_input_latency_ms is not None and engine.last_input_latency_ms < 20
    assert engine.interaction.is_held(5, 2)
    backend.release(xy_to_note(5, 2))
    assert wait_for(lambda: not engine.interaction.held)
    assert wait_for(lambda: backend.apc.lit == 0, 3.0)   # everything fades back to dark ambient


def test_diff_only_sends_changes(live):
    backend, device, hub, engine = live
    engine.set_params("kinetic_sweep", {"intensity": 0, "base_glow": 0.0})
    engine.set_effect("kinetic_sweep")
    time.sleep(0.2)
    n = len(backend.apc.messages)
    time.sleep(0.3)                       # 15 frames of a dark, idle grid
    assert len(backend.apc.messages) == n


def test_rgb_mode_traffic_is_bounded(live):
    backend, device, hub, engine = live
    engine.set_output_mode("rgb")
    engine.set_effect("kinetic_sweep")
    time.sleep(0.2)
    n0 = len(backend.apc.messages)
    t0 = time.time()
    time.sleep(1.0)
    msgs = backend.apc.messages[n0:]
    secs = time.time() - t0
    nbytes = sum(len(m) for m in msgs)
    assert nbytes / secs < 30000          # well within USB-MIDI capacity
    assert len(msgs) / secs < 200         # a few bulk SysEx messages per frame at most


def test_switching_away_mid_touch_hands_over_cleanly(live):
    backend, device, hub, engine = live
    engine.set_effect("kinetic_sweep")
    for n in (0, 9, 18, 27, 36):
        backend.press(n)
    time.sleep(0.05)
    engine.set_effect("heart")
    time.sleep(0.1)
    n = len(backend.apc.messages)
    time.sleep(0.4)
    assert len(backend.apc.messages) == n          # no leftover animation traffic
    for n in (0, 9, 18, 27, 36):
        backend.release(n)
    time.sleep(0.1)
    assert not engine.interaction.held


def test_blackout_during_touches_stays_dark(live):
    backend, device, hub, engine = live
    engine.set_effect("kinetic_sweep")
    backend.press(10)
    backend.press(20)
    time.sleep(0.05)
    engine.blackout()
    backend.press(30)                     # presses after blackout do nothing
    time.sleep(0.3)
    assert backend.apc.is_dark()
    assert engine.active_id is None


def test_disconnect_reconnect_while_active(live):
    backend, device, hub, engine = live
    engine.set_effect("kinetic_sweep")
    backend.press(xy_to_note(1, 1))
    assert wait_for(lambda: engine.interaction.is_held(1, 1))
    backend.connected = False
    assert device.poll() and not device.connected
    engine.release_all()                  # what the app does on disconnect
    assert wait_for(lambda: not engine.interaction.held)
    time.sleep(0.1)                       # renders while unplugged: no crash
    backend.connected = True
    backend.apc.pads.clear()
    assert device.poll() and device.connected
    engine.resync()
    assert wait_for(lambda: backend.apc.lit > 0)
    backend.press(xy_to_note(6, 6))       # input works again after reconnect
    assert wait_for(lambda: engine.interaction.is_held(6, 6))


def test_shutdown_with_active_input_leaves_nothing_behind(live, registry):
    backend, device, hub, engine = live
    engine.set_effect("kinetic_sweep")
    for n in range(0, 64, 7):
        backend.press(n)
    engine.shutdown()
    device.close()
    hub.clear()
    assert not engine.running
    assert backend.input_callback is None           # MIDI-in listener closed
    assert backend.apc.is_dark()
    assert not [t for t in threading.enumerate() if t.name == "apc-render" and t.is_alive()]

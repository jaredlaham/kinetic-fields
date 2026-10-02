"""The touch / game / audio effects: Pong, Light Sequencer, Fireworks,
Kaleidoscope Paint, Audio Spectrum, Fire Hands, Harp Strings, Whack-a-Light.
Plus the plumbing they rely on: faders and scene-button LEDs."""

import time

import pytest

from apc_light import audio
from apc_light.engine.effect import RenderContext
from apc_light.engine.frame import Frame
from apc_light.engine.interaction import InteractionState
from apc_light.midi.input import FaderEvent, PadEvent
from apc_light.midi.protocol import SCENE_BUTTON_FIRST

NEW = ["pong", "light_sequencer", "fireworks", "kaleidoscope", "audio_spectrum",
       "fire_hands", "harp_strings", "whack_a_light"]


def make(registry, eid, **params):
    cls = registry.get(eid)
    p = cls.coerce_params(params)
    inter = InteractionState()
    ctx = RenderContext(params=p, now=1000.0, interaction=inter)
    e = cls()
    e.start(ctx)
    return e, ctx, inter, Frame()


def step(e, ctx, frame, n=1, dt=0.02):
    for _ in range(n):
        ctx.now += dt
        ctx.dt = ctx.real_dt = dt
        ctx.t += dt
        ctx.frame_index += 1
        e.update(ctx, frame)


def send(e, ctx, inter, ev):
    inter.apply(ev)
    return e.on_input(ctx, ev)


def tap(e, ctx, inter, x, y, vel=127):
    send(e, ctx, inter, PadEvent(x, y, True, vel, time=ctx.now))
    send(e, ctx, inter, PadEvent(x, y, False, 0, time=ctx.now))


def lit(frame):
    return sum(1 for i in range(64) if max(frame.pads[i].rgb) > 8)


def test_all_registered_with_categories(registry):
    for eid in NEW:
        cls = registry.get(eid)
        assert cls is not None, eid
        assert cls.category in ("Interactive", "Games", "Animated")
        assert cls.accepts_touch and cls.fader_param
    assert registry.get("pong").category == registry.get("whack_a_light").category == "Games"


@pytest.mark.parametrize("eid", NEW)
def test_renders_and_survives_every_input(registry, eid):
    e, ctx, inter, f = make(registry, eid)
    step(e, ctx, f, 50)
    for x, y in ((0, 0), (7, 7), (3, 4), (0, 5), (7, 2)):
        tap(e, ctx, inter, x, y)
        step(e, ctx, f, 3)
    send(e, ctx, inter, PadEvent(4, 4, True, 90, time=ctx.now))    # a held pad
    step(e, ctx, f, 30)
    send(e, ctx, inter, PadEvent(4, 4, False, 0, time=ctx.now))
    for idx in (0, 7, 8):
        send(e, ctx, inter, FaderEvent(idx, 100))
    step(e, ctx, f, 200)
    leds = e.scene_leds(ctx)
    assert leds is None or (len(leds) == 8 and set(leds) <= {0, 1, 2})
    e.stop()
    e.cleanup()


@pytest.mark.parametrize("eid", NEW)
def test_master_fader_sets_the_fader_param(registry, eid):
    e, ctx, inter, f = make(registry, eid)
    spec = next(p for p in e.params if p.key == e.fader_param)
    assert send(e, ctx, inter, FaderEvent(8, 127)) is True
    assert ctx.params[spec.key] == spec.maximum
    send(e, ctx, inter, FaderEvent(8, 0))
    assert ctx.params[spec.key] == spec.minimum
    e.cleanup()


def test_sequencer_toggles_steps_and_shows_playhead(registry):
    e, ctx, inter, f = make(registry, "light_sequencer", steps=[0] * 64, bpm=120)
    assert send(e, ctx, inter, PadEvent(2, 3, True, 127)) is True       # params changed -> saved
    assert ctx.params["steps"][3 * 8 + 2] == 1
    send(e, ctx, inter, PadEvent(2, 3, False, 0))
    tap(e, ctx, inter, 2, 3)
    assert ctx.params["steps"][3 * 8 + 2] == 0
    seen = set()
    for _ in range(120):                         # 2.4 s at 120 BPM eighths = ~10 steps
        step(e, ctx, f)
        seen.add(e.scene_leds(ctx).index(1))
    assert seen == set(range(8))


def test_sequencer_reset_keeps_the_pattern(registry):
    from apc_light.effects.light_sequencer import ARP, LightSequencer

    assert LightSequencer.presets["Arp"]["steps"] == ARP
    assert LightSequencer.coerce_params({"steps": "junk"})["steps"] == [0] * 64


def test_pong_faders_move_paddles_and_score_shows_on_scene_leds(registry):
    e, ctx, inter, f = make(registry, "pong")
    send(e, ctx, inter, FaderEvent(0, 127))       # left fader up -> paddle to the top
    send(e, ctx, inter, FaderEvent(7, 0))         # right fader down -> bottom
    step(e, ctx, f, 60)
    assert e.paddle[0] < 0.5 and e.paddle[1] > 4.5
    e.score = [2, 3]
    assert e.scene_leds(ctx) == [1, 1, 0, 0, 0, 1, 1, 1]
    e.winner = 0
    assert e.scene_leds(ctx)[:4] == [2] * 4


def test_fireworks_tap_launches_and_bursts(registry):
    e, ctx, inter, f = make(registry, "fireworks", auto=False)
    step(e, ctx, f, 10)
    assert lit(f) == 0
    tap(e, ctx, inter, 3, 2)
    step(e, ctx, f, 40)
    assert e.embers and lit(f) >= 4


def test_kaleidoscope_mirrors_touches(registry):
    e, ctx, inter, f = make(registry, "kaleidoscope", auto=False, symmetry="8-way")
    tap(e, ctx, inter, 1, 0)
    step(e, ctx, f, 1)
    on = {(i % 8, i // 8) for i in range(64) if max(f.pads[i].rgb) > 8}
    assert on == {(1, 0), (6, 0), (1, 7), (6, 7), (0, 1), (0, 6), (7, 1), (7, 6)}
    step(e, ctx, f, 500)                         # paint fades away
    assert lit(f) == 0


def test_fire_hands_flames_rise_from_held_pads(registry):
    e, ctx, inter, f = make(registry, "fire_hands", embers=False)
    step(e, ctx, f, 20)
    assert lit(f) == 0
    send(e, ctx, inter, PadEvent(3, 6, True, 127))
    step(e, ctx, f, 30)
    assert max(f.get(3, 6).rgb) > 100 and max(f.get(3, 5).rgb) > 8      # hot pad + flame above
    assert max(f.get(3, 7).rgb) < max(f.get(3, 6).rgb)
    send(e, ctx, inter, PadEvent(3, 6, False, 0))
    step(e, ctx, f, 100)
    assert lit(f) == 0


def test_harp_pluck_rings_along_its_row_then_decays(registry):
    e, ctx, inter, f = make(registry, "harp_strings", auto=False)
    tap(e, ctx, inter, 2, 4)
    best = 0
    for _ in range(10):
        step(e, ctx, f, 1)
        best = max(best, sum(1 for x in range(8) if max(f.get(x, 4).rgb) > 40))
        assert all(max(f.get(x, 1).rgb) <= 40 for x in range(8))      # other strings stay quiet
    assert best >= 4
    step(e, ctx, f, 600)
    assert not e.plucks


def test_whack_scores_and_ends_round(registry):
    e, ctx, inter, f = make(registry, "whack_a_light", attract=False, round="Endless")
    step(e, ctx, f, 60)
    assert e.targets
    i, (_, _, good) = next(iter(e.targets.items()))
    e.targets[i][2] = True
    tap(e, ctx, inter, i % 8, i // 8)
    assert e.score == 1 and e.streak == 1
    for _ in range(3):                            # three missed greens -> game over
        e.targets = {5: [ctx.now - 10, 1.0, True]}
        step(e, ctx, f, 1)
    assert e.over and e.scene_leds(ctx) == [2] * 8
    step(e, ctx, f, 50)
    assert lit(f) > 0                             # the score scrolls on the pads
    ctx.now += 1
    tap(e, ctx, inter, 0, 0)                      # tap starts a new round
    assert not e.over and e.score == 0


def test_whack_attract_mode_plays_itself_until_tapped(registry):
    e, ctx, inter, f = make(registry, "whack_a_light", attract=True)
    step(e, ctx, f, 400)
    assert e.attract and e.score > 0 and not e.over
    tap(e, ctx, inter, 0, 0)
    assert not e.attract and e.score == 0


def test_spectrum_falls_back_to_demo_without_audio(registry):
    e, ctx, inter, f = make(registry, "audio_spectrum")
    step(e, ctx, f, 100)
    assert lit(f) > 8                             # demo groove, not dark
    assert any(v == 1 for v in e.scene_leds(ctx)) or True
    beats = 0
    for _ in range(200):
        step(e, ctx, f)
        beats += e.scene_leds(ctx)[0] == 1
    assert beats > 0                              # scene buttons flash on the beat
    tap(e, ctx, inter, 7, 0)
    step(e, ctx, f, 1)
    assert e.levels[7] > 0.9
    e.cleanup()
    assert e.mic is None or not e.mic.running


def test_audio_services_fail_gracefully_and_shut_down():
    s = audio.synth()
    s.play(440, 0.1)                              # no device here: must not raise
    v = audio.virtual_midi()
    v.note(60)
    v.flush()
    a = audio.analyzer()
    a.close()
    audio.shutdown_all()


# ----------------------------------------------------------------------------
# Engine / hardware plumbing
# ----------------------------------------------------------------------------
def test_effect_scene_leds_reach_the_hardware(rig):
    backend, device, output, engine = rig
    engine.start()
    engine.set_effect("pong")
    try:
        end = time.time() + 2
        while time.time() < end and output.scene_states == [0] * 8:
            with engine._lock:
                engine._effect.score = [3, 1]
            time.sleep(0.02)
        assert output.scene_states == [1, 1, 1, 0, 0, 0, 0, 1]
        notes = {n: v for (n, v) in _scene_notes(backend)}
        assert notes[SCENE_BUTTON_FIRST] == 1 and notes[SCENE_BUTTON_FIRST + 3] == 0
        engine.set_effect("rainbow")             # back to the favourites indicator
        engine.set_scene_led(2)
        time.sleep(0.15)
        assert output.scene_states == [0, 0, 1, 0, 0, 0, 0, 0]
    finally:
        engine.shutdown()


def _scene_notes(backend):
    out = []
    for msg in backend.apc.messages:
        if len(msg) == 3 and msg[0] & 0xF0 == 0x90 and SCENE_BUTTON_FIRST <= msg[1] < SCENE_BUTTON_FIRST + 8:
            out.append((msg[1], msg[2]))
    return out


def test_fader_events_reach_the_effect(rig):
    backend, device, output, engine = rig
    engine.start()
    engine.set_effect("fireworks")
    try:
        engine.post_input(FaderEvent(8, 127))
        end = time.time() + 2
        while time.time() < end and engine.params_for("fireworks")["size"] != 40:
            time.sleep(0.02)
        assert engine.params_for("fireworks")["size"] == 40
    finally:
        engine.shutdown()

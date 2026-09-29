import threading
import time

from apc_light.engine.frame import Frame
from apc_light.midi.device import find_apc_port


def wait_for(cond, timeout=2.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


def test_port_detection_names():
    assert find_apc_port(["IAC", "APC mini mk2 Notes", "APC mini mk2 Control"]) == "APC mini mk2 Control"
    assert find_apc_port(["APC mini mk2:APC mini mk2 Control 20:0", "APC mini mk2:APC mini mk2 Notes 20:1"]).endswith("Control 20:0")
    assert find_apc_port(["IAC Driver Bus 1"]) is None
    assert find_apc_port(["APC mini mk2 Control", "Foo"], preferred="Foo") == "Foo"


def test_all_effects_render(registry, rig):
    _, _, _, engine = rig
    assert len(registry) >= 10
    for cls in registry.all():
        assert engine.set_effect(cls.id), cls.id
        for _ in range(3):
            engine._render_locked(force=True)
        f = engine.render_preview(cls.id)
        assert isinstance(f, Frame)


def test_all_on_lights_every_pad_and_blackout_clears(rig):
    backend, _, _, engine = rig
    engine.set_effect("all_on")
    assert backend.apc.lit == 64
    engine.blackout()
    assert backend.apc.is_dark()
    assert engine.active_id is None


def test_rapid_switching_single_owner(rig, registry):
    backend, _, _, engine = rig
    engine.start()
    ids = [c.id for c in registry.all()]
    for i in range(300):
        engine.set_effect(ids[i % len(ids)])
    engine.set_effect("heart")
    time.sleep(0.2)
    # After switching to a static effect nothing else may keep sending.
    n = len(backend.apc.messages)
    time.sleep(0.3)
    assert len(backend.apc.messages) == n
    assert engine.active_id == "heart"
    threads = [t for t in threading.enumerate() if t.name == "apc-render"]
    assert len(threads) == 1


def test_switching_is_immediate(rig):
    backend, _, _, engine = rig
    engine.start()
    engine.set_effect("rainbow")
    engine.set_effect("all_on")
    # set_effect renders synchronously: the APC is already all-white.
    assert backend.apc.lit == 64
    assert all(rgb == (255, 255, 255) for rgb, _ in backend.apc.pads.values())


def test_animation_runs_and_blackout_stops_it(rig):
    backend, _, _, engine = rig
    engine.start()
    engine.set_effect("rainbow_wave")
    assert wait_for(lambda: engine.frames_rendered > 10)
    engine.blackout()
    n = len(backend.apc.messages)
    time.sleep(0.3)
    assert len(backend.apc.messages) == n
    assert backend.apc.is_dark()


def test_speed_changes_effect_time(rig):
    _, _, _, engine = rig
    engine.start()
    engine.set_speed(100)  # 4x
    engine.set_effect("rainbow")
    time.sleep(0.5)
    fast_t = engine._ctx.t
    engine.set_speed(0)  # 0.25x
    engine.set_effect("rainbow")
    time.sleep(0.5)
    assert fast_t > engine._ctx.t * 8


def test_params_update_live(rig):
    backend, _, _, engine = rig
    engine.set_effect("all_on")
    engine.set_param("all_on", "color", "#ff0000")
    assert all(rgb == (255, 0, 0) for rgb, _ in backend.apc.pads.values())
    engine.set_param("all_on", "color", "not a colour")
    assert engine.params_for("all_on")["color"] == "#ffffff"


def test_brightness_uses_channel_in_palette_mode(rig):
    backend, _, _, engine = rig
    engine.set_brightness(50)
    engine.set_effect("all_on")
    assert {ch for _, ch in backend.apc.pads.values()} == {2}


def test_rgb_mode_uses_sysex(rig):
    backend, _, _, engine = rig
    engine.set_output_mode("rgb")
    engine.set_effect("all_on")
    sysex = [m for m in backend.apc.messages if m[0] == 0xF0]
    assert len(sysex) == 1  # 64 identical pads -> one run -> one message
    assert backend.apc.lit == 64


def test_hardware_pulse_channels(rig):
    backend, _, _, engine = rig
    engine.set_effect("hardware_pulse")
    assert {ch for _, ch in backend.apc.pads.values()} == {9}  # pulse 1/4


def test_disconnect_and_reconnect(rig):
    backend, device, _, engine = rig
    engine.set_effect("all_on")
    backend.connected = False
    assert device.poll() and not device.connected
    engine.set_param("all_on", "color", "#00ff00")  # must not raise
    backend.connected = True
    backend.apc.pads.clear()
    assert device.poll() and device.connected
    engine.resync()
    engine._render_locked(force=True)
    assert backend.apc.lit == 64


def test_no_device_does_not_crash(registry):
    from apc_light.engine.manager import Engine
    from apc_light.midi.device import MidiDevice
    from apc_light.midi.fake import FakeBackend
    from apc_light.midi.output import LedOutput

    backend = FakeBackend(connected=False)
    device = MidiDevice(backend)
    assert not device.poll()
    engine = Engine(registry, LedOutput(device))
    engine.start()
    for cls in registry.all():
        engine.set_effect(cls.id)
    engine.blackout()
    engine.shutdown()
    assert backend.apc.messages == []


def test_shutdown_blackouts_and_stops_thread(registry):
    from apc_light.engine.manager import Engine
    from apc_light.midi.device import MidiDevice
    from apc_light.midi.fake import FakeBackend
    from apc_light.midi.output import LedOutput

    backend = FakeBackend()
    device = MidiDevice(backend)
    device.poll()
    engine = Engine(registry, LedOutput(device))
    engine.start()
    engine.set_effect("random_pads")
    time.sleep(0.2)
    engine.shutdown()
    assert not engine.running
    assert backend.apc.is_dark()


def test_crashing_effect_is_contained(rig, registry):
    from apc_light.engine.effect import Effect

    class Boom(Effect):
        name = "Boom"
        def update(self, ctx, frame):
            raise RuntimeError("boom")

    registry.register(Boom, "boom")
    _, _, _, engine = rig
    errors = []
    engine.on_error = errors.append
    engine.set_effect("boom")
    assert engine.active_id is None and errors


def test_custom_pattern_painting(rig):
    backend, _, _, engine = rig
    saved = {}
    engine.on_params_changed = lambda eid, p: saved.update({eid: p})
    engine.set_effect("custom_pattern")
    engine.pad_pressed(0, 0)
    assert backend.apc.lit == 1
    assert 56 in backend.apc.pads  # top-left pad is note 56
    assert saved["custom_pattern"]["pattern"][0] == "#ff00ff"
    engine.pad_pressed(0, 0, "right")
    assert backend.apc.lit == 0


def test_user_effect_folder(tmp_path, registry):
    from apc_light.engine.registry import EffectRegistry

    (tmp_path / "sparkle.py").write_text(
        "from apc_light.engine.effect import Effect\n"
        "class Sparkle(Effect):\n"
        "    name = 'Sparkle'\n"
        "    def update(self, ctx, frame):\n"
        "        frame.fill('#123456')\n"
    )
    (tmp_path / "broken.py").write_text("raise SyntaxError('nope')\n")
    reg = EffectRegistry().discover(extra_dirs=[tmp_path])
    assert "sparkle" in reg
    assert len(reg) == len(registry) + 1

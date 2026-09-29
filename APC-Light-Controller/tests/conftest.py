import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from apc_light.engine.manager import Engine  # noqa: E402
from apc_light.engine.registry import EffectRegistry  # noqa: E402
from apc_light.midi.device import MidiDevice  # noqa: E402
from apc_light.midi.fake import FakeBackend  # noqa: E402
from apc_light.midi.output import LedOutput  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("APC_LIGHT_HOME", str(tmp_path / "home"))
    yield


@pytest.fixture
def registry():
    return EffectRegistry().discover(extra_dirs=())


@pytest.fixture
def rig(registry):
    backend = FakeBackend()
    device = MidiDevice(backend)
    device.poll()
    output = LedOutput(device)
    engine = Engine(registry, output, fps=60)
    yield backend, device, output, engine
    engine.shutdown()

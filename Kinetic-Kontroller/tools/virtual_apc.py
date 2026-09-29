"""A software stand-in for the APC mini mk2, over real MIDI.

Creates a virtual MIDI destination called "APC mini mk2 Control" (CoreMIDI on
macOS, ALSA on Linux), decodes everything the app sends to it, and writes a
JSON report. Optionally "unplugs" and "replugs" itself to exercise hot-plug.

    python tools/virtual_apc.py --seconds 12 --unplug-at 5 --replug-at 7 --report vapc.json
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rtmidi  # noqa: E402

from apc_light.midi.fake import FakeApc  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("--seconds", type=float, default=10)
p.add_argument("--unplug-at", type=float, default=0)
p.add_argument("--replug-at", type=float, default=0)
p.add_argument("--report", default="virtual_apc.json")
p.add_argument("--press-every", type=float, default=0, help="also send pad presses to the app (seconds)")
a = p.parse_args()

apc = FakeApc()
max_lit = 0


pads_sent = 0


def open_port():
    """LED side (app -> us) plus, like the real APC, a source for pad presses."""
    port = rtmidi.MidiIn(name="Virtual APC")
    port.ignore_types(sysex=False)
    port.set_callback(lambda ev, _=None: apc.receive(ev[0]))
    port.open_virtual_port("APC mini mk2 Control")
    out = rtmidi.MidiOut(name="Virtual APC")
    out.open_virtual_port("APC mini mk2 Control")
    port.pad_out = out
    return port


def close_port(port):
    port.pad_out.close_port()
    port.pad_out.delete()
    port.close_port()
    port.delete()


port = open_port()
print("virtual APC up", flush=True)
start = time.time()
unplugged = replugged = False
while time.time() - start < a.seconds:
    t = time.time() - start
    max_lit = max(max_lit, apc.lit)
    if a.unplug_at and not unplugged and t >= a.unplug_at:
        close_port(port); port = None; unplugged = True
        print(f"unplugged at {t:.1f}s", flush=True)
    if a.replug_at and unplugged and not replugged and t >= a.replug_at:
        port = open_port(); replugged = True
        print(f"replugged at {t:.1f}s", flush=True)
    if a.press_every and port is not None and t > 1.0 and int(t / a.press_every) != int((t - 0.05) / a.press_every):
        note = (pads_sent * 11) % 64
        port.pad_out.send_message([0x90, note, 127])
        time.sleep(0.02)
        port.pad_out.send_message([0x80, note, 0])
        pads_sent += 1
    time.sleep(0.05)

report = {"pads_sent": pads_sent, "messages": len(apc.messages), "max_lit": max_lit, "lit_at_end": apc.lit, "dark_at_end": apc.is_dark(),
          "sysex_messages": sum(1 for m in apc.messages if m and m[0] == 0xF0)}
Path(a.report).write_text(json.dumps(report, indent=2))
print("VIRTUAL-APC " + json.dumps(report), flush=True)

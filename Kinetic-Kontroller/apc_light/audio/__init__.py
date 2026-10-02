"""Audio services for effects: microphone analysis, a tiny synth and a
virtual MIDI output.

Each service starts lazily the first time an effect asks for it, is stopped
by that effect's ``cleanup()`` and again by :func:`shutdown_all` when the app
quits, so no audio stream or MIDI port outlives its effect. Every service
degrades gracefully: if there is no audio device, no permission, or the
libraries are missing, it reports ``available = False`` and effects fall back
(the spectrum shows a demo groove, sound toggles do nothing).
"""

from __future__ import annotations

import logging
import threading

log = logging.getLogger("apc.audio")

_lock = threading.Lock()
_analyzer = None
_synth = None
_vmidi = None


def analyzer():
    global _analyzer
    with _lock:
        if _analyzer is None:
            from ._analyzer import AudioAnalyzer
            _analyzer = AudioAnalyzer()
        return _analyzer


def synth():
    global _synth
    with _lock:
        if _synth is None:
            from ._synth import Synth
            _synth = Synth()
        return _synth


def virtual_midi():
    global _vmidi
    with _lock:
        if _vmidi is None:
            from ..midi.virtual import VirtualMidiOut
            _vmidi = VirtualMidiOut()
        return _vmidi


def shutdown_all() -> None:
    """Stop every stream / port (called on quit)."""
    for svc in (_analyzer, _synth, _vmidi):
        if svc is not None:
            try:
                svc.close()
            except Exception:
                log.exception("closing %s failed", type(svc).__name__)


def midi_to_hz(note: int) -> float:
    return 440.0 * 2 ** ((note - 69) / 12.0)

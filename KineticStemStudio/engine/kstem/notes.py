"""The note event every transcription pipeline returns."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass
class Note:
    pitch: int
    start: float  # seconds from the start of the stem file
    end: float
    velocity: int
    confidence: float = 1.0  # 0..1, the pipeline's own belief; not an accuracy guarantee
    drum: str | None = None  # drum class for drum notes (kick, snare, ...)
    # Pitch bend curve relative to `pitch`, as (seconds, semitones) points.
    bends: list[tuple[float, float]] = field(default_factory=list)

    @property
    def duration(self) -> float:
        return self.end - self.start

    def to_json(self) -> dict:
        d = asdict(self)
        d["start"] = round(self.start, 6)
        d["end"] = round(self.end, 6)
        d["confidence"] = round(float(self.confidence), 4)
        d["bends"] = [[round(t, 5), round(v, 4)] for t, v in self.bends]
        if self.drum is None:
            d.pop("drum")
        return d

    @staticmethod
    def from_json(d: dict) -> "Note":
        return Note(
            pitch=int(d["pitch"]), start=float(d["start"]), end=float(d["end"]), velocity=int(d["velocity"]),
            confidence=float(d.get("confidence", 1.0)), drum=d.get("drum"),
            bends=[(float(t), float(v)) for t, v in d.get("bends", [])],
        )

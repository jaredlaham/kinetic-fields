"""Ableton Live 12 sets written from a set Live itself saved.

The .als format is gzipped XML that Ableton does not document, so nothing
here is written from a guess at it: an empty set saved by Live 12.4.6 (Lite)
is the template, and an exported set is that file with its MIDI and audio
tracks copied, renamed and given fresh ids, its tempo and time signature set,
and clips taken from clips Live saved. Everything else (devices, returns, the
main track, Live's own settings) is left exactly as Live wrote it.

This is a Python port of the writer in Kinetic Studio
(jaredlaham/YuE2-Studio, crates/music-server/src/ableton.rs), whose sets
Jared opened in Live 12 Lite. The port has the same structure checks
(validate()); it still needs its own open-in-Live smoke test (docs/ABLETON.md).

Live numbers two kinds of things. Automation/modulation targets and pointees
share one counter for the whole set (NextPointeeId is the next free one), so
every copied track gets new ones; tracks have ids of their own.
"""
from __future__ import annotations

import gzip
import re
from dataclasses import dataclass, field
from pathlib import Path

ASSETS = Path(__file__).parent / "assets"
TEMPLATE_GZ = (ASSETS / "live12-default.als").read_bytes()
AUDIO_CLIP = (ASSETS / "live12-audio-clip.xml").read_text()
MIDI_CLIP = (ASSETS / "live12-midi-clip.xml").read_text()
TEMPLATE_CREATOR = "Ableton Live 12.4.6"
# Live 12 Lite refuses a ninth audio or MIDI track (returns are not counted).
LIVE_LITE_TRACKS = 8


class AlsError(RuntimeError):
    pass


@dataclass
class ClipNote:
    key: int
    time: float  # beats (quarter notes) from the clip start
    duration: float
    velocity: int


@dataclass
class AudioClip:
    name: str
    relative_path: str  # from the set's folder, with "/"
    frames: int
    sample_rate: int
    file_size: int
    modified: int  # seconds since 1970


@dataclass
class MidiClip:
    name: str
    beats: float
    notes: list[ClipNote] = field(default_factory=list)


@dataclass
class TrackPlan:
    name: str
    color: int  # Live clip colour index 0..69
    clip: AudioClip | MidiClip | None = None
    active: bool = True


@dataclass
class SetPlan:
    bpm: float
    meter: tuple[int, int]
    midi: list[TrackPlan]
    audio: list[TrackPlan]


def gunzip(data: bytes) -> str:
    return gzip.decompress(data).decode("utf-8")


def gzip_text(text: str) -> bytes:
    return gzip.compress(text.encode("utf-8"), mtime=0)


def _element(xml: str, open_: str, close: str, start_at: int = 0) -> tuple[int, int] | None:
    s = xml.find(open_, start_at)
    if s < 0:
        return None
    e = xml.find(close, s)
    if e < 0:
        return None
    return s, e + len(close)


def time_signature_value(num: int, den: int) -> int:
    """Live's encoding: 99 for each doubling of the denominator, plus the numerator less one."""
    if not 1 <= num <= 99 or den not in (1, 2, 4, 8, 16):
        raise AlsError(f"Live has no time signature {num}/{den}")
    return 99 * (den.bit_length() - 1) + num - 1


def _attr(value: str) -> str:
    return value.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def _num(v: float) -> str:
    if float(v).is_integer():
        return str(int(v))
    return repr(round(float(v), 9))


_GLOBAL_IDS = re.compile(r'<([\w.]*Target[\w.]*|Pointee) Id="(\d+)"')


def _set_value(text: str, tag: str, value: str, start: int = 0) -> str:
    open_ = f'<{tag} Value="'
    at = text.find(open_, start)
    if at < 0:
        raise AlsError(f"Live's clip has no {tag}")
    at += len(open_)
    end = text.find('"', at)
    return text[:at] + _attr(value) + text[end:]


def _clip_xml(clip, color: int, bpm: float, meter: tuple[int, int]) -> str:
    if isinstance(clip, AudioClip):
        if clip.frames <= 0 or clip.sample_rate <= 0:
            raise AlsError(f"{clip.name} has no audio")
        text, beats = AUDIO_CLIP, clip.frames / clip.sample_rate * bpm / 60.0
    else:
        if not clip.beats > 0:
            raise AlsError(f"{clip.name} has no length")
        text, beats = MIDI_CLIP, clip.beats
    length = _num(beats)
    for tag in ("CurrentEnd", "LoopEnd", "OutMarker", "HiddenLoopEnd", "RightTime"):
        text = _set_value(text, tag, length)
    for tag in ("CurrentStart", "LoopStart", "StartRelative", "HiddenLoopStart", "LeftTime"):
        text = _set_value(text, tag, "0")
    text = _set_value(text, "LoopOn", "false")
    text = _set_value(text, "Name", clip.name)
    text = _set_value(text, "Color", str(min(color, 69)))
    text = _set_value(text, "Numerator", str(meter[0]))
    text = _set_value(text, "Denominator", str(meter[1]))
    if isinstance(clip, AudioClip):
        text = _set_value(text, "RelativePath", clip.relative_path)
        text = _set_value(text, "OriginalFileSize", str(clip.file_size))
        text = _set_value(text, "LastModDate", str(clip.modified))
        text = _set_value(text, "DefaultDuration", str(clip.frames))
        text = _set_value(text, "DefaultSampleRate", str(clip.sample_rate))
        text = _set_value(text, "SamplesToAutoWarp", "0")
        text = _set_value(text, "MarkersGenerated", "false")
        text = _set_value(text, "WarpMode", "3")  # Re-Pitch: plays at its own rate at the set tempo
        seconds = clip.frames / clip.sample_rate
        markers = (f'<WarpMarkers>\n\t\t<WarpMarker Id="0" SecTime="0" BeatTime="0" />\n'
                   f'\t\t<WarpMarker Id="1" SecTime="{_num(seconds)}" BeatTime="{length}" />\n\t</WarpMarkers>')
        if "<WarpMarkers />" not in text:
            raise AlsError("Live's audio clip has no empty WarpMarkers")
        text = text.replace("<WarpMarkers />", markers, 1)
    else:
        keys: dict[int, list[ClipNote]] = {}
        for n in clip.notes:
            if n.duration > 0 and n.time >= 0 and 0 <= n.key < 128:
                keys.setdefault(n.key, []).append(n)
        next_note = 1
        out = ["<KeyTracks>\n"]
        for index, key in enumerate(sorted(keys)):
            out.append(f'\t\t\t<KeyTrack Id="{index}">\n\t\t\t\t<Notes>\n')
            for n in sorted(keys[key], key=lambda n: n.time):
                out.append(f'\t\t\t\t\t<MidiNoteEvent Time="{_num(n.time)}" Duration="{_num(n.duration)}" '
                           f'Velocity="{max(1, min(127, int(n.velocity)))}" OffVelocity="64" NoteId="{next_note}" />\n')
                next_note += 1
            out.append(f'\t\t\t\t</Notes>\n\t\t\t\t<MidiKey Value="{key}" />\n\t\t\t</KeyTrack>\n')
        out.append("\t\t</KeyTracks>")
        if "<KeyTracks />" not in text:
            raise AlsError("Live's MIDI clip has no empty KeyTracks")
        text = text.replace("<KeyTracks />", "".join(out), 1)
        gen = text.find("<NoteIdGenerator>")
        if gen < 0:
            raise AlsError("Live's MIDI clip has no note ids")
        text = _set_value(text, "NextId", str(next_note), gen)
    return text


def _place_clip(track: str, kind: str, clip_xml: str, name: str) -> str:
    holder = "<ClipTimeable>" if kind == "MidiTrack" else "<Sample>"
    seq = track.find("<MainSequencer>")
    seq_end = track.find("</MainSequencer>", seq)
    if seq < 0 or seq_end < 0:
        raise AlsError(f"a {kind} without a sequencer")
    held = track.find(holder, seq, seq_end)
    if held < 0:
        raise AlsError(f"a {kind} without {holder}")
    events = track.find("<Events />", held, seq_end)
    if events < 0:
        raise AlsError(f"the {kind} already holds clips")
    line_start = track.rfind("\n", 0, events) + 1
    indent = track[line_start:events]
    inner = indent + "\t"
    body = "\n".join(inner + line for line in clip_xml.rstrip().split("\n"))
    track = track[:events] + f"<Events>\n{body}\n{indent}</Events>" + track[events + len("<Events />"):]
    rem = track.find('<MemorizedFirstClipName Value="')
    if rem < 0:
        raise AlsError(f"a {kind} without MemorizedFirstClipName")
    return _set_value(track, "MemorizedFirstClipName", name, rem)


def _copy_track(block: str, kind: str, track_id: int, counter: list[int], plan: TrackPlan, set_plan: SetPlan) -> str:
    def renumber(m):
        i = counter[0]
        counter[0] += 1
        return f'<{m.group(1)} Id="{i}"'

    text = _GLOBAL_IDS.sub(renumber, block)
    head_end = text.find(">")
    text = re.sub(r'Id="\d+"', f'Id="{track_id}"', text[:head_end], count=1) + text[head_end:]
    span = _element(text, "<Name>", "</Name>")
    if not span:
        raise AlsError(f"a {kind} without a name")
    name_block = re.sub(r'<UserName Value="[^"]*" />', f'<UserName Value="{_attr(plan.name)}" />', text[span[0]:span[1]], count=1)
    text = text[:span[0]] + name_block + text[span[1]:]
    color_at = text.find('<Color Value="', span[0])
    color_end = text.find("/>", color_at) + 2
    text = text[:color_at] + f'<Color Value="{min(plan.color, 69)}" />' + text[color_end:]
    if not plan.active:
        sp = text.find("<Speaker>")
        manual = text.find('<Manual Value="true" />', sp)
        close = text.find("</Speaker>", sp)
        if sp < 0 or manual < 0 or manual > close:
            raise AlsError(f"the {kind}'s activator is not on in the template")
        text = text[:manual] + '<Manual Value="false" />' + text[manual + len('<Manual Value="true" />'):]
    if plan.clip is not None:
        is_midi = isinstance(plan.clip, MidiClip)
        if is_midi != (kind == "MidiTrack"):
            raise AlsError(f"{plan.clip.name} cannot go on a {kind}")
        text = _place_clip(text, kind, _clip_xml(plan.clip, plan.color, set_plan.bpm, set_plan.meter), plan.clip.name)
    return text


def build_xml(template: str, plan: SetPlan) -> str:
    if not 20.0 <= plan.bpm <= 999.0:
        raise AlsError(f"Live's tempo runs from 20 to 999 BPM, not {plan.bpm}")
    if len(plan.midi) + len(plan.audio) > LIVE_LITE_TRACKS:
        raise AlsError(f"Live 12 Lite holds {LIVE_LITE_TRACKS} tracks; the plan has {len(plan.midi) + len(plan.audio)}")
    sig = time_signature_value(*plan.meter)
    midi = _element(template, "<MidiTrack ", "</MidiTrack>")
    audio = _element(template, "<AudioTrack ", "</AudioTrack>")
    if not midi or not audio:
        raise AlsError("the template needs one MIDI and one audio track")
    if template[midi[1]:audio[0]].strip():
        raise AlsError("the template's MIDI and audio tracks are not side by side")
    midi_block, audio_block = template[midi[0]:midi[1]], template[audio[0]:audio[1]]
    indent = template[template.rfind("\n", 0, midi[0]) + 1:midi[0]]
    m = re.search(r'<NextPointeeId Value="(\d+)" />', template)
    if not m:
        raise AlsError("the template has no NextPointeeId")
    counter = [int(m.group(1))]
    track_id = max(int(x) for x in re.findall(r'<(?:MidiTrack|AudioTrack|ReturnTrack|GroupTrack) Id="(\d+)"', template)) + 1
    tracks = []
    for plans, block, kind in ((plan.midi, midi_block, "MidiTrack"), (plan.audio, audio_block, "AudioTrack")):
        for tp in plans:
            tracks.append(_copy_track(block, kind, track_id, counter, tp, plan))
            track_id += 1
    xml = template[:midi[0]] + f"\n{indent}".join(tracks) + template[audio[1]:]
    xml = re.sub(r'<NextPointeeId Value="\d+" />', f'<NextPointeeId Value="{counter[0]}" />', xml, count=1)
    main = _element(xml, "<MainTrack ", "</MainTrack>")
    if not main:
        raise AlsError("the template has no main track")
    body = xml[main[0]:main[1]]
    for tag, value in (("<Tempo>", _num(plan.bpm)), ("<TimeSignature>", str(sig))):
        at = body.find(tag)
        manual = body.find('<Manual Value="', at)
        end = body.find("/>", manual) + 2
        body = body[:manual] + f'<Manual Value="{value}" />' + body[end:]
        # The arrangement plays the main track's automation, not the manual value.
        tm = re.search(r'<AutomationTarget Id="(\d+)"', body[at:])
        if not tm:
            raise AlsError(f"{tag} has no automation target")
        pointee = f'<PointeeId Value="{tm.group(1)}" />'
        env = body.find(pointee)
        if env >= 0:
            ev_end = body.find("</Events>", env)
            events = body[env:ev_end]
            if len(re.findall(r"<(?:Float|Enum)Event ", events)) != 1:
                raise AlsError(f"the template's {tag} envelope is not a single value")
            events = re.sub(r'(<(?:Float|Enum)Event Id="\d+" Time="[^"]*" Value=")[^"]*(")', rf"\g<1>{value}\g<2>", events)
            body = body[:env] + events + body[ev_end:]
    return xml[:main[0]] + body + xml[main[1]:]


def build(plan: SetPlan) -> bytes:
    return gzip_text(build_xml(gunzip(TEMPLATE_GZ), plan))


def validate(als: bytes, plan: SetPlan) -> list[str]:
    """Structural checks of a written set against the template and the plan. Returns problems (empty = pass)."""
    import xml.etree.ElementTree as ET

    problems = []
    try:
        root = ET.fromstring(gunzip(als))
    except Exception as e:
        return [f"not gzipped well-formed XML: {e}"]
    tmpl = ET.fromstring(gunzip(TEMPLATE_GZ))
    if root.get("Creator") != tmpl.get("Creator") or root.get("MinorVersion") != tmpl.get("MinorVersion"):
        problems.append("header differs from the Live 12 template")
    tracks = [t for t in root.find("LiveSet/Tracks") if t.tag in ("MidiTrack", "AudioTrack")]
    want = [("MidiTrack", p.name) for p in plan.midi] + [("AudioTrack", p.name) for p in plan.audio]
    got = [(t.tag, t.find("Name/UserName").get("Value")) for t in tracks]
    if got != want:
        problems.append(f"tracks {got} != planned {want}")
    def shape(node):
        out = [node.tag]
        for child in node:
            if child.tag not in ("MidiClip", "AudioClip"):
                out.extend(shape(child))
        return out

    tmpl_shape = {k: shape(tmpl.find(f"LiveSet/Tracks/{k}")) for k in ("MidiTrack", "AudioTrack")}
    for t in tracks:
        if shape(t) != tmpl_shape[t.tag]:
            problems.append(f"{t.tag} '{t.find('Name/UserName').get('Value')}' differs in shape from Live's track")
    seen = set()
    nxt = int(root.find("LiveSet/NextPointeeId").get("Value"))
    for e in root.iter():
        if ("Target" in e.tag or e.tag == "Pointee") and e.get("Id") is not None:
            i = int(e.get("Id"))
            if i in seen:
                problems.append(f"set-wide id {i} used twice")
            if i >= nxt:
                problems.append(f"id {i} not below NextPointeeId {nxt}")
            seen.add(i)
    ids = [t.get("Id") for t in root.find("LiveSet/Tracks")]
    if len(ids) != len(set(ids)):
        problems.append("track ids repeat")
    main = root.find("LiveSet/MainTrack")
    tempo = main.find(".//Tempo/Manual").get("Value")
    if abs(float(tempo) - plan.bpm) > 1e-6:
        problems.append(f"tempo {tempo} != {plan.bpm}")
    sig = main.find(".//TimeSignature/Manual").get("Value")
    if int(sig) != time_signature_value(*plan.meter):
        problems.append(f"time signature {sig} wrong")
    for t, p in zip(tracks, plan.midi + plan.audio):
        if isinstance(p.clip, MidiClip):
            notes = t.findall(".//MidiClip//MidiNoteEvent")
            expect = sum(1 for n in p.clip.notes if n.duration > 0 and n.time >= 0)
            if len(notes) != expect:
                problems.append(f"{p.name}: {len(notes)} notes in the set, {expect} planned")
        if isinstance(p.clip, AudioClip):
            rp = t.find(".//AudioClip//FileRef/RelativePath")
            if rp is None or rp.get("Value") != p.clip.relative_path:
                problems.append(f"{p.name}: audio reference {rp.get('Value') if rp is not None else None} != {p.clip.relative_path}")
    return problems

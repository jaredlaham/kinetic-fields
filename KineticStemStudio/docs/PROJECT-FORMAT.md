# Project format (.kineticstem)

A project is a folder that Finder shows as one document (a package, UTI `xyz.kineticfields.stemstudio.project`):

```
My Song.kineticstem/
  project.json   the document
  cache/         safe to delete
```

Audio is referenced, never copied. Waveform peaks are cached in `~/Library/Caches/KineticStemStudio/peaks`, keyed by path, size and modification date.

## project.json (schema 1)

Pretty-printed JSON with sorted keys and ISO-8601 dates. Defined by `Sources/StemCore/Model.swift`.

| Key | Meaning |
|---|---|
| `schemaVersion` | 1. Files with a higher number are refused unchanged ("saved by a newer version"). |
| `id`, `name`, `created`, `modified` | Identity and timestamps |
| `tempo` | `bpm`, `beatsPerBar`, `beatUnit`, `downbeat` (seconds of bar 1), `source` (`none`/`detected`/`manual`/`tapped`), `confidence`, `alternatives`, `stable`, `warnings` |
| `quantize` | `enabled`, `division` (`1/4` … `1/16T`), `strength`, `swing`, `quantizeEnds` |
| `export` | `ticksPerQuarter`, `timing` (`original`/`quantized`), `lastFolder` |
| `t8` | `rhythmChannel`, `bassChannel`, `steps`, `drumMap`, `destinationName` |
| `stems[]` | See below, in lane order |

Each stem:

| Key | Meaning |
|---|---|
| `id`, `name`, `colorIndex` | |
| `file` | `path` (absolute), `relativePath` (from the project's parent folder), `sha256`, `sampleRate`, `channels`, `frames`, `format` |
| `muted`, `soloed`, `volumeDB` | Mixer |
| `classification` | Engine proposal: `proposed`, `confidence`, `scores`, `features` |
| `instrumentOverride` | The user's choice, or absent |
| `mode`, `pitchBends`, `drumSensitivity`, `midiChannel`, `confidenceThreshold` | Transcription and review settings |
| `transcription` | Engine output, never edited: `engine`, `engineVersion`, `mode`, `instrument`, `audioSHA256`, `pitchBends`, `createdAt`, `processingSeconds`, `notes`, `warnings` |
| `editedNotes` | The user's notes, absent until the first edit |
| `lastError` | Last engine error for this stem |

A note: `id`, `pitch` (0–127), `start` and `end` (seconds from the start of the audio file), `velocity` (1–127), `confidence` (0–1), `drum` (class name for drum notes), `bends` (`[[seconds from note start, semitones], …]`), `accepted` (absent = not reviewed, `true`, `false` = rejected but kept).

## Compatibility rules

- Every field added later is optional when reading, so older files open.
- Structural changes bump `schemaVersion` and add a step to `ProjectStore.migrate`, which upgrades the JSON before decoding. Schema 0 (pre-release) files gain empty `quantize`, `export` and `t8` blocks.
- Saving always writes the current schema, atomically.
- Opening a project whose audio moved together with it uses `relativePath`; missing audio is reported per stem and can be re-linked with Replace Audio.

## Autosave

While there are unsaved changes, a copy is written every 30 seconds to `~/Library/Application Support/KineticStemStudio/Autosave/<project id>.kineticstem` (plus `original-location.txt`). It is deleted on save, on New/Open and on a normal quit. If one is found at launch the app offers to recover it.

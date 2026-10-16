# Architecture

```
┌───────────────────────── Kinetic Stem Studio.app (SwiftUI) ─────────────────────────┐
│ Views: Transport · Stem list · Timeline lanes · Piano roll / Drum grid · Inspector │
│        Export dialog (MIDI / Ableton / T-8) · Engine setup                           │
│                                   │                                                  │
│ AppModel (@Observable, main actor): project, selection, jobs, undo, autosave        │
│   ├─ PlaybackEngine   AVAudioEngine: player per stem + GM samplers via AVAudioSequencer
│   ├─ WaveformLoader   AVAudioFile → min/max peaks, cached in ~/Library/Caches       │
│   ├─ MIDIOutput       CoreMIDI, host-time scheduled (T-8 Mode B)                     │
│   └─ EngineClient     one `python -m kstem <cmd>` process per job, JSON Lines        │
│                                   │                                                  │
│ StemCore (Foundation only, also builds on Linux)                                     │
│   Model · ProjectStore (.kineticstem, migration) · Quantizer · NoteEditor/EditHistory│
│   WaveformPeaks · PreviewMIDI · EngineProtocol (request/response types)              │
└───────────────────────────────────┬──────────────────────────────────────────────────┘
                                    │ stdin: one JSON request
                                    │ stdout: {"event":"progress"|"result"|"error"}
┌───────────────────────────────────▼──────────────────────────────────────────────────┐
│ kstem engine (Python 3.10/3.11, own venv in ~/Library/Application Support)           │
│  analyze     audio_io (soundfile/ffmpeg, soxr) · tempo (shared grid) · classify      │
│  transcribe  poly (Basic Pitch ONNX) · mono (Basic Pitch attacks + pYIN/CREPE)       │
│              drums (onsets + trained classifier) · post (clean-up) · chunking        │
│  export-*    smf (write + read-back check) · als (Live 12 template) · ableton · t8   │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## Why this split

- **Swift for everything the user touches** (UI, audio playback, MIDI out, files): native performance, AVFoundation and CoreMIDI, no web runtime.
- **Python for analysis**: the transcription models and the music-information-retrieval tools that are proven (Basic Pitch, librosa, mir_eval for measuring) live there. Porting them to Swift/CoreML would cost weeks and remove the ability to measure against the same reference code.
- **A process per job, not a server**: cancelling is `terminate()`, a crash cannot take the app down, memory is returned to the system after each stem (important on 16 GB), and nothing listens on a network port.
- **The engine writes exports**: one implementation of the SMF writer, its read-back validation and the Live Set builder, tested by pytest and used by both the CLI and the app.

## Data flow

1. **Import**: the app reads metadata with AVFoundation and draws waveforms immediately. Audio files are referenced, never copied or modified.
2. **Analyse** (all stems together): engine returns per-stem hash, leading silence, instrument proposal with ranked scores, and **one shared tempo grid** estimated from every stem's onset envelopes. A tempo typed or tapped by the user is never overwritten.
3. **Transcribe** (queued, one stem at a time to bound memory): the stem's class picks the pipeline, the mode picks the algorithm (see below). Results are cached on the stem keyed by audio SHA-256, mode, class and pitch-bend setting; unchanged stems are not re-run.
4. **Edit**: the engine's output is stored unchanged (`transcription`); edits create `editedNotes`. Undo/redo stores snapshots of a stem's note list (200 steps).
5. **Review**: notes carry the engine's confidence. Notes below the stem's threshold, or rejected, are kept in the project but left out of MIDI playback and exports until accepted.
6. **Quantise**: settings live on the project and are applied when notes are played or exported with quantised timing. Stored notes keep detected timing. "Quantize Selected" is the only destructive form, and it is undoable.
7. **Export**: the app sends the notes it would play (threshold, review and optional quantise applied) to the engine, which writes and validates the files.

## Pipelines and modes

| Stem class | Fast | Balanced (default) | High Accuracy |
|---|---|---|---|
| Drums | band-energy onsets (kick/snare/hats) | superflux onsets + 11-class learned classifier | + extra low/high band onset candidates, exclusive-group checks |
| Bass, mono synth, vocal, other | YIN pitch track only | Basic Pitch attacks, sample-accurate onsets, monophonic clean-up | Balanced + fusion with pYIN/CREPE pitch track (slides, legato) |
| Poly synth, piano, guitar | Basic Pitch, no clean-up | + harmonic/subharmonic suppression, false-retrigger merge, onset refinement | + second decoding pass for weak notes (rescue) |

The modes differ in algorithm, not in a single threshold. High Accuracy is slower and, on the current reference stems, not better than Balanced for every class; [ACCURACY.md](ACCURACY.md) has the numbers and the app says so next to the mode picker.

## Threading

- `AppModel`, views and `PlaybackEngine` run on the main actor.
- Engine jobs are Swift concurrency tasks wrapping a `Process`; progress lines hop to the main actor. Cancelling a task terminates its process.
- Waveform peaks are computed on a detached task.
- CoreMIDI messages are scheduled ahead with host timestamps, so UI load does not affect timing.

## Files

| Path | What |
|---|---|
| `Sources/StemCore/` | Platform-neutral model, project format, quantise, editing, peaks, preview SMF |
| `Sources/KineticStemStudio/` | SwiftUI app (App, Audio, Engine, MIDI, Views) |
| `engine/kstem/` | Python engine; `cli.py` is the protocol |
| `engine/eval/` | Reference stems, accuracy harness, drum classifier training |
| `scripts/` | `install-engine.sh`, `build-app.sh`, `make-icon.py` |

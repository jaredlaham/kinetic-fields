# Technical verification and compatibility matrix

Status words used everywhere in this project:

- **Verified**: tested in this repository (automated test, CI run, or a check with real software/hardware that is named).
- **Needs testing**: implemented and believed correct, but not yet checked on the real target (your Mac, Live, the T-8).
- **Unsupported**: deliberately not offered, with the reason.

Last updated: 2026-10-16.

## Platform

| Item | Status | Notes |
|---|---|---|
| macOS 14+ on Apple Silicon (M1/M2, 16 GB) | Needs testing | Builds on GitHub's macOS 15 arm64 runners (`swift build`, `swift test`, packaged `.app`). Not yet launched on Jared's M1 Pro. |
| Native SwiftUI app (no Electron, no web view) | Verified (builds) | Swift Package, SwiftUI + AVFoundation + CoreMIDI. |
| Fully local processing | Verified | No network use after installing the engine. The engine installer needs internet once (PyPI; optionally astral.sh for uv). |
| Gatekeeper | Known | Ad-hoc signed CI build: System Settings > Privacy & Security > Open Anyway once. |
| StemCore (model, project format, quantise, undo) on Linux | Verified | CI `core-linux` job; keeps the core free of Apple frameworks. |

## Audio input

| Format | Status | How |
|---|---|---|
| WAV, AIFF/AIFC, FLAC, MP3, CAF | Verified (engine) / Needs testing (app) | Engine: libsndfile via `soundfile`. App: AVFoundation for waveforms and playback. Engine tests read FLAC/WAV fixtures. |
| M4A/AAC | Needs testing | AVFoundation reads it in the app; the engine falls back to `ffmpeg` (optional, Homebrew) when libsndfile cannot. Without ffmpeg the engine reports a clear error. |
| Sample rates 22.05–192 kHz, mono/stereo | Verified (engine) | Resampled with soxr (HQ) to 22.05 kHz (melodic) / 44.1 kHz (drums). Note times stay in the original file's seconds. |
| Long files | Verified (engine) | Processed in 120 s chunks with 4 s overlap; notes crossing a chunk border are joined (unit test). |

## Transcription models and algorithms

| Component | Status | Notes |
|---|---|---|
| Basic Pitch (Spotify, ICASSP 2022), ONNX model run by onnxruntime | Verified | Apache-2.0. Installed with `--no-deps` so TensorFlow is never pulled in. Used for polyphonic stems and as the attack detector for monophonic stems. |
| pYIN / YIN (librosa) | Verified | Monophonic pitch tracking (Fast and High modes, pitch bends). |
| CREPE (torchcrepe) | Needs testing | Optional (`--high`, ~1 GB PyTorch). Used in High mode for leads/vocals above 60 Hz when installed; falls back to pYIN otherwise. Not exercised in CI. |
| Drum transcription | Verified | Superflux onsets + logistic-regression hit classifier on log-mel features, trained here (`eval/train_drums.py`) on FluidR3 kits that are *not* used by the test stems. 11 classes. |
| Tempo, beat grid, downbeat | Verified | Comb-filter tempo with octave folding, grid fit and phase refinement; downbeat from kick/snare weighting. 8/8 test stems within 0.1 BPM, beat phase within 8 ms. Downbeat for stems without drums is a guess and the app says so. |
| Instrument classification (9 classes) | Verified on fixtures only | Rule-based on audio and note statistics. Rules were tuned on the same 8 fixtures, so the 8/8 result is not an independent measurement. The user can always override. |
| Tempo changes / rubato | Unsupported (detected, warned) | One tempo per project. Drift above 5% raises a warning in the transport bar and the export summary. |
| Vocal transcription | Needs testing | Uses the monophonic pipeline (pYIN/CREPE). No vocal fixture yet. |

Measured accuracy: see [ACCURACY.md](ACCURACY.md).

## MIDI output

| Item | Status | Notes |
|---|---|---|
| Standard MIDI File Type 1 (tempo track + one track per stem) | Verified | Written by `mido`, then **read back and compared note by note** before the app reports success. |
| One file per stem | Verified | Same writer and check. |
| Resolution 96–1920 TPQ | Verified | Unit tests at 480 and 960. |
| Region export | Verified | Notes are clipped to the region and shifted to start at 0. |
| Pitch bends (±2 semitones) | Verified (file) / Needs testing (DAW) | Bends beyond ±2 are clipped with a warning. |
| Live MIDI preview in the app | Needs testing | AVAudioSequencer + AVAudioUnitSampler with the macOS General MIDI DLS bank. |

## Ableton Live

| Item | Status | Notes |
|---|---|---|
| Native `.als` Live Set (gzipped XML) | Verified in Live 12 Lite (method) / Needs testing (this exporter) | Built from a template saved by **Live 12.4.6 Lite** and clip XML Live itself wrote. The same method (ported from Kinetic Studio's Ableton writer) opened without errors in Jared's Live 12 Lite (8 tracks, 4/4, 92 BPM). This exporter's output is validated structurally after writing (ids unique and below `NextPointeeId`, tempo, time signature, track kinds, note counts, sample paths) but has **not yet been opened in Live**. See [ABLETON.md](ABLETON.md) for the 5-minute check. |
| Live 12 Lite track limit (8) | Verified (logic) | MIDI tracks first, then audio; extra files stay in the folder and are listed in the READ ME. |
| Ableton Import Package (no `.als`) | Verified | Samples, per-stem MIDI, "All tracks" MIDI, manifest and READ ME. Works with any Live version. |
| Live 11 or older, Live Suite/Standard specifics | Needs testing | The set declares Live 12.4; older versions may refuse it. Use the Import Package. |

## Roland T-8

Source: Roland T-8 MIDI Implementation Chart v1.02 and the T-8 owner's manual. Details in [T8.md](T8.md).

| Item | Status | Notes |
|---|---|---|
| Channel and note map (rhythm ch 10: BD 36, SD 38, HC 50, TOM 47, CH 42, OH 46; bass ch 2, notes 12–96; program change ch 16 selects patterns 0–63) | Verified against Roland's chart | Not yet confirmed by sending to a real T-8. |
| Mode A: MIDI pattern file (rhythm + bass, 16/32-step segments, accents, slides as overlap) | Verified (file) / Needs testing (hardware) | Unit-tested conversion; read-back of the file. |
| Mode B: play into the T-8 over USB (CoreMIDI, optional clock/start/stop) | Needs testing | CoreMIDI scheduling with host timestamps. |
| T-8 recording incoming notes into a pattern | Unknown | Not documented by Roland. The app never claims a pattern was stored. |
| Mode C: native pattern/backup files (.prm) | Unsupported | Format unpublished; T-8 Pattern Studio's reverse-engineering is waiting on real backups. Writing unverified files risks the device's memory. |
| CC, pitch bend, SysEx to the T-8 | Unsupported | The chart lists none received. |

## Project files

| Item | Status | Notes |
|---|---|---|
| `.kineticstem` package (`project.json` + `cache/`) | Verified | Versioned schema with migration; newer-schema files are refused unchanged. See [PROJECT-FORMAT.md](PROJECT-FORMAT.md). |
| Autosave and crash recovery | Needs testing | Every 30 s while there are unsaved changes, to `~/Library/Application Support/KineticStemStudio/Autosave`. |
| Moved projects | Verified | Audio paths are stored absolute and relative; relative is tried when absolute is missing. |

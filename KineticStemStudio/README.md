# Kinetic Stem Studio

A native macOS app that turns audio stems into editable MIDI, locally on Apple Silicon.

Drop in your stems (WAV, AIFF, FLAC, MP3, M4A). The app finds a shared tempo and bar grid, proposes what each stem is (drums, bass, lead, chords, vocal…), and transcribes each one with a pipeline made for that kind of part. You check the result by ear with A/B playback, fix notes in a piano roll or drum grid, and export Standard MIDI files, an Ableton Live set, or patterns for a Roland T-8.

Nothing leaves your Mac. The app never invents notes: everything you see was detected in the audio or added by you, and low-confidence notes are marked.

## Install

1. Download `Kinetic-Stem-Studio-app` from the latest CI run of the pull request (Actions tab), unzip, move **Kinetic Stem Studio.app** to Applications. If Chrome blocks the zip as a "dangerous download", use chrome://downloads > Download dangerous file, or Safari.
2. First launch: macOS says it cannot verify the developer. Open System Settings > Privacy & Security and click **Open Anyway**.
3. The app opens **Engine Setup** when the analysis engine is missing. Click **Install Engine** (a few minutes, needs internet once). It creates its own Python environment in `~/Library/Application Support/KineticStemStudio/engine-venv` and does not touch any other Python.

Optional: `brew install ffmpeg` for M4A files libsndfile cannot read; tick the CREPE option in Engine Setup (about 1 GB) for High Accuracy leads and vocals.

## Use

1. Drag stems or a folder onto the window. Waveforms appear; analysis runs (tempo, instrument).
2. Check the grid: bar lines should sit on the downbeats. Fix with the BPM field, **Tap**, the ⋯ menu (half/double time, other candidates, set bar 1 at the playhead) and the time signature.
3. Check each stem's instrument in the inspector; change **Treat as** if it is wrong.
4. **Transcribe All** (Balanced is the recommended mode).
5. Listen with **A** (audio), **B** (MIDI) or **A+B**. Turn on the metronome to check the grid.
6. Edit in the piano roll / drum grid. Set a confidence threshold, accept or reject notes.
7. **Export**: MIDI file(s), Ableton Live, or Roland T-8.

### Editor keys

| | |
|---|---|
| Click / Shift-click / drag on empty space | Select / add to selection / box-select |
| Drag a note / its right edge | Move (time and pitch) / change length |
| Double-click empty space | Add a note (one grid step) |
| Delete | Delete selected |
| ← → (Option: 5 ms) / ↑ ↓ (Shift: octave) | Nudge / transpose |
| Space | Play / stop (Cmd-Return anywhere) |
| Cmd-Z / Shift-Cmd-Z | Undo / redo |
| Scroll / Option-scroll | Move in time (piano roll: pitch) / zoom |

## What is verified and what is not

See [docs/RESEARCH.md](docs/RESEARCH.md). In short: the engine, its exports and the app build are tested in CI; the app has not yet been run on a real Mac by a person, the Live set from this exporter has not been opened in Live, and nothing has been sent to a real T-8. Measured accuracy: [docs/ACCURACY.md](docs/ACCURACY.md).

## Docs

- [docs/RESEARCH.md](docs/RESEARCH.md): compatibility matrix
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it is built
- [docs/ACCURACY.md](docs/ACCURACY.md): measured results
- [docs/PLAN.md](docs/PLAN.md): phases and next steps
- [docs/ABLETON.md](docs/ABLETON.md), [docs/T8.md](docs/T8.md), [docs/PROJECT-FORMAT.md](docs/PROJECT-FORMAT.md)

## Develop

```
swift build && swift test                      # StemCore + app (app target on macOS only)
./scripts/install-engine.sh --dev              # engine venv with pytest and mir_eval
cd engine && PYTHONPATH=. ~/Library/Application\ Support/KineticStemStudio/engine-venv/bin/python -m pytest -q tests
PYTHONPATH=. <venv>/bin/python eval/run_eval.py # accuracy on the reference stems
./scripts/build-app.sh                         # build/Kinetic Stem Studio.app
```

`swift run KineticStemStudio` uses the engine sources in `engine/` directly. `KSTEM_PYTHON` and `KSTEM_ENGINE_DIR` override where the app looks.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "The analysis engine is not installed" | Stems > Engine Setup > Install Engine. If it says Python is missing, keep the uv option ticked. |
| Install fails on a network step | Check the connection and click Install Engine again. |
| A stem says "Audio file not found" | The file moved. Right-click the stem > Replace Audio. |
| M4A will not transcribe | `brew install ffmpeg`, then Check Again in Engine Setup. |
| Grid is off by a beat | ⋯ menu > Move Bar 1 One Beat Earlier/Later, or put the playhead on a downbeat and Set Bar 1 at Playhead. |
| Tempo is half or double | ⋯ menu > Half time / Double time. |
| Live says the set is damaged | Use the Ableton Import Package and report the Live version (docs/ABLETON.md). |
| T-8 not listed | Check the USB cable and that the T-8 is on, then click the refresh button next to Output. |

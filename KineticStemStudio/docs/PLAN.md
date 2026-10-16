# Roadmap

Each phase lists what it delivers and the acceptance check that closes it. "Done" means the check passed; "Built, needs testing" means the code exists and passes automated checks but still needs a real Mac, Live or T-8.

## Phase 1: Foundation (built)

- Project model and `.kineticstem` format with versioning, migration, autosave/recovery.
- Stem import (files, folders, drag and drop), reorder, rename, mute/solo, volume, remove/replace.
- Waveform lanes with ruler, beat/bar grid, zoom, scroll, region selection, playhead.
- Engine install script and self-check (Engine Setup).

Acceptance: app builds and packages in CI (done); 30 stems of 5 minutes import and draw without stalls on an M1 (needs testing).

## Phase 2: Audio-to-MIDI MVP (built)

- Instrument classification with override; class-specific pipelines; Fast / Balanced / High modes.
- Tempo, downbeat, grid; manual BPM, tap tempo, half/double, bar-1 placement, drift warning.
- Background jobs with real progress, cancel, caching by audio hash.
- Confidence shading, threshold, accept/reject.
- MIDI export with read-back validation.

Acceptance: measured F1 on the 8 reference stems at or above the floors in `engine/tests` (done: see ACCURACY.md); export of every reference stem reads back identically (done).

## Phase 3: Editing and listening (built, needs testing)

- Piano roll and drum grid: select, marquee, move, resize, add, delete, nudge, transpose, velocity lane, undo/redo.
- Non-destructive quantise (grid, strength, swing, ends) and destructive Quantize Selected.
- A/B playback: audio, MIDI preview (GM sounds), both; metronome; loop region.

Acceptance: Jared transcribes a real song's stems, fixes mistakes by ear with A+B, and exports in under 10 minutes for a 3-minute track.

## Phase 4: DAW and hardware export (built, needs testing)

- Ableton Live Set (.als, Live 12) and Ableton Import Package.
- Roland T-8 Mode A (MIDI pattern file) and Mode B (play over USB).

Acceptance: the .als opens in Live 12 Lite with tracks, tempo and clips in place ([ABLETON.md](ABLETON.md) checklist); a converted drum + bass pattern plays correctly on the T-8 ([T8.md](T8.md) checklist).

## Phase 5: Accuracy work (next)

Targets from the current measurements:
- Acid/303 slides: detect glides as one legato note pair with a slide flag instead of missing the second note (acid F1 0.78 → 0.9).
- Reverb tails: offset estimation from the decay curve rather than Basic Pitch's frame posteriors (reverb melody 0.76 → 0.85).
- High mode for melodic stems: make it measurably better than Balanced or rename it.
- Downbeat for stems without drums (harmonic-change based).
- An independent classifier test set (real stems, not the tuning fixtures); vocal fixture.
- Real-world stems from Jared's own projects added to the harness (MIDI ground truth from his DAW sessions).

## Phase 6: Performance and polish

- Run the engine as a warm worker (models loaded once) to cut per-stem start-up.
- CoreML conversion of Basic Pitch for the Neural Engine, measured against ONNX on CPU.
- Tempo maps (multiple tempos) once detection of changes is reliable.
- Signed and notarised builds (needs an Apple Developer ID).
- Native T-8 pattern files only if the backup format is verified with real backups (shared work with T-8 Pattern Studio).

## Explicitly not planned

- Writing T-8 backup/pattern files before the format is verified.
- Claiming Live compatibility for versions nobody has tested.
- Generating notes that were not detected in the audio.

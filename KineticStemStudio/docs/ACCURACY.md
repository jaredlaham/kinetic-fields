# Measured accuracy

All numbers below were measured, not estimated. Reproduce them with:

```
cd engine && PYTHONPATH=. <engine-venv>/bin/python eval/run_eval.py
```

CI runs the same command on Apple Silicon for every change and uploads `results.json` as the `engine-accuracy` artifact. The numbers here are from `eval/reference-results.json` (2026-10-16).

## Test material

Eight stems with exact MIDI ground truth, made by `eval/make_fixtures.py`: performances written as MIDI with human-like timing and velocity variation, rendered with FluidSynth and the FluidR3 GM SoundFont (the acid line with a built-in 303-style synth). Each starts with a two-beat lead-in.

| Stem | Class | BPM | Notes | Length | What makes it hard |
|---|---|---|---|---|---|
| mono_bass | Bass guitar | 104 | 52 | 22 s | Low register, octave errors |
| analog_lead | Mono synth | 118 | 44 | 36 s | Legato and repeated notes |
| poly_piano | Piano | 92 | 72 | 25 s | Chords, sustain |
| arp_synth | Poly synth | 128 | 128 | 18 s | Fast arpeggio, overlapping releases |
| four_floor | Drums | 124 | 96 | 22 s | Kick/hat overlap |
| breakbeat | Drums | 132 | 132 | 19 s | Ghost notes, syncopation |
| acid_bassline | Synth bass | 135 | 96 | 16 s | Slides, accents, resonant filter |
| reverb_melody | Other melodic | 84 | 34 | 38 s | Long reverb tails |

Limits of this test: the sounds are clean General MIDI renders, not mixed real recordings, so real stems from a mix (bleed, compression, distortion) will score lower. The drum classifier was trained on *other* FluidR3 kits than the test kit, but still on FluidR3 sounds. The instrument classifier's rules were tuned on these same 8 stems, so its 8/8 is not an independent result.

## Metrics

- **F1**: a detected note counts as correct when its pitch matches and its onset is within 50 ms of a reference note (mir_eval). Duration is ignored. P = precision (how many detected notes are real), R = recall (how many real notes were found).
- **F1+off**: also requires the note end within 20% of the reference duration (or 50 ms). Shows how well lengths are right.
- **Onset error**: mean absolute timing error of correct notes.
- **Drums**: a hit counts when the onset is within 50 ms *and* the drum class matches; "class acc." is the fraction of matched onsets given the right class.

## Results by mode

Melodic stems (F1 / F1+off / onset error):

| Stem | Fast | Balanced | High |
|---|---|---|---|
| mono_bass | 0.920 / 0.400 / 12 ms | **1.000** / 0.519 / 17 ms | 1.000 / 0.519 / 17 ms |
| analog_lead | 0.750 / 0.705 / 19 ms | **1.000** / 0.977 / 11 ms | 1.000 / 0.977 / 11 ms |
| poly_piano | 0.814 / 0.467 / 8 ms | **0.901** / 0.702 / 5 ms | 0.883 / 0.688 / 5 ms |
| arp_synth | 0.874 / 0.015 / 6 ms | **0.898** / 0.031 / 8 ms | 0.891 / 0.031 / 8 ms |
| acid_bassline | **0.832** / 0.451 / 21 ms | 0.784 / 0.409 / 3 ms | 0.763 / 0.416 / 2 ms |
| reverb_melody | 0.471 / 0.282 / 18 ms | **0.761** / 0.592 / 14 ms | 0.757 / 0.568 / 13 ms |

Drums (F1 / class acc. / onset error):

| Stem | Fast | Balanced | High |
|---|---|---|---|
| four_floor | 0.573 / 0.718 / 16 ms | **0.925** / 0.968 / 3 ms | 0.925 / 0.968 / 3 ms |
| breakbeat | 0.684 / 0.648 / 14 ms | **0.902** / 0.850 / 4 ms | 0.902 / 0.850 / 4 ms |

Tempo: all 8 stems within 0.1 BPM of the truth (largest error 0.07 BPM); beat phase within 8 ms.

## What this says

- **Balanced is the right default.** It is the best or tied for best on 7 of 8 stems.
- **High Accuracy is not better yet.** For melodic stems it ties Balanced or is slightly worse, and it is much slower (pYIN fusion: about 40 s for the 38 s reverb stem on a 4-core Xeon; the M1 should be faster but has not been measured). For drums it adds extra candidate searches that found nothing new here. The app says this next to the mode picker. Making High worth its cost is Phase 5 work.
- **Acid slides are the weakest point.** 303 slides glide into the next note without a new attack, so Basic Pitch misses about a quarter of those notes (recall 0.72). Plain YIN (Fast) catches more of them (0.83 F1) but with 21 ms timing error. Fix planned: treat a glide as two notes with a slide flag.
- **Note lengths are weaker than note starts** (F1+off well below F1), most of all for the arpeggio (overlapping synth releases) and the bass. Quantising ends or the export's T-8 conversion are unaffected; DAW playback of long notes may need trimming.
- **Reverb** costs about a quarter of the notes on the reverb melody: tails blur onsets and lengths.
- "pitch_acc" in `results.json` is meaningful for monophonic stems only; for chords, onsets are shared by several notes and the pairing is arbitrary.

## Speed

Measured on the 4-core x86 container used for development, per stem, Balanced: 0.2–0.9 s for 16–38 s of audio (plus about 2 s engine start). CI timings on Apple Silicon are in the job log. A real-song measurement on Jared's M1 Pro is still to do.

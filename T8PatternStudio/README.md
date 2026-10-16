# T-8 Pattern Studio

A native macOS groovebox editor for the **Roland AIRA Compact T-8**: drum and TB-303-style bass patterns, a 60-pattern factory library, your own preset collection, Claude-assisted generation, MIDI import/export, local audio preview, live USB-MIDI playback, and a guarded workflow for getting patterns into the T-8's internal memory.

> **Status in one line:** the editor, preset library, audio preview, MIDI and AI features are complete. Writing patterns into the T-8's memory is implemented but **disabled until it is verified against a backup from your own T-8** (see [Hardware transfer](#hardware-transfer-to-the-t-8)).

---

## Quick start

Requirements: macOS 14 (Sonoma) or later, Apple Silicon or Intel, Xcode 16 / Swift 6.

```bash
cd T8PatternStudio
./scripts/build-app.sh            # builds "build/T-8 Pattern Studio.app"
open "build/T-8 Pattern Studio.app"
```

Other ways to run it:

| Option | How |
|---|---|
| Xcode, package | `open Package.swift`, choose the **T8PatternStudio** scheme, Run (⌘R) |
| Xcode, `.xcodeproj` | `brew install xcodegen && xcodegen generate && open T8PatternStudio.xcodeproj` |
| Command line | `swift run T8PatternStudio` (debug, no app icon) |
| Tests | `swift test` (also runs on Linux for the core) |
| CLI companion | `swift run t8studio help` |

CI (`.github/workflows/t8-pattern-studio.yml`) builds the app and runs the tests on macOS 15. It also builds and tests the core on Linux, and uploads the packaged `.app` as a build artifact.

---

## Feasibility audit (research findings)

Sources reviewed:

- **Roland T-8 owner's manual v1.02**, including "Backup and Factory Reset", and the **T-8 MIDI Implementation Chart** (v1.02, Feb 2022). Roland's site could not be fetched from the build environment, so these facts come from Roland's published pages as indexed by search. Re-check them against your firmware.
- **natebosch/aira_pattern_editor**, which I cloned and read in full. It is a Flutter web app, BSD-3-Clause, that reads and writes T-8 rhythm and bass `.prm` content. The user pastes text in and copies text out; the app never touches files or the device.
- No public documentation was found for writing T-8 patterns over USB-MIDI or SysEx.

### Compatibility matrix

| Capability | Evidence | Notes |
|---|---|---|
| 64 user patterns, up to 32 steps; 6 drum voices + bass | Officially documented | Product specs |
| Drum voices BD, SD, HC (clap), Tom, CH, OH | Officially documented | |
| MIDI channels: bass 2, rhythm 10 (defaults) | Officially documented | MIDI chart |
| Rhythm notes: BD 36, SD 38, HC 50, Tom 47, CH 42, OH 46 (rx also 35/40/48/45/44) | Officially documented | MIDI chart. Clap/Tom use 808-style notes |
| Bass note range 12–96 | Officially documented | MIDI chart |
| Backup: hold [PLAY] at power-on, copy BACKUP/BASS + BACKUP/RHYTHM | Officially documented | Manual |
| Restore: copy into RESTORE, eject, press [ACCENT], "dOnE" | Officially documented | Manual |
| Pattern files are line-based text (`.prm`) | Verified in open-source code | `KEY\t= value`, `STEP n\t= FIELD=value …` |
| Rhythm step code `[on][vel 0–A][sub-step 0–4][prob 0–A][sub-prob 0–A]` | Verified in open-source code | Codes AC BD SD LT HT CY CH OH. **HT = clap, LT = tom**, which matches the MIDI notes 50/47 |
| Rhythm header LENGTH, SCALE, SHUFFLE (×10, −900…900), FLAM | Verified in open-source code | SCALE/FLAM meaning unknown. Preserved untouched |
| Bass step `STATE` (0 off / 1 note / 2 tie) `NOTE` `ACCENT` `SLIDE`; header LENGTH, TRIPLET | Verified in open-source code | |
| Bass `NOTE` = MIDI − 12 | **Unverified** | Inferred: NOTE 0…84 ↔ MIDI 12…96. Adjustable in Settings ▸ Hardware |
| Backup file name ↔ pattern slot | **Unverified** | Real file names unknown. The app infers the slot from digits in the name and shows you each file's current content |
| App swing ↔ SHUFFLE | **Unverified** | Linear 0–100 → 0–900 |
| Bass slide/accent over MIDI (legato / velocity 127) | **Unverified** | TB-303 convention |
| Direct pattern write via USB-MIDI/SysEx | **Unsupported** | Not documented. The app uses backup/restore instead |
| A/B/C/D variations on the device | **Unsupported** (app concept) | Each variation exports to its own slot |
| End-to-end transfer verified on a T-8 | **Not yet tested** | No hardware testing has been done. See below |

The same matrix is in the app under **T-8 ▸ Hardware Compatibility Matrix**, and `t8studio matrix` prints it.

**Nothing in this project has been tested on a physical T-8.** All format tests use synthetic fixtures built to match the open-source editor's format. They live in `Tests/T8CoreTests/Fixtures/synthetic-backup` and are clearly labelled.

---

## Using the app

### Preset Library
- The **Preset Library** toolbar menu gives you All Presets, Recent, Favorites, Factory Presets (15 genres × 4 patterns), My Presets (All, My Folders, Recently Saved), and the library actions New, Save, Save As, Duplicate, Import, Export and Manage Library.
- Every preset in a menu opens a submenu: **Preview** (plays without touching your pattern), **Load Full Pattern**, **Load Drums Only**, **Load Bass Only**, **Save As…**, and **Add to Favorites**.
- The **sidebar browser** (⌘B) has expandable genre and folder groups, search across name, tags, genre, key and description, sorting, a favorites filter, a detail card with a mini pattern preview, and double-click to load.
- **Factory presets are read-only.** Saving one opens Save As. **Manage Library** (⇧⌘L) handles folders (create, rename, delete; presets move up a level and are never deleted with a folder), moving, favorites, duplicating, export, delete with confirmation, and **Version History** (each save keeps up to 20 earlier versions you can restore).
- If you have unsaved changes, the app asks before loading another preset, starting a new one, or quitting.

### Editing
- **Drums:** click to toggle a step, drag to paint, ⇧-drag to select a block, and ⌥-click to edit one step's velocity, sub-step (×2/×3/×4/flam), probability and sub-step probability in the inspector. There is an accent row, per-lane mute, Copy/Paste/Clear (⌥⌘C / ⌥⌘V / ⌥⌘⌫), duplicate 16→32 (⌘D), shift (⌥⌘←/→), and Randomize with a density control.
- **Bass:** a piano roll for pitch, plus Tie / Accent / Slide rows. It has scale lock, key and scale change (notes move by the shortest interval), transpose, octave range, and Randomize (density, slides, accents).
- **Variations A/B/C/D** are Foundation, Driving, Minimal and Fill. ⌘1–⌘4 switches between them. Right-click a variation to regenerate it from A, copy it, or generate it with Claude.
- **Undo/redo** (⌘Z / ⇧⌘Z) covers all pattern edits, including AI edits.

### Playback
- **Internal Preview Audio** comes from a sample-accurate synth: an AVAudioSourceNode pulls from the step clock, so timing never depends on UI timers. Drum sounds are synthesized, and the bass is an acid voice with accent, slide and resonant filter. The mixer has per-track volume, mute/solo, master and a metronome.
- **Roland T-8 MIDI Playback** sends notes live to the T-8 over USB, scheduled ahead with CoreMIDI timestamps from a dedicated thread. **This does not store anything on the T-8.** MIDI input is never echoed to output, so there are no feedback loops.
- Play/Stop: ⌘↩ or Space when the editor has focus.

### Claude AI
Add your Anthropic API key under **Settings (⌘,) ▸ AI**. The key is stored in the macOS Keychain. You can describe a beat to create one, apply quick edits (more aggressive, add syncopation, fill, simplify, darker bass, acid slides, variation, minimal, change genre, surprise me), or generate a genre blend.

- Requests use the Messages API with structured JSON output, model `claude-opus-5-5` (configurable). Server-side refusal fallback (`fallbacks: "default"`) is enabled.
- The response is parsed with the same notation parser as the factory library and checked by `ValidationEngine`. Raw model output never reaches the sequencer. If validation fails, the app retries once and sends Claude the exact error.
- Without a key, everything else works, including offline genre blending.

### Beat from Audio (song → pattern)
**From Audio** in the toolbar, **File ▸ Beat from Audio File…** (⇧⌘A), or the AI tab.

1. Choose a WAV, AIFF, MP3 or unprotected M4A/AAC. Apple Music and streaming DRM files can't be read.
2. Pick the section to analyse on the waveform (by default it starts 20% in, to skip intros), how much to analyse (15/30/60 s), and the pattern length. **24 steps = 1½ bars of 4/4.**
3. **Analyse** runs on your Mac, nothing is uploaded. It estimates tempo, kick/snare/hat onsets on a 16th grid (averaged over several 2-bar repetitions), and a bass line with its key.
4. **Preview** it, then either **Use This Pattern** or **Refine with Claude**.

How Claude fits in: the Claude API does not accept audio, so **Claude never hears the song**. It receives the analysis as text (per-step onset strengths, detected bass pitches, tempo, key, and the draft pattern) and builds a clean, musical T-8 pattern from it. You can add a direction such as "keep it sparse" or "add acid slides".

Accuracy: tempo is reliable. Kick and snare placement is good on clear electronic beats. Hats are partial, and the bass line is approximate, because pitched kicks such as 808s can read as bass notes. Treat the result as a draft. Songs usually repeat every 1 or 2 bars, so a 24-step loop takes the first 24 steps of the song's 2-bar groove. `t8studio analyze-audio song.wav --steps 24` runs the same analysis from the command line on WAV files.

### Genre Blend
Choose a primary and a secondary genre and a percentage. The app learns step-probability templates, tempo, swing, bass register and slide/accent rates from the factory presets of each genre, interpolates them, and generates a single groove. It does not stack two patterns. This works **offline**, or with Claude using the blend as guidance.

### MIDI import / export
- **Import** reads type 0 and type 1 files: tempo, multiple tracks, drum and bass channel selection, T-8 or General MIDI drum maps, start bar, 1–2 bars, and quantize tolerance. You get a conversion preview and warnings for unsupported events, unmapped notes, quantization, overlapping bass notes and dropped notes. Overlapping (legato) bass notes become slides.
- **Export** writes type 1 files for Ableton Live: a tempo track, drums on channel 10 using T-8 note numbers, and bass on channel 2. You can export the current variation, or all four as separate files.

---

## Hardware transfer to the T-8

**T-8 ▸ Transfer to T-8…** (⇧⌘T) walks you through six steps:

1. **Connect.** Explains that MIDI playback is not storage, and shows the verification status.
2. **Back up.** Hold [PLAY] at power-on and copy the BACKUP folder, then choose it in the app. **Every `.prm` file must parse and re-serialize byte-for-byte**, or native export stays disabled.
3. **Choose slots.** Pick which variation goes into which RHYTHM and BASS file. Each file shows its current content so you can see what will be overwritten.
4. **Review & stage.** Validation runs, and you must acknowledge the unverified format and confirm the overwrite. The app writes `~/Documents/T-8 Pattern Studio/Transfers/T8-Transfer-<time>/`:
   - `ORIGINAL-BACKUP/` is an untouched copy.
   - `RESTORE/BASS`, `RESTORE/RHYTHM` is the complete set. Only the targeted step values differ, and every other line, field, file and line ending is byte-identical.
   - `transfer-manifest.json` holds checksums and the assignments. `README-RESTORE.txt` has the instructions.
5. **Restore.** Copy into the T-8's RESTORE folder, eject, press [ACCENT], and wait for "dOnE".
6. **Verify.** Make a fresh backup and choose it. The app checks that the targeted slots contain exactly what was staged and that **no other pattern changed**. Only this step reports success.

The same workflow from the command line:
```bash
swift run t8studio inspect-backup ~/T8/BACKUP
swift run t8studio read-slot ~/T8/BACKUP <rhythm-file> <bass-file>
swift run t8studio stage ~/T8/BACKUP "Acid Pressure" <rhythm-file> <bass-file> ~/T8/out --i-understand-unverified --overwrite
swift run t8studio verify ~/T8/BACKUP-after ~/T8/out/T8-Transfer-<time>
```

### What I need from you to verify the transfer
1. **A complete, unmodified T-8 backup** (the BACKUP folder with BASS and RHYTHM). Run `t8studio inspect-backup` on it and send the output, or the folder itself.
2. **A known-content backup.** On the T-8, program pattern 1 with kick on step 1 only, a clap on step 5, an open hat on step 3, and one bass note **C2** on step 1 with accent and slide. Then back up. This pins down the slot↔file mapping, the HT/LT voice mapping, and the bass NOTE offset.
3. Optionally, a backup after setting SHUFFLE to a known value on the unit, to calibrate swing.

Drop real backups into `Tests/T8CoreTests/Fixtures/real-backup/BACKUP/` (git-ignored by default) and `swift test` runs the real-backup round-trip test automatically.

---

## Architecture

```
T8PatternStudio/
├─ Package.swift                 SwiftPM. T8Core + CLI on all platforms; the app target on macOS
├─ Sources/T8Core/               Pure Swift, no UI. Fully unit-tested on macOS and Linux
│  ├─ Model/                     PatternModel: Pattern, DrumPattern, BassPattern, Preset, notation, music theory
│  ├─ Library/                   PresetLibrary, FactoryLibrary (60 presets), LibraryStore (PersistenceManager, migrations, backups)
│  ├─ Editing/                   DrumSequencer/BassSequencer operations, UndoHistory, clipboard
│  ├─ Generation/                PatternVariationEngine (A/B/C/D), GenreProfile, GenreBlend, ProceduralGenerator
│  ├─ Validation/                ValidationEngine, HardwareCapabilities (capability layer + evidence matrix)
│  ├─ MIDI/                      MIDIFile (SMF read/write), MIDIFileImporter, MIDIFileExporter
│  ├─ Playback/                  PlaybackScheduler (shared timing), SynthRenderer (preview synth), WAV writer
│  ├─ Roland/                    PRMDocument (lossless), RolandBackupParser/Serializer (T8PatternCodec, T8Backup), HardwareTransferManager
│  └─ AI/                        AIPatternGenerator (Claude Messages API, schema, validation, retry)
├─ Sources/T8PatternStudio/      macOS app (SwiftUI): ApplicationShell, views, AudioPreviewEngine (AVAudioEngine), MIDIEngine (CoreMIDI), Keychain
├─ Sources/t8studio/             CLI companion
└─ Tests/T8CoreTests/            XCTest suites + synthetic backup fixtures
```

The internal pattern model is separate from Roland's file layout. The Roland layer maps between the two and edits backup files in place, line by line.

### Data model and storage
- **Indexing:** steps are **zero-based** internally (hardware step 1 = index 0). The `.prm` layer converts to one-based `STEP n`.
- **Notes:** MIDI numbers with C4 = 60 (C2 = 36).
- **Pattern:** name, BPM, time signature, swing 0–100, length 1–32, key, scale, six 32-step drum lanes (velocity 0–10, sub-step, probability, sub-step probability), a 32-step accent row, and 32 bass steps (rest / note / tie, accent, slide).
- **Preset:** stable ID (`factory.<genre>.<slug>` or `user.<uuid>`), name, origin, genres, folder, tags, description, notes, energy 1–5, A/B/C/D variations, created/modified dates, and revisions. Favorites and recents live in the library document.
- **User library:** `~/Library/Application Support/T8PatternStudio/library.json` (schema v2, JSON, dates as Foundation reference-date seconds). Writes are atomic. A rolling backup goes to `Backups/` (last 20) on the first save of each launch and before any migration. A damaged file is kept as `library.corrupt-*.json` and the newest readable backup is restored. A library from a newer app version is never modified.
- **Factory presets** are compiled into the app as version-controlled notation (`FactoryLibrary.swift`, versioned by `FactoryLibrary.version`) and are never written to the user file, so updates cannot overwrite user presets. `t8studio export-factory <dir>` writes all 60 as JSON.
- **Preset exchange files:** `.t8presets` (JSON bundle). Imports always become new user presets. Existing presets are never overwritten.

---

## Factory library

15 genres × 4 original patterns. Each has real step data for all six voices, accents, a bass line with ties, accents and slides, BPM, key/scale, swing, length, energy and a description. B/C/D variations are derived from A deterministically. Run `swift run t8studio list` or `t8studio show "<name>"` to inspect them.

| Genre | Presets |
|---|---|
| House | Classic Four 124 · Piano Jack 125 · Warehouse Groove 126 · Late Night Floor 123 |
| Deep House | Velvet Motion 120 · Midnight Current 118 · Afterhours 122 · Submerged 116 |
| Progressive House | Ascending 126 · Long Horizon 124 · Momentum 128 · Afterglow 125 |
| Tech House | Pressure System 128 · Concrete Groove 126 · Switchback 127 · Warehouse Tool 129 |
| Breakbeat | Broken Circuit 132 · Voltage Break 128 · Back Alley 118 · Rupture 135 |
| Lo-Fi Hip-Hop | Dusty Tape 78 · Rainy Window 72 · Cassette Drift 82 · Night Study 85 |
| Trip-Hop | Black Water 88 · Smoke Signals 82 · Low Orbit 92 · Undertow 76 |
| Ambient | Floating Signals 70 · Deep Space 60 · Slow Currents 80 · Weightless 65 |
| Techno | Iron Pulse 135 · Tunnel Vision 132 · Machine State 138 · Sublevel 130 |
| Acid Techno | Acid Pressure 135 · Corrosion 138 · Liquid Circuit 132 · Terminal Acid 140 |
| French Electro | Dark Voltage 128 · Chrome Cathedral 125 · Neon Distortion 130 · Phantom Drive 122 |
| Synthwave | Midnight Highway 105 · Neon Rain 95 · Night Runner 115 · After the Signal 90 |
| Downtempo | Slow Motion 90 · Blue Hour 85 · Drift Pattern 100 · Evening Static 78 |
| Electro Funk | Circuit Funk 115 · Robot Motion 120 · Electric Body 125 · Analog Bounce 110 |
| UK Garage | Two Step Motion 132 · Night Transit 130 · Shuffle Theory 135 · Southside Pulse 128 |

All patterns are original, written from general genre characteristics. None are transcriptions.

---

## Known limitations

- **No hardware testing has been performed.** Writing to the T-8's memory stays behind the round-trip check, explicit acknowledgements, and post-restore verification until it has been confirmed with your unit.
- The backup file naming and slot mapping, the bass NOTE offset, and the SHUFFLE scale are unverified. See the matrix.
- The T-8's tempo and the app's key/scale are not part of the pattern files the open-source editor knows about, so they stay app metadata.
- The `CY` field, `SCALE`, `FLAM`, `TRIPLET` and any unknown fields are preserved but cannot be edited.
- The preview synth is an approximation for auditioning, not an emulation of the T-8's analog circuits.
- In MIDI playback, probability is rolled by the app. Bass slide uses overlapping notes, which is an unverified convention on the T-8.
- Time signature is fixed at 4/4 because the T-8 uses a 16th-note step grid. The Triplet mode is not exposed.
- Space-to-play works when the editor area has focus. ⌘↩ works everywhere.

## Licensing notes
- The T-8 `.prm` format knowledge comes from reading **natebosch/aira_pattern_editor** (BSD-3-Clause, © 2025 aira_pattern_editor authors). No code was copied. The Swift implementation here is independent.
- All sounds are synthesized in code. No samples are used.
- "Roland", "AIRA" and "T-8" are trademarks of Roland Corporation. This project is not affiliated with Roland.

# Ableton Live export

Two formats, chosen in Export > Ableton Live.

## Live Set (.als)

```
<Title> Project/
  <Title>.als          Live Set: MIDI tracks first, then audio tracks
  Samples/             copies of the stems (originals are never touched)
  MIDI/                one .mid per stem plus "All tracks.mid"
  Exports/manifest.json, Exports/READ ME.txt
```

How it is built (`engine/kstem/export/als.py`):

- Starts from `assets/live12-default.als`, a set saved by **Live 12.4.6 Lite**. Clips are copied from clip XML that Live itself wrote (`live12-midi-clip.xml`, `live12-audio-clip.xml`), so every element Live expects is present.
- Every new object gets a fresh id; `NextPointeeId` is raised above the highest id.
- Tempo and time signature are written to the main track's manual value and its automation envelope (Live reads the envelope on load).
- Audio clips use Re-Pitch warp mode with two warp markers that pin the file to its own length, so Live does not re-stretch it; with the set's tempo equal to the detected tempo, audio and MIDI line up from bar 1.
- MIDI notes are written in beats from the start of the audio, the same zero point as the audio clips.
- Live 12 Lite opens at most 8 tracks. MIDI tracks are placed first, audio after, and anything beyond 8 stays in the folder, named in the READ ME and in the export result.
- After writing, the set is re-read and checked: gzip/XML header, track names and kinds, the template's structure outside the clips, ids unique and below `NextPointeeId`, tempo, time signature, note counts per clip, and sample paths. Any difference is shown as a problem in the export result.
- The folder is written as `.Title Project.partial` and renamed when complete; replacing an existing export only removes the old folder after the new one is complete.

What is verified: the same template method opened in Jared's Live 12 Lite (8 tracks, 4/4, 92 BPM) during Kinetic Studio's Phase 6. What still needs testing: a set written by *this* exporter, opened in Live.

### 5-minute check (Live 12 Lite)

1. Import two or three stems, transcribe, Export > Ableton Live > Live Set.
2. Open `<Title>.als` from the new folder. Expected: no "corrupt" or "missing" dialog.
3. Tempo field shows the project's BPM; time signature matches.
4. MIDI tracks are listed first with the stem names; each has one clip starting at bar 1.
5. Audio tracks play the copied stems; MIDI and audio line up when both play (solo a MIDI track with a simple instrument and its audio).
6. Save in Live, close, reopen: still fine.

Report which step failed (and the Live version) if anything goes wrong; the Import Package is the fallback.

## Ableton Import Package

Same folder without the `.als`. The READ ME explains: set Live's tempo to the shown BPM, drag `MIDI/All tracks.mid` (or the per-stem files) to bar 1, drag the stems from `Samples/` to bar 1. Works with any Live version, and with other DAWs.

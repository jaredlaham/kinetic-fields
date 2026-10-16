import Foundation
import XCTest
@testable import StemCore

final class ProjectStoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleProject(audioDir: URL) throws -> Project {
        var p = Project(name: "Test")
        p.tempo = TempoMap(bpm: 124, downbeat: 0.25, source: .detected, confidence: 0.8)
        for name in ["Drums", "Bass", "Keys"] {
            let path = audioDir.appendingPathComponent("\(name).wav")
            try Data([0, 1, 2]).write(to: path)
            var s = Stem(name: name, file: AudioFileRef(path: path.path, sha256: "abc", sampleRate: 44100, channels: 2, frames: 441000, format: "WAV"))
            s.classification = Classification(proposed: name == "Drums" ? .drums : .synthBass, confidence: 0.7)
            s.transcription = Transcription(engine: "test", engineVersion: "0.1.0", mode: .balanced, instrument: s.instrument,
                                            audioSHA256: "abc", pitchBends: false, processingSeconds: 1,
                                            notes: [NoteEvent(pitch: 36, start: 0.5, end: 0.75, velocity: 100, confidence: 0.9)], warnings: [])
            p.stems.append(s)
        }
        return p
    }

    func testRoundTripPreservesEverything() throws {
        let dir = try tempDir()
        var project = try sampleProject(audioDir: dir)
        project.stems[1].editedNotes = [NoteEvent(pitch: 38, start: 0.5, end: 1.0, velocity: 90, confidence: 0.5, accepted: true)]
        project.stems[1].instrumentOverride = .bassGuitar
        project.quantize.enabled = true
        project.quantize.division = .sixteenthTriplet
        let package = dir.appendingPathComponent("Song.kineticstem")
        try ProjectStore.save(project, to: package)
        let loaded = try ProjectStore.load(from: package)
        XCTAssertEqual(loaded.stems.map(\.name), ["Drums", "Bass", "Keys"])
        XCTAssertEqual(loaded.stems[1].editedNotes?.first?.pitch, 38)
        XCTAssertEqual(loaded.stems[1].editedNotes?.first?.accepted, true)
        XCTAssertEqual(loaded.stems[1].instrument, .bassGuitar)
        XCTAssertEqual(loaded.stems[0].transcription?.notes.count, 1)
        XCTAssertEqual(loaded.tempo.bpm, 124)
        XCTAssertEqual(loaded.quantize.division, .sixteenthTriplet)
        XCTAssertEqual(loaded.stems[0].file.relativePath, "Drums.wav")
    }

    func testAudioMovedWithTheProjectIsFoundAgain() throws {
        let dir = try tempDir()
        let project = try sampleProject(audioDir: dir)
        try ProjectStore.save(project, to: dir.appendingPathComponent("Song.kineticstem"))
        let moved = try tempDir().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: dir, to: moved)
        let loaded = try ProjectStore.load(from: moved.appendingPathComponent("Song.kineticstem"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.stems[0].file.path))
    }

    func testNewerSchemaIsRefusedAndOlderIsMigrated() throws {
        var json = try JSONSerialization.jsonObject(with: ProjectStore.encoder().encode(Project(name: "X"))) as! [String: Any]
        json["schemaVersion"] = 99
        XCTAssertThrowsError(try ProjectStore.migrate(JSONSerialization.data(withJSONObject: json))) { error in
            XCTAssertEqual(error as? ProjectStore.StoreError, .newerSchema(99))
        }
        json["schemaVersion"] = 0
        json.removeValue(forKey: "quantize")
        json.removeValue(forKey: "export")
        json.removeValue(forKey: "t8")
        let migrated = try ProjectStore.migrate(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertEqual(migrated.export.ticksPerQuarter, 480)
        XCTAssertEqual(migrated.t8.rhythmChannel, 10)
    }
}

final class QuantizeTests: XCTestCase {
    let tempo = TempoMap(bpm: 120, downbeat: 0)

    func testSixteenthGrid() {
        var s = QuantizeSettings()
        s.enabled = true
        let notes = [NoteEvent(pitch: 60, start: 0.13, end: 0.3, velocity: 100)]
        let q = Quantizer.apply(notes, tempo: tempo, settings: s)
        XCTAssertEqual(q[0].start, 0.125, accuracy: 1e-9)
        XCTAssertEqual(q[0].duration, notes[0].duration, accuracy: 1e-9)
        XCTAssertEqual(notes[0].start, 0.13)  // the source is untouched
    }

    func testStrengthAndSwingAndDisabled() {
        var s = QuantizeSettings()
        s.enabled = true
        s.strength = 0.5
        let n = [NoteEvent(pitch: 60, start: 0.135, end: 0.3, velocity: 100)]
        XCTAssertEqual(Quantizer.apply(n, tempo: tempo, settings: s)[0].start, 0.13, accuracy: 1e-9)
        s.strength = 1
        s.swing = 1
        // Every second 16th moves late by half a step (0.0625 s at 120 BPM).
        XCTAssertEqual(Quantizer.gridTime(0.19, tempo: tempo, settings: s), 0.1875, accuracy: 1e-9)
        s.enabled = false
        XCTAssertEqual(Quantizer.apply(n, tempo: tempo, settings: s)[0].start, 0.135)
    }

    func testTripletGrid() {
        var s = QuantizeSettings()
        s.enabled = true
        s.division = .eighthTriplet
        XCTAssertEqual(Quantizer.gridTime(0.17, tempo: tempo, settings: s), 1.0 / 6.0, accuracy: 1e-9)
    }
}

final class TempoMapTests: XCTestCase {
    func testGridLines() {
        let t = TempoMap(bpm: 120, beatsPerBar: 4, downbeat: 0.5)
        let lines = t.gridLines(from: 0, to: 2.5)
        XCTAssertEqual(lines.map(\.time), [0.0, 0.5, 1.0, 1.5, 2.0, 2.5])
        XCTAssertEqual(lines.filter(\.isBar).map(\.time), [0.5, 2.5])
        XCTAssertEqual(lines.first { $0.time == 2.5 }?.bar, 2)
        XCTAssertEqual(TempoMap(bpm: 90, beatsPerBar: 6, beatUnit: 8).secondsPerBeat, 60.0 / 90.0 / 2, accuracy: 1e-12)
    }
}

final class EngineProtocolTests: XCTestCase {
    func testParsesEventLines() {
        XCTAssertEqual(EngineLineParser.parse(#"{"event": "progress", "fraction": 0.5, "message": "Working"}"#), .progress(0.5, "Working"))
        XCTAssertEqual(EngineLineParser.parse(#"{"event": "error", "kind": "not_found", "message": "gone"}"#), .error(kind: "not_found", message: "gone"))
        XCTAssertNil(EngineLineParser.parse("Predicting MIDI for x.wav..."))
    }

    func testDecodesEngineResults() throws {
        let analyze = #"""
        {"stems": [{"id": "a", "path": "/x.wav", "sha256": "ff", "sample_rate": 44100, "channels": 2, "frames": 100, "duration": 1.5,
          "format": "WAV", "leading_silence": 0.1, "peak_dbfs": -3.0,
          "classification": {"proposed": "synth_bass", "label": "Synth bass", "confidence": 0.8, "scores": {"synth_bass": 0.9},
                             "ranked": [["synth_bass", 0.9], ["bass_guitar", 0.4]], "features": {"median_f0_hz": 55.0}}}],
         "tempo": {"bpm": 124.0, "confidence": 0.7, "alternatives": [62.0, 248.0], "beats": [0.1, 0.58], "downbeat": 0.1,
                   "downbeat_confidence": 0.4, "beats_per_bar": 4, "tempo_stable": true, "local_bpm_range": [123.5, 124.5], "warnings": []}}
        """#
        let a = try EngineLineParser.decoder().decode(AnalyzeResponse.self, from: Data(analyze.utf8))
        XCTAssertEqual(a.stems[0].classification?.model?.proposed, .synthBass)
        XCTAssertEqual(a.stems[0].classification?.model?.scores["bass_guitar"], 0.4)
        XCTAssertEqual(a.tempo.localBpmRange, [123.5, 124.5])

        let transcribe = #"""
        {"notes": [{"pitch": 36, "start": 0.5, "end": 0.7, "velocity": 100, "confidence": 0.9, "bends": []},
                   {"pitch": 36, "start": 1.0, "end": 1.1, "velocity": 90, "confidence": 0.8, "drum": "kick", "bends": []}],
         "pipeline": "drums", "engine": "x", "engine_version": "0.1.0", "mode": "balanced", "instrument": "drums",
         "processing_seconds": 1.2, "warnings": ["w"], "audio_sha256": "ff"}
        """#
        let t = try EngineLineParser.decoder().decode(TranscribeResponse.self, from: Data(transcribe.utf8)).transcription(pitchBends: false)
        XCTAssertEqual(t.notes.count, 2)
        XCTAssertEqual(t.notes[1].drum, "kick")
        XCTAssertEqual(t.instrument, .drums)
        XCTAssertTrue(t.matches(sha: "ff", mode: .balanced, instrument: .drums, pitchBends: false))
        XCTAssertFalse(t.matches(sha: "ff", mode: .high, instrument: .drums, pitchBends: false))
    }

    func testRequestsUseSnakeCase() throws {
        let r = TranscribeRequest(path: "/a.wav", instrument: .bassGuitar, mode: .high, pitchBends: true, sensitivity: 0.5)
        let json = String(decoding: try EngineLineParser.encoder().encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains("\"pitch_bends\":true"))
        XCTAssertTrue(json.contains("\"instrument\":\"bass_guitar\""))
    }
}

final class EditingTests: XCTestCase {
    func testEditsAndUndo() {
        let a = NoteEvent(pitch: 60, start: 0, end: 1, velocity: 100)
        let b = NoteEvent(pitch: 64, start: 1, end: 2, velocity: 100)
        var notes = [a, b]
        var history = EditHistory()
        let stem = UUID()
        let moved = NoteEditor.move([a.id], in: notes, by: -5, semitones: 70)
        XCTAssertEqual(moved.first { $0.id == a.id }?.start, 0)  // clamped at zero
        XCTAssertEqual(moved.first { $0.id == a.id }?.pitch, 127)  // clamped at 127
        history.record(stem: stem, before: notes, after: moved, label: "Move")
        notes = moved
        let entry = history.undo()
        XCTAssertEqual(entry?.before, [a, b])
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo()?.after, moved)
        XCTAssertEqual(NoteEditor.setVelocity([b.id], in: notes, to: 300).first { $0.id == b.id }?.velocity, 127)
        XCTAssertEqual(NoteEditor.delete([a.id], from: notes).count, 1)
    }

    func testExportableNotesRespectThresholdAndReview() {
        var s = Stem(name: "x", file: AudioFileRef(path: "/x", sampleRate: 1, channels: 1, frames: 1, format: "WAV"))
        s.confidenceThreshold = 0.5
        s.editedNotes = [
            NoteEvent(pitch: 1, start: 0, end: 1, velocity: 1, confidence: 0.9),
            NoteEvent(pitch: 2, start: 0, end: 1, velocity: 1, confidence: 0.2),
            NoteEvent(pitch: 3, start: 0, end: 1, velocity: 1, confidence: 0.2, accepted: true),
            NoteEvent(pitch: 4, start: 0, end: 1, velocity: 1, confidence: 0.9, accepted: false),
        ]
        XCTAssertEqual(s.exportableNotes.map(\.pitch), [1, 3])
    }
}

final class WaveformTests: XCTestCase {
    func testPeaksLevelsAndCache() {
        var acc = PeakAccumulator()
        let samples = (0..<(256 * 10_000)).map { Float(sin(Double($0) / 50)) }
        samples.withUnsafeBufferPointer { acc.add($0) }
        let peaks = WaveformPeaks(sampleRate: 44100, frames: Int64(samples.count), base: acc.finish())
        XCTAssertEqual(peaks.levels[0].count, 20_000)
        XCTAssertGreaterThan(peaks.levels.count, 2)
        let (lo, hi) = peaks.range(0, 1, secondsPerPixel: 0.1)
        XCTAssertLessThan(lo, -0.9)
        XCTAssertGreaterThan(hi, 0.9)
        XCTAssertEqual(WaveformPeaks.decode(peaks.encoded()), peaks)
    }
}

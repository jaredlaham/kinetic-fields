import XCTest
@testable import T8Core

final class MIDIAndAudioTests: XCTestCase {
    func testExportThenImportRoundTrip() throws {
        let source = FactoryLibrary.presets.first { $0.name == "Night Runner" }!.main
        var options = MIDIExportOptions()
        options.applySwing = false
        let file = MIDIFileExporter.export(source, options: options)
        let data = file.serialized()
        let parsed = try MIDIFile.parse(data)
        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.tracks.count, 3)
        XCTAssertEqual(parsed.initialTempoBPM, 115, accuracy: 0.01)

        let result = MIDIFileImporter.importPattern(parsed, name: "Imported", options: {
            var o = MIDIImportOptions()
            o.bassChannel = 1
            return o
        }())
        let imported = result.pattern
        XCTAssertEqual(imported.length, 16)
        XCTAssertEqual(imported.bpm, 115)
        for voice in DrumVoice.allCases {
            for step in 0..<16 {
                XCTAssertEqual(imported.drums[voice, step] != nil, source.drums[voice, step] != nil, "\(voice) step \(step + 1)")
            }
        }
        for step in 0..<16 where source.bass[step].kind == .note {
            XCTAssertEqual(imported.bass[step].kind, .note, "step \(step + 1)")
            XCTAssertEqual(imported.bass[step].note, source.bass[step].note)
        }
    }

    func testDrumStepIndexingAndNoteMapping() throws {
        var pattern = Pattern(name: "map", bpm: 120, length: 16)
        pattern.drums[.clap, 4] = .normal
        pattern.drums[.tom, 7] = .normal
        let file = MIDIFileExporter.export(pattern)
        let drumTrack = file.tracks[1]
        let ons = drumTrack.events.compactMap { e -> (Int, UInt8, UInt8)? in
            if case .noteOn(let ch, let n, _) = e.event { return (e.tick, ch, n) }
            return nil
        }
        XCTAssertEqual(ons.count, 2)
        XCTAssertEqual(ons[0].0, 4 * 120, "step index 4 = tick 480 at 480 PPQ")
        XCTAssertEqual(ons[0].1, 9, "rhythm channel 10")
        XCTAssertEqual(ons[0].2, 50, "T-8 clap transmits note 50")
        XCTAssertEqual(ons[1].2, 47, "T-8 tom transmits note 47")
    }

    func testBassSlideBecomesOverlapAndBackToSlide() throws {
        var pattern = Pattern(name: "slide", bpm: 120, length: 16)
        pattern.bass = BassPattern(steps: try PatternNotation.parseBass("C2~ D2 . . . . . . . . . . . . . ."))
        let events = PlaybackScheduler.events(for: pattern)
        let bass = events.filter { if case .bass = $0.kind { return true } else { return false } }
        XCTAssertEqual(bass.count, 2)
        XCTAssertGreaterThan(bass[0].position + bass[0].duration, bass[1].position, "slid note overlaps the next")
        if case .bass(_, _, let slideIn) = bass[1].kind { XCTAssertTrue(slideIn) } else { XCTFail() }

        let file = MIDIFileExporter.export(pattern)
        let imported = MIDIFileImporter.importPattern(try MIDIFile.parse(file.serialized()), name: "x", options: {
            var o = MIDIImportOptions(); o.bassChannel = 1; return o
        }()).pattern
        XCTAssertTrue(imported.bass[0].slide)
        XCTAssertFalse(imported.bass[1].slide)
    }

    func testImportWarningsAndType0() throws {
        // Type 0 file: drums on ch10 with an unmapped note, bass on ch1 with a chord, a pitch bend, off-grid note.
        let track = MIDIFile.Track(events: [
            .init(tick: 0, event: .tempo(microsecondsPerQuarter: 500_000)),
            .init(tick: 0, event: .noteOn(channel: 9, note: 36, velocity: 100)),
            .init(tick: 60, event: .noteOff(channel: 9, note: 36, velocity: 0)),
            .init(tick: 0, event: .noteOn(channel: 9, note: 81, velocity: 100)),
            .init(tick: 60, event: .noteOff(channel: 9, note: 81, velocity: 0)),
            .init(tick: 125, event: .noteOn(channel: 0, note: 40, velocity: 100)),
            .init(tick: 125, event: .noteOn(channel: 0, note: 47, velocity: 100)),
            .init(tick: 200, event: .noteOff(channel: 0, note: 40, velocity: 0)),
            .init(tick: 200, event: .noteOff(channel: 0, note: 47, velocity: 0)),
            .init(tick: 300, event: .pitchBend(channel: 0, value: 9000)),
            .init(tick: 1935, event: .noteOn(channel: 9, note: 38, velocity: 100)),
            .init(tick: 1990, event: .noteOff(channel: 9, note: 38, velocity: 0)),
        ])
        let file = MIDIFile(format: 0, ticksPerQuarter: 480, tracks: [track])
        let parsed = try MIDIFile.parse(file.serialized())
        XCTAssertEqual(parsed.format, 0)
        let result = MIDIFileImporter.importPattern(parsed, name: "t0")
        XCTAssertNotNil(result.pattern.drums[.kick, 0])
        XCTAssertEqual(result.pattern.bass[1].note, 40, "lowest note of a chord wins")
        let warnings = result.warnings.joined(separator: " | ")
        XCTAssertTrue(warnings.contains("pitch bend"), warnings)
        XCTAssertTrue(warnings.contains("Unmapped drum notes ignored: 81"), warnings)
        XCTAssertTrue(warnings.contains("overlapping bass"), warnings)
        XCTAssertNotNil(result.pattern.drums[.snare, 16], "tick 1935 ≈ step index 16 (first step of bar 2)")
        XCTAssertEqual(result.pattern.length, 32)
    }

    func testRunningStatusAndRejection() throws {
        // Hand-built track using running status (0x90 omitted for the second event).
        var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        let body: [UInt8] = [0x00, 0x99, 36, 100, 0x60, 38, 100, 0x00, 0xFF, 0x2F, 0x00]
        bytes += Array("MTrk".utf8) + [0, 0, 0, UInt8(body.count)] + body
        let file = try MIDIFile.parse(Data(bytes))
        let ons = file.tracks[0].events.filter { if case .noteOn = $0.event { return true } else { return false } }
        XCTAssertEqual(ons.count, 2)
        XCTAssertThrowsError(try MIDIFile.parse(Data("RIFF....".utf8)))
        XCTAssertThrowsError(try MIDIFile.parse(Data(bytes.prefix(20))))
    }

    func testSwingDelaysOffbeats() {
        var pattern = Pattern(name: "swing", bpm: 120, swing: 100, length: 16)
        pattern.drums[.closedHat, 0] = .normal
        pattern.drums[.closedHat, 1] = .normal
        let events = PlaybackScheduler.events(for: pattern)
        XCTAssertEqual(events[0].position, 0)
        XCTAssertEqual(events[1].position, 1 + 1.0 / 3.0, accuracy: 1e-9)
    }

    func testOfflineRenderProducesAudioAndRespectsMute() {
        let pattern = FactoryLibrary.presets.first { $0.name == "Acid Pressure" }!.main
        let renderer = SynthRenderer(sampleRate: 22_050, pattern: pattern)
        let samples = renderer.renderOffline(loops: 1)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertLessThanOrEqual(peak, 1.0)
        XCTAssertFalse(samples.contains { $0.isNaN })

        let muted = SynthRenderer(sampleRate: 22_050, pattern: pattern)
        var mix = PreviewMix()
        mix.muted = Set(DrumVoice.allCases.map(\.rawValue) + [PreviewMix.bassTrackID])
        muted.setMix(mix)
        XCTAssertEqual(muted.renderOffline(loops: 1).map(abs).max() ?? 0, 0, accuracy: 1e-6)
    }

    func testStepClockIsSampleAccurate() {
        var pattern = Pattern(name: "clock", bpm: 120, length: 16)
        pattern.drums[.kick, 0] = .normal
        let renderer = SynthRenderer(sampleRate: 48_000, pattern: pattern)
        renderer.play()
        var buffer = [Float](repeating: 0, count: 6_000) // one 16th at 120 BPM = 6000 samples
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frameCount: 5_999) }
        XCTAssertEqual(renderer.currentStep, 0)
        buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frameCount: 2) }
        XCTAssertEqual(renderer.currentStep, 1)
    }

    func testWAVHeader() {
        let wav = WAVWriter.data(samples: [0, 0.5, -0.5], sampleRate: 44_100)
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }
}

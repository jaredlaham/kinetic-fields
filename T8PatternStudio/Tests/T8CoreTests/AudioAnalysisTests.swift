import XCTest
@testable import T8Core

final class AudioAnalysisTests: XCTestCase {
    /// Renders a known pattern with the built-in synth and returns the analysis.
    func analyze(_ pattern: Pattern, loops: Int = 12, steps: Int = 16, lead: Double = 0.37) throws -> AudioBeatAnalyzer.Result {
        let renderer = SynthRenderer(sampleRate: 22_050, pattern: pattern)
        var samples = [Float](repeating: 0, count: Int(lead * 22_050)) // start off-grid
        samples += renderer.renderOffline(loops: loops)
        var options = AudioBeatAnalyzer.Options()
        options.steps = steps
        options.startSeconds = 0
        return try AudioBeatAnalyzer.analyze(samples: samples, sampleRate: 22_050, options: options)
    }

    func lane(_ r: AudioBeatAnalyzer.Result, _ v: DrumVoice) -> String {
        PatternNotation.format(lane: r.pattern.drums.lane(v), length: r.pattern.length).map { $0 == "." ? "." : "x" }.joined()
    }

    func testBrokenBeatWithBass() throws {
        let source = try PatternNotation.pattern(name: "t", bpm: 132, key: .e, scale: .minor,
            drums: [.kick: "x.....x...x.....", .snare: "....x.......x...", .closedHat: "x.x.x.x.x.x.x.x."],
            bass: ". . E1 - . . . . E1 . . . . G1 - .")
        let r = try analyze(source)
        print("BROKEN", lane(r, .kick), lane(r, .snare), lane(r, .closedHat), PatternNotation.format(bass: r.pattern.bass.steps, length: 16))
        XCTAssertEqual(r.bpm, 132, accuracy: 1)
        XCTAssertEqual(lane(r, .kick), "x.....x...x.....")
        XCTAssertEqual(lane(r, .snare), "....x.......x...")
        XCTAssertEqual(r.pattern.bass[2].note, 28, "E1")
        XCTAssertEqual(r.pattern.bass[8].note, 28, "E1")
        XCTAssertEqual(r.pattern.bass[13].note, 31, "G1")
        XCTAssertEqual(r.pattern.key, .e)
    }

    func testTwentyFourStepsAndAIContext() throws {
        let source = FactoryLibrary.presets.first { $0.name == "Dark Voltage" }!.main
        let r = try analyze(source, steps: 24)
        XCTAssertEqual(r.pattern.length, 24)
        XCTAssertEqual(r.pattern.timeSignature, .fourFour)
        XCTAssertFalse(ValidationEngine.hasErrors(ValidationEngine.validate(r.pattern)))
        XCTAssertTrue(r.summaryForAI.contains("128 BPM"))
        XCTAssertTrue(r.warnings.contains { $0.contains("24-step") })
        // Kick on every quarter of the 1.5 bars.
        XCTAssertEqual(lane(r, .kick), "x...x...x...x...x...x...")
    }

    func testFourOnTheFloorWithBackbeat() throws {
        let source = try PatternNotation.pattern(name: "t", bpm: 124, key: .a, scale: .minor,
            drums: [.kick: "x...x...x...x...", .clap: "....x.......x...", .closedHat: "..x...x...x...x."], bass: ".")
        let r = try analyze(source)
        print("KICK", lane(r, .kick), "SNARE", lane(r, .snare), "HAT", lane(r, .closedHat), lane(r, .openHat))
        XCTAssertEqual(r.bpm, 124, accuracy: 1)
        XCTAssertEqual(lane(r, .kick), "x...x...x...x...")
        XCTAssertEqual(lane(r, .snare), "....x.......x...")
    }
}

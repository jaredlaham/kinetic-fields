import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import T8Core

final class EditingTests: XCTestCase {
    func testUndoRedo() {
        var history = UndoHistory<Pattern>()
        var pattern = Pattern()
        history.record(pattern)
        PatternEditor.toggle(&pattern, voice: .kick, step: 0)
        let edited = pattern
        pattern = history.undo(current: pattern)!
        XCTAssertNil(pattern.drums[.kick, 0])
        pattern = history.redo(current: pattern)!
        XCTAssertEqual(pattern, edited)
        XCTAssertFalse(history.canRedo)
    }

    func testHatChokeAndPaint() {
        var p = Pattern()
        PatternEditor.paint(&p, voice: .openHat, step: 2, on: true)
        PatternEditor.paint(&p, voice: .closedHat, step: 2, on: true)
        XCTAssertNil(p.drums[.openHat, 2])
        XCTAssertNotNil(p.drums[.closedHat, 2])
    }

    func testCopyPasteDuplicateAndClear() {
        var p = FactoryLibrary.presets[0].main
        let firstBar = p
        PatternEditor.duplicateLength(&p)
        XCTAssertEqual(p.length, 32)
        for step in 0..<16 {
            XCTAssertEqual(p.drums[.kick, step + 16], firstBar.drums[.kick, step])
            XCTAssertEqual(p.bass[step + 16], firstBar.bass[step])
        }
        PatternEditor.clear(&p, selection: StepSelection(voices: [.kick], steps: 0..<4))
        XCTAssertNil(p.drums[.kick, 0])
        XCTAssertNotNil(p.drums[.kick, 4])
    }

    func testTiesStayValid() {
        var p = Pattern()
        PatternEditor.setBassNote(&p, step: 0, note: 36, scaleLock: false)
        PatternEditor.setBassTie(&p, step: 1)
        PatternEditor.setBassTie(&p, step: 5) // previous is a rest: ignored
        XCTAssertEqual(p.bass[1].kind, .tie)
        XCTAssertEqual(p.bass[5].kind, .rest)
        PatternEditor.setBassRest(&p, step: 0)
        XCTAssertEqual(p.bass[1].kind, .rest, "a tie cannot follow a rest")
    }

    func testScaleLockedTransposeAndKeyChange() {
        var p = Pattern(key: .c, scale: .minor)
        PatternEditor.setBassNote(&p, step: 0, note: 37, scaleLock: true)
        XCTAssertEqual(p.bass[0].note, 36)
        PatternEditor.changeKey(&p, to: .d)
        XCTAssertEqual(p.bass[0].note, 38)
        PatternEditor.transposeBass(&p, semitones: 100, scaleLock: false)
        XCTAssertTrue(HardwareCapabilities.bassNoteRange.contains(p.bass[0].note))
    }

    func testRandomizeIsDeterministicPerSeed() {
        var a = Pattern(), b = Pattern()
        PatternEditor.randomizeDrums(&a, voices: DrumVoice.allCases, density: 0.6, seed: 42)
        PatternEditor.randomizeDrums(&b, voices: DrumVoice.allCases, density: 0.6, seed: 42)
        XCTAssertEqual(a, b)
        PatternEditor.randomizeBass(&a, density: 0.5, slideAmount: 0.2, accentAmount: 0.2, octave: 1, seed: 7)
        XCTAssertFalse(ValidationEngine.hasErrors(ValidationEngine.validate(a)))
    }

    func testValidationCatchesBadData() {
        var p = Pattern()
        p.bass[3] = BassStep(kind: .tie, note: 36)
        p.bass[5] = .note(5)
        p.bpm = 900
        let issues = ValidationEngine.validate(p)
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 3, "\(issues)")
    }
}

final class GenerationTests: XCTestCase {
    func testProfilesAreLearnedFromFactory() {
        let house = GenreProfile.learned(from: .house)
        XCTAssertEqual(house.drumTemplates[.kick]![0], 1.0)
        XCTAssertEqual(house.drumTemplates[.kick]![4], 1.0)
        let tripHop = GenreProfile.learned(from: .tripHop)
        XCTAssertLessThan(tripHop.bpm, house.bpm)
    }

    func testBlendIsCoherentAndWeighted() {
        let blend = GenreBlend(primary: .tripHop, secondary: .frenchElectro, primaryPercent: 70)
        let profile = blend.profile
        let trip = GenreProfile.learned(from: .tripHop), electro = GenreProfile.learned(from: .frenchElectro)
        XCTAssertEqual(profile.bpm, trip.bpm * 0.7 + electro.bpm * 0.3, accuracy: 1e-9)
        XCTAssertEqual(blend.label, "70% Trip-Hop / 30% French Electro")
        let pattern = ProceduralGenerator.generate(profile: profile, name: "Blend", seed: 3)
        XCTAssertFalse(ValidationEngine.hasErrors(ValidationEngine.validate(pattern)))
        XCTAssertNotNil(pattern.drums[.kick, 0])
        XCTAssertGreaterThan(pattern.bass.noteCount(length: pattern.length), 0)
        XCTAssertTrue((Int(trip.bpm)...Int(electro.bpm) + 1).contains(Int(pattern.bpm)))
    }

    func testEveryGenreGeneratesValidPatterns() {
        for genre in Genre.allCases {
            for seed in 0..<5 {
                let p = ProceduralGenerator.generate(profile: .learned(from: genre), name: genre.displayName, options: .init(length: 16), seed: UInt64(seed))
                XCTAssertFalse(ValidationEngine.hasErrors(ValidationEngine.validate(p)), "\(genre) seed \(seed)")
            }
        }
    }
}

/// Captures requests and replays canned API responses.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), status)
    }
}

final class AITests: XCTestCase {
    static func messageBody(_ payload: String, stop: String = "end_turn") -> String {
        let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: [payload], options: .fragmentsAllowed), as: UTF8.self)
        let text = String(escaped.dropFirst().dropLast())
        return #"{"type":"message","role":"assistant","stop_reason":"\#(stop)","content":[{"type":"text","text":\#(text)}]}"#
    }

    static let goodPayload = """
    {"name":"Dark Drive","bpm":128,"swing":0,"length":16,"key":"D","scale":"minor",
     "kick":"x... x... x... x...","snare":"................","clap":".... X... .... X...","tom":"................",
     "closedHat":"x.x. x.x. x.x. x.x.","openHat":"................","accents":"a... a... a... a...",
     "bass":"D1! . D2~ D1 . . F1 . D1 . . A1 . C2 . D1","explanation":"Driving electro groove."}
    """

    func testGenerateBuildsCorrectRequestAndValidates() async throws {
        let transport = MockTransport([(200, Self.messageBody(Self.goodPayload))])
        let generator = AIPatternGenerator(apiKey: "sk-test", transport: transport)
        let result = try await generator.generate(.create(prompt: "dark 128 electro"), context: AIContext(genre: .frenchElectro))
        XCTAssertEqual(result.pattern.name, "Dark Drive")
        XCTAssertEqual(result.pattern.bass[0], .note(26, accent: true))
        XCTAssertTrue(result.pattern.bass[2].slide)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
    }

    func testInvalidOutputIsRejectedThenRetriedWithFeedback() async throws {
        let bad = Self.goodPayload.replacingOccurrences(of: "\"kick\":\"x... x... x... x...\"", with: "\"kick\":\"x... x...\"")
        let transport = MockTransport([(200, Self.messageBody(bad)), (200, Self.messageBody(Self.goodPayload))])
        let result = try await AIPatternGenerator(apiKey: "k", transport: transport).generate(.surprise, context: AIContext())
        XCTAssertEqual(result.pattern.name, "Dark Drive")
        XCTAssertEqual(transport.requests.count, 2)
        let second = try JSONSerialization.jsonObject(with: transport.requests[1].httpBody!) as! [String: Any]
        let messages = second["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 3, "append-only retry: user, assistant, user")
        XCTAssertTrue((messages[2]["content"] as! String).contains("Kick lane has 8 steps"))
    }

    func testPersistentInvalidOutputNeverReachesEditor() async {
        let bad = Self.goodPayload.replacingOccurrences(of: "D1! . D2~", with: "Q9 . D2~")
        let transport = MockTransport([(200, Self.messageBody(bad)), (200, Self.messageBody(bad))])
        do {
            _ = try await AIPatternGenerator(apiKey: "k", transport: transport).generate(.surprise, context: AIContext())
            XCTFail("should throw")
        } catch let error as AIError {
            guard case .invalidPattern = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testErrorsAndRefusals() async {
        let missing = AIPatternGenerator(apiKey: "", transport: MockTransport([]))
        do { _ = try await missing.generate(.surprise, context: AIContext()); XCTFail() } catch { XCTAssertEqual(error as? AIError, .missingAPIKey) }

        let http = AIPatternGenerator(apiKey: "k", transport: MockTransport([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)]))
        do { _ = try await http.generate(.surprise, context: AIContext()); XCTFail() } catch { XCTAssertEqual(error as? AIError, .http(status: 401, message: "invalid x-api-key")) }

        let refusal = AIPatternGenerator(apiKey: "k", transport: MockTransport([(200, #"{"stop_reason":"refusal","stop_details":{"explanation":"nope"},"content":[]}"#)]))
        do { _ = try await refusal.generate(.surprise, context: AIContext()); XCTFail() } catch { XCTAssertEqual(error as? AIError, .refused("nope")) }
    }

    func testPayloadRoundTripsFactoryPresets() throws {
        for preset in FactoryLibrary.presets {
            let payload = AIPatternPayload(from: preset.main)
            let (pattern, _) = try payload.toPattern()
            XCTAssertEqual(pattern.length, preset.main.length)
            for voice in DrumVoice.allCases {
                for step in 0..<pattern.length {
                    XCTAssertEqual(pattern.drums[voice, step] != nil, preset.main.drums[voice, step] != nil, "\(preset.name) \(voice) \(step)")
                }
            }
        }
    }
}

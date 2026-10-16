import XCTest
@testable import T8Core

final class ModelAndFactoryTests: XCTestCase {
    func testNoteNames() {
        XCTAssertEqual(NoteName.midiNote(from: "C4"), 60)
        XCTAssertEqual(NoteName.midiNote(from: "C2"), 36)
        XCTAssertEqual(NoteName.midiNote(from: "A#1"), 34)
        XCTAssertEqual(NoteName.midiNote(from: "Bb1"), 34)
        XCTAssertEqual(NoteName.midiNote(from: "C-1"), 0)
        XCTAssertNil(NoteName.midiNote(from: "H2"))
        XCTAssertEqual(NoteName.string(for: 36), "C2")
        XCTAssertEqual(NoteName.string(for: 21), "A0")
    }

    func testScaleSnapAndMove() {
        XCTAssertEqual(Scale.minor.snap(midiNote: 37, root: .c), 36) // C# -> C in C minor (tie resolves down)
        XCTAssertEqual(Scale.minor.move(midiNote: 36, degrees: 2, root: .c), 39) // C -> D -> Eb
        XCTAssertEqual(Scale.chromatic.snap(midiNote: 37, root: .c), 37)
    }

    func testFactoryLibraryHasSixtyPresetsFourPerGenre() {
        XCTAssertEqual(FactoryLibrary.presets.count, 60)
        for genre in Genre.allCases {
            XCTAssertEqual(FactoryLibrary.presets(for: genre).count, 4, "\(genre)")
        }
        XCTAssertEqual(Set(FactoryLibrary.presets.map(\.id)).count, 60, "IDs must be unique")
    }

    func testFactoryPresetsContainRealPlayableData() {
        for preset in FactoryLibrary.presets {
            let p = preset.main
            XCTAssertTrue(preset.isFactory)
            XCTAssertFalse(preset.summary.isEmpty, preset.name)
            XCTAssertGreaterThan(p.drums.hitCount(length: p.length), 2, "\(preset.name) needs drum data")
            XCTAssertGreaterThan(p.bass.noteCount(length: p.length), 0, "\(preset.name) needs bass data")
            XCTAssertNotNil(p.drums[.kick, 0] ?? p.drums[.kick, 2] ?? p.drums.lane(.kick).compactMap { $0 }.first, preset.name)
            XCTAssertTrue((1...5).contains(preset.energy))
            for slot in VariationSlot.allCases {
                let issues = ValidationEngine.validate(preset.variations[slot])
                XCTAssertFalse(ValidationEngine.hasErrors(issues), "\(preset.name) \(slot): \(issues)")
            }
        }
    }

    /// Catches typos where a lane is accidentally 15 or 17 steps long.
    func testFactoryNotationLanesMatchLength() throws {
        for d in FactoryLibrary.definitions {
            for lane in [d.kick, d.snare, d.clap, d.tom, d.ch, d.oh, d.accents] where !lane.isEmpty {
                let count = lane.filter { $0 != " " && $0 != "|" }.count
                XCTAssertTrue(count == d.length || count == 16, "\(d.id) lane '\(lane)' has \(count) steps")
            }
            let bassCount = d.bass.split(separator: " ").count
            XCTAssertTrue(bassCount == d.length || bassCount == 16, "\(d.id) bass has \(bassCount) steps")
        }
    }

    func testRequestedBPMs() {
        let expected: [String: Double] = [
            "Classic Four": 124, "Velvet Motion": 120, "Rupture": 135, "Undertow": 76,
            "Deep Space": 60, "Terminal Acid": 140, "Dark Voltage": 128, "Southside Pulse": 128,
        ]
        for (name, bpm) in expected {
            XCTAssertEqual(FactoryLibrary.presets.first { $0.name == name }?.main.bpm, bpm, name)
        }
    }

    func testFactoryContentIsDeterministic() {
        // Variations are derived with a stable hash, so re-deriving gives identical results.
        let preset = FactoryLibrary.presets[10]
        let again = PatternVariationEngine.makeVariations(from: preset.main, genre: preset.primaryGenre,
                                                         seed: UInt64(truncatingIfNeeded: FactoryLibrary.definitions[10].id.hashValueStable))
        XCTAssertEqual(again, preset.variations)
    }

    func testVariationsDiffer() {
        let preset = FactoryLibrary.presets.first { $0.name == "Classic Four" }!
        let v = preset.variations
        XCTAssertNotEqual(v.a, v.b)
        XCTAssertNotEqual(v.a, v.d)
        XCTAssertLessThanOrEqual(v.c.drums.hitCount(length: 16), v.a.drums.hitCount(length: 16))
        XCTAssertGreaterThan(v.b.drums.hitCount(length: 16), v.a.drums.hitCount(length: 16))
        // Fill ends with snare activity in the last beat.
        XCTAssertNotNil(v.d.drums[.snare, 15])
    }

    func testNotationRoundTrip() throws {
        let bass = "A1! . A1~ - C2 . . G1"
        let steps = try PatternNotation.parseBass(bass)
        XCTAssertEqual(steps[0], .note(33, accent: true))
        XCTAssertEqual(steps[2].slide, true)
        XCTAssertEqual(steps[3].kind, .tie)
        XCTAssertEqual(steps[3].note, 33)
        XCTAssertEqual(PatternNotation.format(bass: steps, length: 8), bass)
        XCTAssertThrowsError(try PatternNotation.parseBass(". - C1"))
        XCTAssertThrowsError(try PatternNotation.parseDrumLane("x..z"))
    }

    func testPatternCodableRoundTrip() throws {
        let preset = FactoryLibrary.presets[37]
        let data = try JSONCoding.encoder.encode(preset)
        let decoded = try JSONCoding.decoder.decode(Preset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testZeroBasedIndexingDocumented() {
        var p = Pattern()
        PatternEditor.toggle(&p, voice: .kick, step: 0)
        XCTAssertNotNil(p.drums.lane(.kick)[0], "Step 1 on the hardware is index 0")
    }
}

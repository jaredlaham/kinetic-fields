import XCTest
@testable import T8Core

/// Format tests run against SYNTHETIC fixtures that mirror the open-source
/// AIRA Pattern Editor's .prm format. See Fixtures/synthetic-backup/README.md.
final class RolandBackupTests: XCTestCase {
    var fixtureRoot: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("synthetic-backup/BACKUP")
    }

    func loadBackup() throws -> T8BackupSet { try T8BackupSet.load(from: fixtureRoot) }

    func testUnchangedBackupRoundTripsByteForByte() throws {
        let backup = try loadBackup()
        XCTAssertEqual(backup.rhythm.count, 4)
        XCTAssertEqual(backup.bass.count, 4)
        XCTAssertTrue(backup.problems.isEmpty, "\(backup.problems)")
        XCTAssertTrue(backup.roundTripVerified)
        for file in backup.allFiles {
            XCTAssertEqual(file.document.serialized(), file.originalData, file.relativePath)
        }
    }

    func testCRLFAndBOMPreserved() throws {
        let crlf = try loadBackup().file(part: .rhythm, named: "PTN02.PRM")!
        XCTAssertEqual(crlf.document.lineEnding, "\r\n")
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("LENGTH\t= 16\nODD LINE WITHOUT EQUALS\n".utf8))
        let doc = try PRMDocument.parse(bom)
        XCTAssertEqual(doc.serialized(), bom)
    }

    func testLoadsFromVolumeRootToo() throws {
        let parent = fixtureRoot.deletingLastPathComponent()
        XCTAssertEqual(try T8BackupSet.load(from: parent).rhythm.count, 4)
    }

    func testRejectsMalformedAndBinary() {
        XCTAssertThrowsError(try PRMDocument.parse(Data()))
        XCTAssertThrowsError(try PRMDocument.parse(Data([0x00, 0x01, 0x02])))
        let notRhythm = try! PRMDocument.parse(Data("LENGTH\t= 16\nSTEP 1\t= FOO=1\n".utf8))
        XCTAssertThrowsError(try T8RhythmCodec.decode(notRhythm))
        let badValue = try! PRMDocument.parse(Data("STEP 1\t= BD=1Z0AA SD=000AA\n".utf8))
        XCTAssertThrowsError(try T8RhythmCodec.decode(badValue))
        XCTAssertThrowsError(try T8BackupSet.load(from: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")))
    }

    func testDecodeRhythmAndBass() throws {
        let backup = try loadBackup()
        let pattern = try backup.pattern(rhythmFile: "PTN01.PRM", bassFile: "PTN01.PRM", name: "Slot 1")
        XCTAssertEqual(pattern.length, 16)
        XCTAssertEqual(pattern.drums[.kick, 0], DrumHit(velocity: 10))
        XCTAssertEqual(pattern.drums[.clap, 4], DrumHit(velocity: 7), "HT field carries the clap")
        XCTAssertNil(pattern.drums[.snare, 4])
        XCTAssertTrue(pattern.drums.accents[0])
        XCTAssertEqual(pattern.swing, T8Shuffle.swing(fromFileValue: 30))
        XCTAssertEqual(pattern.bass[0], .note(37, accent: true), "NOTE 25 + assumed offset 12")
        XCTAssertEqual(pattern.bass[1].kind, .tie)
        XCTAssertEqual(pattern.bass[1].note, 37, "tie mirrors the held note")
        XCTAssertEqual(pattern.bass[2].kind, .rest)
    }

    func testChangingExactlyOneDrumStepChangesExactlyOneLine() throws {
        let file = try loadBackup().file(part: .rhythm, named: "PTN03.PRM")!
        var pattern = Pattern(name: "x")
        let decoded = try T8RhythmCodec.decode(file.document)
        pattern.drums = decoded.drums
        pattern.length = decoded.length
        pattern.swing = decoded.swing
        PatternEditor.toggle(&pattern, voice: .tom, step: 6) // hardware step 7

        var document = file.document
        try T8RhythmCodec.apply(pattern, to: &document, writeSwing: false)
        let before = String(decoding: file.originalData, as: UTF8.self).components(separatedBy: "\n")
        let after = String(decoding: document.serialized(), as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed[0].element.1.hasPrefix("STEP 7\t="))
        XCTAssertTrue(changed[0].element.1.contains("LT=170AA"), changed[0].element.1)
        XCTAssertTrue(changed[0].element.1.contains("CY=000AA"), "unknown/unsupported fields are preserved")
        // Slot 3 has a CY hit on step 1 that the app does not model; it must survive.
        XCTAssertTrue(after[4].contains("CY=170AA"))
    }

    func testChangingExactlyOneBassNoteChangesExactlyOneLine() throws {
        let file = try loadBackup().file(part: .bass, named: "PTN02.PRM")! // CRLF file
        var pattern = Pattern(name: "x")
        let decoded = try T8BassCodec.decode(file.document)
        pattern.bass = decoded.bass
        pattern.length = decoded.length
        PatternEditor.setBassNote(&pattern, step: 8, note: 45, scaleLock: false)

        var document = file.document
        try T8BassCodec.apply(pattern, to: &document)
        let output = document.serialized()
        let before = String(decoding: file.originalData, as: UTF8.self).components(separatedBy: "\r\n")
        let after = String(decoding: output, as: UTF8.self).components(separatedBy: "\r\n")
        let changed = zip(before, after).filter { $0 != $1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].1, "STEP 9\t= STATE=1 NOTE=33 ACCENT=0 SLIDE=0")
        XCTAssertEqual(before.count, after.count, "line structure and CRLF endings preserved")
    }

    func testTieAndRestStepsKeepStoredNoteValues() throws {
        let file = try loadBackup().file(part: .bass, named: "PTN01.PRM")!
        var pattern = Pattern()
        pattern.bass = try T8BassCodec.decode(file.document).bass
        var document = file.document
        try T8BassCodec.apply(pattern, to: &document)
        XCTAssertEqual(document.serialized(), file.originalData, "a decode/apply cycle is lossless (tie NOTE=84 and rest NOTE=12 kept)")
    }

    func testStageTransferWritesFullRestoreSetAndKeepsOriginal() throws {
        let backup = try loadBackup()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("t8-stage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: out) }
        let preset = FactoryLibrary.presets.first { $0.name == "Acid Pressure" }!
        let assignment = TransferAssignment(pattern: preset.main, rhythmFile: "PTN04.PRM", bassFile: "PTN04.PRM")

        var options = TransferOptions()
        XCTAssertThrowsError(try HardwareTransferManager.stage(backup: backup, assignments: [assignment], options: options, outputDirectory: out)) {
            XCTAssertEqual($0 as? TransferError, .unverifiedFormatNotAcknowledged)
        }
        options.acknowledgedUnverifiedFormat = true
        XCTAssertThrowsError(try HardwareTransferManager.stage(backup: backup, assignments: [assignment], options: options, outputDirectory: out)) {
            XCTAssertEqual($0 as? TransferError, .overwriteNotConfirmed)
        }
        options.confirmedOverwrite = true
        let staged = try HardwareTransferManager.stage(backup: backup, assignments: [assignment], options: options, outputDirectory: out)

        // Only the targeted slot changed; all other files are byte-identical.
        let modified = staged.manifest.entries.filter(\.modified).map(\.path).sorted()
        XCTAssertEqual(modified, ["BASS/PTN04.PRM", "RHYTHM/PTN04.PRM"])
        for name in ["PTN01.PRM", "PTN02.PRM", "PTN03.PRM"] {
            let restored = try Data(contentsOf: staged.restoreDirectory.appendingPathComponent("RHYTHM/\(name)"))
            XCTAssertEqual(restored, backup.file(part: .rhythm, named: name)!.originalData)
        }
        // Original backup copy is untouched.
        let originalCopy = try Data(contentsOf: staged.originalBackupDirectory.appendingPathComponent("RHYTHM/PTN04.PRM"))
        XCTAssertEqual(originalCopy, backup.file(part: .rhythm, named: "PTN04.PRM")!.originalData)

        // Re-reading the staged files yields the pattern we wrote.
        let restoredSet = try T8BackupSet.load(from: staged.restoreDirectory)
        XCTAssertTrue(restoredSet.roundTripVerified)
        let readBack = try restoredSet.pattern(rhythmFile: "PTN04.PRM", bassFile: "PTN04.PRM", name: "r")
        XCTAssertEqual(readBack.drums, preset.main.drums)
        for i in 0..<16 { XCTAssertTrue(T8BassCodec.equivalent(readBack.bass[i], preset.main.bass[i]), "step \(i + 1)") }

        // Simulated verification: a "post-restore backup" identical to what we staged passes…
        let report = HardwareTransferManager.verify(postRestore: restoredSet, manifest: staged.manifest, original: backup)
        XCTAssertTrue(report.passed, "\(report.slots.map(\.details))")
        // …and the original (pre-restore) backup fails, so copying alone is never "success".
        let notRestored = HardwareTransferManager.verify(postRestore: backup, manifest: staged.manifest, original: backup)
        XCTAssertFalse(notRestored.passed)
    }

    func testDuplicateTargetsRejected() throws {
        let backup = try loadBackup()
        var options = TransferOptions()
        options.acknowledgedUnverifiedFormat = true
        options.confirmedOverwrite = true
        let p = FactoryLibrary.presets[0].main
        let assignments = [
            TransferAssignment(pattern: p, rhythmFile: "PTN01.PRM", bassFile: "PTN01.PRM"),
            TransferAssignment(pattern: p, rhythmFile: "PTN01.PRM", bassFile: "PTN02.PRM"),
        ]
        XCTAssertThrowsError(try HardwareTransferManager.stage(backup: backup, assignments: assignments, options: options, outputDirectory: FileManager.default.temporaryDirectory))
    }

    func testSlotInference() {
        XCTAssertEqual(T8BackupSet.inferSlot("PTN07.PRM"), 7)
        XCTAssertEqual(T8BackupSet.inferSlot("T8_RHY_64.prm"), 64)
        XCTAssertNil(T8BackupSet.inferSlot("PATTERN.PRM"))
    }

    func testStepCodeEncoding() {
        let hit = DrumHit(velocity: 10, subStep: .flam, probability: 50, subStepProbability: 100)
        let code = T8RhythmStepCode.encode(hit, offValue: "000AA")
        XCTAssertEqual(code, "1A45A")
        XCTAssertEqual(T8RhythmStepCode.decode(code), .some(hit))
        XCTAssertEqual(T8RhythmStepCode.decode("000AA"), .some(nil))
        XCTAssertNil(T8RhythmStepCode.decode("1A9AA") ?? nil)
    }
}

/// Runs only when a real T-8 backup has been placed in Fixtures/real-backup/BACKUP.
final class RealBackupTests: XCTestCase {
    func testRealBackupRoundTripsIfPresent() throws {
        guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { throw XCTSkip("no fixtures") }
        let real = fixtures.appendingPathComponent("real-backup/BACKUP")
        guard FileManager.default.fileExists(atPath: real.path) else {
            throw XCTSkip("No real T-8 backup fixture present (see Fixtures/synthetic-backup/README.md).")
        }
        let backup = try T8BackupSet.load(from: real)
        XCTAssertTrue(backup.problems.isEmpty, "\(backup.problems)")
        XCTAssertTrue(backup.roundTripVerified)
    }
}

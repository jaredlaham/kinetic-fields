import Foundation
import T8Core

// t8studio — command-line companion for T-8 Pattern Studio.
// Useful for inspecting real T-8 backups, scripting exports and CI.

let usage = """
usage: t8studio <command> [arguments]

  list [genre]                       List factory presets (optionally one genre)
  show <preset-id|name>              Print a preset's pattern in notation
  export-factory <dir>               Write all 60 factory presets as JSON files
  export-midi <preset> <out.mid>     Export a preset (variation A) as a Standard MIDI File
  render <preset> <out.wav> [loops]  Render a preset with the built-in synth
  import-midi <file.mid>             Convert a MIDI file and print the pattern
  inspect-backup <dir>               Load a T-8 backup, check byte-exact round-trip, list slots
  read-slot <dir> <rhythm> <bass>    Decode one slot from a backup
  stage <dir> <preset> <rhythm> <bass> <outdir> --i-understand-unverified --overwrite
                                     Stage a RESTORE set (see README before using)
  verify <post-restore-dir> <transfer-dir>
                                     Compare a post-restore backup with a staged transfer
  matrix                             Print the hardware compatibility matrix
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func findPreset(_ query: String) -> Preset {
    let presets = FactoryLibrary.presets
    if let match = presets.first(where: { $0.id.rawValue == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
        return match
    }
    fail("No factory preset matches '\(query)'. Try `t8studio list`.")
}

func describe(_ p: Pattern) -> String {
    var lines = ["\(p.name) — \(Int(p.bpm)) BPM, \(p.key.name) \(p.scale.displayName), \(p.length) steps, swing \(p.swing)"]
    for voice in DrumVoice.allCases {
        lines.append("  \(voice.shortName)  " + PatternNotation.format(lane: p.drums.lane(voice), length: p.length))
    }
    lines.append("  AC  " + PatternNotation.format(accents: p.drums.accents, length: p.length))
    lines.append("  BASS " + PatternNotation.format(bass: p.bass.steps, length: p.length))
    return lines.joined(separator: "\n")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

do {
    switch command {
    case "list":
        let genre = args.first.flatMap { Genre(displayName: $0) }
        for g in Genre.allCases where genre == nil || genre == g {
            print("\(g.displayName)")
            for p in FactoryLibrary.presets(for: g) {
                print("  \(p.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Int(p.main.bpm)) BPM  \(p.main.key.name) \(p.main.scale.displayName)  energy \(p.energy)  [\(p.id)]")
            }
        }
    case "show":
        guard let q = args.first else { fail(usage) }
        let preset = findPreset(q)
        print(preset.summary)
        for slot in VariationSlot.allCases {
            print("\n[\(slot.letter) — \(slot.title)]")
            print(describe(preset.variations[slot]))
        }
    case "export-factory":
        guard let dir = args.first else { fail(usage) }
        let root = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for preset in FactoryLibrary.presets {
            let url = root.appendingPathComponent("\(preset.id.rawValue).json")
            try JSONCoding.encoder.encode(preset).write(to: url, options: .atomic)
        }
        print("Wrote \(FactoryLibrary.presets.count) presets to \(root.path)")
    case "export-midi":
        guard args.count == 2 else { fail(usage) }
        let preset = findPreset(args[0])
        try MIDIFileExporter.export(preset.main).serialized().write(to: URL(fileURLWithPath: args[1]))
        print("Wrote \(args[1])")
    case "render":
        guard args.count >= 2 else { fail(usage) }
        let preset = findPreset(args[0])
        let loops = args.count > 2 ? Int(args[2]) ?? 2 : 2
        let renderer = SynthRenderer(sampleRate: 44_100, pattern: preset.main)
        let samples = renderer.renderOffline(loops: loops)
        try WAVWriter.data(samples: samples, sampleRate: 44_100).write(to: URL(fileURLWithPath: args[1]))
        print("Rendered \(loops) loop(s) of \(preset.name) to \(args[1])")
    case "import-midi":
        guard let path = args.first else { fail(usage) }
        let file = try MIDIFile.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let result = MIDIFileImporter.importPattern(file, name: (path as NSString).lastPathComponent)
        print(describe(result.pattern))
        for w in result.warnings { print("warning: \(w)") }
    case "inspect-backup":
        guard let dir = args.first else { fail(usage) }
        let backup = try T8BackupSet.load(from: URL(fileURLWithPath: dir))
        print("Rhythm files: \(backup.rhythm.count)   Bass files: \(backup.bass.count)")
        for file in backup.allFiles {
            print("  \(file.relativePath.padding(toLength: 28, withPad: " ", startingAt: 0)) slot? \(file.inferredSlot.map(String.init) ?? "-")  round-trip: \(file.roundTripsExactly ? "exact" : "DIFFERS")  decodes: \(file.decodes ? "yes" : "NO")")
        }
        if !backup.otherFiles.isEmpty { print("Other files (preserved): \(backup.otherFiles.joined(separator: ", "))") }
        for problem in backup.problems { print("problem: \(problem)") }
        print(backup.roundTripVerified ? "Backup verified: every pattern file round-trips byte-for-byte." : "Backup NOT verified — native export stays disabled.")
    case "read-slot":
        guard args.count == 3 else { fail(usage) }
        let backup = try T8BackupSet.load(from: URL(fileURLWithPath: args[0]))
        print(describe(try backup.pattern(rhythmFile: args[1], bassFile: args[2], name: "\(args[1]) / \(args[2])")))
    case "stage":
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let positional = args.filter { !$0.hasPrefix("--") }
        guard positional.count == 5 else { fail(usage) }
        let backup = try T8BackupSet.load(from: URL(fileURLWithPath: positional[0]))
        let preset = findPreset(positional[1])
        var options = TransferOptions()
        options.acknowledgedUnverifiedFormat = flags.contains("--i-understand-unverified")
        options.confirmedOverwrite = flags.contains("--overwrite")
        let staged = try HardwareTransferManager.stage(
            backup: backup,
            assignments: [TransferAssignment(pattern: preset.main, rhythmFile: positional[2], bassFile: positional[3])],
            options: options,
            outputDirectory: URL(fileURLWithPath: positional[4])
        )
        print("Staged restore set: \(staged.restoreDirectory.path)")
        print("Original backup copy: \(staged.originalBackupDirectory.path)")
        print(HardwareTransferManager.instructions(for: staged.manifest))
    case "verify":
        guard args.count == 2 else { fail(usage) }
        let transferDir = URL(fileURLWithPath: args[1])
        let manifest = try JSONCoding.decoder.decode(TransferManifest.self, from: Data(contentsOf: transferDir.appendingPathComponent("transfer-manifest.json")))
        let original = try T8BackupSet.load(from: transferDir.appendingPathComponent("ORIGINAL-BACKUP"))
        let after = try T8BackupSet.load(from: URL(fileURLWithPath: args[0]))
        let report = HardwareTransferManager.verify(postRestore: after, manifest: manifest, original: original)
        for slot in report.slots {
            print("\(slot.patternName): rhythm \(slot.rhythmMatches ? "OK" : "MISMATCH"), bass \(slot.bassMatches ? "OK" : "MISMATCH")")
            for d in slot.details { print("   \(d)") }
        }
        for u in report.unexpectedChanges { print("unexpected change: \(u)") }
        for m in report.missingFiles { print("missing: \(m)") }
        print(report.passed ? "VERIFIED: the T-8 holds exactly the staged data." : "NOT VERIFIED")
        exit(report.passed ? 0 : 2)
    case "matrix":
        for entry in HardwareCapabilities.matrix {
            print("[\(entry.level.label)] \(entry.feature)\n    source: \(entry.source)\(entry.notes.isEmpty ? "" : "\n    note: \(entry.notes)")")
        }
    default:
        print(usage)
        exit(1)
    }
} catch {
    fail("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
}

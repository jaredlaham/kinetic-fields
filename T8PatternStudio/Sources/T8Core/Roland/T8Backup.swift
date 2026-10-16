import Foundation

/// One `.prm` file inside a T-8 backup.
public struct T8BackupFile: Hashable, Sendable, Identifiable {
    public enum Part: String, Sendable, Codable { case rhythm, bass }

    public var id: String { "\(part.rawValue)/\(fileName)" }
    public var part: Part
    public var fileName: String
    public var originalData: Data
    public var document: PRMDocument
    /// Slot number inferred from digits in the file name (UNVERIFIED mapping).
    public var inferredSlot: Int?
    /// True when re-serializing the unmodified document reproduces the original bytes exactly.
    public var roundTripsExactly: Bool
    /// True when the content decodes with the T-8 codec for its part.
    public var decodes: Bool

    public var relativePath: String { "\(part == .rhythm ? "RHYTHM" : "BASS")/\(fileName)" }
}

/// A T-8 backup as copied from the unit's BACKUP folder (containing BASS and
/// RHYTHM subfolders, per the T-8 owner's manual).
public struct T8BackupSet: Sendable {
    public var rootURL: URL
    public var rhythmDirectoryName: String
    public var bassDirectoryName: String
    public var rhythm: [T8BackupFile]
    public var bass: [T8BackupFile]
    /// Files present in the backup that are not .prm pattern files (preserved verbatim when staging).
    public var otherFiles: [String]
    public var problems: [String]

    public enum LoadError: Error, LocalizedError, Equatable {
        case missingFolders(found: [String])
        case noPatternFiles

        public var errorDescription: String? {
            switch self {
            case .missingFolders(let found):
                "Expected BASS and RHYTHM folders (as created by the T-8 backup). Found: \(found.isEmpty ? "nothing" : found.joined(separator: ", "))."
            case .noPatternFiles: "No .prm files were found in the BASS and RHYTHM folders."
            }
        }
    }

    public var allFiles: [T8BackupFile] { rhythm + bass }

    /// Native export is only offered when every pattern file round-trips byte-for-byte.
    public var roundTripVerified: Bool {
        !allFiles.isEmpty && allFiles.allSatisfy { $0.roundTripsExactly && $0.decodes } && problems.isEmpty
    }

    public static func load(from root: URL) throws -> T8BackupSet {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        func directory(named name: String) -> String? {
            entries.first { $0.uppercased() == name && isDirectory(root.appendingPathComponent($0)) }
        }
        // Accept either the BACKUP folder itself or its parent (the T-8 volume root).
        if directory(named: "RHYTHM") == nil, directory(named: "BASS") == nil,
           let nested = entries.first(where: { $0.uppercased() == "BACKUP" }) {
            return try load(from: root.appendingPathComponent(nested))
        }
        guard let rhythmDir = directory(named: "RHYTHM"), let bassDir = directory(named: "BASS") else {
            throw LoadError.missingFolders(found: entries.sorted())
        }
        var problems: [String] = []
        var others: [String] = entries.filter { $0 != rhythmDir && $0 != bassDir && !$0.hasPrefix(".") }
        func loadFiles(_ dirName: String, part: T8BackupFile.Part) -> [T8BackupFile] {
            let dir = root.appendingPathComponent(dirName)
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            var files: [T8BackupFile] = []
            for name in names {
                let url = dir.appendingPathComponent(name)
                guard url.pathExtension.lowercased() == "prm" else {
                    others.append("\(dirName)/\(name)")
                    continue
                }
                guard let data = try? Data(contentsOf: url) else {
                    problems.append("\(dirName)/\(name): unreadable")
                    continue
                }
                do {
                    let document = try PRMDocument.parse(data)
                    let decodes: Bool
                    switch part {
                    case .rhythm: decodes = (try? T8RhythmCodec.decode(document)) != nil
                    case .bass: decodes = (try? T8BassCodec.decode(document)) != nil
                    }
                    if !decodes { problems.append("\(dirName)/\(name): not recognized as a T-8 \(part.rawValue) pattern") }
                    let exact = document.serialized() == data
                    if !exact { problems.append("\(dirName)/\(name): does not round-trip byte-for-byte") }
                    files.append(T8BackupFile(part: part, fileName: name, originalData: data, document: document,
                                              inferredSlot: inferSlot(name), roundTripsExactly: exact, decodes: decodes))
                } catch {
                    problems.append("\(dirName)/\(name): \(error.localizedDescription)")
                }
            }
            return files
        }
        let rhythm = loadFiles(rhythmDir, part: .rhythm)
        let bass = loadFiles(bassDir, part: .bass)
        guard !rhythm.isEmpty || !bass.isEmpty else { throw LoadError.noPatternFiles }
        return T8BackupSet(rootURL: root, rhythmDirectoryName: rhythmDir, bassDirectoryName: bassDir,
                           rhythm: rhythm, bass: bass, otherFiles: others.sorted(), problems: problems)
    }

    /// Takes the last run of digits in a file name, e.g. "PTN_07.PRM" → 7.
    static func inferSlot(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        var digits = ""
        var current = ""
        for c in stem {
            if c.isASCII && c.isNumber { current.append(c) } else if !current.isEmpty { digits = current; current = "" }
        }
        if !current.isEmpty { digits = current }
        return Int(digits)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func file(part: T8BackupFile.Part, named name: String) -> T8BackupFile? {
        (part == .rhythm ? rhythm : bass).first { $0.fileName == name }
    }

    /// Reads one slot back into the app's pattern model.
    public func pattern(rhythmFile: String?, bassFile: String?, name: String, mapping: T8BassNoteMapping = .assumed) throws -> Pattern {
        var pattern = Pattern(name: name)
        if let rhythmFile, let file = file(part: .rhythm, named: rhythmFile) {
            let decoded = try T8RhythmCodec.decode(file.document)
            pattern.drums = decoded.drums
            pattern.length = decoded.length
            pattern.swing = decoded.swing
        }
        if let bassFile, let file = file(part: .bass, named: bassFile) {
            let decoded = try T8BassCodec.decode(file.document, mapping: mapping)
            pattern.bass = decoded.bass
            if rhythmFile == nil { pattern.length = decoded.length }
        }
        return pattern
    }
}

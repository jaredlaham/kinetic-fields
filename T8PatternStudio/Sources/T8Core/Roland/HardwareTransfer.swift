import Foundation

/// One pattern going into one hardware slot.
public struct TransferAssignment: Hashable, Sendable, Codable {
    public var pattern: Pattern
    public var rhythmFile: String
    public var bassFile: String
    public init(pattern: Pattern, rhythmFile: String, bassFile: String) {
        self.pattern = pattern
        self.rhythmFile = rhythmFile
        self.bassFile = bassFile
    }
}

public struct TransferOptions: Hashable, Sendable, Codable {
    public var writeSwing = true
    public var bassMapping: T8BassNoteMapping = .assumed
    /// The user explicitly acknowledged that the format is not yet hardware-verified.
    public var acknowledgedUnverifiedFormat = false
    /// The user explicitly confirmed overwriting the target slots.
    public var confirmedOverwrite = false
    public init() {}
}

public struct TransferManifest: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var path: String
        public var originalChecksum: String
        public var stagedChecksum: String
        public var modified: Bool
    }

    public var createdAt: Date
    public var appSchemaVersion: Int
    public var sourceBackup: String
    public var originalBackupCopy: String
    public var assignments: [TransferAssignment]
    public var entries: [Entry]
    public var bassMapping: T8BassNoteMapping
}

public enum TransferError: Error, LocalizedError, Equatable {
    case backupNotVerified([String])
    case unverifiedFormatNotAcknowledged
    case overwriteNotConfirmed
    case fileNotInBackup(String)
    case duplicateTarget(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .backupNotVerified(let problems): "Native export is disabled because the backup did not pass verification:\n" + problems.joined(separator: "\n")
        case .unverifiedFormatNotAcknowledged: "Please acknowledge that the T-8 pattern format is not yet verified on hardware."
        case .overwriteNotConfirmed: "Please confirm that the target slots may be overwritten."
        case .fileNotInBackup(let name): "\(name) is not in the backup."
        case .duplicateTarget(let name): "\(name) is targeted by more than one pattern."
        case .validationFailed(let message): "The pattern is not valid for the T-8: \(message)"
        }
    }
}

public struct StagedTransfer: Sendable {
    /// Folder containing `BASS` and `RHYTHM` to copy into the T-8's RESTORE folder.
    public var restoreDirectory: URL
    /// Untouched copy of the original backup.
    public var originalBackupDirectory: URL
    public var manifestURL: URL
    public var manifest: TransferManifest
}

/// Prepares restore data for the T-8 using the documented backup/restore workflow:
///
/// 1. Back up the T-8 (power on holding [PLAY]; copy BACKUP/BASS and BACKUP/RHYTHM).
/// 2. Load that backup here. Every file must round-trip byte-for-byte.
/// 3. Stage: the original backup is copied untouched, then a complete RESTORE
///    set is written where only the chosen slots' step values differ.
/// 4. Copy the staged BASS and RHYTHM folders into the T-8's RESTORE folder,
///    eject, press [ACCENT]; the unit shows "dOnE".
/// 5. Verify: take a fresh backup and load it with `verify(...)`.
///
/// Nothing here can claim success on its own: copying files is not proof.
/// Only `verify` comparing a post-restore backup counts as verification.
public enum HardwareTransferManager {
    public static func stage(
        backup: T8BackupSet,
        assignments: [TransferAssignment],
        options: TransferOptions,
        outputDirectory: URL,
        now: Date = Date()
    ) throws -> StagedTransfer {
        guard backup.roundTripVerified else {
            throw TransferError.backupNotVerified(backup.problems.isEmpty ? ["The backup contains no verifiable pattern files."] : backup.problems)
        }
        guard options.acknowledgedUnverifiedFormat else { throw TransferError.unverifiedFormatNotAcknowledged }
        guard options.confirmedOverwrite else { throw TransferError.overwriteNotConfirmed }
        var seen = Set<String>()
        for assignment in assignments {
            for name in ["R:" + assignment.rhythmFile, "B:" + assignment.bassFile] where !seen.insert(name).inserted {
                throw TransferError.duplicateTarget(String(name.dropFirst(2)))
            }
            let issues = ValidationEngine.validateForHardware(assignment.pattern)
            if let error = issues.first(where: { $0.severity == .error }) { throw TransferError.validationFailed(error.description) }
            guard backup.file(part: .rhythm, named: assignment.rhythmFile) != nil else { throw TransferError.fileNotInBackup(assignment.rhythmFile) }
            guard backup.file(part: .bass, named: assignment.bassFile) != nil else { throw TransferError.fileNotInBackup(assignment.bassFile) }
        }

        let fm = FileManager.default
        let stamp = Self.stamp(now)
        let session = outputDirectory.appendingPathComponent("T8-Transfer-\(stamp)", isDirectory: true)
        let original = session.appendingPathComponent("ORIGINAL-BACKUP", isDirectory: true)
        let restore = session.appendingPathComponent("RESTORE", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        // 1. Untouched copy of the original backup.
        try fm.copyItem(at: backup.rootURL, to: original)

        // 2. Full restore set.
        let rhythmOut = restore.appendingPathComponent(backup.rhythmDirectoryName, isDirectory: true)
        let bassOut = restore.appendingPathComponent(backup.bassDirectoryName, isDirectory: true)
        try fm.createDirectory(at: rhythmOut, withIntermediateDirectories: true)
        try fm.createDirectory(at: bassOut, withIntermediateDirectories: true)

        var entries: [TransferManifest.Entry] = []
        for file in backup.rhythm {
            var data = file.originalData
            if let assignment = assignments.first(where: { $0.rhythmFile == file.fileName }) {
                var document = file.document
                try T8RhythmCodec.apply(assignment.pattern, to: &document, writeSwing: options.writeSwing)
                data = document.serialized()
            }
            try data.write(to: rhythmOut.appendingPathComponent(file.fileName), options: .atomic)
            entries.append(.init(path: file.relativePath, originalChecksum: Checksum.hex(file.originalData), stagedChecksum: Checksum.hex(data), modified: data != file.originalData))
        }
        for file in backup.bass {
            var data = file.originalData
            if let assignment = assignments.first(where: { $0.bassFile == file.fileName }) {
                var document = file.document
                try T8BassCodec.apply(assignment.pattern, to: &document, mapping: options.bassMapping)
                data = document.serialized()
            }
            try data.write(to: bassOut.appendingPathComponent(file.fileName), options: .atomic)
            entries.append(.init(path: file.relativePath, originalChecksum: Checksum.hex(file.originalData), stagedChecksum: Checksum.hex(data), modified: data != file.originalData))
        }

        let manifest = TransferManifest(
            createdAt: now,
            appSchemaVersion: UserLibraryDocument.currentSchemaVersion,
            sourceBackup: backup.rootURL.path,
            originalBackupCopy: original.path,
            assignments: assignments,
            entries: entries,
            bassMapping: options.bassMapping
        )
        let manifestURL = session.appendingPathComponent("transfer-manifest.json")
        try JSONCoding.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try instructions(for: manifest).write(to: session.appendingPathComponent("README-RESTORE.txt"), atomically: true, encoding: .utf8)
        return StagedTransfer(restoreDirectory: restore, originalBackupDirectory: original, manifestURL: manifestURL, manifest: manifest)
    }

    public static func instructions(for manifest: TransferManifest) -> String {
        let targets = manifest.assignments.map { "  • \($0.pattern.name) → RHYTHM/\($0.rhythmFile) + BASS/\($0.bassFile)" }.joined(separator: "\n")
        return """
        T-8 Pattern Studio — restore instructions
        =========================================
        Patterns staged:
        \(targets)

        Your untouched original backup is in ORIGINAL-BACKUP. Keep it.

        1. Turn the T-8 off. Connect it to the Mac with USB-C.
        2. Enter backup/restore mode as described in the T-8 owner's manual
           ("Backup and Factory Reset"); the T-8 appears as a USB drive.
        3. Copy the BASS and RHYTHM folders from the RESTORE folder here into
           the T-8 drive's RESTORE folder.
        4. Eject the drive in Finder, then press [ACCENT] on the T-8.
           Wait until the display shows "dOnE".
        5. Restart the T-8 and play the pattern(s).
        6. VERIFY: make a new backup and load it in T-8 Pattern Studio
           (Transfer ▸ Verify). Only this step confirms the transfer.

        If anything looks wrong, restore ORIGINAL-BACKUP the same way.
        The pattern file format is not yet verified on hardware: proceed only
        if you accept that risk.
        """
    }

    // MARK: Verification

    public struct VerificationReport: Sendable {
        public struct SlotResult: Sendable {
            public var patternName: String
            public var rhythmMatches: Bool
            public var bassMatches: Bool
            public var details: [String]
        }
        public var slots: [SlotResult]
        /// Files outside the targeted slots whose content changed.
        public var unexpectedChanges: [String]
        public var missingFiles: [String]

        public var passed: Bool {
            slots.allSatisfy { $0.rhythmMatches && $0.bassMatches } && unexpectedChanges.isEmpty && missingFiles.isEmpty
        }
    }

    /// Compares a backup taken AFTER restoring against the staged transfer.
    public static func verify(postRestore: T8BackupSet, manifest: TransferManifest, original: T8BackupSet) -> VerificationReport {
        var slots: [VerificationReport.SlotResult] = []
        for assignment in manifest.assignments {
            var details: [String] = []
            var rhythmOK = false, bassOK = false
            if let file = postRestore.file(part: .rhythm, named: assignment.rhythmFile), let decoded = try? T8RhythmCodec.decode(file.document) {
                let expected = assignment.pattern
                let mismatches = (0..<expected.length).filter { step in
                    DrumVoice.allCases.contains { decoded.drums[$0, step] != expected.drums[$0, step] } || decoded.drums.accents[step] != expected.drums.accents[step]
                }
                rhythmOK = mismatches.isEmpty && decoded.length == expected.length
                if !mismatches.isEmpty { details.append("Rhythm differs on steps \(mismatches.map { String($0 + 1) }.joined(separator: ", "))") }
                if decoded.length != expected.length { details.append("Length is \(decoded.length), expected \(expected.length)") }
            } else {
                details.append("RHYTHM/\(assignment.rhythmFile) missing or unreadable")
            }
            if let file = postRestore.file(part: .bass, named: assignment.bassFile), let decoded = try? T8BassCodec.decode(file.document, mapping: manifest.bassMapping) {
                let mismatches = (0..<assignment.pattern.length).filter { !T8BassCodec.equivalent(decoded.bass[$0], assignment.pattern.bass[$0]) }
                bassOK = mismatches.isEmpty
                if !mismatches.isEmpty { details.append("Bass differs on steps \(mismatches.map { String($0 + 1) }.joined(separator: ", "))") }
            } else {
                details.append("BASS/\(assignment.bassFile) missing or unreadable")
            }
            slots.append(.init(patternName: assignment.pattern.name, rhythmMatches: rhythmOK, bassMatches: bassOK, details: details))
        }

        let targeted = Set(manifest.assignments.flatMap { ["RHYTHM/\($0.rhythmFile)", "BASS/\($0.bassFile)"] })
        var unexpected: [String] = []
        var missing: [String] = []
        for file in original.allFiles where !targeted.contains(file.relativePath) {
            guard let after = postRestore.file(part: file.part, named: file.fileName) else {
                missing.append(file.relativePath)
                continue
            }
            if after.originalData != file.originalData {
                // Byte differences can be benign; compare decoded musical content.
                let same: Bool
                switch file.part {
                case .rhythm:
                    let a = try? T8RhythmCodec.decode(file.document), b = try? T8RhythmCodec.decode(after.document)
                    same = a?.drums == b?.drums && a?.length == b?.length
                case .bass:
                    let a = try? T8BassCodec.decode(file.document), b = try? T8BassCodec.decode(after.document)
                    same = a?.bass == b?.bass && a?.length == b?.length
                }
                if !same { unexpected.append(file.relativePath) }
            }
        }
        return VerificationReport(slots: slots, unexpectedChanges: unexpected, missingFiles: missing)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// FNV-1a 64-bit checksum, used to identify file versions in the manifest.
public enum Checksum {
    public static func hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

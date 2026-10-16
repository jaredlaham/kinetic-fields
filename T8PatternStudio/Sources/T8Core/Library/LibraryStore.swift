import Foundation

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Foundation reference-date seconds: lossless, so saved presets compare equal after reload.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

public enum LibraryStoreError: Error, LocalizedError, Equatable {
    case unrecognizedFile
    case newerSchema(found: Int, supported: Int)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFile: "This file is not a T-8 Pattern Studio preset file."
        case .newerSchema(let found, let supported):
            "This library was written by a newer version of T-8 Pattern Studio (schema \(found); this version supports \(supported)). It was left untouched."
        case .corrupt(let detail): "The preset library could not be read: \(detail)"
        }
    }
}

/// Schema migrations, applied to raw JSON before decoding.
///
/// Schema history:
///  - v1: pre-release draft. Each preset had a single `genre` string and a
///        `favorite` flag; there was no `favoriteIDs` list.
///  - v2: current. `genres` array; favorites stored in `favoriteIDs`.
public enum LibraryMigrator {
    public static func migrate(_ data: Data) throws -> (data: Data, fromVersion: Int) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryStoreError.corrupt("Top level is not an object")
        }
        let original = root["schemaVersion"] as? Int ?? 1
        if original > UserLibraryDocument.currentSchemaVersion {
            throw LibraryStoreError.newerSchema(found: original, supported: UserLibraryDocument.currentSchemaVersion)
        }
        var version = original
        while version < UserLibraryDocument.currentSchemaVersion {
            switch version {
            case 1: root = migrateV1toV2(root)
            default: throw LibraryStoreError.corrupt("No migration from schema \(version)")
            }
            version += 1
            root["schemaVersion"] = version
        }
        return (try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), original)
    }

    static func migrateBundle(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryStoreError.unrecognizedFile
        }
        if (root["schemaVersion"] as? Int ?? 1) == 1, let presets = root["presets"] as? [[String: Any]] {
            root["presets"] = presets.map { migratePresetV1toV2($0).preset }
            root["schemaVersion"] = 2
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func migrateV1toV2(_ v1: [String: Any]) -> [String: Any] {
        var root = v1
        var favorites = root["favoriteIDs"] as? [String] ?? []
        let presets = (root["presets"] as? [[String: Any]] ?? []).map { raw -> [String: Any] in
            let (preset, favorite) = migratePresetV1toV2(raw)
            if favorite, let id = preset["id"] as? String { favorites.append(id) }
            return preset
        }
        root["presets"] = presets
        root["favoriteIDs"] = favorites
        root["folders"] = root["folders"] ?? []
        root["recentIDs"] = root["recentIDs"] ?? []
        return root
    }

    static func migratePresetV1toV2(_ raw: [String: Any]) -> (preset: [String: Any], favorite: Bool) {
        var preset = raw
        if let genre = preset.removeValue(forKey: "genre") as? String {
            preset["genres"] = Genre(rawValue: genre).map { [$0.rawValue] } ?? Genre(displayName: genre).map { [$0.rawValue] } ?? []
        }
        let favorite = preset.removeValue(forKey: "favorite") as? Bool ?? false
        return (preset, favorite)
    }
}

/// Persists the user library in Application Support:
///
///     <root>/library.json            current user library (schema in UserLibraryDocument)
///     <root>/Backups/library-*.json  automatic rolling backups
///
/// Writes are atomic. A backup is taken once per launch before the first write
/// and before any schema migration. Unreadable files are never overwritten;
/// they are preserved as `library.corrupt-*.json`.
public final class LibraryStore: @unchecked Sendable {
    public static let maxBackups = 20
    public let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var backedUpThisSession = false

    public var libraryURL: URL { directory.appendingPathComponent("library.json") }
    public var backupDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/T8PatternStudio` (or the XDG equivalent on Linux).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".t8patternstudio")
        return base.appendingPathComponent("T8PatternStudio", isDirectory: true)
    }

    public struct LoadResult: Sendable {
        public var document: UserLibraryDocument
        public var migratedFrom: Int?
        public var recoveredFromCorruption: Bool
    }

    public func load() throws -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return LoadResult(document: UserLibraryDocument(), migratedFrom: nil, recoveredFromCorruption: false)
        }
        let data = try Data(contentsOf: libraryURL)
        do {
            let (migrated, fromVersion) = try LibraryMigrator.migrate(data)
            let document = try JSONCoding.decoder.decode(UserLibraryDocument.self, from: migrated)
            if fromVersion != UserLibraryDocument.currentSchemaVersion {
                try backupLocked(data: data, label: "pre-migration-v\(fromVersion)")
                try write(document)
                return LoadResult(document: document, migratedFrom: fromVersion, recoveredFromCorruption: false)
            }
            return LoadResult(document: document, migratedFrom: nil, recoveredFromCorruption: false)
        } catch LibraryStoreError.newerSchema(let found, let supported) {
            // Never touch a library written by a newer app version.
            throw LibraryStoreError.newerSchema(found: found, supported: supported)
        } catch {
            // Keep the unreadable file, then fall back to the most recent readable backup.
            let stamp = Self.timestamp()
            try? fileManager.copyItem(at: libraryURL, to: directory.appendingPathComponent("library.corrupt-\(stamp).json"))
            for backup in backups() {
                if let backupData = try? Data(contentsOf: backup),
                   let (migrated, _) = try? LibraryMigrator.migrate(backupData),
                   let document = try? JSONCoding.decoder.decode(UserLibraryDocument.self, from: migrated) {
                    try write(document)
                    return LoadResult(document: document, migratedFrom: nil, recoveredFromCorruption: true)
                }
            }
            throw LibraryStoreError.corrupt(String(describing: error))
        }
    }

    public func save(_ document: UserLibraryDocument) throws {
        lock.lock(); defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !backedUpThisSession, fileManager.fileExists(atPath: libraryURL.path) {
            try backupLocked(data: try Data(contentsOf: libraryURL), label: "session")
            backedUpThisSession = true
        }
        try write(document)
    }

    /// Backups, newest first.
    public func backups() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func write(_ document: UserLibraryDocument) throws {
        var doc = document
        doc.schemaVersion = UserLibraryDocument.currentSchemaVersion
        let data = try JSONCoding.encoder.encode(doc)
        try data.write(to: libraryURL, options: .atomic)
    }

    private func backupLocked(data: Data, label: String) throws {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        var url = backupDirectory.appendingPathComponent("library-\(Self.timestamp())-\(label).json")
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            url = backupDirectory.appendingPathComponent("library-\(Self.timestamp())-\(label)-\(counter).json")
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        let all = backups()
        if all.count > Self.maxBackups {
            for old in all.suffix(from: Self.maxBackups) { try? fileManager.removeItem(at: old) }
        }
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

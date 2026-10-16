import Foundation

/// Reads and writes `.kineticstem` project packages.
///
/// A project is a folder (a macOS package) containing:
///   project.json   the versioned project document (schema in docs/PROJECT-FORMAT.md)
///   cache/         waveform peaks keyed by audio hash (safe to delete)
/// Audio files are referenced, never copied or modified.
public enum ProjectStore {
    public static let fileExtension = "kineticstem"
    public static let documentName = "project.json"

    public enum StoreError: LocalizedError, Equatable {
        case newerSchema(Int)
        case unreadable(String)
        case notAProject

        public var errorDescription: String? {
            switch self {
            case .newerSchema(let v): "This project was saved by a newer version of Kinetic Stem Studio (schema \(v)). Update the app to open it; it was not modified."
            case .unreadable(let why): "The project file could not be read: \(why)"
            case .notAProject: "This folder is not a Kinetic Stem Studio project."
            }
        }
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes the project atomically: a crash mid-save leaves the previous version intact.
    public static func save(_ project: Project, to package: URL) throws {
        var project = project
        project.schemaVersion = Project.currentSchemaVersion
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("cache"), withIntermediateDirectories: true)
        let parent = package.deletingLastPathComponent().standardizedFileURL.path
        for i in project.stems.indices {
            project.stems[i].file.relativePath = relativePath(from: parent, to: project.stems[i].file.path)
        }
        let data = try encoder().encode(project)
        try data.write(to: package.appendingPathComponent(documentName), options: .atomic)
    }

    public static func load(from package: URL) throws -> Project {
        let doc = package.appendingPathComponent(documentName)
        guard FileManager.default.fileExists(atPath: doc.path) else { throw StoreError.notAProject }
        let data: Data
        do { data = try Data(contentsOf: doc) } catch { throw StoreError.unreadable(error.localizedDescription) }
        var project = try migrate(data)
        // Re-find audio that moved together with the project.
        let parent = package.deletingLastPathComponent()
        for i in project.stems.indices {
            let ref = project.stems[i].file
            if !FileManager.default.fileExists(atPath: ref.path), let rel = ref.relativePath {
                let candidate = parent.appendingPathComponent(rel).standardizedFileURL.path
                if FileManager.default.fileExists(atPath: candidate) { project.stems[i].file.path = candidate }
            }
        }
        return project
    }

    /// Upgrades older documents step by step to the current schema.
    public static func migrate(_ data: Data) throws -> Project {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.unreadable("not a JSON object")
        }
        let version = object["schemaVersion"] as? Int ?? 0
        if version > Project.currentSchemaVersion { throw StoreError.newerSchema(version) }
        var json = object
        if version < 1 {
            // Pre-release documents (schema 0) had no export/t8/quantize blocks; defaults fill them.
            json["schemaVersion"] = 1
            if json["quantize"] == nil { json["quantize"] = [String: Any]() }
            if json["export"] == nil { json["export"] = [String: Any]() }
            if json["t8"] == nil { json["t8"] = [String: Any]() }
        }
        // Future: if version < 2 { ... }
        let upgraded = try JSONSerialization.data(withJSONObject: json)
        do {
            return try decoder().decode(Project.self, from: upgraded)
        } catch {
            throw StoreError.unreadable(String(describing: error))
        }
    }

    static func relativePath(from base: String, to target: String) -> String? {
        let b = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let t = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
        var i = 0
        while i < min(b.count, t.count) && b[i] == t[i] { i += 1 }
        guard i > 0 else { return nil }
        let ups = Array(repeating: "..", count: b.count - i)
        return (ups + t[i...]).joined(separator: "/")
    }
}

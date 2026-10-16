import Foundation

public enum LibraryError: Error, Equatable, LocalizedError {
    case factoryPresetIsReadOnly(PresetID)
    case presetNotFound(PresetID)
    case folderNotFound(FolderID)
    case duplicateName(String)
    case invalidName
    case revisionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .factoryPresetIsReadOnly: "Factory presets are read-only. Use Save As to keep your changes."
        case .presetNotFound: "That preset no longer exists."
        case .folderNotFound: "That folder no longer exists."
        case .duplicateName(let name): "A preset named \"\(name)\" already exists."
        case .invalidName: "Please enter a name."
        case .revisionNotFound: "That saved version is no longer available."
        }
    }
}

/// Library sections shown in the Preset Library menu.
public enum LibraryCategory: Hashable, Sendable {
    case all
    case recent
    case favorites
    case factory
    case factoryGenre(Genre)
    case mine
    case folder(FolderID)
    case unfiled
    case recentlySaved
}

public enum PresetSort: String, CaseIterable, Sendable {
    case name, bpm, energy, modified, genre

    public var displayName: String {
        switch self {
        case .name: "Name"
        case .bpm: "BPM"
        case .energy: "Energy"
        case .modified: "Date Modified"
        case .genre: "Genre"
        }
    }
}

public struct PresetFilter: Hashable, Sendable {
    public var searchText: String = ""
    public var genres: Set<Genre> = []
    public var bpmRange: ClosedRange<Double>? = nil
    public var minimumEnergy: Int? = nil
    public var favoritesOnly = false
    public var tag: String? = nil
    public init(searchText: String = "", genres: Set<Genre> = [], bpmRange: ClosedRange<Double>? = nil, minimumEnergy: Int? = nil, favoritesOnly: Bool = false, tag: String? = nil) {
        self.searchText = searchText
        self.genres = genres
        self.bpmRange = bpmRange
        self.minimumEnergy = minimumEnergy
        self.favoritesOnly = favoritesOnly
        self.tag = tag
    }
}

/// Metadata entered in the Save Preset dialog.
public struct PresetMetadata: Hashable, Sendable {
    public var name: String
    public var genres: [Genre]
    public var folderID: FolderID?
    public var tags: [String]
    public var summary: String
    public var notes: String
    public var energy: Int
    public var favorite: Bool

    public init(name: String, genres: [Genre] = [], folderID: FolderID? = nil, tags: [String] = [], summary: String = "", notes: String = "", energy: Int = 3, favorite: Bool = false) {
        self.name = name
        self.genres = genres
        self.folderID = folderID
        self.tags = tags
        self.summary = summary
        self.notes = notes
        self.energy = energy
        self.favorite = favorite
    }
}

/// The persisted user portion of the library (factory presets are never stored here).
public struct UserLibraryDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var presets: [Preset]
    public var folders: [LibraryFolder]
    public var favoriteIDs: [PresetID]
    public var recentIDs: [PresetID]

    public init(schemaVersion: Int = UserLibraryDocument.currentSchemaVersion, presets: [Preset] = [], folders: [LibraryFolder] = [], favoriteIDs: [PresetID] = [], recentIDs: [PresetID] = []) {
        self.schemaVersion = schemaVersion
        self.presets = presets
        self.folders = folders
        self.favoriteIDs = favoriteIDs
        self.recentIDs = recentIDs
    }
}

/// Factory + user presets with all library operations. A value type so it is
/// trivially testable; the app wraps it in an observable store that persists
/// after each mutation.
public struct PresetLibrary: Sendable {
    public static let recentLimit = 25

    public private(set) var factory: [Preset]
    public private(set) var document: UserLibraryDocument

    public init(factory: [Preset] = FactoryLibrary.presets, document: UserLibraryDocument = UserLibraryDocument()) {
        self.factory = factory
        self.document = document
    }

    // MARK: Queries

    public var userPresets: [Preset] { document.presets }
    public var folders: [LibraryFolder] { document.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    public var allPresets: [Preset] { factory + document.presets }

    public func preset(_ id: PresetID) -> Preset? {
        document.presets.first { $0.id == id } ?? factory.first { $0.id == id }
    }

    public func isFavorite(_ id: PresetID) -> Bool { document.favoriteIDs.contains(id) }

    public func presets(in category: LibraryCategory) -> [Preset] {
        switch category {
        case .all: return allPresets
        case .recent: return document.recentIDs.compactMap { preset($0) }
        case .favorites: return document.favoriteIDs.compactMap { preset($0) }
        case .factory: return factory
        case .factoryGenre(let genre): return factory.filter { $0.primaryGenre == genre }
        case .mine: return document.presets
        case .folder(let id): return document.presets.filter { $0.folderID == id }
        case .unfiled: return document.presets.filter { $0.folderID == nil }
        case .recentlySaved: return document.presets.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(20).map { $0 }
        }
    }

    public func search(_ category: LibraryCategory = .all, filter: PresetFilter = PresetFilter(), sort: PresetSort = .name, ascending: Bool = true) -> [Preset] {
        let terms = filter.searchText.lowercased().split(separator: " ").map(String.init)
        var results = presets(in: category).filter { preset in
            if filter.favoritesOnly && !isFavorite(preset.id) { return false }
            if !filter.genres.isEmpty && filter.genres.isDisjoint(with: preset.genres) { return false }
            if let range = filter.bpmRange, !range.contains(preset.main.bpm) { return false }
            if let minimum = filter.minimumEnergy, preset.energy < minimum { return false }
            if let tag = filter.tag, !preset.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
            guard !terms.isEmpty else { return true }
            let haystack = ([preset.name, preset.summary, preset.notes, preset.main.key.name, preset.main.scale.displayName]
                + preset.tags + preset.genres.map(\.displayName)).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        // Category orders (recent, favorites) are meaningful; only re-sort when asked to.
        let keepOrder = category == .recent || category == .recentlySaved
        if !keepOrder {
            results.sort { lhs, rhs in
                let ordered: Bool
                switch sort {
                case .name: ordered = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                case .bpm: ordered = lhs.main.bpm == rhs.main.bpm ? lhs.name < rhs.name : lhs.main.bpm < rhs.main.bpm
                case .energy: ordered = lhs.energy == rhs.energy ? lhs.name < rhs.name : lhs.energy < rhs.energy
                case .modified: ordered = lhs.modifiedAt < rhs.modifiedAt
                case .genre:
                    let l = lhs.primaryGenre?.displayName ?? "", r = rhs.primaryGenre?.displayName ?? ""
                    ordered = l == r ? lhs.name < rhs.name : l < r
                }
                return ascending ? ordered : !ordered
            }
        }
        return results
    }

    public var allTags: [String] {
        Array(Set(allPresets.flatMap(\.tags))).sorted()
    }

    // MARK: Saving

    /// Saves the given content as a brand-new user preset ("Save Preset As" / "New Preset").
    @discardableResult
    public mutating func saveNew(variations: PatternVariations, metadata: PresetMetadata, now: Date = Date()) throws -> Preset {
        let name = try validatedName(metadata.name)
        if let folder = metadata.folderID, !document.folders.contains(where: { $0.id == folder }) {
            throw LibraryError.folderNotFound(folder)
        }
        let preset = Preset(
            id: .newUser(),
            name: name,
            origin: .user,
            genres: metadata.genres,
            folderID: metadata.folderID,
            tags: normalizedTags(metadata.tags),
            summary: metadata.summary,
            notes: metadata.notes,
            energy: min(max(metadata.energy, 1), 5),
            variations: variations,
            createdAt: now,
            modifiedAt: now
        )
        document.presets.append(preset)
        if metadata.favorite { document.favoriteIDs.append(preset.id) }
        return preset
    }

    /// Overwrites the musical content of an existing user preset ("Save Preset").
    /// The previous content is kept as a revision.
    @discardableResult
    public mutating func update(_ id: PresetID, variations: PatternVariations, now: Date = Date()) throws -> Preset {
        let index = try userIndex(id)
        var preset = document.presets[index]
        guard preset.variations != variations else { return preset }
        preset.revisions.insert(PresetRevision(savedAt: preset.modifiedAt, name: preset.name, variations: preset.variations), at: 0)
        if preset.revisions.count > Preset.maxRevisions { preset.revisions.removeLast(preset.revisions.count - Preset.maxRevisions) }
        preset.variations = variations
        preset.modifiedAt = now
        document.presets[index] = preset
        return preset
    }

    public mutating func updateMetadata(_ id: PresetID, metadata: PresetMetadata, now: Date = Date()) throws {
        let index = try userIndex(id)
        let name = try validatedName(metadata.name)
        if let folder = metadata.folderID, !document.folders.contains(where: { $0.id == folder }) {
            throw LibraryError.folderNotFound(folder)
        }
        document.presets[index].name = name
        document.presets[index].genres = metadata.genres
        document.presets[index].folderID = metadata.folderID
        document.presets[index].tags = normalizedTags(metadata.tags)
        document.presets[index].summary = metadata.summary
        document.presets[index].notes = metadata.notes
        document.presets[index].energy = min(max(metadata.energy, 1), 5)
        document.presets[index].modifiedAt = now
        setFavorite(id, metadata.favorite)
    }

    public mutating func rename(_ id: PresetID, to newName: String, now: Date = Date()) throws {
        let index = try userIndex(id)
        document.presets[index].name = try validatedName(newName)
        document.presets[index].modifiedAt = now
    }

    /// Duplicates any preset (factory or user) into a new user preset.
    @discardableResult
    public mutating func duplicate(_ id: PresetID, now: Date = Date()) throws -> Preset {
        guard let source = preset(id) else { throw LibraryError.presetNotFound(id) }
        var copy = source
        copy.id = .newUser()
        copy.origin = .user
        copy.name = uniqueName(base: source.name + " Copy")
        copy.revisions = []
        copy.createdAt = now
        copy.modifiedAt = now
        if source.isFactory { copy.folderID = nil }
        document.presets.append(copy)
        return copy
    }

    public mutating func delete(_ id: PresetID) throws {
        let index = try userIndex(id)
        document.presets.remove(at: index)
        document.favoriteIDs.removeAll { $0 == id }
        document.recentIDs.removeAll { $0 == id }
    }

    public func revisions(of id: PresetID) -> [PresetRevision] { preset(id)?.revisions ?? [] }

    /// Restores a previous version. The current content becomes a revision itself, so restoring is undoable.
    @discardableResult
    public mutating func restoreRevision(_ revisionID: UUID, of id: PresetID, now: Date = Date()) throws -> Preset {
        let index = try userIndex(id)
        guard let revision = document.presets[index].revisions.first(where: { $0.id == revisionID }) else {
            throw LibraryError.revisionNotFound(revisionID)
        }
        return try update(id, variations: revision.variations, now: now)
    }

    // MARK: Favorites & recents

    public mutating func toggleFavorite(_ id: PresetID) {
        setFavorite(id, !isFavorite(id))
    }

    public mutating func setFavorite(_ id: PresetID, _ favorite: Bool) {
        document.favoriteIDs.removeAll { $0 == id }
        if favorite, preset(id) != nil { document.favoriteIDs.append(id) }
    }

    public mutating func markRecent(_ id: PresetID) {
        document.recentIDs.removeAll { $0 == id }
        document.recentIDs.insert(id, at: 0)
        if document.recentIDs.count > Self.recentLimit { document.recentIDs.removeLast(document.recentIDs.count - Self.recentLimit) }
    }

    // MARK: Folders

    @discardableResult
    public mutating func createFolder(named name: String, parent: FolderID? = nil, now: Date = Date()) throws -> LibraryFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidName }
        if let parent, !document.folders.contains(where: { $0.id == parent }) { throw LibraryError.folderNotFound(parent) }
        let folder = LibraryFolder(name: trimmed, parentID: parent, createdAt: now)
        document.folders.append(folder)
        return folder
    }

    public mutating func renameFolder(_ id: FolderID, to name: String) throws {
        guard let index = document.folders.firstIndex(where: { $0.id == id }) else { throw LibraryError.folderNotFound(id) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidName }
        document.folders[index].name = trimmed
    }

    /// Deletes a folder. Presets inside are kept and moved to the parent folder (or unfiled).
    public mutating func deleteFolder(_ id: FolderID) throws {
        guard let folder = document.folders.first(where: { $0.id == id }) else { throw LibraryError.folderNotFound(id) }
        for index in document.presets.indices where document.presets[index].folderID == id {
            document.presets[index].folderID = folder.parentID
        }
        for index in document.folders.indices where document.folders[index].parentID == id {
            document.folders[index].parentID = folder.parentID
        }
        document.folders.removeAll { $0.id == id }
    }

    public mutating func move(_ id: PresetID, to folder: FolderID?) throws {
        let index = try userIndex(id)
        if let folder, !document.folders.contains(where: { $0.id == folder }) { throw LibraryError.folderNotFound(folder) }
        document.presets[index].folderID = folder
    }

    // MARK: Import / export

    /// Imports presets from a bundle. Imported presets always become user
    /// presets; conflicting IDs get fresh IDs so nothing is overwritten.
    @discardableResult
    public mutating func importPresets(_ bundle: PresetBundle, now: Date = Date()) -> [Preset] {
        var imported: [Preset] = []
        for var preset in bundle.presets {
            if preset.isFactory || self.preset(preset.id) != nil { preset.id = .newUser() }
            preset.origin = .user
            preset.folderID = nil
            preset.name = uniqueName(base: preset.name)
            preset.modifiedAt = now
            document.presets.append(preset)
            imported.append(preset)
        }
        return imported
    }

    public func exportBundle(_ ids: [PresetID]) -> PresetBundle {
        PresetBundle(presets: ids.compactMap { preset($0) })
    }

    // MARK: Helpers

    public func uniqueName(base: String) -> String {
        let names = Set(document.presets.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var counter = 2
        while names.contains("\(base) \(counter)".lowercased()) { counter += 1 }
        return "\(base) \(counter)"
    }

    public func userPreset(named name: String) -> Preset? {
        document.presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func userIndex(_ id: PresetID) throws -> Int {
        if let index = document.presets.firstIndex(where: { $0.id == id }) { return index }
        if factory.contains(where: { $0.id == id }) { throw LibraryError.factoryPresetIsReadOnly(id) }
        throw LibraryError.presetNotFound(id)
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidName }
        return trimmed
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Portable preset exchange file (`.t8presets`, JSON).
public struct PresetBundle: Codable, Hashable, Sendable {
    public static let fileExtension = "t8presets"
    public static let formatIdentifier = "com.t8patternstudio.presets"

    public var format: String
    public var schemaVersion: Int
    public var exportedAt: Date
    public var presets: [Preset]

    public init(presets: [Preset], exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        schemaVersion = UserLibraryDocument.currentSchemaVersion
        self.exportedAt = exportedAt
        self.presets = presets
    }

    public func encoded() throws -> Data {
        try JSONCoding.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PresetBundle {
        let migrated = try LibraryMigrator.migrateBundle(data)
        let bundle = try JSONCoding.decoder.decode(PresetBundle.self, from: migrated)
        guard bundle.format == formatIdentifier else { throw LibraryStoreError.unrecognizedFile }
        return bundle
    }
}

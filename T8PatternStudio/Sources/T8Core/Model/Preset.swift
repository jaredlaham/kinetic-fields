import Foundation

public enum Genre: String, Codable, CaseIterable, Sendable, Identifiable {
    case house, deepHouse, progressiveHouse, techHouse, breakbeat, lofiHipHop, tripHop, ambient,
         techno, acidTechno, frenchElectro, synthwave, downtempo, electroFunk, ukGarage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .house: "House"
        case .deepHouse: "Deep House"
        case .progressiveHouse: "Progressive House"
        case .techHouse: "Tech House"
        case .breakbeat: "Breakbeat"
        case .lofiHipHop: "Lo-Fi Hip-Hop"
        case .tripHop: "Trip-Hop"
        case .ambient: "Ambient"
        case .techno: "Techno"
        case .acidTechno: "Acid Techno"
        case .frenchElectro: "French Electro"
        case .synthwave: "Synthwave"
        case .downtempo: "Downtempo"
        case .electroFunk: "Electro Funk"
        case .ukGarage: "UK Garage"
        }
    }

    public init?(displayName: String) {
        let needle = displayName.lowercased().filter { $0.isLetter }
        guard let match = Genre.allCases.first(where: {
            $0.displayName.lowercased().filter { $0.isLetter } == needle || $0.rawValue.lowercased() == needle
        }) else { return nil }
        self = match
    }
}

/// Stable preset identifier. Factory presets use readable dotted IDs
/// ("factory.house.classic-four"); user presets use UUID strings.
public struct PresetID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible, Comparable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func newUser() -> PresetID { PresetID("user.\(UUID().uuidString.lowercased())") }
    public var description: String { rawValue }
    public var isFactory: Bool { rawValue.hasPrefix("factory.") }
    public static func < (lhs: PresetID, rhs: PresetID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct FolderID: Hashable, Codable, Sendable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> FolderID { FolderID(rawValue: "folder.\(UUID().uuidString.lowercased())") }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PresetOrigin: String, Codable, Sendable {
    case factory, user
}

/// A saved snapshot of a preset's musical content, kept for "restore previous version".
public struct PresetRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var savedAt: Date
    public var name: String
    public var variations: PatternVariations

    public init(id: UUID = UUID(), savedAt: Date, name: String, variations: PatternVariations) {
        self.id = id
        self.savedAt = savedAt
        self.name = name
        self.variations = variations
    }
}

public struct Preset: Codable, Hashable, Sendable, Identifiable {
    public static let maxRevisions = 20

    public var id: PresetID
    public var name: String
    public var origin: PresetOrigin
    public var genres: [Genre]
    public var folderID: FolderID?
    public var tags: [String]
    public var summary: String
    public var notes: String
    /// 1 (calm) ... 5 (peak time).
    public var energy: Int
    public var variations: PatternVariations
    public var createdAt: Date
    public var modifiedAt: Date
    public var revisions: [PresetRevision]

    public init(
        id: PresetID,
        name: String,
        origin: PresetOrigin,
        genres: [Genre],
        folderID: FolderID? = nil,
        tags: [String] = [],
        summary: String = "",
        notes: String = "",
        energy: Int = 3,
        variations: PatternVariations,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        revisions: [PresetRevision] = []
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.genres = genres
        self.folderID = folderID
        self.tags = tags
        self.summary = summary
        self.notes = notes
        self.energy = energy
        self.variations = variations
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revisions = revisions
    }

    /// Foundation (A) pattern; drives list display of BPM / key / length.
    public var main: Pattern { variations.a }
    public var primaryGenre: Genre? { genres.first }
    public var isFactory: Bool { origin == .factory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PresetID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        origin = try c.decodeIfPresent(PresetOrigin.self, forKey: .origin) ?? .user
        genres = try c.decodeIfPresent([Genre].self, forKey: .genres) ?? []
        folderID = try c.decodeIfPresent(FolderID.self, forKey: .folderID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        energy = try c.decodeIfPresent(Int.self, forKey: .energy) ?? 3
        variations = try c.decode(PatternVariations.self, forKey: .variations)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        revisions = try c.decodeIfPresent([PresetRevision].self, forKey: .revisions) ?? []
    }
}

public struct LibraryFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: FolderID
    public var name: String
    public var parentID: FolderID?
    public var createdAt: Date

    public init(id: FolderID = .new(), name: String, parentID: FolderID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

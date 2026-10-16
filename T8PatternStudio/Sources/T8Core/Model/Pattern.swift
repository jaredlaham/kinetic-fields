import Foundation

// MARK: - Indexing convention
//
// All step indices in the internal model are ZERO-BASED (step 1 on the hardware
// is index 0). Roland .PRM files are one-based ("STEP 1 = ..."); conversion
// happens only inside the Roland backup layer.

/// The six T-8 drum instruments, in panel order.
public enum DrumVoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case kick, snare, clap, tom, closedHat, openHat

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .clap: "Clap"
        case .tom: "Tom"
        case .closedHat: "Closed Hi-Hat"
        case .openHat: "Open Hi-Hat"
        }
    }

    public var shortName: String {
        switch self {
        case .kick: "BD"
        case .snare: "SD"
        case .clap: "CP"
        case .tom: "TM"
        case .closedHat: "CH"
        case .openHat: "OH"
        }
    }
}

/// T-8 per-step sub-step (ratchet) options.
public enum SubStep: String, Codable, CaseIterable, Sendable {
    case none, x2, x3, x4, flam

    /// Number of evenly-spaced triggers within the step.
    public var hitCount: Int {
        switch self {
        case .none: 1
        case .x2, .flam: 2
        case .x3: 3
        case .x4: 4
        }
    }

    public var label: String {
        switch self {
        case .none: ""
        case .x2: "×2"
        case .x3: "×3"
        case .x4: "×4"
        case .flam: "F"
        }
    }
}

/// A single active drum step.
public struct DrumHit: Codable, Hashable, Sendable {
    /// Hardware velocity scale 0...10 (T-8 default 7).
    public var velocity: Int
    public var subStep: SubStep
    /// Trigger probability in percent, multiples of 10 (0...100).
    public var probability: Int
    /// Sub-step probability in percent, multiples of 10 (0...100).
    public var subStepProbability: Int

    public static let defaultVelocity = 7
    public static let velocityRange = 0...10

    public init(velocity: Int = DrumHit.defaultVelocity, subStep: SubStep = .none, probability: Int = 100, subStepProbability: Int = 100) {
        self.velocity = velocity
        self.subStep = subStep
        self.probability = probability
        self.subStepProbability = subStepProbability
    }

    public static let normal = DrumHit()
    public static let loud = DrumHit(velocity: 10)
    public static let soft = DrumHit(velocity: 4)
}

/// Six lanes of 32 optional hits plus the T-8 global accent row.
public struct DrumPattern: Codable, Hashable, Sendable {
    public var lanes: [DrumVoice: [DrumHit?]]
    public var accents: [Bool]

    public init() {
        lanes = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map { ($0, Array(repeating: nil, count: Pattern.maxSteps)) })
        accents = Array(repeating: false, count: Pattern.maxSteps)
    }

    public subscript(voice: DrumVoice, step: Int) -> DrumHit? {
        get { lanes[voice]?[step] ?? nil }
        set {
            var lane = lanes[voice] ?? Array(repeating: nil, count: Pattern.maxSteps)
            lane[step] = newValue
            lanes[voice] = lane
        }
    }

    public func lane(_ voice: DrumVoice) -> [DrumHit?] {
        lanes[voice] ?? Array(repeating: nil, count: Pattern.maxSteps)
    }

    public func hitCount(length: Int = Pattern.maxSteps) -> Int {
        DrumVoice.allCases.reduce(0) { total, voice in
            total + lane(voice).prefix(length).compactMap { $0 }.count
        }
    }

    public var isEmpty: Bool { hitCount() == 0 && !accents.contains(true) }

    // Encode lanes as an ordered keyed object so JSON is stable and readable.
    private enum CodingKeys: String, CodingKey { case lanes, accents }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: [DrumHit?]].self, forKey: .lanes)
        for (key, value) in raw {
            guard let voice = DrumVoice(rawValue: key) else { continue } // ignore unknown voices
            lanes[voice] = Pattern.normalized(value, fill: nil)
        }
        accents = Pattern.normalized(try container.decodeIfPresent([Bool].self, forKey: .accents) ?? [], fill: false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: [DrumHit?]] = [:]
        for voice in DrumVoice.allCases { raw[voice.rawValue] = lane(voice) }
        try container.encode(raw, forKey: .lanes)
        try container.encode(accents, forKey: .accents)
    }
}

/// TB-303 style bass step.
public struct BassStep: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Silence.
        case rest
        /// A new note is triggered.
        case note
        /// The previous note is held through this step.
        case tie
    }

    public var kind: Kind
    /// MIDI note number (C4 = 60). Ignored for rests; for ties it mirrors the held note.
    public var note: Int
    public var accent: Bool
    /// Glide from this note into the next note.
    public var slide: Bool

    public init(kind: Kind = .rest, note: Int = 36, accent: Bool = false, slide: Bool = false) {
        self.kind = kind
        self.note = note
        self.accent = accent
        self.slide = slide
    }

    public static let rest = BassStep()
    public static func note(_ note: Int, accent: Bool = false, slide: Bool = false) -> BassStep {
        BassStep(kind: .note, note: note, accent: accent, slide: slide)
    }

    public var isSounding: Bool { kind != .rest }
}

public struct BassPattern: Codable, Hashable, Sendable {
    public var steps: [BassStep]

    public init(steps: [BassStep] = []) {
        self.steps = Pattern.normalized(steps, fill: .rest)
    }

    public subscript(step: Int) -> BassStep {
        get { steps[step] }
        set { steps[step] = newValue }
    }

    public func noteCount(length: Int = Pattern.maxSteps) -> Int {
        steps.prefix(length).filter { $0.kind == .note }.count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(steps: try container.decode([BassStep].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(steps)
    }
}

public struct TimeSignature: Codable, Hashable, Sendable, CustomStringConvertible {
    public var numerator: Int
    public var denominator: Int
    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
    public static let fourFour = TimeSignature(4, 4)
    public var description: String { "\(numerator)/\(denominator)" }
}

/// One complete loop: drums + bass + musical settings. This is the
/// application's normalized representation and is intentionally independent of
/// Roland's backup file layout.
public struct Pattern: Codable, Hashable, Sendable {
    public static let maxSteps = 32
    public static let lengthRange = 1...32
    public static let bpmRange = 40.0...300.0

    public var name: String
    public var bpm: Double
    public var timeSignature: TimeSignature
    /// Swing amount 0...100. 0 = straight; 100 = full triplet shuffle on off-beat 16ths.
    public var swing: Int
    /// Active length in 16th-note steps (1...32).
    public var length: Int
    public var key: PitchClass
    public var scale: Scale
    public var drums: DrumPattern
    public var bass: BassPattern

    public init(
        name: String = "Untitled",
        bpm: Double = 120,
        timeSignature: TimeSignature = .fourFour,
        swing: Int = 0,
        length: Int = 16,
        key: PitchClass = .c,
        scale: Scale = .minor,
        drums: DrumPattern = DrumPattern(),
        bass: BassPattern = BassPattern()
    ) {
        self.name = name
        self.bpm = bpm
        self.timeSignature = timeSignature
        self.swing = swing
        self.length = length
        self.key = key
        self.scale = scale
        self.drums = drums
        self.bass = bass
    }

    static func normalized<T>(_ values: [T], fill: T) -> [T] {
        if values.count == maxSteps { return values }
        if values.count > maxSteps { return Array(values.prefix(maxSteps)) }
        return values + Array(repeating: fill, count: maxSteps - values.count)
    }

    /// Duration of a single 16th step in seconds (without swing).
    public var stepDuration: Double { 60.0 / bpm / 4.0 }
}

/// Application-level A/B/C/D variation slots. These are an app concept, not a
/// native T-8 structure; each slot maps to a separate hardware pattern on export.
public enum VariationSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    case a, b, c, d
    public var id: String { rawValue }
    public var letter: String { rawValue.uppercased() }
    public var title: String {
        switch self {
        case .a: "Foundation"
        case .b: "Driving"
        case .c: "Minimal"
        case .d: "Fill"
        }
    }
}

public struct PatternVariations: Codable, Hashable, Sendable {
    public var a: Pattern
    public var b: Pattern
    public var c: Pattern
    public var d: Pattern

    public init(a: Pattern, b: Pattern, c: Pattern, d: Pattern) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    public subscript(slot: VariationSlot) -> Pattern {
        get {
            switch slot {
            case .a: a
            case .b: b
            case .c: c
            case .d: d
            }
        }
        set {
            switch slot {
            case .a: a = newValue
            case .b: b = newValue
            case .c: c = newValue
            case .d: d = newValue
            }
        }
    }
}

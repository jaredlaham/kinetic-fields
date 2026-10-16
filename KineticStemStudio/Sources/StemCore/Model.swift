import Foundation

/// Instrument categories. Raw values match the engine's class names.
public enum InstrumentClass: String, Codable, CaseIterable, Sendable, Identifiable {
    case drums
    case bassGuitar = "bass_guitar"
    case synthBass = "synth_bass"
    case monoSynth = "mono_synth"
    case polySynth = "poly_synth"
    case piano
    case guitar
    case vocal
    case otherMelodic = "other_melodic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .drums: "Drums / percussion"
        case .bassGuitar: "Bass guitar"
        case .synthBass: "Synth bass"
        case .monoSynth: "Monophonic synth"
        case .polySynth: "Polyphonic synth"
        case .piano: "Piano / keys"
        case .guitar: "Guitar"
        case .vocal: "Vocal melody"
        case .otherMelodic: "Other melodic"
        }
    }

    public var isDrums: Bool { self == .drums }

    /// Which engine pipeline handles this class (mirrors kstem/classify.py PIPELINE).
    public var pipeline: String {
        switch self {
        case .drums: "Drum onsets + hit classifier"
        case .polySynth, .piano, .guitar: "Polyphonic (Basic Pitch)"
        default: "Monophonic pitch"
        }
    }

    public var defaultMIDIChannel: Int { isDrums ? 10 : 1 }

    /// General MIDI program used for the preview instrument.
    public var previewProgram: UInt8 {
        switch self {
        case .drums: 0
        case .bassGuitar: 33
        case .synthBass: 38
        case .monoSynth: 81
        case .polySynth: 90
        case .piano: 0
        case .guitar: 27
        case .vocal: 52
        case .otherMelodic: 11
        }
    }
}

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast, balanced, high
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .high: "High Accuracy"
        }
    }
}

/// One note. Times are seconds from the start of the stem's audio file, so a
/// note lines up sample-accurately with the waveform it came from.
public struct NoteEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var pitch: Int
    public var start: Double
    public var end: Double
    public var velocity: Int
    /// The engine's own 0...1 belief in the note. Not an accuracy guarantee.
    public var confidence: Double
    /// Drum class for drum notes ("kick", "snare", ...).
    public var drum: String?
    /// Pitch-bend curve relative to `pitch`: (seconds from note start, semitones).
    public var bends: [[Double]]
    /// Review state: nil = not reviewed, true = accepted, false = rejected (kept but not exported).
    public var accepted: Bool?

    public init(id: UUID = UUID(), pitch: Int, start: Double, end: Double, velocity: Int, confidence: Double = 1,
                drum: String? = nil, bends: [[Double]] = [], accepted: Bool? = nil) {
        self.id = id
        self.pitch = pitch
        self.start = start
        self.end = end
        self.velocity = velocity
        self.confidence = confidence
        self.drum = drum
        self.bends = bends
        self.accepted = accepted
    }

    public var duration: Double { end - start }

    enum CodingKeys: String, CodingKey { case id, pitch, start, end, velocity, confidence, drum, bends, accepted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pitch = try c.decode(Int.self, forKey: .pitch)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        velocity = try c.decode(Int.self, forKey: .velocity)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        drum = try c.decodeIfPresent(String.self, forKey: .drum)
        bends = try c.decodeIfPresent([[Double]].self, forKey: .bends) ?? []
        accepted = try c.decodeIfPresent(Bool.self, forKey: .accepted)
    }
}

public struct Classification: Codable, Hashable, Sendable {
    public var proposed: InstrumentClass
    public var confidence: Double
    public var scores: [String: Double]
    public var features: [String: Double]

    public init(proposed: InstrumentClass, confidence: Double, scores: [String: Double] = [:], features: [String: Double] = [:]) {
        self.proposed = proposed
        self.confidence = confidence
        self.scores = scores
        self.features = features
    }
}

/// The engine's output for one stem, kept unchanged once made.
public struct Transcription: Codable, Hashable, Sendable {
    public var engine: String
    public var engineVersion: String
    public var mode: TranscriptionMode
    public var instrument: InstrumentClass
    /// Hash of the audio the notes came from: a changed file invalidates the cache.
    public var audioSHA256: String
    public var pitchBends: Bool
    public var createdAt: Date
    public var processingSeconds: Double
    public var notes: [NoteEvent]
    public var warnings: [String]

    public init(engine: String, engineVersion: String, mode: TranscriptionMode, instrument: InstrumentClass,
                audioSHA256: String, pitchBends: Bool, createdAt: Date = Date(), processingSeconds: Double,
                notes: [NoteEvent], warnings: [String]) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.mode = mode
        self.instrument = instrument
        self.audioSHA256 = audioSHA256
        self.pitchBends = pitchBends
        self.createdAt = createdAt
        self.processingSeconds = processingSeconds
        self.notes = notes
        self.warnings = warnings
    }

    /// Same audio, same settings: no need to run the engine again.
    public func matches(sha: String, mode: TranscriptionMode, instrument: InstrumentClass, pitchBends: Bool) -> Bool {
        audioSHA256 == sha && self.mode == mode && self.instrument == instrument && self.pitchBends == pitchBends
    }
}

public struct AudioFileRef: Codable, Hashable, Sendable {
    /// Absolute path when last saved.
    public var path: String
    /// Path relative to the project package's parent folder, used if the absolute path moved with the project.
    public var relativePath: String?
    public var sha256: String?
    public var sampleRate: Double
    public var channels: Int
    public var frames: Int64
    public var format: String

    public init(path: String, relativePath: String? = nil, sha256: String? = nil, sampleRate: Double, channels: Int,
                frames: Int64, format: String) {
        self.path = path
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sampleRate = sampleRate
        self.channels = channels
        self.frames = frames
        self.format = format
    }

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    public var url: URL { URL(fileURLWithPath: path) }
}

public enum JobState: String, Codable, Sendable {
    case idle, queued, analyzing, transcribing, done, failed, cancelled
}

public struct Stem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var file: AudioFileRef
    public var colorIndex: Int
    public var muted: Bool
    public var soloed: Bool
    public var volumeDB: Double
    public var leadingSilence: Double
    public var classification: Classification?
    public var instrumentOverride: InstrumentClass?
    public var mode: TranscriptionMode
    public var pitchBends: Bool
    public var drumSensitivity: Double
    public var midiChannel: Int
    public var confidenceThreshold: Double
    /// Original engine output; never edited.
    public var transcription: Transcription?
    /// The user's corrected notes (original, unquantised timing). nil = untouched.
    public var editedNotes: [NoteEvent]?
    /// Last error from the engine, shown on the stem.
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, file: AudioFileRef, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.file = file
        self.colorIndex = colorIndex
        muted = false
        soloed = false
        volumeDB = 0
        leadingSilence = 0
        mode = .balanced
        pitchBends = false
        drumSensitivity = 0.5
        midiChannel = 1
        confidenceThreshold = 0
    }

    public var instrument: InstrumentClass { instrumentOverride ?? classification?.proposed ?? .otherMelodic }

    /// The notes the editor shows and exports start from.
    public var notes: [NoteEvent] { editedNotes ?? transcription?.notes ?? [] }

    /// Notes that pass the confidence threshold and were not rejected.
    public var exportableNotes: [NoteEvent] {
        notes.filter { $0.accepted != false && ($0.accepted == true || $0.confidence >= confidenceThreshold) }
    }

    public var hasEdits: Bool { editedNotes != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, file, colorIndex, muted, soloed, volumeDB, leadingSilence, classification, instrumentOverride
        case mode, pitchBends, drumSensitivity, midiChannel, confidenceThreshold, transcription, editedNotes, lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(AudioFileRef.self, forKey: .file)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        soloed = try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        leadingSilence = try c.decodeIfPresent(Double.self, forKey: .leadingSilence) ?? 0
        classification = try c.decodeIfPresent(Classification.self, forKey: .classification)
        instrumentOverride = try c.decodeIfPresent(InstrumentClass.self, forKey: .instrumentOverride)
        mode = try c.decodeIfPresent(TranscriptionMode.self, forKey: .mode) ?? .balanced
        pitchBends = try c.decodeIfPresent(Bool.self, forKey: .pitchBends) ?? false
        drumSensitivity = try c.decodeIfPresent(Double.self, forKey: .drumSensitivity) ?? 0.5
        midiChannel = try c.decodeIfPresent(Int.self, forKey: .midiChannel) ?? 1
        confidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? 0
        transcription = try c.decodeIfPresent(Transcription.self, forKey: .transcription)
        editedNotes = try c.decodeIfPresent([NoteEvent].self, forKey: .editedNotes)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

public enum TempoSource: String, Codable, Sendable {
    case none, detected, manual, tapped
}

public struct TempoMap: Codable, Hashable, Sendable {
    public var bpm: Double
    public var beatsPerBar: Int
    public var beatUnit: Int
    /// Seconds of the first bar line (bar 1, beat 1).
    public var downbeat: Double
    public var source: TempoSource
    public var confidence: Double
    public var alternatives: [Double]
    public var stable: Bool
    public var warnings: [String]

    public init(bpm: Double = 120, beatsPerBar: Int = 4, beatUnit: Int = 4, downbeat: Double = 0,
                source: TempoSource = .none, confidence: Double = 0, alternatives: [Double] = [], stable: Bool = true,
                warnings: [String] = []) {
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
        self.downbeat = downbeat
        self.source = source
        self.confidence = confidence
        self.alternatives = alternatives
        self.stable = stable
        self.warnings = warnings
    }

    public var secondsPerBeat: Double { 60.0 / bpm * 4.0 / Double(beatUnit) }
    public var secondsPerBar: Double { secondsPerBeat * Double(beatsPerBar) }

    /// Beat position (0 = first downbeat) of a time in seconds.
    public func beat(at seconds: Double) -> Double { (seconds - downbeat) / secondsPerBeat }
    public func seconds(atBeat beat: Double) -> Double { downbeat + beat * secondsPerBeat }

    /// Beat times within [from, to], with whether each is a bar line.
    public func gridLines(from: Double, to: Double) -> [(time: Double, isBar: Bool, bar: Int)] {
        guard bpm > 0, to > from else { return [] }
        let first = Int(floor(beat(at: from)))
        let last = Int(ceil(beat(at: to)))
        guard last - first < 100_000 else { return [] }
        return (first...last).map { b in
            let barIndex = Int(floor(Double(b) / Double(beatsPerBar)))
            return (seconds(atBeat: Double(b)), b % beatsPerBar == 0, barIndex + 1)
        }.filter { $0.time >= from - 1e-9 && $0.time <= to + 1e-9 }
    }
}

public enum ExportTiming: String, Codable, CaseIterable, Sendable {
    case original, quantized
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public var ticksPerQuarter: Int = 480
    public var timing: ExportTiming = .original
    public var lastFolder: String?
    public init() {}
}

public struct T8Settings: Codable, Hashable, Sendable {
    public var rhythmChannel: Int = 10
    public var bassChannel: Int = 2
    public var steps: Int = 16
    public var drumMap: [String: String] = [
        "kick": "BD", "snare": "SD", "clap": "HC", "rim": "SD", "closed_hat": "CH", "open_hat": "OH",
        "low_tom": "TOM", "high_tom": "TOM", "crash": "OH", "ride": "CH",
    ]
    public var destinationName: String?
    public init() {}
}

public struct Project: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    public var tempo: TempoMap
    public var stems: [Stem]
    public var quantize: QuantizeSettings
    public var export: ExportSettings
    public var t8: T8Settings

    public init(name: String = "Untitled") {
        schemaVersion = Project.currentSchemaVersion
        id = UUID()
        self.name = name
        created = Date()
        modified = Date()
        tempo = TempoMap()
        stems = []
        quantize = QuantizeSettings()
        export = ExportSettings()
        t8 = T8Settings()
    }

    public var duration: Double { stems.map(\.file.duration).max() ?? 0 }

    /// Stems that sound: solo wins over mute.
    public func isAudible(_ stem: Stem) -> Bool {
        let anySolo = stems.contains { $0.soloed }
        return anySolo ? stem.soloed : !stem.muted
    }
}

// Lenient decoding so documents written before a field existed still open.
extension ExportSettings {
    enum CodingKeys: String, CodingKey { case ticksPerQuarter, timing, lastFolder }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticksPerQuarter = try c.decodeIfPresent(Int.self, forKey: .ticksPerQuarter) ?? ticksPerQuarter
        timing = try c.decodeIfPresent(ExportTiming.self, forKey: .timing) ?? timing
        lastFolder = try c.decodeIfPresent(String.self, forKey: .lastFolder)
    }
}

extension T8Settings {
    enum CodingKeys: String, CodingKey { case rhythmChannel, bassChannel, steps, drumMap, destinationName }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rhythmChannel = try c.decodeIfPresent(Int.self, forKey: .rhythmChannel) ?? rhythmChannel
        bassChannel = try c.decodeIfPresent(Int.self, forKey: .bassChannel) ?? bassChannel
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? steps
        drumMap = try c.decodeIfPresent([String: String].self, forKey: .drumMap) ?? drumMap
        destinationName = try c.decodeIfPresent(String.self, forKey: .destinationName)
    }
}

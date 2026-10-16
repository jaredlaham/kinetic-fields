import Foundation

/// Messages exchanged with the Python engine (`python -m kstem <command>`).
/// The engine prints one JSON object per line; see engine/kstem/cli.py.
public enum EngineEvent: Sendable, Equatable {
    case progress(Double, String)
    case result(Data)
    case error(kind: String, message: String)
}

public enum EngineLineParser {
    /// Parses one line of engine output. Lines that are not engine events return nil.
    public static func parse(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return nil }
        switch event {
        case "progress":
            return .progress(obj["fraction"] as? Double ?? 0, obj["message"] as? String ?? "")
        case "result":
            guard let payload = obj["data"], let d = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return .result(d)
        case "error":
            return .error(kind: obj["kind"] as? String ?? "error", message: obj["message"] as? String ?? "Unknown engine error")
        default:
            return nil
        }
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

// MARK: - analyze

public struct AnalyzeRequest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public var id: String
        public var path: String
        public init(id: String, path: String) { self.id = id; self.path = path }
    }
    public var files: [File]
    public var beatsPerBar: Int
    public var classify: Bool
    public init(files: [File], beatsPerBar: Int = 4, classify: Bool = true) {
        self.files = files
        self.beatsPerBar = beatsPerBar
        self.classify = classify
    }
}

public struct AnalyzeResponse: Codable, Sendable {
    public struct StemInfo: Codable, Sendable {
        public var id: String?
        public var path: String
        public var sha256: String
        public var sampleRate: Double
        public var channels: Int
        public var frames: Int64
        public var duration: Double
        public var format: String
        public var leadingSilence: Double
        public var peakDbfs: Double
        public var classification: EngineClassification?
    }
    public struct EngineClassification: Codable, Sendable {
        public var proposed: String
        public var label: String
        public var confidence: Double
        /// [[class, score], ...] best first. (The `scores` dictionary's keys are camel-cased by the
        /// snake-case decoder, so the app reads this list instead.)
        public var ranked: [[RankedValue]]
        public var features: [String: Double]

        public var model: Classification? {
            var s: [String: Double] = [:]
            for pair in ranked where pair.count == 2 {
                if case .name(let n) = pair[0], case .score(let v) = pair[1] { s[n] = v }
            }
            return InstrumentClass(rawValue: proposed).map { Classification(proposed: $0, confidence: confidence, scores: s, features: features) }
        }
    }
    public enum RankedValue: Codable, Sendable {
        case name(String)
        case score(Double)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .score(v) } else { self = .name(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .name(let n): try c.encode(n)
            case .score(let v): try c.encode(v)
            }
        }
    }
    public struct Tempo: Codable, Sendable {
        public var bpm: Double
        public var confidence: Double
        public var alternatives: [Double]
        public var beats: [Double]
        public var downbeat: Double
        public var downbeatConfidence: Double
        public var beatsPerBar: Int
        public var tempoStable: Bool
        public var localBpmRange: [Double]
        public var warnings: [String]
    }
    public var stems: [StemInfo]
    public var tempo: Tempo
}

// MARK: - transcribe

public struct TranscribeRequest: Codable, Sendable {
    public var path: String
    public var instrument: String
    public var mode: String
    public var pitchBends: Bool
    public var sensitivity: Double
    public init(path: String, instrument: InstrumentClass, mode: TranscriptionMode, pitchBends: Bool, sensitivity: Double) {
        self.path = path
        self.instrument = instrument.rawValue
        self.mode = mode.rawValue
        self.pitchBends = pitchBends
        self.sensitivity = sensitivity
    }
}

public struct TranscribeResponse: Codable, Sendable {
    public struct EngineNote: Codable, Sendable {
        public var pitch: Int
        public var start: Double
        public var end: Double
        public var velocity: Int
        public var confidence: Double
        public var drum: String?
        public var bends: [[Double]]?
    }
    public var notes: [EngineNote]
    public var pipeline: String
    public var engine: String
    public var engineVersion: String
    public var mode: String
    public var instrument: String
    public var processingSeconds: Double
    public var warnings: [String]
    public var audioSha256: String

    public func transcription(pitchBends: Bool) -> Transcription {
        Transcription(
            engine: engine, engineVersion: engineVersion, mode: TranscriptionMode(rawValue: mode) ?? .balanced,
            instrument: InstrumentClass(rawValue: instrument) ?? .otherMelodic, audioSHA256: audioSha256,
            pitchBends: pitchBends, processingSeconds: processingSeconds,
            notes: notes.map { NoteEvent(pitch: $0.pitch, start: $0.start, end: $0.end, velocity: $0.velocity,
                                         confidence: $0.confidence, drum: $0.drum, bends: $0.bends ?? []) },
            warnings: warnings)
    }
}

// MARK: - exports

public struct ExportNote: Codable, Sendable {
    public var pitch: Int
    public var start: Double
    public var end: Double
    public var velocity: Int
    public var bends: [[Double]]
    public var drum: String?

    public init(_ n: NoteEvent) {
        pitch = n.pitch
        start = n.start
        end = n.end
        velocity = n.velocity
        bends = n.bends
        drum = n.drum
    }
}

public struct ExportTrack: Codable, Sendable {
    public var name: String
    public var channel: Int
    public var notes: [ExportNote]
    public var program: Int?
    public var isDrum: Bool
    public init(name: String, channel: Int, notes: [NoteEvent], program: Int? = nil, isDrum: Bool) {
        self.name = name
        self.channel = channel
        self.notes = notes.map(ExportNote.init)
        self.program = program
        self.isDrum = isDrum
    }
}

public struct MIDIExportRequest: Codable, Sendable {
    public var tracks: [ExportTrack]
    public var bpm: Double
    public var meter: [Int]
    public var tpq: Int
    public var out: String
    public var layout: String  // "multitrack" | "individual"
    public var title: String
    public var region: [Double]?
    public init(tracks: [ExportTrack], bpm: Double, meter: [Int], tpq: Int, out: String, layout: String, title: String, region: [Double]?) {
        self.tracks = tracks
        self.bpm = bpm
        self.meter = meter
        self.tpq = tpq
        self.out = out
        self.layout = layout
        self.title = title
        self.region = region
    }
}

public struct MIDIExportResponse: Codable, Sendable {
    public var files: [String]
    public var notesWritten: Int
    public var validated: Bool
    public var problems: [String]
    public var warnings: [String]
}

public struct AbletonExportRequest: Codable, Sendable {
    public struct StemPart: Codable, Sendable {
        public var name: String
        public var path: String?
        public var instrument: String
        public var midi: ExportTrack?
        public var includeAudio: Bool
        public init(name: String, path: String?, instrument: InstrumentClass, midi: ExportTrack?, includeAudio: Bool) {
            self.name = name
            self.path = path
            self.instrument = instrument.rawValue
            self.midi = midi
            self.includeAudio = includeAudio
        }
    }
    public var stems: [StemPart]
    public var bpm: Double
    public var meter: [Int]
    public var title: String
    public var parent: String
    public var kind: String  // "native" | "package"
    public var tpq: Int
    public var overwrite: Bool
    public init(stems: [StemPart], bpm: Double, meter: [Int], title: String, parent: String, kind: String, tpq: Int, overwrite: Bool) {
        self.stems = stems
        self.bpm = bpm
        self.meter = meter
        self.title = title
        self.parent = parent
        self.kind = kind
        self.tpq = tpq
        self.overwrite = overwrite
    }
}

public struct AbletonExportResponse: Codable, Sendable {
    public var folder: String
    public var kind: String
    public var files: [String]
    public var tracks: [String]
    public var leftOff: [String]
    public var problems: [String]
    public var warnings: [String]
}

public struct T8ConvertRequest: Codable, Sendable {
    public var drumNotes: [ExportNote]
    public var bassNotes: [ExportNote]
    public var bpm: Double
    public var gridStart: Double
    public var steps: Int
    public var segments: Int?
    public var drumMap: [String: String]
    public var midiOut: String?
    public var rhythmChannel: Int
    public var bassChannel: Int
    public init(drumNotes: [NoteEvent], bassNotes: [NoteEvent], bpm: Double, gridStart: Double, steps: Int,
                segments: Int?, drumMap: [String: String], midiOut: String?, rhythmChannel: Int, bassChannel: Int) {
        self.drumNotes = drumNotes.map(ExportNote.init)
        self.bassNotes = bassNotes.map(ExportNote.init)
        self.bpm = bpm
        self.gridStart = gridStart
        self.steps = steps
        self.segments = segments
        self.drumMap = drumMap
        self.midiOut = midiOut
        self.rhythmChannel = rhythmChannel
        self.bassChannel = bassChannel
    }
}

public struct T8ConvertResponse: Codable, Sendable {
    public struct Segment: Codable, Sendable {
        public var index: Int
        public var startSeconds: Double
        public var steps: Int
        /// Voice -> per step [on, velocity, accent].
        public var drums: [String: [[Int]]]
        /// Per step [note or null, tie, accent, slide].
        public var bass: [[Int?]]
    }
    public var bpm: Double
    public var segments: [Segment]
    public var report: [String]
    public var counts: [String: Int]
    public var midiFile: String?
}

public struct DoctorResponse: Codable, Sendable {
    public struct Check: Codable, Sendable, Identifiable {
        public var name: String
        public var ok: Bool
        public var detail: String
        public var required: Bool
        public var id: String { name }
    }
    public var version: String
    public var checks: [Check]
    public var ok: Bool
}

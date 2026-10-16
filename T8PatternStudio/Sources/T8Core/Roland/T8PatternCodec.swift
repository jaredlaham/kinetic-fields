import Foundation

/// Field codes in T-8 rhythm `.prm` step lines, per the open-source AIRA
/// Pattern Editor. The rhythm file uses TR-808-style codes: `HT` carries the
/// hand clap and `LT` the tom (consistent with the T-8 MIDI chart, where clap
/// is note 50 and tom note 47). `CY` and any other code are preserved untouched.
public enum T8RhythmCode: String, CaseIterable, Sendable {
    case accent = "AC"
    case bassDrum = "BD"
    case snare = "SD"
    case lowTom = "LT"
    case highTom = "HT"
    case cymbal = "CY"
    case closedHat = "CH"
    case openHat = "OH"

    public var voice: DrumVoice? {
        switch self {
        case .bassDrum: .kick
        case .snare: .snare
        case .highTom: .clap
        case .lowTom: .tom
        case .closedHat: .closedHat
        case .openHat: .openHat
        case .accent, .cymbal: nil
        }
    }

    public static func code(for voice: DrumVoice) -> T8RhythmCode {
        allCases.first { $0.voice == voice }!
    }
}

public enum T8CodecError: Error, Equatable, LocalizedError {
    case notARhythmPattern
    case notABassPattern
    case missingSteps([Int])
    case invalidStepValue(step: Int, field: String, value: String)
    case unwritableFields(step: Int, fields: [String])

    public var errorDescription: String? {
        switch self {
        case .notARhythmPattern: "The file does not look like a T-8 rhythm pattern (.prm with STEP lines containing BD/SD/CH… fields)."
        case .notABassPattern: "The file does not look like a T-8 bass pattern (.prm with STEP lines containing STATE/NOTE fields)."
        case .missingSteps(let steps): "The file is missing step lines \(steps.map(String.init).joined(separator: ", "))."
        case .invalidStepValue(let step, let field, let value): "Unrecognized value \(field)=\(value) on step \(step)."
        case .unwritableFields(let step, let fields): "Step \(step) has no \(fields.joined(separator: "/")) field to write to."
        }
    }
}

/// Encodes/decodes the 5-character rhythm step code:
/// `[on 0/1][velocity 0-9,A][sub-step 0-4][probability 0-9,A][sub-step probability 0-9,A]`.
public enum T8RhythmStepCode {
    static func digit(_ c: Character) -> Int? {
        if c == "A" { return 10 }
        return c.wholeNumberValue.flatMap { (0...9).contains($0) ? $0 : nil }
    }

    static func char(_ value: Int) -> Character {
        let v = min(max(value, 0), 10)
        return v == 10 ? "A" : Character(String(v))
    }

    public static func decode(_ value: String) -> DrumHit?? {
        let chars = Array(value)
        guard chars.count == 5, let on = digit(chars[0]), on <= 1,
              let velocity = digit(chars[1]), let sub = digit(chars[2]), sub <= 4,
              let probability = digit(chars[3]), let subProbability = digit(chars[4]) else { return .none } // malformed
        guard on == 1 else { return .some(nil) } // off
        let subStep: SubStep = [.none, .x2, .x3, .x4, .flam][sub]
        return .some(DrumHit(velocity: velocity, subStep: subStep, probability: probability * 10, subStepProbability: subProbability * 10))
    }

    public static func encode(_ hit: DrumHit?, offValue: String) -> String {
        guard let hit else { return offValue }
        let sub = [SubStep.none, .x2, .x3, .x4, .flam].firstIndex(of: hit.subStep)!
        return String([
            "1",
            char(hit.velocity),
            Character(String(sub)),
            char(Int((Double(hit.probability) / 10).rounded())),
            char(Int((Double(hit.subStepProbability) / 10).rounded())),
        ])
    }

    /// Accent row uses the same 5-character format; on/off is the first character.
    public static func encodeAccent(_ on: Bool, existing: String) -> String {
        if on {
            if existing.first == "1" { return existing }
            return "1\(T8RhythmStepCode.char(DrumHit.defaultVelocity))0AA"
        }
        return existing.first == "0" ? existing : "000AA"
    }
}

/// Swing conversion. Unverified: maps app swing 0...100 linearly onto the
/// SHUFFLE field 0...900 (the AIRA editor exposes −90…90 and stores ×10).
public enum T8Shuffle {
    public static func fileValue(fromSwing swing: Int) -> Int { min(max(swing, 0), 100) * 9 }
    public static func swing(fromFileValue value: Int) -> Int { min(max(Int((Double(value) / 9).rounded()), 0), 100) }
}

/// Bass NOTE field ↔ MIDI note. The offset is UNVERIFIED (see capability matrix).
public struct T8BassNoteMapping: Hashable, Sendable, Codable {
    public var midiNoteForZero: Int
    public static let assumed = T8BassNoteMapping(midiNoteForZero: 12)
    public init(midiNoteForZero: Int) { self.midiNoteForZero = midiNoteForZero }
    public func fileValue(forMIDINote note: Int) -> Int { note - midiNoteForZero }
    public func midiNote(forFileValue value: Int) -> Int { value + midiNoteForZero }
}

/// Reads and writes the drum part of a T-8 rhythm `.prm` document.
public enum T8RhythmCodec {
    public static func isRhythm(_ document: PRMDocument) -> Bool {
        guard let fields = document.fields(step: 1) else { return false }
        let keys = Set(fields.map(\.key))
        return keys.contains("BD") && keys.contains("SD")
    }

    public static func decode(_ document: PRMDocument) throws -> (drums: DrumPattern, length: Int, swing: Int) {
        guard isRhythm(document) else { throw T8CodecError.notARhythmPattern }
        var drums = DrumPattern()
        for number in document.stepNumbers where (1...Pattern.maxSteps).contains(number) {
            let index = number - 1
            for field in document.fields(step: number) ?? [] {
                guard let code = T8RhythmCode(rawValue: field.key) else { continue }
                guard let decoded = T8RhythmStepCode.decode(field.value) else {
                    throw T8CodecError.invalidStepValue(step: number, field: field.key, value: field.value)
                }
                if code == .accent {
                    drums.accents[index] = decoded != nil
                } else if let voice = code.voice {
                    drums[voice, index] = decoded
                }
            }
        }
        let length = Int(document.setting("LENGTH") ?? "") ?? 16
        let swing = T8Shuffle.swing(fromFileValue: Int(document.setting("SHUFFLE") ?? "") ?? 0)
        return (drums, min(max(length, 1), Pattern.maxSteps), swing)
    }

    /// Writes drums, length and (optionally) swing into an existing document,
    /// touching only the affected values.
    public static func apply(_ pattern: Pattern, to document: inout PRMDocument, writeSwing: Bool) throws {
        guard isRhythm(document) else { throw T8CodecError.notARhythmPattern }
        let missing = (1...Pattern.maxSteps).filter { document.fields(step: $0) == nil }
        guard missing.isEmpty else { throw T8CodecError.missingSteps(missing) }
        for number in 1...Pattern.maxSteps {
            let index = number - 1
            var values: [String: String] = [:]
            for voice in DrumVoice.allCases {
                let code = T8RhythmCode.code(for: voice).rawValue
                let existing = document.field(code, step: number) ?? "000AA"
                let offValue = existing.first == "0" ? existing : "000AA"
                let newHit = pattern.drums[voice, index]
                // Keep the exact existing string when the decoded value would not change.
                if let decoded = T8RhythmStepCode.decode(existing), decoded == newHit {
                    values[code] = existing
                } else {
                    values[code] = T8RhythmStepCode.encode(newHit, offValue: offValue)
                }
            }
            let accentExisting = document.field(T8RhythmCode.accent.rawValue, step: number) ?? "000AA"
            values[T8RhythmCode.accent.rawValue] = T8RhythmStepCode.encodeAccent(pattern.drums.accents[index], existing: accentExisting)
            let unwritable = document.setFields(step: number, values)
            if !unwritable.isEmpty { throw T8CodecError.unwritableFields(step: number, fields: unwritable) }
        }
        document.setSetting("LENGTH", String(pattern.length))
        if writeSwing { document.setSetting("SHUFFLE", String(T8Shuffle.fileValue(fromSwing: pattern.swing))) }
    }
}

/// Reads and writes the bass part of a T-8 bass `.prm` document.
public enum T8BassCodec {
    public static func isBass(_ document: PRMDocument) -> Bool {
        guard let fields = document.fields(step: 1) else { return false }
        let keys = Set(fields.map(\.key))
        return keys.contains("STATE") && keys.contains("NOTE")
    }

    public static func decode(_ document: PRMDocument, mapping: T8BassNoteMapping = .assumed) throws -> (bass: BassPattern, length: Int) {
        guard isBass(document) else { throw T8CodecError.notABassPattern }
        var bass = BassPattern()
        for number in document.stepNumbers where (1...Pattern.maxSteps).contains(number) {
            let value = { (key: String) -> Int? in document.field(key, step: number).flatMap { Int($0) } }
            guard let state = value("STATE"), (0...2).contains(state) else {
                throw T8CodecError.invalidStepValue(step: number, field: "STATE", value: document.field("STATE", step: number) ?? "")
            }
            let note = mapping.midiNote(forFileValue: value("NOTE") ?? 0)
            let kind: BassStep.Kind = [.rest, .note, .tie][state]
            bass[number - 1] = BassStep(kind: kind, note: note, accent: value("ACCENT") == 1, slide: value("SLIDE") == 1)
        }
        bass.repairTies()
        let length = Int(document.setting("LENGTH") ?? "") ?? 16
        return (bass, min(max(length, 1), Pattern.maxSteps))
    }

    public static func apply(_ pattern: Pattern, to document: inout PRMDocument, mapping: T8BassNoteMapping = .assumed) throws {
        guard isBass(document) else { throw T8CodecError.notABassPattern }
        let missing = (1...Pattern.maxSteps).filter { document.fields(step: $0) == nil }
        guard missing.isEmpty else { throw T8CodecError.missingSteps(missing) }
        let decodedExisting = try decode(document, mapping: mapping).bass
        for number in 1...Pattern.maxSteps {
            let index = number - 1
            let step = pattern.bass[index]
            // Leave lines whose meaning would not change exactly as they are
            // (e.g. rests keep whatever NOTE value the unit stored).
            if equivalent(decodedExisting[index], step) { continue }
            let state: Int
            switch step.kind {
            case .rest: state = 0
            case .note: state = 1
            case .tie: state = 2
            }
            var values = [
                "STATE": String(state),
                "ACCENT": step.accent && step.kind == .note ? "1" : "0",
                "SLIDE": step.slide && step.kind != .rest ? "1" : "0",
            ]
            // NOTE is written for new notes only. What the T-8 stores in NOTE on a
            // tie step is unknown, so tie and rest steps keep the existing value.
            if step.kind == .note { values["NOTE"] = String(mapping.fileValue(forMIDINote: step.note)) }
            let unwritable = document.setFields(step: number, values)
            if !unwritable.isEmpty { throw T8CodecError.unwritableFields(step: number, fields: unwritable) }
        }
        document.setSetting("LENGTH", String(pattern.length))
    }

    static func equivalent(_ a: BassStep, _ b: BassStep) -> Bool {
        if a.kind != b.kind { return false }
        switch a.kind {
        case .rest: return true
        case .note: return a.note == b.note && a.accent == b.accent && a.slide == b.slide
        case .tie: return a.slide == b.slide
        }
    }
}

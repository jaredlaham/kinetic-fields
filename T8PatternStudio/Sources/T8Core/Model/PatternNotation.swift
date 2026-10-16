import Foundation

/// Compact, human-readable text notation for drum lanes and bass lines.
///
/// Used to author the factory library, to exchange patterns with Claude, and
/// for debugging. Spaces and `|` are ignored in drum lanes so bars can be
/// visually separated.
///
/// Drum lane characters (one per 16th step):
///   `.` or `-` off      `x` hit (velocity 7)   `X` loud (10)   `o` soft (4)
///   `g` ghost (2)       `f` flam               `2` `3` `4` sub-step ratchet
///   `?` 50% probability hit
/// Accent row: `a`, `x` or `X` mark an accented step; `.` none.
///
/// Bass line: whitespace separated tokens, one per step:
///   `.` rest   `-` tie (hold previous note)   `D2` note (C4 = MIDI 60)
///   note suffixes: `!` accent, `~` slide into next note. e.g. `A1!~`
public enum PatternNotation {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    // MARK: Drums

    public static func parseDrumLane(_ text: String) throws -> [DrumHit?] {
        var steps: [DrumHit?] = []
        for char in text where char != " " && char != "|" {
            switch char {
            case ".", "-": steps.append(nil)
            case "x": steps.append(.normal)
            case "X": steps.append(.loud)
            case "o": steps.append(.soft)
            case "g": steps.append(DrumHit(velocity: 2))
            case "f", "F": steps.append(DrumHit(subStep: .flam))
            case "2": steps.append(DrumHit(subStep: .x2))
            case "3": steps.append(DrumHit(subStep: .x3))
            case "4": steps.append(DrumHit(subStep: .x4))
            case "?": steps.append(DrumHit(probability: 50))
            default: throw ParseError(message: "Unknown drum character '\(char)' in \"\(text)\"")
            }
        }
        guard steps.count <= Pattern.maxSteps else {
            throw ParseError(message: "Drum lane has \(steps.count) steps; maximum is \(Pattern.maxSteps)")
        }
        return steps
    }

    public static func parseAccents(_ text: String) throws -> [Bool] {
        var steps: [Bool] = []
        for char in text where char != " " && char != "|" {
            switch char {
            case ".", "-": steps.append(false)
            case "a", "A", "x", "X": steps.append(true)
            default: throw ParseError(message: "Unknown accent character '\(char)'")
            }
        }
        guard steps.count <= Pattern.maxSteps else {
            throw ParseError(message: "Accent row has \(steps.count) steps; maximum is \(Pattern.maxSteps)")
        }
        return steps
    }

    public static func format(lane: [DrumHit?], length: Int) -> String {
        lane.prefix(length).map { hit -> String in
            guard let hit else { return "." }
            if hit.probability < 100 && hit.probability >= 40 && hit.subStep == .none { return "?" }
            switch hit.subStep {
            case .flam: return "f"
            case .x2: return "2"
            case .x3: return "3"
            case .x4: return "4"
            case .none: break
            }
            switch hit.velocity {
            case 9...: return "X"
            case 5...8: return "x"
            case 3...4: return "o"
            default: return "g"
            }
        }.joined()
    }

    public static func format(accents: [Bool], length: Int) -> String {
        accents.prefix(length).map { $0 ? "a" : "." }.joined()
    }

    // MARK: Bass

    public static func parseBass(_ text: String) throws -> [BassStep] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "|" })
        guard tokens.count <= Pattern.maxSteps else {
            throw ParseError(message: "Bass line has \(tokens.count) steps; maximum is \(Pattern.maxSteps)")
        }
        var steps: [BassStep] = []
        var lastNote: Int?
        for token in tokens {
            var body = String(token)
            if body == "." {
                steps.append(.rest)
                lastNote = nil
                continue
            }
            var accent = false
            var slide = false
            while let last = body.last, last == "!" || last == "~" {
                if last == "!" { accent = true } else { slide = true }
                body.removeLast()
            }
            if body == "-" {
                guard let held = lastNote else {
                    throw ParseError(message: "Tie '-' must follow a note or another tie")
                }
                steps.append(BassStep(kind: .tie, note: held, accent: false, slide: slide))
                continue
            }
            guard let note = NoteName.midiNote(from: body) else {
                throw ParseError(message: "Invalid bass token '\(token)'")
            }
            steps.append(.note(note, accent: accent, slide: slide))
            lastNote = note
        }
        return steps
    }

    public static func format(bass: [BassStep], length: Int) -> String {
        bass.prefix(length).map { step -> String in
            switch step.kind {
            case .rest: return "."
            case .tie: return step.slide ? "-~" : "-"
            case .note:
                return NoteName.string(for: step.note) + (step.accent ? "!" : "") + (step.slide ? "~" : "")
            }
        }.joined(separator: " ")
    }

    // MARK: Whole patterns

    /// Builds a pattern from notation strings. Lanes shorter than `length` are
    /// repeated to fill it (so a 16-step lane can seed a 32-step pattern).
    public static func pattern(
        name: String,
        bpm: Double,
        swing: Int = 0,
        length: Int = 16,
        key: PitchClass,
        scale: Scale,
        drums: [DrumVoice: String],
        accents: String = "",
        bass: String
    ) throws -> Pattern {
        var pattern = Pattern(name: name, bpm: bpm, swing: swing, length: length, key: key, scale: scale)
        for (voice, text) in drums {
            let steps = repeatToFill(try parseDrumLane(text), length: length, fill: nil)
            for index in 0..<steps.count { pattern.drums[voice, index] = steps[index] }
        }
        let accentSteps = repeatToFill(try parseAccents(accents), length: length, fill: false)
        for index in 0..<accentSteps.count { pattern.drums.accents[index] = accentSteps[index] }
        let bassSteps = repeatToFill(try parseBass(bass), length: length, fill: .rest)
        pattern.bass = BassPattern(steps: bassSteps)
        return pattern
    }

    static func repeatToFill<T>(_ values: [T], length: Int, fill: T) -> [T] {
        guard !values.isEmpty else { return [] }
        var result: [T] = []
        while result.count < length { result.append(contentsOf: values) }
        return Array(result.prefix(length))
    }
}

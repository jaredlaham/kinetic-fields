import Foundation

/// The twelve pitch classes. Raw value is semitones above C.
public enum PitchClass: Int, Codable, CaseIterable, Sendable, Identifiable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    public var id: Int { rawValue }

    public var name: String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][rawValue]
    }

    public init?(name: String) {
        let table: [String: Int] = [
            "C": 0, "B#": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "FB": 4,
            "F": 5, "E#": 5, "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9,
            "A#": 10, "BB": 10, "B": 11, "CB": 11,
        ]
        guard let value = table[name.uppercased()] else { return nil }
        self.init(rawValue: value)
    }
}

/// Musical scales used for scale locking and generation.
public enum Scale: String, Codable, CaseIterable, Sendable, Identifiable {
    case minor, major, harmonicMinor, phrygian, dorian, minorPentatonic, blues, chromatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minor: "Minor"
        case .major: "Major"
        case .harmonicMinor: "Harmonic Minor"
        case .phrygian: "Phrygian"
        case .dorian: "Dorian"
        case .minorPentatonic: "Minor Pentatonic"
        case .blues: "Blues"
        case .chromatic: "Chromatic"
        }
    }

    /// Semitone offsets from the root.
    public var intervals: [Int] {
        switch self {
        case .minor: [0, 2, 3, 5, 7, 8, 10]
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
        case .phrygian: [0, 1, 3, 5, 7, 8, 10]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .blues: [0, 3, 5, 6, 7, 10]
        case .chromatic: Array(0..<12)
        }
    }

    public func contains(midiNote: Int, root: PitchClass) -> Bool {
        let degree = ((midiNote - root.rawValue) % 12 + 12) % 12
        return intervals.contains(degree)
    }

    /// Nearest in-scale note. Ties resolve downward.
    public func snap(midiNote: Int, root: PitchClass) -> Int {
        if contains(midiNote: midiNote, root: root) { return midiNote }
        for distance in 1...6 {
            if contains(midiNote: midiNote - distance, root: root) { return midiNote - distance }
            if contains(midiNote: midiNote + distance, root: root) { return midiNote + distance }
        }
        return midiNote
    }

    /// All in-scale MIDI notes inside a range (inclusive).
    public func notes(root: PitchClass, in range: ClosedRange<Int>) -> [Int] {
        range.filter { contains(midiNote: $0, root: root) }
    }

    /// Moves `steps` scale degrees up (positive) or down (negative) from `midiNote`.
    public func move(midiNote: Int, degrees steps: Int, root: PitchClass) -> Int {
        var note = snap(midiNote: midiNote, root: root)
        var remaining = steps
        while remaining != 0 {
            let direction = remaining > 0 ? 1 : -1
            repeat { note += direction } while !contains(midiNote: note, root: root)
            remaining -= direction
        }
        return note
    }
}

/// Note naming uses the convention C4 = MIDI 60 (so C-1 = 0, C1 = 24, C2 = 36).
public enum NoteName {
    public static func string(for midiNote: Int) -> String {
        let pitch = PitchClass(rawValue: ((midiNote % 12) + 12) % 12)!
        let octave = Int((Double(midiNote) / 12.0).rounded(.down)) - 1
        return "\(pitch.name)\(octave)"
    }

    /// Parses names such as "C2", "D#1", "Bb-1". Returns nil if malformed.
    public static func midiNote(from text: String) -> Int? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        var index = 1
        if chars.count > 1, chars[1] == "#" || chars[1] == "b" { index = 2 }
        let namePart = String(chars[0..<index])
        let octavePart = String(chars[index...])
        guard let pitch = PitchClass(name: namePart), let octave = Int(octavePart) else { return nil }
        return (octave + 1) * 12 + pitch.rawValue
    }
}

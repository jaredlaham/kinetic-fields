import Foundation

/// Linear undo/redo history of value snapshots.
public struct UndoHistory<State: Equatable & Sendable>: Sendable {
    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records `previous` before a change is applied.
    public mutating func record(_ previous: State) {
        if undoStack.last == previous { return }
        undoStack.append(previous)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// A rectangular selection in the drum grid (rows = voices, columns = steps).
public struct StepSelection: Hashable, Sendable {
    public var voices: [DrumVoice]
    public var includesBass: Bool
    public var steps: Range<Int>

    public init(voices: [DrumVoice], includesBass: Bool = false, steps: Range<Int>) {
        self.voices = voices
        self.includesBass = includesBass
        self.steps = steps
    }

    public static func all(length: Int) -> StepSelection {
        StepSelection(voices: DrumVoice.allCases, includesBass: true, steps: 0..<length)
    }
}

/// Copied region of a pattern.
public struct StepClipboard: Hashable, Sendable {
    public var drums: [DrumVoice: [DrumHit?]]
    public var accents: [Bool]
    public var bass: [BassStep]?
    public var width: Int
}

/// Pure editing operations used by the drum sequencer and bass editor.
public enum PatternEditor {
    // MARK: Drums

    public static func toggle(_ pattern: inout Pattern, voice: DrumVoice, step: Int) {
        guard (0..<Pattern.maxSteps).contains(step) else { return }
        pattern.drums[voice, step] = pattern.drums[voice, step] == nil ? .normal : nil
        enforceHatChoke(&pattern, voice: voice, step: step)
    }

    /// Paint mode: set a step on or off (used while dragging).
    public static func paint(_ pattern: inout Pattern, voice: DrumVoice, step: Int, on: Bool) {
        guard (0..<Pattern.maxSteps).contains(step) else { return }
        if on {
            if pattern.drums[voice, step] == nil { pattern.drums[voice, step] = .normal }
        } else {
            pattern.drums[voice, step] = nil
        }
        enforceHatChoke(&pattern, voice: voice, step: step)
    }

    public static func toggleAccent(_ pattern: inout Pattern, step: Int) {
        guard (0..<Pattern.maxSteps).contains(step) else { return }
        pattern.drums.accents[step].toggle()
    }

    public static func setVelocity(_ pattern: inout Pattern, voice: DrumVoice, step: Int, velocity: Int) {
        guard var hit = pattern.drums[voice, step] else { return }
        hit.velocity = min(max(velocity, DrumHit.velocityRange.lowerBound), DrumHit.velocityRange.upperBound)
        pattern.drums[voice, step] = hit
    }

    public static func cycleSubStep(_ pattern: inout Pattern, voice: DrumVoice, step: Int) {
        guard var hit = pattern.drums[voice, step] else { return }
        let all = SubStep.allCases
        hit.subStep = all[(all.firstIndex(of: hit.subStep)! + 1) % all.count]
        pattern.drums[voice, step] = hit
    }

    public static func setProbability(_ pattern: inout Pattern, voice: DrumVoice, step: Int, probability: Int) {
        guard var hit = pattern.drums[voice, step] else { return }
        hit.probability = (min(max(probability, 0), 100) / 10) * 10
        pattern.drums[voice, step] = hit
    }

    /// The T-8's closed hat chokes the open hat. The editor keeps them exclusive per step.
    static func enforceHatChoke(_ pattern: inout Pattern, voice: DrumVoice, step: Int) {
        if voice == .closedHat, pattern.drums[.closedHat, step] != nil { pattern.drums[.openHat, step] = nil }
        if voice == .openHat, pattern.drums[.openHat, step] != nil { pattern.drums[.closedHat, step] = nil }
    }

    // MARK: Selection / clipboard

    public static func copy(_ pattern: Pattern, selection: StepSelection) -> StepClipboard {
        var drums: [DrumVoice: [DrumHit?]] = [:]
        for voice in selection.voices { drums[voice] = Array(pattern.drums.lane(voice)[selection.steps]) }
        return StepClipboard(
            drums: drums,
            accents: Array(pattern.drums.accents[selection.steps]),
            bass: selection.includesBass ? Array(pattern.bass.steps[selection.steps]) : nil,
            width: selection.steps.count
        )
    }

    public static func paste(_ clipboard: StepClipboard, into pattern: inout Pattern, at start: Int) {
        for offset in 0..<clipboard.width {
            let target = start + offset
            guard target < Pattern.maxSteps else { break }
            for (voice, lane) in clipboard.drums { pattern.drums[voice, target] = lane[offset] }
            if !clipboard.drums.isEmpty { pattern.drums.accents[target] = clipboard.accents[offset] }
            if let bass = clipboard.bass { pattern.bass[target] = bass[offset] }
        }
        pattern.bass.repairTies()
    }

    public static func clear(_ pattern: inout Pattern, selection: StepSelection) {
        for step in selection.steps where step < Pattern.maxSteps {
            for voice in selection.voices { pattern.drums[voice, step] = nil }
            if selection.voices.count == DrumVoice.allCases.count { pattern.drums.accents[step] = false }
            if selection.includesBass { pattern.bass[step] = .rest }
        }
        pattern.bass.repairTies()
    }

    /// Doubles a 1–16 step pattern by copying it after itself.
    public static func duplicateLength(_ pattern: inout Pattern) {
        let length = pattern.length
        guard length * 2 <= Pattern.maxSteps else { return }
        let clipboard = copy(pattern, selection: .all(length: length))
        paste(clipboard, into: &pattern, at: length)
        pattern.length = length * 2
    }

    public static func setLength(_ pattern: inout Pattern, _ length: Int) {
        pattern.length = min(max(length, Pattern.lengthRange.lowerBound), Pattern.lengthRange.upperBound)
    }

    /// Rotates the selected rows by `amount` steps within the active length.
    public static func shift(_ pattern: inout Pattern, voices: [DrumVoice], includeBass: Bool, by amount: Int) {
        let length = pattern.length
        func rotated<T>(_ values: [T]) -> [T] {
            var result = values
            for i in 0..<length { result[((i + amount) % length + length) % length] = values[i] }
            return result
        }
        for voice in voices { pattern.drums.lanes[voice] = rotated(pattern.drums.lane(voice)) }
        if voices.count == DrumVoice.allCases.count { pattern.drums.accents = rotated(pattern.drums.accents) }
        if includeBass {
            pattern.bass.steps = rotated(pattern.bass.steps)
            pattern.bass.repairTies()
        }
    }

    /// Randomizes drum lanes with musically weighted probabilities.
    public static func randomizeDrums(_ pattern: inout Pattern, voices: [DrumVoice], density: Double, seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for voice in voices {
            for step in 0..<pattern.length {
                let weight: Double
                switch voice {
                case .kick: weight = step % 4 == 0 ? 0.85 : (step % 2 == 0 ? 0.25 : 0.1)
                case .snare, .clap: weight = step % 8 == 4 ? 0.9 : 0.08
                case .closedHat: weight = step % 2 == 0 ? 0.7 : 0.35
                case .openHat: weight = step % 4 == 2 ? 0.35 : 0.03
                case .tom: weight = 0.08
                }
                let p = min(max(weight * density * 1.4, 0), 1)
                pattern.drums[voice, step] = rng.chance(p) ? DrumHit(velocity: rng.chance(0.2) ? 4 : 7) : nil
            }
        }
        for step in 0..<pattern.length { enforceHatChoke(&pattern, voice: .closedHat, step: step) }
    }

    // MARK: Bass

    public static func setBassNote(_ pattern: inout Pattern, step: Int, note: Int, scaleLock: Bool) {
        guard (0..<Pattern.maxSteps).contains(step) else { return }
        let clamped = min(max(note, HardwareCapabilities.bassNoteRange.lowerBound), HardwareCapabilities.bassNoteRange.upperBound)
        let final = scaleLock ? pattern.scale.snap(midiNote: clamped, root: pattern.key) : clamped
        var current = pattern.bass[step]
        current.kind = .note
        current.note = final
        pattern.bass[step] = current
        pattern.bass.repairTies()
    }

    public static func setBassRest(_ pattern: inout Pattern, step: Int) {
        pattern.bass[step] = .rest
        pattern.bass.repairTies()
    }

    /// Makes a step hold the previous note. No-op if the previous step is a rest.
    public static func setBassTie(_ pattern: inout Pattern, step: Int) {
        guard step > 0, pattern.bass[step - 1].kind != .rest else { return }
        pattern.bass[step] = BassStep(kind: .tie, note: pattern.bass[step - 1].note)
        pattern.bass.repairTies()
    }

    public static func toggleBassAccent(_ pattern: inout Pattern, step: Int) {
        guard pattern.bass[step].kind == .note else { return }
        pattern.bass[step].accent.toggle()
    }

    public static func toggleBassSlide(_ pattern: inout Pattern, step: Int) {
        guard pattern.bass[step].kind != .rest else { return }
        pattern.bass[step].slide.toggle()
    }

    public static func transposeBass(_ pattern: inout Pattern, semitones: Int, scaleLock: Bool) {
        for i in pattern.bass.steps.indices where pattern.bass[i].kind != .rest {
            var note = pattern.bass[i].note + semitones
            while note > HardwareCapabilities.bassNoteRange.upperBound { note -= 12 }
            while note < HardwareCapabilities.bassNoteRange.lowerBound { note += 12 }
            pattern.bass[i].note = scaleLock ? pattern.scale.snap(midiNote: note, root: pattern.key) : note
        }
        pattern.bass.repairTies()
    }

    /// Changes the key, moving every bass note by the shortest interval.
    public static func changeKey(_ pattern: inout Pattern, to key: PitchClass) {
        var delta = key.rawValue - pattern.key.rawValue
        if delta > 6 { delta -= 12 }
        if delta < -6 { delta += 12 }
        pattern.key = key
        transposeBass(&pattern, semitones: delta, scaleLock: false)
    }

    public static func randomizeBass(_ pattern: inout Pattern, density: Double, slideAmount: Double, accentAmount: Double, octave: Int, seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let root = (octave + 1) * 12 + pattern.key.rawValue
        let pool = pattern.scale.notes(root: pattern.key, in: root...(root + 12))
        for i in 0..<pattern.length {
            if i > 0, pattern.bass[i - 1].kind != .rest, rng.chance(0.12) {
                pattern.bass[i] = BassStep(kind: .tie, note: pattern.bass[i - 1].note)
            } else if rng.chance(i % 4 == 0 ? min(1, density + 0.3) : density) {
                let note = (i % 4 == 0 || rng.chance(0.4)) ? root : pool.randomElement(using: &rng) ?? root
                pattern.bass[i] = .note(note, accent: rng.chance(accentAmount), slide: rng.chance(slideAmount))
            } else {
                pattern.bass[i] = .rest
            }
        }
        pattern.bass.repairTies()
    }
}

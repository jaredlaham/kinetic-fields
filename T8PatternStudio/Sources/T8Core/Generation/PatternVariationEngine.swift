import Foundation

/// Deterministic, seedable random number generator (SplitMix64) so that
/// variations and generated patterns are reproducible and testable.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }
}

extension BassPattern {
    /// Makes tie steps consistent: a tie after a rest becomes a rest, and a
    /// tie's pitch always mirrors the note it holds.
    public mutating func repairTies() {
        var held: Int?
        for index in steps.indices {
            switch steps[index].kind {
            case .rest: held = nil
            case .note: held = steps[index].note
            case .tie:
                if let held { steps[index].note = held } else { steps[index] = .rest }
            }
        }
    }
}

/// Derives the B (Driving), C (Minimal) and D (Fill) variations from a
/// foundation pattern. Pure and deterministic for a given seed.
public enum PatternVariationEngine {
    public static func makeVariations(from foundation: Pattern, genre: Genre?, seed: UInt64) -> PatternVariations {
        PatternVariations(
            a: foundation,
            b: driving(from: foundation, seed: seed &+ 1),
            c: minimal(from: foundation),
            d: fill(from: foundation, seed: seed &+ 3)
        )
    }

    public static func variation(_ slot: VariationSlot, from foundation: Pattern, seed: UInt64) -> Pattern {
        switch slot {
        case .a: foundation
        case .b: driving(from: foundation, seed: seed)
        case .c: minimal(from: foundation)
        case .d: fill(from: foundation, seed: seed)
        }
    }

    /// B — more energy and rhythmic density.
    public static func driving(from base: Pattern, seed: UInt64) -> Pattern {
        var rng = SeededRandom(seed: seed)
        var p = base
        p.name = base.name
        let length = p.length

        // Closed hats: fill empty 16ths with soft hits, leaving open-hat steps alone.
        for i in 0..<length where p.drums[.closedHat, i] == nil && p.drums[.openHat, i] == nil {
            if i % 2 == 0 || rng.chance(0.5) { p.drums[.closedHat, i] = DrumHit(velocity: i % 4 == 0 ? 7 : 4) }
        }
        // Ghost snares before backbeats.
        for i in stride(from: 3, to: length, by: 8) where p.drums[.snare, i] == nil && rng.chance(0.6) {
            p.drums[.snare, i] = DrumHit(velocity: 2)
        }
        // Push the kick: an extra syncopated kick in the last beat if space allows.
        if length >= 16, p.drums[.kick, length - 3] == nil, p.drums[.kick, length - 4] != nil || rng.chance(0.5) {
            p.drums[.kick, length - 3] = DrumHit(velocity: 5)
        }
        // Accent every kick on the beat.
        for i in stride(from: 0, to: length, by: 4) where p.drums[.kick, i] != nil { p.drums.accents[i] = true }

        // Bass: answer rests with octave / fifth hits and add accents.
        var lastNote = p.bass.steps.prefix(length).first(where: { $0.kind == .note })?.note ?? (36 + p.key.rawValue)
        for i in 0..<length {
            let step = p.bass[i]
            if step.kind == .note {
                lastNote = step.note
                if i % 4 == 0 { p.bass[i].accent = true }
            } else if step.kind == .rest, i % 2 == 1, rng.chance(0.45) {
                let jump = rng.chance(0.5) ? 12 : 7
                let candidate = p.scale.snap(midiNote: lastNote + jump, root: p.key)
                p.bass[i] = .note(min(candidate, 60), accent: false, slide: false)
            }
        }
        p.bass.repairTies()
        return p
    }

    /// C — reduced percussion and simplified bass.
    public static func minimal(from base: Pattern) -> Pattern {
        var p = base
        let length = p.length
        var drums = DrumPattern()
        for i in 0..<length {
            if i % 4 == 0, let hit = base.drums[.kick, i] { drums[.kick, i] = hit }
            if i % 8 == 4 {
                if let hit = base.drums[.snare, i] { drums[.snare, i] = hit }
                if let hit = base.drums[.clap, i] { drums[.clap, i] = hit }
            }
            if i % 4 == 2 {
                if let hit = base.drums[.closedHat, i] ?? base.drums[.openHat, i] {
                    drums[.closedHat, i] = DrumHit(velocity: min(hit.velocity, 6))
                }
            }
        }
        // Never leave the minimal variation completely empty of time-keeping.
        if drums.hitCount(length: length) == 0 {
            for i in stride(from: 0, to: length, by: 4) { drums[.kick, i] = .soft }
        }
        p.drums = drums

        var bass = BassPattern()
        var keptAny = false
        for i in 0..<length {
            let step = base.bass[i]
            if step.kind == .note, i % 4 == 0 || !keptAny {
                bass[i] = .note(step.note)
                keptAny = true
            } else if step.kind == .tie, bass[max(i - 1, 0)].kind != .rest, i > 0 {
                bass[i] = BassStep(kind: .tie, note: step.note)
            }
        }
        bass.repairTies()
        p.bass = bass
        return p
    }

    /// D — a turnaround fill over the final beat (or two, for 32-step patterns).
    public static func fill(from base: Pattern, seed: UInt64) -> Pattern {
        var rng = SeededRandom(seed: seed)
        var p = base
        let length = p.length
        let fillLength = length >= 32 ? 8 : min(4, length)
        let start = length - fillLength
        guard start >= 0 else { return p }

        let ratchets: [SubStep] = [.none, .x2, .x3, .x4]
        for offset in 0..<fillLength {
            let i = start + offset
            p.drums[.kick, i] = (offset == 0) ? base.drums[.kick, i] ?? .normal : nil
            p.drums[.closedHat, i] = nil
            p.drums[.openHat, i] = nil
            let progress = Double(offset) / Double(max(fillLength - 1, 1))
            let ratchet = ratchets[min(Int(progress * 3.0 + 0.5), 3)]
            p.drums[.snare, i] = DrumHit(velocity: 5 + Int(progress * 5), subStep: ratchet)
            if offset % 2 == 1 || rng.chance(0.3) { p.drums[.tom, i] = DrumHit(velocity: 6) }
        }
        p.drums[.openHat, length - 1] = .loud
        p.drums.accents[length - 1] = true

        // Bass walks up the scale into the loop point.
        let anchor = base.bass.steps.prefix(start).last(where: { $0.kind == .note })?.note ?? (36 + p.key.rawValue)
        var note = p.scale.snap(midiNote: anchor, root: p.key)
        for offset in 0..<fillLength {
            let i = start + offset
            p.bass[i] = .note(note, accent: offset == fillLength - 1, slide: offset == fillLength - 2)
            note = p.scale.move(midiNote: note, degrees: 1, root: p.key)
        }
        p.bass.repairTies()
        return p
    }
}

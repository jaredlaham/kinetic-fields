import Foundation

/// Statistical description of a genre, learned from its factory presets.
/// Step templates are folded to 16 steps and hold the probability (0...1)
/// that a step is active.
public struct GenreProfile: Sendable, Equatable {
    public var genres: [Genre: Double]
    public var bpm: Double
    public var bpmRange: ClosedRange<Double>
    public var swing: Double
    public var drumTemplates: [DrumVoice: [Double]]
    public var accentTemplate: [Double]
    public var bassNoteTemplate: [Double]
    public var bassTieTemplate: [Double]
    public var slideRate: Double
    public var accentRate: Double
    /// Mean MIDI note of bass notes (used to choose the register).
    public var bassCenter: Double
    /// Average spread of bass notes in semitones (how melodic the line is).
    public var bassSpread: Double
    public var scales: [Scale: Double]
    public var energy: Double

    public static func learned(from genre: Genre, presets: [Preset] = FactoryLibrary.presets) -> GenreProfile {
        let patterns = presets.filter { $0.genres.contains(genre) }.map(\.main)
        return learned(patterns: patterns, genre: genre, energy: presets.filter { $0.genres.contains(genre) }.map { Double($0.energy) })
    }

    static func learned(patterns: [Pattern], genre: Genre, energy: [Double]) -> GenreProfile {
        precondition(!patterns.isEmpty, "No patterns to learn \(genre) from")
        var drum: [DrumVoice: [Double]] = [:]
        for voice in DrumVoice.allCases { drum[voice] = Array(repeating: 0, count: 16) }
        var accents = Array(repeating: 0.0, count: 16)
        var notes = Array(repeating: 0.0, count: 16)
        var ties = Array(repeating: 0.0, count: 16)
        var bars = 0.0
        var slideCount = 0.0, accentCount = 0.0, noteCount = 0.0
        var pitches: [Double] = []
        var spreads: [Double] = []
        var scales: [Scale: Double] = [:]

        for pattern in patterns {
            scales[pattern.scale, default: 0] += 1
            let barsInPattern = max(1, pattern.length / 16)
            bars += Double(barsInPattern)
            for i in 0..<(barsInPattern * 16) {
                let folded = i % 16
                for voice in DrumVoice.allCases where pattern.drums[voice, i] != nil { drum[voice]![folded] += 1 }
                if pattern.drums.accents[i] { accents[folded] += 1 }
                let step = pattern.bass[i]
                switch step.kind {
                case .note:
                    notes[folded] += 1
                    noteCount += 1
                    pitches.append(Double(step.note))
                    if step.slide { slideCount += 1 }
                    if step.accent { accentCount += 1 }
                case .tie: ties[folded] += 1
                case .rest: break
                }
            }
            let patternNotes = pattern.bass.steps.prefix(pattern.length).filter { $0.kind == .note }.map { Double($0.note) }
            if let lo = patternNotes.min(), let hi = patternNotes.max() { spreads.append(hi - lo) }
        }
        func normalize(_ values: [Double]) -> [Double] { values.map { $0 / bars } }
        for voice in DrumVoice.allCases { drum[voice] = normalize(drum[voice]!) }
        let bpms = patterns.map(\.bpm)
        return GenreProfile(
            genres: [genre: 1],
            bpm: bpms.reduce(0, +) / Double(bpms.count),
            bpmRange: bpms.min()!...bpms.max()!,
            swing: Double(patterns.map(\.swing).reduce(0, +)) / Double(patterns.count),
            drumTemplates: drum,
            accentTemplate: normalize(accents),
            bassNoteTemplate: normalize(notes),
            bassTieTemplate: normalize(ties),
            slideRate: noteCount > 0 ? slideCount / noteCount : 0,
            accentRate: noteCount > 0 ? accentCount / noteCount : 0,
            bassCenter: pitches.isEmpty ? 36 : pitches.reduce(0, +) / Double(pitches.count),
            bassSpread: spreads.isEmpty ? 7 : spreads.reduce(0, +) / Double(spreads.count),
            scales: scales,
            energy: energy.isEmpty ? 3 : energy.reduce(0, +) / Double(energy.count)
        )
    }

    /// Weighted blend. `weight` is the share of `self` (0...1).
    public func blended(with other: GenreProfile, weight: Double) -> GenreProfile {
        let w = min(max(weight, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a * w + b * (1 - w) }
        func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { mix($0, $1) } }
        var drum: [DrumVoice: [Double]] = [:]
        for voice in DrumVoice.allCases { drum[voice] = mix(drumTemplates[voice]!, other.drumTemplates[voice]!) }
        var genreWeights: [Genre: Double] = [:]
        for (g, v) in genres { genreWeights[g, default: 0] += v * w }
        for (g, v) in other.genres { genreWeights[g, default: 0] += v * (1 - w) }
        var scaleWeights: [Scale: Double] = [:]
        let selfTotal = scales.values.reduce(0, +), otherTotal = other.scales.values.reduce(0, +)
        for (s, v) in scales { scaleWeights[s, default: 0] += v / max(selfTotal, 1) * w }
        for (s, v) in other.scales { scaleWeights[s, default: 0] += v / max(otherTotal, 1) * (1 - w) }
        return GenreProfile(
            genres: genreWeights,
            bpm: mix(bpm, other.bpm),
            bpmRange: min(bpmRange.lowerBound, other.bpmRange.lowerBound)...max(bpmRange.upperBound, other.bpmRange.upperBound),
            swing: mix(swing, other.swing),
            drumTemplates: drum,
            accentTemplate: mix(accentTemplate, other.accentTemplate),
            bassNoteTemplate: mix(bassNoteTemplate, other.bassNoteTemplate),
            bassTieTemplate: mix(bassTieTemplate, other.bassTieTemplate),
            slideRate: mix(slideRate, other.slideRate),
            accentRate: mix(accentRate, other.accentRate),
            bassCenter: mix(bassCenter, other.bassCenter),
            bassSpread: mix(bassSpread, other.bassSpread),
            scales: scaleWeights,
            energy: mix(energy, other.energy)
        )
    }

    public var dominantScale: Scale {
        scales.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key ?? .minor
    }
}

/// A primary/secondary genre mix such as "70% Trip-Hop / 30% French Electro".
public struct GenreBlend: Codable, Hashable, Sendable {
    public var primary: Genre
    public var secondary: Genre
    /// Share of the primary genre, 0...100.
    public var primaryPercent: Int

    public init(primary: Genre, secondary: Genre, primaryPercent: Int) {
        self.primary = primary
        self.secondary = secondary
        self.primaryPercent = min(max(primaryPercent, 0), 100)
    }

    public var label: String {
        "\(primaryPercent)% \(primary.displayName) / \(100 - primaryPercent)% \(secondary.displayName)"
    }

    public var profile: GenreProfile {
        GenreProfile.learned(from: primary).blended(with: .learned(from: secondary), weight: Double(primaryPercent) / 100)
    }
}

/// Rule-based offline pattern generator driven by a (possibly blended) genre
/// profile. Used for "Surprise me", genre blending without an API key, and as
/// a deterministic fallback when cloud generation is unavailable.
public enum ProceduralGenerator {
    public struct Options: Sendable {
        public var key: PitchClass?
        public var scale: Scale?
        public var bpm: Double?
        public var length: Int
        /// -2 ... +2, shifts density.
        public var energyBias: Int
        public init(key: PitchClass? = nil, scale: Scale? = nil, bpm: Double? = nil, length: Int = 16, energyBias: Int = 0) {
            self.key = key
            self.scale = scale
            self.bpm = bpm
            self.length = length
            self.energyBias = energyBias
        }
    }

    public static func generate(profile: GenreProfile, name: String, options: Options = Options(), seed: UInt64) -> Pattern {
        var rng = SeededRandom(seed: seed)
        let key = options.key ?? PitchClass.allCases.randomElement(using: &rng)!
        let scale = options.scale ?? profile.dominantScale
        let length = min(max(options.length, 1), Pattern.maxSteps)
        let densityBias = Double(options.energyBias) * 0.12

        var pattern = Pattern(
            name: name,
            bpm: options.bpm ?? (profile.bpm).rounded(),
            swing: Int(profile.swing.rounded()),
            length: length,
            key: key,
            scale: scale
        )

        func decide(_ p: Double) -> Bool {
            let biased = min(max(p + densityBias * (p > 0.05 ? 1 : 0), 0), 1)
            if biased >= 0.7 { return true }
            if biased <= 0.05 { return false }
            return rng.chance(biased * 0.85)
        }

        for i in 0..<length {
            let folded = i % 16
            for voice in DrumVoice.allCases {
                let p = profile.drumTemplates[voice]![folded]
                guard decide(p) else { continue }
                let velocity = p >= 0.9 ? 9 : (p >= 0.5 ? 7 : (voice == .snare ? 3 : 5))
                pattern.drums[voice, i] = DrumHit(velocity: velocity)
            }
            if pattern.drums[.openHat, i] != nil { pattern.drums[.closedHat, i] = nil } // hats choke each other
            pattern.drums.accents[i] = profile.accentTemplate[folded] >= 0.5
        }
        if pattern.drums[.kick, 0] == nil { pattern.drums[.kick, 0] = .normal }

        // Bass.
        let center = Int(profile.bassCenter.rounded())
        let rootNote = nearest(pitch: key, to: center)
        let spread = max(3, Int(profile.bassSpread.rounded()))
        let pool = scale.notes(root: key, in: (rootNote - 2)...(rootNote + spread + 2))
        var previousKind: BassStep.Kind = .rest
        var lastNote = rootNote
        for i in 0..<length {
            let folded = i % 16
            if previousKind != .rest, rng.chance(profile.bassTieTemplate[folded] * 1.2) {
                pattern.bass[i] = BassStep(kind: .tie, note: lastNote)
                previousKind = .tie
                continue
            }
            guard decide(profile.bassNoteTemplate[folded]) else {
                previousKind = .rest
                continue
            }
            let note: Int
            if folded % 4 == 0 || pool.isEmpty || rng.chance(0.45) {
                note = rng.chance(0.2) && rootNote + 12 <= 72 ? rootNote + 12 : rootNote
            } else {
                note = pool.randomElement(using: &rng)!
            }
            pattern.bass[i] = .note(note, accent: rng.chance(profile.accentRate), slide: rng.chance(profile.slideRate))
            lastNote = note
            previousKind = .note
        }
        if pattern.bass.noteCount(length: length) == 0 { pattern.bass[0] = .note(rootNote) }
        pattern.bass.repairTies()
        return pattern
    }

    static func nearest(pitch: PitchClass, to center: Int) -> Int {
        let base = center - ((center - pitch.rawValue) % 12 + 12) % 12
        return (center - base) > 6 ? base + 12 : base
    }
}

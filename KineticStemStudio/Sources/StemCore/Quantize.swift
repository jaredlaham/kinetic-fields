import Foundation

public enum GridDivision: String, Codable, CaseIterable, Sendable, Identifiable {
    case quarter = "1/4"
    case eighth = "1/8"
    case sixteenth = "1/16"
    case thirtySecond = "1/32"
    case eighthTriplet = "1/8T"
    case sixteenthTriplet = "1/16T"

    public var id: String { rawValue }

    /// Grid step in beats (quarter notes).
    public var beats: Double {
        switch self {
        case .quarter: 1
        case .eighth: 0.5
        case .sixteenth: 0.25
        case .thirtySecond: 0.125
        case .eighthTriplet: 1.0 / 3.0
        case .sixteenthTriplet: 1.0 / 6.0
        }
    }
}

/// Non-destructive quantisation: applied when notes are shown or exported
/// with quantised timing; the stored notes keep their detected timing.
public struct QuantizeSettings: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    public var division: GridDivision = .sixteenth
    /// 0 = no movement, 1 = fully on the grid. Values in between keep part of the groove.
    public var strength: Double = 1.0
    /// 0...1: delays every second grid step by up to half a step.
    public var swing: Double = 0
    public var quantizeEnds: Bool = false

    public init() {}
}

public enum Quantizer {
    /// Grid position (seconds) nearest to `t`, with swing applied to odd steps.
    public static func gridTime(_ t: Double, tempo: TempoMap, settings: QuantizeSettings) -> Double {
        let stepBeats = settings.division.beats
        let step = tempo.secondsPerBeat * stepBeats
        guard step > 0 else { return t }
        let rel = (t - tempo.downbeat) / step
        // Consider the two nearest swung grid points.
        let base = floor(rel)
        var best = t
        var bestDist = Double.infinity
        for k in [base - 1, base, base + 1, base + 2] {
            var g = tempo.downbeat + k * step
            if Int(k).isMultiple(of: 2) == false { g += settings.swing * step * 0.5 }
            let d = abs(g - t)
            if d < bestDist {
                bestDist = d
                best = g
            }
        }
        return best
    }

    public static func apply(_ notes: [NoteEvent], tempo: TempoMap, settings: QuantizeSettings) -> [NoteEvent] {
        guard settings.enabled else { return notes }
        let s = max(0, min(1, settings.strength))
        let minLen = tempo.secondsPerBeat * settings.division.beats * 0.25
        return notes.map { n in
            var q = n
            let target = gridTime(n.start, tempo: tempo, settings: settings)
            q.start = n.start + (target - n.start) * s
            if settings.quantizeEnds {
                let endTarget = gridTime(n.end, tempo: tempo, settings: settings)
                q.end = n.end + (endTarget - n.end) * s
            } else {
                q.end = q.start + n.duration
            }
            if q.end - q.start < minLen { q.end = q.start + max(minLen, 0.005) }
            return q
        }
    }

    /// Largest distance any note start would move, for the export summary.
    public static func maxShift(_ notes: [NoteEvent], tempo: TempoMap, settings: QuantizeSettings) -> Double {
        let q = apply(notes, tempo: tempo, settings: settings)
        return zip(notes, q).map { abs($0.start - $1.start) }.max() ?? 0
    }
}

// Lenient decoding so documents written before a field existed still open.
extension QuantizeSettings {
    enum CodingKeys: String, CodingKey { case enabled, division, strength, swing, quantizeEnds }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        division = try c.decodeIfPresent(GridDivision.self, forKey: .division) ?? division
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        swing = try c.decodeIfPresent(Double.self, forKey: .swing) ?? swing
        quantizeEnds = try c.decodeIfPresent(Bool.self, forKey: .quantizeEnds) ?? quantizeEnds
    }
}

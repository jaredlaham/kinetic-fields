import Foundation

/// A musical event produced from a pattern. Positions and durations are in
/// 16th-note steps from the start of the rendered region (swing applied).
public struct ScheduledEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case drum(DrumVoice, velocity: UInt8)
        /// `slideIn` = this note is glided into from the previous one.
        case bass(note: Int, velocity: UInt8, slideIn: Bool)
    }

    public var position: Double
    public var duration: Double
    public var kind: Kind
    /// Probability 0...100; live players roll against it, exporters keep every event.
    public var probability: Int
    /// The pattern step that produced the event.
    public var step: Int
}

/// Converts patterns into timed events. Shared by the audio preview, the MIDI
/// output scheduler and the MIDI file exporter so they always agree.
public enum PlaybackScheduler {
    /// Delay of odd (off-beat) 16ths, in steps. 100% swing = 1/3 step (triplet feel).
    public static func swingOffset(step: Int, swing: Int) -> Double {
        step % 2 == 1 ? Double(min(max(swing, 0), 100)) / 100.0 / 3.0 : 0
    }

    /// T-8 velocity 0...10 to MIDI velocity.
    public static func midiVelocity(_ t8Velocity: Int, accent: Bool) -> UInt8 {
        if accent { return 127 }
        let clamped = min(max(t8Velocity, 0), 10)
        return UInt8(max(1, min(120, 10 + clamped * 11)))
    }

    public static func events(for pattern: Pattern, loops: Int = 1, applySwing: Bool = true) -> [ScheduledEvent] {
        var events: [ScheduledEvent] = []
        let length = pattern.length
        for loop in 0..<max(loops, 1) {
            let base = Double(loop * length)
            events += drumEvents(pattern, base: base, swing: applySwing ? pattern.swing : 0)
            events += bassEvents(pattern, base: base, swing: applySwing ? pattern.swing : 0)
        }
        return events.sorted { $0.position < $1.position }
    }

    static func drumEvents(_ pattern: Pattern, base: Double, swing: Int) -> [ScheduledEvent] {
        var events: [ScheduledEvent] = []
        for step in 0..<pattern.length {
            let accent = pattern.drums.accents[step]
            let start = base + Double(step) + swingOffset(step: step, swing: swing)
            for voice in DrumVoice.allCases {
                guard let hit = pattern.drums[voice, step] else { continue }
                let velocity = midiVelocity(hit.velocity, accent: accent)
                switch hit.subStep {
                case .none:
                    events.append(ScheduledEvent(position: start, duration: 0.5, kind: .drum(voice, velocity: velocity), probability: hit.probability, step: step))
                case .flam:
                    events.append(ScheduledEvent(position: start, duration: 0.08, kind: .drum(voice, velocity: UInt8(Double(velocity) * 0.6)), probability: hit.probability, step: step))
                    events.append(ScheduledEvent(position: start + 0.12, duration: 0.4, kind: .drum(voice, velocity: velocity), probability: hit.probability, step: step))
                case .x2, .x3, .x4:
                    let count = hit.subStep.hitCount
                    for index in 0..<count {
                        let probability = index == 0 ? hit.probability : hit.probability * hit.subStepProbability / 100
                        events.append(ScheduledEvent(
                            position: start + Double(index) / Double(count),
                            duration: 0.9 / Double(count),
                            kind: .drum(voice, velocity: velocity),
                            probability: probability,
                            step: step
                        ))
                    }
                }
            }
        }
        return events
    }

    static func bassEvents(_ pattern: Pattern, base: Double, swing: Int) -> [ScheduledEvent] {
        var events: [ScheduledEvent] = []
        let length = pattern.length
        let steps = Array(pattern.bass.steps.prefix(length))
        var previousSlid = false
        var step = 0
        while step < length {
            let current = steps[step]
            guard current.kind == .note else {
                if current.kind == .rest { previousSlid = false }
                step += 1
                continue
            }
            // Extend through ties.
            var end = step + 1
            var slide = current.slide
            while end < length, steps[end].kind == .tie {
                slide = steps[end].slide
                end += 1
            }
            let nextIsNote = end < length && steps[end].kind == .note
            let start = base + Double(step) + swingOffset(step: step, swing: swing)
            let endPosition = base + Double(end) + swingOffset(step: end, swing: swing)
            // Non-slid notes are gated at ~half a step on their last step (303 style); slid notes overlap the next.
            let duration = (slide && nextIsNote) ? (endPosition - start) + 0.1 : max(0.1, (endPosition - start) - 0.5)
            events.append(ScheduledEvent(
                position: start,
                duration: duration,
                kind: .bass(note: current.note, velocity: current.accent ? 127 : 90, slideIn: previousSlid),
                probability: 100,
                step: step
            ))
            previousSlid = slide && nextIsNote
            step = end
        }
        return events
    }
}

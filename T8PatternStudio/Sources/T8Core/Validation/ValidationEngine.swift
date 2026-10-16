import Foundation

public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable, Comparable {
        case info, warning, error
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var severity: Severity
    public var message: String
    /// Zero-based step, when the issue concerns a single step.
    public var step: Int?

    public init(_ severity: Severity, _ message: String, step: Int? = nil) {
        self.severity = severity
        self.message = message
        self.step = step
    }

    public var description: String {
        "[\(severity.rawValue)] " + (step.map { "step \($0 + 1): " } ?? "") + message
    }
}

/// Validates patterns for internal consistency (always) and T-8 compatibility (on export).
public enum ValidationEngine {
    /// Structural checks. Patterns with errors must not be saved, played to hardware or exported.
    public static func validate(_ pattern: Pattern) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if pattern.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.warning, "Pattern has no name"))
        }
        if !Pattern.lengthRange.contains(pattern.length) {
            issues.append(.init(.error, "Length \(pattern.length) is outside 1–32"))
        }
        if !Pattern.bpmRange.contains(pattern.bpm) || !pattern.bpm.isFinite {
            issues.append(.init(.error, "BPM \(pattern.bpm) is outside \(Int(Pattern.bpmRange.lowerBound))–\(Int(Pattern.bpmRange.upperBound))"))
        }
        if !(0...100).contains(pattern.swing) {
            issues.append(.init(.error, "Swing \(pattern.swing) is outside 0–100"))
        }
        for voice in DrumVoice.allCases {
            let lane = pattern.drums.lane(voice)
            if lane.count != Pattern.maxSteps { issues.append(.init(.error, "\(voice.displayName) lane has \(lane.count) steps")) }
            for (step, hit) in lane.enumerated() {
                guard let hit else { continue }
                if !DrumHit.velocityRange.contains(hit.velocity) {
                    issues.append(.init(.error, "\(voice.displayName) velocity \(hit.velocity) outside 0–10", step: step))
                }
                if !(0...100).contains(hit.probability) || !(0...100).contains(hit.subStepProbability) {
                    issues.append(.init(.error, "\(voice.displayName) probability outside 0–100", step: step))
                }
            }
        }
        if pattern.drums.accents.count != Pattern.maxSteps {
            issues.append(.init(.error, "Accent row has \(pattern.drums.accents.count) steps"))
        }
        if pattern.bass.steps.count != Pattern.maxSteps {
            issues.append(.init(.error, "Bass has \(pattern.bass.steps.count) steps"))
        }
        var held: Int?
        for (step, bass) in pattern.bass.steps.enumerated() {
            switch bass.kind {
            case .rest: held = nil
            case .note:
                held = bass.note
                if !HardwareCapabilities.bassNoteRange.contains(bass.note) {
                    issues.append(.init(.error, "Bass note \(NoteName.string(for: bass.note)) is outside the T-8 range C0–C7", step: step))
                }
            case .tie:
                if held == nil { issues.append(.init(.error, "Tie without a preceding note", step: step)) }
                if bass.accent { issues.append(.init(.warning, "Accent on a tied step has no effect", step: step)) }
            }
        }
        return issues
    }

    /// Additional checks before sending to / exporting for the T-8.
    public static func validateForHardware(_ pattern: Pattern) -> [ValidationIssue] {
        var issues = validate(pattern)
        for (step, hit) in pattern.drums.lanes.values.flatMap({ $0.enumerated() }) {
            if let hit, hit.probability % 10 != 0 {
                issues.append(.init(.warning, "Probability \(hit.probability)% will be rounded to the T-8's 10% steps", step: step))
            }
        }
        if pattern.swing > 0 {
            issues.append(.init(.info, "Swing is written to the T-8 SHUFFLE setting using an unverified conversion"))
        }
        if pattern.bass.steps[pattern.length - 1].slide && pattern.bass.steps[0].kind == .rest {
            issues.append(.init(.info, "Slide on the last step glides into a rest at the loop point", step: pattern.length - 1))
        }
        issues.append(.init(.info, "BPM \(Int(pattern.bpm)) and key are stored in the app only; set the tempo on the T-8"))
        return issues
    }

    public static func hasErrors(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }
}

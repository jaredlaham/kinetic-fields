import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The structured pattern Claude must return. It reuses `PatternNotation`, so
/// every lane is validated by the same parser used for the factory library.
public struct AIPatternPayload: Codable, Hashable, Sendable {
    public var name: String
    public var bpm: Double
    public var swing: Int
    public var length: Int
    public var key: String
    public var scale: String
    public var kick: String
    public var snare: String
    public var clap: String
    public var tom: String
    public var closedHat: String
    public var openHat: String
    public var accents: String
    public var bass: String
    public var explanation: String

    public init(from pattern: Pattern, explanation: String = "") {
        name = pattern.name
        bpm = pattern.bpm
        swing = pattern.swing
        length = pattern.length
        key = pattern.key.name
        scale = pattern.scale.rawValue
        func lane(_ v: DrumVoice) -> String { PatternNotation.format(lane: pattern.drums.lane(v), length: pattern.length) }
        kick = lane(.kick)
        snare = lane(.snare)
        clap = lane(.clap)
        tom = lane(.tom)
        closedHat = lane(.closedHat)
        openHat = lane(.openHat)
        accents = PatternNotation.format(accents: pattern.drums.accents, length: pattern.length)
        bass = PatternNotation.format(bass: pattern.bass.steps, length: pattern.length)
        self.explanation = explanation
    }

    /// JSON schema sent as the structured-output format.
    public static var jsonSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "bpm", "swing", "length", "key", "scale", "kick", "snare", "clap", "tom", "closedHat", "openHat", "accents", "bass", "explanation"],
        "properties": [
            "name": ["type": "string", "description": "Short evocative pattern name"],
            "bpm": ["type": "number"],
            "swing": ["type": "integer", "description": "0 straight … 100 full triplet shuffle"],
            "length": ["type": "integer", "description": "Steps (16th notes), 1-32; usually 16 or 32"],
            "key": ["type": "string", "description": "Root pitch class, e.g. D, F#, Bb"],
            "scale": ["type": "string", "enum": Scale.allCases.map(\.rawValue)],
            "kick": ["type": "string"], "snare": ["type": "string"], "clap": ["type": "string"], "tom": ["type": "string"],
            "closedHat": ["type": "string"], "openHat": ["type": "string"], "accents": ["type": "string"],
            "bass": ["type": "string"],
            "explanation": ["type": "string", "description": "One or two sentences on what was done"],
        ],
    ] }

    /// Converts and validates. Throws with a precise message on any problem —
    /// raw model output never reaches the sequencer without passing here.
    public func toPattern() throws -> (pattern: Pattern, issues: [ValidationIssue]) {
        guard Pattern.lengthRange.contains(length) else { throw AIError.invalidPattern("length \(length) outside 1–32") }
        guard let root = PitchClass(name: key) else { throw AIError.invalidPattern("unknown key \(key)") }
        guard let scaleValue = Scale(rawValue: scale) else { throw AIError.invalidPattern("unknown scale \(scale)") }
        guard Pattern.bpmRange.contains(bpm) else { throw AIError.invalidPattern("BPM \(bpm) outside 40–300") }
        let lanes: [(DrumVoice, String)] = [(.kick, kick), (.snare, snare), (.clap, clap), (.tom, tom), (.closedHat, closedHat), (.openHat, openHat)]
        for (voice, text) in lanes {
            let count = text.filter { $0 != " " && $0 != "|" }.count
            guard count == length || count == 0 else { throw AIError.invalidPattern("\(voice.displayName) lane has \(count) steps, expected \(length)") }
        }
        let bassCount = bass.split(whereSeparator: { $0 == " " || $0 == "|" }).count
        guard bassCount == length else { throw AIError.invalidPattern("bass has \(bassCount) steps, expected \(length)") }
        var drums: [DrumVoice: String] = [:]
        for (voice, text) in lanes where !text.isEmpty { drums[voice] = text }
        do {
            var pattern = try PatternNotation.pattern(
                name: name.isEmpty ? "AI Pattern" : name, bpm: bpm.rounded(), swing: min(max(swing, 0), 100), length: length,
                key: root, scale: scaleValue, drums: drums, accents: accents, bass: bass
            )
            for step in 0..<length where pattern.drums[.closedHat, step] != nil && pattern.drums[.openHat, step] != nil {
                pattern.drums[.closedHat, step] = nil
            }
            let issues = ValidationEngine.validateForHardware(pattern)
            if let error = issues.first(where: { $0.severity == .error }) { throw AIError.invalidPattern(error.description) }
            return (pattern, issues)
        } catch let error as PatternNotation.ParseError {
            throw AIError.invalidPattern(error.message)
        }
    }
}

public enum AIError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case refused(String)
    case truncated
    case emptyResponse
    case invalidJSON(String)
    case invalidPattern(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Anthropic API key in Settings to use AI generation. Everything else works without it."
        case .http(let status, let message): "Claude API error \(status): \(message)"
        case .refused(let reason): "Claude declined this request\(reason.isEmpty ? "" : ": \(reason)")."
        case .truncated: "The response was cut off before the pattern was complete. Try again."
        case .emptyResponse: "Claude returned no pattern."
        case .invalidJSON(let detail): "Claude's response was not valid pattern JSON (\(detail))."
        case .invalidPattern(let detail): "Claude's pattern failed validation: \(detail)"
        case .transport(let detail): "Network error: \(detail)"
        }
    }

    /// Validation failures are worth one automatic retry with the error fed back.
    var isRetryableWithFeedback: Bool {
        switch self {
        case .invalidJSON, .invalidPattern: true
        default: false
        }
    }
}

/// Abstracts HTTP so the generator is testable without network access.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// What the user asked for.
public enum AIRequestKind: Hashable, Sendable {
    case create(prompt: String)
    case edit(instruction: String)
    case blend(GenreBlend, prompt: String)
    case surprise
    case variation(VariationSlot)
    /// Turn an audio analysis (text summary from `AudioBeatAnalyzer`) into a clean pattern.
    case fromAudio(analysis: String, steps: Int, direction: String)

    public static let quickEdits: [String] = [
        "Make it more aggressive", "Add syncopation", "Add a drum fill", "Simplify the groove",
        "Create a darker bassline", "Add acid slides", "Create a variation", "Make it more minimal",
    ]
}

public struct AIContext: Sendable {
    public var current: Pattern?
    public var genre: Genre?
    public var referencePresets: [Preset]
    public init(current: Pattern? = nil, genre: Genre? = nil, referencePresets: [Preset] = []) {
        self.current = current
        self.genre = genre
        self.referencePresets = referencePresets
    }
}

/// Generates and edits patterns with the Claude Messages API.
///
/// Uses structured outputs (`output_config.format` with a JSON schema) so the
/// response is schema-shaped JSON, then validates it again locally with the
/// notation parser and `ValidationEngine` before anything reaches the editor.
public struct AIPatternGenerator: Sendable {
    public static let defaultModel = "claude-opus-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public var apiKey: String
    public var model: String
    public var transport: HTTPTransport

    public init(apiKey: String, model: String = AIPatternGenerator.defaultModel, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public struct Result: Sendable {
        public var pattern: Pattern
        public var explanation: String
        public var issues: [ValidationIssue]
    }

    public func generate(_ kind: AIRequestKind, context: AIContext) async throws -> Result {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw AIError.missingAPIKey }
        var messages: [[String: Any]] = [["role": "user", "content": Self.userMessage(kind, context: context)]]
        var lastError: AIError = .emptyResponse
        for attempt in 0..<2 {
            let response = try await call(messages: messages)
            do {
                let payload = try Self.decodePayload(fromText: response.text)
                let (pattern, issues) = try payload.toPattern()
                return Result(pattern: pattern, explanation: payload.explanation, issues: issues)
            } catch let error as AIError where error.isRetryableWithFeedback && attempt == 0 {
                lastError = error
                // Append-only retry: keep the assistant turn and add the validation error.
                messages.append(["role": "assistant", "content": response.content])
                messages.append(["role": "user", "content": "That pattern failed validation: \(error.errorDescription ?? "invalid"). Return a corrected pattern following the notation rules exactly."])
            }
        }
        throw lastError
    }

    struct APIResponse {
        var text: String
        var content: [[String: Any]]
    }

    func call(messages: [[String: Any]]) async throws -> APIResponse {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Self.systemPrompt,
            "messages": messages,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": AIPatternPayload.jsonSchema],
            ],
            // Server-side refusal fallback ("default" routing).
            "fallbacks": "default",
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, status: Int
        do {
            (data, status) = try await transport.send(request)
        } catch {
            throw AIError.transport(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.http(status: status, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            throw AIError.http(status: status, message: message)
        }
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw AIError.refused(details?["explanation"] as? String ?? "")
        }
        if stopReason == "max_tokens" { throw AIError.truncated }
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.emptyResponse }
        return APIResponse(text: text, content: content)
    }

    static func decodePayload(fromText text: String) throws -> AIPatternPayload {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a fenced block even though structured output should not produce one.
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}") {
            candidate = String(candidate[start...end])
        }
        do {
            return try JSONDecoder().decode(AIPatternPayload.self, from: Data(candidate.utf8))
        } catch {
            throw AIError.invalidJSON(String(describing: error).prefix(200).description)
        }
    }

    // MARK: Prompts

    static let systemPrompt = """
    You are a drum-machine programmer and electronic music producer writing patterns for a Roland T-8 \
    (six drum voices — kick, snare, clap, tom, closed hat, open hat — plus a TB-303-style monophonic bass). \
    Patterns are loops of 16th-note steps (length 1–32, normally 16 or 32). Write original patterns; never \
    transcribe existing songs.

    Notation (every lane must contain exactly `length` characters, spaces are allowed between groups of 4):
    - Drum lanes: `.` off, `x` hit, `X` loud, `o` soft, `g` ghost, `f` flam, `2`/`3`/`4` ratchet, `?` 50% chance.
    - accents: `a` accented step, `.` none (the T-8 accent applies to every voice on that step).
    - bass: exactly `length` space-separated tokens. `.` rest, `-` tie (hold previous note; only after a note or tie), \
    a note name with octave such as `D1`, `F#2`, `A#0` (C4 = MIDI 60; use roughly A0–C3), optional suffix `!` accent, \
    `~` slide into the next note (e.g. `G1!~`).
    - Closed and open hat must not both hit on the same step.

    Musical guidance: keep a strong, idiomatic foundation for the genre; leave space; use accents and slides \
    purposefully rather than everywhere; keep bass notes in the given key/scale unless the request is chromatic. \
    When editing an existing pattern, change what was asked and keep the rest recognizable.
    """

    static func userMessage(_ kind: AIRequestKind, context: AIContext) -> String {
        var parts: [String] = []
        switch kind {
        case .create(let prompt):
            parts.append("Create a new pattern: \(prompt)")
        case .edit(let instruction):
            parts.append("Edit the current pattern: \(instruction)")
        case .blend(let blend, let prompt):
            parts.append("""
            Create a genre-blend pattern: \(blend.label). Make it one coherent groove — choose the tempo, kick \
            placement, hat feel and bass style so both genres are audible in proportion — do not just overlay two patterns.
            """)
            let profile = blend.profile
            parts.append("Suggested tempo from the blend: \(Int(profile.bpm)) BPM, swing \(Int(profile.swing)).")
            if !prompt.isEmpty { parts.append("Additional direction: \(prompt)") }
        case .surprise:
            parts.append("Surprise me: create an unexpected but musical pattern\(context.genre.map { " rooted in \($0.displayName)" } ?? "").")
        case .variation(let slot):
            parts.append("Create variation \(slot.letter) (\(slot.title)) of the current pattern.")
        case .fromAudio(let analysis, let steps, let direction):
            parts.append("""
            Build a \(steps)-step 4/4 T-8 pattern (length must be exactly \(steps)) from this analysis of a recording the user uploaded. \
            You cannot hear the audio; the numbers below come from onset and pitch detection, so treat them as noisy evidence. \
            Keep hits where the evidence is strong and consistent with a coherent groove, drop isolated weak detections, \
            keep the detected tempo, and keep the bass in the detected key unless the pitches clearly say otherwise. \
            Capture the feel of the groove rather than copying every detection.

            \(analysis)
            """)
            if !direction.isEmpty { parts.append("Additional direction from the user: \(direction)") }
        }
        if let genre = context.genre { parts.append("Selected genre: \(genre.displayName).") }
        if let current = context.current {
            parts.append("Current pattern (JSON):\n" + Self.json(AIPatternPayload(from: current)))
        }
        if !context.referencePresets.isEmpty {
            let refs = context.referencePresets.prefix(3).map { "\($0.name) (\($0.primaryGenre?.displayName ?? "")):\n" + Self.json(AIPatternPayload(from: $0.main)) }
            parts.append("Reference patterns for style:\n" + refs.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func json(_ payload: AIPatternPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self)) ?? "{}"
    }
}

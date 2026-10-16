import Foundation

/// Lossless, line-preserving model of a Roland `.prm` text file.
///
/// Evidence: the open-source AIRA Pattern Editor reads and writes T-8 rhythm
/// and bass patterns as text lines of the form `KEY\t= value` and
/// `STEP n\t= FIELD=value FIELD=value ...`. Nothing else about the file is
/// assumed: every line is kept verbatim and only lines that are explicitly
/// modified are re-rendered, so an unmodified document serializes back to the
/// exact original bytes, including line endings, unknown keys and fields.
public struct PRMDocument: Hashable, Sendable {
    public enum Line: Hashable, Sendable {
        /// `KEY<separator>value`, e.g. `LENGTH\t= 16`. `prefix` is everything before the value.
        case setting(key: String, value: String, prefix: String, original: String?)
        /// `STEP n<separator>FIELD=v FIELD=v`.
        case step(number: Int, fields: [Field], prefix: String, original: String?)
        /// Anything else (blank lines, comments, unknown syntax). Always preserved.
        case other(String)
    }

    public struct Field: Hashable, Sendable {
        public var key: String
        public var value: String
        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notText
        case empty
        case binary

        public var errorDescription: String? {
            switch self {
            case .notText: "The file is not valid text."
            case .empty: "The file is empty."
            case .binary: "The file appears to be binary, not a T-8 .prm text file."
            }
        }
    }

    public var lines: [Line]
    public var lineEnding: String
    public var endsWithNewline: Bool
    public var hasBOM: Bool

    public init(lines: [Line], lineEnding: String = "\n", endsWithNewline: Bool = true, hasBOM: Bool = false) {
        self.lines = lines
        self.lineEnding = lineEnding
        self.endsWithNewline = endsWithNewline
        self.hasBOM = hasBOM
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> PRMDocument {
        guard !data.isEmpty else { throw ParseError.empty }
        if data.contains(0) { throw ParseError.binary }
        var bytes = data
        var bom = false
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true
            bytes = bytes.dropFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ParseError.notText }
        let crlf = text.contains("\r\n")
        let ending = crlf ? "\r\n" : "\n"
        var rawLines = text.components(separatedBy: ending)
        let trailing = rawLines.last == ""
        if trailing { rawLines.removeLast() }
        return PRMDocument(lines: rawLines.map(parseLine), lineEnding: ending, endsWithNewline: trailing, hasBOM: bom)
    }

    static func parseLine(_ raw: String) -> Line {
        guard let equals = raw.firstIndex(of: "=") else { return .other(raw) }
        let keyPart = raw[..<equals]
        let key = keyPart.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return .other(raw) }
        let afterEquals = raw.index(after: equals)
        let valueStart = raw[afterEquals...].firstIndex(where: { $0 != " " && $0 != "\t" }) ?? raw.endIndex
        let prefix = String(raw[..<valueStart])
        let value = String(raw[valueStart...])

        let keyTokens = key.split(separator: " ")
        if keyTokens.count == 2, keyTokens[0] == "STEP", let number = Int(keyTokens[1]) {
            var fields: [Field] = []
            for token in value.split(separator: " ", omittingEmptySubsequences: true) {
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return .other(raw) }
                fields.append(Field(String(parts[0]), String(parts[1])))
            }
            // Re-render check: if we cannot reproduce the line exactly, keep it opaque.
            let rendered = prefix + fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            guard rendered == raw else { return .other(raw) }
            return .step(number: number, fields: fields, prefix: prefix, original: raw)
        }
        if keyTokens.count == 1 {
            return .setting(key: key, value: value, prefix: prefix, original: raw)
        }
        return .other(raw)
    }

    // MARK: Serialization

    public func serialized() -> Data {
        var text = lines.map(Self.render).joined(separator: lineEnding)
        if endsWithNewline { text += lineEnding }
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: Array(text.utf8))
        return data
    }

    static func render(_ line: Line) -> String {
        switch line {
        case .setting(_, let value, let prefix, let original):
            return original ?? prefix + value
        case .step(_, let fields, let prefix, let original):
            return original ?? prefix + fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        case .other(let raw):
            return raw
        }
    }

    // MARK: Access

    public func setting(_ key: String) -> String? {
        for line in lines { if case .setting(let k, let v, _, _) = line, k == key { return v } }
        return nil
    }

    /// Updates an existing setting. Returns false if the key is not present
    /// (new keys are never invented).
    @discardableResult
    public mutating func setSetting(_ key: String, _ value: String) -> Bool {
        for index in lines.indices {
            if case .setting(let k, let old, let prefix, _) = lines[index], k == key {
                if old != value { lines[index] = .setting(key: k, value: value, prefix: prefix, original: nil) }
                return true
            }
        }
        return false
    }

    public var stepNumbers: [Int] {
        lines.compactMap { if case .step(let n, _, _, _) = $0 { return n } else { return nil } }
    }

    public func fields(step number: Int) -> [Field]? {
        for line in lines { if case .step(let n, let f, _, _) = line, n == number { return f } }
        return nil
    }

    public func field(_ key: String, step number: Int) -> String? {
        fields(step: number)?.first { $0.key == key }?.value
    }

    /// Sets field values on an existing step line. Unknown fields on the line
    /// are kept in place. Fields that do not exist on the line are not added.
    /// Returns the keys that could not be written.
    @discardableResult
    public mutating func setFields(step number: Int, _ values: [String: String]) -> [String] {
        for index in lines.indices {
            guard case .step(let n, var fields, let prefix, let original) = lines[index], n == number else { continue }
            var missing = Set(values.keys)
            var changed = false
            for f in fields.indices {
                if let newValue = values[fields[f].key] {
                    missing.remove(fields[f].key)
                    if fields[f].value != newValue {
                        fields[f].value = newValue
                        changed = true
                    }
                }
            }
            lines[index] = .step(number: n, fields: fields, prefix: prefix, original: changed ? nil : original)
            return missing.sorted()
        }
        return values.keys.sorted()
    }
}

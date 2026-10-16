import Foundation

/// Note-editing operations on one stem, with undo/redo.
/// Edits always produce `editedNotes`; the engine's original transcription is never changed.
public struct NoteEditor {
    public static func add(_ note: NoteEvent, to notes: [NoteEvent]) -> [NoteEvent] {
        (notes + [note]).sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    public static func delete(_ ids: Set<UUID>, from notes: [NoteEvent]) -> [NoteEvent] {
        notes.filter { !ids.contains($0.id) }
    }

    /// Moves notes by a time and pitch offset; pitches are clamped to 0...127 and times to >= 0.
    public static func move(_ ids: Set<UUID>, in notes: [NoteEvent], by seconds: Double, semitones: Int) -> [NoteEvent] {
        notes.map { n in
            guard ids.contains(n.id) else { return n }
            var m = n
            let shift = max(seconds, -n.start)
            m.start += shift
            m.end += shift
            m.pitch = min(127, max(0, n.pitch + semitones))
            return m
        }.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    public static func resize(_ ids: Set<UUID>, in notes: [NoteEvent], endBy seconds: Double, minimum: Double = 0.01) -> [NoteEvent] {
        notes.map { n in
            guard ids.contains(n.id) else { return n }
            var m = n
            m.end = max(n.start + minimum, n.end + seconds)
            return m
        }
    }

    public static func setVelocity(_ ids: Set<UUID>, in notes: [NoteEvent], to velocity: Int) -> [NoteEvent] {
        notes.map { n in
            guard ids.contains(n.id) else { return n }
            var m = n
            m.velocity = min(127, max(1, velocity))
            return m
        }
    }

    public static func setAccepted(_ ids: Set<UUID>, in notes: [NoteEvent], to accepted: Bool?) -> [NoteEvent] {
        notes.map { n in
            guard ids.contains(n.id) else { return n }
            var m = n
            m.accepted = accepted
            return m
        }
    }

    /// Bakes quantisation into the selected notes (an explicit, undoable edit).
    public static func quantize(_ ids: Set<UUID>, in notes: [NoteEvent], tempo: TempoMap, settings: QuantizeSettings) -> [NoteEvent] {
        var s = settings
        s.enabled = true
        let selected = notes.filter { ids.contains($0.id) }
        let q = Dictionary(uniqueKeysWithValues: Quantizer.apply(selected, tempo: tempo, settings: s).map { ($0.id, $0) })
        return notes.map { q[$0.id] ?? $0 }.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }
}

/// Undo/redo of whole-note-list snapshots per stem. Note lists are small, so
/// snapshots are simpler and safer than inverse operations.
public struct EditHistory {
    public struct Entry: Equatable {
        public var stemID: UUID
        public var before: [NoteEvent]?
        public var after: [NoteEvent]?
        public var label: String
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public var limit = 200

    public init() {}

    public mutating func record(stem: UUID, before: [NoteEvent]?, after: [NoteEvent]?, label: String) {
        undoStack.append(Entry(stemID: stem, before: before, after: after, label: label))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo() -> Entry? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append(e)
        return e
    }

    public mutating func redo() -> Entry? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append(e)
        return e
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
}

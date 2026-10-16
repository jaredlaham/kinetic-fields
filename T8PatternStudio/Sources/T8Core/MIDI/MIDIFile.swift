import Foundation

/// Minimal, complete Standard MIDI File (SMF) reader/writer for formats 0 and 1.
public struct MIDIFile: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
        case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
        case programChange(channel: UInt8, program: UInt8)
        case pitchBend(channel: UInt8, value: UInt16)
        case otherChannel(status: UInt8, data: [UInt8])
        case tempo(microsecondsPerQuarter: UInt32)
        case timeSignature(numerator: UInt8, denominatorPower: UInt8)
        case trackName(String)
        case endOfTrack
        case meta(type: UInt8, data: [UInt8])
        case sysex([UInt8])
    }

    public struct TimedEvent: Hashable, Sendable {
        /// Absolute time in ticks.
        public var tick: Int
        public var event: Event
        public init(tick: Int, event: Event) {
            self.tick = tick
            self.event = event
        }
    }

    public struct Track: Hashable, Sendable {
        public var events: [TimedEvent]
        public init(events: [TimedEvent] = []) { self.events = events }
        public var name: String? {
            for e in events { if case .trackName(let n) = e.event { return n } }
            return nil
        }
    }

    public var format: Int
    public var ticksPerQuarter: Int
    public var tracks: [Track]

    public init(format: Int = 1, ticksPerQuarter: Int = 480, tracks: [Track] = []) {
        self.format = format
        self.ticksPerQuarter = ticksPerQuarter
        self.tracks = tracks
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notAMIDIFile
        case unsupportedFormat(Int)
        case smpteTimingUnsupported
        case truncated
        case malformedEvent(offset: Int)

        public var errorDescription: String? {
            switch self {
            case .notAMIDIFile: "This is not a Standard MIDI File."
            case .unsupportedFormat(let f): "MIDI file format \(f) is not supported (only types 0 and 1)."
            case .smpteTimingUnsupported: "SMPTE-timed MIDI files are not supported."
            case .truncated: "The MIDI file is truncated."
            case .malformedEvent(let offset): "Malformed MIDI event at byte \(offset)."
            }
        }
    }

    /// Microseconds per quarter of the first tempo event (default 120 BPM).
    public var initialTempoBPM: Double {
        for track in tracks {
            for e in track.events.sorted(by: { $0.tick < $1.tick }) {
                if case .tempo(let us) = e.event, us > 0 { return 60_000_000.0 / Double(us) }
            }
        }
        return 120
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> MIDIFile {
        var reader = ByteReader(bytes: [UInt8](data))
        guard try reader.readASCII(4) == "MThd" else { throw ParseError.notAMIDIFile }
        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw ParseError.notAMIDIFile }
        let format = Int(try reader.readUInt16())
        let trackCount = Int(try reader.readUInt16())
        let division = try reader.readUInt16()
        try reader.skip(headerLength - 6)
        guard format == 0 || format == 1 else { throw ParseError.unsupportedFormat(format) }
        guard division & 0x8000 == 0 else { throw ParseError.smpteTimingUnsupported }

        var tracks: [Track] = []
        while tracks.count < trackCount, reader.remaining >= 8 {
            let chunkID = try reader.readASCII(4)
            let length = Int(try reader.readUInt32())
            guard reader.remaining >= length else { throw ParseError.truncated }
            let chunk = Array(reader.bytes[reader.offset..<(reader.offset + length)])
            try reader.skip(length)
            if chunkID == "MTrk" { tracks.append(try parseTrack(chunk)) }
        }
        guard tracks.count == trackCount else { throw ParseError.truncated }
        return MIDIFile(format: format, ticksPerQuarter: Int(division), tracks: tracks)
    }

    static func parseTrack(_ bytes: [UInt8]) throws -> Track {
        var reader = ByteReader(bytes: bytes)
        var events: [TimedEvent] = []
        var tick = 0
        var runningStatus: UInt8?
        while reader.remaining > 0 {
            tick += Int(try reader.readVariableLength())
            let eventOffset = reader.offset
            var status = try reader.peek()
            if status < 0x80 {
                guard let running = runningStatus else { throw ParseError.malformedEvent(offset: eventOffset) }
                status = running
            } else {
                _ = try reader.readByte()
            }
            switch status {
            case 0xFF:
                let type = try reader.readByte()
                let length = Int(try reader.readVariableLength())
                let data = try reader.readBytes(length)
                switch type {
                case 0x51 where data.count == 3:
                    events.append(.init(tick: tick, event: .tempo(microsecondsPerQuarter: UInt32(data[0]) << 16 | UInt32(data[1]) << 8 | UInt32(data[2]))))
                case 0x58 where data.count >= 2:
                    events.append(.init(tick: tick, event: .timeSignature(numerator: data[0], denominatorPower: data[1])))
                case 0x03:
                    events.append(.init(tick: tick, event: .trackName(String(decoding: data, as: UTF8.self))))
                case 0x2F:
                    events.append(.init(tick: tick, event: .endOfTrack))
                    return Track(events: events)
                default:
                    events.append(.init(tick: tick, event: .meta(type: type, data: data)))
                }
                runningStatus = nil
            case 0xF0, 0xF7:
                let length = Int(try reader.readVariableLength())
                events.append(.init(tick: tick, event: .sysex(try reader.readBytes(length))))
                runningStatus = nil
            default:
                guard status >= 0x80 && status < 0xF0 else { throw ParseError.malformedEvent(offset: eventOffset) }
                runningStatus = status
                let channel = status & 0x0F
                let kind = status & 0xF0
                let dataLength = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                let data = try reader.readBytes(dataLength)
                guard data.allSatisfy({ $0 < 0x80 }) else { throw ParseError.malformedEvent(offset: eventOffset) }
                switch kind {
                case 0x90 where data[1] > 0: events.append(.init(tick: tick, event: .noteOn(channel: channel, note: data[0], velocity: data[1])))
                case 0x90, 0x80: events.append(.init(tick: tick, event: .noteOff(channel: channel, note: data[0], velocity: data[1])))
                case 0xB0: events.append(.init(tick: tick, event: .controlChange(channel: channel, controller: data[0], value: data[1])))
                case 0xC0: events.append(.init(tick: tick, event: .programChange(channel: channel, program: data[0])))
                case 0xE0: events.append(.init(tick: tick, event: .pitchBend(channel: channel, value: UInt16(data[0]) | UInt16(data[1]) << 7)))
                default: events.append(.init(tick: tick, event: .otherChannel(status: status, data: data)))
                }
            }
        }
        return Track(events: events)
    }

    // MARK: Writing

    public func serialized() -> Data {
        var out: [UInt8] = Array("MThd".utf8)
        out += UInt32(6).bigEndianBytes
        out += UInt16(format).bigEndianBytes
        out += UInt16(tracks.count).bigEndianBytes
        out += UInt16(ticksPerQuarter).bigEndianBytes
        for track in tracks {
            var body: [UInt8] = []
            var lastTick = 0
            // Stable sort: note-offs before note-ons at the same tick avoids stuck/clipped notes.
            let sorted = track.events.enumerated().sorted { lhs, rhs in
                if lhs.element.tick != rhs.element.tick { return lhs.element.tick < rhs.element.tick }
                let lp = Self.sortPriority(lhs.element.event), rp = Self.sortPriority(rhs.element.event)
                return lp != rp ? lp < rp : lhs.offset < rhs.offset
            }.map(\.element)
            for timed in sorted {
                if case .endOfTrack = timed.event { continue }
                body += Self.variableLength(UInt32(max(0, timed.tick - lastTick)))
                lastTick = max(lastTick, timed.tick)
                body += Self.encode(timed.event)
            }
            let endTick = max(lastTick, track.events.map(\.tick).max() ?? 0)
            body += Self.variableLength(UInt32(endTick - lastTick))
            body += [0xFF, 0x2F, 0x00]
            out += Array("MTrk".utf8)
            out += UInt32(body.count).bigEndianBytes
            out += body
        }
        return Data(out)
    }

    static func sortPriority(_ event: Event) -> Int {
        switch event {
        case .trackName, .tempo, .timeSignature, .meta: 0
        case .noteOff: 1
        case .controlChange, .programChange, .pitchBend, .otherChannel, .sysex: 2
        case .noteOn: 3
        case .endOfTrack: 4
        }
    }

    static func encode(_ event: Event) -> [UInt8] {
        switch event {
        case .noteOn(let c, let n, let v): [0x90 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case .noteOff(let c, let n, let v): [0x80 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case .controlChange(let c, let cc, let v): [0xB0 | (c & 0x0F), cc & 0x7F, v & 0x7F]
        case .programChange(let c, let p): [0xC0 | (c & 0x0F), p & 0x7F]
        case .pitchBend(let c, let v): [0xE0 | (c & 0x0F), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
        case .otherChannel(let status, let data): [status] + data
        case .tempo(let us): [0xFF, 0x51, 0x03, UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]
        case .timeSignature(let n, let d): [0xFF, 0x58, 0x04, n, d, 24, 8]
        case .trackName(let name):
            { let bytes = Array(name.utf8); return [0xFF, 0x03] + variableLength(UInt32(bytes.count)) + bytes }()
        case .endOfTrack: [0xFF, 0x2F, 0x00]
        case .meta(let type, let data): [0xFF, type] + variableLength(UInt32(data.count)) + data
        case .sysex(let data): [0xF0] + variableLength(UInt32(data.count)) + data
        }
    }

    static func variableLength(_ value: UInt32) -> [UInt8] {
        var buffer: [UInt8] = [UInt8(value & 0x7F)]
        var v = value >> 7
        while v > 0 {
            buffer.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return buffer
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    init(bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    func peek() throws -> UInt8 {
        guard offset < bytes.count else { throw MIDIFile.ParseError.truncated }
        return bytes[offset]
    }
    mutating func readByte() throws -> UInt8 {
        let b = try peek()
        offset += 1
        return b
    }
    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw MIDIFile.ParseError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
    mutating func skip(_ count: Int) throws { _ = try readBytes(count) }
    mutating func readUInt16() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    mutating func readASCII(_ count: Int) throws -> String {
        String(decoding: try readBytes(count), as: UTF8.self)
    }
    mutating func readVariableLength() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = (value << 7) | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw MIDIFile.ParseError.malformedEvent(offset: offset)
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}

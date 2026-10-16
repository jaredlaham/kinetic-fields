import Foundation

/// Builds a small Standard MIDI File in memory for the app's MIDI preview
/// (played by AVAudioSequencer). Exports go through the engine, which
/// validates its files; this writer only feeds the local preview.
public enum PreviewMIDI {
    public struct Part {
        public var channel: Int  // 0...15
        public var notes: [NoteEvent]
        public init(channel: Int, notes: [NoteEvent]) {
            self.channel = channel
            self.notes = notes
        }
    }

    public static let ticksPerQuarter = 960

    /// Type 1: a tempo track, one track per part, then a metronome track (channel 10) when requested.
    public static func file(parts: [Part], bpm: Double, beatsPerBar: Int, downbeat: Double, metronomeUntil: Double?) -> Data {
        var tracks: [[UInt8]] = [tempoTrack(bpm: bpm, beatsPerBar: beatsPerBar)]
        for part in parts { tracks.append(track(notes: part.notes, channel: part.channel, bpm: bpm)) }
        if let until = metronomeUntil {
            var clicks: [NoteEvent] = []
            let beat = 60.0 / bpm
            var k = Int(ceil(-downbeat / beat))
            while downbeat + Double(k) * beat < until {
                let t = downbeat + Double(k) * beat
                let bar = k % beatsPerBar == 0
                clicks.append(NoteEvent(pitch: bar ? 76 : 77, start: t, end: t + 0.05, velocity: bar ? 120 : 90))
                k += 1
            }
            tracks.append(track(notes: clicks, channel: 9, bpm: bpm))
        }
        var data = Data("MThd".utf8)
        data.append(be32(6))
        data.append(be16(1))
        data.append(be16(UInt16(tracks.count)))
        data.append(be16(UInt16(ticksPerQuarter)))
        for t in tracks {
            data.append(Data("MTrk".utf8))
            data.append(be32(UInt32(t.count)))
            data.append(contentsOf: t)
        }
        return data
    }

    static func ticks(_ seconds: Double, bpm: Double) -> Int {
        max(0, Int((seconds * bpm / 60.0 * Double(ticksPerQuarter)).rounded()))
    }

    static func tempoTrack(bpm: Double, beatsPerBar: Int) -> [UInt8] {
        let usPerQuarter = UInt32((60_000_000.0 / bpm).rounded())
        var t: [UInt8] = [0x00, 0xFF, 0x51, 0x03, UInt8(usPerQuarter >> 16 & 0xFF), UInt8(usPerQuarter >> 8 & 0xFF), UInt8(usPerQuarter & 0xFF)]
        t += [0x00, 0xFF, 0x58, 0x04, UInt8(max(1, min(99, beatsPerBar))), 0x02, 0x18, 0x08]
        t += [0x00, 0xFF, 0x2F, 0x00]
        return t
    }

    static func track(notes: [NoteEvent], channel: Int, bpm: Double) -> [UInt8] {
        // (tick, order, bytes): note-offs sort before note-ons at the same tick.
        var events: [(Int, Int, [UInt8])] = []
        let ch = UInt8(max(0, min(15, channel)))
        for n in notes {
            let p = UInt8(max(0, min(127, n.pitch)))
            let s = ticks(n.start, bpm: bpm)
            let e = max(s + 1, ticks(n.end, bpm: bpm))
            events.append((s, 1, [0x90 | ch, p, UInt8(max(1, min(127, n.velocity)))]))
            events.append((e, 0, [0x80 | ch, p, 64]))
        }
        events.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var out: [UInt8] = []
        var last = 0
        for (tick, _, bytes) in events {
            out += varLen(tick - last)
            out += bytes
            last = tick
        }
        out += [0x00, 0xFF, 0x2F, 0x00]
        return out
    }

    static func varLen(_ value: Int) -> [UInt8] {
        var v = UInt32(max(0, value))
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }

    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
}

import CoreMIDI
import Foundation
import StemCore

struct MIDIDestination: Identifiable, Hashable, Sendable {
    var id: MIDIUniqueID
    var name: String
    var endpoint: MIDIEndpointRef
    var isT8: Bool { name.uppercased().contains("T-8") || name.uppercased().contains("T8") }
}

/// T-8 Mode B: plays a converted pattern live into the T-8 over CoreMIDI
/// (rhythm and bass channels, optional MIDI clock and Start/Stop).
///
/// This is playback, not storage. Whether the T-8 records incoming notes into
/// its sequencer is not documented by Roland and has not been tested, so the
/// app never claims a pattern was saved on the device.
final class MIDIOutput: @unchecked Sendable {
    struct TimedMessage {
        var seconds: Double
        var bytes: [UInt8]
    }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private(set) var setupError: String?
    private let lock = NSLock()
    private var activeDestination: MIDIEndpointRef = 0
    private var activeChannels: [UInt8] = []
    private var stopTimer: DispatchWorkItem?

    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init() {
        var status = MIDIClientCreateWithBlock("Kinetic Stem Studio" as CFString, &client) { _ in }
        if status != noErr { setupError = "CoreMIDI client error \(status)" }
        status = MIDIOutputPortCreate(client, "Output" as CFString, &port)
        if status != noErr { setupError = "CoreMIDI port error \(status)" }
    }

    func destinations() -> [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            return MIDIDestination(id: uid, name: (name?.takeRetainedValue() as String?) ?? "MIDI Destination \(index + 1)",
                                   endpoint: endpoint)
        }
    }

    /// Builds the message list for converted T-8 segments, played back to back.
    static func messages(for segments: [T8ConvertResponse.Segment], bpm: Double, rhythmChannel: Int, bassChannel: Int,
                         sendClock: Bool, loops: Int) -> (messages: [TimedMessage], length: Double) {
        let step = 60.0 / bpm / 4.0
        let rch = UInt8(max(1, min(16, rhythmChannel)) - 1)
        let bch = UInt8(max(1, min(16, bassChannel)) - 1)
        let notes: [String: UInt8] = ["BD": 36, "SD": 38, "HC": 50, "TOM": 47, "CH": 42, "OH": 46]
        var out: [TimedMessage] = []
        var t0 = 0.0
        for _ in 0..<max(1, loops) {
            for seg in segments {
                for (voice, steps) in seg.drums {
                    guard let note = notes[voice] else { continue }
                    for (i, s) in steps.enumerated() where s.count >= 2 && s[0] != 0 {
                        let accent = s.count > 2 && s[2] != 0
                        let vel = UInt8(max(1, min(127, accent ? max(s[1], 112) : s[1])))
                        let t = t0 + Double(i) * step
                        out.append(TimedMessage(seconds: t, bytes: [0x90 | rch, note, vel]))
                        out.append(TimedMessage(seconds: t + step * 0.5, bytes: [0x80 | rch, note, 0]))
                    }
                }
                // Bass: [note or nil, tie, accent, slide]. Tied steps continue the note before them
                // (same layout as engine/kstem/export/t8.py).
                var i = 0
                while i < seg.bass.count {
                    let cell = seg.bass[i]
                    let tied = cell.count > 1 && (cell[1] ?? 0) != 0
                    guard let first = cell.first, let n = first, !tied else { i += 1; continue }
                    var len = 1
                    while i + len < seg.bass.count, seg.bass[i + len].count > 1, (seg.bass[i + len][1] ?? 0) != 0 { len += 1 }
                    let slide = cell.count > 3 && (cell[3] ?? 0) != 0
                    let accent = cell.count > 2 && (cell[2] ?? 0) != 0
                    let t = t0 + Double(i) * step
                    // A slide overlaps the next note so the T-8 glides (legato), as in the T-8 manual.
                    let end = slide ? t + (Double(len) + 0.25) * step : (len > 1 ? t + Double(len) * step : t + step * 0.5)
                    let note = UInt8(max(0, min(127, n)))
                    out.append(TimedMessage(seconds: t, bytes: [0x90 | bch, note, accent ? 120 : 96]))
                    out.append(TimedMessage(seconds: end, bytes: [0x80 | bch, note, 0]))
                    i += len
                }
                t0 += Double(seg.steps) * step
            }
        }
        if sendClock {
            let tick = 60.0 / bpm / 24.0
            out.append(TimedMessage(seconds: -0.001, bytes: [0xFA]))
            var t = 0.0
            while t < t0 {
                out.append(TimedMessage(seconds: t, bytes: [0xF8]))
                t += tick
            }
            out.append(TimedMessage(seconds: t0, bytes: [0xFC]))
        }
        out.sort { $0.seconds < $1.seconds }
        return (out, t0)
    }

    /// Schedules all messages with CoreMIDI timestamps, starting shortly from now.
    func play(_ messages: [TimedMessage], length: Double, to destination: MIDIDestination, channels: [Int]) {
        stop()
        let start = mach_absolute_time() + hostTicks(0.15)
        lock.lock()
        activeDestination = destination.endpoint
        activeChannels = channels.map { UInt8(max(1, min(16, $0)) - 1) }
        lock.unlock()
        for m in messages {
            send(m.bytes, at: start + hostTicks(max(0, m.seconds + 0.001)), to: destination.endpoint)
        }
        let work = DispatchWorkItem { [weak self] in self?.lock.withLock { self?.activeDestination = 0 } }
        stopTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.5, execute: work)
    }

    var isPlaying: Bool { lock.withLock { activeDestination != 0 } }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        let (dest, channels) = lock.withLock { () -> (MIDIEndpointRef, [UInt8]) in
            let d = activeDestination
            activeDestination = 0
            return (d, activeChannels)
        }
        guard dest != 0 else { return }
        MIDIFlushOutput(dest)  // drops everything still scheduled
        send([0xFC], at: 0, to: dest)
        for ch in channels { send([0xB0 | ch, 123, 0], at: 0, to: dest) }  // All Notes Off
    }

    private func hostTicks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Sends one MIDI 1.0 message as a Universal MIDI Packet.
    private func send(_ bytes: [UInt8], at time: MIDITimeStamp, to destination: MIDIEndpointRef) {
        guard destination != 0, let status = bytes.first else { return }
        let word: UInt32
        if status >= 0xF0 {
            word = (0x1 << 28) | (UInt32(status) << 16)  // system real-time
        } else {
            word = (0x2 << 28) | (UInt32(status) << 16) | (UInt32(bytes.count > 1 ? bytes[1] : 0) << 8)
                | UInt32(bytes.count > 2 ? bytes[2] : 0)
        }
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { ptr in
            let packet = MIDIEventListInit(ptr, ._1_0)
            _ = MIDIEventListAdd(ptr, MemoryLayout<MIDIEventList>.size, packet, time, 1, [word])
            MIDISendEventList(port, destination, ptr)
        }
    }
}

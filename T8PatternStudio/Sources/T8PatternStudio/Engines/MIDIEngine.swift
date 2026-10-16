import CoreMIDI
import Foundation
import T8Core

struct MIDIDestination: Identifiable, Hashable, Sendable {
    var id: MIDIUniqueID
    var name: String
    var endpoint: MIDIEndpointRef
    var isT8: Bool { name.uppercased().contains("T-8") || name.uppercased().contains("T8") }
}

/// CoreMIDI output for playing patterns through the T-8 over USB.
///
/// This is *playback*, not storage: notes are sent live to the T-8's rhythm
/// and bass channels. Nothing is written to the T-8's pattern memory.
///
/// Events are scheduled ahead with CoreMIDI timestamps from a dedicated
/// high-priority thread, so timing does not depend on the UI. The app never
/// routes MIDI input to output, which avoids feedback loops.
final class MIDIEngine: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private let lock = NSLock()
    private var setupError: String?

    // Playback state (guarded by lock).
    private var pattern: Pattern?
    private var events: [ScheduledEvent] = []
    private var destination: MIDIEndpointRef = 0
    private var rhythmChannel: UInt8 = 9
    private var bassChannel: UInt8 = 1
    private var playing = false
    private var looping = true
    private var startHostTime: UInt64 = 0
    private var scheduledUntilStep: Double = 0
    private var pendingNoteOffs: [(time: UInt64, channel: UInt8, note: UInt8)] = []
    private var rng = SeededRandom(seed: 0xD1CE)
    private var thread: Thread?

    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Called on the main actor when MIDI devices change.
    var onDevicesChanged: (@MainActor @Sendable () -> Void)?

    init() {
        let status = MIDIClientCreateWithBlock("T-8 Pattern Studio" as CFString, &client, Self.makeNotifyBlock(engine: self))
        if status != noErr { setupError = "CoreMIDI client error \(status)" }
        let portStatus = MIDIOutputPortCreate(client, "Output" as CFString, &outputPort)
        if portStatus != noErr { setupError = "CoreMIDI port error \(portStatus)" }
    }

    private nonisolated static func makeNotifyBlock(engine: MIDIEngine) -> MIDINotifyBlock {
        { [weak engine] _ in
            guard let callback = engine?.onDevicesChanged else { return }
            Task { @MainActor in callback() }
        }
    }

    var errorDescription: String? { setupError }

    func destinations() -> [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            return MIDIDestination(id: uid, name: (name?.takeRetainedValue() as String?) ?? "MIDI Destination \(index + 1)", endpoint: endpoint)
        }
    }

    /// True when a T-8 shows up as a MIDI source or destination.
    func isT8Connected() -> Bool {
        if destinations().contains(where: \.isT8) { return true }
        for index in 0..<MIDIGetNumberOfSources() {
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(index), kMIDIPropertyDisplayName, &name)
            if let n = name?.takeRetainedValue() as String?, n.uppercased().contains("T-8") { return true }
        }
        return false
    }

    // MARK: Playback

    func play(pattern: Pattern, to destination: MIDIDestination, rhythmChannel: UInt8, bassChannel: UInt8, loop: Bool) {
        stop()
        lock.lock()
        self.pattern = pattern
        self.events = PlaybackScheduler.events(for: pattern)
        self.destination = destination.endpoint
        self.rhythmChannel = rhythmChannel
        self.bassChannel = bassChannel
        self.looping = loop
        self.startHostTime = mach_absolute_time() + hostTicks(seconds: 0.05)
        self.scheduledUntilStep = 0
        self.playing = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.schedulerLoop() }
        thread.qualityOfService = .userInteractive
        thread.name = "T8 MIDI Scheduler"
        self.thread = thread
        thread.start()
    }

    func update(pattern: Pattern) {
        lock.lock()
        guard playing, let old = self.pattern else { lock.unlock(); return }
        // Keep the musical position: re-anchor so the current step continues.
        let elapsed = stepsElapsed(now: mach_absolute_time(), pattern: old)
        let oldLength = Double(old.length)
        let loopsDone = (elapsed / oldLength).rounded(.down)
        self.pattern = pattern
        self.events = PlaybackScheduler.events(for: pattern)
        let offsetInLoop = elapsed - loopsDone * oldLength
        let alreadyAhead = max(0, scheduledUntilStep - elapsed)
        startHostTime = mach_absolute_time() - hostTicks(seconds: offsetInLoop * pattern.stepDuration)
        scheduledUntilStep = offsetInLoop + alreadyAhead
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let wasPlaying = playing
        playing = false
        let destination = self.destination
        let channels = [rhythmChannel, bassChannel]
        let offs = pendingNoteOffs
        pendingNoteOffs.removeAll()
        lock.unlock()
        thread?.cancel()
        thread = nil
        guard wasPlaying, destination != 0 else { return }
        for off in offs { send([0x80 | off.channel, off.note, 0], at: 0) }
        for channel in channels {
            send([0xB0 | channel, 123, 0], at: 0) // All Notes Off
        }
    }

    var currentStep: Int {
        lock.lock(); defer { lock.unlock() }
        guard playing, let pattern else { return 0 }
        let now = mach_absolute_time()
        guard now >= startHostTime else { return 0 }
        return Int(stepsElapsed(now: now, pattern: pattern)) % max(pattern.length, 1)
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    private func schedulerLoop() {
        let lookahead = 0.12 // seconds
        while !Thread.current.isCancelled {
            lock.lock()
            guard playing, let pattern else { lock.unlock(); break }
            let now = mach_absolute_time()
            let horizonStep = stepsElapsed(now: now, pattern: pattern) + lookahead / pattern.stepDuration
            let length = Double(pattern.length)
            var toSend: [(UInt64, [UInt8])] = []

            // Release note-offs that fall inside the horizon.
            let horizonTime = now + hostTicks(seconds: lookahead)
            pendingNoteOffs.removeAll { off in
                if off.time <= horizonTime { toSend.append((off.time, [0x80 | off.channel, off.note, 0])); return true }
                return false
            }

            while scheduledUntilStep < horizonStep {
                let loopIndex = (scheduledUntilStep / length).rounded(.down)
                if !looping && loopIndex >= 1 { playing = false; break }
                let loopStart = loopIndex * length
                let windowStart = scheduledUntilStep - loopStart
                let windowEnd = min(horizonStep - loopStart, length)
                for event in events where event.position >= windowStart && event.position < windowEnd {
                    if event.probability < 100 && !rng.chance(Double(event.probability) / 100) { continue }
                    let time = startHostTime + hostTicks(seconds: (loopStart + event.position) * pattern.stepDuration)
                    let offTime = time + hostTicks(seconds: event.duration * pattern.stepDuration)
                    switch event.kind {
                    case .drum(let voice, let velocity):
                        let note = HardwareCapabilities.rhythmNoteMap[voice] ?? 36
                        toSend.append((time, [0x90 | rhythmChannel, note, velocity]))
                        pendingNoteOffs.append((offTime, rhythmChannel, note))
                    case .bass(let note, let velocity, _):
                        toSend.append((time, [0x90 | bassChannel, UInt8(note), velocity]))
                        pendingNoteOffs.append((offTime, bassChannel, UInt8(note)))
                    }
                }
                scheduledUntilStep = loopStart + windowEnd
            }
            lock.unlock()

            for (time, bytes) in toSend.sorted(by: { $0.0 < $1.0 }) { send(bytes, at: time) }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func stepsElapsed(now: UInt64, pattern: Pattern) -> Double {
        guard now > startHostTime else { return 0 }
        return seconds(hostTicks: now - startHostTime) / pattern.stepDuration
    }

    private func hostTicks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    private func seconds(hostTicks: UInt64) -> Double {
        Double(hostTicks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Sends one MIDI 1.0 channel message as a Universal MIDI Packet.
    private func send(_ bytes: [UInt8], at time: MIDITimeStamp) {
        lock.lock()
        let destination = self.destination
        lock.unlock()
        guard destination != 0, bytes.count >= 2 else { return }
        let word: UInt32 = (0x2 << 28) | (UInt32(bytes[0]) << 16) | (UInt32(bytes[1]) << 8) | UInt32(bytes.count > 2 ? bytes[2] : 0)
        let port = outputPort
        var eventList = MIDIEventList()
        withUnsafeMutablePointer(to: &eventList) { list in
            let packet = MIDIEventListInit(list, ._1_0)
            _ = MIDIEventListAdd(list, MemoryLayout<MIDIEventList>.size, packet, time, 1, [word])
            MIDISendEventList(port, destination, list)
        }
    }
}

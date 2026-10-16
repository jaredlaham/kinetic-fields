import Foundation

/// Which MIDI notes map to which drum voice on import.
public struct DrumNoteMapping: Hashable, Sendable {
    public var name: String
    public var notes: [UInt8: DrumVoice]

    /// The T-8's own transmit and receive notes (from the MIDI implementation chart).
    public static let rolandT8: DrumNoteMapping = {
        var notes: [UInt8: DrumVoice] = [:]
        for (voice, note) in HardwareCapabilities.rhythmNoteMap { notes[note] = voice }
        for (note, voice) in HardwareCapabilities.rhythmAlternateReceiveNotes { notes[note] = voice }
        return DrumNoteMapping(name: "Roland T-8", notes: notes)
    }()

    /// General MIDI percussion, folded onto the six T-8 voices.
    public static let generalMIDI = DrumNoteMapping(name: "General MIDI", notes: [
        35: .kick, 36: .kick,
        37: .snare, 38: .snare, 40: .snare,
        39: .clap,
        41: .tom, 43: .tom, 45: .tom, 47: .tom, 48: .tom, 50: .tom,
        42: .closedHat, 44: .closedHat, 54: .closedHat, 70: .closedHat,
        46: .openHat, 49: .openHat, 51: .openHat, 57: .openHat,
    ])

    public static let all = [rolandT8, generalMIDI]
}

public struct MIDIImportOptions: Hashable, Sendable {
    /// Channels (0-based) treated as drums. Default: channel 10 (index 9).
    public var drumChannels: Set<UInt8> = [9]
    /// Channel (0-based) treated as bass, or nil to take the first non-drum channel with notes.
    public var bassChannel: UInt8? = nil
    public var drumMapping: DrumNoteMapping = .rolandT8
    /// Start of the region to import, in bars.
    public var startBar: Int = 0
    /// Maximum steps to import (16 = 1 bar, 32 = 2 bars).
    public var maxSteps: Int = 32
    /// 0...1: how far an off-grid note may be from a 16th line and still be placed (fraction of a step).
    public var quantizeTolerance: Double = 0.5
    public init() {}
}

public struct MIDIImportResult: Sendable {
    public var pattern: Pattern
    public var warnings: [String]
    public var detectedChannels: [UInt8: Int]
    public var droppedNoteCount: Int
}

/// Converts Standard MIDI Files into the internal pattern model.
public enum MIDIFileImporter {
    struct NoteSpan {
        var channel: UInt8
        var note: UInt8
        var velocity: UInt8
        var start: Int
        var end: Int
    }

    public static func importPattern(_ file: MIDIFile, name: String, options: MIDIImportOptions = MIDIImportOptions()) -> MIDIImportResult {
        var warnings: [String] = []
        let tpq = file.ticksPerQuarter
        let ticksPerStep = Double(tpq) / 4.0
        let offsetTicks = options.startBar * tpq * 4

        // Pair note on/off events.
        var spans: [NoteSpan] = []
        var channelCounts: [UInt8: Int] = [:]
        var unsupported = Set<String>()
        var timeSignature = TimeSignature.fourFour
        for track in file.tracks {
            var open: [UInt16: [(start: Int, velocity: UInt8)]] = [:]
            for timed in track.events.sorted(by: { $0.tick < $1.tick }) {
                switch timed.event {
                case .noteOn(let ch, let note, let vel):
                    open[UInt16(ch) << 8 | UInt16(note), default: []].append((timed.tick, vel))
                    channelCounts[ch, default: 0] += 1
                case .noteOff(let ch, let note, _):
                    let key = UInt16(ch) << 8 | UInt16(note)
                    if var stack = open[key], !stack.isEmpty {
                        let begin = stack.removeFirst()
                        open[key] = stack
                        spans.append(NoteSpan(channel: ch, note: note, velocity: begin.velocity, start: begin.start, end: timed.tick))
                    }
                case .timeSignature(let n, let d):
                    timeSignature = TimeSignature(Int(n), 1 << Int(d))
                case .pitchBend: unsupported.insert("pitch bend")
                case .controlChange: unsupported.insert("control changes")
                case .programChange: unsupported.insert("program changes")
                case .sysex: unsupported.insert("SysEx")
                default: break
                }
            }
            for (key, stack) in open {
                for begin in stack {
                    spans.append(NoteSpan(channel: UInt8(key >> 8), note: UInt8(key & 0xFF), velocity: begin.velocity, start: begin.start, end: begin.start + Int(ticksPerStep)))
                }
            }
        }
        if !unsupported.isEmpty {
            warnings.append("Ignored events the T-8 pattern cannot store: \(unsupported.sorted().joined(separator: ", ")).")
        }
        if timeSignature != .fourFour {
            warnings.append("Time signature \(timeSignature) was imported onto the T-8's 16th-note grid.")
        }

        let bassChannel = options.bassChannel ?? channelCounts.keys.filter { !options.drumChannels.contains($0) }.sorted().first
        let relevant = spans.map { span -> NoteSpan in
            var s = span
            s.start -= offsetTicks
            s.end -= offsetTicks
            return s
        }.filter { $0.start >= -Int(ticksPerStep / 2) }

        // Pattern length = last note rounded up to whole bars (max 32 steps).
        let lastTick = relevant.map(\.start).max() ?? 0
        let lastStep = Int((Double(lastTick) / ticksPerStep).rounded())
        let length = min(options.maxSteps, max(16, ((lastStep / 16) + 1) * 16), Pattern.maxSteps)

        var pattern = Pattern(name: name, bpm: min(max(file.initialTempoBPM.rounded(), 40), 300), length: length)
        var dropped = 0
        var offGrid = 0
        var beyond = 0
        var unmapped = Set<UInt8>()
        var polyphonic = 0

        func step(for tick: Int) -> Int? {
            let exact = Double(tick) / ticksPerStep
            let nearest = exact.rounded()
            if abs(exact - nearest) > options.quantizeTolerance { return nil }
            if abs(exact - nearest) > 0.1 { offGrid += 1 }
            return Int(nearest)
        }

        // Drums.
        for span in relevant where options.drumChannels.contains(span.channel) {
            guard let voice = options.drumMapping.notes[span.note] else {
                unmapped.insert(span.note)
                dropped += 1
                continue
            }
            guard let s = step(for: span.start) else { dropped += 1; continue }
            guard s < length else { beyond += 1; dropped += 1; continue }
            let velocity = max(1, min(10, Int((Double(span.velocity) / 127.0 * 10).rounded())))
            if let existing = pattern.drums[voice, s], existing.velocity >= velocity { continue }
            pattern.drums[voice, s] = DrumHit(velocity: velocity)
            if span.velocity >= 120 { pattern.drums.accents[s] = true }
        }
        for s in 0..<length where pattern.drums[.closedHat, s] != nil && pattern.drums[.openHat, s] != nil {
            pattern.drums[.closedHat, s] = nil
        }

        // Bass: monophonic, highest-velocity then lowest note wins per step.
        if let bassChannel {
            let bassSpans = relevant.filter { $0.channel == bassChannel }.sorted { $0.start < $1.start }
            var byStep: [Int: NoteSpan] = [:]
            for span in bassSpans {
                guard let s = step(for: span.start) else { dropped += 1; continue }
                guard s < length else { beyond += 1; dropped += 1; continue }
                if let existing = byStep[s] {
                    polyphonic += 1
                    if span.note < existing.note { byStep[s] = span }
                } else {
                    byStep[s] = span
                }
            }
            let ordered = byStep.keys.sorted()
            for (index, s) in ordered.enumerated() {
                let span = byStep[s]!
                var note = Int(span.note)
                while note < HardwareCapabilities.bassNoteRange.lowerBound { note += 12 }
                while note > HardwareCapabilities.bassNoteRange.upperBound { note -= 12 }
                let nextStart = index + 1 < ordered.count ? ordered[index + 1] : length
                let endStep = Int((Double(span.end) / ticksPerStep).rounded())
                // Overlap into the next note = legato = slide (heuristic).
                let overlapsNext = index + 1 < ordered.count && span.end > byStep[nextStart]!.start
                pattern.bass[s] = .note(note, accent: span.velocity >= 110, slide: overlapsNext)
                let holdUntil = min(endStep, nextStart, length)
                if holdUntil > s + 1 {
                    for t in (s + 1)..<holdUntil { pattern.bass[t] = BassStep(kind: .tie, note: note) }
                }
            }
            pattern.bass.repairTies()
            if let root = ordered.first.map({ byStep[$0]!.note }) {
                pattern.key = PitchClass(rawValue: Int(root) % 12)!
            }
        } else {
            warnings.append("No bass channel found; only drums were imported.")
        }

        if !unmapped.isEmpty {
            warnings.append("Unmapped drum notes ignored: \(unmapped.sorted().map(String.init).joined(separator: ", ")). Try the \(options.drumMapping.name == "General MIDI" ? "Roland T-8" : "General MIDI") mapping.")
        }
        if offGrid > 0 { warnings.append("\(offGrid) notes were quantized to the nearest 16th.") }
        if beyond > 0 { warnings.append("\(beyond) notes beyond \(length) steps were dropped (the T-8 holds up to 32 steps).") }
        if polyphonic > 0 { warnings.append("\(polyphonic) overlapping bass notes were reduced to a single line.") }
        if spans.isEmpty { warnings.append("The file contains no notes.") }

        return MIDIImportResult(pattern: pattern, warnings: warnings, detectedChannels: channelCounts, droppedNoteCount: dropped)
    }
}

public struct MIDIExportOptions: Hashable, Sendable {
    /// 0-based channels. Defaults follow the T-8 (rhythm 10, bass 2).
    public var drumChannel: UInt8 = 9
    public var bassChannel: UInt8 = 1
    public var ticksPerQuarter = 480
    public var loops = 1
    public var applySwing = true
    public var drumNoteMap: [DrumVoice: UInt8] = HardwareCapabilities.rhythmNoteMap
    public init() {}
}

/// Writes patterns as Type 1 Standard MIDI Files (tempo, drums, bass tracks).
public enum MIDIFileExporter {
    public static func export(_ pattern: Pattern, options: MIDIExportOptions = MIDIExportOptions()) -> MIDIFile {
        let events = PlaybackScheduler.events(for: pattern, loops: options.loops, applySwing: options.applySwing)
        let tpq = options.ticksPerQuarter
        let ticksPerStep = Double(tpq) / 4.0
        func tick(_ stepPosition: Double) -> Int { Int((stepPosition * ticksPerStep).rounded()) }

        var conductor = MIDIFile.Track(events: [
            .init(tick: 0, event: .trackName(pattern.name)),
            .init(tick: 0, event: .tempo(microsecondsPerQuarter: UInt32((60_000_000.0 / pattern.bpm).rounded()))),
            .init(tick: 0, event: .timeSignature(numerator: UInt8(pattern.timeSignature.numerator), denominatorPower: UInt8(log2(Double(pattern.timeSignature.denominator))))),
        ])
        var drums = MIDIFile.Track(events: [.init(tick: 0, event: .trackName("T-8 Rhythm"))])
        var bass = MIDIFile.Track(events: [.init(tick: 0, event: .trackName("T-8 Bass"))])

        for event in events {
            switch event.kind {
            case .drum(let voice, let velocity):
                let note = options.drumNoteMap[voice] ?? 36
                let start = tick(event.position)
                drums.events.append(.init(tick: start, event: .noteOn(channel: options.drumChannel, note: note, velocity: velocity)))
                drums.events.append(.init(tick: start + max(1, tick(event.duration)), event: .noteOff(channel: options.drumChannel, note: note, velocity: 0)))
            case .bass(let note, let velocity, _):
                let start = tick(event.position)
                bass.events.append(.init(tick: start, event: .noteOn(channel: options.bassChannel, note: UInt8(note), velocity: velocity)))
                bass.events.append(.init(tick: start + max(1, tick(event.duration)), event: .noteOff(channel: options.bassChannel, note: UInt8(note), velocity: 0)))
            }
        }
        let end = tick(Double(pattern.length * options.loops))
        conductor.events.append(.init(tick: end, event: .endOfTrack))
        drums.events.append(.init(tick: end, event: .endOfTrack))
        bass.events.append(.init(tick: end, event: .endOfTrack))
        return MIDIFile(format: 1, ticksPerQuarter: tpq, tracks: [conductor, drums, bass])
    }
}

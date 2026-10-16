import AudioToolbox
import AVFoundation
import QuartzCore
import Foundation
import StemCore

enum ListenMode: String, CaseIterable, Identifiable {
    case audio = "A: Audio"
    case midi = "B: MIDI"
    case both = "A+B"
    var id: String { rawValue }
}

/// Audio and MIDI preview: one player per stem plus General MIDI samplers
/// driven by AVAudioSequencer, all on one AVAudioEngine so A/B switching keeps
/// the same clock. Preview sounds come from the macOS built-in DLS bank; they
/// are for checking timing and pitch, not for production.
@MainActor
final class PlaybackEngine {
    struct StemPlayback {
        var id: UUID
        var url: URL
        var gain: Float
        var audible: Bool
        var notes: [NoteEvent]
        var program: UInt8
        var isDrums: Bool
    }

    private let engine = AVAudioEngine()
    private var players: [UUID: (node: AVAudioPlayerNode, file: AVAudioFile)] = [:]
    private var samplers: [AVAudioUnitSampler] = []
    private var sequencer: AVAudioSequencer?
    private var startHostSeconds: Double = 0
    private var startPosition: Double = 0
    private(set) var isPlaying = false
    private(set) var lastError: String?
    var loopRegion: ClosedRange<Double>?

    static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    init() {
        // A silent mixer connection keeps the engine startable before any stem exists.
        _ = engine.mainMixerNode
    }

    /// Current position in seconds.
    var position: Double {
        guard isPlaying else { return startPosition }
        return startPosition + (CACurrentMediaTime() - startHostSeconds)
    }

    func seek(_ seconds: Double) {
        startPosition = max(0, seconds)
    }

    func play(stems: [StemPlayback], mode: ListenMode, tempo: TempoMap, metronome: Bool, from: Double, until: Double) {
        stop()
        lastError = nil
        startPosition = max(0, from)
        do {
            try configure(stems: stems, mode: mode, tempo: tempo, metronome: metronome, until: until)
            if !engine.isRunning { try engine.start() }
            let lead: Double = 0.08
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
            if mode != .midi {
                for s in stems where s.audible {
                    guard let entry = players[s.id] else { continue }
                    let node = entry.node, file = entry.file
                    let sr = file.processingFormat.sampleRate
                    let startFrame = AVAudioFramePosition(startPosition * sr)
                    guard startFrame < file.length else { continue }
                    node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(file.length - startFrame), at: nil)
                    node.play(at: startTime)
                }
            }
            if let seq = sequencer {
                seq.currentPositionInSeconds = startPosition
                seq.prepareToPlay()
                // AVAudioSequencer has no host-time start; start it at the same moment the players begin.
                DispatchQueue.main.asyncAfter(deadline: .now() + lead) { try? seq.start() }
            }
            startHostSeconds = CACurrentMediaTime() + lead
            isPlaying = true
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        if isPlaying { startPosition = position }
        sequencer?.stop()
        for (node, _) in players.values { node.stop() }
        for s in samplers {
            for ch in 0..<16 { s.sendController(123, withValue: 0, onChannel: UInt8(ch)) }
        }
        isPlaying = false
    }

    private func configure(stems: [StemPlayback], mode: ListenMode, tempo: TempoMap, metronome: Bool, until: Double) throws {
        // Audio players: reuse nodes for files already loaded.
        let wanted = Set(stems.map(\.id))
        for (id, entry) in players where !wanted.contains(id) {
            engine.detach(entry.node)
            players[id] = nil
        }
        for s in stems {
            if players[s.id]?.file.url != s.url {
                if let old = players[s.id] { engine.detach(old.node) }
                let file = try AVAudioFile(forReading: s.url)
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
                players[s.id] = (node, file)
            }
            players[s.id]?.node.volume = s.audible ? s.gain : 0
        }

        // MIDI preview: rebuilt on every play so edits are always heard.
        sequencer?.stop()
        sequencer = nil
        for s in samplers { engine.detach(s) }
        samplers.removeAll()
        guard mode != .audio || metronome else { return }

        var parts: [PreviewMIDI.Part] = []
        var programs: [(UInt8, Bool)] = []
        if mode != .audio {
            for s in stems where s.audible && !s.notes.isEmpty {
                // Preview channel: drums on 10 (index 9); melodic parts take their own channel.
                let ch = s.isDrums ? 9 : (parts.count % 15 >= 9 ? parts.count % 15 + 1 : parts.count % 15)
                parts.append(PreviewMIDI.Part(channel: ch, notes: s.notes))
                programs.append((s.program, s.isDrums))
            }
        }
        let data = PreviewMIDI.file(parts: parts, bpm: tempo.bpm, beatsPerBar: tempo.beatsPerBar, downbeat: tempo.downbeat,
                                    metronomeUntil: metronome ? until : nil)
        if metronome { programs.append((0, true)) }
        guard !programs.isEmpty else { return }

        for (program, drums) in programs {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            if FileManager.default.fileExists(atPath: Self.soundBank.path) {
                try? sampler.loadSoundBankInstrument(
                    at: Self.soundBank, program: drums ? 0 : program,
                    bankMSB: UInt8(drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            }
            samplers.append(sampler)
        }
        let seq = AVAudioSequencer(audioEngine: engine)
        try seq.load(from: data, options: [])
        for (i, track) in seq.tracks.enumerated() where i < samplers.count {
            track.destinationAudioUnit = samplers[i]
        }
        sequencer = seq
    }
}

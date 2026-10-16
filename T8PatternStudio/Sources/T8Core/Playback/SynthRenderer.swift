import Foundation

/// Mixer settings for the preview engine.
public struct PreviewMix: Hashable, Sendable {
    public var voiceVolume: [DrumVoice: Float] = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map { ($0, 0.8) })
    public var bassVolume: Float = 0.7
    public var masterVolume: Float = 0.8
    public var muted: Set<String> = []
    public var soloed: Set<String> = []
    public var metronome = false
    public var metronomeVolume: Float = 0.4
    public init() {}

    public static let bassTrackID = "bass"

    public func isAudible(_ trackID: String) -> Bool {
        if !soloed.isEmpty { return soloed.contains(trackID) }
        return !muted.contains(trackID)
    }
}

/// Sample-accurate pattern player and synthesizer, written in plain Swift so it
/// is testable on any platform. The macOS app drives `render` from an
/// `AVAudioSourceNode` on the real-time audio thread; timing therefore comes
/// from the sample clock, never from UI timers.
///
/// All sounds are synthesized (no samples), so there are no licensing concerns.
public final class SynthRenderer: @unchecked Sendable {
    public let sampleRate: Double

    private let lock = NSLock()
    private var pattern: Pattern
    private var events: [ScheduledEvent]
    private var mix = PreviewMix()
    private var playing = false
    private var loop = true
    /// Playback position in steps.
    private var position: Double = 0
    private var rng = SeededRandom(seed: 0x5EED)

    private var drumVoices: [DrumVoiceState] = []
    private var bass = BassVoice()
    private var clicks: [ClickState] = []

    public init(sampleRate: Double, pattern: Pattern = Pattern()) {
        self.sampleRate = sampleRate
        self.pattern = pattern
        self.events = PlaybackScheduler.events(for: pattern)
    }

    // MARK: Control (any thread)

    public func setPattern(_ newPattern: Pattern) {
        let newEvents = PlaybackScheduler.events(for: newPattern)
        lock.lock()
        pattern = newPattern
        events = newEvents
        if position >= Double(newPattern.length) { position = position.truncatingRemainder(dividingBy: Double(newPattern.length)) }
        lock.unlock()
    }

    public func setMix(_ newMix: PreviewMix) {
        lock.lock(); mix = newMix; lock.unlock()
    }

    public func play(fromStart: Bool = true) {
        lock.lock()
        if fromStart { position = 0 }
        playing = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        playing = false
        bass.gateOff()
        lock.unlock()
    }

    public func setLooping(_ looping: Bool) {
        lock.lock(); loop = looping; lock.unlock()
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    /// Current step (0-based) for UI highlighting.
    public var currentStep: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(position) % max(pattern.length, 1)
    }

    // MARK: Rendering (audio thread)

    /// Renders mono audio into `buffer`. Safe to call from the real-time thread.
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock(); defer { lock.unlock() }
        let stepsPerSample = pattern.bpm / 60.0 * 4.0 / sampleRate
        let length = Double(pattern.length)
        for frame in 0..<frameCount {
            if playing {
                let next = position + stepsPerSample
                trigger(from: position, to: next, length: length)
                position = next
                if position >= length {
                    if loop {
                        position -= length
                    } else {
                        playing = false
                        bass.gateOff()
                    }
                }
            }
            buffer[frame] = nextSample()
        }
    }

    /// Offline render of `loops` loops (used for tests and WAV export).
    public func renderOffline(loops: Int) -> [Float] {
        let seconds = Double(pattern.length * loops) * pattern.stepDuration + 0.5
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        play(fromStart: true)
        setLooping(true)
        let loopFrames = Int(Double(pattern.length * loops) * pattern.stepDuration * sampleRate)
        samples.withUnsafeMutableBufferPointer { pointer in
            var offset = 0
            while offset < pointer.count {
                if offset >= loopFrames && isPlaying { stop() }
                let count = min(512, pointer.count - offset)
                render(into: pointer.baseAddress! + offset, frameCount: count)
                offset += count
            }
        }
        return samples
    }

    private func trigger(from start: Double, to end: Double, length: Double) {
        // Events in [start, end), handling wrap at the loop point.
        fire(in: start..<min(end, length))
        if end > length, loop { fire(in: 0..<(end - length)) }
        if mix.metronome {
            let beatStart = (start / 4).rounded(.up) * 4
            if beatStart < end, beatStart >= start {
                let step = Int(beatStart) % max(Int(length), 1)
                clicks.append(ClickState(frequency: step == 0 ? 1760 : 1320, sampleRate: sampleRate, gain: mix.metronomeVolume))
            }
        }
    }

    private func fire(in range: Range<Double>) {
        guard !range.isEmpty else { return }
        for event in events where range.contains(event.position) {
            if event.probability < 100, !rng.chance(Double(event.probability) / 100) { continue }
            switch event.kind {
            case .drum(let voice, let velocity):
                guard mix.isAudible(voice.rawValue) else { continue }
                if voice == .closedHat { drumVoices.removeAll { $0.voice == .openHat } } // choke
                drumVoices.removeAll { $0.voice == voice && $0.age > 0.01 * sampleRate && voice != .clap }
                drumVoices.append(DrumVoiceState(voice: voice, velocity: Float(velocity) / 127, sampleRate: sampleRate, seed: rng.next()))
            case .bass(let note, let velocity, let slideIn):
                guard mix.isAudible(PreviewMix.bassTrackID) else { continue }
                let gateSamples = event.duration * 60.0 / pattern.bpm / 4.0 * sampleRate
                bass.noteOn(note: note, accent: velocity >= 120, slide: slideIn, gateSamples: gateSamples, sampleRate: sampleRate)
            }
        }
    }

    private func nextSample() -> Float {
        var out: Float = 0
        var index = 0
        while index < drumVoices.count {
            let sample = drumVoices[index].next()
            out += sample * (mix.voiceVolume[drumVoices[index].voice] ?? 0.8)
            if drumVoices[index].finished { drumVoices.remove(at: index) } else { index += 1 }
        }
        out += bass.next() * mix.bassVolume
        var c = 0
        while c < clicks.count {
            out += clicks[c].next()
            if clicks[c].finished { clicks.remove(at: c) } else { c += 1 }
        }
        out *= mix.masterVolume
        // Soft clip to keep the preview safe at high levels.
        return out / (1 + abs(out))
    }
}

// MARK: - Drum synthesis

struct DrumVoiceState {
    let voice: DrumVoice
    let velocity: Float
    let sampleRate: Float
    var age: Double = 0
    var phase: Float = 0
    var noise: SeededRandom
    var hp1: Float = 0, hpPrev: Float = 0
    var bp = StateVariableFilter()
    var finished = false

    init(voice: DrumVoice, velocity: Float, sampleRate: Double, seed: UInt64) {
        self.voice = voice
        self.velocity = velocity
        self.sampleRate = Float(sampleRate)
        self.noise = SeededRandom(seed: seed)
    }

    mutating func white() -> Float {
        Float(noise.next() >> 40) / Float(1 << 24) * 2 - 1
    }

    mutating func highpass(_ x: Float, _ coefficient: Float) -> Float {
        hp1 = coefficient * (hp1 + x - hpPrev)
        hpPrev = x
        return hp1
    }

    mutating func next() -> Float {
        let t = Float(age) / sampleRate
        age += 1
        var s: Float = 0
        switch voice {
        case .kick:
            let frequency = 48 + 110 * expf(-t * 28)
            phase += frequency / sampleRate
            let amp = expf(-t * 7.5)
            s = sinf(2 * .pi * phase) * amp * 1.1 + (t < 0.002 ? white() * 0.3 : 0)
            if t > 0.8 { finished = true }
        case .snare:
            phase += 185 / sampleRate
            let tone = sinf(2 * .pi * phase) * expf(-t * 22) * 0.5
            let n = highpass(white(), 0.92) * expf(-t * 16) * 0.7
            s = tone + n
            if t > 0.4 { finished = true }
        case .clap:
            let burst: Float
            if t < 0.03 { burst = expf(-(t.truncatingRemainder(dividingBy: 0.01)) * 300) }
            else { burst = expf(-(t - 0.03) * 18) }
            s = bp.process(white(), cutoff: 1200, resonance: 0.5, sampleRate: sampleRate).band * burst * 1.6
            if t > 0.45 { finished = true }
        case .tom:
            let frequency = 95 + 60 * expf(-t * 12)
            phase += frequency / sampleRate
            s = sinf(2 * .pi * phase) * expf(-t * 7) * 0.9
            if t > 0.7 { finished = true }
        case .closedHat, .openHat:
            let decay: Float = voice == .closedHat ? 55 : 7
            let metallic = squareSum(t) * 0.5 + white() * 0.5
            s = highpass(metallic, 0.82) * expf(-t * decay) * 0.55
            if t > (voice == .closedHat ? 0.15 : 0.8) { finished = true }
        }
        return s * velocity
    }

    /// Six detuned square waves, a classic analog-hat approximation.
    private func squareSum(_ t: Float) -> Float {
        let frequencies: [Float] = [205.3, 304.4, 369.6, 522.7, 540, 800]
        var sum: Float = 0
        for f in frequencies { sum += (sinf(2 * .pi * f * 2.2 * t) >= 0 ? 1 : -1) }
        return sum / 6
    }
}

struct StateVariableFilter {
    var low: Float = 0, band: Float = 0
    mutating func process(_ input: Float, cutoff: Float, resonance: Float, sampleRate: Float) -> (low: Float, band: Float, high: Float) {
        let f = 2 * sinf(.pi * min(cutoff, sampleRate / 6) / sampleRate)
        let q = 1 - min(max(resonance, 0), 0.98)
        low += f * band
        let high = input - low - q * band
        band += f * high
        return (low, band, high)
    }
}

// MARK: - Bass synthesis (TB-303 inspired)

struct BassVoice {
    var phase: Double = 0
    var frequency: Double = 55
    var targetFrequency: Double = 55
    var glideCoefficient: Double = 0
    var gateRemaining: Double = 0
    var ampEnv: Float = 0
    var filterEnv: Float = 0
    var accent = false
    var stages: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var sampleRate: Float = 44100

    mutating func noteOn(note: Int, accent: Bool, slide: Bool, gateSamples: Double, sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        targetFrequency = 440 * pow(2, Double(note - 69) / 12)
        gateRemaining = gateSamples
        if slide && ampEnv > 0.01 {
            glideCoefficient = 1 - exp(-1 / (0.06 * sampleRate)) // ~60 ms glide, no retrigger
        } else {
            frequency = targetFrequency
            glideCoefficient = 1
            filterEnv = 1
            ampEnv = max(ampEnv, 0.001)
            self.accent = accent
        }
    }

    mutating func gateOff() { gateRemaining = 0 }

    mutating func next() -> Float {
        frequency += (targetFrequency - frequency) * glideCoefficient
        let gate = gateRemaining > 0
        if gate { gateRemaining -= 1 }
        // Envelopes.
        let attack: Float = 0.02
        if gate { ampEnv += (1 - ampEnv) * attack } else { ampEnv *= 0.9985 }
        filterEnv *= accent ? 0.99965 : 0.9997
        if ampEnv < 0.0005 && !gate { return 0 }

        // Band-limited-ish saw via polyBLEP.
        let increment = frequency / Double(sampleRate)
        phase += increment
        if phase >= 1 { phase -= 1 }
        var saw = Float(2 * phase - 1)
        saw -= polyBlep(phase, increment)

        // Resonant 4-pole low-pass with tanh saturation.
        let envAmount: Float = accent ? 3800 : 2200
        let cutoff = min(180 + envAmount * filterEnv, sampleRate * 0.45)
        let g = 1 - expf(-2 * .pi * cutoff / sampleRate)
        let resonance: Float = accent ? 3.3 : 2.6
        let input = tanhf(saw - resonance * stages.3)
        stages.0 += g * (input - stages.0)
        stages.1 += g * (stages.0 - stages.1)
        stages.2 += g * (stages.1 - stages.2)
        stages.3 += g * (stages.2 - stages.3)
        let level: Float = accent ? 0.95 : 0.65
        return tanhf(stages.3 * 1.8) * ampEnv * level
    }

    private func polyBlep(_ t: Double, _ dt: Double) -> Float {
        if t < dt {
            let x = t / dt
            return Float(x + x - x * x - 1)
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return Float(x * x + x + x + 1)
        }
        return 0
    }
}

struct ClickState {
    var phase: Float = 0
    let frequency: Float
    let sampleRate: Float
    let gain: Float
    var age: Int = 0
    var finished = false

    init(frequency: Float, sampleRate: Double, gain: Float) {
        self.frequency = frequency
        self.sampleRate = Float(sampleRate)
        self.gain = gain
    }

    mutating func next() -> Float {
        age += 1
        let t = Float(age) / sampleRate
        if t > 0.05 { finished = true }
        phase += frequency / sampleRate
        return sinf(2 * .pi * phase) * expf(-t * 90) * gain
    }
}

/// 16-bit PCM WAV writer for offline renders.
public enum WAVWriter {
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
        return data
    }
}

import Foundation

/// Extracts a T-8 drum + bass pattern from recorded audio.
///
/// This is signal analysis, not source separation, so results are an
/// approximation for you (or Claude) to refine:
///  1. Split the signal into low (kick/bass), mid (snare/clap) and high (hats) bands.
///  2. Build onset-strength envelopes and estimate tempo by autocorrelation.
///  3. Find the 16th-note grid phase and the downbeat (strongest low-band beat).
///  4. Average onsets over several 2-bar repetitions per 16th step, then
///     threshold them into hits.
///  5. Track the bass pitch per step on a decimated low-passed signal and
///     estimate the key from the pitch histogram.
public enum AudioBeatAnalyzer {
    public struct Options: Sendable, Hashable {
        /// Steps in the resulting pattern (1...32). 24 = one and a half bars of 4/4.
        public var steps: Int = 24
        /// Where to start analysing, in seconds. nil = 20% into the audio (skips most intros).
        public var startSeconds: Double? = nil
        /// How much audio to analyse, in seconds.
        public var durationSeconds: Double = 30
        /// Force a tempo instead of detecting it.
        public var bpmOverride: Double? = nil
        public var bpmRange: ClosedRange<Double> = 70...180
        /// 0 (fewest hits) ... 1 (most hits).
        public var sensitivity: Double = 0.5
        public var includeBass = true
        public init() {}
    }

    public struct Result: Sendable {
        public var pattern: Pattern
        public var bpm: Double
        /// 0...1, how clearly the tempo stood out.
        public var tempoConfidence: Double
        /// Seconds where the analysed grid starts (on a detected downbeat).
        public var gridStartSeconds: Double
        public var repetitionsAnalysed: Int
        /// Per-voice average onset strength per step (0...1), for display and for Claude.
        public var stepStrengths: [DrumVoice: [Double]]
        public var bassNotes: [Int?]
        public var warnings: [String]

        /// Plain-text description used to give Claude the analysis.
        public var summaryForAI: String {
            var lines = [
                "Detected tempo: \(Int(bpm.rounded())) BPM (confidence \(Int(tempoConfidence * 100))%).",
                "Key estimate: \(pattern.key.name) \(pattern.scale.displayName). Steps: \(pattern.length) sixteenth notes in 4/4.",
                "Onset strength per step, 0-9 (from audio analysis, \(repetitionsAnalysed) two-bar repetitions averaged):",
            ]
            for voice in [DrumVoice.kick, .snare, .closedHat, .openHat] {
                let values = (stepStrengths[voice] ?? []).prefix(pattern.length).map { String(min(9, Int($0 * 10))) }.joined()
                lines.append("  \(voice.displayName): \(values)")
            }
            let bass = bassNotes.prefix(pattern.length).map { $0.map(NoteName.string(for:)) ?? "." }.joined(separator: " ")
            lines.append("  Bass pitch per step: \(bass)")
            lines.append("Draft pattern from thresholding:")
            for voice in DrumVoice.allCases {
                lines.append("  \(voice.displayName): " + PatternNotation.format(lane: pattern.drums.lane(voice), length: pattern.length))
            }
            lines.append("  Bass: " + PatternNotation.format(bass: pattern.bass.steps, length: pattern.length))
            if !warnings.isEmpty { lines.append("Analysis notes: " + warnings.joined(separator: " ")) }
            return lines.joined(separator: "\n")
        }
    }

    public enum AnalysisError: Error, LocalizedError, Equatable {
        case tooShort
        case silent
        public var errorDescription: String? {
            switch self {
            case .tooShort: "The audio is too short to analyse. Use at least 8 seconds."
            case .silent: "The selected part of the audio is silent."
            }
        }
    }

    static let hopSize = 256

    public static func analyze(samples input: [Float], sampleRate: Double, options: Options = Options()) throws -> Result {
        let steps = min(max(options.steps, 1), Pattern.maxSteps)
        let total = Double(input.count) / sampleRate
        guard total >= 8 else { throw AnalysisError.tooShort }
        var start = options.startSeconds ?? (total > 40 ? total * 0.2 : 0)
        start = min(max(0, start), max(0, total - 8))
        let duration = min(options.durationSeconds, total - start)
        let startIndex = Int(start * sampleRate)
        let endIndex = min(input.count, startIndex + Int(duration * sampleRate))
        let samples = Array(input[startIndex..<endIndex])
        guard samples.contains(where: { abs($0) > 1e-4 }) else { throw AnalysisError.silent }
        var warnings: [String] = []

        // 1. Band split.
        let fs = Float(sampleRate)
        var lowFilter = Biquad.lowPass(cutoff: 140, q: 0.7, sampleRate: fs)
        var midHighPass = Biquad.highPass(cutoff: 1500, q: 0.7, sampleRate: fs)
        var midBandPass = Biquad.bandPass(center: 3200, q: 0.9, sampleRate: fs)
        var highFilter = Biquad.highPass(cutoff: 7000, q: 0.7, sampleRate: fs)
        let low = lowFilter.process(samples)
        let mid = midBandPass.process(midHighPass.process(samples))
        let high = highFilter.process(samples)

        // 2. Onset envelopes.
        let hopSeconds = Double(hopSize) / sampleRate
        let lowEnv = onsetEnvelope(low), midEnv = onsetEnvelope(mid), highEnv = onsetEnvelope(high)
        let lowLevel = levelEnvelope(low), highLevel = levelEnvelope(high)
        let frameCount = min(lowEnv.count, midEnv.count, highEnv.count)
        var combined = [Double](repeating: 0, count: frameCount)
        for i in 0..<frameCount { combined[i] = lowEnv[i] * 1.2 + midEnv[i] + highEnv[i] * 0.6 }

        // 3. Tempo.
        let (roughBPM, confidence): (Double, Double)
        if let forced = options.bpmOverride {
            (roughBPM, confidence) = (forced, 1)
        } else {
            (roughBPM, confidence) = estimateTempo(combined, hopSeconds: hopSeconds, range: options.bpmRange)
            if confidence < 0.25 { warnings.append("Tempo detection was uncertain; set the BPM manually if the grid sounds wrong.") }
        }
        // Refine tempo and grid phase together so the grid doesn't drift over many bars.
        let refined = refineGrid(combined, bpm: roughBPM, hopSeconds: hopSeconds, searchBPM: options.bpmOverride == nil ? 1.5 : 0)
        let bpm = refined.bpm
        let stepFrames = 60.0 / bpm / 4.0 / hopSeconds // envelope frames per 16th
        let bestPhase = refined.phase

        // Downbeat: which of the 4 sixteenths in a beat, and which of the 4 beats in a bar, has the strongest kick.
        var beatScores = Array(repeating: 0.0, count: 16)
        var position = bestPhase
        var stepIndex = 0
        while position < Double(lowEnv.count) {
            beatScores[stepIndex % 16] += sample(lowEnv, at: position)
            position += stepFrames
            stepIndex += 1
        }
        // Prefer the offset whose quarter-note positions together carry the most kick energy, then the strongest of those as beat 1.
        func quarterSum(_ offset: Int) -> Double {
            var total = 0.0
            for i in stride(from: offset, to: 16, by: 4) { total += beatScores[i] }
            return total
        }
        let quarterOffset = (0..<4).max { quarterSum($0) < quarterSum($1) } ?? 0
        let downbeat = stride(from: quarterOffset, to: 16, by: 4).max { beatScores[$0] < beatScores[$1] } ?? quarterOffset
        var gridStart = bestPhase + Double(downbeat) * stepFrames

        // 5. Average onset strength per step over 2-bar (32-step) repetitions.
        let period = 32
        let reps = max(1, Int((Double(combined.count) - gridStart) / (stepFrames * Double(period))))
        if reps < 2 { warnings.append("Only one 2-bar repetition was available; analyse a longer section for steadier results.") }
        func average(_ env: [Double]) -> [Double] {
            var sums = Array(repeating: 0.0, count: period)
            for r in 0..<reps {
                for s in 0..<period {
                    let center = gridStart + (Double(r * period + s)) * stepFrames
                    // Max within ±1/3 step tolerates swing and timing drift.
                    var peak = 0.0
                    var f = center - stepFrames / 3
                    while f <= center + stepFrames / 3 {
                        peak = max(peak, sample(env, at: f))
                        f += 0.5
                    }
                    sums[s] += peak
                }
            }
            let mean = sums.map { $0 / Double(reps) }
            let top = mean.max() ?? 0
            return top > 0 ? mean.map { $0 / top } : mean
        }
        var kickStrength = average(lowEnv)
        var snareStrength = average(midEnv)
        var hatStrength = average(highEnv)
        // Open-hat detection: how much of the high-band level is left 0.6 steps after the hit.
        var sustain = Array(repeating: 0.0, count: period)
        for r in 0..<reps {
            for s in 0..<period {
                let peak = gridStart + (Double(r * period + s) + 0.1) * stepFrames
                let later = gridStart + (Double(r * period + s) + 0.6) * stepFrames
                sustain[s] += sample(highLevel, at: later) / max(sample(highLevel, at: peak), 1e-9)
            }
        }
        sustain = sustain.map { $0 / Double(reps) }

        // 6. Threshold into hits.
        let sensitivity = min(max(options.sensitivity, 0), 1)
        // Adaptive threshold per band: a hit must stand out from that band's
        // typical level, which absorbs steady bleed from other instruments.
        func hits(_ strengths: [Double], base: Double) -> [Bool] {
            let mean = strengths.reduce(0, +) / Double(strengths.count)
            let deviation = sqrt(strengths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(strengths.count))
            let adaptive = mean + 0.8 * deviation
            let threshold = max(base, adaptive) - 0.3 * (sensitivity - 0.5)
            return strengths.map { $0 >= threshold }
        }
        // Remove the share of each band that the other instruments explain: the
        // median ratio seen on clear source steps is treated as bleed (steps where
        // both instruments really play are the minority and fall above the median).
        func bleed(_ target: [Double], from source: [Double]) -> Double {
            let ratios = source.indices.filter { source[$0] > 0.6 }.map { target[$0] / source[$0] }.sorted()
            return ratios.isEmpty ? 0 : ratios[(ratios.count - 1) / 2]
        }
        let snareFromKick = bleed(snareStrength, from: kickStrength)
        let hatFromKick = bleed(hatStrength, from: kickStrength)
        var hatClean = hatStrength.indices.map { max(0, hatStrength[$0] - hatFromKick * kickStrength[$0]) }
        // Snares share the noise region with hats, so a snare is a step whose
        // noise-band onset stands out above the regular pulse: compare each step
        // with the median of steps at the same 16th position (on/off the 8th).
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let parityMedian = [0, 1].map { parity in median(snareStrength.indices.filter { $0 % 2 == parity }.map { snareStrength[$0] }) }
        var snareClean = snareStrength.indices.map { i in
            max(0, snareStrength[i] - parityMedian[i % 2] - snareFromKick * 0.25 * kickStrength[i])
        }

        // Choose bar 1 with the usual backbeat convention: kick on beat 1,
        // snare/clap on beats 2 and 4, little snare on 1 and 3. Every 16th offset
        // is considered, since a syncopated kick can mislead the first guess.
        let snareNorm = normalized(snareClean)
        func backbeatScore(_ d: Int) -> Double {
            var score = 0.0
            for bar in [0, 16] {
                func k(_ i: Int) -> Double { kickStrength[(d + bar + i) % period] }
                func sn(_ i: Int) -> Double { snareNorm[(d + bar + i) % period] }
                score += 2 * k(0) + 0.5 * k(8) + sn(4) + sn(12) - 0.7 * (sn(0) + sn(8))
            }
            return score
        }
        let rotation = (0..<16).max { backbeatScore($0) < backbeatScore($1) } ?? 0
        if rotation != 0 {
            func rotate(_ a: [Double]) -> [Double] { (0..<a.count).map { a[($0 + rotation) % a.count] } }
            kickStrength = rotate(kickStrength)
            snareStrength = rotate(snareStrength)
            hatStrength = rotate(hatStrength)
            sustain = rotate(sustain)
            hatClean = rotate(hatClean)
            snareClean = rotate(snareClean)
            gridStart += Double(rotation) * stepFrames
        }
        let kickOn = hits(kickStrength, base: 0.55)
        let snareOn = hits(normalized(snareClean), base: 0.5)
        // Hats are usually a steady pulse, so use a fixed share of the loudest hat.
        let hatOn = normalized(hatClean).map { $0 >= 0.35 - 0.3 * (sensitivity - 0.5) }

        var pattern = Pattern(name: "From Audio", bpm: bpm.rounded(), length: steps)
        for s in 0..<steps {
            if kickOn[s] { pattern.drums[.kick, s] = DrumHit(velocity: velocity(kickStrength[s])) }
            if snareOn[s] {
                pattern.drums[.snare, s] = DrumHit(velocity: velocity(snareStrength[s]))
                // Strong backbeats often carry a clap layer in electronic music.
                if s % 8 == 4 && snareStrength[s] > 0.85 { pattern.drums[.clap, s] = DrumHit(velocity: velocity(snareStrength[s])) }
            }
            if hatOn[s] {
                if sustain[s] > 0.35 {
                    pattern.drums[.openHat, s] = DrumHit(velocity: velocity(hatStrength[s]))
                } else {
                    pattern.drums[.closedHat, s] = DrumHit(velocity: velocity(hatStrength[s]))
                }
            }
            pattern.drums.accents[s] = kickOn[s] && kickStrength[s] > 0.9 && s % 4 == 0
        }
        if pattern.drums.hitCount(length: steps) == 0 {
            warnings.append("No clear drum hits were found; try a section with drums or raise sensitivity.")
        }

        // 7. Bass.
        var bassNotes: [Int?] = Array(repeating: nil, count: period)
        if options.includeBass {
            // Pitch is tracked on 55-350 Hz: bass harmonics keep the periodicity,
            // while most of a kick's sub-bass sweep is filtered out.
            var bassHighPass = Biquad.highPass(cutoff: 55, q: 0.7, sampleRate: fs)
            var bassLowPass = Biquad.lowPass(cutoff: 350, q: 0.7, sampleRate: fs)
            let bassBand = bassLowPass.process(bassHighPass.process(samples))
            bassNotes = trackBass(low: bassBand, lowLevel: lowLevel, sampleRate: sampleRate, gridStart: gridStart, stepFrames: stepFrames, reps: reps, period: period, kickStrength: kickStrength)
            // The kick's decaying tail leaves the same low pitch on the step after
            // each kick; drop that recurring pitch where no bass onset is heard.
            let postKick = (0..<period).filter { kickStrength[$0] < 0.3 && kickStrength[($0 + period - 1) % period] > 0.5 }
            var tailVotes: [Int: Int] = [:]
            for i in postKick { if let n = bassNotes[i] { tailVotes[n, default: 0] += 1 } }
            if let (tail, count) = tailVotes.max(by: { $0.value < $1.value }), count >= 2, count * 2 >= postKick.count {
                for i in postKick where bassNotes[i] == tail
                    && !lowOnset(at: i, lowEnv: lowEnv, gridStart: gridStart, stepFrames: stepFrames, reps: reps, period: period) {
                    bassNotes[i] = nil
                }
            }
            if kickStrength.contains(where: { $0 > 0.5 }) {
                warnings.append("Bass pitches on kick steps are less reliable: pitched kicks (like an 808) can read as bass notes.")
            }
            let detected = bassNotes.compactMap { $0 }
            if let (key, scale) = estimateKey(detected) {
                pattern.key = key
                pattern.scale = scale
            }
            var previous: Int?
            for s in 0..<steps {
                guard let note = bassNotes[s] else { previous = nil; continue }
                let onset = kickStrength[s] > 0.35 || lowOnset(at: s, lowEnv: lowEnv, gridStart: gridStart, stepFrames: stepFrames, reps: reps, period: period)
                if let previous, previous == note, !onset {
                    pattern.bass[s] = BassStep(kind: .tie, note: note)
                } else {
                    pattern.bass[s] = .note(note, accent: kickStrength[s] > 0.9)
                }
                previous = note
            }
            pattern.bass.repairTies()
            if detected.isEmpty { warnings.append("No stable bass pitch was found; the bass line is empty.") }
        }

        let strengths: [DrumVoice: [Double]] = [
            .kick: kickStrength, .snare: snareStrength, .clap: snareStrength,
            .closedHat: hatStrength, .openHat: zip(hatStrength, sustain).map { $1 > 0.35 ? $0 : 0 }, .tom: Array(repeating: 0, count: period),
        ]
        if steps % 16 != 0 {
            warnings.append("A \(steps)-step loop is \(Double(steps) / 16) bars, so it won't line up with a song that repeats every 1 or 2 bars. It uses the first \(steps) steps of the song's 2-bar groove.")
        }
        return Result(
            pattern: pattern, bpm: bpm, tempoConfidence: confidence,
            gridStartSeconds: start + gridStart * hopSeconds, repetitionsAnalysed: reps,
            stepStrengths: strengths, bassNotes: bassNotes, warnings: warnings
        )
    }

    // MARK: Envelopes

    /// RMS per hop.
    static func levelEnvelope(_ x: [Float]) -> [Double] {
        stride(from: 0, to: x.count - hopSize, by: hopSize).map { i in
            var sum: Float = 0
            for j in i..<(i + hopSize) { sum += x[j] * x[j] }
            return Double(sqrt(sum / Float(hopSize)))
        }
    }

    /// Half-wave-rectified difference of log energy.
    static func onsetEnvelope(_ x: [Float]) -> [Double] {
        let level = levelEnvelope(x)
        var out = Array(repeating: 0.0, count: level.count)
        for i in 1..<max(level.count, 1) {
            let d = log(1 + 100 * level[i]) - log(1 + 100 * level[i - 1])
            out[i] = max(0, d)
        }
        return out
    }

    static func sample(_ env: [Double], at position: Double) -> Double {
        guard position >= 0 else { return 0 }
        let i = Int(position)
        guard i + 1 < env.count else { return i < env.count ? env[i] : 0 }
        let t = position - Double(i)
        return env[i] * (1 - t) + env[i + 1] * t
    }

    static func estimateTempo(_ env: [Double], hopSeconds: Double, range: ClosedRange<Double>) -> (Double, Double) {
        let mean = env.reduce(0, +) / Double(max(env.count, 1))
        let centered = env.map { $0 - mean }
        var best = (bpm: 120.0, score: -Double.infinity)
        var scores: [Double] = []
        for tenth in Int(range.lowerBound * 10)...Int(range.upperBound * 10) {
            let bpm = Double(tenth) / 10
            let lag = 60.0 / bpm / hopSeconds
            // Autocorrelation at the beat lag plus its double (bar-level evidence), interpolated.
            var score = 0.0
            for multiple in [1.0, 2.0, 0.5] {
                let l = lag * multiple
                var s = 0.0
                var i = 0
                while Double(i) + l < Double(centered.count) {
                    s += centered[i] * sample(centered, at: Double(i) + l)
                    i += 2
                }
                score += s * (multiple == 1 ? 1 : 0.5)
            }
            // Mild preference for common dance tempos (log-Gaussian around 120).
            score *= exp(-pow(log2(bpm / 120), 2) / (2 * 0.5 * 0.5))
            scores.append(score)
            if score > best.score { best = (bpm, score) }
        }
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let confidence = best.score > 0 ? min(1, max(0, (best.score - median) / best.score)) : 0
        return (best.bpm, confidence)
    }

    /// Maximizes onset energy landing on a 16th-note grid over the whole excerpt,
    /// searching tempo (±searchBPM, 0.01 BPM steps) and phase.
    static func refineGrid(_ env: [Double], bpm: Double, hopSeconds: Double, searchBPM: Double) -> (bpm: Double, phase: Double) {
        func score(_ candidate: Double, _ phase: Double) -> Double {
            let step = 60.0 / candidate / 4.0 / hopSeconds
            var total = 0.0
            var position = phase
            while position < Double(env.count) {
                total += sample(env, at: position)
                position += step
            }
            return total
        }
        var best = (bpm: bpm, phase: 0.0, score: -1.0)
        // Coarse pass.
        var candidate = bpm - searchBPM
        while candidate <= bpm + searchBPM + 1e-9 {
            let step = 60.0 / candidate / 4.0 / hopSeconds
            var phase = 0.0
            while phase < step {
                let s = score(candidate, phase)
                if s > best.score { best = (candidate, phase, s) }
                phase += 1
            }
            candidate += 0.05
        }
        // Fine pass around the best point.
        let center = best
        candidate = center.bpm - 0.06
        while candidate <= center.bpm + 0.06 + 1e-9 {
            var phase = max(0, center.phase - 1.5)
            while phase <= center.phase + 1.5 {
                let s = score(candidate, phase)
                if s > best.score { best = (candidate, phase, s) }
                phase += 0.1
            }
            candidate += 0.01
        }
        // Onset frames sit up to one hop before the true attack; shift the grid half a hop later.
        return (best.bpm, best.phase + 0.5)
    }

    static func normalized(_ values: [Double]) -> [Double] {
        let top = values.max() ?? 0
        return top > 0 ? values.map { $0 / top } : values
    }

    static func velocity(_ strength: Double) -> Int {
        min(10, max(3, Int((3 + strength * 7).rounded())))
    }

    // MARK: Bass pitch

    static func lowOnset(at step: Int, lowEnv: [Double], gridStart: Double, stepFrames: Double, reps: Int, period: Int) -> Bool {
        var total = 0.0
        for r in 0..<reps { total += sample(lowEnv, at: gridStart + Double(r * period + step) * stepFrames) }
        let average = total / Double(reps)
        let globalMean = lowEnv.reduce(0, +) / Double(max(lowEnv.count, 1))
        return average > globalMean * 3
    }

    static func trackBass(low: [Float], lowLevel: [Double], sampleRate: Double, gridStart: Double, stepFrames: Double, reps: Int, period: Int, kickStrength: [Double]) -> [Int?] {
        // Decimate to ~2.7 kHz (the input is already low-passed at 350 Hz).
        let factor = max(1, Int(sampleRate / 2756))
        let rate = sampleRate / Double(factor)
        let decimated = stride(from: 0, to: low.count, by: factor).map { low[$0] }
        let window = Int(rate * 0.06)
        let minLag = Int(rate / 160), maxLag = Int(rate / 38)
        let quietLevel = (lowLevel.sorted().dropFirst(lowLevel.count / 2).first ?? 0) * 0.6

        var notes: [Int?] = []
        for s in 0..<period {
            var votes: [Int: Int] = [:]
            for r in 0..<reps {
                // On kick steps, measure twice late in the step and keep only a
                // steady pitch: a kick's falling pitch sweep is rejected.
                let offsets = kickStrength[s] > 0.4 ? [0.55, 0.9] : [0.4]
                var estimates: [Double] = []
                for offset in offsets {
                    let frame = gridStart + (Double(r * period + s) + offset) * stepFrames
                    guard sample(lowLevel, at: frame) > quietLevel else { break }
                    let center = Int(frame * Double(hopSize) / Double(factor))
                    let begin = center - window / 2
                    guard begin >= 0, begin + window + maxLag < decimated.count else { break }
                    var bestLag = 0, bestScore: Float = 0, energy: Float = 0
                    for i in 0..<window { energy += decimated[begin + i] * decimated[begin + i] }
                    guard energy > 0 else { break }
                    for lag in minLag...maxLag {
                        var sum: Float = 0
                        for i in 0..<window { sum += decimated[begin + i] * decimated[begin + i + lag] }
                        if sum > bestScore { bestScore = sum; bestLag = lag }
                    }
                    guard bestLag > 0, bestScore / energy > 0.45 else { break }
                    estimates.append(69 + 12 * log2(rate / Double(bestLag) / 440))
                }
                guard estimates.count == offsets.count else { continue }
                if estimates.count == 2, abs(estimates[0] - estimates[1]) > 0.7 { continue }
                var midi = Int(estimates[0].rounded())
                while midi < 24 { midi += 12 }
                while midi > 52 { midi -= 12 }
                votes[midi, default: 0] += 1
            }
            if let (note, count) = votes.max(by: { $0.value < $1.value }), count * 2 >= max(1, reps) || (reps == 1 && count == 1) {
                notes.append(note)
            } else {
                notes.append(nil)
            }
        }
        return notes
    }

    static func estimateKey(_ notes: [Int]) -> (PitchClass, Scale)? {
        guard !notes.isEmpty else { return nil }
        var histogram = Array(repeating: 0, count: 12)
        for n in notes { histogram[((n % 12) + 12) % 12] += 1 }
        let root = histogram.indices.max { histogram[$0] < histogram[$1] }!
        let minorThird = histogram[(root + 3) % 12], majorThird = histogram[(root + 4) % 12]
        return (PitchClass(rawValue: root)!, majorThird > minorThird ? .major : .minor)
    }
}

/// Minimal RBJ biquad filter.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func coefficients(_ type: Int, f: Float, q: Float, fs: Float) -> Biquad {
        let w = 2 * Float.pi * min(f, fs * 0.45) / fs
        let alpha = sin(w) / (2 * q), c = cos(w)
        var b0: Float, b1: Float, b2: Float
        switch type {
        case 0: b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2          // low-pass
        case 1: b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2       // high-pass
        default: b0 = alpha; b1 = 0; b2 = -alpha                         // band-pass
        }
        let a0 = 1 + alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    static func lowPass(cutoff: Float, q: Float, sampleRate: Float) -> Biquad { coefficients(0, f: cutoff, q: q, fs: sampleRate) }
    static func highPass(cutoff: Float, q: Float, sampleRate: Float) -> Biquad { coefficients(1, f: cutoff, q: q, fs: sampleRate) }
    static func bandPass(center: Float, q: Float, sampleRate: Float) -> Biquad { coefficients(2, f: center, q: q, fs: sampleRate) }

    mutating func process(_ input: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        for i in input.indices {
            let x = input[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
}

/// Reads PCM 16/24/32-bit integer and 32-bit float WAV files into mono samples
/// (used by the CLI and tests; the macOS app decodes any format with AVFoundation).
public enum WAVReader {
    public enum ReadError: Error, LocalizedError {
        case unsupported(String)
        public var errorDescription: String? {
            if case .unsupported(let why) = self { return "Unsupported WAV file: \(why)" }
            return nil
        }
    }

    public static func read(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        guard bytes.count > 44, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw ReadError.unsupported("not a RIFF/WAVE file")
        }
        var offset = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 40 { format = u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                guard channels > 0, rate > 0 else { throw ReadError.unsupported("missing fmt chunk") }
                let end = min(bytes.count, body + size)
                let frameBytes = channels * bits / 8
                guard frameBytes > 0 else { throw ReadError.unsupported("invalid format") }
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / frameBytes)
                var i = body
                while i + frameBytes <= end {
                    var sum: Float = 0
                    for c in 0..<channels {
                        let o = i + c * bits / 8
                        switch (format, bits) {
                        case (1, 16): sum += Float(Int16(bitPattern: UInt16(u16(o)))) / 32768
                        case (1, 24):
                            let v = Int32(bitPattern: UInt32(bytes[o]) << 8 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 24) >> 8
                            sum += Float(v) / 8_388_608
                        case (1, 32): sum += Float(Int32(bitPattern: UInt32(u32(o)))) / 2_147_483_648
                        case (3, 32): sum += Float(bitPattern: UInt32(u32(o)))
                        default: throw ReadError.unsupported("format \(format), \(bits)-bit")
                        }
                    }
                    samples.append(sum / Float(channels))
                    i += frameBytes
                }
                return (samples, Double(rate))
            }
            offset = body + size + (size % 2)
        }
        throw ReadError.unsupported("no data chunk")
    }
}

import AVFoundation
import SwiftUI
import T8Core
import UniformTypeIdentifiers

/// "Beat from Audio": analyse a song on this Mac, then use the extracted
/// pattern directly or let Claude refine it. Claude never receives the audio,
/// only the text summary of the analysis.
struct AudioToBeatSheet: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var fileName = ""
    @State private var samples: [Float] = []
    @State private var sampleRate: Double = AudioDecoder.analysisRate
    @State private var overview: [Float] = []
    @State private var loading = false
    @State private var analyzing = false
    @State private var errorText: String?

    @State private var startSeconds = 0.0
    @State private var analyseSeconds = 30.0
    @State private var steps = 24
    @State private var overrideBPM = false
    @State private var bpm = 120.0
    @State private var sensitivity = 0.5
    @State private var includeBass = true
    @State private var direction = ""
    @State private var result: AudioBeatAnalyzer.Result?

    private var duration: Double { Double(samples.count) / sampleRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beat from Audio").font(.title3.bold())
            Text("Analyses a song on your Mac (tempo, kick, snare, hats and bass) and turns it into a T-8 pattern. Claude doesn't hear the audio. It only receives the analysis as text, which it uses to clean up the pattern.")
                .font(Theme.small).foregroundStyle(Theme.textDim)

            HStack {
                Button("Choose Audio File…", action: choose).disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Text(fileName.isEmpty ? "WAV, AIFF, MP3, M4A/AAC, CAF" : "\(fileName) · \(format(duration))")
                    .foregroundStyle(Theme.textDim).lineLimit(1)
            }

            if !samples.isEmpty {
                WaveformView(overview: overview, duration: duration, start: startSeconds, length: min(analyseSeconds, max(0, duration - startSeconds)))
                    .frame(height: 60)
                Form {
                    LabeledContent("Start at \(format(startSeconds))") {
                        Slider(value: $startSeconds, in: 0...max(0, duration - 8))
                    }
                    Picker("Analyse", selection: $analyseSeconds) {
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                        Text("60 s").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                    Picker("Pattern length", selection: $steps) {
                        Text("16 (1 bar)").tag(16)
                        Text("24 (1½ bars)").tag(24)
                        Text("32 (2 bars)").tag(32)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Toggle("Set BPM manually", isOn: $overrideBPM)
                        if overrideBPM {
                            TextField("BPM", value: $bpm, format: .number.precision(.fractionLength(0...1))).frame(width: 70)
                        }
                    }
                    LabeledContent("Sensitivity") {
                        HStack {
                            Text("Fewer hits").font(Theme.small)
                            Slider(value: $sensitivity, in: 0...1)
                            Text("More hits").font(Theme.small)
                        }
                    }
                    Toggle("Extract bass line", isOn: $includeBass)
                }
                .formStyle(.grouped)
                .frame(height: 250)

                HStack {
                    Button(analyzing ? "Analysing…" : "Analyse", action: analyze).disabled(analyzing)
                    if analyzing { ProgressView().controlSize(.small) }
                }
            }

            if let errorText {
                Text(errorText).foregroundStyle(Theme.danger).font(.system(size: 12))
            }

            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Int(result.bpm.rounded())) BPM · \(result.pattern.key.name) \(result.pattern.scale.displayName) · \(result.pattern.length) steps · tempo confidence \(Int(result.tempoConfidence * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                    MiniPatternView(pattern: result.pattern).frame(height: 70)
                    ForEach(result.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "info.circle").font(Theme.small).foregroundStyle(Theme.warning)
                    }
                    HStack {
                        Button(store.previewingPresetID == StudioStore.audioPreviewID && store.isPlaying ? "Stop Preview" : "Preview") {
                            store.previewPattern(result.pattern)
                        }
                        Spacer()
                        Button("Use This Pattern") { use(result) }
                    }
                    Divider()
                    TextField("Optional direction for Claude, e.g. “keep it sparse, add acid slides”", text: $direction)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text(store.hasAPIKey ? "Claude turns the analysis into a clean, musical pattern." : "Add an API key in Settings to refine with Claude.")
                            .font(Theme.small).foregroundStyle(Theme.textDim)
                        Spacer()
                        Button {
                            refine(result)
                        } label: {
                            Label("Refine with Claude", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!store.hasAPIKey || store.aiBusy)
                    }
                }
                .padding(10)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Text("Analyse only music you have the right to use. The result is a draft to edit.").font(Theme.small).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Close") {
                    if store.previewingPresetID == StudioStore.audioPreviewID { store.stop() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a song to turn into a T-8 beat"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loading = true
        errorText = nil
        result = nil
        Task {
            do {
                let decoded = try await Task.detached(priority: .userInitiated) { try AudioDecoder.decode(url: url) }.value
                samples = decoded
                sampleRate = AudioDecoder.analysisRate
                overview = AudioDecoder.overview(decoded, buckets: 600)
                fileName = url.lastPathComponent
                let total = Double(decoded.count) / sampleRate
                startSeconds = total > 40 ? (total * 0.2).rounded() : 0
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }

    private func analyze() {
        var options = AudioBeatAnalyzer.Options()
        options.steps = steps
        options.startSeconds = startSeconds
        options.durationSeconds = analyseSeconds
        options.bpmOverride = overrideBPM ? bpm : nil
        options.sensitivity = sensitivity
        options.includeBass = includeBass
        let input = samples, rate = sampleRate
        analyzing = true
        errorText = nil
        Task {
            do {
                let analysed = try await Task.detached(priority: .userInitiated) {
                    try AudioBeatAnalyzer.analyze(samples: input, sampleRate: rate, options: options)
                }.value
                var named = analysed
                named.pattern.name = (fileName as NSString).deletingPathExtension
                result = named
                if !overrideBPM { bpm = analysed.bpm.rounded() }
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            analyzing = false
        }
    }

    private func use(_ result: AudioBeatAnalyzer.Result) {
        store.guardUnsaved(title: "Replace the current pattern with the beat from audio?") {
            store.stop()
            store.replaceVariations(PatternVariationEngine.makeVariations(from: result.pattern, genre: nil, seed: 7))
            store.currentPresetID = nil
            store.activeSlot = .a
            store.statusMessage = "Beat from audio: \(result.pattern.name)"
        }
        dismiss()
    }

    private func refine(_ result: AudioBeatAnalyzer.Result) {
        store.stop()
        store.runAI(.fromAudio(analysis: result.summaryForAI, steps: result.pattern.length, direction: direction))
        store.inspectorTab = .ai
        dismiss()
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Peak overview of the song with the analysed region highlighted.
struct WaveformView: View {
    let overview: [Float]
    let duration: Double
    let start: Double
    let length: Double

    var body: some View {
        Canvas { context, size in
            guard !overview.isEmpty, duration > 0 else { return }
            let x0 = CGFloat(start / duration) * size.width
            let w = CGFloat(length / duration) * size.width
            context.fill(Path(CGRect(x: x0, y: 0, width: w, height: size.height)), with: .color(Theme.accent.opacity(0.18)))
            let barWidth = size.width / CGFloat(overview.count)
            for (i, peak) in overview.enumerated() {
                let h = CGFloat(peak) * size.height
                let x = CGFloat(i) * barWidth
                let inRegion = x >= x0 && x <= x0 + w
                context.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: max(1, barWidth - 0.5), height: h)),
                             with: .color(inRegion ? Theme.accent : Theme.textDim.opacity(0.6)))
            }
        }
        .background(Theme.cellOff.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Waveform with the analysed section highlighted")
    }
}

/// Decodes any audio file AVFoundation can read into mono Float32 at a fixed analysis rate.
enum AudioDecoder {
    static let analysisRate = 22_050.0
    static let maxSeconds = 15.0 * 60

    enum DecodeError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): "This audio file can't be read (\(detail)). DRM-protected purchases and streaming downloads can't be analysed; use a WAV, AIFF, MP3 or unprotected M4A."
            }
        }
    }

    static func decode(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError.unreadable(error.localizedDescription)
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: analysisRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw DecodeError.unreadable("unsupported format")
        }
        converter.downmix = true
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * analysisRate) + 1024)
        var finished = false
        while !finished && Double(output.count) < maxSeconds * analysisRate {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { requested, inputStatus in
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw DecodeError.unreadable(error.localizedDescription) }
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            if status == .endOfStream || status == .error || buffer.frameLength == 0 { finished = true }
        }
        guard !output.isEmpty else { throw DecodeError.unreadable("no audio frames") }
        return output
    }

    static func overview(_ samples: [Float], buckets: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        let peaks = stride(from: 0, to: samples.count, by: size).map { start in
            samples[start..<min(samples.count, start + size)].reduce(0) { max($0, abs($1)) }
        }
        let top = peaks.max() ?? 1
        return top > 0 ? peaks.map { $0 / top } : peaks
    }
}

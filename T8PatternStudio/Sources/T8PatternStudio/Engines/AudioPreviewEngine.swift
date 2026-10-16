import AVFoundation
import T8Core

/// Local preview audio: an `AVAudioSourceNode` pulls samples from the
/// sample-accurate `SynthRenderer`, so musical timing comes from the audio
/// clock rather than from UI timers.
final class AudioPreviewEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let renderer: SynthRenderer
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var lastError: String?

    init() {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        renderer = SynthRenderer(sampleRate: sampleRate > 0 ? sampleRate : 48_000)
    }

    /// Built outside any actor so the render block is not main-actor isolated
    /// (it runs on the real-time audio thread).
    private nonisolated static func makeSourceNode(renderer: SynthRenderer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let frames = Int(frameCount)
            let mono = data.assumingMemoryBound(to: Float.self)
            renderer.render(into: mono, frameCount: frames)
            // Copy to any additional channels.
            for index in 1..<buffers.count {
                if let other = buffers[index].mData?.assumingMemoryBound(to: Float.self) {
                    other.update(from: mono, count: frames)
                }
            }
            return noErr
        }
    }

    func start() {
        guard !isRunning else { return }
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: renderer.sampleRate, channels: max(1, min(outputFormat.channelCount, 2))) else {
            lastError = "Unsupported audio format"
            return
        }
        let node = Self.makeSourceNode(renderer: renderer, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        do {
            try engine.start()
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setPattern(_ pattern: Pattern) { renderer.setPattern(pattern) }
    func setMix(_ mix: PreviewMix) { renderer.setMix(mix) }
    func setLooping(_ loop: Bool) { renderer.setLooping(loop) }

    func play() {
        start()
        renderer.play(fromStart: true)
    }

    func stop() { renderer.stop() }
    var isPlaying: Bool { renderer.isPlaying }
    var currentStep: Int { renderer.currentStep }
}

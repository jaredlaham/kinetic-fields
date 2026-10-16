import AVFoundation
import CryptoKit
import Foundation
import StemCore

/// Reads audio metadata and waveform peaks with AVFoundation. Peaks are cached
/// in ~/Library/Caches keyed by path, size and modification date, so reopening
/// a project draws instantly.
enum WaveformLoader {
    static let supportedExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "flac", "mp3", "m4a", "caf"]

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("KineticStemStudio/peaks", isDirectory: true)
    }

    static func fileRef(for url: URL) throws -> AudioFileRef {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.fileFormat
        return AudioFileRef(path: url.standardizedFileURL.path, sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount),
                            frames: file.length, format: url.pathExtension.uppercased())
    }

    static func cacheKey(for url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.standardizedFileURL.path)|\(size)|\(mtime)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads (or computes and caches) peaks. Runs off the main thread.
    static func peaks(for url: URL) async throws -> WaveformPeaks {
        try await Task.detached(priority: .userInitiated) {
            let cached = cacheDirectory.appendingPathComponent(cacheKey(for: url) + ".peaks")
            if let d = try? Data(contentsOf: cached), let p = WaveformPeaks.decode(d) { return p }
            let p = try compute(url)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? p.encoded().write(to: cached, options: .atomic)
            return p
        }.value
    }

    static func compute(_ url: URL) throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let block: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var acc = PeakAccumulator()
        var mono = [Float](repeating: 0, count: Int(block))
        let channels = Int(format.channelCount)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                mono[i] = s / Float(max(1, channels))
            }
            mono.withUnsafeBufferPointer { acc.add(UnsafeBufferPointer(rebasing: $0[0..<n])) }
        }
        return WaveformPeaks(sampleRate: format.sampleRate, frames: file.length, base: acc.finish())
    }
}

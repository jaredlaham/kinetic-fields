import Foundation

/// Min/max peaks of an audio file at a fixed bucket size, with coarser levels
/// for zoomed-out drawing. Stored in the project's cache as little-endian Float32.
public struct WaveformPeaks: Sendable, Equatable {
    public static let bucket = 256
    public var sampleRate: Double
    public var frames: Int64
    /// Interleaved min, max per bucket (level 0).
    public var levels: [[Float]]

    public init(sampleRate: Double, frames: Int64, base: [Float]) {
        self.sampleRate = sampleRate
        self.frames = frames
        var levels = [base]
        var current = base
        while current.count > 4096 {
            var next = [Float]()
            next.reserveCapacity(current.count / 2 + 2)
            var i = 0
            while i + 3 < current.count {
                next.append(min(current[i], current[i + 2]))
                next.append(max(current[i + 1], current[i + 3]))
                i += 4
            }
            if i + 1 < current.count {
                next.append(current[i])
                next.append(current[i + 1])
            }
            levels.append(next)
            current = next
        }
        self.levels = levels
    }

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// The level whose buckets are just finer than `secondsPerPixel`, and its bucket length in seconds.
    public func level(forSecondsPerPixel spp: Double) -> (peaks: [Float], secondsPerBucket: Double) {
        var bucketSeconds = Double(Self.bucket) / sampleRate
        var index = 0
        while index + 1 < levels.count && bucketSeconds * 2 <= spp {
            bucketSeconds *= 2
            index += 1
        }
        return (levels[index], bucketSeconds)
    }

    /// Min/max over [t0, t1).
    public func range(_ t0: Double, _ t1: Double, secondsPerPixel spp: Double) -> (Float, Float) {
        let (peaks, bs) = level(forSecondsPerPixel: spp)
        let n = peaks.count / 2
        guard n > 0 else { return (0, 0) }
        let a = max(0, min(n - 1, Int(t0 / bs)))
        let b = max(a, min(n - 1, Int(t1 / bs)))
        var lo: Float = 0
        var hi: Float = 0
        for i in a...b {
            lo = min(lo, peaks[2 * i])
            hi = max(hi, peaks[2 * i + 1])
        }
        return (lo, hi)
    }

    // MARK: cache encoding

    public func encoded() -> Data {
        var d = Data()
        var header: [Double] = [sampleRate, Double(frames)]
        d.append(Data(bytes: &header, count: MemoryLayout<Double>.size * 2))
        var base = levels[0]
        d.append(Data(bytes: &base, count: base.count * MemoryLayout<Float>.size))
        return d
    }

    public static func decode(_ data: Data) -> WaveformPeaks? {
        let headerSize = MemoryLayout<Double>.size * 2
        guard data.count >= headerSize, (data.count - headerSize) % (2 * MemoryLayout<Float>.size) == 0 else { return nil }
        let header = data.prefix(headerSize).withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        let floats = data.dropFirst(headerSize).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return WaveformPeaks(sampleRate: header[0], frames: Int64(header[1]), base: floats)
    }
}

/// Builds level-0 peaks incrementally from blocks of mono samples.
public struct PeakAccumulator {
    private var lo: Float = .greatestFiniteMagnitude
    private var hi: Float = -.greatestFiniteMagnitude
    private var count = 0
    public private(set) var peaks: [Float] = []

    public init() {}

    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            if s < lo { lo = s }
            if s > hi { hi = s }
            count += 1
            if count == WaveformPeaks.bucket {
                peaks.append(lo)
                peaks.append(hi)
                lo = .greatestFiniteMagnitude
                hi = -.greatestFiniteMagnitude
                count = 0
            }
        }
    }

    public mutating func finish() -> [Float] {
        if count > 0 {
            peaks.append(lo)
            peaks.append(hi)
            count = 0
        }
        return peaks
    }
}

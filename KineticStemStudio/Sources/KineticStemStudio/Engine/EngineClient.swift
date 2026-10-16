import Foundation
import StemCore

/// Runs the Python analysis engine (`python -m kstem <command>`) as a worker
/// process: one process per job, request on stdin, JSON Lines on stdout.
/// Cancelling a job terminates its process; the engine writes nothing in place,
/// so a cancelled job leaves no partial output behind.
final class EngineClient: @unchecked Sendable {
    struct Location: Equatable {
        var python: URL
        var engineDirectory: URL
    }

    enum EngineError: LocalizedError {
        case notInstalled(String)
        case failed(kind: String, message: String)
        case noResult(stderr: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notInstalled(let why): "The analysis engine is not installed: \(why)"
            case .failed(_, let message): message
            case .noResult(let stderr):
                "The engine stopped without a result." + (stderr.isEmpty ? "" : "\n\n" + String(stderr.suffix(1200)))
            case .cancelled: "Cancelled."
            }
        }
    }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KineticStemStudio", isDirectory: true)
    }()

    static var defaultVenv: URL { supportDirectory.appendingPathComponent("engine-venv", isDirectory: true) }

    /// GUI apps start with a minimal PATH; add the usual places for uv, Homebrew and ffmpeg.
    static var processPath: String {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (extra + [current]).joined(separator: ":")
    }

    /// The engine's Python sources: bundled in the app, or the source tree in development.
    static func engineDirectory() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KSTEM_ENGINE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine"),
           fm.fileExists(atPath: res.appendingPathComponent("kstem/__init__.py").path) {
            return res
        }
        // `swift run` from the package: Sources/KineticStemStudio/Engine/EngineClient.swift -> ../../../engine
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine")
        if fm.fileExists(atPath: source.appendingPathComponent("kstem/__init__.py").path) { return source }
        return nil
    }

    /// The installer script, next to the bundled engine or in the source tree.
    static func installScript() -> URL? {
        guard let engine = engineDirectory() else { return nil }
        let script = engine.deletingLastPathComponent().appendingPathComponent("scripts/install-engine.sh")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    static func locate() -> Result<Location, EngineError> {
        guard let engine = engineDirectory() else {
            return .failure(.notInstalled("the engine's Python files are missing from the app bundle."))
        }
        let fm = FileManager.default
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["KSTEM_PYTHON"] { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(defaultVenv.appendingPathComponent("bin/python"))
        for c in candidates where fm.isExecutableFile(atPath: c.path) {
            return .success(Location(python: c, engineDirectory: engine))
        }
        return .failure(.notInstalled("no engine environment at \(defaultVenv.path). Open Engine Setup to install it."))
    }

    private let lock = NSLock()
    private var running: [UUID: Process] = [:]

    /// Runs one engine command and decodes its result.
    func run<Response: Decodable>(
        _ command: String,
        request: some Encodable,
        as: Response.Type,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> Response {
        let data = try await runRaw(command, request: try EngineLineParser.encoder().encode(request), progress: progress)
        do {
            return try EngineLineParser.decoder().decode(Response.self, from: data)
        } catch {
            throw EngineError.failed(kind: "decode", message: "The engine's reply could not be read: \(error)")
        }
    }

    func runRaw(_ command: String, request: Data, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Data {
        let location: Location
        switch Self.locate() {
        case .success(let l): location = l
        case .failure(let e): throw e
        }
        let jobID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let process = Process()
                process.executableURL = location.python
                process.arguments = ["-m", "kstem", command]
                var env = ProcessInfo.processInfo.environment
                env["PYTHONPATH"] = location.engineDirectory.path
                env["PATH"] = Self.processPath
                env["PYTHONUNBUFFERED"] = "1"
                // Keep bytecode out of the (signed) app bundle.
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                env["OMP_NUM_THREADS"] = env["OMP_NUM_THREADS"] ?? "4"
                process.environment = env
                process.currentDirectoryURL = location.engineDirectory

                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                let state = OutputState()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    for line in state.append(chunk) {
                        switch EngineLineParser.parse(line) {
                        case .progress(let f, let m)?: progress(f, m)
                        case .result(let d)?: state.setResult(d)
                        case .error(let kind, let message)?: state.setError(kind, message)
                        case nil: break
                        }
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { state.appendStderr(chunk) }
                }
                process.terminationHandler = { [weak self] p in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    // Drain anything left in the pipe after the handler was removed.
                    let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                    for line in state.append(rest) + state.flush() {
                        switch EngineLineParser.parse(line) {
                        case .result(let d)?: state.setResult(d)
                        case .error(let kind, let message)?: state.setError(kind, message)
                        default: break
                        }
                    }
                    self?.forget(jobID)
                    if p.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: EngineError.cancelled)
                    } else if let r = state.result {
                        continuation.resume(returning: r)
                    } else if let e = state.error {
                        continuation.resume(throwing: EngineError.failed(kind: e.0, message: e.1))
                    } else {
                        continuation.resume(throwing: EngineError.noResult(stderr: state.stderrText))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: EngineError.notInstalled(error.localizedDescription))
                    return
                }
                self.remember(jobID, process)
                stdin.fileHandleForWriting.write(request)
                try? stdin.fileHandleForWriting.close()
            }
        } onCancel: {
            self.cancel(jobID)
        }
    }

    private func remember(_ id: UUID, _ p: Process) {
        lock.lock()
        running[id] = p
        lock.unlock()
    }

    private func forget(_ id: UUID) {
        lock.lock()
        running[id] = nil
        lock.unlock()
    }

    func cancel(_ id: UUID) {
        lock.lock()
        let p = running[id]
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func cancelAll() {
        lock.lock()
        let all = Array(running.values)
        lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

/// Line splitting and result bookkeeping shared between pipe callbacks.
private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrData = Data()
    private(set) var result: Data?
    private(set) var error: (String, String)?

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) else { return [] }
        buffer.removeAll()
        return [s]
    }

    func appendStderr(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        stderrData.append(d)
        if stderrData.count > 64_000 { stderrData.removeFirst(stderrData.count - 64_000) }
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    func setResult(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        result = d
    }

    func setError(_ kind: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        error = (kind, message)
    }
}

/// Runs scripts/install-engine.sh and streams its output.
@MainActor
final class EngineInstaller {
    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    func install(high: Bool, bootstrapUV: Bool, output: @escaping @MainActor (String) -> Void,
                 finished: @escaping @MainActor (Bool) -> Void) {
        guard let script = EngineClient.installScript() else {
            output("The installer script is missing from the app bundle.\n")
            finished(false)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [script.path, "--venv", EngineClient.defaultVenv.path]
        if high { args.append("--high") }
        if bootstrapUV { args.append("--bootstrap-uv") }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EngineClient.processPath
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in output(s) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = proc.terminationStatus == 0
            Task { @MainActor in finished(ok) }
        }
        do {
            try FileManager.default.createDirectory(at: EngineClient.supportDirectory, withIntermediateDirectories: true)
            try p.run()
            process = p
        } catch {
            output("Could not start the installer: \(error.localizedDescription)\n")
            finished(false)
        }
    }

    func cancel() { process?.terminate() }
}

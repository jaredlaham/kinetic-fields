import AppKit
import QuartzCore
import Foundation
import Observation
import StemCore
import UniformTypeIdentifiers

struct JobStatus: Equatable {
    var state: JobState
    var fraction: Double = 0
    var message: String = ""
}

enum EngineStatus: Equatable {
    case checking
    case ready(String)
    case missing(String)
    case problem(String)

    var isReady: Bool { if case .ready = self { true } else { false } }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    var id = UUID()
    var kind: Kind
    var text: String
}

enum ActiveSheet: String, Identifiable {
    case export, engineSetup
    var id: String { rawValue }
}

/// The app's state and every user action. Views read from here and call its methods.
@Observable
@MainActor
final class AppModel {
    // Document
    var project = Project()
    var projectURL: URL?
    var isDirty = false

    // Selection and view
    var selectedStemID: UUID?
    var selectedNoteIDs: Set<UUID> = []
    var pixelsPerSecond: Double = 60
    var viewStart: Double = 0
    var region: ClosedRange<Double>?
    var showConfidence = true

    // Playback
    var playhead: Double = 0
    var isPlaying = false
    var listenMode: ListenMode = .both
    var metronome = false
    var loopRegion = false

    // Jobs
    var peaks: [UUID: WaveformPeaks] = [:]
    var jobs: [UUID: JobStatus] = [:]
    var analysis: JobStatus?
    var engineStatus: EngineStatus = .checking
    var doctor: DoctorResponse?

    // UI
    var sheet: ActiveSheet?
    var banner: Banner?
    var recoveryCandidate: URL?
    var history = EditHistory()

    @ObservationIgnored let engine = EngineClient()
    @ObservationIgnored let playback = PlaybackEngine()
    @ObservationIgnored let midiOut = MIDIOutput()
    @ObservationIgnored private var transcribeQueue: [UUID] = []
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var playTimer: Timer?
    @ObservationIgnored private var autosaveTimer: Timer?
    @ObservationIgnored private var tapTimes: [Double] = []

    static let projectType = UTType(exportedAs: "xyz.kineticfields.stemstudio.project", conformingTo: .package)
    static var autosaveDirectory: URL { EngineClient.supportDirectory.appendingPathComponent("Autosave", isDirectory: true) }

    init() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        recoveryCandidate = Self.findAutosave()
        checkEngine()
    }

    // MARK: - Derived

    var selectedStem: Stem? { project.stems.first { $0.id == selectedStemID } }
    var selectedIndex: Int? { project.stems.firstIndex { $0.id == selectedStemID } }
    var duration: Double { max(project.duration, 1) }
    var title: String { (projectURL?.deletingPathExtension().lastPathComponent ?? project.name) + (isDirty ? " (edited)" : "") }
    var isBusy: Bool { analysis != nil || jobs.values.contains { $0.state == .transcribing || $0.state == .queued } }

    func index(of id: UUID) -> Int? { project.stems.firstIndex { $0.id == id } }

    func show(_ kind: Banner.Kind, _ text: String) { banner = Banner(kind: kind, text: text) }

    private func changed() {
        isDirty = true
        project.modified = Date()
    }

    // MARK: - Engine

    func checkEngine() {
        engineStatus = .checking
        Task {
            do {
                let r = try await engine.run("doctor", request: [String: String](), as: DoctorResponse.self)
                doctor = r
                if r.ok {
                    engineStatus = .ready(r.version)
                } else {
                    let failing = r.checks.filter { !$0.ok && $0.required }.map(\.name).joined(separator: ", ")
                    engineStatus = .problem("Missing: \(failing)")
                }
            } catch let e as EngineClient.EngineError {
                if case .notInstalled(let why) = e { engineStatus = .missing(why) } else { engineStatus = .problem(e.localizedDescription) }
            } catch {
                engineStatus = .problem(error.localizedDescription)
            }
        }
    }

    // MARK: - Stems

    func importFiles(_ urls: [URL]) {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if url.pathExtension == ProjectStore.fileExtension { open(url); return }
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += items.filter { WaveformLoader.supportedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if WaveformLoader.supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        let existing = Set(project.stems.map(\.file.path))
        var added: [UUID] = []
        var failed: [String] = []
        for url in files where !existing.contains(url.standardizedFileURL.path) {
            do {
                let ref = try WaveformLoader.fileRef(for: url)
                let stem = Stem(name: url.deletingPathExtension().lastPathComponent, file: ref, colorIndex: project.stems.count)
                project.stems.append(stem)
                added.append(stem.id)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            show(.error, "Could not read \(failed.joined(separator: ", ")). Supported: WAV, AIFF, FLAC, MP3, M4A.")
        } else if files.isEmpty {
            show(.warning, "No audio files found. Supported: WAV, AIFF, FLAC, MP3, M4A.")
        }
        guard !added.isEmpty else { return }
        changed()
        if selectedStemID == nil { selectedStemID = added.first }
        for id in added { loadPeaks(id) }
        analyze()
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose stems or a folder of stems"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func replaceAudio(_ id: UUID) {
        guard let i = index(of: id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose the replacement audio for “\(project.stems[i].name)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            project.stems[i].file = try WaveformLoader.fileRef(for: url)
            project.stems[i].transcription = nil
            project.stems[i].editedNotes = nil
            project.stems[i].lastError = nil
            peaks[id] = nil
            changed()
            loadPeaks(id)
            analyze()
        } catch {
            show(.error, "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func removeStem(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if project.stems[i].hasEdits && !confirm("Remove “\(project.stems[i].name)”?", "Its note edits will be lost. The audio file is not touched.") { return }
        cancelTranscription(id)
        project.stems.remove(at: i)
        peaks[id] = nil
        jobs[id] = nil
        if selectedStemID == id { selectedStemID = project.stems.first?.id }
        selectedNoteIDs.removeAll()
        changed()
    }

    func moveStems(from: IndexSet, to: Int) {
        project.stems.move(fromOffsets: from, toOffset: to)
        changed()
    }

    func updateStem(_ id: UUID, _ f: (inout Stem) -> Void) {
        guard let i = index(of: id) else { return }
        f(&project.stems[i])
        changed()
    }

    func loadPeaks(_ id: UUID) {
        guard let stem = project.stems.first(where: { $0.id == id }) else { return }
        let url = stem.file.url
        Task {
            do {
                peaks[id] = try await WaveformLoader.peaks(for: url)
            } catch {
                updateStem(id) { $0.lastError = "Audio unreadable: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Analysis (tempo + instrument)

    func analyze() {
        analysisTask?.cancel()
        let stems = project.stems.filter { FileManager.default.fileExists(atPath: $0.file.path) }
        guard !stems.isEmpty else { return }
        let request = AnalyzeRequest(files: stems.map { .init(id: $0.id.uuidString, path: $0.file.path) },
                                     beatsPerBar: project.tempo.beatsPerBar)
        analysis = JobStatus(state: .analyzing, message: "Starting the engine")
        analysisTask = Task {
            do {
                let r = try await engine.run("analyze", request: request, as: AnalyzeResponse.self) { f, m in
                    Task { @MainActor [weak self] in self?.analysis = JobStatus(state: .analyzing, fraction: f, message: m) }
                }
                apply(r)
                analysis = nil
            } catch is CancellationError {
                analysis = nil
            } catch {
                analysis = nil
                if case EngineClient.EngineError.notInstalled = error { sheet = .engineSetup }
                show(.error, "Analysis failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ r: AnalyzeResponse) {
        for info in r.stems {
            guard let idString = info.id, let id = UUID(uuidString: idString), let i = index(of: id) else { continue }
            project.stems[i].file.sha256 = info.sha256
            project.stems[i].leadingSilence = info.leadingSilence
            if let c = info.classification?.model { project.stems[i].classification = c }
            if project.stems[i].classification?.proposed == .drums && project.stems[i].instrumentOverride == nil {
                project.stems[i].midiChannel = 10
            }
        }
        // A tempo the user typed or tapped is never overwritten by detection.
        if project.tempo.source == .none || project.tempo.source == .detected {
            let t = r.tempo
            project.tempo = TempoMap(bpm: t.bpm, beatsPerBar: project.tempo.beatsPerBar, beatUnit: project.tempo.beatUnit,
                                     downbeat: t.downbeat, source: .detected, confidence: t.confidence,
                                     alternatives: t.alternatives, stable: t.tempoStable, warnings: t.warnings)
        }
        changed()
        show(.success, String(format: "Detected %.2f BPM. Check the grid against the audio, then transcribe.", r.tempo.bpm))
    }

    // MARK: - Transcription

    func transcribe(_ ids: [UUID], force: Bool = false) {
        var queued: [UUID] = []
        for id in ids {
            guard let stem = project.stems.first(where: { $0.id == id }) else { continue }
            if !force, let t = stem.transcription, let sha = stem.file.sha256,
               t.matches(sha: sha, mode: stem.mode, instrument: stem.instrument, pitchBends: stem.pitchBends) {
                continue  // cached: same audio and settings
            }
            if stem.hasEdits && !confirm("Transcribe “\(stem.name)” again?", "This replaces your note edits on this stem. You can undo it.") { continue }
            if transcribeQueue.contains(id) || jobs[id]?.state == .transcribing { continue }
            transcribeQueue.append(id)
            jobs[id] = JobStatus(state: .queued, message: "Waiting")
            queued.append(id)
        }
        if queued.isEmpty && ids.count == 1 { show(.info, "Already transcribed with these settings.") }
        if queueTask == nil { runQueue() }
    }

    func transcribeAll() { transcribe(project.stems.map(\.id)) }

    private func runQueue() {
        queueTask = Task {
            while !transcribeQueue.isEmpty {
                let id = transcribeQueue.removeFirst()
                await transcribeOne(id)
            }
            queueTask = nil
        }
    }

    private func transcribeOne(_ id: UUID) async {
        guard let stem = project.stems.first(where: { $0.id == id }) else { return }
        guard jobs[id]?.state == .queued else { return }  // cancelled while waiting
        jobs[id] = JobStatus(state: .transcribing, message: "Starting")
        let request = TranscribeRequest(path: stem.file.path, instrument: stem.instrument, mode: stem.mode,
                                        pitchBends: stem.pitchBends, sensitivity: stem.drumSensitivity)
        let pitchBends = stem.pitchBends
        let task = Task { () throws -> TranscribeResponse in
            try await engine.run("transcribe", request: request, as: TranscribeResponse.self) { f, m in
                Task { @MainActor [weak self] in
                    if self?.jobs[id]?.state == .transcribing { self?.jobs[id] = JobStatus(state: .transcribing, fraction: f, message: m) }
                }
            }
        }
        runningTasks[id] = task
        defer { runningTasks[id] = nil }
        do {
            let r = try await task.value
            guard let i = index(of: id) else { return }
            let before = project.stems[i].editedNotes
            let t = r.transcription(pitchBends: pitchBends)
            project.stems[i].transcription = t
            project.stems[i].file.sha256 = r.audioSha256
            project.stems[i].editedNotes = nil
            project.stems[i].lastError = nil
            if before != nil { history.record(stem: id, before: before, after: nil, label: "Transcribe") }
            jobs[id] = JobStatus(state: .done, fraction: 1, message: String(format: "%d notes in %.1f s", t.notes.count, t.processingSeconds))
            changed()
        } catch {
            if case EngineClient.EngineError.cancelled = error {
                jobs[id] = JobStatus(state: .cancelled, message: "Cancelled")
            } else if error is CancellationError {
                jobs[id] = JobStatus(state: .cancelled, message: "Cancelled")
            } else {
                jobs[id] = JobStatus(state: .failed, message: error.localizedDescription)
                updateStem(id) { $0.lastError = error.localizedDescription }
                if case EngineClient.EngineError.notInstalled = error { sheet = .engineSetup }
            }
        }
    }

    @ObservationIgnored private var runningTasks: [UUID: Task<TranscribeResponse, Error>] = [:]

    func cancelTranscription(_ id: UUID) {
        transcribeQueue.removeAll { $0 == id }
        if jobs[id]?.state == .queued { jobs[id] = JobStatus(state: .cancelled, message: "Cancelled") }
        runningTasks[id]?.cancel()
    }

    func cancelAll() {
        for id in transcribeQueue { jobs[id] = JobStatus(state: .cancelled, message: "Cancelled") }
        transcribeQueue.removeAll()
        for t in runningTasks.values { t.cancel() }
        analysisTask?.cancel()
        engine.cancelAll()
    }

    // MARK: - Note editing (undoable)

    func edit(_ label: String, stem id: UUID, _ f: ([NoteEvent]) -> [NoteEvent]) {
        guard let i = index(of: id) else { return }
        let before = project.stems[i].editedNotes
        let after = f(project.stems[i].notes)
        project.stems[i].editedNotes = after
        history.record(stem: id, before: before, after: after, label: label)
        changed()
    }

    func undo() {
        guard let e = history.undo(), let i = index(of: e.stemID) else { return }
        project.stems[i].editedNotes = e.before
        selectedNoteIDs.formIntersection(Set(project.stems[i].notes.map(\.id)))
        changed()
    }

    func redo() {
        guard let e = history.redo(), let i = index(of: e.stemID) else { return }
        project.stems[i].editedNotes = e.after
        changed()
    }

    func deleteSelectedNotes() {
        guard let id = selectedStemID, !selectedNoteIDs.isEmpty else { return }
        let ids = selectedNoteIDs
        edit("Delete Notes", stem: id) { NoteEditor.delete(ids, from: $0) }
        selectedNoteIDs.removeAll()
    }

    func setAccepted(_ value: Bool?, ids: Set<UUID>? = nil) {
        guard let id = selectedStemID else { return }
        let target = ids ?? selectedNoteIDs
        guard !target.isEmpty else { return }
        edit(value == false ? "Reject Notes" : "Accept Notes", stem: id) { NoteEditor.setAccepted(target, in: $0, to: value) }
    }

    /// Rejects every note under the stem's confidence threshold (kept, not exported).
    func rejectBelowThreshold() {
        guard let stem = selectedStem else { return }
        let ids = Set(stem.notes.filter { $0.accepted == nil && $0.confidence < stem.confidenceThreshold }.map(\.id))
        guard !ids.isEmpty else { show(.info, "No unreviewed notes below the threshold."); return }
        edit("Reject Low-Confidence Notes", stem: stem.id) { NoteEditor.setAccepted(ids, in: $0, to: false) }
    }

    func quantizeSelection() {
        guard let id = selectedStemID, !selectedNoteIDs.isEmpty else { return }
        let ids = selectedNoteIDs, tempo = project.tempo, q = project.quantize
        edit("Quantize Notes", stem: id) { NoteEditor.quantize(ids, in: $0, tempo: tempo, settings: q) }
    }

    func revertToTranscription() {
        guard let stem = selectedStem, stem.hasEdits else { return }
        if !confirm("Revert “\(stem.name)” to the engine's notes?", "All edits on this stem are discarded. You can undo it.") { return }
        let before = stem.editedNotes
        updateStem(stem.id) { $0.editedNotes = nil }
        history.record(stem: stem.id, before: before, after: nil, label: "Revert")
        selectedNoteIDs.removeAll()
    }

    /// Notes as they are heard and exported: threshold and review applied, and quantised when enabled.
    func outputNotes(_ stem: Stem, quantized: Bool) -> [NoteEvent] {
        var notes = stem.exportableNotes
        if quantized {
            var q = project.quantize
            q.enabled = true
            notes = Quantizer.apply(notes, tempo: project.tempo, settings: q)
        }
        return notes
    }

    // MARK: - Tempo

    func setBPM(_ bpm: Double, source: TempoSource = .manual) {
        guard bpm.isFinite, bpm >= 20, bpm <= 400 else { return }
        project.tempo.bpm = bpm
        project.tempo.source = source
        changed()
    }

    func halveTempo() { setBPM(project.tempo.bpm / 2) }
    func doubleTempo() { setBPM(project.tempo.bpm * 2) }

    func tap() {
        let now = CACurrentMediaTime()
        if let last = tapTimes.last, now - last > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst(tapTimes.count - 8) }
        guard tapTimes.count >= 3 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        setBPM((60 / median * 10).rounded() / 10, source: .tapped)
    }

    func setMeter(beatsPerBar: Int, beatUnit: Int) {
        project.tempo.beatsPerBar = beatsPerBar
        project.tempo.beatUnit = beatUnit
        changed()
    }

    func setDownbeatAtPlayhead() {
        project.tempo.downbeat = playhead
        if project.tempo.source == .detected { project.tempo.source = .manual }
        changed()
    }

    func nudgeDownbeat(beats: Double) {
        project.tempo.downbeat += beats * project.tempo.secondsPerBeat
        changed()
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        let audible = project.stems.map { s -> PlaybackEngine.StemPlayback in
            PlaybackEngine.StemPlayback(id: s.id, url: s.file.url, gain: Float(pow(10, s.volumeDB / 20)),
                                        audible: project.isAudible(s), notes: outputNotes(s, quantized: project.quantize.enabled),
                                        program: s.instrument.previewProgram, isDrums: s.instrument.isDrums)
        }.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        var from = playhead
        if loopRegion, let r = region, !(r.contains(from)) { from = r.lowerBound }
        if from >= duration - 0.05 { from = 0 }
        playback.play(stems: audible, mode: listenMode, tempo: project.tempo, metronome: metronome, from: from, until: duration)
        if let e = playback.lastError { show(.error, e); return }
        isPlaying = true
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let p = playback.position
        if loopRegion, let r = region, p >= r.upperBound {
            playhead = r.lowerBound
            play()
            return
        }
        if p >= duration {
            stop()
            playhead = 0
            return
        }
        playhead = p
        // Keep the playhead in view.
        let visible = viewportWidth / pixelsPerSecond
        if p > viewStart + visible * 0.92 || p < viewStart { viewStart = max(0, p - visible * 0.1) }
    }

    func stop() {
        playback.stop()
        playTimer?.invalidate()
        playTimer = nil
        if isPlaying { playhead = playback.position }
        isPlaying = false
    }

    func seek(_ t: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        playhead = max(0, min(duration, t))
        playback.seek(playhead)
        if wasPlaying { play() }
    }

    /// Set by the timeline so scrolling and zoom know the visible width.
    var viewportWidth: Double = 800

    func zoom(by factor: Double, around t: Double? = nil) {
        let anchor = t ?? (viewStart + viewportWidth / pixelsPerSecond / 2)
        let old = pixelsPerSecond
        pixelsPerSecond = max(4, min(2000, pixelsPerSecond * factor))
        viewStart = max(0, anchor - (anchor - viewStart) * old / pixelsPerSecond)
    }

    func zoomToFit() {
        pixelsPerSecond = max(4, viewportWidth / duration)
        viewStart = 0
    }

    func scroll(seconds: Double) {
        let maxStart = max(0, duration - viewportWidth / pixelsPerSecond * 0.5)
        viewStart = max(0, min(maxStart, viewStart + seconds))
    }

    // MARK: - Documents

    func newProject() {
        guard confirmDiscard() else { return }
        stop()
        cancelAll()
        clearAutosave()
        project = Project()
        projectURL = nil
        isDirty = false
        peaks.removeAll()
        jobs.removeAll()
        history = EditHistory()
        selectedStemID = nil
        selectedNoteIDs.removeAll()
        region = nil
        playhead = 0
    }

    func openWithPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Open a Kinetic Stem Studio project (.kineticstem)"
        if panel.runModal() == .OK, let url = panel.url { open(url, confirmed: true) }
    }

    func open(_ url: URL, confirmed: Bool = false) {
        guard confirmed || confirmDiscard() else { return }
        do {
            let p = try ProjectStore.load(from: url)
            stop()
            cancelAll()
            clearAutosave()
            project = p
            projectURL = url
            isDirty = false
            history = EditHistory()
            peaks.removeAll()
            jobs.removeAll()
            selectedStemID = p.stems.first?.id
            selectedNoteIDs.removeAll()
            region = nil
            playhead = 0
            viewStart = 0
            let missing = p.stems.filter { !FileManager.default.fileExists(atPath: $0.file.path) }
            for s in p.stems where !missing.contains(where: { $0.id == s.id }) { loadPeaks(s.id) }
            if !missing.isEmpty {
                show(.warning, "Audio not found for \(missing.map(\.name).joined(separator: ", ")). Use Replace Audio on those stems.")
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = projectURL else { return saveAs() }
        do {
            project.name = url.deletingPathExtension().lastPathComponent
            try ProjectStore.save(project, to: url)
            isDirty = false
            clearAutosave()
            show(.success, "Saved \(url.lastPathComponent)")
            return true
        } catch {
            show(.error, "Could not save: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = project.name + "." + ProjectStore.fileExtension
        panel.message = "Audio files stay where they are; the project refers to them."
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension != ProjectStore.fileExtension { url.appendPathExtension(ProjectStore.fileExtension) }
        projectURL = url
        return save()
    }

    /// True when it is fine to replace the current project.
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(project.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func confirm(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Autosave and recovery

    private var autosaveURL: URL { Self.autosaveDirectory.appendingPathComponent(project.id.uuidString + "." + ProjectStore.fileExtension) }

    func autosave() {
        guard isDirty, !project.stems.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: Self.autosaveDirectory, withIntermediateDirectories: true)
            try ProjectStore.save(project, to: autosaveURL)
            if let original = projectURL {
                try? original.path.write(to: autosaveURL.appendingPathComponent("original-location.txt"), atomically: true, encoding: .utf8)
            }
        } catch {
            // Autosave failures are not fatal; the next attempt retries.
        }
    }

    func clearAutosave() {
        try? FileManager.default.removeItem(at: autosaveURL)
    }

    static func findAutosave() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: autosaveDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == ProjectStore.fileExtension }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    func recover() {
        guard let url = recoveryCandidate else { return }
        recoveryCandidate = nil
        do {
            let p = try ProjectStore.load(from: url)
            let originalPath = try? String(contentsOf: url.appendingPathComponent("original-location.txt"), encoding: .utf8)
            project = p
            projectURL = originalPath.map { URL(fileURLWithPath: $0) }
            isDirty = true
            selectedStemID = p.stems.first?.id
            for s in p.stems { loadPeaks(s.id) }
            try? FileManager.default.removeItem(at: url)
            show(.success, "Recovered unsaved work. Save it to keep it.")
        } catch {
            show(.error, "Could not recover: \(error.localizedDescription)")
        }
    }

    func discardRecovery() {
        if let url = recoveryCandidate { try? FileManager.default.removeItem(at: url) }
        recoveryCandidate = Self.findAutosave()
    }
}

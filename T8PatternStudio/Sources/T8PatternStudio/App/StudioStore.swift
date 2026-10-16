import AppKit
import CoreMIDI
import Foundation
import Observation
import T8Core
import UniformTypeIdentifiers

enum PlaybackTarget: String, CaseIterable, Identifiable {
    case internalAudio = "Internal Preview Audio"
    case t8MIDI = "Roland T-8 MIDI Playback"
    var id: String { rawValue }
}

enum LoadMode: String, CaseIterable, Identifiable {
    case full = "Load Full Pattern"
    case drumsOnly = "Load Drums Only"
    case bassOnly = "Load Bass Only"
    var id: String { rawValue }
}

enum ActiveSheet: Identifiable {
    case savePresetAs
    case editMetadata(PresetID)
    case manageLibrary
    case midiImport
    case transfer
    case capabilities

    var id: String {
        switch self {
        case .savePresetAs: "saveAs"
        case .editMetadata(let id): "meta-\(id)"
        case .manageLibrary: "manage"
        case .midiImport: "midiImport"
        case .transfer: "transfer"
        case .capabilities: "capabilities"
        }
    }
}

/// An action waiting for the user to resolve unsaved changes.
struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let perform: @MainActor () -> Void
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case step = "Step"
    case ai = "AI"
    case blend = "Blend"
    case mixer = "Mixer"
    var id: String { rawValue }
}

/// Central application state. All UI reads from here; engines are driven from here.
@MainActor
@Observable
final class StudioStore {
    // MARK: Library
    var library: PresetLibrary
    let libraryStore: LibraryStore
    var libraryLoadMessage: String?

    // MARK: Working pattern
    /// The library preset the working pattern came from (nil = new, unsaved).
    var currentPresetID: PresetID?
    var variations: PatternVariations
    var activeSlot: VariationSlot = .a
    private(set) var savedSnapshot: PatternVariations
    private var history = UndoHistory<PatternVariations>()
    var clipboard: StepClipboard?
    var selection: StepSelection?
    /// Step whose attributes are shown in the Step inspector (voice nil = bass).
    var focusedStep: (voice: DrumVoice?, step: Int)?
    var scaleLock = true

    // MARK: Playback
    let audio = AudioPreviewEngine()
    let midi = MIDIEngine()
    var playbackTarget: PlaybackTarget = .internalAudio
    var isPlaying = false
    var isLooping = true
    var playheadStep: Int?
    var previewingPresetID: PresetID?
    var mix = PreviewMix()
    var midiDestinations: [MIDIDestination] = []
    var selectedDestinationID: MIDIUniqueID?
    var t8Connected = false
    var rhythmChannel = 10
    var bassChannel = 2
    private var playheadTimer: Timer?

    // MARK: UI
    var activeSheet: ActiveSheet?
    var pendingAction: PendingAction?
    var pendingDelete: PresetID?
    var errorMessage: String?
    var statusMessage: String?
    var inspectorTab: InspectorTab = .step
    var browserCategory: LibraryCategory = .factory
    var showBrowser = true

    // MARK: AI
    var aiBusy = false
    var aiPrompt = ""
    var aiLastExplanation: String?
    var hasAPIKey = Keychain.readAPIKey()?.isEmpty == false
    var aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? AIPatternGenerator.defaultModel

    // MARK: Hardware settings
    var bassNoteOffset: Int = UserDefaults.standard.object(forKey: "bassNoteOffset") as? Int ?? T8BassNoteMapping.assumed.midiNoteForZero
    var hardwareVerified: Bool = UserDefaults.standard.bool(forKey: "hardwareVerified")

    init() {
        libraryStore = LibraryStore(directory: LibraryStore.defaultDirectory())
        var loaded = PresetLibrary()
        do {
            let result = try libraryStore.load()
            loaded = PresetLibrary(document: result.document)
            if let from = result.migratedFrom { libraryLoadMessage = "Your library was upgraded from schema \(from). A backup was saved first." }
            if result.recoveredFromCorruption { libraryLoadMessage = "Your library file was damaged and has been restored from the most recent backup. The damaged file was kept." }
        } catch {
            libraryLoadMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        library = loaded
        let start = FactoryLibrary.presets.first!
        variations = start.variations
        savedSnapshot = start.variations
        currentPresetID = start.id

        audio.setPattern(variations[activeSlot])
        audio.setMix(mix)
        midi.onDevicesChanged = { [weak self] in self?.refreshMIDI() }
        refreshMIDI()
    }

    // MARK: Derived

    var pattern: Pattern { variations[activeSlot] }
    var isDirty: Bool { variations != savedSnapshot }
    var currentPreset: Preset? { currentPresetID.flatMap { library.preset($0) } }
    var currentIsFactory: Bool { currentPreset?.isFactory ?? false }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var bassMapping: T8BassNoteMapping { T8BassNoteMapping(midiNoteForZero: bassNoteOffset) }

    var displayName: String {
        let name = currentPreset?.name ?? pattern.name
        return isDirty ? "\(name) — Edited" : name
    }

    // MARK: Editing

    /// Applies an edit to the active variation with undo support.
    func edit(_ change: (inout Pattern) -> Void) {
        var updated = variations[activeSlot]
        change(&updated)
        guard updated != variations[activeSlot] else { return }
        history.record(variations)
        variations[activeSlot] = updated
        patternDidChange()
    }

    /// Edits every variation (e.g. tempo and key apply to the whole preset).
    func editAll(_ change: (inout Pattern) -> Void) {
        var updated = variations
        for slot in VariationSlot.allCases { change(&updated[slot]) }
        guard updated != variations else { return }
        history.record(variations)
        variations = updated
        patternDidChange()
    }

    func replaceVariations(_ new: PatternVariations, recordUndo: Bool = true) {
        if recordUndo { history.record(variations) }
        variations = new
        patternDidChange()
    }

    func undo() {
        guard let previous = history.undo(current: variations) else { return }
        variations = previous
        patternDidChange()
    }

    func redo() {
        guard let next = history.redo(current: variations) else { return }
        variations = next
        patternDidChange()
    }

    func selectSlot(_ slot: VariationSlot) {
        activeSlot = slot
        selection = nil
        patternDidChange()
    }

    /// Re-derives one variation from the foundation (A).
    func regenerateVariation(_ slot: VariationSlot) {
        guard slot != .a else { return }
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        var updated = variations
        updated[slot] = PatternVariationEngine.variation(slot, from: variations.a, seed: seed)
        replaceVariations(updated)
    }

    func copyVariation(_ from: VariationSlot, to: VariationSlot) {
        var updated = variations
        updated[to] = variations[from]
        replaceVariations(updated)
    }

    func copySelection() {
        let sel = selection ?? .all(length: pattern.length)
        clipboard = PatternEditor.copy(pattern, selection: sel)
        statusMessage = "Copied \(sel.steps.count) steps"
    }

    func pasteAtSelection() {
        guard let clipboard else { return }
        let start = selection?.steps.lowerBound ?? 0
        edit { PatternEditor.paste(clipboard, into: &$0, at: start) }
    }

    func clearSelection() {
        let sel = selection ?? .all(length: pattern.length)
        edit { PatternEditor.clear(&$0, selection: sel) }
    }

    private func patternDidChange() {
        let current = pattern
        if previewingPresetID == nil {
            audio.setPattern(current)
            if playbackTarget == .t8MIDI { midi.update(pattern: current) }
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        previewingPresetID = nil
        start(pattern: pattern)
    }

    private func start(pattern: Pattern) {
        stopEngines()
        switch playbackTarget {
        case .internalAudio:
            audio.setPattern(pattern)
            audio.setLooping(isLooping)
            audio.play()
            if let error = audio.lastError { errorMessage = "Audio could not start: \(error)" }
        case .t8MIDI:
            guard let destination = selectedDestination else {
                errorMessage = "Choose a MIDI output (your T-8) first."
                return
            }
            midi.play(pattern: pattern, to: destination, rhythmChannel: UInt8(rhythmChannel - 1), bassChannel: UInt8(bassChannel - 1), loop: isLooping)
        }
        isPlaying = true
        startPlayheadTimer()
    }

    func stop() {
        stopEngines()
        isPlaying = false
        playheadStep = nil
        if previewingPresetID != nil {
            previewingPresetID = nil
            audio.setPattern(pattern)
        }
    }

    private func stopEngines() {
        audio.stop()
        midi.stop()
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    /// UI-only polling of the playhead; audio/MIDI timing never depends on this timer.
    private func startPlayheadTimer() {
        playheadTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePlayhead() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func updatePlayhead() {
        switch playbackTarget {
        case .internalAudio:
            if !audio.isPlaying { isPlaying = false; playheadStep = nil; return }
            playheadStep = audio.currentStep
        case .t8MIDI:
            if !midi.isPlaying { isPlaying = false; playheadStep = nil; return }
            playheadStep = midi.currentStep
        }
    }

    func setLooping(_ loop: Bool) {
        isLooping = loop
        audio.setLooping(loop)
    }

    func updateMix(_ change: (inout PreviewMix) -> Void) {
        change(&mix)
        audio.setMix(mix)
    }

    // MARK: MIDI devices

    var selectedDestination: MIDIDestination? {
        midiDestinations.first { $0.id == selectedDestinationID }
    }

    func refreshMIDI() {
        midiDestinations = midi.destinations()
        t8Connected = midi.isT8Connected()
        if selectedDestination == nil {
            selectedDestinationID = midiDestinations.first(where: \.isT8)?.id ?? midiDestinations.first?.id
        }
    }

    // MARK: Preview & loading

    func preview(_ preset: Preset) {
        if previewingPresetID == preset.id && isPlaying {
            stop()
            return
        }
        previewingPresetID = preset.id
        start(pattern: preset.main) // the working pattern is untouched
    }

    /// Loads a preset, asking first if there are unsaved changes.
    func requestLoad(_ preset: Preset, mode: LoadMode = .full) {
        guardUnsaved(title: "Load “\(preset.name)”?") { [weak self] in self?.load(preset, mode: mode) }
    }

    func load(_ preset: Preset, mode: LoadMode) {
        let wasPlaying = isPlaying
        if previewingPresetID != nil { stop() }
        switch mode {
        case .full:
            variations = preset.variations
            savedSnapshot = preset.variations
            currentPresetID = preset.id
            history.clear()
        case .drumsOnly:
            var updated = variations
            for slot in VariationSlot.allCases {
                updated[slot].drums = preset.variations[slot].drums
                updated[slot].length = preset.variations[slot].length
                updated[slot].swing = preset.variations[slot].swing
            }
            replaceVariations(updated)
        case .bassOnly:
            var updated = variations
            for slot in VariationSlot.allCases {
                updated[slot].bass = preset.variations[slot].bass
                updated[slot].key = preset.variations[slot].key
                updated[slot].scale = preset.variations[slot].scale
            }
            replaceVariations(updated)
        }
        library.markRecent(preset.id)
        persist()
        selection = nil
        focusedStep = nil
        patternDidChange()
        if wasPlaying { play() }
        statusMessage = "\(mode.rawValue): \(preset.name)"
    }

    /// "Save As" on a library preset: load it, then open the Save As dialog.
    func saveAs(from preset: Preset) {
        guardUnsaved(title: "Load “\(preset.name)” to save a copy?") { [weak self] in
            self?.load(preset, mode: .full)
            self?.activeSheet = .savePresetAs
        }
    }

    func guardUnsaved(title: String, _ action: @escaping @MainActor () -> Void) {
        if isDirty {
            pendingAction = PendingAction(title: title, perform: action)
        } else {
            action()
        }
    }

    func newPreset() {
        guardUnsaved(title: "Start a new preset?") { [weak self] in
            guard let self else { return }
            var blank = Pattern(name: "New Pattern", bpm: self.pattern.bpm)
            blank.drums[.kick, 0] = .normal
            let fresh = PatternVariations(a: blank, b: blank, c: blank, d: blank)
            self.variations = fresh
            self.savedSnapshot = fresh
            self.currentPresetID = nil
            self.history.clear()
            self.patternDidChange()
        }
    }

    // MARK: Saving

    /// "Save Preset": overwrites the current user preset; factory or new patterns go to Save As.
    func save() {
        guard let id = currentPresetID, let preset = library.preset(id), !preset.isFactory else {
            activeSheet = .savePresetAs
            return
        }
        do {
            try library.update(id, variations: variations)
            savedSnapshot = variations
            persist()
            statusMessage = "Saved “\(preset.name)”"
        } catch {
            show(error)
        }
    }

    func saveAs(metadata: PresetMetadata) -> Bool {
        do {
            var named = variations
            for slot in VariationSlot.allCases { named[slot].name = metadata.name }
            let preset = try library.saveNew(variations: named, metadata: metadata)
            variations = named
            savedSnapshot = named
            currentPresetID = preset.id
            library.markRecent(preset.id)
            persist()
            statusMessage = "Saved “\(preset.name)”"
            return true
        } catch {
            show(error)
            return false
        }
    }

    func duplicateCurrent() {
        guard let id = currentPresetID else { activeSheet = .savePresetAs; return }
        mutateLibrary { lib in
            let copy = try lib.duplicate(id)
            self.statusMessage = "Duplicated as “\(copy.name)”"
        }
    }

    func persist() {
        do {
            try libraryStore.save(library.document)
        } catch {
            errorMessage = "Could not save the library: \(error.localizedDescription)"
        }
    }

    func mutateLibrary(_ change: (inout PresetLibrary) throws -> Void) {
        do {
            try change(&library)
            persist()
        } catch {
            show(error)
        }
    }

    func toggleFavorite(_ id: PresetID) {
        library.toggleFavorite(id)
        persist()
    }

    func confirmDelete(_ id: PresetID) {
        mutateLibrary { try $0.delete(id) }
        if currentPresetID == id { currentPresetID = nil }
        pendingDelete = nil
    }

    // MARK: Import / export

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PresetBundle.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var count = 0
        for url in panel.urls {
            do {
                let bundle = try PresetBundle.decode(Data(contentsOf: url))
                count += library.importPresets(bundle).count
            } catch {
                show(error)
            }
        }
        persist()
        if count > 0 { statusMessage = "Imported \(count) preset\(count == 1 ? "" : "s") into My Presets" }
    }

    func exportPresets(_ ids: [PresetID]) {
        guard !ids.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PresetBundle.fileExtension) ?? .json]
        panel.nameFieldStringValue = (ids.count == 1 ? library.preset(ids[0])?.name ?? "Presets" : "T-8 Presets") + "." + PresetBundle.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportBundle(ids).encoded().write(to: url, options: .atomic)
            statusMessage = "Exported \(ids.count) preset\(ids.count == 1 ? "" : "s")"
        } catch {
            show(error)
        }
    }

    func exportMIDI() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = "\(currentPreset?.name ?? pattern.name) \(activeSlot.letter).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MIDIFileExporter.export(pattern).serialized().write(to: url, options: .atomic)
            statusMessage = "Exported MIDI for Ableton Live: \(url.lastPathComponent)"
        } catch {
            show(error)
        }
    }

    func exportAllVariationsMIDI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            for slot in VariationSlot.allCases {
                let name = "\(currentPreset?.name ?? pattern.name) \(slot.letter) - \(slot.title).mid"
                try MIDIFileExporter.export(variations[slot]).serialized().write(to: dir.appendingPathComponent(name), options: .atomic)
            }
            statusMessage = "Exported A/B/C/D as four MIDI files"
        } catch {
            show(error)
        }
    }

    // MARK: AI

    func runAI(_ kind: AIRequestKind) {
        guard let key = Keychain.readAPIKey(), !key.isEmpty else {
            errorMessage = AIError.missingAPIKey.errorDescription
            return
        }
        let generator = AIPatternGenerator(apiKey: key, model: aiModel)
        let genre = currentPreset?.primaryGenre
        let references = genre.map { FactoryLibrary.presets(for: $0) } ?? []
        let context = AIContext(current: pattern, genre: genre, referencePresets: references)
        aiBusy = true
        aiLastExplanation = nil
        Task {
            do {
                let result = try await generator.generate(kind, context: context)
                self.applyAIResult(result, kind: kind)
            } catch {
                self.show(error)
            }
            self.aiBusy = false
        }
    }

    private func applyAIResult(_ result: AIPatternGenerator.Result, kind: AIRequestKind) {
        switch kind {
        case .edit:
            edit { $0 = result.pattern }
        case .variation(let slot):
            var updated = variations
            updated[slot] = result.pattern
            replaceVariations(updated)
            activeSlot = slot
        case .create, .blend, .surprise:
            let derived = PatternVariationEngine.makeVariations(from: result.pattern, genre: nil, seed: UInt64(Date().timeIntervalSince1970))
            replaceVariations(derived)
            currentPresetID = nil
            activeSlot = .a
        }
        aiLastExplanation = result.explanation
        let notes = result.issues.filter { $0.severity == .warning }.map(\.message)
        statusMessage = "AI: \(result.pattern.name)" + (notes.isEmpty ? "" : " (\(notes.count) warning\(notes.count == 1 ? "" : "s"))")
    }

    func generateBlendOffline(_ blend: GenreBlend, energyBias: Int) {
        let pattern = ProceduralGenerator.generate(
            profile: blend.profile,
            name: "\(blend.primary.displayName) × \(blend.secondary.displayName)",
            options: .init(length: 16, energyBias: energyBias),
            seed: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        replaceVariations(PatternVariationEngine.makeVariations(from: pattern, genre: blend.primary, seed: UInt64(pattern.bpm * 1000)))
        currentPresetID = nil
        activeSlot = .a
        statusMessage = "Generated \(blend.label)"
    }

    func setAPIKey(_ key: String) {
        Keychain.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = Keychain.readAPIKey()?.isEmpty == false
    }

    func setModel(_ model: String) {
        aiModel = model
        UserDefaults.standard.set(model, forKey: "aiModel")
    }

    func setBassNoteOffset(_ offset: Int) {
        bassNoteOffset = offset
        UserDefaults.standard.set(offset, forKey: "bassNoteOffset")
    }

    func markHardwareVerified() {
        hardwareVerified = true
        UserDefaults.standard.set(true, forKey: "hardwareVerified")
    }

    // MARK: Errors

    func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

import AppKit
import SwiftUI
import T8Core
import UniformTypeIdentifiers

// MARK: - Save Preset (Save As / Edit Details)

struct SavePresetSheet: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// nil = Save As (new preset from the working pattern); otherwise edit that preset's details.
    let existing: Preset?

    @State private var name = ""
    @State private var genres: Set<Genre> = []
    @State private var folderID: FolderID?
    @State private var bpm = 120.0
    @State private var key: PitchClass = .c
    @State private var scale: Scale = .minor
    @State private var tags = ""
    @State private var summary = ""
    @State private var notes = ""
    @State private var energy = 3
    @State private var favorite = false
    @State private var newFolderName = ""
    @State private var confirmOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Save Preset As" : "Preset Details").font(.title3.bold())
            Form {
                TextField("Preset Name", text: $name)
                LabeledContent("Genre") {
                    Menu(genres.isEmpty ? "None" : Genre.allCases.filter { genres.contains($0) }.map(\.displayName).joined(separator: ", ")) {
                        ForEach(Genre.allCases) { genre in
                            Toggle(genre.displayName, isOn: Binding(get: { genres.contains(genre) }, set: { on in
                                if on { genres.insert(genre) } else { genres.remove(genre) }
                            }))
                        }
                    }
                    .fixedSize()
                }
                Picker("Folder", selection: $folderID) {
                    Text("Unfiled").tag(FolderID?.none)
                    ForEach(store.library.folders) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    TextField("New folder", text: $newFolderName)
                    Button("Create") {
                        store.mutateLibrary { lib in folderID = try lib.createFolder(named: newFolderName).id }
                        newFolderName = ""
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if existing == nil {
                    TextField("BPM", value: $bpm, format: .number.precision(.fractionLength(0...1)))
                    Picker("Musical Key", selection: $key) { ForEach(PitchClass.allCases) { Text($0.name).tag($0) } }
                    Picker("Scale", selection: $scale) { ForEach(Scale.allCases) { Text($0.displayName).tag($0) } }
                }
                TextField("Tags (comma separated)", text: $tags)
                TextField("Description", text: $summary, axis: .vertical).lineLimit(2...4)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                Picker("Energy", selection: $energy) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.segmented)
                Toggle("Favorite", isOn: $favorite)
            }
            .formStyle(.grouped)
            if existing == nil {
                Text("Saves all four variations (A/B/C/D): drum steps, accents, bass notes, slides, ties, swing and length.")
                    .font(Theme.small).foregroundStyle(Theme.textDim)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Save" : "Update") { attemptSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: populate)
        .alert("Replace existing preset?", isPresented: $confirmOverwrite) {
            Button("Replace", role: .destructive) { overwriteExisting() }
            Button("Save as Separate Preset") { commitNew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A preset named “\(name)” already exists in My Presets.")
        }
    }

    private var metadata: PresetMetadata {
        PresetMetadata(
            name: name, genres: Genre.allCases.filter { genres.contains($0) }, folderID: folderID,
            tags: tags.split(separator: ",").map(String.init), summary: summary, notes: notes, energy: energy, favorite: favorite
        )
    }

    private func populate() {
        if let existing {
            name = existing.name
            genres = Set(existing.genres)
            folderID = existing.folderID
            tags = existing.tags.joined(separator: ", ")
            summary = existing.summary
            notes = existing.notes
            energy = existing.energy
            favorite = store.library.isFavorite(existing.id)
        } else {
            let source = store.currentPreset
            name = source.map { $0.isFactory ? "\($0.name) (My Version)" : $0.name } ?? store.pattern.name
            genres = Set(source?.genres ?? [])
            folderID = source?.isFactory == false ? source?.folderID : nil
            tags = source?.tags.joined(separator: ", ") ?? ""
            summary = source?.summary ?? ""
            energy = source?.energy ?? 3
            bpm = store.pattern.bpm
            key = store.pattern.key
            scale = store.pattern.scale
        }
    }

    private func attemptSave() {
        if let existing {
            store.mutateLibrary { try $0.updateMetadata(existing.id, metadata: metadata) }
            dismiss()
            return
        }
        if store.library.userPreset(named: name) != nil {
            confirmOverwrite = true
        } else {
            commitNew()
        }
    }

    private func applyMusicalSettings() {
        let bpmValue = min(max(bpm, Pattern.bpmRange.lowerBound), Pattern.bpmRange.upperBound)
        let newKey = key, newScale = scale
        store.editAll { p in
            p.bpm = bpmValue
            if p.key != newKey { PatternEditor.changeKey(&p, to: newKey) }
            p.scale = newScale
        }
    }

    private func commitNew() {
        applyMusicalSettings()
        if store.saveAs(metadata: metadata) { dismiss() }
    }

    private func overwriteExisting() {
        guard let target = store.library.userPreset(named: name) else { return commitNew() }
        applyMusicalSettings()
        store.mutateLibrary { lib in
            try lib.update(target.id, variations: store.variations)
            try lib.updateMetadata(target.id, metadata: metadata)
        }
        store.currentPresetID = target.id
        store.save()
        dismiss()
    }
}

// MARK: - Manage Library

struct ManageLibrarySheet: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolder: FolderID?
    @State private var showUnfiled = true
    @State private var selection: Set<PresetID> = []
    @State private var newFolder = ""
    @State private var renaming: FolderID?
    @State private var renameText = ""
    @State private var revisionsFor: PresetID?

    var presets: [Preset] {
        if let folder = selectedFolder { return store.library.search(.folder(folder)) }
        return store.library.search(showUnfiled ? .unfiled : .mine)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Library").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            HSplitView {
                VStack(alignment: .leading) {
                    List {
                        Button("All My Presets") { selectedFolder = nil; showUnfiled = false }.buttonStyle(.plain)
                        Button("Unfiled") { selectedFolder = nil; showUnfiled = true }.buttonStyle(.plain)
                        Section("Folders") {
                            ForEach(store.library.folders) { folder in
                                if renaming == folder.id {
                                    TextField("Name", text: $renameText, onCommit: {
                                        store.mutateLibrary { try $0.renameFolder(folder.id, to: renameText) }
                                        renaming = nil
                                    })
                                } else {
                                    Button { selectedFolder = folder.id } label: {
                                        Label(folder.name, systemImage: "folder")
                                            .foregroundStyle(selectedFolder == folder.id ? Theme.accent : Theme.text)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Rename") { renaming = folder.id; renameText = folder.name }
                                        Button("Delete Folder (keeps presets)", role: .destructive) {
                                            store.mutateLibrary { try $0.deleteFolder(folder.id) }
                                            if selectedFolder == folder.id { selectedFolder = nil }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("New folder", text: $newFolder).textFieldStyle(.roundedBorder)
                        Button("Add") {
                            store.mutateLibrary { _ = try $0.createFolder(named: newFolder) }
                            newFolder = ""
                        }
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(8)
                }
                .frame(minWidth: 200, maxWidth: 260)

                VStack(alignment: .leading) {
                    Table(presets, selection: $selection) {
                        TableColumn("Name") { p in
                            HStack {
                                if store.library.isFavorite(p.id) { Image(systemName: "star.fill").foregroundStyle(Theme.warning) }
                                Text(p.name)
                            }
                        }
                        TableColumn("Genre") { p in Text(p.genres.map(\.displayName).joined(separator: ", ")) }
                        TableColumn("BPM") { p in Text("\(Int(p.main.bpm))") }.width(50)
                        TableColumn("Tags") { p in Text(p.tags.joined(separator: ", ")) }
                        TableColumn("Modified") { p in Text(p.modifiedAt, style: .date) }.width(90)
                    }
                    .contextMenu(forSelectionType: PresetID.self) { ids in
                        if let id = ids.first, ids.count == 1 {
                            Button("Edit Details…") { store.activeSheet = .editMetadata(id) }
                            Button("Load") { if let p = store.library.preset(id) { store.requestLoad(p) } }
                            Button("Version History…") { revisionsFor = id }
                        }
                        Menu("Move to") {
                            Button("Unfiled") { for id in ids { store.mutateLibrary { try $0.move(id, to: nil) } } }
                            ForEach(store.library.folders) { folder in
                                Button(folder.name) { for id in ids { store.mutateLibrary { try $0.move(id, to: folder.id) } } }
                            }
                        }
                        Button("Toggle Favorite") { for id in ids { store.toggleFavorite(id) } }
                        Button("Duplicate") { for id in ids { store.mutateLibrary { _ = try $0.duplicate(id) } } }
                        Button("Export…") { store.exportPresets(Array(ids)) }
                        Divider()
                        Button("Delete…", role: .destructive) { if let id = ids.first { store.pendingDelete = id } }
                    }
                    HStack {
                        Text("\(presets.count) presets · right-click for actions · stored in \(store.libraryStore.directory.path)")
                            .font(Theme.small).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal Backups") { NSWorkspace.shared.activateFileViewerSelecting([store.libraryStore.backupDirectory]) }
                        Button("Import…") { store.importPresets() }
                        Button("Export Selected…") { store.exportPresets(Array(selection)) }.disabled(selection.isEmpty)
                    }
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        .frame(width: 900, height: 540)
        .sheet(item: Binding(get: { revisionsFor.map { RevisionTarget(id: $0) } }, set: { revisionsFor = $0?.id })) { target in
            RevisionsView(presetID: target.id)
        }
    }
}

struct RevisionTarget: Identifiable { let id: PresetID }

struct RevisionsView: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let presetID: PresetID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Version History — \(store.library.preset(presetID)?.name ?? "")").font(.headline)
            let revisions = store.library.revisions(of: presetID)
            if revisions.isEmpty {
                Text("No earlier versions yet. Each Save keeps the previous version (up to \(Preset.maxRevisions)).")
                    .font(Theme.small).foregroundStyle(Theme.textDim)
            }
            List(revisions) { revision in
                HStack {
                    VStack(alignment: .leading) {
                        Text(revision.savedAt, format: .dateTime)
                        MiniPatternView(pattern: revision.variations.a).frame(width: 220, height: 30)
                    }
                    Spacer()
                    Button("Restore") {
                        store.mutateLibrary { try $0.restoreRevision(revision.id, of: presetID) }
                        if store.currentPresetID == presetID, let p = store.library.preset(presetID) { store.load(p, mode: .full) }
                        dismiss()
                    }
                }
            }
            .frame(height: 280)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(width: 440)
    }
}

// MARK: - MIDI import

struct MIDIImportSheet: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var file: MIDIFile?
    @State private var fileName = ""
    @State private var options = MIDIImportOptions()
    @State private var result: MIDIImportResult?
    @State private var drumChannel = 10
    @State private var bassChannel = 0 // 0 = auto
    @State private var target: VariationSlot = .a
    @State private var replaceAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import MIDI File").font(.title3.bold())
            HStack {
                Button("Choose File…", action: choose)
                Text(fileName.isEmpty ? "Standard MIDI File (type 0 or 1)" : fileName).foregroundStyle(Theme.textDim)
            }
            if let file {
                Form {
                    LabeledContent("Tracks") { Text("\(file.tracks.count) · type \(file.format) · \(Int(file.initialTempoBPM)) BPM") }
                    Picker("Drum channel", selection: $drumChannel) { ForEach(1...16, id: \.self) { Text("\($0)").tag($0) } }
                    Picker("Bass channel", selection: $bassChannel) {
                        Text("Auto (first non-drum)").tag(0)
                        ForEach(1...16, id: \.self) { ch in
                            Text("\(ch)\(result?.detectedChannels[UInt8(ch - 1)].map { " — \($0) notes" } ?? "")").tag(ch)
                        }
                    }
                    Picker("Drum note map", selection: Binding(get: { options.drumMapping.name }, set: { name in
                        options.drumMapping = DrumNoteMapping.all.first { $0.name == name } ?? .rolandT8
                    })) {
                        ForEach(DrumNoteMapping.all, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Stepper("Start at bar \(options.startBar + 1)", value: $options.startBar, in: 0...256)
                    Picker("Length", selection: $options.maxSteps) {
                        Text("1 bar (16)").tag(16)
                        Text("2 bars (32)").tag(32)
                    }
                    LabeledContent("Quantize tolerance") {
                        Slider(value: $options.quantizeTolerance, in: 0.1...0.5)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: drumChannel) { convert() }
                .onChange(of: bassChannel) { convert() }
                .onChange(of: options) { convert() }

                if let result {
                    SectionHeader(title: "Conversion Preview")
                    MiniPatternView(pattern: result.pattern).frame(height: 70)
                    Text("\(result.pattern.length) steps · \(result.pattern.drums.hitCount(length: result.pattern.length)) drum hits · \(result.pattern.bass.noteCount(length: result.pattern.length)) bass notes")
                        .font(Theme.small)
                    ForEach(result.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(Theme.small).foregroundStyle(Theme.warning)
                    }
                    HStack {
                        Toggle("Replace all variations (derive B/C/D)", isOn: $replaceAll)
                        if !replaceAll {
                            Picker("Into", selection: $target) { ForEach(VariationSlot.allCases) { Text($0.letter).tag($0) } }
                                .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { apply() }.keyboardShortcut(.defaultAction).disabled(result == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "midi") ?? .midi, .midi]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            file = try MIDIFile.parse(Data(contentsOf: url))
            fileName = url.lastPathComponent
            convert()
        } catch {
            store.show(error)
        }
    }

    private func convert() {
        guard let file else { return }
        var o = options
        o.drumChannels = [UInt8(drumChannel - 1)]
        o.bassChannel = bassChannel == 0 ? nil : UInt8(bassChannel - 1)
        result = MIDIFileImporter.importPattern(file, name: (fileName as NSString).deletingPathExtension, options: o)
    }

    private func apply() {
        guard let pattern = result?.pattern else { return }
        if replaceAll {
            store.guardUnsaved(title: "Replace the current pattern with the imported MIDI?") {
                store.replaceVariations(PatternVariationEngine.makeVariations(from: pattern, genre: nil, seed: 1))
                store.currentPresetID = nil
                store.activeSlot = .a
            }
        } else {
            var updated = store.variations
            updated[target] = pattern
            store.replaceVariations(updated)
            store.selectSlot(target)
        }
        store.statusMessage = "Imported \(fileName)"
        dismiss()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(StudioStore.self) private var store
    @State private var apiKey = ""
    @State private var saved = false

    var body: some View {
        TabView {
            Form {
                Section("Anthropic API") {
                    SecureField("API key", text: $apiKey)
                    HStack {
                        Button("Save to Keychain") {
                            store.setAPIKey(apiKey)
                            apiKey = ""
                            saved = true
                        }
                        Button("Remove Key", role: .destructive) {
                            store.setAPIKey("")
                            saved = false
                        }
                        Spacer()
                        Text(store.hasAPIKey ? "Key stored in Keychain" : "No key").foregroundStyle(store.hasAPIKey ? Theme.ok : Theme.textDim)
                    }
                    TextField("Model", text: Binding(get: { store.aiModel }, set: { store.setModel($0) }))
                    Text("The key is stored in the macOS Keychain and only sent to api.anthropic.com. The app works fully without a key; only AI generation needs it.")
                        .font(Theme.small).foregroundStyle(Theme.textDim)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }

            Form {
                Section("MIDI Playback") {
                    Picker("Rhythm channel", selection: Binding(get: { store.rhythmChannel }, set: { store.rhythmChannel = $0 })) {
                        ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Bass channel", selection: Binding(get: { store.bassChannel }, set: { store.bassChannel = $0 })) {
                        ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text("T-8 defaults per the MIDI implementation chart: bass 2, rhythm 10.").font(Theme.small).foregroundStyle(Theme.textDim)
                }
                Section("Native Pattern Format (unverified)") {
                    Stepper("Bass NOTE 0 = MIDI \(store.bassNoteOffset) (\(NoteName.string(for: store.bassNoteOffset)))",
                            value: Binding(get: { store.bassNoteOffset }, set: { store.setBassNoteOffset($0) }), in: 0...48)
                    Text("Calibrate by programming a known note (e.g. C2) on the T-8, backing up, and checking the NOTE value in the bass file with the Transfer wizard's slot preview.")
                        .font(Theme.small).foregroundStyle(Theme.textDim)
                    LabeledContent("Hardware verification") {
                        Text(store.hardwareVerified ? "Completed on your T-8" : "Not yet performed").foregroundStyle(store.hardwareVerified ? Theme.ok : Theme.warning)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Hardware", systemImage: "pianokeys") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - Capability matrix

struct CapabilityMatrixView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("T-8 Hardware Compatibility").font(.title3.bold())
            Text("What is known, where it comes from, and what still needs testing on a real T-8.")
                .font(Theme.small).foregroundStyle(Theme.textDim)
            Table(HardwareCapabilities.matrix) {
                TableColumn("Feature") { Text($0.feature).lineLimit(3) }
                TableColumn("Status") { entry in
                    Text(entry.level.label).foregroundStyle(color(entry.level))
                }
                .width(170)
                TableColumn("Source / Notes") { entry in
                    Text(entry.source + (entry.notes.isEmpty ? "" : " — " + entry.notes)).lineLimit(4)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 860, height: 520)
    }

    private func color(_ level: EvidenceLevel) -> Color {
        switch level {
        case .officiallyDocumented, .hardwareVerified: Theme.ok
        case .openSourceVerified: Theme.bass
        case .unverified: Theme.warning
        case .unsupported: Theme.danger
        }
    }
}

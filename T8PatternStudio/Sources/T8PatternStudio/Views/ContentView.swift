import SwiftUI
import T8Core

struct ContentView: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            TransportBar()
            Divider().overlay(Color.black)
            HStack(spacing: 0) {
                if store.showBrowser {
                    PresetBrowserView()
                        .frame(width: 290)
                    Divider().overlay(Color.black)
                }
                EditorArea()
                Divider().overlay(Color.black)
                InspectorView()
                    .frame(width: 300)
            }
            StatusBar()
        }
        .background(Theme.background)
        .sheet(item: $store.activeSheet) { sheet in
            switch sheet {
            case .savePresetAs: SavePresetSheet(existing: nil)
            case .editMetadata(let id): SavePresetSheet(existing: store.library.preset(id))
            case .manageLibrary: ManageLibrarySheet()
            case .midiImport: MIDIImportSheet()
            case .transfer: TransferWizardView()
            case .capabilities: CapabilityMatrixView()
            case .audioToBeat: AudioToBeatSheet()
            }
        }
        .alert(item: $store.pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text("“\(store.currentPreset?.name ?? store.pattern.name)” has unsaved changes."),
                primaryButton: .destructive(Text("Discard Changes")) { action.perform() },
                secondaryButton: .cancel()
            )
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog("Delete preset?", isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } })) {
            Button("Delete “\(store.pendingDelete.flatMap { store.library.preset($0)?.name } ?? "")”", role: .destructive) {
                if let id = store.pendingDelete { store.confirmDelete(id) }
            }
        } message: {
            Text("This cannot be undone. Library backups are kept in Application Support.")
        }
        .onAppear {
            if let message = store.libraryLoadMessage { store.statusMessage = message }
        }
    }
}

// MARK: - Transport / toolbar

struct TransportBar: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Text("T-8 PATTERN STUDIO")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(Theme.accent)
                .padding(.leading, 76) // clear the window traffic lights

            PresetLibraryMenu()

            VStack(alignment: .leading, spacing: 0) {
                Text(store.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(store.currentPreset?.primaryGenre?.displayName ?? (store.currentPresetID == nil ? "Unsaved" : "My Preset"))
                    .font(Theme.small).foregroundStyle(Theme.textDim)
            }
            .frame(minWidth: 140, maxWidth: 220, alignment: .leading)

            Divider().frame(height: 28)

            LabeledField("BPM") {
                TextField("BPM", value: Binding(get: { store.pattern.bpm }, set: { value in
                    let clamped = min(max(value, Pattern.bpmRange.lowerBound), Pattern.bpmRange.upperBound)
                    store.editAll { $0.bpm = clamped }
                }), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 52)
                .textFieldStyle(.roundedBorder)
            }
            LabeledField("TIME") {
                Text(store.pattern.timeSignature.description).font(Theme.mono).frame(width: 30)
                    .help("The T-8 sequences 16th-note steps; patterns are 4/4.")
            }
            LabeledField("SWING \(store.pattern.swing)%") {
                Slider(value: Binding(get: { Double(store.pattern.swing) }, set: { v in store.edit { $0.swing = Int(v) } }), in: 0...100, step: 5)
                    .frame(width: 90)
            }
            LabeledField("LENGTH") {
                Picker("", selection: Binding(get: { store.pattern.length }, set: { len in store.edit { PatternEditor.setLength(&$0, len) } })) {
                    ForEach([4, 8, 12, 16, 24, 32], id: \.self) { Text("\($0)").tag($0) }
                    if ![4, 8, 12, 16, 24, 32].contains(store.pattern.length) {
                        Text("\(store.pattern.length)").tag(store.pattern.length)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }

            Divider().frame(height: 28)

            Button { store.togglePlay() } label: {
                Image(systemName: store.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .help(store.isPlaying ? "Stop (⌘↩)" : "Play (⌘↩)")
            .buttonStyle(.borderedProminent)
            .tint(store.isPlaying ? Theme.danger : Theme.accent)

            Toggle(isOn: Binding(get: { store.isLooping }, set: { store.setLooping($0) })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop")

            OutputPicker()

            Spacer(minLength: 8)

            Button { store.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help(store.currentIsFactory ? "Factory presets are read-only — saves as a new preset" : "Save Preset (⌘S)")
            Menu {
                Button("Export MIDI File…") { store.exportMIDI() }
                Button("Export A/B/C/D as MIDI Files…") { store.exportAllVariationsMIDI() }
                Divider()
                Button("Export Preset File…") { if let id = store.currentPresetID { store.exportPresets([id]) } }
                    .disabled(store.currentPresetID == nil)
                Button("Import MIDI File…") { store.activeSheet = .midiImport }
                Button("Beat from Audio File…") { store.activeSheet = .audioToBeat }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            Button { store.activeSheet = .audioToBeat } label: {
                Label("From Audio", systemImage: "waveform")
            }
            .help("Analyse a song and turn its beat into a pattern (⇧⌘A)")
            Button { store.activeSheet = .transfer } label: {
                Label("Transfer to T-8", systemImage: "arrow.down.to.line.compact")
            }
            .tint(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .controlSize(.small)
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
            content
        }
    }
}

struct OutputPicker: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Playback", selection: Binding(get: { store.playbackTarget }, set: { target in
                    store.stop()
                    store.playbackTarget = target
                })) {
                    ForEach(PlaybackTarget.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Section("MIDI Output") {
                    if store.midiDestinations.isEmpty {
                        Text("No MIDI outputs found")
                    }
                    ForEach(store.midiDestinations) { destination in
                        Button {
                            store.selectedDestinationID = destination.id
                        } label: {
                            if destination.id == store.selectedDestinationID {
                                Label(destination.name, systemImage: "checkmark")
                            } else {
                                Text(destination.name)
                            }
                        }
                    }
                }
                Button("Refresh Devices") { store.refreshMIDI() }
            } label: {
                Label(store.playbackTarget == .internalAudio ? "Internal" : (store.selectedDestination?.name ?? "MIDI"),
                      systemImage: store.playbackTarget == .internalAudio ? "speaker.wave.2.fill" : "pianokeys")
            }
            .fixedSize()
            .help("Internal preview audio or live playback through the T-8 over USB MIDI. MIDI playback does not store anything on the T-8.")

            HStack(spacing: 4) {
                Circle().fill(store.t8Connected ? Theme.ok : Theme.cellOffBeat).frame(width: 8, height: 8)
                Text(store.t8Connected ? "T-8" : "No T-8").font(Theme.small).foregroundStyle(Theme.textDim)
            }
            .help(store.t8Connected ? "A Roland T-8 is connected over USB MIDI." : "No T-8 detected. Connect it with USB-C.")
        }
    }
}

struct StatusBar: View {
    @Environment(StudioStore.self) private var store
    var body: some View {
        HStack {
            Text(store.statusMessage ?? "Ready").font(Theme.small).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer()
            if store.previewingPresetID != nil {
                Text("PREVIEWING — your pattern is unchanged").font(Theme.small.bold()).foregroundStyle(Theme.warning)
            }
            Text("\(store.library.userPresets.count) of my presets · 60 factory").font(Theme.small).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.panel)
    }
}

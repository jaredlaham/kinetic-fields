import SwiftUI
import T8Core

struct InspectorView: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("", selection: $store.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch store.inspectorTab {
                    case .step: StepInspector()
                    case .ai: AIPanel()
                    case .blend: GenreBlendPanel()
                    case .mixer: MixerPanel()
                    }
                    ValidationPanel()
                }
                .padding(10)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Step details

struct StepInspector: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Step Details")
            if let focus = store.focusedStep {
                if let voice = focus.voice {
                    drumDetails(voice: voice, step: focus.step)
                } else {
                    bassDetails(step: focus.step)
                }
            } else {
                Text("Click a step to edit it. ⌥-click selects a step without toggling it.")
                    .font(Theme.small).foregroundStyle(Theme.textDim)
            }
            Divider()
            SectionHeader(title: "Pattern")
            LabeledContent("Name") {
                TextField("Name", text: Binding(get: { store.pattern.name }, set: { name in store.edit { $0.name = name } }))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Steps") { Text("\(store.pattern.length) (\(store.pattern.drums.hitCount(length: store.pattern.length)) hits, \(store.pattern.bass.noteCount(length: store.pattern.length)) notes)").font(Theme.small) }
            Text("Steps are numbered 1–32 as on the T-8 (stored zero-based internally).")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
    }

    @ViewBuilder
    private func drumDetails(voice: DrumVoice, step: Int) -> some View {
        let hit = store.pattern.drums[voice, step]
        HStack {
            Circle().fill(Theme.voiceColor(voice)).frame(width: 8, height: 8)
            Text("\(voice.displayName) · Step \(step + 1)").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(hit == nil ? "Add" : "Remove") { store.edit { PatternEditor.toggle(&$0, voice: voice, step: step) } }
                .controlSize(.small)
        }
        if let hit {
            LabeledContent("Velocity \(hit.velocity)") {
                Slider(value: Binding(get: { Double(hit.velocity) }, set: { v in store.edit { PatternEditor.setVelocity(&$0, voice: voice, step: step, velocity: Int(v)) } }), in: 0...10, step: 1)
            }
            LabeledContent("Sub-step") {
                Picker("", selection: Binding(get: { hit.subStep }, set: { sub in
                    store.edit { p in var h = hit; h.subStep = sub; p.drums[voice, step] = h }
                })) {
                    Text("Off").tag(SubStep.none)
                    Text("×2").tag(SubStep.x2)
                    Text("×3").tag(SubStep.x3)
                    Text("×4").tag(SubStep.x4)
                    Text("Flam").tag(SubStep.flam)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledContent("Probability \(hit.probability)%") {
                Slider(value: Binding(get: { Double(hit.probability) }, set: { v in store.edit { PatternEditor.setProbability(&$0, voice: voice, step: step, probability: Int(v)) } }), in: 0...100, step: 10)
            }
            if hit.subStep != .none {
                LabeledContent("Sub-step prob. \(hit.subStepProbability)%") {
                    Slider(value: Binding(get: { Double(hit.subStepProbability) }, set: { v in
                        store.edit { p in var h = hit; h.subStepProbability = Int(v); p.drums[voice, step] = h }
                    }), in: 0...100, step: 10)
                }
            }
            Text("Velocity, sub-step and probability are T-8 step attributes (format per the open-source editor; not yet hardware-verified).")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
        Toggle("Accent on step \(step + 1)", isOn: Binding(get: { store.pattern.drums.accents[step] }, set: { _ in store.edit { PatternEditor.toggleAccent(&$0, step: step) } }))
    }

    @ViewBuilder
    private func bassDetails(step: Int) -> some View {
        let s = store.pattern.bass[step]
        Text("Bass · Step \(step + 1)").font(.system(size: 12, weight: .semibold))
        Picker("Type", selection: Binding(get: { s.kind }, set: { kind in
            store.edit { p in
                switch kind {
                case .rest: PatternEditor.setBassRest(&p, step: step)
                case .tie: PatternEditor.setBassTie(&p, step: step)
                case .note: PatternEditor.setBassNote(&p, step: step, note: s.note, scaleLock: store.scaleLock)
                }
            }
        })) {
            Text("Rest").tag(BassStep.Kind.rest)
            Text("Note").tag(BassStep.Kind.note)
            Text("Tie").tag(BassStep.Kind.tie)
        }
        .pickerStyle(.segmented)
        if s.kind == .note {
            Stepper("Pitch \(NoteName.string(for: s.note))", onIncrement: {
                let lock = store.scaleLock
                store.edit { p in
                    let next = lock ? p.scale.move(midiNote: s.note, degrees: 1, root: p.key) : s.note + 1
                    PatternEditor.setBassNote(&p, step: step, note: next, scaleLock: lock)
                }
            }, onDecrement: {
                let lock = store.scaleLock
                store.edit { p in
                    let next = lock ? p.scale.move(midiNote: s.note, degrees: -1, root: p.key) : s.note - 1
                    PatternEditor.setBassNote(&p, step: step, note: next, scaleLock: lock)
                }
            })
            HStack {
                Button("Octave −") { store.edit { PatternEditor.setBassNote(&$0, step: step, note: s.note - 12, scaleLock: false) } }
                Button("Octave +") { store.edit { PatternEditor.setBassNote(&$0, step: step, note: s.note + 12, scaleLock: false) } }
            }
            .controlSize(.small)
            Toggle("Accent", isOn: Binding(get: { s.accent }, set: { _ in store.edit { PatternEditor.toggleBassAccent(&$0, step: step) } }))
        }
        if s.kind != .rest {
            Toggle("Slide into next note", isOn: Binding(get: { s.slide }, set: { _ in store.edit { PatternEditor.toggleBassSlide(&$0, step: step) } }))
        }
    }
}

// MARK: - AI

struct AIPanel: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Claude Beat Generator")
            if !store.hasAPIKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add an Anthropic API key in Settings (⌘,) to generate with Claude. Everything else works offline.")
                        .font(Theme.small).foregroundStyle(Theme.warning)
                    SettingsLink { Text("Open Settings…") }.controlSize(.small)
                }
            }
            TextEditor(text: $store.aiPrompt)
                .font(.system(size: 12))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topLeading) {
                    if store.aiPrompt.isEmpty {
                        Text("e.g. “A dark 128 BPM French electro groove with aggressive kicks, syncopated hats and a sinister acid bassline in D minor.”")
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim).padding(6).allowsHitTesting(false)
                    }
                }
            HStack {
                Button {
                    store.runAI(.create(prompt: store.aiPrompt))
                } label: {
                    Label("Create New", systemImage: "sparkles")
                }
                .disabled(store.aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty || store.aiBusy)
                Button("Edit Current") { store.runAI(.edit(instruction: store.aiPrompt)) }
                    .disabled(store.aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty || store.aiBusy)
                if store.aiBusy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            SectionHeader(title: "Quick Edits")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(AIRequestKind.quickEdits, id: \.self) { instruction in
                    Button(instruction) { store.runAI(.edit(instruction: instruction)) }
                        .controlSize(.small)
                        .disabled(store.aiBusy)
                }
                Button("Change the genre…") {
                    store.runAI(.edit(instruction: "Change the genre to \(store.aiPrompt.isEmpty ? "something contrasting" : store.aiPrompt)"))
                }
                .controlSize(.small)
                .disabled(store.aiBusy)
                Button("Surprise me") { store.runAI(.surprise) }
                    .controlSize(.small)
                    .disabled(store.aiBusy)
            }
            if let explanation = store.aiLastExplanation {
                Text(explanation).font(.system(size: 11)).foregroundStyle(Theme.text)
                    .padding(6)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text("Claude's output is parsed and validated before it reaches the sequencer; invalid patterns are rejected. Edits are undoable (⌘Z). Uses \(store.aiModel).")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Genre blend

struct GenreBlendPanel: View {
    @Environment(StudioStore.self) private var store
    @State private var primary: Genre = .tripHop
    @State private var secondary: Genre = .frenchElectro
    @State private var percent = 70.0
    @State private var energy = 0
    @State private var direction = ""

    var blend: GenreBlend { GenreBlend(primary: primary, secondary: secondary, primaryPercent: Int(percent)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Genre Blend")
            Picker("Primary", selection: $primary) { ForEach(Genre.allCases) { Text($0.displayName).tag($0) } }
            Picker("Secondary", selection: $secondary) { ForEach(Genre.allCases) { Text($0.displayName).tag($0) } }
            VStack(alignment: .leading) {
                Text(blend.label).font(.system(size: 12, weight: .semibold))
                Slider(value: $percent, in: 0...100, step: 5)
            }
            let profile = blend.profile
            Text("≈ \(Int(profile.bpm)) BPM · swing \(Int(profile.swing)) · \(profile.dominantScale.displayName)")
                .font(Theme.small).foregroundStyle(Theme.textDim)
            Picker("Energy", selection: $energy) {
                Text("Calmer").tag(-1)
                Text("As blended").tag(0)
                Text("Hotter").tag(1)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Generate Offline") { store.generateBlendOffline(blend, energyBias: energy) }
                Button("Generate with Claude") { store.runAI(.blend(blend, prompt: direction)) }
                    .disabled(!store.hasAPIKey || store.aiBusy)
            }
            .controlSize(.small)
            TextField("Optional direction for Claude", text: $direction).textFieldStyle(.roundedBorder)
            Text("Blends interpolate step-probability templates, tempo, swing, bass register and slide/accent rates learned from the factory presets of both genres, then generate one coherent groove rather than overlaying two patterns.")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Mixer

struct MixerPanel: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Preview Mixer")
            ForEach(DrumVoice.allCases) { voice in
                channel(id: voice.rawValue, name: voice.displayName, color: Theme.voiceColor(voice),
                        value: Binding(get: { Double(store.mix.voiceVolume[voice] ?? 0.8) }, set: { v in store.updateMix { $0.voiceVolume[voice] = Float(v) } }))
            }
            channel(id: PreviewMix.bassTrackID, name: "Bass", color: Theme.bass,
                    value: Binding(get: { Double(store.mix.bassVolume) }, set: { v in store.updateMix { $0.bassVolume = Float(v) } }))
            Divider()
            HStack {
                Text("Master").font(Theme.label).frame(width: 90, alignment: .leading)
                Slider(value: Binding(get: { Double(store.mix.masterVolume) }, set: { v in store.updateMix { $0.masterVolume = Float(v) } }), in: 0...1)
            }
            Toggle("Metronome", isOn: Binding(get: { store.mix.metronome }, set: { v in store.updateMix { $0.metronome = v } }))
            Text("Mixer settings affect the internal preview only. Sounds are synthesized in the app (no samples).")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
    }

    private func channel(id: String, name: String, color: Color, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(Theme.label).frame(width: 82, alignment: .leading)
            Slider(value: value, in: 0...1)
            toggleButton("M", on: store.mix.muted.contains(id), color: Theme.warning) {
                store.updateMix { mix in if mix.muted.contains(id) { mix.muted.remove(id) } else { mix.muted.insert(id) } }
            }
            toggleButton("S", on: store.mix.soloed.contains(id), color: Theme.ok) {
                store.updateMix { mix in if mix.soloed.contains(id) { mix.soloed.remove(id) } else { mix.soloed.insert(id) } }
            }
        }
    }

    private func toggleButton(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                .background(on ? color : Theme.cellOff)
                .foregroundStyle(on ? .black : Theme.textDim)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Validation

struct ValidationPanel: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        let issues = ValidationEngine.validateForHardware(store.pattern).filter { $0.severity != .info }
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Checks")
                ForEach(issues, id: \.self) { issue in
                    Label(issue.description, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(Theme.small)
                        .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                }
            }
        }
    }
}

import AppKit
import SwiftUI
import T8Core

struct EditorArea: View {
    @Environment(StudioStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            VariationBar()
            DrumSequencerView()
                .panel()
            BassEditorView()
                .panel()
        }
        .padding(8)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            store.togglePlay()
            return .handled
        }
        .onDeleteCommand { store.clearSelection() }
        .onTapGesture { focused = true }
    }
}

struct VariationBar: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            ForEach(VariationSlot.allCases) { slot in
                Button {
                    store.selectSlot(slot)
                } label: {
                    VStack(spacing: 0) {
                        Text(slot.letter).font(.system(size: 13, weight: .heavy))
                        Text(slot.title).font(.system(size: 9))
                    }
                    .frame(width: 70, height: 32)
                    .background(store.activeSlot == slot ? Theme.accent : Theme.panelRaised)
                    .foregroundStyle(store.activeSlot == slot ? Color.black : Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if slot != .a { Button("Regenerate from A") { store.regenerateVariation(slot) } }
                    ForEach(VariationSlot.allCases.filter { $0 != slot }) { other in
                        Button("Copy \(slot.letter) to \(other.letter)") { store.copyVariation(slot, to: other) }
                    }
                    Divider()
                    Button("Generate \(slot.letter) with Claude") { store.runAI(.variation(slot)) }
                }
                .help("Variation \(slot.letter) — \(slot.title). App-level variation; each can be exported to its own T-8 slot.")
            }
            Spacer()
            Toggle("Scale Lock", isOn: Binding(get: { store.scaleLock }, set: { store.scaleLock = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
            Menu("Key \(store.pattern.key.name) \(store.pattern.scale.displayName)") {
                Menu("Key") {
                    ForEach(PitchClass.allCases) { key in
                        Button(key.name) { store.editAll { PatternEditor.changeKey(&$0, to: key) } }
                    }
                }
                Menu("Scale") {
                    ForEach(Scale.allCases) { scale in
                        Button(scale.displayName) { store.editAll { $0.scale = scale } }
                    }
                }
            }
            .fixedSize()
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help("Undo (⌘Z)")
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).help("Redo (⇧⌘Z)")
        }
        .controlSize(.small)
    }
}

// MARK: - Drum sequencer

struct DrumSequencerView: View {
    @Environment(StudioStore.self) private var store
    @State private var paintValue: Bool?
    @State private var lastPainted: Set<Int> = []
    @State private var density = 0.5

    private let labelWidth: CGFloat = 92
    private let rowHeight: CGFloat = 30
    private var rows: [DrumVoice] { DrumVoice.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "Drums")
                Spacer()
                Text("Click toggle · drag paint · ⇧-drag select · ⌥-click step details")
                    .font(Theme.small).foregroundStyle(Theme.textDim)
                Menu("Tools") {
                    Button("Copy Steps (⌥⌘C)") { store.copySelection() }
                    Button("Paste Steps (⌥⌘V)") { store.pasteAtSelection() }.disabled(store.clipboard == nil)
                    Button("Clear Selection / All") { store.clearSelection() }
                    Button("Duplicate 16 → 32") { store.edit { PatternEditor.duplicateLength(&$0) } }
                    Divider()
                    Menu("Randomize") {
                        Button("All Drums") { randomize(DrumVoice.allCases) }
                        ForEach(DrumVoice.allCases) { voice in Button(voice.displayName) { randomize([voice]) } }
                    }
                    Divider()
                    Button("Select All") { store.selection = .all(length: store.pattern.length) }
                    Button("Deselect") { store.selection = nil }
                }
                .fixedSize()
                .controlSize(.small)
                HStack(spacing: 4) {
                    Text("Density").font(Theme.small).foregroundStyle(Theme.textDim)
                    Slider(value: $density, in: 0.1...1).frame(width: 70).controlSize(.mini)
                }
            }
            GeometryReader { geo in
                let gridWidth = geo.size.width - labelWidth
                let cellWidth = gridWidth / CGFloat(Pattern.maxSteps)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        StepNumberRow(cellWidth: cellWidth, labelWidth: labelWidth, length: store.pattern.length, playhead: store.playheadStep)
                        ForEach(rows) { voice in
                            DrumLaneRow(voice: voice, cellWidth: cellWidth, labelWidth: labelWidth, height: rowHeight)
                        }
                        AccentRow(cellWidth: cellWidth, labelWidth: labelWidth)
                    }
                    if let sel = store.selection, !sel.voices.isEmpty {
                        let firstRow = rows.firstIndex(of: sel.voices.first!) ?? 0
                        Rectangle()
                            .stroke(Theme.playhead, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: CGFloat(sel.steps.count) * cellWidth, height: CGFloat(sel.voices.count) * rowHeight)
                            .offset(x: labelWidth + CGFloat(sel.steps.lowerBound) * cellWidth, y: 16 + CGFloat(firstRow) * rowHeight)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(cellWidth: cellWidth))
            }
            .frame(height: 16 + rowHeight * CGFloat(rows.count) + 22)
        }
        .padding(8)
    }

    private func randomize(_ voices: [DrumVoice]) {
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        store.edit { PatternEditor.randomizeDrums(&$0, voices: voices, density: density, seed: seed) }
    }

    private func cell(at point: CGPoint, cellWidth: CGFloat) -> (row: Int, step: Int)? {
        let x = point.x - labelWidth
        let y = point.y - 16
        guard x >= 0, y >= 0 else { return nil }
        let step = Int(x / cellWidth)
        let row = Int(y / rowHeight)
        guard step < Pattern.maxSteps, row < rows.count else { return nil }
        return (row, step)
    }

    private func dragGesture(cellWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let start = cell(at: value.startLocation, cellWidth: cellWidth),
                      let current = cell(at: value.location, cellWidth: cellWidth) else { return }
                let flags = NSEvent.modifierFlags
                if flags.contains(.shift) {
                    let lowRow = min(start.row, current.row), highRow = max(start.row, current.row)
                    let lowStep = min(start.step, current.step), highStep = max(start.step, current.step)
                    store.selection = StepSelection(voices: Array(rows[lowRow...highRow]), steps: lowStep..<(highStep + 1))
                    return
                }
                if flags.contains(.option) {
                    if value.translation == .zero {
                        store.focusedStep = (rows[start.row], start.step)
                        store.inspectorTab = .step
                    }
                    return
                }
                guard current.step < store.pattern.length else { return }
                let voice = rows[current.row]
                if paintValue == nil {
                    paintValue = store.pattern.drums[voice, current.step] == nil
                    lastPainted = []
                }
                let key = current.row * 100 + current.step
                guard !lastPainted.contains(key), let on = paintValue else { return }
                lastPainted.insert(key)
                store.edit { PatternEditor.paint(&$0, voice: voice, step: current.step, on: on) }
                store.focusedStep = (voice, current.step)
            }
            .onEnded { _ in
                paintValue = nil
                lastPainted = []
            }
    }
}

struct StepNumberRow: View {
    let cellWidth: CGFloat
    let labelWidth: CGFloat
    let length: Int
    let playhead: Int?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            ForEach(0..<Pattern.maxSteps, id: \.self) { step in
                Text(step % 4 == 0 ? "\(step + 1)" : "·")
                    .font(.system(size: 9, weight: step % 4 == 0 ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(step == playhead ? Theme.playhead : (step < length ? Theme.textDim : Theme.textDim.opacity(0.3)))
                    .frame(width: cellWidth, height: 16)
            }
        }
    }
}

struct DrumLaneRow: View {
    @Environment(StudioStore.self) private var store
    let voice: DrumVoice
    let cellWidth: CGFloat
    let labelWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let pattern = store.pattern
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    store.updateMix { mix in
                        if mix.muted.contains(voice.rawValue) { mix.muted.remove(voice.rawValue) } else { mix.muted.insert(voice.rawValue) }
                    }
                } label: {
                    Text("M").font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(store.mix.muted.contains(voice.rawValue) ? Theme.warning : Theme.cellOff)
                        .foregroundStyle(store.mix.muted.contains(voice.rawValue) ? .black : Theme.textDim)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .help("Mute \(voice.displayName) (preview)")
                Circle().fill(Theme.voiceColor(voice)).frame(width: 6, height: 6)
                Text(voice.displayName).font(Theme.label).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .frame(width: labelWidth, height: height)
            ForEach(0..<Pattern.maxSteps, id: \.self) { step in
                DrumCell(
                    hit: pattern.drums[voice, step],
                    color: Theme.voiceColor(voice),
                    active: step < pattern.length,
                    downbeat: (step / 4) % 2 == 0,
                    accent: pattern.drums.accents[step],
                    playing: store.playheadStep == step,
                    focused: store.focusedStep?.voice == voice && store.focusedStep?.step == step
                )
                .frame(width: cellWidth, height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(voice.displayName) lane, \(pattern.drums.lane(voice).prefix(pattern.length).compactMap { $0 }.count) hits")
    }
}

struct DrumCell: View {
    let hit: DrumHit?
    let color: Color
    let active: Bool
    let downbeat: Bool
    let accent: Bool
    let playing: Bool
    let focused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
            if let hit {
                if hit.subStep != .none {
                    Text(hit.subStep.label).font(.system(size: 8, weight: .heavy)).foregroundStyle(.black.opacity(0.75))
                }
                if hit.probability < 100 {
                    Text("\(hit.probability)%").font(.system(size: 6, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                        .offset(y: 8)
                }
            }
            if playing {
                RoundedRectangle(cornerRadius: 3).stroke(Theme.playhead, lineWidth: 1.5)
            } else if focused {
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
        }
        .padding(1.5)
        .opacity(active ? 1 : 0.28)
    }

    private var fill: Color {
        if let hit {
            let level = 0.35 + 0.65 * Double(hit.velocity) / 10
            return color.opacity(accent ? 1 : level)
        }
        return downbeat ? Theme.cellOffBeat : Theme.cellOff
    }
}

struct AccentRow: View {
    @Environment(StudioStore.self) private var store
    let cellWidth: CGFloat
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("ACCENT").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(0..<Pattern.maxSteps, id: \.self) { step in
                Button {
                    store.edit { PatternEditor.toggleAccent(&$0, step: step) }
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(store.pattern.drums.accents[step] ? Theme.accent : Theme.cellOff)
                        .frame(height: 8)
                        .padding(.horizontal, 2)
                        .opacity(step < store.pattern.length ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .frame(width: cellWidth, height: 18)
                .help("T-8 accent for step \(step + 1) (applies to all voices)")
            }
        }
        .frame(height: 22)
    }
}

import AppKit
import SwiftUI
import T8Core

/// TB-303 style bass editor: piano roll for pitch plus per-step rows for
/// tie, accent and slide (the T-8's step attributes).
struct BassEditorView: View {
    @Environment(StudioStore.self) private var store
    @State private var baseOctave = 1
    @State private var paintNote: Int?
    @State private var erasing = false
    @State private var painted: Set<Int> = []
    @State private var bassDensity = 0.55
    @State private var slideAmount = 0.2
    @State private var accentAmount = 0.25

    private let labelWidth: CGFloat = 92
    private let rowHeight: CGFloat = 11
    /// Two octaves plus the top note, highest first.
    private var visibleNotes: [Int] {
        let low = (baseOctave + 1) * 12
        return Array((low...(low + 24)).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader(title: "Bass")
                Spacer()
                Stepper("Octave \(baseOctave)–\(baseOctave + 2)", value: $baseOctave, in: 0...5)
                    .font(Theme.small)
                Menu("Transpose") {
                    Button("+1 Octave") { store.edit { PatternEditor.transposeBass(&$0, semitones: 12, scaleLock: false) } }
                    Button("−1 Octave") { store.edit { PatternEditor.transposeBass(&$0, semitones: -12, scaleLock: false) } }
                    Divider()
                    Button("+1 Semitone") { store.edit { PatternEditor.transposeBass(&$0, semitones: 1, scaleLock: store.scaleLock) } }
                    Button("−1 Semitone") { store.edit { PatternEditor.transposeBass(&$0, semitones: -1, scaleLock: store.scaleLock) } }
                }
                .fixedSize()
                Menu("Randomize") {
                    Button("Randomize Bass") { randomize() }
                    Divider()
                    Text("Density \(Int(bassDensity * 100))% · Slides \(Int(slideAmount * 100))% · Accents \(Int(accentAmount * 100))%")
                    Button("Sparser") { bassDensity = max(0.15, bassDensity - 0.15); randomize() }
                    Button("Busier") { bassDensity = min(0.95, bassDensity + 0.15); randomize() }
                    Button("More Slides") { slideAmount = min(0.8, slideAmount + 0.15); randomize() }
                    Button("More Accents") { accentAmount = min(0.8, accentAmount + 0.15); randomize() }
                }
                .fixedSize()
                Button("Clear") { store.edit { p in for i in 0..<Pattern.maxSteps { p.bass[i] = .rest } } }
            }
            .controlSize(.small)

            GeometryReader { geo in
                let cellWidth = (geo.size.width - labelWidth) / CGFloat(Pattern.maxSteps)
                VStack(spacing: 0) {
                    pianoRoll(cellWidth: cellWidth)
                        .contentShape(Rectangle())
                        .gesture(rollGesture(cellWidth: cellWidth))
                    attributeRow("TIE", color: Theme.bass.opacity(0.6), cellWidth: cellWidth,
                                 isOn: { $0.kind == .tie },
                                 toggle: { step in store.edit { p in
                                     if p.bass[step].kind == .tie { PatternEditor.setBassRest(&p, step: step) } else { PatternEditor.setBassTie(&p, step: step) }
                                 } })
                    attributeRow("ACCENT", color: Theme.accent, cellWidth: cellWidth,
                                 isOn: { $0.accent && $0.kind == .note },
                                 toggle: { step in store.edit { PatternEditor.toggleBassAccent(&$0, step: step) } })
                    attributeRow("SLIDE", color: Theme.slide, cellWidth: cellWidth,
                                 isOn: { $0.slide && $0.kind != .rest },
                                 toggle: { step in store.edit { PatternEditor.toggleBassSlide(&$0, step: step) } })
                }
            }
            .frame(height: rowHeight * CGFloat(visibleNotes.count) + 3 * 18)
        }
        .padding(8)
        .onAppear(perform: centerOctave)
        .onChange(of: store.currentPresetID) { centerOctave() }
    }

    private func centerOctave() {
        let notes = store.pattern.bass.steps.prefix(store.pattern.length).filter { $0.kind == .note }.map(\.note)
        guard let low = notes.min() else { return }
        baseOctave = max(0, min(5, low / 12 - 1))
    }

    private func randomize() {
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        store.edit { PatternEditor.randomizeBass(&$0, density: bassDensity, slideAmount: slideAmount, accentAmount: accentAmount, octave: baseOctave, seed: seed) }
    }

    private func pianoRoll(cellWidth: CGFloat) -> some View {
        let pattern = store.pattern
        let playheadStep = store.playheadStep
        let notes = visibleNotes
        let labelWidth = self.labelWidth
        let rowHeight = self.rowHeight
        return Canvas { context, size in
            let visibleNotes = notes
            for (row, note) in visibleNotes.enumerated() {
                let y = CGFloat(row) * rowHeight
                let isBlack = [1, 3, 6, 8, 10].contains(note % 12)
                let inScale = pattern.scale.contains(midiNote: note, root: pattern.key)
                // Key label column.
                let keyRect = CGRect(x: 0, y: y, width: labelWidth - 4, height: rowHeight - 0.5)
                context.fill(Path(keyRect), with: .color(isBlack ? Color(white: 0.16) : Color(white: 0.75)))
                if note % 12 == 0 || note % 12 == pattern.key.rawValue {
                    context.draw(Text(NoteName.string(for: note)).font(.system(size: 8, weight: .bold)).foregroundColor(isBlack ? .white : .black),
                                 at: CGPoint(x: labelWidth - 22, y: y + rowHeight / 2))
                }
                // Lane background.
                let laneRect = CGRect(x: labelWidth, y: y, width: size.width - labelWidth, height: rowHeight - 0.5)
                let base = inScale ? Theme.cellOffBeat : Theme.cellOff.opacity(0.55)
                context.fill(Path(laneRect), with: .color(note % 12 == pattern.key.rawValue ? Theme.panelRaised.opacity(1) : base))
            }
            // Beat lines and inactive region.
            for step in 0...Pattern.maxSteps {
                let x = labelWidth + CGFloat(step) * cellWidth
                let line = Path(CGRect(x: x, y: 0, width: step % 4 == 0 ? 1 : 0.5, height: size.height))
                context.fill(line, with: .color(Color.black.opacity(step % 4 == 0 ? 0.7 : 0.35)))
            }
            if pattern.length < Pattern.maxSteps {
                let x = labelWidth + CGFloat(pattern.length) * cellWidth
                context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)), with: .color(Color.black.opacity(0.5)))
            }
            if let playhead = playheadStep {
                let x = labelWidth + CGFloat(playhead) * cellWidth
                context.fill(Path(CGRect(x: x, y: 0, width: cellWidth, height: size.height)), with: .color(Theme.playhead.opacity(0.12)))
            }
            // Notes (a note plus its ties render as one bar).
            var step = 0
            while step < Pattern.maxSteps {
                let s = pattern.bass[step]
                guard s.kind == .note, let row = visibleNotes.firstIndex(of: s.note) else {
                    if s.kind == .note {
                        // Out of view: draw an arrow marker at the edge.
                        let y: CGFloat = s.note > visibleNotes[0] ? 0 : CGFloat(visibleNotes.count - 1) * rowHeight
                        let rect = CGRect(x: labelWidth + CGFloat(step) * cellWidth + 2, y: y, width: cellWidth - 4, height: 3)
                        context.fill(Path(rect), with: .color(Theme.warning))
                    }
                    step += 1
                    continue
                }
                var end = step + 1
                while end < Pattern.maxSteps, pattern.bass[end].kind == .tie { end += 1 }
                let rect = CGRect(x: labelWidth + CGFloat(step) * cellWidth + 1, y: CGFloat(row) * rowHeight + 1,
                                  width: CGFloat(end - step) * cellWidth - 2, height: rowHeight - 2)
                let color = s.accent ? Theme.accent : Theme.bass
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(step < pattern.length ? 1 : 0.35)))
                let lastSlide = pattern.bass[end - 1].slide
                if lastSlide {
                    var glide = Path()
                    glide.move(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
                    glide.addLine(to: CGPoint(x: rect.maxX + cellWidth * 0.5, y: rect.midY))
                    context.stroke(glide, with: .color(Theme.slide), lineWidth: 2)
                }
                step = end
            }
        }
        .frame(height: rowHeight * CGFloat(visibleNotes.count))
        .accessibilityLabel("Bass piano roll, \(pattern.bass.noteCount(length: pattern.length)) notes")
    }

    private func rollGesture(cellWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = value.location.x - labelWidth
                guard x >= 0 else { return }
                let step = Int(x / cellWidth)
                let row = Int(value.location.y / rowHeight)
                guard step < store.pattern.length, row >= 0, row < visibleNotes.count else { return }
                let note = visibleNotes[row]
                if NSEvent.modifierFlags.contains(.option) {
                    store.focusedStep = (nil, step)
                    store.inspectorTab = .step
                    return
                }
                if paintNote == nil {
                    let existing = store.pattern.bass[step]
                    erasing = existing.kind == .note && existing.note == note
                    paintNote = note
                    painted = []
                }
                guard !painted.contains(step) else { return }
                painted.insert(step)
                if erasing {
                    store.edit { PatternEditor.setBassRest(&$0, step: step) }
                } else {
                    let target = paintNote ?? note
                    store.edit { PatternEditor.setBassNote(&$0, step: step, note: target, scaleLock: store.scaleLock) }
                }
                store.focusedStep = (nil, step)
            }
            .onEnded { _ in
                paintNote = nil
                painted = []
                erasing = false
            }
    }

    private func attributeRow(_ title: String, color: Color, cellWidth: CGFloat, isOn: @escaping (BassStep) -> Bool, toggle: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(0..<Pattern.maxSteps, id: \.self) { step in
                Button { toggle(step) } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isOn(store.pattern.bass[step]) ? color : Theme.cellOff)
                        .frame(height: 10)
                        .padding(.horizontal, 2)
                        .opacity(step < store.pattern.length ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .frame(width: cellWidth, height: 18)
                .disabled(step >= store.pattern.length)
            }
        }
    }
}

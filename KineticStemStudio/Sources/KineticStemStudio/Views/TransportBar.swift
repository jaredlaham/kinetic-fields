import AppKit
import StemCore
import SwiftUI

/// Transport, tempo and grid controls, A/B listening and the main actions.
struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @State private var bpmText = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            ToolbarButton(symbol: "backward.end.fill", help: "Return to start") { model.seek(0) }
            ToolbarButton(symbol: model.isPlaying ? "stop.fill" : "play.fill",
                          help: "Play / stop (Space in the note editor, Cmd-Return anywhere)", active: model.isPlaying) {
                model.togglePlay()
            }
            .disabled(model.project.stems.isEmpty)

            VStack(alignment: .leading, spacing: 0) {
                Text(TimeFormat.clock(model.playhead)).font(Theme.mono)
                Text(model.project.tempo.source == .none ? "—" : TimeFormat.barsBeats(model.playhead, tempo: model.project.tempo))
                    .font(Theme.small).foregroundStyle(Theme.textDim)
            }
            .frame(width: 84, alignment: .leading)

            Picker("", selection: $model.listenMode) {
                ForEach(ListenMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .help("A: the stems' audio. B: the transcribed MIDI through a General MIDI preview sound. A+B: both together, to hear mistakes.")
            .onChange(of: model.listenMode) { _, _ in if model.isPlaying { model.seek(model.playhead) } }

            ToolbarButton(symbol: "metronome", help: "Metronome", active: model.metronome) {
                model.metronome.toggle()
                if model.isPlaying { model.seek(model.playhead) }
            }
            ToolbarButton(symbol: "repeat", help: "Loop the selected region", active: model.loopRegion) { model.loopRegion.toggle() }
                .disabled(model.region == nil)

            Divider().frame(height: 22)
            tempoControls
            Divider().frame(height: 22)

            ToolbarButton(symbol: "minus.magnifyingglass", help: "Zoom out") { model.zoom(by: 1 / 1.5) }
            ToolbarButton(symbol: "plus.magnifyingglass", help: "Zoom in") { model.zoom(by: 1.5) }
            ToolbarButton(symbol: "arrow.left.and.right", help: "Zoom to fit") { model.zoomToFit() }

            Spacer()

            Button {
                model.chooseFilesToImport()
            } label: { Label("Import", systemImage: "plus") }
            Button {
                model.transcribeAll()
            } label: { Label("Transcribe All", systemImage: "waveform.path.ecg") }
                .disabled(model.project.stems.isEmpty || !model.engineStatus.isReady)
            Button {
                model.sheet = .export
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!model.project.stems.contains { !$0.notes.isEmpty })
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(Theme.panel)
    }

    private var tempoControls: some View {
        let tempo = model.project.tempo
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    TextField("BPM", text: $bpmText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono)
                        .frame(width: 66)
                        .focused($bpmFocused)
                        .onSubmit { commitBPM() }
                        .onAppear { bpmText = format(tempo.bpm) }
                        .onChange(of: tempo.bpm) { _, v in if !bpmFocused { bpmText = format(v) } }
                    Text("BPM").font(Theme.small).foregroundStyle(Theme.textDim)
                }
                Text(sourceLabel(tempo)).font(.system(size: 9)).foregroundStyle(tempo.stable ? Theme.textDim : Theme.warning)
                    .help(tempo.warnings.joined(separator: "\n"))
            }
            Button("Tap") { model.tap() }.help("Tap at least three times in time with the music")
            Menu {
                Button("Half time (\(format(tempo.bpm / 2)) BPM)") { model.halveTempo() }
                Button("Double time (\(format(tempo.bpm * 2)) BPM)") { model.doubleTempo() }
                if !tempo.alternatives.isEmpty {
                    Section("Other candidates") {
                        ForEach(tempo.alternatives, id: \.self) { alt in
                            Button("\(format(alt)) BPM") { model.setBPM(alt) }
                        }
                    }
                }
                Divider()
                Button("Set Bar 1 at Playhead") { model.setDownbeatAtPlayhead() }
                Button("Move Bar 1 One Beat Earlier") { model.nudgeDownbeat(beats: -1) }
                Button("Move Bar 1 One Beat Later") { model.nudgeDownbeat(beats: 1) }
                Divider()
                Button("Detect Again") {
                    model.project.tempo.source = .detected
                    model.analyze()
                }
            } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("Half/double time, other tempo candidates and bar-1 position")
            Picker("", selection: Binding(
                get: { "\(tempo.beatsPerBar)/\(tempo.beatUnit)" },
                set: { v in
                    let parts = v.split(separator: "/").compactMap { Int($0) }
                    if parts.count == 2 { model.setMeter(beatsPerBar: parts[0], beatUnit: parts[1]) }
                })) {
                ForEach(["2/4", "3/4", "4/4", "5/4", "6/8", "7/8"], id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 70)
            .help("Time signature")
            if !tempo.stable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help("The tempo seems to change in this audio. Kinetic Stem Studio uses one tempo; check the grid near the end of the song.\n" + tempo.warnings.joined(separator: "\n"))
            }
        }
    }

    private func commitBPM() {
        let v = Double(bpmText.replacingOccurrences(of: ",", with: ".")) ?? 0
        if v >= 20 && v <= 400 { model.setBPM(v) } else { bpmText = format(model.project.tempo.bpm) }
        bpmFocused = false
    }

    private func format(_ bpm: Double) -> String {
        bpm == bpm.rounded() ? String(Int(bpm)) : String(format: "%.2f", bpm)
    }

    private func sourceLabel(_ t: TempoMap) -> String {
        switch t.source {
        case .none: "no tempo yet"
        case .detected: String(format: "detected · %.0f%% sure", t.confidence * 100)
        case .manual: "set by you"
        case .tapped: "tapped"
        }
    }
}

import AppKit
import StemCore
import SwiftUI

/// Export dialog: Standard MIDI, Ableton Live and Roland T-8, each with a
/// summary of exactly what will be written before anything is written.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case midi = "MIDI File"
        case ableton = "Ableton Live"
        case t8 = "Roland T-8"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .midi
    @State private var included: Set<UUID> = []
    @State private var individual = false
    @State private var tpq = 480
    @State private var quantized = false
    @State private var regionOnly = false
    @State private var native = true
    @State private var includeAudio = true
    @State private var busy = false
    @State private var resultLines: [String] = []
    @State private var resultFiles: [String] = []
    @State private var resultOK = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
                .onChange(of: tab) { _, _ in clearResult() }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .midi: midiTab
                    case .ableton: abletonTab
                    case .t8: T8ExportView(quantized: $quantized)
                    }
                    if !resultLines.isEmpty { resultView }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Writing and checking files…").foregroundStyle(Theme.textDim) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if tab != .t8 {
                    Button(tab == .midi ? "Export MIDI…" : "Export for Live…") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || included.isEmpty || !model.engineStatus.isReady)
                }
            }
            .padding(16)
        }
        .frame(width: 720, height: 640)
        .background(Theme.panel)
        .font(.system(size: 12))
        .onAppear {
            included = Set(model.project.stems.filter { !$0.notes.isEmpty }.map(\.id))
            tpq = model.project.export.ticksPerQuarter
            quantized = model.project.export.timing == .quantized
        }
    }

    // MARK: common pieces

    private var stemPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Stems")
            ForEach(model.project.stems) { s in
                let notes = s.exportableNotes.count
                let excluded = s.notes.count - notes
                Toggle(isOn: Binding(get: { included.contains(s.id) },
                                     set: { if $0 { included.insert(s.id) } else { included.remove(s.id) } })) {
                    HStack {
                        Circle().fill(Theme.stemColor(s.colorIndex)).frame(width: 7, height: 7)
                        Text(s.name)
                        Text(s.instrument.displayName).foregroundStyle(Theme.textDim)
                        Spacer()
                        if s.transcription == nil {
                            Text("not transcribed").foregroundStyle(Theme.warning)
                        } else {
                            Text("\(notes) notes · ch \(s.midiChannel)").foregroundStyle(Theme.textDim)
                            if excluded > 0 {
                                Text("(\(excluded) left out: rejected or below threshold)").foregroundStyle(Theme.lowConfidence)
                            }
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var timingPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Timing", selection: $quantized) {
                Text("As detected (keeps the groove)").tag(false)
                Text("Quantised").tag(true)
            }
            .pickerStyle(.radioGroup)
            if quantized {
                let q = model.project.quantize
                let shift = model.project.stems.filter { included.contains($0.id) }
                    .map { Quantizer.maxShift($0.exportableNotes, tempo: model.project.tempo, settings: { var s = q; s.enabled = true; return s }()) }
                    .max() ?? 0
                Text(String(format: "Grid %@, strength %.0f%%, swing %.0f%%. Notes move by up to %.0f ms.",
                            q.division.rawValue, q.strength * 100, q.swing * 100, shift * 1000))
                    .font(Theme.small).foregroundStyle(Theme.warning)
                if model.project.tempo.source == .none {
                    Text("No tempo is set, so quantising has nothing to snap to.").font(Theme.small).foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var tempoSummary: some View {
        let t = model.project.tempo
        return HStack {
            Text(String(format: "Tempo %.2f BPM · %d/%d · bar 1 at %@", t.bpm, t.beatsPerBar, t.beatUnit, TimeFormat.clock(t.downbeat)))
            if !t.stable { Text("tempo may drift: one tempo is written").foregroundStyle(Theme.warning) }
        }
        .font(Theme.small).foregroundStyle(Theme.textDim)
    }

    // MARK: MIDI

    private var midiTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stemPicker
            SectionHeader(title: "File")
            Picker("Layout", selection: $individual) {
                Text("One Type 1 file, one track per stem").tag(false)
                Text("One file per stem").tag(true)
            }
            .pickerStyle(.radioGroup)
            Picker("Resolution (ticks per quarter note)", selection: $tpq) {
                ForEach([96, 192, 240, 384, 480, 960, 1920], id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(width: 330)
            timingPicker
            if let r = model.region {
                Toggle("Only the selected region (\(TimeFormat.clock(r.lowerBound)) – \(TimeFormat.clock(r.upperBound)))", isOn: $regionOnly)
            }
            tempoSummary
            Text("Time zero in the file is the start of the audio, so the MIDI lines up when the stems are placed at the start of a DAW session. Every file is read back after writing and compared note by note.")
                .font(Theme.small).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ableton

    private var abletonTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stemPicker
            SectionHeader(title: "Format")
            Picker("", selection: $native) {
                Text("Live Set (.als) with MIDI and audio tracks").tag(true)
                Text("Ableton Import Package (MIDI files, audio and instructions; no .als)").tag(false)
            }
            .pickerStyle(.radioGroup)
            Toggle("Include the stems' audio (copied into the project's Samples folder)", isOn: $includeAudio)
            timingPicker
            tempoSummary
            let trackCount = model.project.stems.filter { included.contains($0.id) }
                .reduce(0) { $0 + ($1.notes.isEmpty ? 0 : 1) + (includeAudio ? 1 : 0) }
            if native {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The Live Set is built from a set saved by Live 12.4 and checked after writing. It opened in Live 12 Lite during development with up to 8 tracks; test it with your own Live version before relying on it.")
                    if trackCount > 8 {
                        Text("\(trackCount) tracks requested. Live 12 Lite opens at most 8, so MIDI tracks come first and the rest stay in the folder, listed in the READ ME.")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .font(Theme.small).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Creates “\(model.safeTitle) Project” with Samples, MIDI and a READ ME explaining how to drag the files into Live at the right tempo.")
                    .font(Theme.small).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: result

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: resultOK ? "Done" : "Problems")
            ForEach(Array(resultLines.enumerated()), id: \.offset) { _, line in
                Text(line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !resultFiles.isEmpty {
                Button("Show in Finder") { model.revealInFinder(resultFiles) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(resultOK ? Theme.ok.opacity(0.1) : Theme.danger.opacity(0.12)))
    }

    private func clearResult() {
        resultLines = []
        resultFiles = []
        resultOK = true
    }

    private func run() {
        clearResult()
        busy = true
        let ids = model.project.stems.map(\.id).filter { included.contains($0) }
        Task {
            defer { busy = false }
            do {
                switch tab {
                case .midi:
                    guard let r = try await model.exportMIDI(stemIDs: ids, individual: individual, tpq: tpq, quantized: quantized,
                                                             regionOnly: regionOnly && model.region != nil) else { return }
                    resultOK = r.validated && r.problems.isEmpty
                    resultLines = [resultOK ? "Wrote \(r.files.count) file(s), \(r.notesWritten) notes. Read back and verified."
                                            : "Written, but the read-back check found differences:"] + r.problems + r.warnings
                    resultFiles = r.files
                case .ableton:
                    guard let r = try await model.exportAbleton(stemIDs: ids, native: native, includeAudio: includeAudio,
                                                                quantized: quantized, tpq: tpq) else { return }
                    resultOK = r.problems.isEmpty
                    var lines = [resultOK ? "Created \(r.folder)" : "Created \(r.folder), but the check found problems:"]
                    lines += r.problems
                    if !r.tracks.isEmpty { lines.append("Tracks: " + r.tracks.joined(separator: ", ")) }
                    if !r.leftOff.isEmpty { lines.append("In the folder but not on a track: " + r.leftOff.joined(separator: ", ")) }
                    lines += r.warnings
                    resultLines = lines
                    resultFiles = [r.folder]
                case .t8:
                    break
                }
                model.isDirty = true
            } catch {
                resultOK = false
                resultLines = [error.localizedDescription]
            }
        }
    }
}

/// Roland T-8 export: Mode A (MIDI pattern file), Mode B (play into the T-8
/// over USB MIDI). Mode C (native pattern files) is not offered: the T-8's
/// pattern backup format is not documented and has not been verified.
struct T8ExportView: View {
    @Environment(AppModel.self) private var model
    @Binding var quantized: Bool
    @State private var drumStem: UUID?
    @State private var bassStem: UUID?
    @State private var conversion: T8ConvertResponse?
    @State private var error: String?
    @State private var busy = false
    @State private var destinations: [MIDIDestination] = []
    @State private var destination: MIDIDestination?
    @State private var sendClock = true
    @State private var loops = 1
    @State private var savedPath: String?

    static let voices = ["BD", "SD", "HC", "TOM", "CH", "OH"]
    static let drumClasses = ["kick", "snare", "clap", "rim", "closed_hat", "open_hat", "low_tom", "high_tom", "crash", "ride", "perc"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The T-8 has six drum voices and a monophonic bass. Patterns hold up to 32 sixteenth-note steps, so longer parts are cut into consecutive patterns.")
                .font(Theme.small).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            SectionHeader(title: "Source")
            HStack {
                Picker("Drums", selection: $drumStem) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.project.stems.filter { $0.instrument.isDrums }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("Bass", selection: $bassStem) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.project.stems.filter { !$0.instrument.isDrums }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            HStack {
                Picker("Pattern length", selection: Binding(get: { model.project.t8.steps },
                                                            set: { model.project.t8.steps = $0; conversion = nil })) {
                    Text("16 steps").tag(16)
                    Text("32 steps").tag(32)
                }
                .frame(width: 200)
                Picker("Timing", selection: $quantized) {
                    Text("Nearest step").tag(false)
                    Text("Quantise first").tag(true)
                }
                .frame(width: 220)
            }
            .help("T-8 steps are sixteenth notes; every hit lands on its nearest step either way. Quantise first applies your quantise settings (swing included) before that.")
            if drumStem != nil { drumMapEditor }
            HStack {
                Button("Convert and Preview") { convert() }.disabled(busy || (drumStem == nil && bassStem == nil))
                if busy { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if let c = conversion { preview(c) }
        }
        .onAppear {
            drumStem = model.project.stems.first { $0.instrument.isDrums && !$0.notes.isEmpty }?.id
            bassStem = model.project.stems.first { [.synthBass, .bassGuitar].contains($0.instrument) && !$0.notes.isEmpty }?.id
            refreshDestinations()
        }
        .onChange(of: drumStem) { _, _ in conversion = nil }
        .onChange(of: bassStem) { _, _ in conversion = nil }
        .onChange(of: quantized) { _, _ in conversion = nil }
    }

    private var drumMapEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Drum mapping")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                ForEach(Self.drumClasses, id: \.self) { cls in
                    Picker(cls.replacingOccurrences(of: "_", with: " "), selection: Binding(
                        get: { model.project.t8.drumMap[cls] ?? "" },
                        set: { model.project.t8.drumMap[cls] = $0; conversion = nil })) {
                        Text("—").tag("")
                        ForEach(Self.voices, id: \.self) { Text($0).tag($0) }
                    }
                    .font(Theme.small)
                }
            }
            Text("T-8 notes (Roland MIDI implementation 1.02): BD 36, SD 38, HC 50, TOM 47, CH 42, OH 46 on channel \(model.project.t8.rhythmChannel); bass on channel \(model.project.t8.bassChannel).")
                .font(Theme.small).foregroundStyle(Theme.textDim)
        }
    }

    private func preview(_ c: T8ConvertResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Result: \(c.segments.count) pattern\(c.segments.count == 1 ? "" : "s")")
            ForEach(c.report, id: \.self) { Text($0).font(Theme.small) }
            if let first = c.segments.first { stepGrid(first) }
            if c.segments.count > 1 { Text("Showing pattern 1 of \(c.segments.count).").font(Theme.small).foregroundStyle(Theme.textDim) }

            SectionHeader(title: "Mode A: MIDI pattern file")
            HStack {
                Button("Save MIDI Pattern…") { saveMIDI() }.disabled(busy)
                if let savedPath { Text(URL(fileURLWithPath: savedPath).lastPathComponent).foregroundStyle(Theme.ok) }
            }
            Text("Rhythm on channel \(model.project.t8.rhythmChannel) and bass on \(model.project.t8.bassChannel), one bar block per pattern; slides are written as overlapping notes. Play it into the T-8 from any DAW or sequencer.")
                .font(Theme.small).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)

            SectionHeader(title: "Mode B: play into the T-8 (USB MIDI)")
            HStack {
                Picker("Output", selection: $destination) {
                    Text("Choose…").tag(MIDIDestination?.none)
                    ForEach(destinations) { d in Text(d.name + (d.isT8 ? "  (T-8)" : "")).tag(MIDIDestination?.some(d)) }
                }
                .frame(width: 300)
                Button { refreshDestinations() } label: { Image(systemName: "arrow.clockwise") }.help("Look for MIDI devices again")
            }
            HStack {
                Toggle("Send MIDI clock and Start/Stop", isOn: $sendClock)
                Stepper("Repeat \(loops)×", value: $loops, in: 1...16)
            }
            HStack {
                Button("Play into T-8") { playIntoT8(c) }.disabled(destination == nil)
                Button("Stop") { model.midiOut.stop() }
            }
            Text("This plays the notes live. Whether the T-8 records incoming MIDI into a pattern is not documented by Roland and has not been tested here, so nothing is claimed to be saved on the device. With clock on, set the T-8 to follow USB clock (see its manual).")
                .font(Theme.small).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)

            SectionHeader(title: "Native T-8 pattern files")
            Text("Not available. The T-8's backup/pattern file format is not published, and writing unverified files to the device could corrupt its memory.")
                .font(Theme.small).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepGrid(_ seg: T8ConvertResponse.Segment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.voices, id: \.self) { v in
                HStack(spacing: 2) {
                    Text(v).font(Theme.mono).frame(width: 36, alignment: .leading)
                    let steps = seg.drums[v] ?? []
                    ForEach(0..<seg.steps, id: \.self) { i in
                        let on = i < steps.count && steps[i].first == 1
                        let accent = i < steps.count && steps[i].count > 2 && steps[i][2] == 1
                        RoundedRectangle(cornerRadius: 2)
                            .fill(on ? (accent ? Theme.accent : Theme.text.opacity(0.8)) : (i % 4 == 0 ? Theme.panelRaised : Theme.lane))
                            .frame(width: 14, height: 12)
                    }
                }
            }
            HStack(spacing: 2) {
                Text("BASS").font(Theme.mono).frame(width: 36, alignment: .leading)
                ForEach(0..<seg.steps, id: \.self) { i in
                    let cell = i < seg.bass.count ? seg.bass[i] : []
                    let note = cell.first ?? nil
                    let tie = cell.count > 1 && (cell[1] ?? 0) == 1
                    Text(note.map { tie ? "–" : NoteEvent.name($0).replacingOccurrences(of: "-", with: "") } ?? "")
                        .font(.system(size: 7, design: .monospaced))
                        .frame(width: 14, height: 12)
                        .background(RoundedRectangle(cornerRadius: 2).fill(note == nil ? Theme.lane : Theme.selection.opacity(0.5)))
                }
            }
        }
    }

    private func refreshDestinations() {
        destinations = model.midiOut.destinations()
        if destination == nil || !destinations.contains(where: { $0.id == destination?.id }) {
            destination = destinations.first { $0.isT8 }
        }
    }

    private func convert() {
        busy = true
        error = nil
        savedPath = nil
        Task {
            defer { busy = false }
            do {
                conversion = try await model.t8Convert(drumStem: drumStem, bassStem: bassStem, quantized: quantized)
                model.isDirty = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func saveMIDI() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let r = try await model.t8SaveMIDI(drumStem: drumStem, bassStem: bassStem, quantized: quantized) {
                    savedPath = r.midiFile
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func playIntoT8(_ c: T8ConvertResponse) {
        guard let destination else { return }
        let t8 = model.project.t8
        let built = MIDIOutput.messages(for: c.segments, bpm: c.bpm, rhythmChannel: t8.rhythmChannel, bassChannel: t8.bassChannel,
                                        sendClock: sendClock, loops: loops)
        model.midiOut.play(built.messages, length: built.length, to: destination, channels: [t8.rhythmChannel, t8.bassChannel])
    }
}

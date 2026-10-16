import AppKit
import StemCore
import SwiftUI

/// Settings for the selected stem (instrument, mode, thresholds), the
/// transcription job, note review and quantisation.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stem = model.selectedStem {
                    instrumentSection(stem)
                    transcriptionSection(stem)
                    reviewSection(stem)
                } else {
                    Text("Select a stem.").foregroundStyle(Theme.textDim)
                }
                quantizeSection
            }
            .padding(12)
            .font(.system(size: 12))
        }
        .background(Theme.panel)
    }

    // MARK: instrument

    private func instrumentSection(_ stem: Stem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Instrument")
            if let c = stem.classification {
                HStack {
                    Text("Detected:").foregroundStyle(Theme.textDim)
                    Text(c.proposed.displayName)
                    Text(String(format: "%.0f%%", c.confidence * 100))
                        .foregroundStyle(c.confidence < 0.5 ? Theme.warning : Theme.textDim)
                }
                let ranked = c.scores.sorted { $0.value > $1.value }.prefix(3)
                if ranked.count > 1 {
                    Text("Also possible: " + ranked.dropFirst().compactMap { k, v in
                        InstrumentClass(rawValue: k).map { "\($0.displayName) \(Int(v * 100))%" }
                    }.joined(separator: ", "))
                    .font(Theme.small).foregroundStyle(Theme.textDim)
                }
            } else if model.analysis != nil {
                Text("Analysing…").foregroundStyle(Theme.textDim)
            }
            Picker("Treat as", selection: Binding(
                get: { stem.instrumentOverride ?? stem.classification?.proposed ?? .otherMelodic },
                set: { v in
                    model.updateStem(stem.id) {
                        $0.instrumentOverride = v == $0.classification?.proposed ? nil : v
                        $0.midiChannel = v.isDrums ? 10 : ($0.midiChannel == 10 ? 1 : $0.midiChannel)
                    }
                })) {
                ForEach(InstrumentClass.allCases) { Text($0.displayName).tag($0) }
            }
            HStack {
                Text("Pipeline:").foregroundStyle(Theme.textDim)
                Text(stem.instrument.pipeline)
            }
            .font(Theme.small)
            if stem.instrumentOverride != nil {
                Text("Your choice overrides the detection.").font(Theme.small).foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: transcription

    private func transcriptionSection(_ stem: Stem) -> some View {
        let job = model.jobs[stem.id]
        let running = job?.state == .transcribing || job?.state == .queued
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Transcription")
            Picker("Mode", selection: Binding(get: { stem.mode }, set: { v in model.updateStem(stem.id) { $0.mode = v } })) {
                ForEach(TranscriptionMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(modeHelp(stem.mode, instrument: stem.instrument)).font(Theme.small).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if stem.instrument.isDrums {
                LabeledSlider(label: "Hit sensitivity", value: Binding(get: { stem.drumSensitivity },
                                                                        set: { v in model.updateStem(stem.id) { $0.drumSensitivity = v } }),
                              range: 0...1, format: "%.2f")
            } else {
                Toggle("Pitch bends (slides, vibrato)", isOn: Binding(get: { stem.pitchBends },
                                                                      set: { v in model.updateStem(stem.id) { $0.pitchBends = v } }))
            }
            Stepper("MIDI channel \(stem.midiChannel)", value: Binding(get: { stem.midiChannel },
                                                                       set: { v in model.updateStem(stem.id) { $0.midiChannel = v } }),
                    in: 1...16)
            HStack {
                if running {
                    ProgressView(value: job?.fraction ?? 0).frame(maxWidth: .infinity)
                    Button("Cancel") { model.cancelTranscription(stem.id) }
                } else {
                    Button(stem.transcription == nil ? "Transcribe" : "Transcribe Again") {
                        model.transcribe([stem.id], force: stem.transcription != nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!model.engineStatus.isReady)
                }
            }
            if let job {
                Text(job.message).font(Theme.small)
                    .foregroundStyle(job.state == .failed ? Theme.danger : Theme.textDim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = stem.transcription {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(t.notes.count) notes · \(t.mode.displayName) · \(String(format: "%.1f s", t.processingSeconds))")
                    Text(t.engine).foregroundStyle(Theme.textDim)
                }
                .font(Theme.small)
                ForEach(t.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modeHelp(_ mode: TranscriptionMode, instrument: InstrumentClass) -> String {
        switch (mode, instrument.isDrums) {
        case (.fast, true): "Band-energy onsets: kick, snare and hats only."
        case (.balanced, true): "Onsets plus a trained hit classifier (11 drum classes)."
        case (.high, true): "Classifier plus extra low/high-band onset search for quiet hits."
        case (.fast, false): instrument.pipeline.hasPrefix("Poly") ? "Neural note model, no clean-up." : "Pitch tracking (YIN) only."
        case (.balanced, false): "Neural note model with harmonic and retrigger clean-up. Recommended."
        case (.high, false): "Adds a second pass for missed notes (and CREPE for leads when installed). Slower; on our tests not more accurate than Balanced for every stem."
        }
    }

    // MARK: review

    private func reviewSection(_ stem: Stem) -> some View {
        let notes = stem.notes
        let below = notes.filter { $0.accepted == nil && $0.confidence < stem.confidenceThreshold }.count
        let selected = model.selectedNoteIDs
        let selNotes = notes.filter { selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Review")
            LabeledSlider(label: "Confidence threshold",
                          value: Binding(get: { stem.confidenceThreshold },
                                         set: { v in model.updateStem(stem.id) { $0.confidenceThreshold = v } }),
                          range: 0...1, format: "%.2f")
            Text(below == 0 ? "No unreviewed notes below the threshold."
                 : "\(below) notes below the threshold are left out of playback B and exports until you accept them.")
                .font(Theme.small).foregroundStyle(below == 0 ? Theme.textDim : Theme.lowConfidence)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reject Below Threshold") { model.rejectBelowThreshold() }.disabled(below == 0)
            }
            if !selNotes.isEmpty {
                Divider()
                Text("\(selNotes.count) selected").foregroundStyle(Theme.selection)
                if selNotes.count == 1, let n = selNotes.first {
                    Text("\(stem.instrument.isDrums ? (n.drum ?? "hit") : NoteEvent.name(n.pitch)) · \(TimeFormat.clock(n.start)) · \(String(format: "%.0f ms", n.duration * 1000)) · confidence \(String(format: "%.2f", n.confidence))")
                        .font(Theme.small).foregroundStyle(Theme.textDim)
                }
                HStack {
                    Button("Accept") { model.setAccepted(true) }
                    Button("Reject") { model.setAccepted(false) }
                    Button("Clear") { model.setAccepted(nil) }.help("Back to unreviewed")
                }
                HStack {
                    Button("Quantize") { model.quantizeSelection() }
                        .help("Moves the selected notes onto the grid using the settings below (undoable)")
                    Button("Delete", role: .destructive) { model.deleteSelectedNotes() }
                }
            }
            if stem.hasEdits {
                Button("Revert to Transcription…") { model.revertToTranscription() }
            }
        }
    }

    // MARK: quantize

    private var quantizeSection: some View {
        let q = model.project.quantize
        let shift: Double = {
            guard q.enabled else { return 0 }
            return model.project.stems.map { Quantizer.maxShift($0.exportableNotes, tempo: model.project.tempo, settings: q) }.max() ?? 0
        }()
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Quantize (non-destructive)")
            Toggle("Quantize playback and preview", isOn: Binding(get: { q.enabled }, set: { v in setQ { $0.enabled = v } }))
            Picker("Grid", selection: Binding(get: { q.division }, set: { v in setQ { $0.division = v } })) {
                ForEach(GridDivision.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledSlider(label: "Strength", value: Binding(get: { q.strength }, set: { v in setQ { $0.strength = v } }),
                          range: 0...1, format: "%.0f%%", scale: 100)
            LabeledSlider(label: "Swing", value: Binding(get: { q.swing }, set: { v in setQ { $0.swing = v } }),
                          range: 0...1, format: "%.0f%%", scale: 100)
            Toggle("Quantize note ends", isOn: Binding(get: { q.quantizeEnds }, set: { v in setQ { $0.quantizeEnds = v } }))
            Text(q.enabled
                 ? String(format: "Detected timing is kept. Notes move up to %.0f ms when heard or exported with quantised timing.", shift * 1000)
                 : "Off: notes keep the timing detected in the audio. Exports ask which timing to use.")
                .font(Theme.small).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if model.project.tempo.source == .none {
                Text("Needs a tempo: analyse the stems or set the BPM first.").font(Theme.small).foregroundStyle(Theme.warning)
            }
        }
    }

    private func setQ(_ f: (inout QuantizeSettings) -> Void) {
        f(&model.project.quantize)
        model.isDirty = true
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value * scale)).font(Theme.mono).foregroundStyle(Theme.textDim)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

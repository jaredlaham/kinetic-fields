import AppKit
import StemCore
import SwiftUI

/// The stem list: reorder by dragging, rename, mute/solo, volume, remove or replace.
struct StemSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "Stems")
                Button { model.chooseFilesToImport() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Import stems")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            List(selection: Binding(
                get: { model.selectedStemID },
                set: { id in
                    if id != model.selectedStemID { model.selectedNoteIDs.removeAll() }
                    model.selectedStemID = id
                })) {
                ForEach(model.project.stems) { stem in
                    StemRow(stem: stem).tag(stem.id)
                }
                .onMove { model.moveStems(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.panel)
    }
}

struct StemRow: View {
    @Environment(AppModel.self) private var model
    let stem: Stem
    @State private var editingName = false
    @State private var name = ""

    var body: some View {
        let color = Theme.stemColor(stem.colorIndex)
        let job = model.jobs[stem.id]
        let missing = !FileManager.default.fileExists(atPath: stem.file.path)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    if editingName {
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(Theme.label)
                            .onSubmit {
                                let n = name.trimmingCharacters(in: .whitespaces)
                                if !n.isEmpty { model.updateStem(stem.id) { $0.name = n } }
                                editingName = false
                            }
                            .onExitCommand { editingName = false }
                    } else {
                        Text(stem.name).font(Theme.label).lineLimit(1)
                            .onTapGesture(count: 2) { name = stem.name; editingName = true }
                    }
                    Text(subtitle(stem, missing: missing)).font(Theme.small)
                        .foregroundStyle(missing || stem.lastError != nil ? Theme.danger : Theme.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                toggle("M", on: stem.muted, color: Theme.warning, help: "Mute") { model.updateStem(stem.id) { $0.muted.toggle() } }
                toggle("S", on: stem.soloed, color: Theme.ok, help: "Solo") { model.updateStem(stem.id) { $0.soloed.toggle() } }
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                Slider(value: Binding(get: { stem.volumeDB }, set: { v in model.updateStem(stem.id) { $0.volumeDB = v } }),
                       in: -36...6)
                    .controlSize(.mini)
                Text(String(format: "%+.0f dB", stem.volumeDB)).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textDim).frame(width: 40, alignment: .trailing)
            }
            if let job, job.state == .transcribing || job.state == .queued {
                HStack(spacing: 4) {
                    ProgressView(value: job.fraction).controlSize(.mini)
                    Button { model.cancelTranscription(stem.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Cancel")
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Rename") { name = stem.name; editingName = true }
            Button("Transcribe") { model.transcribe([stem.id]) }
            Button("Replace Audio…") { model.replaceAudio(stem.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([stem.file.url]) }
            Divider()
            Button("Remove", role: .destructive) { model.removeStem(stem.id) }
        }
    }

    private func subtitle(_ s: Stem, missing: Bool) -> String {
        if missing { return "Audio file not found" }
        if let e = s.lastError { return e }
        let dur = TimeFormat.clock(s.file.duration)
        let kind = s.instrumentOverride != nil ? s.instrument.displayName : (s.classification.map { "\($0.proposed.displayName)?" } ?? "Analysing…")
        let notes = s.transcription == nil ? "" : " · \(s.notes.count) notes"
        return "\(kind) · \(dur)\(notes)"
    }

    private func toggle(_ label: String, on: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 16)
                .foregroundStyle(on ? Color.black : Theme.textDim)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? color : Theme.panelRaised))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

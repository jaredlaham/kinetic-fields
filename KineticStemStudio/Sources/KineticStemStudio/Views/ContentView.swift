import AppKit
import StemCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TransportBar()
            Divider()
            HStack(spacing: 0) {
                StemSidebar()
                    .frame(width: 250)
                Divider()
                Group {
                    if model.project.stems.isEmpty {
                        EmptyStateView()
                    } else {
                        VSplitView {
                            TimelineView()
                                .frame(minHeight: 150, idealHeight: 260)
                            NoteEditorView()
                                .frame(minHeight: 220)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView()
                    .frame(width: 300)
            }
            Divider()
            StatusBar()
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .top) { BannerView() }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle(model.title)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .export: ExportSheet().environment(model)
            case .engineSetup: EngineSetupView().environment(model)
            }
        }
        .alert("Recover unsaved work?", isPresented: Binding(
            get: { model.recoveryCandidate != nil && model.sheet == nil },
            set: { if !$0 && model.recoveryCandidate != nil { model.discardRecovery() } })
        ) {
            Button("Recover") { model.recover() }
            Button("Discard", role: .destructive) { model.discardRecovery() }
        } message: {
            Text("Kinetic Stem Studio found a project that was not saved before the app closed.")
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Drop stems here").font(.system(size: 20, weight: .semibold))
            Text("WAV, AIFF, FLAC, MP3 or M4A files, or a folder of them.\nEach stem gets its own lane, instrument and MIDI track.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
            HStack {
                Button("Import Stems…") { model.chooseFilesToImport() }
                    .keyboardShortcut(.defaultAction)
                Button("Open Project…") { model.openWithPanel() }
            }
            if !model.engineStatus.isReady {
                EngineStatusLine().padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let b = model.banner {
            HStack(spacing: 8) {
                Image(systemName: icon(b.kind)).foregroundStyle(color(b.kind))
                Text(b.text).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                Button { model.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelRaised).shadow(radius: 8))
            .padding(.top, 52)
            .frame(maxWidth: 640)
            .task(id: b.id) {
                // Errors stay until dismissed; other messages fade.
                guard b.kind != .error else { return }
                try? await Task.sleep(for: .seconds(6))
                if model.banner?.id == b.id { model.banner = nil }
            }
        }
    }

    private func icon(_ k: Banner.Kind) -> String {
        switch k {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ k: Banner.Kind) -> Color {
        switch k {
        case .info: Theme.selection
        case .success: Theme.ok
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

struct EngineStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.engineStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking the analysis engine…").foregroundStyle(Theme.textDim)
            case .ready(let v):
                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                Text("Engine \(v)").foregroundStyle(Theme.textDim)
            case .missing:
                Circle().fill(Theme.warning).frame(width: 7, height: 7)
                Text("The analysis engine is not installed.")
                Button("Set Up…") { model.sheet = .engineSetup }
            case .problem(let why):
                Circle().fill(Theme.danger).frame(width: 7, height: 7)
                Text(why).lineLimit(1)
                Button("Details…") { model.sheet = .engineSetup }
            }
        }
        .font(.system(size: 11))
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            EngineStatusLine()
            if let a = model.analysis {
                HStack(spacing: 6) {
                    ProgressView(value: a.fraction).frame(width: 90).controlSize(.small)
                    Text(a.message).lineLimit(1).foregroundStyle(Theme.textDim)
                }
            }
            let running = model.jobs.values.filter { $0.state == .transcribing }.count
            let queued = model.jobs.values.filter { $0.state == .queued }.count
            if running + queued > 0 {
                Text("Transcribing \(running)" + (queued > 0 ? ", \(queued) waiting" : ""))
                    .foregroundStyle(Theme.textDim)
                Button("Cancel All") { model.cancelAll() }.controlSize(.small)
            }
            Spacer()
            if let r = model.region {
                Text("Selection \(TimeFormat.clock(r.lowerBound)) – \(TimeFormat.clock(r.upperBound))")
                    .foregroundStyle(Theme.selection)
                Button { model.region = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            }
            Text("\(model.project.stems.count) stems").foregroundStyle(Theme.textDim)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.panel)
    }
}

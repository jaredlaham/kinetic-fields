import AppKit
import StemCore
import SwiftUI

@main
struct KineticStemStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Kinetic Stem Studio", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.model = model }
        }
        .commands { StudioCommands(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.confirmDiscard() else { return .terminateCancel }
        model.cancelAll()
        model.clearAutosave()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        if let project = urls.first(where: { $0.pathExtension == ProjectStore.fileExtension }) {
            model.open(project)
        } else {
            model.importFiles(urls)
        }
    }
}

struct StudioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { model.openWithPanel() }.keyboardShortcut("o")
            Divider()
            Button("Import Stems…") { model.chooseFilesToImport() }.keyboardShortcut("i")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s")
            Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export…") { model.sheet = .export }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.history.undoLabel.map { "Undo \($0)" } ?? "Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.history.canUndo)
            Button(model.history.redoLabel.map { "Redo \($0)" } ?? "Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.history.canRedo)
        }
        CommandMenu("Stems") {
            Button("Analyse Tempo and Instruments") { model.analyze() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Transcribe Selected Stem") { if let id = model.selectedStemID { model.transcribe([id]) } }
                .keyboardShortcut("t")
                .disabled(model.selectedStemID == nil)
            Button("Transcribe All Stems") { model.transcribeAll() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Cancel All Jobs") { model.cancelAll() }.keyboardShortcut(".")
            Divider()
            Button("Engine Setup…") { model.sheet = .engineSetup }
        }
        CommandMenu("Notes") {
            Button("Accept Selected") { model.setAccepted(true) }.keyboardShortcut("a", modifiers: [.command, .option])
            Button("Reject Selected") { model.setAccepted(false) }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Reject All Below Threshold") { model.rejectBelowThreshold() }
            Button("Quantize Selected") { model.quantizeSelection() }.keyboardShortcut("u")
            Divider()
            Button("Revert Stem to Transcription") { model.revertToTranscription() }
        }
        CommandMenu("Transport") {
            Button(model.isPlaying ? "Stop" : "Play") { model.togglePlay() }.keyboardShortcut(.return, modifiers: [.command])
            Button("Return to Start") { model.seek(0) }.keyboardShortcut(.leftArrow, modifiers: [.command])
            Divider()
            Picker("Listen", selection: Binding(get: { model.listenMode }, set: { model.listenMode = $0 })) {
                ForEach(ListenMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Metronome", isOn: Binding(get: { model.metronome }, set: { model.metronome = $0 }))
                .keyboardShortcut("k")
            Toggle("Loop Selection", isOn: Binding(get: { model.loopRegion }, set: { model.loopRegion = $0 }))
                .keyboardShortcut("l")
            Divider()
            Button("Zoom In") { model.zoom(by: 1.5) }.keyboardShortcut("=")
            Button("Zoom Out") { model.zoom(by: 1 / 1.5) }.keyboardShortcut("-")
            Button("Zoom to Fit") { model.zoomToFit() }.keyboardShortcut("0")
        }
    }
}

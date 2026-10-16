import AppKit
import SwiftUI
import T8Core

@main
struct T8PatternStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = StudioStore()

    var body: some Scene {
        WindowGroup("T-8 Pattern Studio") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.store = store }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { StudioCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

/// Asks before quitting with unsaved changes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: StudioStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(store.currentPreset?.name ?? store.pattern.name)” before quitting?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if store.currentPresetID != nil && !store.currentIsFactory {
                store.save()
                return .terminateNow
            }
            store.activeSheet = .savePresetAs
            return .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct StudioCommands: Commands {
    let store: StudioStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Preset") { store.newPreset() }.keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Preset") { store.save() }.keyboardShortcut("s")
            Button("Save Preset As…") { store.activeSheet = .savePresetAs }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Duplicate Preset") { store.duplicateCurrent() }
            Divider()
            Button("Import Presets…") { store.importPresets() }
            Button("Export Current Preset…") { if let id = store.currentPresetID { store.exportPresets([id]) } }
            Divider()
            Button("Import MIDI File…") { store.activeSheet = .midiImport }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Beat from Audio File…") { store.activeSheet = .audioToBeat }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Export MIDI File…") { store.exportMIDI() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export A/B/C/D as MIDI…") { store.exportAllVariationsMIDI() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }.keyboardShortcut("z")
            Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Pattern") {
            Button("Copy Steps") { store.copySelection() }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Paste Steps") { store.pasteAtSelection() }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Clear Steps") { store.clearSelection() }.keyboardShortcut(.delete, modifiers: [.command, .option])
            Button("Duplicate Length (16 → 32)") { store.edit { PatternEditor.duplicateLength(&$0) } }.keyboardShortcut("d")
            Divider()
            Button("Shift Left") { store.edit { PatternEditor.shift(&$0, voices: DrumVoice.allCases, includeBass: true, by: -1) } }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Shift Right") { store.edit { PatternEditor.shift(&$0, voices: DrumVoice.allCases, includeBass: true, by: 1) } }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            ForEach(VariationSlot.allCases) { slot in
                Button("Variation \(slot.letter) — \(slot.title)") { store.selectSlot(slot) }
                    .keyboardShortcut(KeyEquivalent(Character(String(VariationSlot.allCases.firstIndex(of: slot)! + 1))))
            }
        }
        CommandMenu("Transport") {
            Button(store.isPlaying ? "Stop" : "Play") { store.togglePlay() }.keyboardShortcut(.return, modifiers: [.command])
            Toggle("Loop", isOn: Binding(get: { store.isLooping }, set: { store.setLooping($0) })).keyboardShortcut("l")
        }
        CommandMenu("T-8") {
            Button("Transfer to T-8…") { store.activeSheet = .transfer }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Hardware Compatibility Matrix") { store.activeSheet = .capabilities }
            Button("Refresh MIDI Devices") { store.refreshMIDI() }
        }
        CommandMenu("Library") {
            Button("Manage Library…") { store.activeSheet = .manageLibrary }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(store.showBrowser ? "Hide Preset Browser" : "Show Preset Browser") { store.showBrowser.toggle() }.keyboardShortcut("b", modifiers: [.command])
        }
    }
}

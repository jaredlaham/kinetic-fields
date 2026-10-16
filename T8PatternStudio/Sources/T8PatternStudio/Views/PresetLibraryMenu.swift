import SwiftUI
import T8Core

/// Toolbar "Preset Library" menu: a synth-style hierarchical preset menu with
/// factory genres, user folders, favorites, recents and library actions.
struct PresetLibraryMenu: View {
    @Environment(StudioStore.self) private var store

    var body: some View {
        Menu {
            Button("All Presets…") { store.browserCategory = .all; store.showBrowser = true }
            Menu("Recent") { presetItems(store.library.presets(in: .recent)) }
            Menu("Favorites") { presetItems(store.library.presets(in: .favorites)) }
            Menu("Factory Presets") {
                ForEach(Genre.allCases) { genre in
                    Menu(genre.displayName) { presetItems(FactoryLibrary.presets(for: genre)) }
                }
            }
            Menu("My Presets") {
                Menu("All My Presets") { presetItems(store.library.search(.mine)) }
                Menu("My Folders") {
                    if store.library.folders.isEmpty { Text("No folders yet") }
                    ForEach(store.library.folders) { folder in
                        Menu(folder.name) { presetItems(store.library.search(.folder(folder.id))) }
                    }
                    Menu("Unfiled") { presetItems(store.library.search(.unfiled)) }
                }
                Menu("Recently Saved") { presetItems(store.library.presets(in: .recentlySaved)) }
            }
            Divider()
            Button("New Preset") { store.newPreset() }
            Button("Save Preset") { store.save() }
            Button("Save Preset As…") { store.activeSheet = .savePresetAs }
            Button("Duplicate Preset") { store.duplicateCurrent() }
            Divider()
            Button("Import Presets…") { store.importPresets() }
            Button("Export Presets…") {
                let ids = store.library.userPresets.map(\.id)
                if ids.isEmpty { store.errorMessage = "You have no presets of your own to export yet." } else { store.exportPresets(ids) }
            }
            Button("Manage Library…") { store.activeSheet = .manageLibrary }
        } label: {
            Label("Preset Library", systemImage: "square.grid.3x3.square")
        }
        .fixedSize()
        .help("Browse factory and personal presets")
    }

    @ViewBuilder
    private func presetItems(_ presets: [Preset]) -> some View {
        if presets.isEmpty {
            Text("Empty")
        }
        ForEach(presets) { preset in
            Menu("\(store.library.isFavorite(preset.id) ? "★ " : "")\(preset.name)  ·  \(Int(preset.main.bpm)) BPM") {
                Button(store.previewingPresetID == preset.id ? "Stop Preview" : "Preview") { store.preview(preset) }
                Divider()
                ForEach(LoadMode.allCases) { mode in
                    Button(mode.rawValue) { store.requestLoad(preset, mode: mode) }
                }
                Divider()
                Button("Save As…") {
                    store.saveAs(from: preset)
                }
                Button(store.library.isFavorite(preset.id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(preset.id) }
            }
        }
    }
}

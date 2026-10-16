import SwiftUI
import T8Core

/// Persistent, expandable preset browser (sidebar), like a synth preset browser.
struct PresetBrowserView: View {
    @Environment(StudioStore.self) private var store
    @State private var search = ""
    @State private var sort: PresetSort = .name
    @State private var favoritesOnly = false
    @State private var selectedID: PresetID?
    @State private var factoryExpanded = true
    @State private var mineExpanded = true
    @State private var expandedGenres: Set<Genre> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                SectionHeader(title: "Preset Library")
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                    TextField("Search name, tag, genre, key…", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                HStack {
                    Picker("Sort", selection: $sort) {
                        ForEach(PresetSort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Toggle(isOn: $favoritesOnly) { Image(systemName: favoritesOnly ? "star.fill" : "star") }
                        .toggleStyle(.button)
                        .help("Favorites only")
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(8)

            List(selection: $selectedID) {
                if !search.isEmpty || favoritesOnly {
                    Section("Results") {
                        ForEach(results(.all)) { row($0) }
                    }
                } else {
                    Section("Library") {
                        categoryRow("All Presets", icon: "square.stack.3d.up", category: .all)
                        categoryRow("Recent", icon: "clock", category: .recent)
                        categoryRow("Favorites", icon: "star", category: .favorites)
                    }
                    if isFactoryCategory {
                        factorySection
                    } else {
                        Section(categoryTitle) {
                            ForEach(results(store.browserCategory)) { row($0) }
                        }
                        factorySection
                    }
                    mySection
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let id = selectedID, let preset = store.library.preset(id) {
                PresetDetailCard(preset: preset)
                    .padding(8)
            }
        }
        .background(Theme.panel)
    }

    private var isFactoryCategory: Bool {
        switch store.browserCategory {
        case .factory, .factoryGenre: true
        default: false
        }
    }

    private var categoryTitle: String {
        switch store.browserCategory {
        case .all: "All Presets"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .mine: "All My Presets"
        case .recentlySaved: "Recently Saved"
        case .unfiled: "Unfiled"
        case .folder(let id): store.library.folders.first { $0.id == id }?.name ?? "Folder"
        case .factory, .factoryGenre: "Factory Presets"
        }
    }

    private var factorySection: some View {
        Section(isExpanded: $factoryExpanded) {
            ForEach(Genre.allCases) { genre in
                DisclosureGroup(isExpanded: Binding(get: { expandedGenres.contains(genre) }, set: { open in
                    if open { expandedGenres.insert(genre) } else { expandedGenres.remove(genre) }
                })) {
                    ForEach(results(.factoryGenre(genre))) { row($0) }
                } label: {
                    Label(genre.displayName, systemImage: "music.note.list")
                }
            }
        } header: {
            Text("Factory Presets")
        }
    }

    private var mySection: some View {
        Section(isExpanded: $mineExpanded) {
            categoryRow("All My Presets", icon: "person", category: .mine)
            categoryRow("Recently Saved", icon: "clock.arrow.circlepath", category: .recentlySaved)
            ForEach(store.library.folders) { folder in
                DisclosureGroup {
                    ForEach(results(.folder(folder.id))) { row($0) }
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
                .contextMenu {
                    Button("Show in Browser") { store.browserCategory = .folder(folder.id) }
                    Button("Manage Library…") { store.activeSheet = .manageLibrary }
                }
            }
            if store.library.userPresets.isEmpty {
                Text("Save a pattern to start your collection.").font(Theme.small).foregroundStyle(Theme.textDim)
            }
        } header: {
            Text("My Presets")
        }
    }

    private func categoryRow(_ title: String, icon: String, category: LibraryCategory) -> some View {
        Button {
            store.browserCategory = category
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(store.library.presets(in: category).count)").font(Theme.small).foregroundStyle(Theme.textDim)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.browserCategory == category ? Theme.accent : Theme.text)
    }

    private func results(_ category: LibraryCategory) -> [Preset] {
        store.library.search(category, filter: PresetFilter(searchText: search, favoritesOnly: favoritesOnly), sort: sort)
    }

    private func row(_ preset: Preset) -> some View {
        PresetRow(preset: preset)
            .tag(preset.id)
            .onTapGesture(count: 2) { store.requestLoad(preset, mode: .full) }
            .simultaneousGesture(TapGesture().onEnded { selectedID = preset.id })
            .contextMenu { PresetContextMenu(preset: preset) }
    }
}

struct PresetRow: View {
    @Environment(StudioStore.self) private var store
    let preset: Preset

    var body: some View {
        HStack(spacing: 6) {
            Button { store.preview(preset) } label: {
                Image(systemName: store.previewingPresetID == preset.id && store.isPlaying ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Preview without replacing your pattern")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.name).font(.system(size: 12, weight: store.currentPresetID == preset.id ? .bold : .regular)).lineLimit(1)
                    if preset.isFactory { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.textDim) }
                }
                Text("\(Int(preset.main.bpm)) BPM · \(preset.main.key.name) \(preset.main.scale.displayName) · \(preset.main.length) st")
                    .font(Theme.small).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer()
            EnergyMeter(energy: preset.energy)
            Button { store.toggleFavorite(preset.id) } label: {
                Image(systemName: store.library.isFavorite(preset.id) ? "star.fill" : "star")
                    .foregroundStyle(store.library.isFavorite(preset.id) ? Theme.warning : Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
    }
}

struct PresetContextMenu: View {
    @Environment(StudioStore.self) private var store
    let preset: Preset

    var body: some View {
        Button(store.previewingPresetID == preset.id ? "Stop Preview" : "Preview") { store.preview(preset) }
        ForEach(LoadMode.allCases) { mode in
            Button(mode.rawValue) { store.requestLoad(preset, mode: mode) }
        }
        Divider()
        Button("Save As…") { store.saveAs(from: preset) }
        Button(store.library.isFavorite(preset.id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(preset.id) }
        Button("Duplicate") { store.mutateLibrary { _ = try $0.duplicate(preset.id) } }
        Button("Export…") { store.exportPresets([preset.id]) }
        if !preset.isFactory {
            Divider()
            Button("Edit Details…") { store.activeSheet = .editMetadata(preset.id) }
            Menu("Move to Folder") {
                Button("Unfiled") { store.mutateLibrary { try $0.move(preset.id, to: nil) } }
                ForEach(store.library.folders) { folder in
                    Button(folder.name) { store.mutateLibrary { try $0.move(preset.id, to: folder.id) } }
                }
            }
            Button("Delete…", role: .destructive) { store.pendingDelete = preset.id }
        }
    }
}

struct PresetDetailCard: View {
    @Environment(StudioStore.self) private var store
    let preset: Preset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(preset.name).font(.system(size: 13, weight: .bold))
                Spacer()
                if store.library.isFavorite(preset.id) { Image(systemName: "star.fill").foregroundStyle(Theme.warning) }
            }
            Text([preset.genres.map(\.displayName).joined(separator: ", "),
                  "\(Int(preset.main.bpm)) BPM", "\(preset.main.key.name) \(preset.main.scale.displayName)", "\(preset.main.length) steps"]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.small).foregroundStyle(Theme.textDim)
            HStack { Text("Energy").font(Theme.small).foregroundStyle(Theme.textDim); EnergyMeter(energy: preset.energy) }
            if !preset.summary.isEmpty { Text(preset.summary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
            if !preset.tags.isEmpty {
                Text(preset.tags.map { "#\($0)" }.joined(separator: " ")).font(Theme.small).foregroundStyle(Theme.bass)
            }
            MiniPatternView(pattern: preset.main).frame(height: 44)
            HStack {
                Button(store.previewingPresetID == preset.id ? "Stop" : "Preview") { store.preview(preset) }
                Menu("Load") {
                    ForEach(LoadMode.allCases) { mode in Button(mode.rawValue) { store.requestLoad(preset, mode: mode) } }
                }
                .fixedSize()
                Spacer()
                Button("Save As…") { store.saveAs(from: preset) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Small read-only grid used for previews in lists and the transfer wizard.
struct MiniPatternView: View {
    let pattern: Pattern

    var body: some View {
        Canvas { context, size in
            let rows = DrumVoice.allCases.count + 1
            let cellW = size.width / CGFloat(pattern.length)
            let cellH = size.height / CGFloat(rows)
            for (row, voice) in DrumVoice.allCases.enumerated() {
                for step in 0..<pattern.length where pattern.drums[voice, step] != nil {
                    let rect = CGRect(x: CGFloat(step) * cellW + 0.5, y: CGFloat(row) * cellH + 0.5, width: cellW - 1, height: cellH - 1)
                    context.fill(Path(rect), with: .color(Theme.voiceColor(voice)))
                }
            }
            for step in 0..<pattern.length where pattern.bass[step].kind != .rest {
                let rect = CGRect(x: CGFloat(step) * cellW + 0.5, y: CGFloat(rows - 1) * cellH + 0.5, width: cellW - 1, height: cellH - 1)
                context.fill(Path(rect), with: .color(pattern.bass[step].kind == .tie ? Theme.bass.opacity(0.5) : Theme.bass))
            }
        }
        .background(Theme.cellOff.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

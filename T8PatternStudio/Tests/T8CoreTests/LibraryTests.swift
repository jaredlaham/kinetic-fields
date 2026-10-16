import XCTest
@testable import T8Core

final class LibraryTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("t8-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func makeVariations(_ name: String = "Mine") -> PatternVariations {
        var base = FactoryLibrary.presets[0].main
        base.name = name
        return PatternVariationEngine.makeVariations(from: base, genre: .house, seed: 1)
    }

    func testSaveNewAndLoad() throws {
        var library = PresetLibrary()
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "My Groove", genres: [.house], tags: ["Dark", "dark", " club "], favorite: true))
        XCTAssertEqual(saved.origin, .user)
        XCTAssertEqual(saved.tags, ["dark", "club"])
        XCTAssertTrue(library.isFavorite(saved.id))
        XCTAssertEqual(library.preset(saved.id)?.name, "My Groove")
        XCTAssertEqual(library.allPresets.count, 61)
    }

    func testFactoryPresetsAreReadOnly() throws {
        var library = PresetLibrary()
        let factoryID = FactoryLibrary.presets[0].id
        XCTAssertThrowsError(try library.update(factoryID, variations: makeVariations())) { error in
            XCTAssertEqual(error as? LibraryError, .factoryPresetIsReadOnly(factoryID))
        }
        XCTAssertThrowsError(try library.rename(factoryID, to: "Hacked"))
        XCTAssertThrowsError(try library.delete(factoryID))
        XCTAssertEqual(library.preset(factoryID), FactoryLibrary.presets[0])
        // Save As path: duplicate produces an editable user copy.
        let copy = try library.duplicate(factoryID)
        XCTAssertEqual(copy.origin, .user)
        XCTAssertEqual(copy.name, "Classic Four Copy")
        XCTAssertNoThrow(try library.update(copy.id, variations: makeVariations()))
    }

    func testPersistenceAcrossRestart() throws {
        let store = LibraryStore(directory: tempDir)
        var library = PresetLibrary(document: try store.load().document)
        let folder = try library.createFolder(named: "Live Set")
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Opener", genres: [.techno], folderID: folder.id))
        library.markRecent(saved.id)
        try store.save(library.document)

        // "Restart": new store + library from disk.
        let reloaded = PresetLibrary(document: try LibraryStore(directory: tempDir).load().document)
        XCTAssertEqual(reloaded.preset(saved.id), library.preset(saved.id))
        XCTAssertEqual(reloaded.presets(in: .folder(folder.id)).map(\.id), [saved.id])
        XCTAssertEqual(reloaded.presets(in: .recent).first?.id, saved.id)
        XCTAssertEqual(reloaded.factory.count, 60, "factory presets come from the bundle, not the user file")
    }

    func testFoldersMoveAndDelete() throws {
        var library = PresetLibrary()
        let parent = try library.createFolder(named: "Sets")
        let child = try library.createFolder(named: "Friday", parent: parent.id)
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "A"))
        try library.move(saved.id, to: child.id)
        XCTAssertEqual(library.presets(in: .folder(child.id)).count, 1)
        try library.deleteFolder(child.id)
        XCTAssertEqual(library.preset(saved.id)?.folderID, parent.id, "presets move up, never get deleted with a folder")
        try library.renameFolder(parent.id, to: "Sets 2026")
        XCTAssertEqual(library.folders.first?.name, "Sets 2026")
        XCTAssertThrowsError(try library.createFolder(named: "  "))
    }

    func testFavoritesAndSearch() throws {
        var library = PresetLibrary()
        let acid = FactoryLibrary.presets.first { $0.name == "Acid Pressure" }!
        library.toggleFavorite(acid.id)
        XCTAssertEqual(library.presets(in: .favorites).map(\.id), [acid.id])
        library.toggleFavorite(acid.id)
        XCTAssertTrue(library.presets(in: .favorites).isEmpty)

        let results = library.search(filter: PresetFilter(searchText: "acid"))
        XCTAssertTrue(results.contains { $0.id == acid.id })
        let tripHop = library.search(.factoryGenre(.tripHop), sort: .bpm)
        XCTAssertEqual(tripHop.map(\.main.bpm), [76, 82, 88, 92])
        let fast = library.search(filter: PresetFilter(bpmRange: 138...200))
        XCTAssertTrue(fast.allSatisfy { $0.main.bpm >= 138 })
        let multi = library.search(filter: PresetFilter(searchText: "dark electro"))
        XCTAssertTrue(multi.contains { $0.name == "Dark Voltage" })
    }

    func testDuplicateUserPresetGetsUniqueNames() throws {
        var library = PresetLibrary()
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Loop"))
        let c1 = try library.duplicate(saved.id)
        let c2 = try library.duplicate(saved.id)
        XCTAssertEqual(c1.name, "Loop Copy")
        XCTAssertEqual(c2.name, "Loop Copy 2")
        XCTAssertNotEqual(c1.id, c2.id)
    }

    func testRevisionsAndRestore() throws {
        var library = PresetLibrary()
        let original = makeVariations("v1")
        let saved = try library.saveNew(variations: original, metadata: PresetMetadata(name: "Evolving"))
        var changed = original
        PatternEditor.toggle(&changed.a, voice: .tom, step: 3)
        try library.update(saved.id, variations: changed)
        XCTAssertEqual(library.revisions(of: saved.id).count, 1)
        let revision = library.revisions(of: saved.id)[0]
        try library.restoreRevision(revision.id, of: saved.id)
        XCTAssertEqual(library.preset(saved.id)?.variations, original)
        XCTAssertEqual(library.revisions(of: saved.id).count, 2, "restoring keeps the replaced content as a revision")
    }

    func testDeleteRemovesFavoritesAndRecents() throws {
        var library = PresetLibrary()
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Temp", favorite: true))
        library.markRecent(saved.id)
        try library.delete(saved.id)
        XCTAssertNil(library.preset(saved.id))
        XCTAssertTrue(library.document.favoriteIDs.isEmpty)
        XCTAssertTrue(library.document.recentIDs.isEmpty)
    }

    func testImportExportBundle() throws {
        var library = PresetLibrary()
        let saved = try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Shared"))
        let data = try library.exportBundle([saved.id, FactoryLibrary.presets[5].id]).encoded()
        var other = PresetLibrary()
        let imported = other.importPresets(try PresetBundle.decode(data))
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(imported.allSatisfy { $0.origin == .user && !$0.id.isFactory })
        // Importing again never overwrites.
        let again = other.importPresets(try PresetBundle.decode(data))
        XCTAssertEqual(Set((imported + again).map(\.id)).count, 4)
        XCTAssertEqual(again[0].name, "Shared 2")
    }

    func testSchemaMigrationFromV1() throws {
        let v1 = """
        {"schemaVersion":1,"presets":[{"id":"user.legacy","name":"Old One","origin":"user","genre":"Trip-Hop","favorite":true,
        "variations":\(String(decoding: try JSONCoding.encoder.encode(makeVariations()), as: UTF8.self))}],"folders":[]}
        """
        try Data(v1.utf8).write(to: tempDir.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: tempDir)
        let result = try store.load()
        XCTAssertEqual(result.migratedFrom, 1)
        XCTAssertEqual(result.document.presets.first?.genres, [.tripHop])
        XCTAssertEqual(result.document.favoriteIDs, [PresetID("user.legacy")])
        XCTAssertFalse(store.backups().isEmpty, "a backup is written before migrating")
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryURL)) as! [String: Any]
        XCTAssertEqual(onDisk["schemaVersion"] as? Int, UserLibraryDocument.currentSchemaVersion)
    }

    func testNewerSchemaIsNotTouched() throws {
        let future = #"{"schemaVersion":99,"presets":[]}"#
        try Data(future.utf8).write(to: tempDir.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try LibraryStore(directory: tempDir).load())
        XCTAssertEqual(try String(contentsOf: tempDir.appendingPathComponent("library.json"), encoding: .utf8), future)
    }

    func testCorruptLibraryRecoversFromBackupAndKeepsCorruptCopy() throws {
        let store = LibraryStore(directory: tempDir)
        var library = PresetLibrary()
        try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Keep Me"))
        try store.save(library.document)
        try library.saveNew(variations: makeVariations(), metadata: PresetMetadata(name: "Second"))
        try store.save(library.document) // first save of a session backs up the previous file
        try Data("{not json".utf8).write(to: store.libraryURL)
        let result = try LibraryStore(directory: tempDir).load()
        XCTAssertTrue(result.recoveredFromCorruption)
        XCTAssertTrue(result.document.presets.contains { $0.name == "Keep Me" })
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("library.corrupt-") })
    }
}

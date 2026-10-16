import AppKit
import Foundation
import StemCore
import UniformTypeIdentifiers

/// Exports: Standard MIDI, Ableton Live, Roland T-8. The engine writes and
/// validates the files; the app chooses destinations and reports results.
extension AppModel {
    func exportTrack(_ stem: Stem, quantized: Bool) -> ExportTrack {
        ExportTrack(name: stem.name, channel: stem.midiChannel, notes: outputNotes(stem, quantized: quantized),
                    program: stem.instrument.isDrums ? nil : Int(stem.instrument.previewProgram), isDrum: stem.instrument.isDrums)
    }

    var meter: [Int] { [project.tempo.beatsPerBar, project.tempo.beatUnit] }

    var safeTitle: String {
        let t = projectURL?.deletingPathExtension().lastPathComponent ?? project.name
        return t.isEmpty ? "Kinetic Stem" : t
    }

    /// Asks where to write MIDI. Returns nil when cancelled.
    func chooseMIDIDestination(individual: Bool) -> URL? {
        if individual {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose a folder for one MIDI file per stem"
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = safeTitle + ".mid"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func exportMIDI(stemIDs: [UUID], individual: Bool, tpq: Int, quantized: Bool, regionOnly: Bool) async throws -> MIDIExportResponse? {
        guard let out = chooseMIDIDestination(individual: individual) else { return nil }
        let stems = project.stems.filter { stemIDs.contains($0.id) }
        let req = MIDIExportRequest(tracks: stems.map { exportTrack($0, quantized: quantized) }, bpm: project.tempo.bpm,
                                    meter: meter, tpq: tpq, out: out.path, layout: individual ? "individual" : "multitrack",
                                    title: safeTitle, region: regionOnly ? region.map { [$0.lowerBound, $0.upperBound] } : nil)
        project.export.ticksPerQuarter = tpq
        project.export.timing = quantized ? .quantized : .original
        project.export.lastFolder = (individual ? out : out.deletingLastPathComponent()).path
        return try await engine.run("export-midi", request: req, as: MIDIExportResponse.self)
    }

    func exportAbleton(stemIDs: [UUID], native: Bool, includeAudio: Bool, quantized: Bool, tpq: Int) async throws -> AbletonExportResponse? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to create the “\(safeTitle) Project” folder"
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let stems = project.stems.filter { stemIDs.contains($0.id) }
        let parts = stems.map { s in
            AbletonExportRequest.StemPart(name: s.name, path: s.file.path, instrument: s.instrument,
                                          midi: s.notes.isEmpty ? nil : exportTrack(s, quantized: quantized),
                                          includeAudio: includeAudio)
        }
        var req = AbletonExportRequest(stems: parts, bpm: project.tempo.bpm, meter: meter, title: safeTitle,
                                       parent: parent.path, kind: native ? "native" : "package", tpq: tpq, overwrite: false)
        do {
            return try await engine.run("export-ableton", request: req, as: AbletonExportResponse.self)
        } catch EngineClient.EngineError.failed(let kind, _) where kind == "exists" {
            guard confirm("“\(safeTitle) Project” already exists there.", "Replace it? The old folder is moved aside only after the new one is complete.") else { return nil }
            req.overwrite = true
            return try await engine.run("export-ableton", request: req, as: AbletonExportResponse.self)
        }
    }

    func t8Request(drumStem: UUID?, bassStem: UUID?, quantized: Bool, midiOut: String?) -> T8ConvertRequest {
        let drums = drumStem.flatMap { id in project.stems.first { $0.id == id } }.map { outputNotes($0, quantized: quantized) } ?? []
        let bass = bassStem.flatMap { id in project.stems.first { $0.id == id } }.map { outputNotes($0, quantized: quantized) } ?? []
        return T8ConvertRequest(drumNotes: drums, bassNotes: bass, bpm: project.tempo.bpm, gridStart: project.tempo.downbeat,
                                steps: project.t8.steps, segments: nil, drumMap: project.t8.drumMap, midiOut: midiOut,
                                rhythmChannel: project.t8.rhythmChannel, bassChannel: project.t8.bassChannel)
    }

    func t8Convert(drumStem: UUID?, bassStem: UUID?, quantized: Bool) async throws -> T8ConvertResponse {
        try await engine.run("t8-convert", request: t8Request(drumStem: drumStem, bassStem: bassStem, quantized: quantized, midiOut: nil),
                             as: T8ConvertResponse.self)
    }

    func t8SaveMIDI(drumStem: UUID?, bassStem: UUID?, quantized: Bool) async throws -> T8ConvertResponse? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = safeTitle + " (T-8).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try await engine.run("t8-convert", request: t8Request(drumStem: drumStem, bassStem: bassStem, quantized: quantized,
                                                                    midiOut: url.path),
                                    as: T8ConvertResponse.self)
    }

    func revealInFinder(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }
}

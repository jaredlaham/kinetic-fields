import AppKit
import StemCore
import SwiftUI

/// Vertical layout of the editor: pitches for the piano roll, drum classes for the drum grid.
struct RowLayout {
    static let drumRows: [(id: String, label: String, pitch: Int)] = [
        ("crash", "Crash", 49), ("ride", "Ride", 51), ("open_hat", "Open hat", 46), ("closed_hat", "Closed hat", 42),
        ("high_tom", "High tom", 50), ("low_tom", "Low tom", 45), ("perc", "Perc", 56), ("rim", "Rim", 37),
        ("clap", "Clap", 39), ("snare", "Snare", 38), ("kick", "Kick", 36),
    ]

    var isDrums: Bool
    var topPitch: Int
    var rowHeight: CGFloat

    var rowCount: Int { isDrums ? Self.drumRows.count : topPitch + 1 }

    func row(of note: NoteEvent) -> Int {
        guard isDrums else { return topPitch - note.pitch }
        if let d = note.drum, let i = Self.drumRows.firstIndex(where: { $0.id == d }) { return i }
        if let i = Self.drumRows.firstIndex(where: { $0.pitch == note.pitch }) { return i }
        return Self.drumRows.firstIndex { $0.id == "perc" } ?? 0
    }

    func y(ofRow r: Int) -> CGFloat { CGFloat(r) * rowHeight }

    func row(atY y: CGFloat) -> Int { Int(floor(y / rowHeight)) }

    /// Pitch and drum class for a row.
    func values(forRow r: Int) -> (pitch: Int, drum: String?) {
        if isDrums {
            let d = Self.drumRows[max(0, min(Self.drumRows.count - 1, r))]
            return (d.pitch, d.id)
        }
        return (max(0, min(127, topPitch - r)), nil)
    }

    func label(forRow r: Int) -> String {
        isDrums ? Self.drumRows[r].label : NoteEvent.name(topPitch - r)
    }
}

/// Piano roll (melodic stems) or drum grid (drum stems) for the selected stem.
/// Drag notes to move them, drag their right edge to resize, double-click
/// empty space to add a note, drag empty space to select. Delete removes,
/// arrow keys nudge, Cmd-A selects all. Every edit can be undone.
struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var snap = true
    @State private var topPitch = 84
    @State private var drag: DragState?
    @State private var lastClick: (time: Date, point: CGPoint)?
    @State private var velocityPreview: (ids: Set<UUID>, velocity: Int)?
    @FocusState private var focused: Bool

    enum DragMode { case move, resize, marquee }

    struct DragState {
        var mode: DragMode
        var ids: Set<UUID>
        var start: CGPoint
        var current: CGPoint
        var anchor: NoteEvent?
        var additive: Bool
    }

    var body: some View {
        if let stem = model.selectedStem {
            VStack(spacing: 0) {
                header(stem)
                Divider()
                editor(stem)
            }
            .background(Theme.panel)
            .onChange(of: stem.id) { _, _ in fit(stem) }
            .onChange(of: stem.transcription?.createdAt) { _, _ in fit(stem) }
            .onAppear { fit(stem) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "pianokeys").font(.system(size: 26)).foregroundStyle(Theme.textDim)
                Text("Select a stem to edit its notes").foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
        }
    }

    private func layout(_ stem: Stem, height: CGFloat) -> RowLayout {
        stem.instrument.isDrums
            ? RowLayout(isDrums: true, topPitch: 0, rowHeight: max(14, min(26, height / CGFloat(RowLayout.drumRows.count))))
            : RowLayout(isDrums: false, topPitch: topPitch, rowHeight: 12)
    }

    private func fit(_ stem: Stem) {
        let pitches = stem.notes.map(\.pitch)
        guard let hi = pitches.max(), let lo = pitches.min() else { topPitch = 84; return }
        topPitch = min(127, max(hi + 4, lo + 24))
    }

    // MARK: header

    private func header(_ stem: Stem) -> some View {
        let notes = stem.notes
        let low = notes.filter { $0.accepted == nil && $0.confidence < stem.confidenceThreshold }.count
        let rejected = notes.filter { $0.accepted == false }.count
        return HStack(spacing: 10) {
            Text(stem.instrument.isDrums ? "DRUM GRID" : "PIANO ROLL")
                .font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textDim)
            Text(stem.name).font(Theme.label).foregroundStyle(Theme.text)
            if stem.transcription == nil {
                Text("Not transcribed yet").font(Theme.small).foregroundStyle(Theme.warning)
            } else {
                Text("\(notes.count) notes").font(Theme.small).foregroundStyle(Theme.textDim)
                if low > 0 { Text("\(low) below threshold").font(Theme.small).foregroundStyle(Theme.lowConfidence) }
                if rejected > 0 { Text("\(rejected) rejected").font(Theme.small).foregroundStyle(Theme.textDim) }
                if stem.hasEdits { Text("edited").font(Theme.small).foregroundStyle(Theme.accent) }
            }
            if !model.selectedNoteIDs.isEmpty {
                Text("\(model.selectedNoteIDs.count) selected").font(Theme.small).foregroundStyle(Theme.selection)
            }
            Spacer()
            Toggle("Snap", isOn: $snap).toggleStyle(.checkbox).font(Theme.small)
                .help("Snap moves and new notes to the \(model.project.quantize.division.rawValue) grid")
            Toggle("Confidence", isOn: Bindable(model).showConfidence).toggleStyle(.checkbox).font(Theme.small)
                .help("Shade notes by the engine's confidence; outline notes below the stem's threshold")
            if model.project.quantize.enabled {
                Label("Quantize preview on", systemImage: "squareshape.split.3x3").font(Theme.small).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    // MARK: editor

    private func editor(_ stem: Stem) -> some View {
        GeometryReader { g in
            let velocityHeight: CGFloat = 54
            let keysWidth: CGFloat = 64
            let rows = layout(stem, height: g.size.height - velocityHeight)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    keys(rows).frame(width: keysWidth)
                    Divider()
                    grid(stem, rows: rows)
                        .focusable()
                        .focused($focused)
                        .focusEffectDisabled()
                        .onKeyPress(phases: [.down, .repeat]) { press in key(press, stem: stem) }
                }
                .clipped()
                Divider()
                HStack(spacing: 0) {
                    Text("VELOCITY").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
                        .frame(width: keysWidth)
                    Divider()
                    velocityLane(stem)
                }
                .frame(height: velocityHeight)
            }
            .background(ScrollWheelCatcher { e in
                if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
                    model.zoom(by: pow(1.01, Double(e.scrollingDeltaY)), around: model.playhead)
                    return true
                }
                let vertical = abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) && !e.modifierFlags.contains(.shift)
                if vertical && !rows.isDrums {
                    let step = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
                    topPitch = max(12, min(127, topPitch + Int(step.rounded())))
                    return true
                }
                let dx = Double(e.scrollingDeltaX) + (e.modifierFlags.contains(.shift) ? Double(e.scrollingDeltaY) : 0)
                guard abs(dx) > 0.01 else { return false }
                model.scroll(seconds: -dx / model.pixelsPerSecond * (e.hasPreciseScrollingDeltas ? 1 : 8))
                return true
            })
        }
    }

    private func keys(_ rows: RowLayout) -> some View {
        Canvas { ctx, size in
            let visible = Int(ceil(size.height / rows.rowHeight))
            for r in 0..<min(rows.rowCount, visible) {
                let y = rows.y(ofRow: r)
                let pitch = rows.topPitch - r
                let black = !rows.isDrums && [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rows.rowHeight - 0.5)),
                         with: .color(black ? Color(white: 0.16) : Color(white: rows.isDrums ? 0.13 : 0.24)))
                if rows.isDrums || pitch % 12 == 0 || rows.rowHeight >= 14 {
                    ctx.draw(Text(rows.label(forRow: r)).font(.system(size: 9, weight: pitch % 12 == 0 ? .bold : .regular))
                        .foregroundColor(Theme.text.opacity(0.8)), at: CGPoint(x: size.width - 4, y: y + rows.rowHeight / 2), anchor: .trailing)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            // Audition the row through the preview sampler is out of scope; selecting the row's notes is useful instead.
            let r = rows.row(atY: location.y)
            guard let stem = model.selectedStem else { return }
            model.selectedNoteIDs = Set(stem.notes.filter { rows.row(of: $0) == r }.map(\.id))
        }
        .help("Click a row to select all its notes")
    }

    private func gridTimes(_ stem: Stem) -> (step: Double, snapTo: (Double) -> Double) {
        let tempo = model.project.tempo
        let step = tempo.secondsPerBeat * model.project.quantize.division.beats
        let snapTo: (Double) -> Double = { t in
            guard step > 0, tempo.source != .none else { return t }
            return tempo.downbeat + ((t - tempo.downbeat) / step).rounded() * step
        }
        return (step, snapTo)
    }

    private func grid(_ stem: Stem, rows: RowLayout) -> some View {
        let pps = model.pixelsPerSecond
        let t0 = model.viewStart
        let tempo = model.project.tempo
        let playhead = model.playhead
        let region = model.region
        let selected = model.selectedNoteIDs
        let showConf = model.showConfidence
        let color = Theme.stemColor(stem.colorIndex)
        let quantPreview = model.project.quantize.enabled
        let displayNotes = quantPreview ? Quantizer.apply(stem.notes, tempo: tempo, settings: model.project.quantize) : stem.notes
        let drag = self.drag
        let preview = dragPreview(stem: stem, rows: rows)
        let velocityPreview = self.velocityPreview

        return Canvas { ctx, size in
            let t1 = t0 + Double(size.width) / pps
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.lane))
            // Row stripes.
            let visibleRows = Int(ceil(size.height / rows.rowHeight))
            for r in 0..<min(rows.rowCount, visibleRows) {
                let pitch = rows.topPitch - r
                let dark = rows.isDrums ? r % 2 == 1 : [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12)
                if dark {
                    ctx.fill(Path(CGRect(x: 0, y: rows.y(ofRow: r), width: size.width, height: rows.rowHeight)),
                             with: .color(Color.black.opacity(0.18)))
                }
                if !rows.isDrums && pitch % 12 == 0 {
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: 0, y: rows.y(ofRow: r + 1)))
                        p.addLine(to: CGPoint(x: size.width, y: rows.y(ofRow: r + 1)))
                    }, with: .color(Theme.gridBar), lineWidth: 1)
                }
            }
            // Beat grid (and subdivisions when zoomed in).
            if tempo.source != .none {
                for line in tempo.gridLines(from: t0, to: t1) {
                    let x = CGFloat((line.time - t0) * pps)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(line.isBar ? Theme.gridBar : Theme.gridBeat), lineWidth: 1)
                }
            }
            if let r = region {
                let x0 = CGFloat((r.lowerBound - t0) * pps), x1 = CGFloat((r.upperBound - t0) * pps)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(Theme.selection.opacity(0.08)))
            }
            // Notes.
            for n in displayNotes where n.end >= t0 && n.start <= t1 {
                let shown = preview[n.id] ?? n
                let r = rows.row(of: shown)
                let y = rows.y(ofRow: r)
                guard y > -rows.rowHeight, y < size.height else { continue }
                let x = CGFloat((shown.start - t0) * pps)
                let w: CGFloat = rows.isDrums ? max(6, min(14, CGFloat(shown.duration * pps))) : max(3, CGFloat(shown.duration * pps))
                let rect = CGRect(x: x, y: y + 1, width: w, height: rows.rowHeight - 2)
                let isSel = selected.contains(n.id)
                let rejected = n.accepted == false
                let low = n.accepted == nil && n.confidence < stem.confidenceThreshold
                let velocity = velocityPreview.flatMap { $0.ids.contains(n.id) ? $0.velocity : nil } ?? shown.velocity
                var fill = color.opacity(showConf ? 0.35 + 0.65 * n.confidence : 0.9)
                if rejected { fill = Theme.textDim.opacity(0.25) }
                let shape = rows.isDrums
                    ? Path(roundedRect: rect.insetBy(dx: 0, dy: max(0, (rect.height - CGFloat(velocity) / 127 * rect.height) / 2)), cornerRadius: 2)
                    : Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(shape, with: .color(fill))
                if showConf && low && !rejected {
                    ctx.stroke(shape, with: .color(Theme.lowConfidence), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
                if n.accepted == true {
                    ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)), with: .color(Theme.ok))
                }
                if isSel {
                    ctx.stroke(shape, with: .color(Theme.selection), lineWidth: 2)
                }
                if !n.bends.isEmpty && !rows.isDrums {
                    var path = Path()
                    for (k, b) in n.bends.enumerated() where b.count == 2 {
                        let px = CGFloat((shown.start + b[0] - t0) * pps)
                        let py = y + rows.rowHeight / 2 - CGFloat(b[1]) * rows.rowHeight
                        if k == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    ctx.stroke(path, with: .color(Theme.text.opacity(0.7)), lineWidth: 1)
                }
                if rows.rowHeight >= 12 && w > 26 && !rows.isDrums {
                    ctx.draw(Text(NoteEvent.name(shown.pitch)).font(.system(size: 8, weight: .medium)).foregroundColor(.black.opacity(0.75)),
                             at: CGPoint(x: x + 3, y: y + rows.rowHeight / 2), anchor: .leading)
                }
            }
            // Marquee.
            if let d = drag, d.mode == .marquee {
                let rect = CGRect(x: min(d.start.x, d.current.x), y: min(d.start.y, d.current.y),
                                  width: abs(d.current.x - d.start.x), height: abs(d.current.y - d.start.y))
                ctx.fill(Path(rect), with: .color(Theme.selection.opacity(0.12)))
                ctx.stroke(Path(rect), with: .color(Theme.selection), lineWidth: 1)
            }
            let px = CGFloat((playhead - t0) * pps)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(Theme.playhead), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in dragChanged(v, stem: stem, rows: rows) }
            .onEnded { v in dragEnded(v, stem: stem, rows: rows) })
    }

    // MARK: gestures

    private func hit(_ p: CGPoint, stem: Stem, rows: RowLayout) -> (NoteEvent, Bool)? {
        let pps = model.pixelsPerSecond, t0 = model.viewStart
        for n in stem.notes.reversed() {
            let y = rows.y(ofRow: rows.row(of: n))
            guard p.y >= y, p.y < y + rows.rowHeight else { continue }
            let x0 = CGFloat((n.start - t0) * pps)
            let w: CGFloat = rows.isDrums ? max(6, min(14, CGFloat(n.duration * pps))) : max(3, CGFloat(n.duration * pps))
            if p.x >= x0 - 2 && p.x <= x0 + w + 2 {
                return (n, !rows.isDrums && w > 10 && p.x >= x0 + w - 5)
            }
        }
        return nil
    }

    private func dragChanged(_ v: DragGesture.Value, stem: Stem, rows: RowLayout) {
        focused = true
        if drag == nil {
            let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
            if let found = hit(v.startLocation, stem: stem, rows: rows) {
                let note = found.0, edge = found.1
                var ids = model.selectedNoteIDs
                if !ids.contains(note.id) { ids = additive ? ids.union([note.id]) : [note.id] }
                model.selectedNoteIDs = ids
                drag = DragState(mode: edge ? .resize : .move, ids: ids, start: v.startLocation, current: v.location,
                                 anchor: note, additive: additive)
            } else {
                if !additive { model.selectedNoteIDs.removeAll() }
                drag = DragState(mode: .marquee, ids: model.selectedNoteIDs, start: v.startLocation, current: v.location,
                                 anchor: nil, additive: additive)
            }
        }
        drag?.current = v.location
    }

    /// Time and row offsets of the current drag, snapped when Snap is on.
    private func dragOffsets(stem: Stem, rows: RowLayout) -> (seconds: Double, rows: Int)? {
        guard let d = drag, d.mode != .marquee else { return nil }
        var dt = Double(d.current.x - d.start.x) / model.pixelsPerSecond
        let dr = Int(((d.current.y - d.start.y) / rows.rowHeight).rounded())
        if snap, let a = d.anchor {
            let g = gridTimes(stem)
            if d.mode == .move { dt = g.snapTo(a.start + dt) - a.start } else { dt = g.snapTo(a.end + dt) - a.end }
        }
        return (dt, d.mode == .move ? dr : 0)
    }

    private func dragPreview(stem: Stem, rows: RowLayout) -> [UUID: NoteEvent] {
        guard let d = drag, let off = dragOffsets(stem: stem, rows: rows), abs(off.seconds) > 0 || off.rows != 0 else { return [:] }
        let dt = off.seconds, dr = off.rows
        var out: [UUID: NoteEvent] = [:]
        for n in stem.notes where d.ids.contains(n.id) {
            var m = n
            if d.mode == .move {
                m.start = max(0, n.start + dt)
                m.end = m.start + n.duration
                let vals = rows.values(forRow: rows.row(of: n) + dr)
                m.pitch = vals.pitch
                if rows.isDrums { m.drum = vals.drum }
            } else {
                m.end = max(n.start + 0.01, n.end + dt)
            }
            out[n.id] = m
        }
        return out
    }

    private func dragEnded(_ v: DragGesture.Value, stem: Stem, rows: RowLayout) {
        defer { drag = nil }
        guard let d = drag else { return }
        let moved = hypot(v.location.x - v.startLocation.x, v.location.y - v.startLocation.y) > 3
        switch d.mode {
        case .marquee:
            if moved {
                let rect = CGRect(x: min(d.start.x, v.location.x), y: min(d.start.y, v.location.y),
                                  width: abs(v.location.x - d.start.x), height: abs(v.location.y - d.start.y))
                let pps = model.pixelsPerSecond, t0 = model.viewStart
                let inside = stem.notes.filter { n in
                    let y = rows.y(ofRow: rows.row(of: n))
                    let r = CGRect(x: CGFloat((n.start - t0) * pps), y: y, width: CGFloat(max(4, n.duration * pps)), height: rows.rowHeight)
                    return r.intersects(rect)
                }.map(\.id)
                model.selectedNoteIDs = d.additive ? model.selectedNoteIDs.union(inside) : Set(inside)
            } else {
                // Double-click on empty space adds a note.
                if let last = lastClick, Date().timeIntervalSince(last.time) < 0.35,
                   hypot(last.point.x - v.location.x, last.point.y - v.location.y) < 5 {
                    addNote(at: v.location, stem: stem, rows: rows)
                    lastClick = nil
                } else {
                    lastClick = (Date(), v.location)
                    model.seek(model.viewStart + Double(v.location.x) / model.pixelsPerSecond)
                }
            }
        case .move, .resize:
            guard moved else {
                if d.additive, let a = d.anchor, model.selectedNoteIDs.contains(a.id), model.selectedNoteIDs.count > 1 {
                    model.selectedNoteIDs.remove(a.id)
                } else if let a = d.anchor, !d.additive {
                    model.selectedNoteIDs = [a.id]
                }
                return
            }
            let preview = dragPreview(stem: stem, rows: rows)
            guard !preview.isEmpty else { return }
            model.edit(d.mode == .move ? "Move Notes" : "Resize Notes", stem: stem.id) { notes in
                notes.map { preview[$0.id] ?? $0 }.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
            }
        }
    }

    private func addNote(at p: CGPoint, stem: Stem, rows: RowLayout) {
        let g = gridTimes(stem)
        var t = model.viewStart + Double(p.x) / model.pixelsPerSecond
        if snap { t = g.snapTo(t) }
        let vals = rows.values(forRow: rows.row(atY: p.y))
        let length = rows.isDrums ? 0.1 : max(0.05, g.step)
        let note = NoteEvent(pitch: vals.pitch, start: max(0, t), end: max(0, t) + length, velocity: 100, confidence: 1,
                             drum: vals.drum, accepted: true)
        model.edit("Add Note", stem: stem.id) { NoteEditor.add(note, to: $0) }
        model.selectedNoteIDs = [note.id]
    }

    private func key(_ press: KeyPress, stem: Stem) -> KeyPress.Result {
        let ids = model.selectedNoteIDs
        switch press.key {
        case .delete, .deleteForward:
            model.deleteSelectedNotes()
            return .handled
        case .escape:
            model.selectedNoteIDs.removeAll()
            return .handled
        case .space:
            model.togglePlay()
            return .handled
        case .upArrow, .downArrow:
            guard !ids.isEmpty, !stem.instrument.isDrums else { return .ignored }
            let semis = (press.key == .upArrow ? 1 : -1) * (press.modifiers.contains(.shift) ? 12 : 1)
            model.edit("Transpose Notes", stem: stem.id) { NoteEditor.move(ids, in: $0, by: 0, semitones: semis) }
            return .handled
        case .leftArrow, .rightArrow:
            guard !ids.isEmpty else { return .ignored }
            let step = press.modifiers.contains(.option) ? 0.005 : gridTimes(stem).step
            let dt = press.key == .rightArrow ? step : -step
            model.edit("Nudge Notes", stem: stem.id) { NoteEditor.move(ids, in: $0, by: dt, semitones: 0) }
            return .handled
        default:
            if press.characters == "a" && press.modifiers.contains(.command) {
                model.selectedNoteIDs = Set(stem.notes.map(\.id))
                return .handled
            }
            return .ignored
        }
    }

    // MARK: velocity lane

    private func velocityLane(_ stem: Stem) -> some View {
        let pps = model.pixelsPerSecond
        let t0 = model.viewStart
        let selected = model.selectedNoteIDs
        let color = Theme.stemColor(stem.colorIndex)
        let preview = velocityPreview
        let notes = stem.notes
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background))
            let t1 = t0 + Double(size.width) / pps
            for n in notes where n.start >= t0 - 1 && n.start <= t1 {
                let x = CGFloat((n.start - t0) * pps)
                let vel = preview.flatMap { $0.ids.contains(n.id) ? $0.velocity : nil } ?? n.velocity
                let h = CGFloat(vel) / 127 * (size.height - 6)
                let c = selected.contains(n.id) ? Theme.selection : color.opacity(n.accepted == false ? 0.25 : 0.8)
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 2, height: h)), with: .color(c))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height - h - 2, width: 6, height: 4)), with: .color(c))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = model.viewStart + Double(v.startLocation.x) / model.pixelsPerSecond
                let tolerance = 6 / model.pixelsPerSecond
                guard let nearest = stem.notes.min(by: { abs($0.start - t) < abs($1.start - t) }),
                      abs(nearest.start - t) <= tolerance || velocityPreview != nil else { return }
                let ids = velocityPreview?.ids ?? (selected.contains(nearest.id) ? selected : [nearest.id])
                let vel = Int((1 - min(1, max(0, v.location.y / 48))) * 126) + 1
                velocityPreview = (ids, vel)
            }
            .onEnded { _ in
                if let p = velocityPreview {
                    model.edit("Change Velocity", stem: stem.id) { NoteEditor.setVelocity(p.ids, in: $0, to: p.velocity) }
                }
                velocityPreview = nil
            })
        .help("Drag a note's bar to set its velocity (all selected notes when it is selected)")
    }
}

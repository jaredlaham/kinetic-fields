import AppKit
import StemCore
import SwiftUI

/// Catches scroll-wheel and trackpad scrolling over a view without blocking clicks.
/// `onScroll` returns true when it handled the event; unhandled events continue
/// to the views below (for example a vertical ScrollView).
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                return (self.onScroll?(e) ?? false) ? nil : e
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

enum TimeFormat {
    static func clock(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%06.3f", m, s)
    }

    static func barsBeats(_ t: Double, tempo: TempoMap) -> String {
        let beat = tempo.beat(at: t)
        let bar = Int(floor(beat / Double(tempo.beatsPerBar)))
        let inBar = beat - Double(bar * tempo.beatsPerBar)
        let b = Int(floor(inBar))
        let sixteenth = Int(floor((inBar - Double(b)) * 4))
        return "\(bar + 1).\(b + 1).\(sixteenth + 1)"
    }
}

/// Ruler plus one waveform lane per stem, with the beat grid, MIDI note overlay,
/// region selection and playhead. Scroll horizontally to move, hold Option (or
/// pinch) to zoom.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    static let laneHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            RulerView()
                .frame(height: 28)
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: 1) {
                    ForEach(model.project.stems) { stem in
                        LaneView(stem: stem)
                            .frame(height: Self.laneHeight)
                    }
                }
            }
            .background(Theme.background)
            TimeScroller()
                .frame(height: 14)
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.viewportWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in model.viewportWidth = w }
        })
        .background(ScrollWheelCatcher { e in handleScroll(e) })
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
            let factor = pow(1.01, Double(e.scrollingDeltaY))
            model.zoom(by: factor, around: model.playhead)
            return true
        }
        let dx = Double(e.scrollingDeltaX) + (e.modifierFlags.contains(.shift) ? Double(e.scrollingDeltaY) : 0)
        guard abs(dx) > 0.01 else { return false }
        model.scroll(seconds: -dx / model.pixelsPerSecond * (e.hasPreciseScrollingDeltas ? 1 : 8))
        return true
    }
}

/// Horizontal scrollbar for the shared time view.
struct TimeScroller: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { g in
            let total = max(model.duration, 0.001)
            let visible = Double(g.size.width) / model.pixelsPerSecond
            let frac = min(1, visible / total)
            let w = max(24, g.size.width * frac)
            let x = (g.size.width - w) * (total > visible ? model.viewStart / (total - visible) : 0)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.panel)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: w, height: 8)
                    .offset(x: min(max(0, x), g.size.width - w))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = Double((v.location.x - w / 2) / max(1, g.size.width - w))
                model.viewStart = max(0, min(max(0, total - visible), f * (total - visible)))
            })
        }
    }
}

struct RulerView: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: Double?

    var body: some View {
        // Values are read here, not inside the Canvas renderer, so observation redraws on change.
        let pps = model.pixelsPerSecond
        let t0 = model.viewStart
        let tempo = model.project.tempo
        let region = model.region
        let playhead = model.playhead
        Canvas { ctx, size in
            let t1 = t0 + Double(size.width) / pps
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panel))
            if let r = region {
                let x0 = (r.lowerBound - t0) * pps, x1 = (r.upperBound - t0) * pps
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(Theme.selection.opacity(0.35)))
            }
            if tempo.source != .none {
                let barPx = tempo.secondsPerBar * pps
                let labelEvery = max(1, Int(ceil(44 / max(barPx, 1))))
                for line in tempo.gridLines(from: t0, to: t1) {
                    let x = (line.time - t0) * pps
                    if line.isBar {
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 12)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(Theme.textDim), lineWidth: 1)
                        if (line.bar - 1) % labelEvery == 0 {
                            ctx.draw(Text("\(line.bar)").font(Theme.mono).foregroundColor(Theme.text),
                                     at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                        }
                    } else if tempo.secondsPerBeat * pps > 6 {
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 20)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(Theme.textDim.opacity(0.5)), lineWidth: 1)
                    }
                }
            } else {
                // No tempo yet: plain seconds.
                let step = niceStep(seconds: 80 / pps)
                var t = floor(t0 / step) * step
                while t <= t1 {
                    let x = (t - t0) * pps
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 14)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Theme.textDim), lineWidth: 1)
                    ctx.draw(Text(TimeFormat.clock(t)).font(Theme.small).foregroundColor(Theme.textDim),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                    t += step
                }
            }
            let px = (playhead - t0) * pps
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: px - 5, y: size.height - 8))
                p.addLine(to: CGPoint(x: px + 5, y: size.height - 8))
                p.addLine(to: CGPoint(x: px, y: size.height))
            }, with: .color(Theme.playhead))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = model.viewStart + Double(v.location.x) / model.pixelsPerSecond
                if dragStart == nil { dragStart = model.viewStart + Double(v.startLocation.x) / model.pixelsPerSecond }
                if abs(v.translation.width) > 3, let s = dragStart {
                    model.region = min(s, t)...max(s, t)
                }
            }
            .onEnded { v in
                if abs(v.translation.width) <= 3 {
                    model.seek(model.viewStart + Double(v.location.x) / model.pixelsPerSecond)
                }
                dragStart = nil
            })
        .help("Click to move the playhead. Drag to select a region (for looping and region export).")
    }

    private func niceStep(seconds: Double) -> Double {
        for s in [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120] where s >= seconds { return s }
        return 300
    }
}

struct LaneView: View {
    @Environment(AppModel.self) private var model
    let stem: Stem

    var body: some View {
        let color = Theme.stemColor(stem.colorIndex)
        let selected = model.selectedStemID == stem.id
        let audible = model.project.isAudible(stem)
        let job = model.jobs[stem.id]
        let pps = model.pixelsPerSecond
        let t0 = model.viewStart
        let tempo = model.project.tempo
        let region = model.region
        let playhead = model.playhead
        let peaks = model.peaks[stem.id]
        Canvas { ctx, size in
            let t1 = t0 + Double(size.width) / pps
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(selected ? Theme.laneSelected : Theme.lane))

            if tempo.source != .none && tempo.secondsPerBeat * pps > 4 {
                for line in tempo.gridLines(from: t0, to: t1) {
                    let x = (line.time - t0) * pps
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(line.isBar ? Theme.gridBar : Theme.gridBeat), lineWidth: 1)
                }
            }
            if let r = region {
                let x0 = (r.lowerBound - t0) * pps, x1 = (r.upperBound - t0) * pps
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(Theme.selection.opacity(0.12)))
            }

            // Waveform: min/max per pixel column.
            let mid = size.height / 2
            if let peaks {
                let spp = 1 / pps
                let gain = CGFloat(pow(10, stem.volumeDB / 20))
                var path = Path()
                let endX = min(Double(size.width), (peaks.duration - t0) * pps)
                var x = max(0.0, -t0 * pps)
                while x < endX {
                    let t = t0 + x / pps
                    let (lo, hi) = peaks.range(t, t + spp, secondsPerPixel: spp)
                    let y0 = mid - CGFloat(hi) * gain * (mid - 4)
                    let y1 = mid - CGFloat(lo) * gain * (mid - 4)
                    path.addRect(CGRect(x: x, y: max(2, y0), width: 1, height: max(1, min(size.height - 2, y1) - max(2, y0))))
                    x += 1
                }
                ctx.fill(path, with: .color(color.opacity(audible ? 0.55 : 0.18)))
            } else {
                ctx.draw(Text("Reading audio…").font(Theme.small).foregroundColor(Theme.textDim),
                         at: CGPoint(x: size.width / 2, y: mid))
            }

            // MIDI note overlay.
            let notes = stem.notes.filter { $0.end >= t0 && $0.start <= t1 }
            if !notes.isEmpty {
                let pitches = stem.notes.map(\.pitch)
                let lo = (pitches.min() ?? 60) - 1, hi = (pitches.max() ?? 60) + 1
                let range = CGFloat(max(hi - lo, 12))
                let h = max(2, (size.height - 8) / range)
                for n in notes {
                    let x = (n.start - t0) * pps
                    let w = max(2, n.duration * pps)
                    let y = 4 + (CGFloat(hi - n.pitch) / range) * (size.height - 8) - h / 2
                    let rejected = n.accepted == false
                    let low = n.accepted == nil && n.confidence < stem.confidenceThreshold
                    let fill: Color = rejected ? Theme.textDim.opacity(0.3) : (low ? Theme.lowConfidence : Theme.text)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 1),
                             with: .color(fill.opacity(rejected ? 0.4 : 0.55 + 0.4 * n.confidence)))
                }
            }

            let px = (playhead - t0) * pps
            ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(Theme.playhead), lineWidth: 1.5)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(stem.name).font(Theme.label).foregroundStyle(Theme.text)
                Text(stem.instrument.displayName).font(Theme.small).foregroundStyle(Theme.textDim)
                if let job, job.state == .transcribing || job.state == .queued {
                    ProgressView(value: job.fraction).frame(width: 60).controlSize(.mini)
                    Text(job.message).font(Theme.small).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                if stem.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.system(size: 10))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.background.opacity(0.75)))
            .padding(4)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: selected ? 3 : 0)
        }
        .contentShape(Rectangle())
        .gesture(LaneGesture(stemID: stem.id).gesture(model: model))
        .contextMenu {
            Button("Transcribe") { model.transcribe([stem.id]) }
            Button("Transcribe Again (ignore cache)") { model.transcribe([stem.id], force: true) }
            Button("Replace Audio…") { model.replaceAudio(stem.id) }
            Divider()
            Button("Remove Stem", role: .destructive) { model.removeStem(stem.id) }
        }
    }
}

/// Click a lane to select its stem and move the playhead; drag to select a region.
@MainActor
struct LaneGesture {
    let stemID: UUID

    func gesture(model: AppModel) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard abs(v.translation.width) > 3 else { return }
                let a = model.viewStart + Double(v.startLocation.x) / model.pixelsPerSecond
                let b = model.viewStart + Double(v.location.x) / model.pixelsPerSecond
                model.region = max(0, min(a, b))...max(a, b)
            }
            .onEnded { v in
                if model.selectedStemID != stemID {
                    model.selectedStemID = stemID
                    model.selectedNoteIDs.removeAll()
                }
                if abs(v.translation.width) <= 3 {
                    if NSEvent.modifierFlags.contains(.shift) { model.region = nil }
                    model.seek(model.viewStart + Double(v.location.x) / model.pixelsPerSecond)
                }
            }
    }
}

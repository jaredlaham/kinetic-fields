import StemCore
import SwiftUI

/// Dark, compact palette: DAW clarity with a restrained Roland-orange accent.
enum Theme {
    static let background = Color(red: 0.072, green: 0.075, blue: 0.083)
    static let panel = Color(red: 0.105, green: 0.11, blue: 0.12)
    static let panelRaised = Color(red: 0.145, green: 0.15, blue: 0.165)
    static let lane = Color(red: 0.09, green: 0.094, blue: 0.104)
    static let laneSelected = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let gridBeat = Color.white.opacity(0.05)
    static let gridBar = Color.white.opacity(0.13)
    static let text = Color(white: 0.92)
    static let textDim = Color(white: 0.56)
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.16)
    static let playhead = Color(red: 1.0, green: 0.86, blue: 0.32)
    static let selection = Color(red: 0.35, green: 0.6, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.22)
    static let ok = Color(red: 0.36, green: 0.84, blue: 0.5)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let lowConfidence = Color(red: 1.0, green: 0.74, blue: 0.22)

    static let stemColors: [Color] = [
        Color(red: 1.0, green: 0.45, blue: 0.16), Color(red: 0.36, green: 0.78, blue: 0.95),
        Color(red: 0.62, green: 0.5, blue: 1.0), Color(red: 0.45, green: 0.86, blue: 0.45),
        Color(red: 1.0, green: 0.4, blue: 0.55), Color(red: 1.0, green: 0.78, blue: 0.3),
        Color(red: 0.3, green: 0.9, blue: 0.8), Color(red: 0.85, green: 0.6, blue: 0.95),
    ]

    static func stemColor(_ index: Int) -> Color { stemColors[((index % stemColors.count) + stemColors.count) % stemColors.count] }

    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
    static let small = Font.system(size: 10)
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolbarButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? Theme.accent.opacity(0.15) : Theme.panelRaised))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension NoteEvent {
    static func name(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((pitch % 12) + 12) % 12])\(pitch / 12 - 1)"
    }
}

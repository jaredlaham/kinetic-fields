import SwiftUI
import T8Core

/// Dark, compact palette inspired by hardware grooveboxes and DAWs.
enum Theme {
    static let background = Color(red: 0.075, green: 0.078, blue: 0.086)
    static let panel = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let panelRaised = Color(red: 0.15, green: 0.155, blue: 0.17)
    static let cellOff = Color(red: 0.19, green: 0.195, blue: 0.21)
    static let cellOffBeat = Color(red: 0.235, green: 0.24, blue: 0.26)
    static let gridLine = Color.white.opacity(0.06)
    static let text = Color(white: 0.92)
    static let textDim = Color(white: 0.58)
    /// Roland-style orange accent.
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.13)
    static let playhead = Color(red: 1.0, green: 0.85, blue: 0.3)
    static let bass = Color(red: 0.33, green: 0.78, blue: 0.95)
    static let slide = Color(red: 0.62, green: 0.48, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.75, blue: 0.2)
    static let ok = Color(red: 0.35, green: 0.85, blue: 0.5)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    static func voiceColor(_ voice: DrumVoice) -> Color {
        switch voice {
        case .kick: Color(red: 1.0, green: 0.42, blue: 0.13)
        case .snare: Color(red: 1.0, green: 0.68, blue: 0.2)
        case .clap: Color(red: 0.98, green: 0.36, blue: 0.5)
        case .tom: Color(red: 0.55, green: 0.86, blue: 0.4)
        case .closedHat: Color(red: 0.36, green: 0.8, blue: 0.85)
        case .openHat: Color(red: 0.45, green: 0.6, blue: 1.0)
        }
    }

    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
    static let small = Font.system(size: 10)
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.05)))
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textDim).tracking(0.8)
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct EnergyMeter: View {
    let energy: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= energy ? Theme.accent : Theme.cellOff)
                    .frame(width: 4, height: 4 + CGFloat(level) * 2)
            }
        }
        .accessibilityLabel("Energy \(energy) of 5")
    }
}

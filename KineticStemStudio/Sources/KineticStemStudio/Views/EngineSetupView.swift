import AppKit
import StemCore
import SwiftUI

/// Shows the engine's self-check and installs its Python environment.
struct EngineSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var installer = EngineInstaller()
    @State private var log = ""
    @State private var installing = false
    @State private var high = false
    @State private var bootstrap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis Engine").font(.system(size: 16, weight: .semibold))
            Text("Transcription runs locally in a Python engine (Basic Pitch, librosa, a trained drum classifier). It is installed once into its own folder and never touches your system Python.")
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack { EngineStatusLine(); Spacer(); Button("Check Again") { model.checkEngine() } }

            if let d = model.doctor {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(d.checks) { c in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : (c.required ? "xmark.circle.fill" : "minus.circle"))
                                .foregroundStyle(c.ok ? Theme.ok : (c.required ? Theme.danger : Theme.textDim))
                            Text(c.name).frame(width: 220, alignment: .leading)
                            Text(c.detail).foregroundStyle(Theme.textDim).lineLimit(2).textSelection(.enabled)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.lane))
            }

            Divider()
            Text("Install or repair").font(.system(size: 13, weight: .semibold))
            Text("Location: \(EngineClient.defaultVenv.path)").font(Theme.small).foregroundStyle(Theme.textDim).textSelection(.enabled)
            Toggle("Also install CREPE for High Accuracy leads and vocals (PyTorch, about 1 GB)", isOn: $high)
            Toggle("If Python 3.10/3.11 is missing, install uv from astral.sh to fetch it", isOn: $bootstrap)
            HStack {
                Button(installing ? "Installing…" : "Install Engine") { install() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(installing)
                if installing {
                    ProgressView().controlSize(.small)
                    Button("Stop") { installer.cancel() }
                }
                Spacer()
                Button("Open Folder") {
                    NSWorkspace.shared.open(EngineClient.supportDirectory)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "Installer output appears here. It needs an internet connection and takes a few minutes." : log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(log.isEmpty ? Theme.textDim : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("log")
                }
                .frame(minHeight: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                .onChange(of: log) { _, _ in proxy.scrollTo("log", anchor: .bottom) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 680, height: 620)
        .background(Theme.panel)
        .font(.system(size: 12))
    }

    private func install() {
        installing = true
        log = ""
        installer.install(high: high, bootstrapUV: bootstrap, output: { text in
            log += text
            if log.count > 200_000 { log = String(log.suffix(150_000)) }
        }, finished: { ok in
            installing = false
            log += ok ? "\nInstalled.\n" : "\nThe installer stopped with an error (see above).\n"
            model.checkEngine()
        })
    }
}

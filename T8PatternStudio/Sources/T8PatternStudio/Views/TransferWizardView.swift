import AppKit
import SwiftUI
import T8Core

/// Guided transfer of patterns into the T-8's memory via the documented
/// backup/restore workflow. Copying files is never reported as success; only
/// the final verification against a fresh backup is.
struct TransferWizardView: View {
    @Environment(StudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case connect, backup, select, review, restore, verify
        var title: String {
            switch self {
            case .connect: "Connect"
            case .backup: "Back Up"
            case .select: "Choose Slots"
            case .review: "Review & Stage"
            case .restore: "Restore"
            case .verify: "Verify"
            }
        }
    }

    struct SlotChoice: Identifiable {
        var id: VariationSlot { slot }
        var slot: VariationSlot
        var include: Bool
        var rhythmFile: String
        var bassFile: String
    }

    @State private var step: Step = .connect
    @State private var backup: T8BackupSet?
    @State private var backupError: String?
    @State private var choices: [SlotChoice] = []
    @State private var acknowledged = false
    @State private var confirmOverwrite = false
    @State private var writeSwing = true
    @State private var staged: StagedTransfer?
    @State private var stageError: String?
    @State private var report: HardwareTransferManager.VerificationReport?
    @State private var showMatrix = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch step {
                    case .connect: connectStep
                    case .backup: backupStep
                    case .select: selectStep
                    case .review: reviewStep
                    case .restore: restoreStep
                    case .verify: verifyStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .sheet(isPresented: $showMatrix) { CapabilityMatrixView() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.self) { s in
                HStack(spacing: 6) {
                    Text("\(s.rawValue + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(s.rawValue <= step.rawValue ? Theme.accent : Theme.cellOff)
                        .foregroundStyle(s.rawValue <= step.rawValue ? Color.black : Theme.textDim)
                        .clipShape(Circle())
                    Text(s.title).font(.system(size: 11, weight: s == step ? .bold : .regular))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if step != .connect {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .connect }
            }
            if step != .verify {
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .verify }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(14)
    }

    private var canContinue: Bool {
        switch step {
        case .connect: true
        case .backup: backup?.roundTripVerified == true
        case .select: choices.contains(where: \.include) && duplicateTargets.isEmpty
        case .review: staged != nil
        case .restore: true
        case .verify: false
        }
    }

    // MARK: Steps

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transfer patterns into your T-8").font(.title3.bold())
            Text("The T-8 stores patterns in its own memory. This wizard prepares restore files using Roland's documented backup/restore procedure, so you can unplug the Mac and play the patterns directly on the T-8.")
            callout("USB MIDI playback (the output menu) only plays notes live. It does not store anything on the T-8. This wizard is how patterns get into memory.", color: Theme.bass)
            HStack(spacing: 6) {
                Circle().fill(store.t8Connected ? Theme.ok : Theme.warning).frame(width: 10, height: 10)
                Text(store.t8Connected ? "T-8 detected over USB MIDI." : "No T-8 detected over USB MIDI. That's fine. Backup/restore uses USB mass-storage mode.")
            }
            callout("""
            Status: the T-8 pattern file format is NOT yet verified on hardware. The format support comes from the open-source AIRA Pattern Editor. \
            Native export stays disabled until your own backup round-trips byte-for-byte, and the transfer only counts as successful after step 6 verifies a fresh backup. \
            Your original backup is always kept.
            """, color: Theme.warning)
            Button("View Hardware Compatibility Matrix") { showMatrix = true }
        }
    }

    private var backupStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Back up your T-8").font(.title3.bold())
            numbered([
                "Turn the T-8 off and connect it to your Mac with USB-C.",
                "Hold [PLAY] while turning the T-8 on. It mounts as a USB drive.",
                "Copy the BACKUP folder (it contains BASS and RHYTHM) to your Mac. Keep this copy safe.",
                "Eject the drive in Finder, then choose that copied folder below.",
            ])
            Text("These steps follow the T-8 owner's manual, “Backup and Factory Reset”. Check the manual for your firmware version if the unit behaves differently.")
                .font(Theme.small).foregroundStyle(Theme.textDim)
            Button("Choose Backup Folder…", action: chooseBackup)
            if let backupError { callout(backupError, color: Theme.danger) }
            if let backup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(backup.rhythm.count) rhythm files, \(backup.bass.count) bass files").font(.headline)
                    if backup.roundTripVerified {
                        Label("Every pattern file parsed and re-serialized byte-for-byte. Native export enabled for this backup.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.ok)
                    } else {
                        Label("This backup did not pass verification. Native export stays disabled.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                        ForEach(backup.problems, id: \.self) { Text("• \($0)").font(Theme.small) }
                        Text("Please share this backup folder (or the messages above) so the format support can be extended.").font(Theme.small)
                    }
                    if !backup.otherFiles.isEmpty {
                        Text("Other files preserved untouched: \(backup.otherFiles.joined(separator: ", "))").font(Theme.small).foregroundStyle(Theme.textDim)
                    }
                }
                .padding(10)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var selectStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose target slots").font(.title3.bold())
            callout("The mapping of backup file names to the T-8's pattern numbers is unverified. The slot number shown is read from digits in the file name. Check the preview of what is in each file now, and confirm on the T-8 after restoring.", color: Theme.warning)
            if let backup {
                ForEach($choices) { $choice in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $choice.include) {
                            Text("Variation \(choice.slot.letter) — \(choice.slot.title)").font(.headline)
                        }
                        if choice.include {
                            MiniPatternView(pattern: store.variations[choice.slot]).frame(height: 36)
                            HStack {
                                Picker("Rhythm file", selection: $choice.rhythmFile) {
                                    ForEach(backup.rhythm) { Text(label($0)).tag($0.fileName) }
                                }
                                Picker("Bass file", selection: $choice.bassFile) {
                                    ForEach(backup.bass) { Text(label($0)).tag($0.fileName) }
                                }
                            }
                            if let current = try? backup.pattern(rhythmFile: choice.rhythmFile, bassFile: choice.bassFile, name: "Current", mapping: store.bassMapping) {
                                Text("Currently in these files (will be overwritten):").font(Theme.small).foregroundStyle(Theme.textDim)
                                MiniPatternView(pattern: current).frame(height: 30).opacity(0.7)
                            }
                        }
                    }
                    .padding(10)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !duplicateTargets.isEmpty {
                    callout("Each file can only receive one variation: \(duplicateTargets.joined(separator: ", "))", color: Theme.danger)
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.title3.bold())
            ForEach(choices.filter(\.include)) { choice in
                let issues = ValidationEngine.validateForHardware(store.variations[choice.slot])
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(choice.slot.letter): \(store.variations[choice.slot].name) → RHYTHM/\(choice.rhythmFile) + BASS/\(choice.bassFile)").font(.headline)
                    ForEach(issues, id: \.self) { issue in
                        Text("• \(issue.description)").font(Theme.small)
                            .foregroundStyle(issue.severity == .error ? Theme.danger : (issue.severity == .warning ? Theme.warning : Theme.textDim))
                    }
                }
            }
            Toggle("Write swing to the T-8 SHUFFLE setting (conversion unverified)", isOn: $writeSwing)
            Toggle("I understand the T-8 pattern format is not yet verified on hardware and I have kept my original backup.", isOn: $acknowledged)
            Toggle("Overwrite the selected files: \(choices.filter(\.include).map { "\($0.rhythmFile)/\($0.bassFile)" }.joined(separator: ", "))", isOn: $confirmOverwrite)
            Button("Stage Restore Files…", action: stage)
                .disabled(!acknowledged || !confirmOverwrite)
            if let stageError { callout(stageError, color: Theme.danger) }
            if let staged {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Restore files staged. Nothing has been sent to the T-8 yet.", systemImage: "tray.full.fill").foregroundStyle(Theme.ok)
                    Text("Changed files: \(staged.manifest.entries.filter(\.modified).map(\.path).joined(separator: ", "))").font(Theme.small)
                    Text("Untouched original backup: \(staged.originalBackupDirectory.path)").font(Theme.small)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([staged.restoreDirectory]) }
                }
                .padding(10)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var restoreStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore on the T-8").font(.title3.bold())
            numbered([
                "Connect the T-8 and enter backup/restore mode as described in the owner's manual. It mounts as a USB drive.",
                "Open the staged RESTORE folder (Reveal in Finder) and copy its BASS and RHYTHM folders into the T-8 drive's RESTORE folder.",
                "Eject the T-8 drive in Finder.",
                "Press [ACCENT] on the T-8. Wait until the display shows “dOnE”.",
                "Restart the T-8 and play the pattern(s). Disconnect the Mac and check that they loop correctly.",
            ])
            if let staged {
                Button("Reveal Staged RESTORE Folder") { NSWorkspace.shared.activateFileViewerSelecting([staged.restoreDirectory]) }
            }
            callout("If anything sounds wrong, restore the ORIGINAL-BACKUP folder the same way. It is an untouched copy of your backup.", color: Theme.bass)
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify").font(.title3.bold())
            Text("Make a fresh backup of the T-8 (hold [PLAY] at power-on, copy the BACKUP folder), then choose it here. The app checks that the targeted slots hold exactly what was staged and that no other pattern changed.")
            Button("Choose Post-Restore Backup…", action: verify).disabled(staged == nil || backup == nil)
            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.slots, id: \.patternName) { slot in
                        Label("\(slot.patternName): rhythm \(slot.rhythmMatches ? "matches" : "DIFFERS"), bass \(slot.bassMatches ? "matches" : "DIFFERS")",
                              systemImage: slot.rhythmMatches && slot.bassMatches ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(slot.rhythmMatches && slot.bassMatches ? Theme.ok : Theme.danger)
                        ForEach(slot.details, id: \.self) { Text("   \($0)").font(Theme.small) }
                    }
                    ForEach(report.unexpectedChanges, id: \.self) { Text("Unexpected change: \($0)").foregroundStyle(Theme.danger) }
                    ForEach(report.missingFiles, id: \.self) { Text("Missing: \($0)").foregroundStyle(Theme.danger) }
                    if report.passed {
                        Label("Verified: the T-8 now holds exactly the staged patterns. Play them on the unit to confirm they sound right.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.ok).font(.headline)
                    } else {
                        Text("Not verified. Restore your ORIGINAL-BACKUP if needed, and please share both backups so the format support can be corrected.")
                            .foregroundStyle(Theme.warning)
                    }
                }
                .padding(10)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Actions

    private func chooseBackup() {
        guard let url = chooseFolder(prompt: "Use Backup") else { return }
        do {
            let loaded = try T8BackupSet.load(from: url)
            backup = loaded
            backupError = nil
            staged = nil
            report = nil
            choices = VariationSlot.allCases.enumerated().map { index, slot in
                let rhythm = loaded.rhythm.indices.contains(index) ? loaded.rhythm[index].fileName : loaded.rhythm.first?.fileName ?? ""
                let bassMatch = loaded.bass.first { $0.inferredSlot != nil && $0.inferredSlot == loaded.file(part: .rhythm, named: rhythm)?.inferredSlot }
                let bass = bassMatch?.fileName ?? (loaded.bass.indices.contains(index) ? loaded.bass[index].fileName : loaded.bass.first?.fileName ?? "")
                return SlotChoice(slot: slot, include: slot == store.activeSlot, rhythmFile: rhythm, bassFile: bass)
            }
        } catch {
            backup = nil
            backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func stage() {
        guard let backup else { return }
        let defaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("T-8 Pattern Studio/Transfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        var options = TransferOptions()
        options.acknowledgedUnverifiedFormat = acknowledged
        options.confirmedOverwrite = confirmOverwrite
        options.writeSwing = writeSwing
        options.bassMapping = store.bassMapping
        let assignments = choices.filter(\.include).map {
            TransferAssignment(pattern: store.variations[$0.slot], rhythmFile: $0.rhythmFile, bassFile: $0.bassFile)
        }
        do {
            staged = try HardwareTransferManager.stage(backup: backup, assignments: assignments, options: options, outputDirectory: defaultDir)
            stageError = nil
        } catch {
            stageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func verify() {
        guard let staged, let backup, let url = chooseFolder(prompt: "Verify") else { return }
        do {
            let after = try T8BackupSet.load(from: url)
            let result = HardwareTransferManager.verify(postRestore: after, manifest: staged.manifest, original: backup)
            report = result
            if result.passed { store.markHardwareVerified() }
        } catch {
            store.show(error)
        }
    }

    // MARK: Helpers

    private var duplicateTargets: [String] {
        let included = choices.filter(\.include)
        let rhythm = Dictionary(grouping: included, by: \.rhythmFile).filter { $0.value.count > 1 }.keys
        let bass = Dictionary(grouping: included, by: \.bassFile).filter { $0.value.count > 1 }.keys
        return rhythm.map { "RHYTHM/\($0)" } + bass.map { "BASS/\($0)" }
    }

    private func label(_ file: T8BackupFile) -> String {
        file.fileName + (file.inferredSlot.map { " (slot \($0)?)" } ?? "")
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = prompt
        panel.message = "Choose the BACKUP folder (containing BASS and RHYTHM)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func callout(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func numbered(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(item).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

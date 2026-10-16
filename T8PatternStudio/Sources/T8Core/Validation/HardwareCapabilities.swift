import Foundation

/// How well a capability is established. Ordered from strongest to weakest evidence.
public enum EvidenceLevel: String, Codable, CaseIterable, Sendable {
    /// Stated in Roland's official documentation (owner's manual / MIDI implementation chart).
    case officiallyDocumented
    /// Implemented in the open-source AIRA Pattern Editor source code (natebosch/aira_pattern_editor).
    case openSourceVerified
    /// Confirmed on a physical T-8 by a documented test (none yet — see README).
    case hardwareVerified
    /// Inferred or assumed; must be confirmed before relying on it.
    case unverified
    /// Not supported by the T-8 (or by this application).
    case unsupported

    public var label: String {
        switch self {
        case .officiallyDocumented: "Officially documented"
        case .openSourceVerified: "Verified in open-source code"
        case .hardwareVerified: "Verified on hardware"
        case .unverified: "Unverified"
        case .unsupported: "Unsupported"
        }
    }
}

public struct CapabilityEntry: Sendable, Identifiable {
    public var id: String
    public var feature: String
    public var level: EvidenceLevel
    public var source: String
    public var notes: String
}

/// Hardware capability layer: separates what the T-8 can store from what is
/// application-only, and records the evidence behind each claim.
public enum HardwareCapabilities {
    /// T-8 bass note range per MIDI implementation chart (receive 12–96).
    public static let bassNoteRange = 12...96
    public static let userPatternCount = 64
    public static let maxSteps = 32
    public static let rhythmChannelDefault = 10
    public static let bassChannelDefault = 2

    /// MIDI note numbers the T-8 rhythm part *transmits* (and receives) per the
    /// MIDI implementation chart. Note the 808 heritage: clap uses note 50
    /// (Hi Tom in GM) and tom uses 47.
    public static let rhythmNoteMap: [DrumVoice: UInt8] = [
        .kick: 36, .snare: 38, .clap: 50, .tom: 47, .closedHat: 42, .openHat: 46,
    ]
    /// Additional notes the T-8 accepts on receive.
    public static let rhythmAlternateReceiveNotes: [UInt8: DrumVoice] = [
        35: .kick, 40: .snare, 48: .clap, 45: .tom, 44: .closedHat,
    ]

    public static let matrix: [CapabilityEntry] = [
        CapabilityEntry(id: "patterns", feature: "64 user patterns, up to 32 steps", level: .officiallyDocumented,
                        source: "Roland T-8 product specifications", notes: "Rhythm (6 instruments) + bass part per pattern."),
        CapabilityEntry(id: "voices", feature: "Drum voices: BD, SD, HC, Tom, CH, OH", level: .officiallyDocumented,
                        source: "Roland T-8 specifications", notes: ""),
        CapabilityEntry(id: "midi-channels", feature: "MIDI channels: bass 2, rhythm 10 (defaults)", level: .officiallyDocumented,
                        source: "T-8 MIDI Implementation Chart (v1.02)", notes: "Configurable on the unit."),
        CapabilityEntry(id: "midi-notes", feature: "Rhythm notes 36/38/50/47/42/46", level: .officiallyDocumented,
                        source: "T-8 MIDI Implementation Chart (v1.02)", notes: "Receive also accepts 35/40/48/45/44."),
        CapabilityEntry(id: "bass-range", feature: "Bass note range 12–96", level: .officiallyDocumented,
                        source: "T-8 MIDI Implementation Chart (v1.02)", notes: ""),
        CapabilityEntry(id: "backup-procedure", feature: "Backup/restore via USB mass storage (BACKUP / RESTORE folders with BASS and RHYTHM subfolders)", level: .officiallyDocumented,
                        source: "T-8 Owner's Manual, \"Backup and Factory Reset\"", notes: "Backup: power on holding [PLAY]. Restore: copy into RESTORE, eject, press [ACCENT], unit shows \"dOnE\"."),
        CapabilityEntry(id: "prm-text", feature: "Pattern files are line-based text (.prm)", level: .openSourceVerified,
                        source: "aira_pattern_editor", notes: "Not yet confirmed against a backup from your unit."),
        CapabilityEntry(id: "rhythm-step-code", feature: "Rhythm step code: on, velocity 0–A, sub-step 0–4, probability 0–A, sub-step probability 0–A", level: .openSourceVerified,
                        source: "aira_pattern_editor lib/t8_rhythm/models", notes: "Instrument codes AC BD SD LT HT CY CH OH. HT = clap and LT = tom (consistent with MIDI notes 50/47)."),
        CapabilityEntry(id: "rhythm-header", feature: "Rhythm header: LENGTH, SCALE, SHUFFLE (×10, −900…900), FLAM", level: .openSourceVerified,
                        source: "aira_pattern_editor", notes: "SCALE and FLAM meanings unknown; preserved untouched."),
        CapabilityEntry(id: "bass-step-code", feature: "Bass step: STATE (0 off / 1 note / 2 tie), NOTE, ACCENT, SLIDE", level: .openSourceVerified,
                        source: "aira_pattern_editor lib/t8_bass/models", notes: "Header: LENGTH, TRIPLET."),
        CapabilityEntry(id: "bass-note-offset", feature: "Bass NOTE value = MIDI note − 12", level: .unverified,
                        source: "Inference: editor names NOTE 0 as C0 and 0…84 matches the 12…96 MIDI range", notes: "Confirm with a backup of a known bass note before transfer."),
        CapabilityEntry(id: "slot-files", feature: "Mapping of backup file names to pattern slots", level: .unverified,
                        source: "—", notes: "Needs a real T-8 backup. The app infers the slot from digits in the file name and asks you to confirm."),
        CapabilityEntry(id: "shuffle-scale", feature: "App swing ↔ T-8 SHUFFLE conversion", level: .unverified,
                        source: "—", notes: "App maps 0–100 swing to SHUFFLE 0–900 linearly."),
        CapabilityEntry(id: "midi-slide", feature: "Bass slide over MIDI via overlapping (legato) notes", level: .unverified,
                        source: "TB-303-style convention", notes: "Not documented for the T-8."),
        CapabilityEntry(id: "midi-accent", feature: "Bass accent over MIDI via high velocity", level: .unverified,
                        source: "TB-303-style convention", notes: "App sends 127 for accent, 90 otherwise."),
        CapabilityEntry(id: "sysex-write", feature: "Direct pattern write over USB MIDI / SysEx", level: .unsupported,
                        source: "No documentation found", notes: "Transfer uses the documented backup/restore workflow instead."),
        CapabilityEntry(id: "variations", feature: "A/B/C/D variations as a native structure", level: .unsupported,
                        source: "—", notes: "App concept; each variation can be exported to its own hardware slot."),
        CapabilityEntry(id: "transfer", feature: "End-to-end transfer to T-8 memory", level: .unverified,
                        source: "—", notes: "Disabled until your backup round-trips byte-for-byte and you complete the verification step."),
    ]

    /// Features of the internal model that the T-8 cannot store.
    public enum AppOnlyFeature: String, CaseIterable, Sendable {
        case bpmPerPattern = "Pattern BPM (no tempo field appears in the .prm pattern files read by the open-source editor)"
        case key = "Key and scale (metadata only)"
        case variations = "A/B/C/D grouping"
        case swingResolution = "Swing amounts finer than the T-8 SHUFFLE resolution"
    }
}

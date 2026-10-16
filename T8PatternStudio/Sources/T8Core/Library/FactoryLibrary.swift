import Foundation

/// The bundled, read-only factory library: 15 genres × 4 starting patterns.
///
/// Every preset is authored as actual step data in `PatternNotation`; the B/C/D
/// variations are derived deterministically from A by `PatternVariationEngine`.
/// All patterns are original and written from general genre characteristics.
///
/// Library version is bumped whenever factory content changes so the app can
/// tell users what changed. Factory IDs are stable and must never be reused.
public enum FactoryLibrary {
    public static let version = 1

    /// Fixed timestamp for factory content so presets compare equal across launches.
    static let factoryDate = Date(timeIntervalSince1970: 1_790_000_000)

    public static let presets: [Preset] = {
        definitions.map { definition in
            do {
                return try definition.makePreset()
            } catch {
                fatalError("Factory preset \(definition.id) is malformed: \(error)")
            }
        }
    }()

    public static func preset(id: PresetID) -> Preset? {
        presets.first { $0.id == id }
    }

    public static func presets(for genre: Genre) -> [Preset] {
        presets.filter { $0.primaryGenre == genre }
    }

    // MARK: - Definition

    struct Definition {
        var id: String
        var name: String
        var genre: Genre
        var bpm: Double
        var swing: Int = 0
        var length: Int = 16
        var key: PitchClass
        var scale: Scale
        var energy: Int
        var summary: String
        var tags: [String] = []
        var kick = ""
        var snare = ""
        var clap = ""
        var tom = ""
        var ch = ""
        var oh = ""
        var accents = ""
        var bass = ""

        func makePreset() throws -> Preset {
            var drums: [DrumVoice: String] = [:]
            if !kick.isEmpty { drums[.kick] = kick }
            if !snare.isEmpty { drums[.snare] = snare }
            if !clap.isEmpty { drums[.clap] = clap }
            if !tom.isEmpty { drums[.tom] = tom }
            if !ch.isEmpty { drums[.closedHat] = ch }
            if !oh.isEmpty { drums[.openHat] = oh }
            var base = try PatternNotation.pattern(
                name: name, bpm: bpm, swing: swing, length: length, key: key, scale: scale,
                drums: drums, accents: accents, bass: bass
            )
            // The open hat wins where both hats are written (closed/open choke each other).
            for step in 0..<length where base.drums[.openHat, step] != nil {
                base.drums[.closedHat, step] = nil
            }
            let variations = PatternVariationEngine.makeVariations(from: base, genre: genre, seed: UInt64(truncatingIfNeeded: id.hashValueStable))
            return Preset(
                id: PresetID("factory.\(genre.rawValue).\(id)"),
                name: name,
                origin: .factory,
                genres: [genre],
                tags: tags,
                summary: summary,
                energy: energy,
                variations: variations,
                createdAt: FactoryLibrary.factoryDate,
                modifiedAt: FactoryLibrary.factoryDate
            )
        }
    }

    // MARK: - Content
    // Drum lanes: one character per 16th step, spaces are visual only.
    // x = hit, X = loud, o = soft, g = ghost, f = flam, 2/3/4 = ratchet, ? = 50% chance.

    static let definitions: [Definition] = [
        // MARK: House
        Definition(
            id: "classic-four", name: "Classic Four", genre: .house, bpm: 124, swing: 10, key: .a, scale: .minor, energy: 3,
            summary: "Traditional four-on-the-floor groove with offbeat open hats and a bouncing octave bass.",
            tags: ["four-on-the-floor", "classic"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "xo.o xo.o xo.o xo.o",
            oh: "..x. ..x. ..x. ..x.",
            accents: "a... a... a... a...",
            bass: ". . A1 . . . A1 . . . A1 . . A2 G1 ."
        ),
        Definition(
            id: "piano-jack", name: "Piano Jack", genre: .house, bpm: 125, swing: 15, key: .g, scale: .minor, energy: 4,
            summary: "Punchy jacking drums with ghost snares and a syncopated, pushing bassline.",
            tags: ["jack", "syncopated"],
            kick: "x... x... x... x...",
            snare: ".... ...g .... ..o.",
            clap: ".... x... .... x...",
            ch: "x.x. x.xx x.x. x.xx",
            oh: ".... .... .... ....",
            accents: "a... a... a... a.a.",
            bass: "G1 . . G1 . . A#1 . . G1 . . D2! . C2 ."
        ),
        Definition(
            id: "warehouse-groove", name: "Warehouse Groove", genre: .house, bpm: 126, swing: 5, key: .f, scale: .minor, energy: 4,
            summary: "Raw underground house: dry kick, rimshot-style snare and a stabbing low bass.",
            tags: ["raw", "underground"],
            kick: "x... x... x... x..x",
            snare: ".... x... .... x...",
            tom: ".... .... ..o. ....",
            ch: "..x. ..x. ..x. ..xx",
            oh: ".... ...x .... ...x",
            accents: "a... a... a... a...",
            bass: "F1! . F1 . . F1 . . F1! . G#1 . . F1 . ."
        ),
        Definition(
            id: "late-night-floor", name: "Late Night Floor", genre: .house, bpm: 123, swing: 30, key: .d, scale: .dorian, energy: 3,
            summary: "Warm swung house with shuffled hats and a melodic dorian walking bass.",
            tags: ["swing", "warm"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "xoxo xoxo xoxo xoxo",
            oh: ".... .... .... ..x.",
            accents: "a... a... a... a...",
            bass: ". . D2 . . . F2 . . . D2 . A1 . B1~ C2"
        ),

        // MARK: Deep House
        Definition(
            id: "velvet-motion", name: "Velvet Motion", genre: .deepHouse, bpm: 120, swing: 20, key: .e, scale: .minor, energy: 2,
            summary: "Warm, restrained groove with soft rim ghosts and a round, sustained bass.",
            tags: ["warm", "restrained"],
            kick: "x... x... x... x...",
            snare: ".... .... ...g ....",
            clap: ".... o... .... o...",
            ch: "..x. ..x. ..x. ..xo",
            oh: ".... .... .... ....",
            bass: ". . E1 - . . E1 - . . G1 - . A1 - ."
        ),
        Definition(
            id: "midnight-current", name: "Midnight Current", genre: .deepHouse, bpm: 118, swing: 15, key: .c, scale: .minor, energy: 2,
            summary: "Deep hypnotic bass loop under a soft shaker-like hat line.",
            tags: ["hypnotic", "deep"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "gogo gogo gogo gogo",
            oh: "..o. ..o. ..o. ..o.",
            bass: "C1 . . C1 - . D#1 . . C1 . . G1~ F1 . ."
        ),
        Definition(
            id: "afterhours", name: "Afterhours", genre: .deepHouse, bpm: 122, swing: 35, key: .f, scale: .dorian, energy: 3,
            summary: "Shuffled hats, offbeat accents and a slinky dorian bass for the late session.",
            tags: ["shuffle", "afterhours"],
            kick: "x... x... x... x...",
            snare: ".... .... .... ...g",
            clap: ".... x... .... x...",
            ch: "x.xo x.xo x.xo x.xo",
            oh: "..x. .... ..x. ....",
            accents: "..a. ..a. ..a. ..a.",
            bass: ". F1 . . G#1 . F1 . . . D#1 . . F1 . C2"
        ),
        Definition(
            id: "submerged", name: "Submerged", genre: .deepHouse, bpm: 116, swing: 10, key: .a, scale: .phrygian, energy: 2,
            summary: "Dark, spacious deep house with a lot of air between the hits.",
            tags: ["dark", "spacious"],
            kick: "x... x... x... x...",
            clap: ".... o... .... o...",
            tom: ".... .... .... .o..",
            ch: "..o. ..o. ..o. ..o.",
            bass: "A0 - - . . . A0 . . . A#0 - . . . ."
        ),

        // MARK: Progressive House
        Definition(
            id: "ascending", name: "Ascending", genre: .progressiveHouse, bpm: 126, length: 32, key: .b, scale: .minor, energy: 3,
            summary: "Two-bar build with evolving hat density and a rising rolling bass.",
            tags: ["build", "rolling"],
            kick: "x... x... x... x... x... x... x... x...",
            clap: ".... x... .... x... .... x... .... x...",
            ch: "..x. ..x. ..x. ..x. ..x. ..x. .xx. .xxx",
            oh: ".... .... .... .... .... .... .... ..x.",
            accents: "a... .... a... .... a... .... a... a...",
            bass: ". B1 B1 B1 . B1 B1 B1 . B1 B1 B1 . D2 D2 D2 . B1 B1 B1 . B1 B1 B1 . E2 E2 E2 . F#2 F#2 F#2"
        ),
        Definition(
            id: "long-horizon", name: "Long Horizon", genre: .progressiveHouse, bpm: 124, length: 32, key: .d, scale: .minor, energy: 2,
            summary: "Spacious two-bar progression with long tied bass notes.",
            tags: ["spacious", "melodic"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "..x. ..x. ..x. ..x.",
            oh: ".... .... .... .... .... .... .... ..o.",
            bass: ". . D2 - - . . . . . D2 - . . C2 . . . A#1 - - . . . . . A#1 - . . C2 ."
        ),
        Definition(
            id: "momentum", name: "Momentum", genre: .progressiveHouse, bpm: 128, key: .f, scale: .minor, energy: 4,
            summary: "Driving offbeat bass and tight percussion that keeps pushing forward.",
            tags: ["driving"],
            kick: "x... x... x... x...",
            snare: ".... .... .... ..g.",
            clap: ".... x... .... x...",
            ch: "xxox xxox xxox xxox",
            oh: "..x. ..x. ..x. ..x.",
            accents: "..a. ..a. ..a. ..a.",
            bass: ". F1 F2 . . F1 F2 . . F1 F2 . . G#1 G#2 ."
        ),
        Definition(
            id: "afterglow", name: "Afterglow", genre: .progressiveHouse, bpm: 125, swing: 10, key: .g, scale: .major, energy: 3,
            summary: "Melodic, atmospheric groove with a major-key arpeggiated bass.",
            tags: ["melodic", "uplifting"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "..o. ..o. ..o. ..oo",
            oh: "..x. ..x. ..x. ..x.",
            bass: "G1 . D2 . G2 . D2 . E1 . B1 . E2 . B1 ."
        ),

        // MARK: Tech House
        Definition(
            id: "pressure-system", name: "Pressure System", genre: .techHouse, bpm: 128, swing: 10, key: .g, scale: .minor, energy: 4,
            summary: "Punchy kick with short accented bass stabs between the beats.",
            tags: ["stabs", "punchy"],
            kick: "X... X... X... X...",
            clap: ".... x... .... x...",
            ch: "x.xx x.xx x.xx x.xx",
            oh: "..x. ..x. ..x. ..x.",
            accents: "a.a. a.a. a.a. a.a.",
            bass: ". . G1! . . G1 . G1! . . G1! . . A#1 . G1"
        ),
        Definition(
            id: "concrete-groove", name: "Concrete Groove", genre: .techHouse, bpm: 126, swing: 15, key: .a, scale: .minor, energy: 3,
            summary: "Tight, minimal percussion with tom accents and a rubbery bass.",
            tags: ["minimal", "tight"],
            kick: "x... x... x... x...",
            snare: ".... .... .g.. ....",
            clap: ".... x... .... x...",
            tom: "...o .... .... .o..",
            ch: "..x. ..x. ..x. ..x.",
            bass: "A1 . . A1 . . . A1 . A1 . . C2 . A1 ."
        ),
        Definition(
            id: "switchback", name: "Switchback", genre: .techHouse, bpm: 127, swing: 20, key: .c, scale: .minor, energy: 4,
            summary: "Syncopated bass answering skipping 16th hats.",
            tags: ["syncopated"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "xoxx xoxx xoxx xox.",
            oh: ".... .... .... ...x",
            accents: "...a ...a ...a ...a",
            bass: ". . . C2 . . C1 . . C2 . . D#2 . C1 ."
        ),
        Definition(
            id: "warehouse-tool", name: "Warehouse Tool", genre: .techHouse, bpm: 129, key: .e, scale: .phrygian, energy: 4,
            summary: "Hypnotic club tool with a repeating phrygian bass riff.",
            tags: ["hypnotic", "tool"],
            kick: "x... x... x... x...",
            snare: ".... .... .... ...g",
            clap: ".... x... .... x...",
            ch: "x.x. x.x. x.x. x.x.",
            oh: "..x. ..x. ..x. ..x.",
            bass: "E1 E1 . F1 . E1 . . E1 E1 . G1 . F1 . E1"
        ),

        // MARK: Breakbeat
        Definition(
            id: "broken-circuit", name: "Broken Circuit", genre: .breakbeat, bpm: 132, key: .e, scale: .minor, energy: 4,
            summary: "Broken kicks against sharp backbeat snares with a jagged bass.",
            tags: ["broken"],
            kick: "x... ..x. ..x. .x..",
            snare: ".... X... .... X..o",
            ch: "x.x. x.x. x.x. x.x.",
            oh: ".... ...x .... ....",
            accents: ".... a... .... a...",
            bass: "E1 . . . . . E1 . . G1 . . . . D2 ."
        ),
        Definition(
            id: "voltage-break", name: "Voltage Break", genre: .breakbeat, bpm: 128, key: .d, scale: .phrygian, energy: 5,
            summary: "Aggressive electronic break with ratcheted snares and distorted bass hits.",
            tags: ["aggressive", "electronic"],
            kick: "X... ..X. .X.. ....",
            snare: ".... X... .... X.2.",
            clap: ".... x... .... ....",
            ch: "xxxx xxxx xxxx xxxx",
            accents: "a... a.a. .a.. a...",
            bass: "D1! . . D1 . . D#1! . . D1 . . . . D2! ."
        ),
        Definition(
            id: "back-alley", name: "Back Alley", genre: .breakbeat, bpm: 118, swing: 40, key: .g, scale: .dorian, energy: 3,
            summary: "Funky swung breaks with ghost snares and a strutting bass.",
            tags: ["funky", "swing"],
            kick: "x.x. .... ..x. ....",
            snare: ".... x..g .g.. x..g",
            ch: "x.x. x.x. x.x. x.xx",
            oh: ".... .... .... ..x.",
            bass: "G1 . G1 . . . A#1 . C2 . . . D2 . C2 A#1"
        ),
        Definition(
            id: "rupture", name: "Rupture", genre: .breakbeat, bpm: 135, key: .a, scale: .minor, energy: 5,
            summary: "Fast, high-energy breakbeat with tom rolls and a racing bass.",
            tags: ["fast", "high-energy"],
            kick: "x..x ..x. .x.x ....",
            snare: ".... x... .... x.xx",
            tom: ".... .... ..o. ....",
            ch: "x.xx x.xx x.xx x.xx",
            oh: "..x. .... .... ....",
            accents: "a... a... .... a...",
            bass: "A1 A1 . A1 . . C2 . A1 . E2 . . G1 A1 ."
        ),

        // MARK: Lo-Fi Hip-Hop
        Definition(
            id: "dusty-tape", name: "Dusty Tape", genre: .lofiHipHop, bpm: 78, swing: 55, key: .f, scale: .minor, energy: 2,
            summary: "Relaxed boom-bap with heavy swing and a lazy minor bass.",
            tags: ["boom-bap", "swing"],
            kick: "x... ...x ..x. ....",
            snare: ".... x... .... x...",
            ch: "x.x. x.x. x.x. x.xo",
            bass: "F1 - - . . . G#1 . . . D#1 - - . C1 ."
        ),
        Definition(
            id: "rainy-window", name: "Rainy Window", genre: .lofiHipHop, bpm: 72, swing: 45, key: .a, scale: .minor, energy: 1,
            summary: "Sparse, mellow groove with soft hats and long bass notes.",
            tags: ["sparse", "mellow"],
            kick: "x... .... ..x. ....",
            snare: ".... o... .... o...",
            ch: "o.o. o.o. o.o. o.o.",
            bass: "A1 - - - . . . . F1 - - - . . E1 ."
        ),
        Definition(
            id: "cassette-drift", name: "Cassette Drift", genre: .lofiHipHop, bpm: 82, swing: 60, key: .d, scale: .dorian, energy: 2,
            summary: "Loose, dusty rhythm with off-grid feel from swing and probability hats.",
            tags: ["loose", "dusty"],
            kick: "x..x .... ..x. ..x.",
            snare: ".... x... .... x...",
            clap: ".... .... .... x...",
            ch: "x?x? x?x? x?x? x?x?",
            oh: ".... .... ...o ....",
            bass: "D1 . . D1 . . F1 . . . A1 . . G1 . ."
        ),
        Definition(
            id: "night-study", name: "Night Study", genre: .lofiHipHop, bpm: 85, swing: 50, key: .c, scale: .minorPentatonic, energy: 2,
            summary: "Restrained hip-hop beat with a rim-like snare and pentatonic bass.",
            tags: ["restrained", "study"],
            kick: "x... ..x. .x.. ....",
            snare: ".... x... .... x..g",
            ch: "x.x. x.x. x.x. x.x.",
            bass: "C1 - . . . . D#1 . . F1 . . G1 - . ."
        ),

        // MARK: Trip-Hop
        Definition(
            id: "black-water", name: "Black Water", genre: .tripHop, bpm: 88, swing: 25, key: .e, scale: .phrygian, energy: 2,
            summary: "Heavy, dark half-time groove with a looming phrygian bass.",
            tags: ["half-time", "dark"],
            kick: "X... .... ..x. ....",
            snare: ".... .... X... ....",
            ch: "x.x. x.x. x.x. x.x.",
            oh: ".... .... .... ..o.",
            bass: "E1 - - - . . . . F1 - - . E1 - . ."
        ),
        Definition(
            id: "smoke-signals", name: "Smoke Signals", genre: .tripHop, bpm: 82, swing: 30, key: .c, scale: .harmonicMinor, energy: 2,
            summary: "Ominous drums with tom pulses and a harmonic-minor bass figure.",
            tags: ["ominous"],
            kick: "x... ...x .... ....",
            snare: ".... .... x... ....",
            tom: ".... .... .... .o.o",
            ch: "..x. ..x. ..x. ..x.",
            bass: "C1 - . . . . G#1 - . . B0 - . . . ."
        ),
        Definition(
            id: "low-orbit", name: "Low Orbit", genre: .tripHop, bpm: 92, swing: 20, length: 32, key: .g, scale: .minor, energy: 3,
            summary: "Cinematic broken rhythm over two bars with a drifting bass.",
            tags: ["cinematic", "broken"],
            kick: "x... ..x. .... .... x... .... ..x. .x..",
            snare: ".... .... x... .... .... .... x... ..o.",
            ch: "x.x. x.x. x.x. x.x.",
            oh: ".... .... .... ..x. .... .... .... ....",
            bass: "G1 - - . . . A#1 . . . D2 - . . C2 . G1 - - . . . A#1 . . . F1 - - . . ."
        ),
        Definition(
            id: "undertow", name: "Undertow", genre: .tripHop, bpm: 76, swing: 15, key: .b, scale: .minor, energy: 1,
            summary: "Slow, brooding trip-hop with long silences and a heavy downbeat.",
            tags: ["slow", "brooding"],
            kick: "X... .... .... ..x.",
            snare: ".... .... X... ....",
            ch: "o... o... o... o.o.",
            bass: "B0 - - - - - . . D1 - - . C#1 - . ."
        ),

        // MARK: Ambient
        Definition(
            id: "floating-signals", name: "Floating Signals", genre: .ambient, bpm: 70, length: 32, key: .d, scale: .major, energy: 1,
            summary: "Sparse rhythmic pulses and long, tied bass tones.",
            tags: ["sparse", "pulse"],
            kick: "o... .... .... .... o... .... .... ....",
            tom: ".... .... o... .... .... .... .... ..o.",
            ch: "..o. .... ..o. .... ..o. .... ..o. ....",
            bass: "D1 - - - - - - - . . . . . . . . A0 - - - - - - - . . . . . . . ."
        ),
        Definition(
            id: "deep-space", name: "Deep Space", genre: .ambient, bpm: 60, length: 32, key: .a, scale: .minor, energy: 1,
            summary: "Minimal atmospheric rhythm: a heartbeat kick and distant hats.",
            tags: ["minimal", "atmospheric"],
            kick: "o... .... .... .... .... .... .... ....",
            ch: ".... .... .... ..g. .... .... .... ..g.",
            oh: ".... .... o... .... .... .... .... ....",
            bass: "A0 - - - - - - - - - - - . . . . E1 - - - - - - - . . . . . . . ."
        ),
        Definition(
            id: "slow-currents", name: "Slow Currents", genre: .ambient, bpm: 80, key: .e, scale: .dorian, energy: 1,
            summary: "Subtle repeating motion with soft probability hats.",
            tags: ["subtle"],
            kick: "o... .... o... ....",
            tom: ".... ..g. .... ....",
            ch: "?.?. ?.?. ?.?. ?.?.",
            bass: "E1 - - . . . F#1 - . . . . B0 - . ."
        ),
        Definition(
            id: "weightless", name: "Weightless", genre: .ambient, bpm: 65, length: 32, key: .f, scale: .major, energy: 1,
            summary: "Extremely restrained percussion; mostly space and a slow bass swell.",
            tags: ["restrained"],
            kick: "g... .... .... .... .... .... .... ....",
            ch: ".... .... g... .... .... .... g... ....",
            bass: "F1 - - - - - - - - - - - - - - . C1 - - - - - - - - - - - . . . ."
        ),

        // MARK: Techno
        Definition(
            id: "iron-pulse", name: "Iron Pulse", genre: .techno, bpm: 135, key: .f, scale: .minor, energy: 5,
            summary: "Relentless driving kick with a rolling 16th bass and clangy offbeat hats.",
            tags: ["driving", "relentless"],
            kick: "X... X... X... X...",
            clap: ".... x... .... x...",
            ch: "xxxx xxxx xxxx xxxx",
            oh: "..x. ..x. ..x. ..x.",
            accents: "a... a... a... a...",
            bass: ". F1 F1 F1 . F1 F1 F1 . F1 F1 F1 . F1 G#1 F1"
        ),
        Definition(
            id: "tunnel-vision", name: "Tunnel Vision", genre: .techno, bpm: 132, key: .a, scale: .phrygian, energy: 4,
            summary: "Dark rolling percussion with toms and a low phrygian rumble.",
            tags: ["dark", "rolling"],
            kick: "x... x... x... x...",
            tom: "..o. .o.. ..o. ...o",
            ch: "..x. ..x. ..x. ..x.",
            oh: ".... .... .... ...o",
            bass: ". A0 . A0 . A0 . A#0 . A0 . A0 . A0 . C1"
        ),
        Definition(
            id: "machine-state", name: "Machine State", genre: .techno, bpm: 138, key: .c, scale: .minor, energy: 5,
            summary: "Mechanical industrial groove with ratchets and hard accents.",
            tags: ["industrial", "mechanical"],
            kick: "X... X... X... X..x",
            snare: ".... .... .... .2..",
            clap: ".... X... .... X...",
            ch: "x.xx x.xx x.xx x.x4",
            accents: "a..a a..a a..a a...",
            bass: "C1! . C1 . . C1 . C1! . . C1 . D#1! . C1 ."
        ),
        Definition(
            id: "sublevel", name: "Sublevel", genre: .techno, bpm: 130, key: .d, scale: .minor, energy: 3,
            summary: "Minimal hypnotic techno: kick, a single hat and a two-note bass.",
            tags: ["minimal", "hypnotic"],
            kick: "x... x... x... x...",
            snare: ".... .... .... .g..",
            ch: "..x. ..x. ..x. ..x.",
            bass: ". . D1 . . . D1 . . . F1 . . . D1 ."
        ),

        // MARK: Acid Techno
        Definition(
            id: "acid-pressure", name: "Acid Pressure", genre: .acidTechno, bpm: 135, key: .a, scale: .minor, energy: 5,
            summary: "Resonant acid line with accents and slides over driving drums.",
            tags: ["acid", "303"],
            kick: "X... X... X... X...",
            clap: ".... x... .... x...",
            ch: "x.xx x.xx x.xx x.xx",
            oh: "..x. ..x. ..x. ..x.",
            bass: "A1 A1! A2~ A1 . C2! A1 A1~ G1 A1! . E2~ D2 A1 C2! A1"
        ),
        Definition(
            id: "corrosion", name: "Corrosion", genre: .acidTechno, bpm: 138, key: .e, scale: .chromatic, energy: 5,
            summary: "Chromatic, aggressive acid bass with clashing semitones.",
            tags: ["chromatic", "aggressive"],
            kick: "X... X... X... X...",
            snare: ".... .... .... ..xx",
            clap: ".... X... .... X...",
            ch: "xxxx xxxx xxxx xxxx",
            accents: "a.a. a.a. a.a. a.a.",
            bass: "E1! F1~ E1 E2! . F1 F#1! E1~ D#1 E1 . E2! F2~ E1 D#1! E1"
        ),
        Definition(
            id: "liquid-circuit", name: "Liquid Circuit", genre: .acidTechno, bpm: 132, key: .d, scale: .dorian, energy: 4,
            summary: "Rolling acid sequence that glides almost continuously.",
            tags: ["rolling", "slides"],
            kick: "x... x... x... x...",
            clap: ".... x... .... x...",
            ch: "..x. ..x. ..x. ..xx",
            oh: ".... ..x. .... ..x.",
            bass: "D1~ D2~ D1 F1~ G1 D1~ D2! C2~ D1 A1~ D1 F1~ D2! D1~ C2 D1"
        ),
        Definition(
            id: "terminal-acid", name: "Terminal Acid", genre: .acidTechno, bpm: 140, key: .g, scale: .phrygian, energy: 5,
            summary: "Intense fast acid techno with ratcheted hats and squelching accents.",
            tags: ["intense", "fast"],
            kick: "X... X... X... X...",
            clap: ".... x... .... x...",
            ch: "x.2. x.2. x.2. x.24",
            oh: "..x. ..x. ..x. ..x.",
            accents: "a... a... a... a...",
            bass: "G1! G1 G#1~ G1 G2! G1 . G1! A#1~ G1 G2! G1 G#1! G1~ F1 G1!"
        ),

        // MARK: French Electro
        Definition(
            id: "dark-voltage", name: "Dark Voltage", genre: .frenchElectro, bpm: 128, key: .d, scale: .minor, energy: 5,
            summary: "Aggressive, compressed-sounding electro with heavy claps and a gnarly octave bass.",
            tags: ["aggressive", "distorted"],
            kick: "X... X... X... X...",
            snare: ".... X... .... X...",
            clap: ".... X... .... X...",
            ch: "x.x. x.x. x.x. x.xx",
            accents: "a... a... a... a...",
            bass: "D1! D2 . D1 D1! D2 . D1 C1! C2 . C1 F1! F2 . E1"
        ),
        Definition(
            id: "chrome-cathedral", name: "Chrome Cathedral", genre: .frenchElectro, bpm: 125, length: 32, key: .b, scale: .harmonicMinor, energy: 4,
            summary: "Heavy, cinematic electro with a two-bar harmonic-minor bass progression.",
            tags: ["cinematic", "heavy"],
            kick: "X... ..X. X... ....",
            snare: ".... X... .... X...",
            clap: ".... x... .... x...",
            ch: "x.x. x.x. x.x. x.x.",
            oh: ".... .... .... .... .... .... .... ..x.",
            bass: "B0! . B1 . B0 . B1 . G1! . G2 . G1 . G2 . E1! . E2 . E1 . E2 . F#1! . F#2 . A#1! . F#2 ."
        ),
        Definition(
            id: "neon-distortion", name: "Neon Distortion", genre: .frenchElectro, bpm: 130, key: .e, scale: .minor, energy: 5,
            summary: "Driving distorted electro: pumping 16th bass and ratcheted snare pickups.",
            tags: ["pumping", "driving"],
            kick: "X... X... X... X...",
            snare: ".... x... .... x.2.",
            clap: ".... x... .... x...",
            ch: "..x. ..x. ..x. ..x.",
            oh: ".... .... .... ...x",
            accents: "..a. ..a. ..a. ..a.",
            bass: ". E1 E1 E2 . E1 E1 E2 . E1 E1 E2 . G1 A1 B1"
        ),
        Definition(
            id: "phantom-drive", name: "Phantom Drive", genre: .frenchElectro, bpm: 122, swing: 10, key: .c, scale: .phrygian, energy: 4,
            summary: "Dark synth-driven rhythm with sliding phrygian bass and filtered-sounding hats.",
            tags: ["dark", "synth"],
            kick: "x... x... x..x x...",
            clap: ".... x... .... x...",
            ch: "x.o. x.o. x.o. x.o.",
            oh: "..x. .... ..x. ....",
            bass: "C1 . C2~ C#2 . C1 . . C1 . G1~ G#1 . C1 . C#1"
        ),

        // MARK: Synthwave
        Definition(
            id: "midnight-highway", name: "Midnight Highway", genre: .synthwave, bpm: 105, key: .a, scale: .minor, energy: 4,
            summary: "Driving retro drums with gated-style snare and an 8th-note pumping bass.",
            tags: ["retro", "driving"],
            kick: "x... x... x... x...",
            snare: ".... X... .... X...",
            ch: "x.x. x.x. x.x. x.x.",
            bass: "A1 . A1 . A1 . A1 . F1 . F1 . G1 . G1 ."
        ),
        Definition(
            id: "neon-rain", name: "Neon Rain", genre: .synthwave, bpm: 95, key: .e, scale: .minor, energy: 2,
            summary: "Atmospheric retro groove with a slow octave bass and soft hats.",
            tags: ["atmospheric"],
            kick: "x... .... x... ....",
            snare: ".... x... .... x...",
            ch: "o.o. o.o. o.o. o.o.",
            oh: ".... .... .... ..o.",
            bass: "E1 . E2 . E1 . E2 . C1 . C2 . D1 . D2 ."
        ),
        Definition(
            id: "night-runner", name: "Night Runner", genre: .synthwave, bpm: 115, key: .d, scale: .minor, energy: 4,
            summary: "Energetic sequenced 16th bass with a classic backbeat.",
            tags: ["sequenced", "energetic"],
            kick: "x... ..x. x... ....",
            snare: ".... X... .... X...",
            ch: "xxxx xxxx xxxx xxxx",
            bass: "D1 D1 D2 D1 D1 D1 D2 D1 A#0 A#0 A#1 A#0 C1 C1 C2 C1"
        ),
        Definition(
            id: "after-the-signal", name: "After the Signal", genre: .synthwave, bpm: 90, length: 32, key: .f, scale: .harmonicMinor, energy: 2,
            summary: "Dark cinematic synthwave with a tom-driven half-time feel.",
            tags: ["dark", "cinematic"],
            kick: "x... .... ..x. .... x... .... .... ....",
            snare: ".... .... x... .... .... .... x... ....",
            tom: ".... .... .... .... .... .... .... o.o.",
            ch: "x.x. x.x. x.x. x.x.",
            bass: "F1 - - - . . F1 . C#1 - - - . . C#1 . A#0 - - - . . A#0 . C1 - - - . . E1 ."
        ),

        // MARK: Downtempo
        Definition(
            id: "slow-motion", name: "Slow Motion", genre: .downtempo, bpm: 90, swing: 20, key: .g, scale: .dorian, energy: 2,
            summary: "Relaxed electronic rhythm with a gentle dorian bass.",
            tags: ["relaxed"],
            kick: "x... ..x. .... ....",
            snare: ".... x... .... x...",
            ch: "x.x. x.x. x.x. x.xo",
            bass: "G1 - . . . . A#1 . C2 - . . A#1 . F1 ."
        ),
        Definition(
            id: "blue-hour", name: "Blue Hour", genre: .downtempo, bpm: 85, swing: 25, key: .c, scale: .minor, energy: 1,
            summary: "Sparse minor-key groove with lots of space.",
            tags: ["sparse", "minor"],
            kick: "x... .... ..x. ....",
            snare: ".... .... x... ....",
            ch: "..o. ..o. ..o. ..o.",
            bass: "C1 - - . . . . . G#0 - - . . . G0 ."
        ),
        Definition(
            id: "drift-pattern", name: "Drift Pattern", genre: .downtempo, bpm: 100, swing: 15, key: .a, scale: .dorian, energy: 3,
            summary: "Light electronic breaks with syncopated kick and a bouncing bass.",
            tags: ["breaks", "light"],
            kick: "x..x ..x. .... .x..",
            snare: ".... x... .... x...",
            ch: "x.xx x.x. x.xx x.x.",
            oh: ".... ...o .... ....",
            bass: "A1 . . A1 . . C2 . . . E2 . D2 . C2 ."
        ),
        Definition(
            id: "evening-static", name: "Evening Static", genre: .downtempo, bpm: 78, swing: 10, key: .f, scale: .phrygian, energy: 1,
            summary: "Slow hypnotic pulse with ghost snares and a two-note bass drone.",
            tags: ["hypnotic", "slow"],
            kick: "x... .... x... ....",
            snare: ".... ..g. .... x...",
            ch: "g.g. g.g. g.g. g.g.",
            bass: "F1 - - - F#1 - - . F1 - - - . . . ."
        ),

        // MARK: Electro Funk
        Definition(
            id: "circuit-funk", name: "Circuit Funk", genre: .electroFunk, bpm: 115, swing: 15, key: .e, scale: .dorian, energy: 4,
            summary: "Syncopated electro funk drums with a popping bass.",
            tags: ["syncopated", "funk"],
            kick: "x... ..x. ..x. ....",
            snare: ".... x... .... x...",
            clap: ".... x... .... x...",
            ch: "x.xx x.xx x.xx x.xx",
            accents: "a... ..a. ..a. ....",
            bass: "E1 . E2 . . E1 . G1 . A1 . . E1 . D2 E2"
        ),
        Definition(
            id: "robot-motion", name: "Robot Motion", genre: .electroFunk, bpm: 120, key: .a, scale: .minor, energy: 4,
            summary: "Mechanical funky bass with robotic, evenly spaced hats.",
            tags: ["robotic", "mechanical"],
            kick: "x... .... ..x. .x..",
            snare: ".... x... .... x...",
            tom: ".... .... .... ..o.",
            ch: "x.x. x.x. x.x. x.x.",
            bass: "A1 . A1 A2 . A1 . . C2 . C2 C3 . G1 A1 ."
        ),
        Definition(
            id: "electric-body", name: "Electric Body", genre: .electroFunk, bpm: 125, key: .d, scale: .dorian, energy: 5,
            summary: "Energetic electro funk with clap doubles and an active bass.",
            tags: ["energetic"],
            kick: "x..x ..x. x... ..x.",
            snare: ".... x... .... x...",
            clap: ".... x... .... x..x",
            ch: "xxxx xxxx xxxx xxxx",
            oh: ".... .... .... ..x.",
            accents: "a... a... a... a...",
            bass: "D1! . D2 D1 . F1 . G1 A1! . G1 F1 . D1 C1 D1"
        ),
        Definition(
            id: "analog-bounce", name: "Analog Bounce", genre: .electroFunk, bpm: 110, swing: 25, key: .g, scale: .minorPentatonic, energy: 3,
            summary: "Playful rhythmic bass with bouncing octaves and a loose backbeat.",
            tags: ["playful", "bouncy"],
            kick: "x... ..x. .x.. ....",
            snare: ".... x... .... x...",
            ch: "x.x. x.x. x.x. x.x.",
            oh: ".... ..o. .... ....",
            bass: "G1 G2 . G1 . A#1 . C2 . G1 G2 . D2 . F1 ."
        ),

        // MARK: UK Garage
        Definition(
            id: "two-step-motion", name: "Two Step Motion", genre: .ukGarage, bpm: 132, swing: 45, key: .f, scale: .minor, energy: 4,
            summary: "Skipping two-step groove: kick on 1 and the 'and' of 3, snare on 2 and 4.",
            tags: ["2-step", "skippy"],
            kick: "x... .... ..x. ....",
            snare: ".... x... .... x...",
            ch: "..x. ..x. ..x. ..xx",
            oh: ".... .... .... ....",
            bass: "F1 . . . . . G#1 . . F1 . . C2 . . ."
        ),
        Definition(
            id: "night-transit", name: "Night Transit", genre: .ukGarage, bpm: 130, swing: 40, key: .c, scale: .minor, energy: 3,
            summary: "Deep garage rhythm with a sub-heavy, rolling bass.",
            tags: ["deep", "rolling"],
            kick: "x... .... .x.. ....",
            snare: ".... x... .... x...",
            ch: "..x. ..xx ..x. ..x.",
            oh: ".... .... .... ..o.",
            bass: "C1 - . C1 . . . D#1 . . C1 - . . A#0 ."
        ),
        Definition(
            id: "shuffle-theory", name: "Shuffle Theory", genre: .ukGarage, bpm: 135, swing: 60, key: .g, scale: .dorian, energy: 4,
            summary: "Heavy swing and syncopation with skipping kicks and ghost snares.",
            tags: ["swing", "syncopated"],
            kick: "x... ...x ..x. ....",
            snare: ".... x..g .... x.g.",
            ch: "x.x. x.x. x.x. x.x.",
            oh: "..o. .... .... ..o.",
            bass: "G1 . . G1 . . A#1 . . . C2 . A#1 . F1 ."
        ),
        Definition(
            id: "southside-pulse", name: "Southside Pulse", genre: .ukGarage, bpm: 128, swing: 35, key: .a, scale: .phrygian, energy: 3,
            summary: "Minimal dark garage with a sparse kick and a low phrygian pulse.",
            tags: ["minimal", "dark"],
            kick: "x... .... ..x. ....",
            snare: ".... x... .... x...",
            ch: "..x. ..x. ..x. ..x.",
            bass: "A0 . . . . . A#0 . . . A0 . . . . ."
        ),
    ]
}

extension String {
    /// Deterministic (process-independent) hash used to seed factory variation generation.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

import AudioToolbox

/// Sorts plugins from any maker into the same categories Logic uses for its own plugins
/// (Imaging, Metering, Drums …), so a category chip shows every plugin of that kind, not
/// only Logic's (a user's report, 2026-10-31: wideners, sonible and iZotope missing from Imaging).
enum PluginCategories {
    /// Every category a user can choose, in Logic's words.
    static let all = ["Amps and Pedals", "Channel Strip", "Compressor", "Limiter", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging",
                      "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Utility", "Effects",
                      "Synth", "Sampler", "Drums", "Keys", "Bass", "Orchestral", "MIDI FX"]

    /// Channel strips (BL-140): R-Channel, SSL E and G Channel, SSL 4K, bx_console, Console 1 and
    /// the like. Checked before any other source, so a strip never hides under Multi Effects or EQ.
    /// Logic's Channel EQ is not a strip.
    private static let stripWords = ["channel strip", "channelstrip", "r-channel", "rchannel", "r channel",
                                     "e-channel", "g-channel", "echannel", "gchannel", "e channel", "g channel",
                                     "bx_console", "bx_ssl", "brit channel", "britchannel", "console 1", "omni channel",
                                     "ultrachannel", "vision channel", "mixhub", "ssl 4k", "4000 e", "4000 g", "9000 j",
                                     "88rs", "native channel", "british channel", "nls channel", "grand channel",
                                     "vocalstrip", "drumstrip", "guitarstrip", "vocal strip", "camel strip", "hitstrip", "fx strip"]
    @MainActor private static var stripMemo: [String: Bool] = [:]
    @MainActor static func isChannelStrip(_ name: String) -> Bool {
        if let m = stripMemo[name] { return m }
        let n = name.lowercased()
        let yes = !n.contains("channel eq") && stripWords.contains { n.contains($0) }
        stripMemo[name] = yes
        return yes
    }

    /// Words in a plugin's name, most telling first. Matched against the lowercased name.
    private static let effectWords: [(String, [String])] = [
        ("Metering", ["tonal balance", "tonalbalance", "truebalance", "true:balance", "true balance", "truelevel", "true level", "true-level", "adptr metric", "metric ab", "metricab", #"\bexpose\b"#, "loudness", #"\bpaz"#, #"\blevels\b"#, #"\breference\b"#, "meter", "loudness", "lufs", "analyzer", "analyser", "scope", "spectrum", "tuner",
                      "correlat", "insight", #"\bspan\b"#, "monitor"]),
        ("Imaging", ["midside", "mid side", #"\bsplit"#, "xsplit", "wider", "widen", "width", "imager", "imaging", "stereo", "spread", "panner", "binaural",
                     "haas", "microshift", "dimension", "spatial", "surround", "mid/side", "upmix"]),
        ("Pitch", ["pitch", "autotune", "auto-tune", "melodyne", "harmoni", "formant", "vocalsynth", "octav",
                   "transpos", "throat"]),
        ("Reverb", ["utopia", "spaces", "nightsky", "zrev", #"\brev\b"#, "lx-24", "im90", "abyss", "spaceblender", "wetter", "temperance", "crystalline", "lexicon", "valhalla", "reverb", "verb", "pro-r", "room", "hall", "plate", "chamber", "spring", "ambien", "convol", "shimmer"]),
        ("Delay", ["re-201", "space echo", "timeless", "timemachine", "crystallizer", "delay", "echo", "dly"]),
        ("Dynamics", [#"\bc[1-6]\b"#, #"\bl[1-4]\b"#, #"(^|[^0-9])76\b"#, "dbx", "opto", #"\bvsc"#, "dyna-mu", "kotelnikov", #"clip(per)?\b"#, #"\bott\b"#, #"\bvss"#, "alpha mix", "rvox", "climax", "loudener", "fastermaster", "renaissance axx", "mc2000", "weiss ds", "autobus", "dynassist", "rider", "linmb", "c4 ", "silika", "comp", "limit", "gate", "expander", "transient", "de-ess", "deess", "esser", "leveler",
                      "leveller", "maximiz", "clipper", "dynamic", "ducker", "envelope", "punch", "glue", "1176",
                      "la-2a", "la2a", "vocal rider", "smart:comp", "smack", "pro-l", "pro-c", "pro-mb",
                      "pro-g", "pro-ds", "soothe", "kickstart", "volume shap", "lfotool", "pump", "sidechain"]),
        ("Multi Effects", [#"\bchannel\b"#, "ultrachannel", #"\brack"#, "suite", "mixdown", "cla effects", "butch vig", "maserati", "voicecentric", "unplugged", "mastering", "god particle", "voxity", #"\bfx\b"#, #"^efx"#, "transit", "stutter", "looperator", "endless smile", "audiotrack", "neutron", "ozone", "channel strip", "chain", "multi", "strip"]),
        ("Amps and Pedals", ["ampeg", "suhr", "bass one", "pt100", "amplitube", "bad speaker", #"\bamps?\b"#, "amplif", "guitar", #"\bcab"#, "pedal", "stomp", "overloud", #"\bbias\b"#]),
        ("Distortion", ["decimort", "ohmicide", "heatwave", "microwarmer", "radiator", "inflator", "dragon fire", "cassette", "teac", "a-3340", "retro fi", "neold", #"\bk7d\b"#, "nls buss", "rbass", "lowender", "dist", "satur", "drive", "fuzz", "crush", "decapitat", "tube", "tape", "lofi", "lo-fi",
                        #"\bwarm"#, #"\bheat\b"#, "destruct", "bitcrush", "devil-loc", #"\btrash"#]),
        ("Modulation", ["phasemistress", "movement", "autopan", "vocoder", "talkbox", "sheen", "chorus", "flang", "phaser", "tremolo", "vibrato", "ensemble", "rotary", "leslie",
                        "modul", "doubler", "shaper", "shifter"]),
        ("Filter", ["flux", "lohi", "filter", #"\bwah"#, "bandpass", "hipass", "lowpass", "highpass"]),
        ("EQ", [#"\bq\d+\b"#, #"\breq\b"#, "emo-q", #"\bapi-5"#, "curves", "maag", "sie-q", "equivoc", "riceflat", "phils cascade", #"\bu17\b"#, "electra", "omega 458", "equal", "shelf", "pultec", "graphic", "pro-q", "smart:eq", "tilt", "q10"]),
        ("Utility", ["stream send", "recorder", "frontdaw", "vocalign", "clarity", "voiceassist", "kraftur", "gain", "utility", "trim", "polarity", "router", "tool", #"\bmono"#, "noise", "denois",
                     "de-noise", #"\brx\b"#, "repair", "clean", "netsend", "aac", #"\btest"#, "oscillat"]),
    ]

    private static let instrumentWords: [(String, [String])] = [
        ("Drums", ["drum", #"\bbeat"#, #"\bkit\b"#, "percuss", "808", "909", "groove", #"\bperc"#, "snare", #"\bkick"#, "battery",
                   "superior", "ezdrummer", "bfd"]),
        ("Keys", ["piano", "keys", "rhodes", "wurli", "organ", "b3", "clav", "grand", "upright", "keyscape",
                  "electric p"]),
        ("Orchestral", ["string", "orchestr", "brass", "woodwind", "choir", "cinemat", "symphon", "spitfire",
                        "labs", "ensemble", "cello", "violin", "horn", "flute"]),
        ("Bass", ["bass"]),
        ("Sampler", ["sampl", "kontakt", "player", "phrase", "loop", "slice", "rompler"]),
        ("Synth", ["synth", "osc", "serum", "vital", "massive", "pigments", "omnisphere", "diva", "repro",
                   "analog", "poly", #"\bmono"#, "wave", #"\bpads?\b"#, #"\blead"#, "pluck", #"\bfm\b"#, #"\bmini"#, "jup", "prophet"]),
    ]

    /// An Audio Unit tag or a looked-up category, in Logic's words; nil when it says nothing useful.
    static func normalize(_ raw: String) -> String? {
        let t = raw.lowercased()
        let table: [(String, [String])] = [
            ("Metering", ["meter", "analy", "loudness", "scope"]),
            ("Imaging", ["imag", "stereo", "spatial", "surround", "width", "panning"]),
            ("Reverb", ["reverb"]),
            ("Delay", ["delay", "echo", "time effect"]),
            ("Dynamics", ["dynamic", "compress", "limit", "gate", "transient", "de-ess", "deess"]),
            ("Amps and Pedals", ["amp", "guitar", "pedal", "cabinet"]),
            ("Distortion", ["distort", "saturat", "overdrive", "lo-fi", "lofi", "bitcrush"]),
            ("Modulation", ["modulat", "chorus", "flang", "phaser", "tremolo"]),
            ("Pitch", ["pitch", "tuning", "harmoniz", "vocal processing"]),
            ("Filter", ["filter"]),
            ("EQ", ["eq", "equaliz"]),
            ("Drums", ["drum", "percussion"]),
            ("Keys", ["piano", "keys", "organ"]),
            ("Orchestral", ["orchestr", "string", "brass", "choir"]),
            ("Sampler", ["sampler", "rompler"]),
            ("Synth", ["synth"]),
            ("Utility", ["utility", "restoration", "noise reduction", "tool", "gain"]),
            ("Multi Effects", ["multi", "channel strip", "mastering suite", "mixing suite"]),
        ]
        for (category, words) in table where words.contains(where: { t.contains($0) }) { return category }
        return nil
    }

    /// Dynamics split in three (BL-121): Compressor, Limiter (and maximizers), and Dynamics for
    /// the rest (gates, de-essers, transient shapers, multiband). The exact kind from the maker's
    /// page decides first, then the name.
    static func refineDynamics(name: String, kind: String?) -> String {
        switch kind {
        case "Compressor": return "Compressor"
        case "Limiter", "Maximizer": return "Limiter"
        case "Gate", "Expander", "De-esser", "Transient Shaper", "Multiband Dynamics": return "Dynamics"
        default: break
        }
        let n = name.lowercased()
        func has(_ list: [String]) -> Bool { list.contains { n.range(of: $0, options: .regularExpression) != nil } }
        if has(["multipressor", "multiband", "multi-band", #"\bmb\b"#, "pro-mb", "c4 ", #"\bc6\b"#, "linmb", "gate", "de-?ess", "esser",
                "transient", "expander", "envelope", "ducker", "smack", "punch", "kickstart", "lfotool", "volume shap", "rider"]) {
            return "Dynamics"
        }
        if n.contains("compress") { return "Compressor" }
        if has(["limit", "maximi", "pro-l", #"\bl[1-4]\b"#, #"\bl2\b"#, "loudener", "fastermaster", "clipper", #"clip\b"#, "inflator", "weiss ds"]) {
            return "Limiter"
        }
        if has(["comp", "1176", "la-?2a", "opto", "dbx", #"\bvsc"#, "dyna-mu", "vari-?mu", "fairchild", "glue", "pro-c", #"\bc[1-3]\b"#,
                #"(^|[^0-9])76\b"#, "kotelnikov", "rvox", "renaissance axx", "mc2000", "distressor", "api-2500", "bus comp", #"\bfet\b"#,
                #"\bvca\b"#, "smart:comp", "silika", "leveler", "leveller", "dynassist", "autobus", #"\bott\b"#]) {
            return "Compressor"
        }
        return "Dynamics"
    }

    static func guess(name: String, tags: [String], type: OSType) -> String {
        let lower = name.lowercased()
        let isInstrument = type == kAudioUnitType_MusicDevice
        if type == kAudioUnitType_MIDIProcessor { return "MIDI FX" }
        // "EQ" as its own word (Channel EQ, Smart EQ 4, ProEQ), not "sequencer" or "frequency".
        if !isInstrument, lower.range(of: #"(^|[^a-z])eq([^a-z]|$)|eq\d|[a-z]eq$"#, options: .regularExpression) != nil {
            return "EQ"
        }
        let words = isInstrument ? instrumentWords : effectWords
        // Words are matched as patterns, so a short word can be whole-word only ("amp", not sampler).
        for (category, list) in words where list.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return category
        }
        for tag in tags {
            if let c = normalize(tag) {
                let instrumentKinds: Set = ["Drums", "Keys", "Orchestral", "Sampler", "Synth", "Bass"]
                if isInstrument == instrumentKinds.contains(c) { return c }
            }
        }
        return isInstrument ? "Synth" : "Effects"
    }
}

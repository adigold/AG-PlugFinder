import Foundation

/// Logic Pro's own plugins (ChromaVerb, Channel EQ, Alchemy …). They live inside Logic and are
/// not Audio Units, so they are listed from this table, grouped the way Logic's plug-in menu
/// groups them. Only entries that the installed Logic actually ships are shown.
enum LogicCatalog {
    struct Entry {
        let name: String
        let category: String
        let slot: SlotKind
        var legacy = false
    }

    private static func fx(_ category: String, _ names: [String], legacy: Bool = false) -> [Entry] {
        names.map { Entry(name: $0, category: category, slot: .audioFX, legacy: legacy) }
    }
    private static func inst(_ category: String, _ names: [String], legacy: Bool = false) -> [Entry] {
        names.map { Entry(name: $0, category: category, slot: .instrument, legacy: legacy) }
    }

    static let entries: [Entry] = {
        var all: [Entry] = []
        all += fx("Amps and Pedals", ["Amp Designer", "Bass Amp Designer", "Pedalboard"])
        all += fx("Delay", ["Delay Designer", "Echo", "Sample Delay", "Stereo Delay", "Tape Delay"])
        all += fx("Distortion", ["Bitcrusher", "ChromaGlow", "Clip Distortion", "Distortion", "Overdrive",
                            "Phase Distortion"])
        all += fx("Dynamics", ["Adaptive Limiter", "Compressor", "DeEsser 2", "Enveloper", "Expander",
                          "Limiter", "Multipressor", "Noise Gate", "Surround Compressor"])
        all += fx("EQ", ["Channel EQ", "Linear Phase EQ", "Match EQ", "Single Band EQ",
                    "Vintage Console EQ", "Vintage Graphic EQ", "Vintage Tube EQ"])
        all += fx("Filter", ["AutoFilter", "EVOC 20 Filterbank", "EVOC 20 TrackOscillator", "Fuzz-Wah",
                        "Spectral Gate"])
        all += fx("Imaging", ["Binaural Post-Processing", "Direction Mixer", "Stereo Spread"])
        all += fx("Metering", ["BPM Counter", "Correlation Meter", "Level Meter", "Loudness Meter",
                          "MultiMeter", "Tuner"])
        all += fx("Modulation", ["Chorus", "Ensemble", "Flanger", "Microphaser", "Modulation Delay",
                            "Phaser", "Ringshifter", "Rotor Cabinet", "Scanner Vibrato", "Spreader",
                            "Tremolo"])
        all += fx("Multi Effects", ["Beat Breaker", "Phat FX", "Remix FX", "Step FX"])
        all += fx("Pitch", ["Pitch Correction", "Pitch Shifter", "Vocal Transformer"])
        all += fx("Reverb", ["ChromaVerb", "EnVerb", "Quantec Room Simulator", "SilverVerb",
                        "Space Designer"])
        all += fx("Specialized", ["Exciter", "SubBass"])
        all += fx("Utility", ["Gain", "Multichannel Gain", "Down Mixer", "Test Oscillator"])
        // Logic 12.4's Legacy menu (Distortion II and Ducker are no longer in it).
        all += fx("Legacy", ["AVerb", "Bass Amp", "DeEsser", "Denoiser", "DJ EQ", "Fat EQ", "Grooveshifter",
                        "GoldVerb", "Guitar Amp Pro", "High Cut", "High Pass Filter",
                        "High Shelving EQ", "Low Cut", "Low Pass Filter", "Low Shelving EQ",
                        "Parametric EQ", "PlatinumVerb", "Silver Compressor", "Silver EQ",
                        "Silver Gate", "Speech Enhancer"], legacy: true)
        all += inst("Synth", ["Alchemy", "EFM1", "ES E", "ES M", "ES P", "ES1", "ES2",
                         "Retro Synth", "Sculpture"])
        all += inst("Sampler", ["Quick Sampler", "Sample Alchemy", "Sampler"])
        all += inst("Drums", ["Drum Synth", "Drum Machine Designer", "Drum Kit Designer"])
        all += inst("Keys", ["Studio Piano", "Vintage B3 Organ", "Vintage Clav", "Vintage Electric Piano",
                        "Vintage Mellotron"])
        all += inst("Orchestral", ["Studio Strings", "Studio Horns"])
        all += inst("Bass", ["Studio Bass"])
        // Klopfgeist, Ultrabeat and EVOC 20 PolySynth are no longer in Logic 12.4's menus.
        all += ["Arpeggiator", "Chord Trigger", "Modifier", "Modulator", "Note Repeater", "Randomizer",
           "Scripter", "Transposer", "Velocity Processor"].map {
               Entry(name: $0, category: "MIDI FX", slot: .midiFX)
           }
        return all
    }()

    static let appPaths = ["/Applications/Logic Pro.app", "/Applications/Logic Pro X.app"]

    /// The plugins the installed Logic ships, or none when Logic is not installed.
    static func scan() -> [Plugin] {
        guard let appPath = appPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let bundle = Bundle(path: appPath) else { return [] }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let shipped = shippedNames(appPath)
        return entries
            .filter { shipped.isEmpty || shipped.contains(normalize($0.name)) }
            .map { e in
                Plugin(id: "logic-" + e.name.lowercased().filter { $0.isLetter || $0.isNumber },
                       name: e.name, manufacturer: "Logic Pro",
                       typeName: e.slot == .instrument ? "Instrument"
                           : e.slot == .midiFX ? "MIDI FX" : "Effect",
                       category: e.category, tags: [], version: version, isV3: false,
                       componentType: 0, componentSubType: 0, componentManufacturer: 0,
                       snapshotState: .builtIn,
                       source: .logic, logicSlot: e.slot.rawValue, isLegacy: e.legacy)
            }
    }

    /// Names Logic itself knows: its plug-in settings folders and its plugin name table.
    private static func shippedNames(_ appPath: String) -> Set<String> {
        var names = Set<String>()
        let fm = FileManager.default
        for dir in ["Contents/Resources/Plug-In Settings", "Contents/Resources/Library.bundle/Plug-In Settings"] {
            for n in (try? fm.contentsOfDirectory(atPath: "\(appPath)/\(dir)")) ?? [] {
                names.insert(normalize(n))
            }
        }
        let mapping = "\(appPath)/Contents/Frameworks/MAContentTagging.framework/Versions/A/Resources/DefaultPluginMapping.plist"
        if let dict = NSDictionary(contentsOfFile: mapping) as? [String: String] {
            for v in dict.values { names.insert(normalize(v)) }
        }
        return names
    }

    /// "ES2  (Synthesizer 2)" → "es2"
    static func normalize(_ s: String) -> String {
        let base = s.components(separatedBy: "  (").first ?? s
        return base.components(separatedBy: " (").first!
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}

import Foundation

/// Ableton Live's own devices (EQ Eight, Glue Compressor, Wavetable …), listed when Live is on
/// this Mac and shown only while Ableton is the program in use (BL-161). Sorted into the app's
/// own categories so a pill shows Live's devices beside the plugins of that kind.
enum AbletonCatalog {
    private typealias Entry = (name: String, category: String, slot: SlotKind)

    private static func fx(_ category: String, _ names: [String]) -> [Entry] { names.map { ($0, category, .audioFX) } }
    private static func inst(_ category: String, _ names: [String]) -> [Entry] { names.map { ($0, category, .instrument) } }

    private static let entries: [Entry] = {
        var all: [Entry] = []
        all += fx("Amps and Pedals", ["Amp", "Cabinet", "Pedal"])
        all += fx("Delay", ["Delay", "Echo", "Filter Delay", "Grain Delay", "Align Delay"])
        all += fx("Distortion", ["Dynamic Tube", "Erosion", "Overdrive", "Redux", "Roar", "Saturator", "Vinyl Distortion"])
        all += fx("Compressor", ["Compressor", "Glue Compressor"])
        all += fx("Limiter", ["Limiter", "Color Limiter"])
        all += fx("Multiband", ["Multiband Dynamics"])
        all += fx("Gate", ["Gate"])
        all += fx("Transient", ["Re-Enveloper"])
        all += fx("EQ", ["EQ Eight", "EQ Three", "Channel EQ"])
        all += fx("Filter", ["Auto Filter", "Vocoder"])
        all += fx("Modulation", ["Auto Pan", "Chorus-Ensemble", "Phaser-Flanger"])
        all += fx("Reverb", ["Reverb", "Hybrid Reverb"])
        all += fx("Pitch", ["Shifter", "Auto Shift"])
        all += fx("Metering", ["Spectrum", "Tuner"])
        all += fx("Utility", ["Utility", "External Audio Effect", "Looper"])
        all += fx("Multi Effects", ["Beat Repeat", "Drum Buss"])
        all += fx("Specialized", ["Corpus", "Resonators", "Spectral Resonator", "Spectral Time", "Spectral Blur"])
        all += inst("Synth", ["Analog", "Drift", "Meld", "Operator", "Wavetable", "Tension", "Collision"])
        all += inst("Keys", ["Electric"])
        all += inst("Sampler", ["Sampler", "Simpler"])
        all += inst("Drums", ["Drum Rack", "Impulse"])
        all += inst("Utility", ["External Instrument", "Instrument Rack"])
        all += ["Arpeggiator", "Chord", "Note Length", "Pitch", "Random", "Scale", "Velocity", "CC Control",
                "Expression Control", "Note Echo", "MIDI Effect Rack"].map { ($0, "MIDI FX", SlotKind.midiFX) }
        return all
    }()

    /// The Live app on this Mac, newest first.
    static var app: URL? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("Ableton Live") && $0.hasSuffix(".app") }.sorted().last
            .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
    }

    /// Live's devices, or none when Live is not installed.
    static func scan() -> [Plugin] {
        guard let app else { return [] }
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return entries.map { e in
            Plugin(id: "ableton-" + e.name.lowercased().filter { $0.isLetter || $0.isNumber } + (e.slot == .midiFX ? "-midi" : ""),
                   name: e.name, manufacturer: "Ableton",
                   typeName: e.slot == .instrument ? "Instrument" : e.slot == .midiFX ? "MIDI FX" : "Effect",
                   category: e.category, tags: [], version: version, isV3: false,
                   componentType: 0, componentSubType: 0, componentManufacturer: 0,
                   snapshotState: .builtIn, source: .ableton, logicSlot: e.slot.rawValue, isLegacy: false)
        }
    }
}

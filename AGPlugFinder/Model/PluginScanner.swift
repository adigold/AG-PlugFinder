import AVFoundation
import AudioToolbox

/// Lists the Audio Units installed on this Mac. Reads system metadata only; nothing is loaded.
enum PluginScanner {
    static let scannedTypes: [OSType] = [
        kAudioUnitType_Effect,
        kAudioUnitType_MusicEffect,
        kAudioUnitType_MusicDevice,
        kAudioUnitType_MIDIProcessor,
    ]

    static func scan() -> [Plugin] {
        var result: [String: Plugin] = [:]
        let manager = AVAudioUnitComponentManager.shared()
        for type in scannedTypes {
            let match = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                  componentManufacturer: 0, componentFlags: 0,
                                                  componentFlagsMask: 0)
            for c in manager.components(matching: match) {
                let d = c.audioComponentDescription
                var full = AudioComponentDescription()
                AudioComponentGetDescription(c.audioComponent, &full)
                let isV3 = (full.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue) != 0
                let id = Plugin.makeID(type: d.componentType, subType: d.componentSubType,
                                       manufacturer: d.componentManufacturer)
                let tags = c.allTagNames
                result[id] = Plugin(
                    id: id,
                    name: c.name,
                    manufacturer: c.manufacturerName,
                    typeName: c.typeName,
                    category: guessCategory(name: c.name, tags: tags, type: d.componentType),
                    tags: tags,
                    version: c.versionString,
                    isV3: isV3,
                    componentType: d.componentType,
                    componentSubType: d.componentSubType,
                    componentManufacturer: d.componentManufacturer,
                    path: c.componentURL?.path)
            }
        }
        return Array(result.values)
    }

    private static let keywordCategories: [(String, [String])] = [
        ("Reverb", ["reverb", "verb", "room", "hall", "plate", "space"]),
        ("Delay", ["delay", "echo", "tape"]),
        ("EQ", ["eq", "equal", "shelf", "bandpass", "hipass", "lowpass", "graphic"]),
        ("Dynamics", ["comp", "limit", "dynamics", "gate", "expander", "transient", "clip"]),
        ("Distortion", ["dist", "satur", "drive", "fuzz", "crush", "amplifier"]),
        ("Modulation", ["chorus", "flang", "phase", "tremolo", "vibrato", "ensemble", "rotary"]),
        ("Pitch", ["pitch", "tune", "harmon", "formant"]),
        ("Filter", ["filter", "wah"]),
        ("Utility", ["meter", "analy", "scope", "gain", "utility", "netsend", "aac"]),
    ]

    static func guessCategory(name: String, tags: [String], type: OSType) -> String {
        let known = Set(keywordCategories.map(\.0))
        if let tag = tags.first(where: { known.contains($0) }) { return tag }
        let lower = name.lowercased()
        if type == kAudioUnitType_MusicDevice {
            if lower.contains("sampl") { return "Sampler" }
            if lower.contains("drum") { return "Drums" }
            return tags.first ?? "Instrument"
        }
        for (category, words) in keywordCategories where words.contains(where: { lower.contains($0) }) {
            return category
        }
        if let tag = tags.first { return tag }
        switch type {
        case kAudioUnitType_MusicDevice: return "Instrument"
        case kAudioUnitType_MIDIProcessor: return "MIDI FX"
        case kAudioUnitType_MusicEffect: return "Music Effect"
        default: return "Effect"
        }
    }
}

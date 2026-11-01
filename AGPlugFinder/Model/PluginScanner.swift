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
        // macOS can keep listing a plugin after its file was deleted (BL-142): drop the ones whose
        // file is gone. If that would drop most of them, the check itself is wrong, so keep all.
        return keepInstalled(Array(result.values))
    }

    /// The plugins whose file is still on disk; all of them when the check would drop most.
    static func keepInstalled(_ list: [Plugin]) -> [Plugin] {
        let present = list.filter { p in p.path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
        return present.count >= list.count / 2 ? present : list
    }

    static func guessCategory(name: String, tags: [String], type: OSType) -> String {
        PluginCategories.guess(name: name, tags: tags, type: type)
    }
}

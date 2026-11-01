import AudioToolbox
import Foundation

/// What we learned about a plugin from the web lookup.
struct PluginDetails: Codable, Hashable {
    var category: String
    var kind: String
    var summary: String
    var bestFeature: String
    var highlights: [String]
    var fetchedAt: Date
}

enum SnapshotState: String, Codable {
    case pending, done, noUI, failed
    /// Logic's own plugins only run inside Logic, so they get a category card instead.
    case builtIn
}

/// One installed Audio Unit.
struct Plugin: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var manufacturer: String
    var typeName: String
    var category: String
    var tags: [String]
    var version: String
    var isV3: Bool
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32

    var parameterCount: Int?
    var snapshotState: SnapshotState = .pending
    var snapshotError: String?
    var details: PluginDetails?
    /// nil in catalogs saved before Logic plugins were added (= Audio Unit).
    var source: PluginSource?
    var logicSlot: String?
    var isLegacy: Bool?
    /// Where the plugin lives on disk (Audio Units), for the cleanup report (BL-32).
    var path: String?
    /// The category the user chose (BL-82); always wins over the guess and the look-up.
    var userCategory: String?
    /// What other users chose for it and shared (BL-104).
    var communityCategory: String?

    var kind: PluginSource { source ?? (isV3 ? .audioUnitV3 : .audioUnit) }
    var isLogic: Bool { kind == .logic }
    /// Logic's and Ableton's own: they come with their pictures and are never photographed or shared (BL-164).
    var isBuiltIn: Bool { kind == .logic || kind == .ableton }

    /// Group label used by the list editor and the Format filter.
    var formatName: String {
        switch kind {
        case .audioUnit: return "Audio Unit"
        case .audioUnitV3: return "Audio Unit v3"
        case .logic: return isLegacy == true ? "Logic (legacy)" : "Logic"
        case .ableton: return "Ableton"
        }
    }

    var typeGroup: String {
        switch slotKind {
        case .audioFX: return "Effect"
        case .instrument: return "Instrument"
        case .midiFX: return "MIDI FX"
        }
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: componentType,
                                  componentSubType: componentSubType,
                                  componentManufacturer: componentManufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    /// Which kind of Logic slot this plugin goes into.
    var slotKind: SlotKind {
        if let s = logicSlot, let k = SlotKind(rawValue: s) { return k }
        switch componentType {
        case kAudioUnitType_MusicDevice: return .instrument
        case kAudioUnitType_MIDIProcessor: return .midiFX
        default: return .audioFX
        }
    }

    /// Category shown in the UI: the looked-up one wins over our guess.
    var displayCategory: String {
        // A category chosen before Dynamics was split is split the same way (BL-150).
        if let c = userCategory { return Self.splitDynamics(c, name: name, id: id) }
        if !isLogic, MainActor.assumeIsolated({ PluginCategories.isChannelStrip(name) }) { return "Channel Strip" }
        return Self.splitDynamics(baseCategory, name: name, id: id)
    }

    private var baseCategory: String {
        if let c = communityCategory { return c }
        if isLogic { return category } // Logic's own menu category
        // A looked-up category counts only when it is one of the app's own (BL-77).
        if let c = details?.category, let known = PluginCategories.normalize(c) { return known }
        return category
    }

    /// Dynamics shows as one of its eight kinds (BL-121, BL-150).
    @MainActor private static var kinds: [String: String] = UserDefaults.standard.dictionary(forKey: "plugin.kinds") as? [String: String] ?? [:]
    @MainActor static func reloadKinds() {
        kinds = UserDefaults.standard.dictionary(forKey: "plugin.kinds") as? [String: String] ?? [:]
        PluginStore.shared.bumpRevision()
    }
    private static func splitDynamics(_ c: String, name: String, id: String) -> String {
        // The catch-all Effects category is gone (BL-152); a voice or noise tool is a utility.
        if c == "Effects" {
            let n = name.lowercased()
            return ["isolat", "noise", "denois", "hum", "declick"].contains(where: n.contains) ? "Utility" : "Specialized"
        }
        guard c == "Dynamics" else { return c }
        let kind = MainActor.assumeIsolated { kinds[id] }
        return PluginCategories.refineDynamics(name: name, kind: kind)
    }

    static func makeID(type: UInt32, subType: UInt32, manufacturer: UInt32) -> String {
        "\(fourCC(type))-\(fourCC(subType))-\(fourCC(manufacturer))"
    }
}

enum PluginSource: String, Codable {
    case audioUnit, audioUnitV3, logic
    /// Ableton Live's own devices (BL-161).
    case ableton
}

enum SlotKind: String {
    case audioFX, instrument, midiFX
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    let s = String(bytes: bytes, encoding: .macOSRoman) ?? "\(v)"
    return s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
}

enum PluginSort: String, CaseIterable, Identifiable {
    case name, manufacturer, category, recent, mostUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .manufacturer: return "Manufacturer"
        case .category: return "Category"
        case .recent: return "Recently used"
        case .mostUsed: return "Most used"
        }
    }
}

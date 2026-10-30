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

    var kind: PluginSource { source ?? (isV3 ? .audioUnitV3 : .audioUnit) }
    var isLogic: Bool { kind == .logic }

    /// Group label used by the list editor and the Format filter.
    var formatName: String {
        switch kind {
        case .audioUnit: return "Audio Unit"
        case .audioUnitV3: return "Audio Unit v3"
        case .logic: return isLegacy == true ? "Logic (legacy)" : "Logic"
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
        if isLogic { return category } // Logic's own menu category
        if let c = details?.category, !c.isEmpty { return c }
        return category
    }

    static func makeID(type: UInt32, subType: UInt32, manufacturer: UInt32) -> String {
        "\(fourCC(type))-\(fourCC(subType))-\(fourCC(manufacturer))"
    }
}

enum PluginSource: String, Codable {
    case audioUnit, audioUnitV3, logic
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

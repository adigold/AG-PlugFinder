import Foundation
import Observation

/// Which version of a plugin goes in when Logic offers several (Mono, Stereo, Mono→Stereo,
/// Dual Mono…) (BL-69). Auto picks the one that fits the track; Ask leaves Logic's own format
/// menu open to choose from. A plugin can have its own fixed choice.
enum ChannelFormat: String, CaseIterable, Identifiable {
    case auto, ask, stereo, monoToStereo, mono, dualMono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .ask: return "Ask me"
        case .stereo: return "Stereo"
        case .monoToStereo: return "Mono to Stereo"
        case .mono: return "Mono"
        case .dualMono: return "Dual Mono"
        }
    }

    static let fixed: [ChannelFormat] = [.stereo, .monoToStereo, .mono, .dualMono]

    /// Does Logic's menu item title name this format? Logic writes "Mono→Stereo".
    func matches(_ title: String) -> Bool {
        let t = title.lowercased().replacingOccurrences(of: " ", with: "")
        let both = t.contains("mono") && t.contains("stereo")
        switch self {
        case .stereo: return t == "stereo"
        case .monoToStereo: return both
        case .mono: return t == "mono"
        case .dualMono: return t.contains("dual")
        case .auto, .ask: return false
        }
    }

    /// Auto: Logic lists only the formats that fit the track. Stereo on a stereo track,
    /// Mono→Stereo on a mono one (so a mono vocal into a reverb comes out wide), else the first.
    static func autoChoice(_ titles: [String]) -> Int? {
        for f in [ChannelFormat.stereo, .monoToStereo] {
            if let i = titles.firstIndex(where: f.matches) { return i }
        }
        return titles.isEmpty ? nil : 0
    }
}

@MainActor
@Observable
final class ChannelFormats {
    static let shared = ChannelFormats()

    /// Auto or Ask, for every plugin without its own choice.
    var mode: ChannelFormat { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "channelMode") } }
    private(set) var perPlugin: [String: String]

    private init() {
        mode = ChannelFormat(rawValue: UserDefaults.standard.string(forKey: "channelMode") ?? "") ?? .auto
        perPlugin = UserDefaults.standard.dictionary(forKey: "channelFormat.perPlugin") as? [String: String] ?? [:]
    }

    /// The plugin's own choice, nil when it follows the general setting.
    func own(_ id: String) -> ChannelFormat? { perPlugin[id].flatMap(ChannelFormat.init(rawValue:)) }

    func set(_ f: ChannelFormat?, for id: String) {
        perPlugin[id] = f?.rawValue
        UserDefaults.standard.set(perPlugin, forKey: "channelFormat.perPlugin")
    }

    func choice(for id: String?) -> ChannelFormat { id.flatMap(own) ?? mode }
}

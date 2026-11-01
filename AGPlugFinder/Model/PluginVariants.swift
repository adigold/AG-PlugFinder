import Foundation

/// Mono and stereo versions of one plugin, such as Waves "API-550A (m)", "(s)" and "(m->s)",
/// shown as one (BL-124). Only plugins whose other version is really installed are joined, so a
/// name like "Stereo Image" is never touched. Logic gets the version that fits the track.
@MainActor
enum PluginVariants {
    enum Role: Int { case stereo = 0, monoToStereo = 1, mono = 2 }

    /// "API-550A (m)" → ("API-550A", .mono); nil when the name has no version mark.
    static func split(_ name: String) -> (base: String, role: Role)? {
        let patterns: [(String, Role)] = [
            (#"\s*\((m-?>s|m→s|mono\s*to\s*stereo)\)\s*$"#, .monoToStereo),
            (#"\s*\((s|stereo)\)\s*$"#, .stereo),
            (#"\s*\((m|mono)\)\s*$"#, .mono),
            (#"\s+stereo\s*$"#, .stereo),
            (#"\s+mono\s*$"#, .mono),
        ]
        for (p, role) in patterns {
            if let r = name.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let base = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return base.isEmpty ? nil : (base, role)
            }
        }
        return nil
    }

    private static var memo: (rev: Int, groups: [String: [Plugin]], member: [String: String])?

    /// Groups of two or more versions, keyed by maker and base name.
    private static func index() -> (groups: [String: [Plugin]], member: [String: String]) {
        let store = PluginStore.shared
        if let m = memo, m.rev == store.revision { return (m.groups, m.member) }
        var groups: [String: [Plugin]] = [:]
        for p in store.plugins {
            guard let (base, _) = split(p.name) else { continue }
            groups[p.manufacturer.lowercased() + "|" + base.lowercased(), default: []].append(p)
        }
        groups = groups.filter { $0.value.count > 1 && Set($0.value.compactMap { split($0.name)?.role }).count > 1 }
        var member: [String: String] = [:]
        for (k, list) in groups { for p in list { member[p.id] = k } }
        memo = (store.revision, groups, member)
        return (groups, member)
    }

    static var enabled: Bool { ViewSettings.shared.joinMonoStereo }

    /// The other versions of this plugin, best first: stereo, mono to stereo, mono.
    static func versions(of p: Plugin) -> [Plugin] {
        let (groups, member) = index()
        guard let k = member[p.id], let list = groups[k] else { return [] }
        return list.sorted { (split($0.name)?.role.rawValue ?? 9) < (split($1.name)?.role.rawValue ?? 9) }
    }

    /// The one shown for a joined group: the stereo version.
    static func isShown(_ p: Plugin) -> Bool {
        guard enabled else { return true }
        let v = versions(of: p)
        return v.isEmpty || v.first?.id == p.id
    }

    /// "API-550A" for a joined plugin, its own name otherwise.
    static func title(_ p: Plugin) -> String {
        guard enabled, versions(of: p).count > 1, let (base, _) = split(p.name) else { return p.name }
        return base
    }

    static func role(_ p: Plugin) -> Role? { split(p.name)?.role }

    static func roleTitle(_ p: Plugin) -> String {
        switch role(p) {
        case .stereo: return "Stereo"
        case .monoToStereo: return "Mono to Stereo"
        case .mono: return "Mono"
        case nil: return p.name
        }
    }


    static func version(_ role: Role, of p: Plugin) -> Plugin? {
        versions(of: p).first { split($0.name)?.role == role }
    }

    /// Reading Logic's format list for the chosen version tells the track's format: Logic lists
    /// only what fits the track. Returns the version to use instead, or nil to keep it.
    static func better(for p: Plugin, formats titles: [String]) -> Plugin? {
        guard enabled, let role = role(p), versions(of: p).count > 1 else { return nil }
        let t = titles.map { $0.lowercased().replacingOccurrences(of: " ", with: "") }
        let stereoTrack = t.contains("stereo") || t.contains { $0.contains("dual") }
        let monoTrack = !stereoTrack && (t.contains("mono") || t.contains { $0.contains("mono") && $0.contains("stereo") })
        if monoTrack, role != .mono { return version(.mono, of: p) }
        if stereoTrack, role == .mono { return version(.stereo, of: p) }
        return nil
    }
}

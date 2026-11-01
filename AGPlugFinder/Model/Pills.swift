import AppKit
import Foundation

/// Your own pill made of several categories, for example "Space" = Reverb + Delay (BL-110).
struct PillGroup: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var categories: [String]
}

/// How the pills above the plugins look and in what order (BL-110). Synced with the library.
/// Keys: "col:<collection id>", "cat:<category>", "grp:<group id>".
struct PillPrefs: Codable, Equatable {
    enum Sort: String, Codable, CaseIterable, Identifiable {
        case count, name, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .count: return "Most plugins"
            case .name: return "A to Z"
            case .custom: return "My order"
            }
        }
    }

    var sort: Sort = .count
    var order: [String] = []
    var pinned: [String] = []
    var hidden: [String] = []
    var names: [String: String] = [:]
    var colors: [String: String] = [:]
    var groups: [PillGroup] = []
    /// Counts on category pills; collections always show theirs.
    var showCounts = false
    var compact = false
    /// Wrap to more rows instead of the More pill.
    var wrap = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .count
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        groups = try c.decodeIfPresent([PillGroup].self, forKey: .groups) ?? []
        showCounts = try c.decodeIfPresent(Bool.self, forKey: .showCounts) ?? false
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap) ?? false
    }
}

/// One pill as drawn.
struct Pill: Identifiable, Hashable {
    enum Kind { case collection, category, group }
    let key: String
    let kind: Kind
    let title: String
    let original: String
    let count: Int
    let color: String?
    let pinned: Bool
    let hidden: Bool
    var id: String { key }
}

@MainActor
enum Pills {
    static var prefs: PillPrefs {
        get { UserLibrary.shared.pills }
        set { UserLibrary.shared.pills = newValue }
    }

    static let colorNames = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    /// Visible plugins per category.
    static func categoryCounts() -> [String: Int] {
        let store = PluginStore.shared
        return Dictionary(grouping: store.plugins.filter(store.isVisible), by: \.displayCategory)
            .mapValues(\.count).filter { !$0.key.isEmpty }
    }

    /// The real categories a category or combined pill stands for.
    static func categories(for key: String) -> [String] {
        if key.hasPrefix("cat:") { return [String(key.dropFirst(4))] }
        if key.hasPrefix("grp:") { return prefs.groups.first { "grp:" + $0.id == key }?.categories ?? [] }
        return []
    }

    static func collectionPills(includeHidden: Bool = false) -> [Pill] {
        let p = prefs
        let list = UserLibrary.shared.collections.map { c -> Pill in
            let key = "col:" + c.id
            return Pill(key: key, kind: .collection, title: c.name, original: c.name, count: c.pluginIDs.count,
                        color: p.colors[key], pinned: p.pinned.contains(key), hidden: p.hidden.contains(key))
        }
        return sorted(list.filter { includeHidden || !$0.hidden }, keepOrder: true)
    }

    /// Combined pills and the categories not inside one.
    static func categoryPills(includeHidden: Bool = false) -> [Pill] {
        let p = prefs
        let counts = categoryCounts()
        let grouped = Set(p.groups.flatMap(\.categories))
        var list = p.groups.map { g -> Pill in
            let key = "grp:" + g.id
            return Pill(key: key, kind: .group, title: g.name, original: g.name,
                        count: g.categories.reduce(0) { $0 + (counts[$1] ?? 0) },
                        color: p.colors[key], pinned: p.pinned.contains(key), hidden: p.hidden.contains(key))
        }
        list += counts.keys.filter { !grouped.contains($0) }.map { c in
            let key = "cat:" + c
            return Pill(key: key, kind: .category, title: p.names[key] ?? c, original: c, count: counts[c] ?? 0,
                        color: p.colors[key], pinned: p.pinned.contains(key), hidden: p.hidden.contains(key))
        }
        return sorted(list.filter { includeHidden || !$0.hidden })
    }

    /// Collections keep the library's order unless the user sorts them.
    private static func sorted(_ list: [Pill], keepOrder: Bool = false) -> [Pill] {
        switch prefs.sort {
        case .count:
            if keepOrder { return list }
            return list.sorted { $0.count == $1.count ? $0.title.localizedCompare($1.title) == .orderedAscending : $0.count > $1.count }
        case .name:
            return list.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .custom:
            let rank = Dictionary(prefs.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return list.enumerated().sorted { a, b in
                let ra = rank[a.element.key] ?? Int.max, rb = rank[b.element.key] ?? Int.max
                return ra == rb ? a.offset < b.offset : ra < rb
            }.map(\.element)
        }
    }

    // MARK: Changes

    static func togglePin(_ key: String) {
        var p = prefs
        if let i = p.pinned.firstIndex(of: key) { p.pinned.remove(at: i) } else { p.pinned.append(key) }
        prefs = p
    }

    static func setHidden(_ key: String, _ hide: Bool) {
        var p = prefs
        p.hidden.removeAll { $0 == key }
        if hide { p.hidden.append(key) }
        prefs = p
    }

    static func setColor(_ key: String, _ color: String?) {
        var p = prefs
        p.colors[key] = color
        prefs = p
    }

    /// Collections and combined pills get a new name; a category gets a name of its own on its
    /// pill (empty goes back to the category's name).
    static func rename(_ pill: Pill) {
        let what = pill.kind == .category ? "Name for the \(pill.original) pill" : "Rename \(pill.title)"
        guard let name = NamePrompt.ask(what, placeholder: pill.original, initial: pill.title) else { return }
        switch pill.kind {
        case .collection:
            let lib = UserLibrary.shared
            if let i = lib.collections.firstIndex(where: { "col:" + $0.id == pill.key }) { lib.collections[i].name = name }
        case .group:
            var p = prefs
            if let i = p.groups.firstIndex(where: { "grp:" + $0.id == pill.key }) { p.groups[i].name = name }
            prefs = p
        case .category:
            var p = prefs
            p.names[pill.key] = name == pill.original ? nil : name
            prefs = p
        }
    }

    static func restoreName(_ key: String) {
        var p = prefs
        p.names[key] = nil
        prefs = p
    }

    /// The rows in their new order, as dragged in Edit Pills: switches to My order.
    static func setOrder(_ keys: [String]) {
        var p = prefs
        let moved = Set(keys)
        p.order = keys + p.order.filter { !moved.contains($0) }
        p.sort = .custom
        prefs = p
    }

    @discardableResult
    static func saveGroup(id: String?, name: String, categories: [String]) -> String {
        var p = prefs
        let cats = categories.sorted()
        // A category moves out of any other combined pill.
        for i in p.groups.indices where p.groups[i].id != id { p.groups[i].categories.removeAll { cats.contains($0) } }
        if let id, let i = p.groups.firstIndex(where: { $0.id == id }) {
            p.groups[i].name = name
            p.groups[i].categories = cats
            prefs = p
            return "grp:" + id
        }
        let g = PillGroup(name: name, categories: cats)
        p.groups.append(g)
        prefs = p
        return "grp:" + g.id
    }

    static func ungroup(_ key: String) {
        var p = prefs
        p.groups.removeAll { "grp:" + $0.id == key }
        p.pinned.removeAll { $0 == key }
        p.hidden.removeAll { $0 == key }
        p.colors[key] = nil
        prefs = p
    }

    /// Back to the default look and order. Combined pills stay.
    static func reset() {
        var p = PillPrefs()
        p.groups = prefs.groups
        prefs = p
    }

    // MARK: Widths for the More pill

    static func font(compact: Bool) -> NSFont { .systemFont(ofSize: compact ? 11 : 12, weight: .semibold) }

    static func text(_ pill: Pill, showCounts: Bool) -> String {
        pill.kind == .collection || showCounts ? "\(pill.title)  \(pill.count)" : pill.title
    }

    /// The width a pill takes in the row, with the space after it.
    static func width(_ pill: Pill, prefs p: PillPrefs) -> CGFloat {
        let t = text(pill, showCounts: p.showCounts) as NSString
        let w = t.size(withAttributes: [.font: font(compact: p.compact)]).width
        return ceil(w) + (p.compact ? 18 : 22) + (pill.color != nil ? 11 : 0) + 8
    }
}

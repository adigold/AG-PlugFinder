import AppKit
import Foundation
import Observation

/// Holds the plugin catalog, favorites, recents and the screenshot cache. Everything lives in
/// ~/Library/Application Support/AG PlugFinder so the popup opens instantly.
@MainActor
@Observable
final class PluginStore {
    static let shared = PluginStore()

    private(set) var plugins: [Plugin] = []
    var favorites: Set<String> = [] { didSet { saveDefaults() } }
    var lastUsed: [String: Date] = [:] { didSet { saveDefaults() } }
    /// Groups hidden in the list editor, as "maker:Apple", "category:Reverb", "format:Logic", "type:MIDI FX".
    var hiddenGroups: Set<String> = [] { didSet { saveDefaults() } }
    /// Single plugins hidden or forced visible in the list editor.
    var hiddenPlugins: Set<String> = [] { didSet { saveDefaults() } }
    var shownPlugins: Set<String> = [] { didSet { saveDefaults() } }
    /// Bumped whenever a screenshot file changes, so views reload images.
    private(set) var imageGeneration = 0

    let supportDir: URL
    let thumbsDir: URL
    private let catalogURL: URL
    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("AG PlugFinder", isDirectory: true)
        thumbsDir = supportDir.appendingPathComponent("Screenshots", isDirectory: true)
        catalogURL = supportDir.appendingPathComponent("catalog.json")
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Catalog

    /// Re-reads the installed Audio Units and merges them with what we already know
    /// (screenshots and looked-up info are kept for plugins whose version did not change).
    func rescan() {
        let found = PluginScanner.scan() + LogicCatalog.scan()
        let old = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        plugins = found.map { p in
            guard let prev = old[p.id] else { return p }
            var merged = p
            merged.details = prev.details
            merged.parameterCount = prev.parameterCount
            if prev.version == p.version, !p.isLogic {
                merged.snapshotState = prev.snapshotState
                merged.snapshotError = prev.snapshotError
            }
            return merged
        }
        save()
    }

    func update(_ id: String, _ change: (inout Plugin) -> Void) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        change(&plugins[i])
        save()
    }

    func plugin(_ id: String) -> Plugin? { plugins.first { $0.id == id } }

    // MARK: Screenshots

    func snapshotURL(for id: String) -> URL { thumbsDir.appendingPathComponent("\(id).png") }

    func image(for id: String) -> NSImage? {
        let key = "\(id)#\(imageGeneration)" as NSString
        if let img = imageCache.object(forKey: key) { return img }
        guard let img = NSImage(contentsOf: snapshotURL(for: id)) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// Deletes a plugin's screenshot so it can be taken again (Logic's own plugins keep their card).
    func clearScreenshots(_ ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: snapshotURL(for: id))
            update(id) { p in
                if !p.isLogic { p.snapshotState = .pending; p.snapshotError = nil }
            }
        }
        snapshotChanged()
    }

    func clearInfo(_ ids: [String]) {
        for id in ids { update(id) { $0.details = nil } }
    }

    /// Shows only the plugins of one group: every other value of that grouping is hidden.
    func showOnly(_ kind: GroupKind, _ value: String) {
        let values = Set(plugins.map { Self.groupValue($0, kind) })
        for v in values { setGroup(kind, v, visible: v == value) }
    }

    func snapshotChanged() {
        imageCache.removeAllObjects()
        imageGeneration += 1
    }

    // MARK: Favorites / recents

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }

    func markUsed(_ id: String) { lastUsed[id] = Date() }

    // MARK: Visibility (list editor)

    enum GroupKind: String, CaseIterable, Identifiable {
        case maker, category, format, type
        var id: String { rawValue }
        var title: String {
            switch self {
            case .maker: return "Manufacturer"
            case .category: return "Category"
            case .format: return "Format"
            case .type: return "Type"
            }
        }
    }

    static func groupValue(_ p: Plugin, _ kind: GroupKind) -> String {
        switch kind {
        case .maker: return p.manufacturer
        case .category: return p.displayCategory
        case .format: return p.formatName
        case .type: return p.typeGroup
        }
    }

    static func groupKey(_ kind: GroupKind, _ value: String) -> String { "\(kind.rawValue):\(value)" }

    func isVisible(_ p: Plugin) -> Bool {
        if hiddenPlugins.contains(p.id) { return false }
        if shownPlugins.contains(p.id) { return true }
        return !GroupKind.allCases.contains { hiddenGroups.contains(Self.groupKey($0, Self.groupValue(p, $0))) }
    }

    func setPlugin(_ id: String, visible: Bool) {
        hiddenPlugins.remove(id); shownPlugins.remove(id)
        guard let p = plugin(id) else { return }
        let groupHidden = GroupKind.allCases.contains {
            hiddenGroups.contains(Self.groupKey($0, Self.groupValue(p, $0)))
        }
        if visible && groupHidden { shownPlugins.insert(id) }
        if !visible && !groupHidden { hiddenPlugins.insert(id) }
    }

    func setGroup(_ kind: GroupKind, _ value: String, visible: Bool) {
        let key = Self.groupKey(kind, value)
        if visible { hiddenGroups.remove(key) } else { hiddenGroups.insert(key) }
        // A group switch overrides earlier single-plugin choices inside it.
        for p in plugins where Self.groupValue(p, kind) == value {
            hiddenPlugins.remove(p.id); shownPlugins.remove(p.id)
        }
    }

    // MARK: Search and sort

    func filtered(query: String, sort: PluginSort, favoritesOnly: Bool = false) -> [Plugin] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let pool = plugins.filter { isVisible($0) && (!favoritesOnly || favorites.contains($0.id)) }
        let list = words.isEmpty ? pool : pool.filter { p in
            let hay = [p.name, p.manufacturer, p.displayCategory, p.typeName, p.formatName,
                       p.details?.kind ?? "", p.tags.joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let byName: (Plugin, Plugin) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        switch sort {
        case .name:
            return list.sorted(by: byName)
        case .category:
            return list.sorted {
                let c = $0.displayCategory.localizedCaseInsensitiveCompare($1.displayCategory)
                return c == .orderedSame ? byName($0, $1) : c == .orderedAscending
            }
        case .manufacturer:
            return list.sorted {
                let c = $0.manufacturer.localizedCaseInsensitiveCompare($1.manufacturer)
                return c == .orderedSame ? byName($0, $1) : c == .orderedAscending
            }
        case .recent:
            return list.sorted {
                let a = lastUsed[$0.id], b = lastUsed[$1.id]
                switch (a, b) {
                case let (a?, b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName($0, $1)
                }
            }
        }
    }

    // MARK: Persistence

    private var isLoading = false

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let data = try? Data(contentsOf: catalogURL),
           let list = try? JSONDecoder().decode([Plugin].self, from: data) {
            plugins = list
        }
        let d = UserDefaults.standard
        favorites = Set(d.stringArray(forKey: "favorites") ?? [])
        hiddenGroups = Set(d.stringArray(forKey: "hiddenGroups") ?? ["format:Logic (legacy)"])
        hiddenPlugins = Set(d.stringArray(forKey: "hiddenPlugins") ?? [])
        shownPlugins = Set(d.stringArray(forKey: "shownPlugins") ?? [])
        if let data = d.data(forKey: "lastUsed"),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastUsed = map
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(plugins)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            NSLog("AG PlugFinder: could not save catalog: \(error)")
        }
    }

    private func saveDefaults() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(Array(favorites), forKey: "favorites")
        d.set(try? JSONEncoder().encode(lastUsed), forKey: "lastUsed")
        d.set(Array(hiddenGroups), forKey: "hiddenGroups")
        d.set(Array(hiddenPlugins), forKey: "hiddenPlugins")
        d.set(Array(shownPlugins), forKey: "shownPlugins")
    }
}

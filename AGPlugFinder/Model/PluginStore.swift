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
    /// Called when favorites or visibility change, so they sync to the user's other Macs.
    var onSettingsChanged: (() -> Void)?
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
            merged.userCategory = prev.userCategory
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

    /// Pictures that ship inside the app (Logic's own plugins, BL-21). A picture the user took
    /// or downloaded always wins over the bundled one.
    static func bundledSnapshotURL(for id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "LogicScreenshots")
    }

    func hasScreenshot(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: id).path) || Self.bundledSnapshotURL(for: id) != nil
    }

    func image(for id: String) -> NSImage? {
        let key = "\(id)#\(imageGeneration)" as NSString
        if let img = imageCache.object(forKey: key) { return img }
        guard let img = NSImage(contentsOf: snapshotURL(for: id))
                ?? Self.bundledSnapshotURL(for: id).flatMap(NSImage.init(contentsOf:)) else { return nil }
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

    /// The plugin waiting for "Remove from Favorites?" to be answered.
    var confirmingUnfavorite: String?

    /// Adds at once; removing asks first (Adi, 2026-10-31).
    func favoriteTapped(_ id: String) {
        if favorites.contains(id) { confirmingUnfavorite = id } else { favorites.insert(id) }
    }

    func markUsed(_ id: String) {
        lastUsed[id] = Date()
        UserLibrary.shared.countUse(id)
    }

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

    func filtered(query: String, sort: PluginSort, favoritesOnly: Bool = false,
                  only ids: Set<String>? = nil) -> [Plugin] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let pool = plugins.filter {
            isVisible($0) && (!favoritesOnly || favorites.contains($0.id)) && (ids?.contains($0.id) ?? true)
        }
        var list = words.isEmpty ? pool : pool.filter { p in
            let hay = Self.nameHay(p)
            return words.allSatisfy { hay.contains($0) }
        }
        // Search by what it does (BL-27): name matches first, then plugins whose description,
        // best feature or highlights match every word.
        if !words.isEmpty {
            let named = Set(list.map(\.id))
            let described = pool.filter { p in
                guard !named.contains(p.id) else { return false }
                let hay = Self.descriptionHay(p)
                return words.allSatisfy { hay.contains($0) }
            }
            if !described.isEmpty {
                return sortList(list, sort) + sortList(described, sort)
            }
        }
        list = sortList(list, sort)
        return list
    }

    static func nameHay(_ p: Plugin) -> String {
        [p.name, p.manufacturer, p.displayCategory, p.typeName, p.formatName,
         p.details?.kind ?? "", p.tags.joined(separator: " ")].joined(separator: " ").lowercased()
    }

    static func descriptionHay(_ p: Plugin) -> String {
        guard let d = p.details else { return "" }
        return ([d.summary, d.bestFeature, d.kind, d.category] + d.highlights).joined(separator: " ").lowercased()
    }

    private func sortList(_ list: [Plugin], _ sort: PluginSort) -> [Plugin] {
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
        case .mostUsed:
            let count = UserLibrary.shared.useCount
            return list.sorted {
                let a = count[$0.id] ?? 0, b = count[$1.id] ?? 0
                return a == b ? byName($0, $1) : a > b
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
        onSettingsChanged?()
    }
}

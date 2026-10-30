import AppKit
import Foundation
import Observation

/// Holds the plugin catalog, favorites, recents and the screenshot cache. Everything lives in
/// ~/Library/Application Support/AU Plugin Helper so the popup opens instantly.
@MainActor
@Observable
final class PluginStore {
    static let shared = PluginStore()

    private(set) var plugins: [Plugin] = []
    var favorites: Set<String> = [] { didSet { saveDefaults() } }
    var lastUsed: [String: Date] = [:] { didSet { saveDefaults() } }
    /// Bumped whenever a screenshot file changes, so views reload images.
    private(set) var imageGeneration = 0

    let supportDir: URL
    let thumbsDir: URL
    private let catalogURL: URL
    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("AU Plugin Helper", isDirectory: true)
        thumbsDir = supportDir.appendingPathComponent("Screenshots", isDirectory: true)
        catalogURL = supportDir.appendingPathComponent("catalog.json")
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Catalog

    /// Re-reads the installed Audio Units and merges them with what we already know
    /// (screenshots and looked-up info are kept for plugins whose version did not change).
    func rescan() {
        let found = PluginScanner.scan()
        let old = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        plugins = found.map { p in
            guard let prev = old[p.id] else { return p }
            var merged = p
            merged.details = prev.details
            merged.parameterCount = prev.parameterCount
            if prev.version == p.version {
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

    func snapshotChanged() {
        imageCache.removeAllObjects()
        imageGeneration += 1
    }

    // MARK: Favorites / recents

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }

    func markUsed(_ id: String) { lastUsed[id] = Date() }

    // MARK: Search and sort

    func filtered(query: String, sort: PluginSort) -> [Plugin] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let list = words.isEmpty ? plugins : plugins.filter { p in
            let hay = [p.name, p.manufacturer, p.displayCategory, p.typeName,
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
        case .favorites:
            return list.sorted {
                let a = favorites.contains($0.id), b = favorites.contains($1.id)
                return a == b ? byName($0, $1) : a
            }
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: catalogURL),
           let list = try? JSONDecoder().decode([Plugin].self, from: data) {
            plugins = list
        }
        let d = UserDefaults.standard
        favorites = Set(d.stringArray(forKey: "favorites") ?? [])
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
            NSLog("AU Plugin Helper: could not save catalog: \(error)")
        }
    }

    private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(Array(favorites), forKey: "favorites")
        d.set(try? JSONEncoder().encode(lastUsed), forKey: "lastUsed")
    }
}

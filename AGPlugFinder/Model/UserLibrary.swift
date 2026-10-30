import Foundation
import Observation

/// What the user builds on top of the catalog: chains (BL-25), number pins (BL-26),
/// collections (BL-29), notes (BL-30) and usage counts (BL-31). Saved in library.json and,
/// when sync is on, mirrored through iCloud Drive to the user's other Macs (BL-34).
@MainActor
@Observable
final class UserLibrary {
    static let shared = UserLibrary()

    struct Chain: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var pluginIDs: [String]
    }

    struct Collection: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var pluginIDs: [String]
    }

    /// A number key (1…9) points at a plugin ("p:<id>") or a chain ("c:<id>").
    enum PinTarget: Equatable {
        case plugin(String), chain(String)
        var ref: String {
            switch self { case .plugin(let id): return "p:" + id; case .chain(let id): return "c:" + id }
        }
        init?(ref: String) {
            if ref.hasPrefix("p:") { self = .plugin(String(ref.dropFirst(2))) }
            else if ref.hasPrefix("c:") { self = .chain(String(ref.dropFirst(2))) }
            else { return nil }
        }
    }

    private struct Saved: Codable {
        var chains: [Chain] = []
        var collections: [Collection] = []
        var notes: [String: String] = [:]
        var pins: [String: String] = [:]          // "1"…"9" → ref
        var useCount: [String: Int] = [:]
        var updatedAt = Date()
        // Synced along with the library (BL-34); read from and written to PluginStore.
        var favorites: [String]? = nil
        var hiddenGroups: [String]? = nil
        var hiddenPlugins: [String]? = nil
        var shownPlugins: [String]? = nil
    }

    var chains: [Chain] = [] { didSet { changed() } }
    var collections: [Collection] = [] { didSet { changed() } }
    var notes: [String: String] = [:] { didSet { changed() } }
    private(set) var pins: [String: String] = [:] {
        didSet { changed(); if !loading { HotKey.shared.registerPins() } }
    }
    var useCount: [String: Int] = [:] { didSet { changed() } }

    var syncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sync.iCloud") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sync.iCloud"); if newValue { pushToCloud() } }
    }

    private let fileURL: URL
    private var loading = false
    private var updatedAt = Date.distantPast

    private init() {
        fileURL = PluginStore.shared.supportDir.appendingPathComponent("library.json")
        if !load(from: fileURL) {
            // First run of this version: plugins used before count once each.
            loading = true
            useCount = PluginStore.shared.lastUsed.mapValues { _ in 1 }
            loading = false
        }
        pullFromCloud()
        PluginStore.shared.onSettingsChanged = { [weak self] in self?.storeSettingsChanged() }
    }

    // MARK: Chains

    @discardableResult
    func newChain(named name: String, with ids: [String] = []) -> Chain {
        let chain = Chain(name: name, pluginIDs: ids)
        chains.append(chain)
        return chain
    }

    func addToChain(_ chainID: String, _ pluginID: String) {
        guard let i = chains.firstIndex(where: { $0.id == chainID }) else { return }
        chains[i].pluginIDs.append(pluginID)
    }

    func deleteChain(_ id: String) {
        chains.removeAll { $0.id == id }
        for (k, v) in pins where v == PinTarget.chain(id).ref { pins[k] = nil }
    }

    func plugins(in chain: Chain) -> [Plugin] {
        chain.pluginIDs.compactMap { PluginStore.shared.plugin($0) }
    }

    // MARK: Collections

    func toggle(_ pluginID: String, in collectionID: String) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let j = collections[i].pluginIDs.firstIndex(of: pluginID) { collections[i].pluginIDs.remove(at: j) }
        else { collections[i].pluginIDs.append(pluginID) }
    }

    func collections(containing pluginID: String) -> [Collection] {
        collections.filter { $0.pluginIDs.contains(pluginID) }
    }

    // MARK: Pins

    func pin(_ key: Int, to target: PinTarget?) {
        var p = pins
        for (k, v) in p where v == target?.ref { p[k] = nil }   // one key per target
        p[String(key)] = target?.ref
        pins = p
    }

    func pinTarget(_ key: Int) -> PinTarget? { pins[String(key)].flatMap(PinTarget.init(ref:)) }

    func key(for target: PinTarget) -> Int? {
        pins.first { $0.value == target.ref }.flatMap { Int($0.key) }
    }

    // MARK: Usage

    func countUse(_ id: String) { useCount[id, default: 0] += 1 }

    // MARK: Saving and sync

    private func changed() {
        guard !loading else { return }
        updatedAt = Date()
        save(to: fileURL)
        pushToCloud()
    }

    private func snapshot() -> Saved {
        let store = PluginStore.shared
        return Saved(chains: chains, collections: collections, notes: notes, pins: pins, useCount: useCount,
                     updatedAt: updatedAt, favorites: Array(store.favorites),
                     hiddenGroups: Array(store.hiddenGroups), hiddenPlugins: Array(store.hiddenPlugins),
                     shownPlugins: Array(store.shownPlugins))
    }

    private func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snapshot()) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    private func load(from url: URL, applyStoreSettings: Bool = false) -> Bool {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data)
        else { return false }
        loading = true
        defer { loading = false }
        chains = s.chains
        collections = s.collections
        notes = s.notes
        pins = s.pins
        useCount = s.useCount
        updatedAt = s.updatedAt
        if applyStoreSettings {
            let store = PluginStore.shared
            if let f = s.favorites { store.favorites = Set(f) }
            if let g = s.hiddenGroups { store.hiddenGroups = Set(g) }
            if let h = s.hiddenPlugins { store.hiddenPlugins = Set(h) }
            if let v = s.shownPlugins { store.shownPlugins = Set(v) }
        }
        return true
    }

    /// iCloud Drive's folder on this Mac; nil when iCloud Drive is off.
    static var cloudFile: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("AG PlugFinder/library.json")
    }

    /// Settings that changed in PluginStore (favorites, hidden plugins) also go to the cloud.
    func storeSettingsChanged() {
        guard !loading else { return }
        updatedAt = Date()
        save(to: fileURL)
        pushToCloud()
    }

    private func pushToCloud() {
        guard syncEnabled, let cloud = Self.cloudFile else { return }
        try? FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        save(to: cloud)
    }

    /// Takes the cloud copy when it is newer than this Mac's (on launch and when the app
    /// comes to the front).
    func pullFromCloud() {
        guard syncEnabled, let cloud = Self.cloudFile,
              let data = try? Data(contentsOf: cloud),
              let s = try? JSONDecoder().decode(Saved.self, from: data),
              s.updatedAt > updatedAt.addingTimeInterval(1) else { return }
        if load(from: cloud, applyStoreSettings: true) { save(to: fileURL) }
    }

    var lastSynced: Date? {
        guard let cloud = Self.cloudFile else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: cloud.path))?[.modificationDate] as? Date
    }
}

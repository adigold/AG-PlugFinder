import Foundation
import Observation

/// What the user builds on top of the catalog: chains (BL-25), number pins (BL-26),
/// collections (BL-29), notes (BL-30) and usage counts (BL-31). Saved in library.json and,
/// when sync is on, mirrored through iCloud Drive to the user's other Macs (BL-34).

/// The parts of the library a Mac can choose to sync or keep to itself (BL-157).
enum SyncSection: String, CaseIterable, Identifiable {
    case favorites, collections, chains, notes, keys, hidden, pills, purchases, appearance, view
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .collections: return "Collections"
        case .chains: return "Chains"
        case .notes: return "Notes"
        case .keys: return "Number keys 1 to 9"
        case .hidden: return "Hidden plugins"
        case .pills: return "Pills: order, names, colors and combined pills"
        case .purchases: return "My Purchases: purchases and subscriptions"
        case .appearance: return "Theme and text size"
        case .view: return "View: grid or list, picture size, names and details"
        }
    }
}

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
        var pills: PillPrefs? = nil
        // Synced from BL-157 on: the look and the view choices, as plain text values.
        var appearance: [String: String]? = nil
        var view: [String: String]? = nil
    }

    var chains: [Chain] = [] { didSet { changed() } }
    var collections: [Collection] = [] { didSet { changed() } }
    var notes: [String: String] = [:] { didSet { changed() } }
    private(set) var pins: [String: String] = [:] {
        didSet { changed(); if !loading { HotKey.shared.registerPins() } }
    }
    var useCount: [String: Int] = [:] { didSet { changed() } }
    /// The pills above the plugins: order, names, colors, combined pills (BL-110).
    var pills = PillPrefs() { didSet { if pills != oldValue { changed() } } }

    var syncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sync.iCloud") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sync.iCloud"); if newValue { pushToCloud() } }
    }

    /// Sections this Mac keeps to itself (BL-157). Empty means everything syncs.
    var syncOff: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sync.off") ?? []) {
        didSet {
            guard syncOff != oldValue else { return }
            if !readOnly { UserDefaults.standard.set(Array(syncOff), forKey: "sync.off") }
            // A section turned back on takes what the other Macs have, then shares from here on.
            for s in oldValue.subtracting(syncOff).compactMap(SyncSection.init(rawValue:)) { adoptCloud(s) }
            if oldValue.contains(SyncSection.purchases.rawValue), !syncOff.contains(SyncSection.purchases.rawValue) {
                Licenses.shared.pullFromCloud()
            }
            pushToCloud()
        }
    }

    /// Whether this part syncs on this Mac.
    func syncs(_ s: SyncSection) -> Bool { syncEnabled && !syncOff.contains(s.rawValue) }

    /// Settings made outside the library (look, view) arrive here once the library is ready.
    nonisolated(unsafe) static var ready = false

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
        Self.ready = true
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

    /// Self-tests change the library without saving it here or in iCloud.
    var readOnly = false

    private func changed() {
        guard !loading, !readOnly else { return }
        updatedAt = Date()
        save(to: fileURL)
        pushToCloud()
    }

    private func snapshot() -> Saved {
        let store = PluginStore.shared
        let look = AppearanceSettings.shared
        return Saved(chains: chains, collections: collections, notes: notes, pins: pins, useCount: useCount,
                     updatedAt: updatedAt, favorites: Array(store.favorites),
                     hiddenGroups: Array(store.hiddenGroups), hiddenPlugins: Array(store.hiddenPlugins),
                     shownPlugins: Array(store.shownPlugins), pills: pills,
                     appearance: ["theme": look.paletteID, "textScale": String(look.textScale),
                                  "followSystem": look.followSystem ? "1" : "0", "themeLight": look.lightID, "themeDark": look.darkID],
                     view: ViewSettings.shared.syncValues)
    }

    private func save(to url: URL) { write(snapshot(), to: url) }

    private func write(_ saved: Saved, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    private static func decode(_ url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Reads a saved library. From iCloud (`applyStoreSettings`), only the sections this Mac
    /// syncs are taken (BL-157); this Mac's own file always loads whole.
    @discardableResult
    private func load(from url: URL, applyStoreSettings: Bool = false) -> Bool {
        guard let s = Self.decode(url) else { return false }
        loading = true
        defer { loading = false }
        apply(s, only: applyStoreSettings ? Set(SyncSection.allCases.filter { !syncOff.contains($0.rawValue) }) : Set(SyncSection.allCases),
              cloud: applyStoreSettings)
        useCount = s.useCount
        updatedAt = s.updatedAt
        return true
    }

    private func apply(_ s: Saved, only: Set<SyncSection>, cloud: Bool) {
        if only.contains(.chains) { chains = s.chains }
        if only.contains(.collections) { collections = s.collections }
        if only.contains(.notes) { notes = s.notes }
        if only.contains(.keys) { pins = s.pins }
        if only.contains(.pills) { pills = s.pills ?? PillPrefs() }
        guard cloud else { return }
        let store = PluginStore.shared
        if only.contains(.favorites), let f = s.favorites { store.favorites = Set(f) }
        if only.contains(.hidden) {
            if let g = s.hiddenGroups { store.hiddenGroups = Set(g) }
            if let h = s.hiddenPlugins { store.hiddenPlugins = Set(h) }
            if let v = s.shownPlugins { store.shownPlugins = Set(v) }
        }
        if only.contains(.appearance), let a = s.appearance {
            let look = AppearanceSettings.shared
            if let t = a["theme"], t != look.paletteID, Palette.all.contains(where: { $0.id == t }) { look.paletteID = t }
            if let z = a["textScale"].flatMap(Double.init), abs(z - look.textScale) > 0.001 { look.textScale = min(max(z, 0.85), 1.3) }
            // Match the Mac and its two themes (BL-183); older copies of the app send none of these.
            if let f = a["followSystem"].map({ $0 == "1" }), f != look.followSystem { look.followSystem = f }
            if let t = a["themeLight"], t != look.lightID, Palette.all.contains(where: { $0.id == t }) { look.lightID = t }
            if let t = a["themeDark"], t != look.darkID, Palette.all.contains(where: { $0.id == t }) { look.darkID = t }
        }
        if only.contains(.view), let v = s.view { ViewSettings.shared.applySync(v) }
    }

    /// A section just turned on takes the iCloud copy, so this Mac does not overwrite the others.
    private func adoptCloud(_ section: SyncSection) {
        guard syncEnabled, section != .purchases, let cloud = Self.cloudFile, let s = Self.decode(cloud) else { return }
        loading = true
        apply(s, only: [section], cloud: true)
        loading = false
        if !readOnly { save(to: fileURL) }
    }

    /// iCloud Drive's folder on this Mac; nil when iCloud Drive is off.
    static var cloudFile: URL? {
        #if DEBUG
        // Self-test only: a stand-in for the iCloud file, so a test never touches the real one.
        if let k = CommandLine.arguments.firstIndex(of: "--sync-cloud"), k + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[k + 1])
        }
        #endif
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("AG PlugFinder/library.json")
    }

    /// Settings that changed in PluginStore (favorites, hidden plugins) also go to the cloud.
    func storeSettingsChanged() {
        guard !loading, !readOnly else { return }
        updatedAt = Date()
        save(to: fileURL)
        pushToCloud()
    }

    private func pushToCloud() {
        guard syncEnabled, let cloud = Self.cloudFile else { return }
        try? FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = snapshot()
        // Sections this Mac keeps to itself: the iCloud copy keeps the other Macs' version.
        if !syncOff.isEmpty, let old = Self.decode(cloud) {
            for s in syncOff.compactMap(SyncSection.init(rawValue:)) {
                switch s {
                case .favorites: out.favorites = old.favorites
                case .collections: out.collections = old.collections
                case .chains: out.chains = old.chains
                case .notes: out.notes = old.notes
                case .keys: out.pins = old.pins
                case .hidden: out.hiddenGroups = old.hiddenGroups; out.hiddenPlugins = old.hiddenPlugins; out.shownPlugins = old.shownPlugins
                case .pills: out.pills = old.pills
                case .appearance: out.appearance = old.appearance
                case .view: out.view = old.view
                case .purchases: break
                }
            }
        }
        write(out, to: cloud)
    }

    /// The look or a view choice changed on this Mac: share it (BL-157).
    func settingChanged() {
        guard Self.ready, !loading else { return }
        storeSettingsChanged()
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

    /// Sync right now (BL-131): take the newer cloud copy, write this Mac's, then wait for iCloud
    /// to say the file is uploaded. true when iCloud confirmed it, false when it is still
    /// uploading after the wait (it carries on in the background).
    func syncNow(wait: Duration = .seconds(30)) async -> Bool {
        pullFromCloud()
        pushToCloud()
        guard let cloud = Self.cloudFile else { return false }
        let end = ContinuousClock.now + wait
        while ContinuousClock.now < end {
            var url = cloud
            url.removeAllCachedResourceValues()
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            if v?.ubiquitousItemIsUploaded == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    var lastSynced: Date? {
        guard let cloud = Self.cloudFile else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: cloud.path))?[.modificationDate] as? Date
    }
}

import Foundation

/// What Logic's Plug-in Manager knows about each Audio Unit (BL-139): the categories the user
/// made, the plugins they starred, and how often Logic saw a plugin crash. Read only, from the
/// files Logic keeps in ~/Music/Audio Music Apps/Databases/Tags. Logic's own plugins are left out.
enum LogicTags {
    struct Entry {
        var categories: [String] = []
        var favorite = false
        var crashes = 0
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Audio Music Apps/Databases/Tags", isDirectory: true)
    }

    private static var cache: (date: Date, entries: [String: Entry])?

    /// One entry per Audio Unit, keyed like the app's plugin ids ("aufx-Chao-NbsA"). Read again
    /// only when Logic changed its files.
    static func entries() -> [String: Entry] {
        let fm = FileManager.default
        let changed = (try? fm.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date ?? .distantPast
        if let cache, cache.date == changed { return cache.entries }
        var out: [String: Entry] = [:]
        let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasSuffix(".tagset") {
            guard let id = pluginID(file),
                  let data = fm.contents(atPath: folder.appendingPathComponent(file).path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            var e = Entry()
            // A category the user chose; Logic marks its own sorting "default".
            if let tags = plist["tags"] as? [String: Any] {
                e.categories = tags.compactMap { name, how in
                    guard !name.isEmpty, (how as? String) != "default" else { return nil }
                    return name.replacingOccurrences(of: ":", with: " · ")
                }.sorted()
            }
            e.favorite = isOn(plist["favorite"])
            e.crashes = (plist["crashes"] as? Int) ?? Int(plist["crashes"] as? String ?? "") ?? 0
            if !e.categories.isEmpty || e.favorite || e.crashes > 0 { out[id] = e }
        }
        cache = (changed, out)
        return out
    }

    /// "61756678-4368616f-4e627341.tagset" is type, subtype and maker in hex: "aufx-Chao-NbsA".
    /// nil for Logic's own plugins and anything that isn't an Audio Unit code.
    static func pluginID(_ file: String) -> String? {
        let parts = file.replacingOccurrences(of: ".tagset", with: "").split(separator: "-")
        guard parts.count == 3 else { return nil }
        var codes: [String] = []
        for p in parts {
            guard p.count == 8, let n = UInt32(p, radix: 16) else { return nil }
            let bytes = withUnsafeBytes(of: n.bigEndian) { Array($0) }
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }), let s = String(bytes: bytes, encoding: .ascii) else { return nil }
            codes.append(s)
        }
        guard codes[0].hasPrefix("au") else { return nil }
        return codes.joined(separator: "-")
    }

    private static func isOn(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as Int: return n != 0
        case let s as String: return !s.isEmpty && s != "0" && s.lowercased() != "false"
        default: return false
        }
    }

    /// How many times Logic recorded this plugin crashing, 0 when never.
    static func crashes(_ id: String) -> Int { entries()[id]?.crashes ?? 0 }

    /// What an import would bring in, for the plugins installed on this Mac.
    struct Found {
        var favorites: [String] = []
        var categories: [String: [String]] = [:]   // Logic category → plugin ids
    }

    @MainActor
    static func found() -> Found {
        let installed = Set(PluginStore.shared.plugins.map(\.id))
        var f = Found()
        for (id, e) in entries() where installed.contains(id) {
            if e.favorite { f.favorites.append(id) }
            for c in e.categories { f.categories[c, default: []].append(id) }
        }
        return f
    }
}

extension LogicTags {
    /// Adds Logic's favorites to the app's and makes each Logic category a collection (merged into
    /// one with the same name). Only adds: nothing is removed here, and nothing in Logic changes.
    @MainActor
    @discardableResult
    static func importIntoLibrary(_ f: Found) -> (favorites: Int, collections: Int) {
        let store = PluginStore.shared, lib = UserLibrary.shared
        let newFavorites = f.favorites.filter { !store.favorites.contains($0) }
        if !newFavorites.isEmpty { store.favorites.formUnion(newFavorites) }
        var made = 0
        for (name, ids) in f.categories.sorted(by: { $0.key < $1.key }) {
            if let i = lib.collections.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let add = ids.filter { !lib.collections[i].pluginIDs.contains($0) }
                lib.collections[i].pluginIDs += add
            } else {
                lib.collections.append(UserLibrary.Collection(name: name, pluginIDs: ids.sorted()))
                made += 1
            }
        }
        return (newFavorites.count, made)
    }
}

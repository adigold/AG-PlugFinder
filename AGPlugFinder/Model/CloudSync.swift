import AppKit
import Foundation

/// A file in iCloud Drive and whether it can be read yet (BL-193). On a Mac that just joined,
/// iCloud lists the file before its contents have arrived; reading it then would look like an
/// empty library, and writing over it would wipe the other Macs' data.
enum CloudFile {
    enum State { case missing, notDownloaded, ready }

    static func state(_ url: URL) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        var u = url
        u.removeAllCachedResourceValues()
        let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard v?.isUbiquitousItem == true else { return .ready }       // a plain file (tests, iCloud off)
        if v?.ubiquitousItemDownloadingStatus == .current { return .ready }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return .notDownloaded
    }
}

/// Your own plugin screenshots, mirrored through iCloud Drive (BL-193): a picture taken, found on
/// the web or chosen on one Mac shows on the others. Newer wins, except the first time a Mac
/// joins: then the iCloud copy wins, so a fresh download never replaces a picture you chose.
/// A cleared picture is cleared on every Mac. Pictures that come with the app are not copied.
@MainActor
enum PictureSync {
    private static var running = false
    private static var again = false
    private static var lastRun = Date.distantPast
    private static var pending: Task<Void, Never>?
    private static var testJoined = false
    /// For the self test: the folder of this Mac's pictures (normally the real one).
    static var localDir: URL { testLocal ?? PluginStore.shared.thumbsDir }
    static var testLocal: URL?

    static var cloudDir: URL? {
        UserLibrary.cloudFile?.deletingLastPathComponent().appendingPathComponent("Screenshots", isDirectory: true)
    }

    private static var enabled: Bool { UserLibrary.shared.syncs(.pictures) && (!UserLibrary.shared.readOnly || testLocal != nil) }

    /// Soon, once: many pictures saved in a row make one sync.
    static func soon(_ delay: Duration = .seconds(3)) {
        guard enabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            run()
        }
    }

    /// When the app comes to the front; at most every half minute.
    static func whenActive() {
        guard Date().timeIntervalSince(lastRun) > 30 else { return }
        soon(.milliseconds(500))
    }

    /// A picture cleared on this Mac is cleared in iCloud too, and remembered so the other Macs
    /// clear theirs instead of sending it back.
    static func removed(_ ids: [String]) {
        guard enabled, let dir = cloudDir, !ids.isEmpty else { return }
        let now = Date()
        DispatchQueue.global(qos: .utility).async {
            var gone = readRemoved(dir)
            for id in ids {
                gone[id] = now
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".png"))
            }
            writeRemoved(gone, dir)
        }
    }

    static func run() {
        guard enabled, let dir = cloudDir else { return }
        if running { again = true; return }
        running = true
        lastRun = Date()
        let local = localDir
        let joined = UserLibrary.testing ? testJoined : UserDefaults.standard.bool(forKey: "sync.picturesJoined")
        DispatchQueue.global(qos: .utility).async {
            let result = reconcile(local: local, cloud: dir, joined: joined)
            DispatchQueue.main.async {
                running = false
                if !joined, result.complete {
                    if UserLibrary.testing { testJoined = true } else { UserDefaults.standard.set(true, forKey: "sync.picturesJoined") }
                }
                if !result.arrived.isEmpty || !result.cleared.isEmpty { applyArrivals(result.arrived, cleared: result.cleared) }
                if again { again = false; soon() }
            }
        }
    }

    /// Plugins whose picture just came from iCloud show it; cleared ones go back to waiting.
    private static func applyArrivals(_ arrived: [String], cleared: [String]) {
        let store = PluginStore.shared
        let ids = Set(store.plugins.map(\.id))
        for id in arrived where ids.contains(id) {
            store.update(id) { p in if p.snapshotState != .done || p.snapshotError != nil { p.snapshotState = .done; p.snapshotError = nil } }
        }
        for id in cleared where ids.contains(id) {
            store.update(id) { p in if !p.isLogic { p.snapshotState = .pending; p.snapshotError = nil } }
        }
        store.snapshotChanged()
    }

    // MARK: Off the main thread

    nonisolated private static func pictures(in dir: URL) -> [String: Date] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: Date] = [:]
        for name in names where name.hasSuffix(".png") && !name.hasSuffix(".previous.png") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            out[String(name.dropLast(4))] = date
        }
        return out
    }

    nonisolated private static func readRemoved(_ dir: URL) -> [String: Date] {
        let url = dir.appendingPathComponent("removed.json")
        guard CloudFile.state(url) == .ready, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    nonisolated private static func writeRemoved(_ map: [String: Date], _ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: dir.appendingPathComponent("removed.json"), options: .atomic) }
    }

    /// Copies whichever side is newer. Returns the pictures that arrived here and the ones cleared here.
    nonisolated private static func reconcile(local: URL, cloud: URL, joined: Bool) -> (arrived: [String], cleared: [String], complete: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mine = pictures(in: local), theirs = pictures(in: cloud)
        var removed = readRemoved(cloud)
        var removedChanged = false
        var arrived: [String] = [], cleared: [String] = []
        var complete = true

        for (id, date) in mine {
            if let gone = removed[id] {
                // Cleared on another Mac after this picture was made: clear it here too.
                if date <= gone, theirs[id] == nil {
                    try? fm.removeItem(at: local.appendingPathComponent(id + ".png"))
                    cleared.append(id)
                    continue
                }
                // Taken again since: it counts, and the old clearing is forgotten.
                removed[id] = nil
                removedChanged = true
            }
            // Joining: a picture already in iCloud wins over this Mac's.
            let up = theirs[id].map { joined && date.timeIntervalSince($0) > 2 } ?? true
            if up { copy(local.appendingPathComponent(id + ".png"), to: cloud.appendingPathComponent(id + ".png"), date: date) }
        }
        for (id, date) in theirs {
            let down = mine[id].map { !joined || date.timeIntervalSince($0) > 2 } ?? true
            guard down else { continue }
            let src = cloud.appendingPathComponent(id + ".png")
            guard CloudFile.state(src) == .ready else { complete = false; continue }   // downloading; next time
            if copy(src, to: local.appendingPathComponent(id + ".png"), date: date) { arrived.append(id) }
        }
        if removedChanged { writeRemoved(removed, cloud) }
        return (arrived, cleared, complete)
    }

    /// Replaces the file safely and gives the copy the same date, so it is not sent back.
    @discardableResult
    nonisolated private static func copy(_ src: URL, to dst: URL, date: Date) -> Bool {
        let fm = FileManager.default
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".sync-" + UUID().uuidString + ".png")
        guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return false }
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dst.path) {
            guard (try? fm.replaceItemAt(dst, withItemAt: tmp)) != nil else { try? fm.removeItem(at: tmp); return false }
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dst.path)
        } else {
            guard (try? fm.moveItem(at: tmp, to: dst)) != nil else { try? fm.removeItem(at: tmp); return false }
        }
        return true
    }
}

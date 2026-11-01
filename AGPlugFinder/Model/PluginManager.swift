import AppKit

/// Plugin Manager (BL-144): every plugin file on the Mac in every format, the duplicates among
/// them, and removal that moves files into a folder on the Desktop instead of deleting them.
@MainActor
@Observable
final class PluginManager {
    static let shared = PluginManager()

    enum Format: String, CaseIterable, Identifiable {
        case au = "AU", vst = "VST", vst3 = "VST3", aax = "AAX", clap = "CLAP"
        var id: String { rawValue }
        var usedByLogic: Bool { self == .au }
        static func of(_ url: URL) -> Format? {
            switch url.pathExtension.lowercased() {
            case "component": return .au
            case "vst": return .vst
            case "vst3": return .vst3
            case "aaxplugin": return .aax
            case "clap": return .clap
            default: return nil
            }
        }
    }

    struct Item: Identifiable, Hashable {
        let url: URL
        let format: Format
        let name: String
        let version: String
        let bundleID: String
        let size: Int64
        let installed: Date?
        let system: Bool          // in /Library (needs the Mac's password to move)
        var receipt: String?      // the installer that put it there, when macOS kept a record
        var id: String { url.path }
        /// The same plugin in any format, version or folder.
        var key: String { PluginManager.matchKey(name) }
    }

    enum Note: String { case twice = "Installed twice", older = "Older version", notLogic = "Not used by Logic" }

    private(set) var items: [Item] = []
    private(set) var scanning = false
    private(set) var lastScan: Date?
    var selected: Set<String> = []
    /// Files each installer put outside the plugin folders (support files, presets, manuals),
    /// only those no other installer claims and none inside an app.
    private(set) var leftoverFiles: [String: [String]] = [:]

    /// The standard plugin folders, for this user and for every user of the Mac.
    nonisolated static var folders: [(URL, Bool)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [(URL, Bool)] = []
        for (root, system) in [(home.appendingPathComponent("Library/Audio/Plug-Ins"), false),
                               (URL(fileURLWithPath: "/Library/Audio/Plug-Ins"), true)] {
            for sub in ["Components", "VST", "VST3", "CLAP"] { list.append((root.appendingPathComponent(sub), system)) }
        }
        list.append((URL(fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins"), true))
        list.append((home.appendingPathComponent("Library/Application Support/Avid/Audio/Plug-Ins"), false))
        return list
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = Self.findAll()
            let (receipts, extras) = Self.receipts(for: Set(found.map(\.url.path)))
            let withReceipts = found.map { i -> Item in var j = i; j.receipt = receipts[i.url.path]; return j }
            await MainActor.run {
                self.leftoverFiles = extras
                self.items = withReceipts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.selected = self.selected.filter { id in withReceipts.contains { $0.id == id } }
                self.scanning = false
                self.lastScan = Date()
            }
        }
    }

    nonisolated private static func findAll() -> [Item] {
        let fm = FileManager.default
        var out: [Item] = []
        for (folder, system) in folders {
            // Makers often keep their plugins in a folder of their own, one level down.
            var candidates: [URL] = []
            for u in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if Format.of(u) != nil { candidates.append(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    candidates += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { Format.of($0) != nil }
                }
            }
            for u in candidates {
                guard let format = Format.of(u) else { continue }
                let info = Bundle(url: u)?.infoDictionary ?? [:]
                let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? u.deletingPathExtension().lastPathComponent
                out.append(Item(url: u, format: format,
                                name: u.deletingPathExtension().lastPathComponent.isEmpty ? name : u.deletingPathExtension().lastPathComponent,
                                version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "",
                                bundleID: info["CFBundleIdentifier"] as? String ?? "",
                                size: size(of: u),
                                installed: (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                                system: system, receipt: nil))
            }
        }
        return out
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Which installer put each plugin there, from the receipts macOS keeps (pkgutil), and the
    /// other files each installer left outside the plugin folders. Read only.
    nonisolated private static func receipts(for paths: Set<String>) -> ([String: String], [String: [String]]) {
        func run(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var out: [String: String] = [:]
        var others: [String: [String]] = [:]
        var owners: [String: Int] = [:]
        let pkgs = run(["--pkgs"]).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("com.apple.") }
        for pkg in pkgs {
            let info = run(["--pkg-info", pkg])
            let volume = info.split(separator: "\n").first { $0.hasPrefix("volume: ") }.map { String($0.dropFirst(8)) } ?? "/"
            let location = info.split(separator: "\n").first { $0.hasPrefix("location: ") }.map { String($0.dropFirst(10)) } ?? ""
            let base = URL(fileURLWithPath: volume).appendingPathComponent(location)
            var mine = false
            var extra: [String] = []
            for line in run(["--files", pkg]).split(separator: "\n") {
                let full = base.appendingPathComponent(String(line)).standardizedFileURL.path
                if paths.contains(full) { mine = true; if out[full] == nil { out[full] = pkg } }
                // A leftover is a single file in a Library folder, never part of a plugin or an app.
                guard full.hasPrefix("/Library/") || full.hasPrefix(home + "/Library/") else { continue }
                let lower = full.lowercased()
                guard ![".component/", ".vst/", ".vst3/", ".aaxplugin/", ".clap/", ".app/", ".framework/", ".bundle/", ".kext/"]
                        .contains(where: lower.contains),
                      !lower.contains("/launchdaemons/"), !lower.contains("/launchagents/"),
                      !lower.contains("/privilegedhelpertools/"), !lower.contains("/extensions/") else { continue }
                owners[full, default: 0] += 1
                extra.append(full)
            }
            if mine { others[pkg] = extra }
        }
        // Only files that exist, are plain files and belong to this installer alone.
        for (pkg, list) in others {
            others[pkg] = list.filter { f in
                var dir: ObjCBool = false
                return owners[f] == 1 && fm.fileExists(atPath: f, isDirectory: &dir) && !dir.boolValue
            }
        }
        return (out, others.filter { !$0.value.isEmpty })
    }

    /// The leftovers that go with the chosen plugins: only for an installer whose every plugin
    /// is among them, so nothing a remaining plugin needs is touched.
    func leftovers(for chosen: [Item]) -> [String] {
        let ids = Set(chosen.map(\.id))
        let pkgs = Set(chosen.compactMap(\.receipt)).filter { pkg in
            items.filter { $0.receipt == pkg }.allSatisfy { ids.contains($0.id) }
        }
        return pkgs.sorted().flatMap { leftoverFiles[$0] ?? [] }
    }

    // MARK: Duplicates

    /// "FabFilter Pro-Q 3 (m)", "Pro-Q 3.vst3" and "FabFilter Pro-Q 3" all match.
    nonisolated static func matchKey(_ name: String) -> String {
        var n = name.lowercased()
        for cut in [#"\s*\((m|s|m->s|mono|stereo)\)\s*$"#, #"\s+(x64|64|intel|arm|universal)$"#] {
            n = n.replacingOccurrences(of: cut, with: "", options: .regularExpression)
        }
        return n.filter { $0.isLetter || $0.isNumber }
    }

    /// What is worth a look in each group of the same plugin. Nothing is ever ticked by itself.
    func notes() -> [String: Note] {
        var out: [String: Note] = [:]
        for (_, group) in Dictionary(grouping: items, by: \.key) where group.count > 1 {
            let hasAU = group.contains { $0.format == .au }
            for (_, same) in Dictionary(grouping: group, by: \.format) where same.count > 1 {
                let newest = same.max { Self.older($0.version, than: $1.version) }
                for i in same where i.id != newest?.id {
                    out[i.id] = same.allSatisfy({ $0.version == same[0].version }) ? .twice : .older
                }
            }
            if hasAU { for i in group where !i.format.usedByLogic && out[i.id] == nil { out[i.id] = .notLogic } }
        }
        return out
    }

    nonisolated static func older(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    // MARK: Removal

    /// Moves the chosen plugins into "Removed Plugins <date>" on the Desktop, one folder per
    /// format, keeping them whole so they can be dragged back. System folders ask for the Mac's
    /// password once. Returns the folder and what could not be moved.
    func moveToDesktop(_ chosen: [Item], leftovers: [String] = []) -> (folder: URL, moved: Int, failed: [String], extras: Int) {
        let fm = FileManager.default
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        var folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Removed Plugins \(stamp)")
        var n = 2
        while fm.fileExists(atPath: folder.path), (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == false && n < 50 {
            // Keep earlier removals of the same day apart.
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Removed Plugins \(stamp) (\(n))"); n += 1
        }
        var moved = 0, extras = 0, failed: [String] = []
        // (source, destination, plugin name or nil for a leftover)
        var jobs: [(URL, URL, String?)] = []
        for item in chosen {
            let dir = folder.appendingPathComponent(item.format.rawValue)
            var dest = dir.appendingPathComponent(item.url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) || jobs.contains(where: { $0.1 == dest }) {
                dest = dir.appendingPathComponent("\(item.url.deletingPathExtension().lastPathComponent) \(item.system ? "system" : "user").\(item.url.pathExtension)")
            }
            jobs.append((item.url, dest, item.name))
        }
        // Leftovers keep their full path under "Other Files", so each one can go back where it was.
        for path in leftovers {
            jobs.append((URL(fileURLWithPath: path), folder.appendingPathComponent("Other Files").appendingPathComponent(String(path.drop { $0 == "/" })), nil))
        }
        var needsPassword: [(URL, URL, String?)] = []
        for job in jobs {
            try? fm.createDirectory(at: job.1.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.moveItem(at: job.0, to: job.1); if job.2 != nil { moved += 1 } else { extras += 1 } }
            catch { needsPassword.append(job) }
        }
        if !needsPassword.isEmpty {
            // One password prompt for every file in the system folders.
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let user = NSUserName()
            let cmd = needsPassword.map { "/bin/mv \(q($0.0.path)) \(q($0.1.path))" }.joined(separator: " ; ")
                + " ; /usr/sbin/chown -R \(q(user)) \(q(folder.path))"
            let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            for (src, dest, name) in needsPassword {
                let ok = fm.fileExists(atPath: dest.path) && !fm.fileExists(atPath: src.path)
                if let name { if ok { moved += 1 } else { failed.append(name) } } else if ok { extras += 1 }
            }
        }
        selected.subtract(chosen.map(\.id))
        scan()
        PluginWatcher.shared.rescanNow(quietWhenNothingNew: true)
        return (folder, moved, failed, extras)
    }
}

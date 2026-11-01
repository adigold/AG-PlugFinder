import AppKit

/// The shared plugin database (BL-71). Pictures the app takes of third-party plugins are sent
/// there, so other users won't have to take them. On unless the user turns it off in
/// Settings. Only the picture and the plugin's name, maker, version and category are sent,
/// with a random id for this Mac. Every failure is silent: sharing never gets in the way.
@MainActor
enum PlugDB {
    static var base: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "AGPFPlugDBURL") as? String).flatMap(URL.init(string:))
    }
    static var key: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AGPFUploadKey") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    static var sharing: Bool {
        get { UserDefaults.standard.object(forKey: "share.pictures") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "share.pictures") }
    }

    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "share.installID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "share.installID")
        return id
    }

    /// Plugin id → version already sent, so each picture goes up once per version.
    private static var sent: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "share.sent") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "share.sent") }
    }

    private static var busy = false

    /// Sends one plugin's picture right after it was taken.
    static func share(_ plugin: Plugin) {
        Task { await send(plugin) }
    }

    /// Sends the pictures already on this Mac that were not sent yet, one at a time.
    static func shareExisting() {
        guard sharing, !busy, base != nil, key != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            let store = PluginStore.shared
            let todo = store.plugins.filter { !$0.isBuiltIn && sent[$0.id] != $0.version }
            for p in todo.prefix(400) {
                guard sharing else { return }
                if await send(p) { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
    }

    /// Sends a category the user chose for these plugins, after they agreed (BL-82).
    static func shareCategory(_ plugins: [Plugin], _ category: String) {
        // A category the user made is theirs alone: it never goes to the database (BL-201).
        guard !UserLibrary.shared.isMine(category) else { return }
        guard let base, let key, !plugins.isEmpty else { return }
        let body: [String: Any] = [
            "installId": installID, "category": category,
            "plugins": plugins.prefix(500).map {
                ["pluginId": $0.id, "name": $0.name, "manufacturer": $0.manufacturer]
            },
        ]
        var request = URLRequest(url: base.appendingPathComponent("v1/categories"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    /// The revision of each database picture this Mac has. A picture replaced in the database
    /// gets a higher one, and is then downloaded again (Adi, 2026-10-31).
    static var pictureRev: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "share.pictureRev") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "share.pictureRev") }
    }

    /// At launch: pictures that were replaced in the database since this Mac got (or took) its
    /// own are downloaded again. The old one is kept, so Undo brings it back. Silent on failure.
    /// The plugin's page on its maker's site, when the database has one.
    static func productURL(_ id: String) -> URL? {
        (UserDefaults.standard.dictionary(forKey: "plugin.urls")?[id] as? String).flatMap(URL.init(string:))
    }

    /// The plugin's exact kind from its maker's page, for example Limiter.
    static func kind(_ id: String) -> String? {
        UserDefaults.standard.dictionary(forKey: "plugin.kinds")?[id] as? String
    }

    static func refreshReplacedPictures() async {
        guard let base, let key else { return }
        let store = PluginStore.shared
        let ids = store.plugins.filter { !$0.isBuiltIn }.map(\.id)
        guard !ids.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/lookup"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": Array(ids.prefix(2000))])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["available"] as? [[String: Any]] else { return }
        // Each plugin's page on its maker's site and its exact kind (BL-119, BL-120).
        var urls: [String: String] = [:], kinds: [String: String] = [:]
        for r in rows {
            guard let id = r["plugin_id"] as? String else { continue }
            if let u = r["product_url"] as? String, u.hasPrefix("https://") { urls[id] = u }
            if let k = r["kind"] as? String, !k.isEmpty { kinds[id] = k }
        }
        // Only the plugins asked about change: a shorter plugin list (a scan still running, a test
        // copy) never wipes the links and kinds of the others (BL-129).
        var test = false
        #if DEBUG
        test = CommandLine.arguments.contains { $0.hasPrefix("--selftest") }
        #endif
        if !test {
            let asked = Set(ids.prefix(2000))
            func merged(_ key: String, _ found: [String: String]) -> [String: String] {
                var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
                for id in asked { all[id] = nil }
                all.merge(found) { _, new in new }
                return all
            }
            UserDefaults.standard.set(merged("plugin.urls", urls), forKey: "plugin.urls")
            UserDefaults.standard.set(merged("plugin.kinds", kinds), forKey: "plugin.kinds")
            Plugin.reloadKinds()
        }
        let seen = pictureRev
        let newer = rows.compactMap { r -> String? in
            guard let id = r["plugin_id"] as? String, let rev = r["picture_rev"] as? Int, rev > (seen[id] ?? 0) else { return nil }
            return id
        }
        guard !newer.isEmpty else { return }
        for id in newer { WebPicture.backUp(id) }
        let got = await fetchApproved(newer)
        if !got.isEmpty { NSLog("AG PlugFinder: \(got.count) pictures replaced from the database") }
    }

    /// Downloads the community's categories and applies them (BL-104). The user's own choice
    /// always wins; silent on any failure.
    static func applyCommunityCategories() async {
        guard let base, let key else { return }
        let store = PluginStore.shared
        let ids = store.plugins.map(\.id)
        guard !ids.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/categories/agreed"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": ids])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["categories"] as? [[String: Any]] else { return }
        let agreed = Dictionary(rows.compactMap { r -> (String, String)? in
            guard let id = r["plugin_id"] as? String, let c = r["category"] as? String,
                  PluginCategories.all.contains(c) || c == "Dynamics" else { return nil }
            return (id, c)
        }, uniquingKeysWith: { a, _ in a })
        store.setCommunityCategories(agreed)
    }

    /// Once, after the update that made shared categories reach everyone: categories the user
    /// changed before can be shared too, if they agree (BL-104).
    static func offerEarlierCategories() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "share.categories.offered") else { return }
        let mine = PluginStore.shared.plugins.filter { $0.userCategory.map { !UserLibrary.shared.isMine($0) } ?? false }
        guard !mine.isEmpty else { d.set(true, forKey: "share.categories.offered"); return }
        NSApp.activate()
        let answer = Dialog.show("Share your \(mine.count) category change\(mine.count == 1 ? "" : "s") with everyone?",
            message: "Other AG PlugFinder users will then see these plugins in the categories you chose. Only the plugin names and the categories are sent.",
            choices: [.init(title: "Only This Mac", cancel: true), .init(title: "Everyone", primary: true)])
        d.set(true, forKey: "share.categories.offered")
        guard answer.index == 1 else { return }
        for (category, group) in Dictionary(grouping: mine, by: { $0.userCategory! }) { shareCategory(group, category) }
        Toast.show("Shared \(mine.count) category change\(mine.count == 1 ? "" : "s"). Thank you!")
    }

    /// Downloads approved pictures for these plugins, saves them like a picture the app took,
    /// and returns the ids it got. Silent on any failure: the app then takes the pictures itself.
    static func fetchApproved(_ ids: [String]) async -> Set<String> {
        guard let base, let key, !ids.isEmpty else { return [] }
        lookupFailed = false
        var request = URLRequest(url: base.appendingPathComponent("v1/lookup"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": Array(ids.prefix(2000))])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = json["available"] as? [[String: Any]] else { lookupFailed = true; return [] }
        lookupFailed = false
        let store = PluginStore.shared
        var got: Set<String> = []
        for entry in available {
            guard let id = entry["plugin_id"] as? String, ids.contains(id) else { continue }
            var get = URLRequest(url: base.appendingPathComponent("v1/pictures/\(id)"))
            get.timeoutInterval = 20
            get.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
            guard let (bytes, r) = try? await URLSession.shared.data(for: get),
                  (r as? HTTPURLResponse)?.statusCode == 200, bytes.count > 200,
                  NSImage(data: bytes) != nil else { continue }
            let url = store.snapshotURL(for: id)
            // Saved as PNG, like the pictures the app takes.
            let png: Data? = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? bytes
                : NSImage(data: bytes).flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            guard let png, (try? png.write(to: url)) != nil else { continue }
            pictureRev[id] = entry["picture_rev"] as? Int ?? 0
            store.update(id) { $0.snapshotState = .done; $0.snapshotError = nil }
            if let p = store.plugin(id) { sent[id] = p.version }   // came from the database: nothing to send back
            got.insert(id)
        }
        if !got.isEmpty { store.snapshotChanged() }
        return got
    }

    /// Plugins whose screenshot failed on this Mac (Logic's own never fail: they ship with the app).
    static var failedIDs: [String] {
        PluginStore.shared.plugins.filter { !$0.isBuiltIn && $0.snapshotState == .failed }.map(\.id)
    }

    /// The failed ones the user actually sees as a tile: not hidden, and for a joined mono and
    /// stereo plugin only the version that is shown. The button counts these.
    static var shownFailedIDs: [String] {
        let store = PluginStore.shared
        return store.plugins.filter {
            !$0.isBuiltIn && $0.snapshotState == .failed && store.isVisible($0) && PluginVariants.isShown($0)
        }.map(\.id)
    }

    /// Fix Failed Screenshots (BL-130): asks the shared database again for every plugin whose
    /// screenshot failed and downloads the pictures other users shared since. Only touches
    /// failed plugins; the rest of the library is never changed. Tells the user how many it fixed.
    static var fixing = false
    /// The last database lookup could not be made (offline, server down).
    private static var lookupFailed = false
    static func fixFailed() {
        let shown = shownFailedIDs
        guard !fixing, !shown.isEmpty else { return }
        // Hidden copies (the mono version behind a joined tile) are asked about too, quietly.
        let ids = failedIDs
        guard base != nil, key != nil else {
            Toast.show("The shared database isn't available in this build.", warning: true); return
        }
        fixing = true
        let n = shown.count
        Toast.show("Checking the database for \(n) failed screenshot\(n == 1 ? "" : "s")…", busy: true)
        Task {
            let got = await fetchApproved(ids).intersection(shown)
            fixing = false
            let left = n - got.count
            if got.isEmpty && lookupFailed {
                Toast.show("Couldn't reach the database. Check the internet connection and try again.", warning: true)
            } else if got.isEmpty {
                Toast.show("None of the \(n) failed screenshot\(n == 1 ? " is" : "s are") in the database yet. Try again later.", warning: true)
            } else if left == 0 {
                Toast.show("Fixed all \(n) failed screenshot\(n == 1 ? "" : "s") from the database.")
            } else {
                Toast.show("Fixed \(got.count) of \(n) failed screenshots. \(left) \(left == 1 ? "is" : "are") not in the database yet.")
            }
        }
    }

    /// A big plugin window makes a picture of several megabytes; it is sent as a JPEG at most
    /// 1600 pixels wide, which still looks sharp in the app (about 150 to 400 KB).
    static func compact(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let scale = min(1, 1600 / CGFloat(max(rep.pixelsWide, 1)))
        let w = max(1, Int(CGFloat(rep.pixelsWide) * scale)), h = max(1, Int(CGFloat(rep.pixelsHigh) * scale))
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let jpeg = small.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        return jpeg.flatMap { $0.count < 2_000_000 ? $0 : nil }
    }

    #if DEBUG
    static func compactForTest(_ d: Data) -> Int? { compact(d)?.count }
    #endif

    @discardableResult
    private static func send(_ p: Plugin) async -> Bool {
        guard sharing, !p.isBuiltIn, let base, let key, sent[p.id] != p.version else { return false }
        let file = PluginStore.shared.snapshotURL(for: p.id)
        guard let original = try? Data(contentsOf: file), let data = compact(original) else { return false }
        let body: [String: Any] = [
            "pluginId": p.id, "name": p.name, "manufacturer": p.manufacturer, "version": p.version,
            "category": p.category, "installId": installID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "picture": data.base64EncodedString(),
        ]
        var request = URLRequest(url: base.appendingPathComponent("v1/pictures"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        // Sent, or refused for good (not a picture, odd id): don't try this version again.
        if code == 201 || code == 400 || code == 413 { sent[p.id] = p.version }
        return code == 201
    }
}

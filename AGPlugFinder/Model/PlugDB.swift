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
            let todo = store.plugins.filter { !$0.isLogic && sent[$0.id] != $0.version }
            for p in todo.prefix(400) {
                guard sharing else { return }
                if await send(p) { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
    }

    /// Sends a category the user chose for these plugins, after they agreed (BL-82).
    static func shareCategory(_ plugins: [Plugin], _ category: String) {
        guard let base, let key, !plugins.isEmpty else { return }
        let body: [String: Any] = [
            "installId": installID, "category": category,
            "plugins": plugins.filter { !$0.isLogic }.prefix(500).map {
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

    /// Downloads approved pictures for these plugins, saves them like a picture the app took,
    /// and returns the ids it got. Silent on any failure: the app then takes the pictures itself.
    static func fetchApproved(_ ids: [String]) async -> Set<String> {
        guard let base, let key, !ids.isEmpty else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("v1/lookup"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": Array(ids.prefix(2000))])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = json["available"] as? [[String: Any]] else { return [] }
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
            store.update(id) { $0.snapshotState = .done; $0.snapshotError = nil }
            if let p = store.plugin(id) { sent[id] = p.version }   // came from the database: nothing to send back
            got.insert(id)
        }
        if !got.isEmpty { store.snapshotChanged() }
        return got
    }

    /// A big plugin window makes a picture of several megabytes; it is sent as a JPEG at most
    /// 1600 pixels wide, which still looks sharp in the app (about 150 to 400 KB).
    private static func compact(_ data: Data) -> Data? {
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
        guard sharing, !p.isLogic, let base, let key, sent[p.id] != p.version else { return false }
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

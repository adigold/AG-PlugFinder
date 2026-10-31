import Foundation

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

    @discardableResult
    private static func send(_ p: Plugin) async -> Bool {
        guard sharing, !p.isLogic, let base, let key, sent[p.id] != p.version else { return false }
        let file = PluginStore.shared.snapshotURL(for: p.id)
        guard let data = try? Data(contentsOf: file), data.count < 2_000_000 else { return false }
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

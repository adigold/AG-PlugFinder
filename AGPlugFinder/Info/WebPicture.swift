import AppKit

/// Finds a plugin's picture on the web when taking it failed (BL-80): the official product
/// image from the maker's own site, found with the online look-up (the user's own API key).
/// The picture is checked to be a real image before it is saved, and then shared like one the
/// app took.
@MainActor
enum WebPicture {
    private(set) static var running = 0

    static var available: Bool { PluginInfoFetcher.shared.hasKey }

    /// Looks up each plugin in turn and reports how many pictures it found.
    static func find(_ plugins: [Plugin]) {
        let list = plugins.filter { !$0.isLogic }
        guard !list.isEmpty else { return }
        guard let key = Keychain.read() else {
            Toast.show("Add your API key in Settings > Plugin info to find pictures on the web.", warning: true); return
        }
        let model = PluginInfoFetcher.shared.model
        running += list.count
        Toast.show("Looking for \(list.count == 1 ? list[0].name : "\(list.count) plugins") on the web…", busy: true)
        Task {
            var found = 0
            for p in list {
                if let data = await search(p, key: key, model: model), save(data, for: p) { found += 1 }
                running -= 1
            }
            Toast.show(found == 0 ? "No picture found on the web." :
                        "Found \(found) of \(list.count) picture\(list.count == 1 ? "" : "s") on the web.",
                       warning: found == 0)
        }
    }

    #if DEBUG
    /// Looks one plugin up and reports the picture's size, without saving or sharing it.
    static func probe(_ p: Plugin, to url: URL) async -> String {
        guard let key = Keychain.read() else { return "no API key" }
        guard let data = await search(p, key: key, model: PluginInfoFetcher.shared.model) else { return "nothing found" }
        try? data.write(to: url)
        let rep = NSBitmapImageRep(data: data)
        return "\(data.count) bytes, \(rep?.pixelsWide ?? 0)x\(rep?.pixelsHigh ?? 0)"
    }
    #endif

    private static func save(_ data: Data, for p: Plugin) -> Bool {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide >= 200, rep.pixelsHigh >= 120,
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let store = PluginStore.shared
        guard (try? png.write(to: store.snapshotURL(for: p.id))) != nil else { return false }
        store.update(p.id) { $0.snapshotState = .done; $0.snapshotError = nil }
        store.snapshotChanged()
        if let fresh = store.plugin(p.id) { PlugDB.share(fresh) }
        return true
    }

    private static let system = """
    You find the official product page of an audio plugin. Use web search to find the page on the \
    maker's own website (or a large shop like Plugin Boutique when the maker has none) for this \
    exact plugin. Answer with one JSON object and nothing else: {"page": the product page URL, \
    "image": a direct URL of the plugin's interface screenshot if the search results show one, \
    else ""}. Give "page": "" only if no page for this plugin exists.
    """

    nonisolated private static func search(_ p: Plugin, key: String, model: PluginInfoFetcher.Model) async -> Data? {
        var messages: [[String: Any]] = [[
            "role": "user",
            "content": "Audio plugin \"\(p.name)\" by \(p.manufacturer), \(p.typeName), version \(p.version).",
        ]]
        for _ in 0..<4 {
            let body: [String: Any] = [
                "model": model.rawValue, "max_tokens": 2000, "system": system,
                "output_config": ["effort": "low"], "fallbacks": "default",
                "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 3]],
                "messages": messages,
            ]
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { note("no answer"); return nil }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                note("status \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"); return nil
            }
            let content = json["content"] as? [[String: Any]] ?? []
            if json["stop_reason"] as? String == "pause_turn" {
                messages.append(["role": "assistant", "content": content]); continue
            }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            note("answer: \(text.suffix(200))")
            if let b = content.first(where: { $0["type"] as? String == "web_search_tool_result" }),
               let items = b["content"] as? [[String: Any]] {
                note("result items: " + items.prefix(6).map { "\($0["title"] ?? "-") | \($0["url"] ?? "-")" }.joined(separator: " || "))
            }
            let obj = text.firstIndex(of: "{").flatMap { start in text.lastIndex(of: "}").flatMap { end in
                (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] } } ?? [:]
            // The product page's own preview image (og:image) first: the maker picked it.
            if let page = (obj["page"] as? String).flatMap(URL.init(string:)), let img = await ogImage(page),
               let d = await download(img) { return d }
            if let img = (obj["image"] as? String).flatMap(URL.init(string:)), let d = await download(img) { return d }
            // Else the search results themselves: pages whose title names the plugin, the maker's own first.
            for page in resultPages(content, p).prefix(4) {
                note("trying \(page)")
                if let img = await ogImage(page), let d = await download(img) { return d }
            }
            return nil
        }
        return nil
    }

    nonisolated private static func resultPages(_ content: [[String: Any]], _ p: Plugin) -> [URL] {
        let name = p.name.lowercased().replacingOccurrences(of: " ", with: "")
        let maker = p.manufacturer.lowercased().replacingOccurrences(of: " ", with: "")
        var found: [(URL, Int)] = []
        for block in content where block["type"] as? String == "web_search_tool_result" {
            for r in block["content"] as? [[String: Any]] ?? [] {
                guard let s = r["url"] as? String, let url = URL(string: s), url.scheme == "https" else { continue }
                let title = (r["title"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                let host = url.host?.lowercased() ?? ""
                guard title.contains(name) || url.path.lowercased().replacingOccurrences(of: "-", with: "").contains(name) else { continue }
                // The maker's own site first, then shops, never video or forum sites.
                if ["youtube", "reddit", "facebook", "instagram", "gearspace", "kvr"].contains(where: host.contains) { continue }
                let score = (host.replacingOccurrences(of: "-", with: "").contains(maker.prefix(6)) ? 0 : 1)
                if !found.contains(where: { $0.0 == url }) { found.append((url, score)) }
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    nonisolated private static func note(_ s: String) {
        #if DEBUG
        print("WEB " + s); fflush(stdout)
        #endif
    }

    /// Only an https image of a sensible size.
    nonisolated private static func download(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.setValue("Mozilla/5.0 (Macintosh) AG PlugFinder", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              data.count > 5_000, data.count < 15_000_000 else { note("image refused: \(url)"); return nil }
        return data
    }

    nonisolated private static func ogImage(_ page: URL) async -> URL? {
        guard page.scheme == "https" else { return nil }
        var r = URLRequest(url: page)
        r.timeoutInterval = 30
        r.setValue("Mozilla/5.0 (Macintosh) AG PlugFinder", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1)
        else { return nil }
        let pattern = #"<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']|<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for i in 1...2 {
            if let range = Range(m.range(at: i), in: html) {
                return URL(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL
            }
        }
        return nil
    }
}

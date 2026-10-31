import AppKit
import SwiftUI

/// Finds a plugin's picture on the web when taking it failed (BL-80). Several candidates are
/// collected (the maker's product page, shops, the pages the search found) and shown side by
/// side; the user clicks the right one. Uses the online look-up's web search (the user's own
/// API key). A chosen picture is saved and shared like one the app took.
@MainActor
enum WebPicture {
    /// The quick search needs no key; the slower AI search is used only with one.
    static var available: Bool { true }

    /// Opens the chooser for each plugin in turn.
    static func find(_ plugins: [Plugin]) {
        let list = plugins.filter { !$0.isLogic }
        guard !list.isEmpty else { return }
        WebPictureWindow.shared.show(list)
    }

    static func save(_ data: Data, for p: Plugin) -> Bool {
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
    You help find pictures of an audio plugin's interface. Use web search to find pages about this \
    exact plugin: the maker's own product page first, then large shops (Plugin Boutique, Sweetwater, \
    Thomann, KVR) and reviews. Answer with one JSON object and nothing else: {"pages": up to 5 page \
    URLs about this plugin, "images": up to 6 direct image URLs that show the plugin's interface}. \
    Use empty lists when you find nothing.
    """

    /// The quick way (about 2 seconds): an ordinary web search for the plugin's pages, then each
    /// page's pictures, all at once. Each picture is handed over as soon as it has arrived.
    nonisolated static func quick(_ p: Plugin, found: @escaping @Sendable (Data) async -> Void) async -> Int {
        let q = "\(p.name) \(p.manufacturer) plugin"
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var r = URLRequest(url: comps.url!)
        r.timeoutInterval = 10
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let html = String(data: data, encoding: .utf8) else { return 0 }
        var pages: [URL] = []
        if let re = try? NSRegularExpression(pattern: #"class="result__a" href="([^"]+)""#) {
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(m.range(at: 1), in: html) else { continue }
                var link = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                // Some results come wrapped in a redirect: the real address is in uddg.
                if let c = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link),
                   let real = c.queryItems?.first(where: { $0.name == "uddg" })?.value { link = real }
                guard let url = URL(string: link), url.scheme == "https" else { continue }
                let host = url.host?.lowercased() ?? ""
                if ["youtube", "reddit", "facebook", "instagram", "tiktok", "duckduckgo"].contains(where: host.contains) { continue }
                if !pages.contains(url) { pages.append(url) }
                if pages.count >= 7 { break }
            }
        }
        note("quick pages: \(pages.count)")
        return await collect(pages: pages, images: [], p, found: found)
    }

    /// Opens the pages at once and hands over every new picture as soon as it arrives.
    nonisolated private static func collect(pages: [URL], images: [URL], _ p: Plugin,
                                            found: @escaping @Sendable (Data) async -> Void) async -> Int {
        let seen = SeenSet()
        return await withTaskGroup(of: Int.self) { group in
            for url in images {
                group.addTask { await deliver(url, seen, found) ? 1 : 0 }
            }
            for page in pages.prefix(7) {
                group.addTask {
                    var n = 0
                    for url in await pageImages(page, p) where await deliver(url, seen, found) { n += 1 }
                    return n
                }
            }
            var total = 0
            for await n in group { total += n }
            return total
        }
    }

    nonisolated private static func deliver(_ url: URL, _ seen: SeenSet, _ found: @Sendable (Data) async -> Void) async -> Bool {
        guard await seen.claim(url.absoluteString), let d = await download(url),
              let rep = NSBitmapImageRep(data: d), rep.pixelsWide >= 300, rep.pixelsHigh >= 150,
              await seen.claim("\(rep.pixelsWide)x\(rep.pixelsHigh)-\(d.count / 1000)") else { return false }
        await found(d)
        return true
    }

    /// Up to 9 different pictures of the plugin from the web, best first.
    nonisolated static func candidates(_ p: Plugin, key: String, model: PluginInfoFetcher.Model) async -> [Data] {
        var images: [URL] = []
        var pages: [URL] = []
        var messages: [[String: Any]] = [[
            "role": "user",
            "content": "Audio plugin \"\(p.name)\" by \(p.manufacturer), \(p.typeName), version \(p.version).",
        ]]
        for _ in 0..<4 {
            let body: [String: Any] = [
                "model": model.rawValue, "max_tokens": 3000, "system": system,
                "output_config": ["effort": "low"], "fallbacks": "default",
                "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 4]],
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
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { note("no answer"); break }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                note("status \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"); break
            }
            let content = json["content"] as? [[String: Any]] ?? []
            pages += resultPages(content, p)
            if json["stop_reason"] as? String == "pause_turn" {
                messages.append(["role": "assistant", "content": content]); continue
            }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            note("answer: \(text.suffix(300))")
            if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
               let obj = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] {
                images += (obj["images"] as? [String] ?? []).compactMap(URL.init(string:))
                pages = (obj["pages"] as? [String] ?? []).compactMap(URL.init(string:)) + pages
            }
            break
        }
        // Each page's own pictures: its preview image and big pictures that name the plugin.
        var seenPages: Set<String> = []
        let uniquePages = pages.filter { $0.scheme == "https" && seenPages.insert($0.absoluteString).inserted }.prefix(6)
        let fromPages = await withTaskGroup(of: (Int, [URL]).self) { group in
            for (i, page) in uniquePages.enumerated() { group.addTask { (i, await pageImages(page, p)) } }
            var all: [(Int, [URL])] = []
            for await r in group { all.append(r) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<String> = []
        let urls = (fromPages + images).filter { $0.scheme == "https" && seen.insert($0.absoluteString).inserted }.prefix(16)
        note("candidate links: \(urls.count) from \(uniquePages.count) pages")
        let downloaded = await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, url) in urls.enumerated() { group.addTask { (i, await download(url)) } }
            var all: [(Int, Data)] = []
            for await (i, d) in group { if let d { all.append((i, d)) } }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // Real pictures only, big enough to show a plugin, each once.
        var sizes: Set<String> = []
        return Array(downloaded.filter { d in
            guard let rep = NSBitmapImageRep(data: d), rep.pixelsWide >= 300, rep.pixelsHigh >= 150 else { return false }
            return sizes.insert("\(rep.pixelsWide)x\(rep.pixelsHigh)-\(d.count / 1000)").inserted
        }.prefix(9))
    }

    nonisolated private static func note(_ s: String) {
        #if DEBUG
        print("WEB " + s); fflush(stdout)
        #endif
    }

    /// Pages from the search results whose title or address names the plugin.
    nonisolated private static func resultPages(_ content: [[String: Any]], _ p: Plugin) -> [URL] {
        let name = p.name.lowercased().replacingOccurrences(of: " ", with: "")
        var out: [URL] = []
        for block in content where block["type"] as? String == "web_search_tool_result" {
            for r in block["content"] as? [[String: Any]] ?? [] {
                guard let s = r["url"] as? String, let url = URL(string: s), url.scheme == "https" else { continue }
                let title = (r["title"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                let host = url.host?.lowercased() ?? ""
                if ["youtube", "reddit", "facebook", "instagram", "gearspace", "tiktok"].contains(where: host.contains) { continue }
                if title.contains(name) || url.path.lowercased().replacingOccurrences(of: "-", with: "").contains(name) {
                    out.append(url)
                }
            }
        }
        return out
    }

    /// A page's preview images (og:image, twitter:image) and pictures whose address or caption
    /// names the plugin.
    nonisolated private static func pageImages(_ page: URL, _ p: Plugin) async -> [URL] {
        var r = URLRequest(url: page)
        r.timeoutInterval = 20
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let html = String(data: data.prefix(600_000), encoding: .utf8) ?? String(data: data.prefix(600_000), encoding: .isoLatin1)
        else { return [] }
        var out: [URL] = []
        func grab(_ pattern: String, limit: Int, filter: ((String) -> Bool)? = nil) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                for i in 1..<m.numberOfRanges {
                    guard let range = Range(m.range(at: i), in: html) else { continue }
                    let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                    if let f = filter, !f(raw.lowercased()) { continue }
                    if let u = URL(string: raw, relativeTo: page)?.absoluteURL, !out.contains(u) { out.append(u) }
                    if out.count >= limit { return }
                }
            }
        }
        grab(#"<meta[^>]+(?:property|name)=["'](?:og:image(?::secure_url)?|twitter:image)["'][^>]+content=["']([^"']+)["']|<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']"#, limit: 2)
        let words = p.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        grab(#"<img[^>]+(?:src|data-src)=["']([^"']+\.(?:png|jpe?g|webp)[^"']*)["']"#, limit: 5) { src in
            !src.contains("logo") && !src.contains("icon") && words.contains(where: { src.contains($0) })
        }
        return out
    }

    /// Only an https image of a sensible size.
    nonisolated private static func download(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              data.count > 5_000, data.count < 15_000_000 else { return nil }
        return data
    }

    #if DEBUG
    static func probe(_ p: Plugin, to url: URL) async -> String {
        let start = Date()
        let box = DataBox()
        _ = await quick(p) { d in await box.add(d) }
        let found = await box.all
        note("quick took \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        for (i, d) in found.enumerated() { try? d.write(to: url.appendingPathExtension("\(i)")) }
        return "\(found.count) pictures: " + found.map { d in
            let r = NSBitmapImageRep(data: d); return "\(r?.pixelsWide ?? 0)x\(r?.pixelsHigh ?? 0)"
        }.joined(separator: ", ")
    }
    #endif
}

/// "Choose a picture for X": the web's candidates side by side; a click saves one.
@MainActor
final class WebPictureWindow {
    static let shared = WebPictureWindow()
    private var window: NSWindow?
    private let state = WebPictureState()

    func show(_ plugins: [Plugin]) {
        state.queue += plugins
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: WebPictureView(state: state) { [weak self] in self?.window?.close() })
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if state.current == nil { state.next() }
    }
}

@MainActor
@Observable
final class WebPictureState {
    var queue: [Plugin] = []
    var current: Plugin?
    var pictures: [Data] = []
    var searching = false

    func next() {
        guard !queue.isEmpty else { current = nil; pictures = []; return }
        let p = queue.removeFirst()
        current = p
        pictures = []
        searching = true
        Task {
            // Quick search first; pictures appear one by one as they arrive.
            let n = await WebPicture.quick(p) { data in
                await MainActor.run {
                    if self.current?.id == p.id, self.pictures.count < 12 { self.pictures.append(data) }
                }
            }
            guard current?.id == p.id else { return }
            // Nothing quick: the slower AI search, only when there is an API key.
            if n == 0, let key = Keychain.read() {
                let more = await WebPicture.candidates(p, key: key, model: PluginInfoFetcher.shared.model)
                guard current?.id == p.id else { return }
                pictures += more
            }
            searching = false
        }
    }
}

struct WebPictureView: View {
    var state: WebPictureState
    var close: () -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = state.current {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a picture for \(p.name)").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                    Text(p.manufacturer + (state.queue.isEmpty ? "" : " · \(state.queue.count) more after this"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 18)
                if state.searching && state.pictures.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("Looking on the web…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.pictures.isEmpty {
                    Text("No pictures of \(p.name) were found on the web.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(Array(state.pictures.enumerated()), id: \.offset) { i, data in
                                if let image = NSImage(data: data) {
                                    Button { choose(data, p) } label: {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(maxWidth: .infinity).frame(height: 140)
                                            .background(Color.black)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(hovered == i ? Theme.accent : Theme.rule, lineWidth: hovered == i ? 2 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                                    .help("Use this picture")
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if state.searching { ProgressView().controlSize(.small) }
                        Text(state.searching ? "More pictures are coming. Click the one that shows the plugin."
                             : "Click the picture that shows the plugin.")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                }
                HStack(spacing: 8) {
                    // Google Images in the browser; drag a picture back here, or copy it and Paste.
                    PrimaryPill(title: "Search Google Images", systemImage: "magnifyingglass", height: 30) { google(p) }
                    QuietPill(title: "Paste Image", systemImage: "doc.on.clipboard", height: 30) { paste(p) }
                    Text("or drag a picture here").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Spacer()
                    QuietPill(title: state.queue.isEmpty ? "None of These" : "Skip, Next Plugin", height: 30) {
                        if state.queue.isEmpty { state.current = nil; close() } else { state.next() }
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .frame(width: 760, height: 620)
        .onDrop(of: [.image, .url, .fileURL], isTargeted: nil) { providers in
            guard let p = state.current else { return false }
            return dropped(providers, p)
        }
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }

    private func google(_ p: Plugin) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "tbm", value: "isch"),
                        URLQueryItem(name: "q", value: "\(p.name) \(p.manufacturer) plugin")]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func paste(_ p: Plugin) {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            choose(tiff, p)
        } else if let s = pb.string(forType: .string), let url = URL(string: s), url.scheme == "https" {
            take(url, p)
        } else {
            Toast.show("Copy a picture first: right-click it in the browser and choose Copy Image.", warning: true)
        }
    }

    /// A picture dropped from the browser: the image itself, or its address.
    private func dropped(_ providers: [NSItemProvider], _ p: Plugin) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let tiff = (obj as? NSImage)?.tiffRepresentation {
                        DispatchQueue.main.async { choose(tiff, p) }
                    }
                }
                return true
            }
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { take(url, p) } }
                }
                return true
            }
        }
        return false
    }

    private func take(_ url: URL, _ p: Plugin) {
        if url.isFileURL, let d = try? Data(contentsOf: url), NSImage(data: d) != nil { choose(d, p); return }
        Task {
            if let (d, _) = try? await URLSession.shared.data(from: url), NSImage(data: d) != nil { choose(d, p) }
            else { Toast.show("That link isn't a picture. Drag the picture itself.", warning: true) }
        }
    }

    private func choose(_ data: Data, _ p: Plugin) {
        if WebPicture.save(data, for: p) { Toast.show("Saved the picture for \(p.name)") }
        if state.queue.isEmpty { state.current = nil; close() } else { state.next() }
    }
}


/// Addresses and picture sizes already handed over, shared by the parallel downloads.
actor SeenSet {
    private var seen: Set<String> = []
    func claim(_ key: String) -> Bool { seen.insert(key).inserted }
}

#if DEBUG
actor DataBox {
    private(set) var all: [Data] = []
    func add(_ d: Data) { all.append(d) }
}
#endif

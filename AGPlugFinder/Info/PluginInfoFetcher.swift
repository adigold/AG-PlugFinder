import Foundation
import Observation

/// Looks each plugin up on the web with the Claude API (web search) and stores a short summary,
/// its best feature and a category. Runs only when the user presses "Look up info"; each plugin
/// is looked up once and the result is cached in the catalog.
@MainActor
@Observable
final class PluginInfoFetcher {
    static let shared = PluginInfoFetcher()

    enum Model: String, CaseIterable, Identifiable {
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        var id: String { rawValue }
        var title: String { self == .opus ? "Claude Opus 5.5" : "Claude Sonnet 5.5" }
        /// Rough cost per plugin in US dollars: tokens plus up to 3 web searches ($10 / 1,000).
        var estimatedCostPerPlugin: Double { self == .opus ? 0.10 : 0.06 }
    }

    /// Where descriptions come from (BL-50): the web lookup with the user's key (most accurate),
    /// the Mac's built-in model, or the downloaded model. The two free ones need no key.
    enum Source: String, CaseIterable, Identifiable {
        case online, builtIn, downloaded
        var id: String { rawValue }
        /// The choices this build offers.
        static var offered: [Source] {
            #if LOCAL_MODEL
            return allCases
            #else
            return [.online, .builtIn]
            #endif
        }
        var title: String {
            switch self {
            case .online: return "Most accurate"
            case .builtIn: return "Free, built into this Mac"
            case .downloaded: return "Free, downloaded model"
            }
        }
    }

    var source: Source {
        get {
            if let s = Source(rawValue: UserDefaults.standard.string(forKey: "infoSource") ?? "") { return s }
            if hasKey { return .online }
            if OnDeviceInfo.status == .ready { return .builtIn }
            #if LOCAL_MODEL
            return LocalModel.shared.state == .ready ? .downloaded : .online
            #else
            return .online
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "infoSource") }
    }

    /// True when the chosen source can run now.
    var canLookUp: Bool {
        switch source {
        case .online: return hasKey
        case .builtIn: return OnDeviceInfo.status == .ready
        case .downloaded:
            #if LOCAL_MODEL
            return LocalModel.shared.state == .ready
            #else
            return false
            #endif
        }
    }

    var isFree: Bool { source != .online }

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var failures: [String: String] = [:]
    private(set) var lastError: String?
    private var cancelled = false

    var model: Model {
        get { Model(rawValue: UserDefaults.standard.string(forKey: "infoModel") ?? "") ?? .opus }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "infoModel") }
    }

    var hasKey: Bool { Keychain.read() != nil }

    func missingCount() -> Int { PluginStore.shared.plugins.filter { $0.details == nil }.count }

    /// Looks up the given plugins (default: every plugin with no info yet).
    func start(ids: [String]? = nil) {
        guard !isRunning else { return }
        let source = self.source
        let key = Keychain.read() ?? ""
        guard canLookUp else {
            switch source {
            case .online: lastError = "Add your API key in Settings, or choose a free option there."
            case .builtIn: lastError = "The Mac's built-in model isn't available. Choose another option in Settings."
            case .downloaded: lastError = "Download the free model in Settings first."
            }
            return
        }
        let store = PluginStore.shared
        let todo: [Plugin]
        if let ids {
            let wanted = Set(ids)
            todo = store.plugins.filter { wanted.contains($0.id) }
        } else {
            todo = store.plugins.filter { $0.details == nil }
        }
        guard !todo.isEmpty else { return }
        isRunning = true
        cancelled = false
        lastError = nil
        done = 0
        total = todo.count
        let model = self.model
        Task {
            // Online: two at a time keeps it quick without hitting rate limits. On the Mac: one
            // at a time, the model uses the whole machine.
            var index = 0
            while index < todo.count, !cancelled {
                let batch = Array(todo[index..<min(index + (source == .online ? 2 : 1), todo.count)])
                index += batch.count
                var results: [(String, Result<PluginDetails, Error>)] = []
                switch source {
                case .online:
                    results = await withTaskGroup(of: (String, Result<PluginDetails, Error>).self) { group in
                        for p in batch { group.addTask { (p.id, await Self.lookUp(p, key: key, model: model)) } }
                        var out: [(String, Result<PluginDetails, Error>)] = []
                        for await r in group { out.append(r) }
                        return out
                    }
                case .builtIn:
                    for p in batch { results.append((p.id, await OnDeviceInfo.lookUp(p))) }
                case .downloaded:
                    #if LOCAL_MODEL
                    for p in batch { results.append((p.id, await LocalModel.shared.lookUp(p))) }
                    #endif
                    break
                }
                for (id, result) in results {
                    switch result {
                    case .success(let details):
                        store.update(id) { $0.details = details }
                        failures[id] = nil
                    case .failure(let error):
                        failures[id] = error.localizedDescription
                        lastError = error.localizedDescription
                        if case LookupError.auth = error { cancelled = true }
                    }
                    done += 1
                }
            }
            isRunning = false
        }
    }

    func cancel() { cancelled = true }

    // MARK: API call

    enum LookupError: LocalizedError {
        case auth, http(Int, String), refused, unreadable
        var errorDescription: String? {
            switch self {
            case .auth: return "The Anthropic API key was not accepted."
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .refused: return "Claude declined to answer for this plugin."
            case .unreadable: return "Could not read Claude's answer."
            }
        }
    }

    nonisolated private static let system = """
    You research audio plugins for a music producer who works in Logic Pro. Use web search to \
    find what the plugin is and what it does best. Answer with one JSON object and nothing else:
    {"category": one or two words such as Reverb, Delay, EQ, Compressor, Limiter, Saturation, \
    Modulation, Pitch, Filter, Utility, Synth, Sampler, Drums, MIDI FX,
     "kind": a short phrase such as "Algorithmic plate reverb",
     "summary": two plain sentences on what it does and when to reach for it,
     "bestFeature": one sentence naming the single thing it does best,
     "highlights": up to three short phrases}
    If you cannot find the plugin, describe it from its name and maker and say so in summary.
    """

    nonisolated static func lookUp(_ p: Plugin, key: String,
                                   model: Model) async -> Result<PluginDetails, Error> {
        var messages: [[String: Any]] = [[
            "role": "user",
            "content": "Audio Unit plugin: \"\(p.name)\" by \(p.manufacturer). Type: \(p.typeName). " +
                "Version \(p.version). Tags: \(p.tags.joined(separator: ", "))."
        ]]
        do {
            // Server-side web search can pause a long turn; continue it up to 3 times.
            for _ in 0..<4 {
                let body: [String: Any] = [
                    "model": model.rawValue,
                    "max_tokens": 8000,
                    "system": system,
                    "output_config": ["effort": "low"],
                    "fallbacks": "default",
                    "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 3]],
                    "messages": messages,
                ]
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 180
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if status == 401 || status == 403 { throw LookupError.auth }
                guard status == 200 else {
                    let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
                    throw LookupError.http(status, msg)
                }
                let content = json["content"] as? [[String: Any]] ?? []
                switch json["stop_reason"] as? String {
                case "refusal":
                    throw LookupError.refused
                case "pause_turn":
                    messages.append(["role": "assistant", "content": content])
                    continue
                default:
                    let text = content.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined()
                    guard let details = parse(text) else { throw LookupError.unreadable }
                    return .success(details)
                }
            }
            throw LookupError.unreadable
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func parse(_ text: String) -> PluginDetails? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func s(_ k: String) -> String {
            (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s("summary").isEmpty else { return nil }
        return PluginDetails(category: s("category"), kind: s("kind"), summary: s("summary"),
                             bestFeature: s("bestFeature"),
                             highlights: (obj["highlights"] as? [String] ?? []).prefix(3).map { $0 },
                             fetchedAt: Date())
    }
}

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Free plugin descriptions with the Mac's own built-in model (BL-50, option 1): nothing to
/// download, nothing leaves the Mac. Needs a Mac where Apple Intelligence is on. It can't search
/// the web, so it describes a plugin from its name, maker, type and tags.
enum OnDeviceInfo {
    enum Status: Equatable {
        case ready
        case notSupported      // this Mac or macOS can't run it
        case turnedOff         // Apple Intelligence is off in System Settings
        case preparing         // the model is still downloading by the system
        case unavailable(String)
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.deviceNotEligible): return .notSupported
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .preparing
            case .unavailable(let other): return .unavailable("\(other)")
            }
        }
        #endif
        return .notSupported
    }

    static let instructions = """
    You describe audio plugins for a music producer who works in Logic Pro. You cannot browse \
    the web: use what you know about the plugin and its maker, and when you are not sure, describe \
    it from its name, type and tags without inventing specific features.
    """

    static func prompt(for p: Plugin) -> String {
        "Audio plugin: \"\(p.name)\" by \(p.manufacturer). Type: \(p.typeName). " +
            "Category so far: \(p.displayCategory). Tags: \(p.tags.joined(separator: ", "))."
    }

    static func lookUp(_ p: Plugin) async -> Result<PluginDetails, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let r = try await session.respond(to: prompt(for: p), generating: GeneratedInfo.self)
                let g = r.content
                return .success(PluginDetails(category: g.category, kind: g.kind, summary: g.summary,
                                              bestFeature: g.bestFeature, highlights: Array(g.highlights.prefix(3)),
                                              fetchedAt: Date()))
            } catch {
                return .failure(error)
            }
        }
        #endif
        return .failure(PluginInfoFetcher.LookupError.unreadable)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedInfo {
    @Guide(description: "One or two words, such as Reverb, Delay, EQ, Compressor, Saturation, Synth, Sampler, Utility")
    var category: String
    @Guide(description: "A short phrase, such as Algorithmic plate reverb")
    var kind: String
    @Guide(description: "Two plain sentences: what it does and when to reach for it")
    var summary: String
    @Guide(description: "One sentence naming the single thing it does best")
    var bestFeature: String
    @Guide(description: "Up to three short phrases", .maximumCount(3))
    var highlights: [String]
}
#endif

import SwiftUI

/// Settings: where plugin descriptions come from (BL-50).
struct InfoSourcePicker: View {
    var fetcher = PluginInfoFetcher.shared
    var local = LocalModel.shared
    @State private var source = PluginInfoFetcher.shared.source

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PluginInfoFetcher.Source.allCases) { s in
                Button { source = s; fetcher.source = s } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: source == s ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(source == s ? Theme.accent : Theme.faint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(detail(s)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        trailing(s)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(source == s ? Theme.raised : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detail(_ s: PluginInfoFetcher.Source) -> String {
        switch s {
        case .online:
            return "Searches the web for each plugin. Uses your own API key, about 6 to 10 cents per plugin."
        case .builtIn:
            switch OnDeviceInfo.status {
            case .ready: return "Free and private, nothing to download. Describes plugins from their name and maker, without the web."
            case .turnedOff: return "Turn on Apple Intelligence in System Settings to use it."
            case .preparing: return "Your Mac is still getting it ready. Try again in a little while."
            case .notSupported: return "Not available on this Mac. Use the downloaded model instead."
            case .unavailable: return "Not available right now."
            }
        case .downloaded:
            return "Free and private, works offline. A one-time download of \(LocalModel.sizeText). Describes plugins from their name and maker, without the web."
        }
    }

    @ViewBuilder private func trailing(_ s: PluginInfoFetcher.Source) -> some View {
        if s == .downloaded {
            switch local.state {
            case .notDownloaded, .failed:
                QuietPill(title: "Download", systemImage: "arrow.down.circle", height: 26) {
                    source = .downloaded; fetcher.source = .downloaded
                    Task { await local.download() }
                }
            case .downloading(let f):
                HStack(spacing: 8) {
                    ProgressView(value: f).frame(width: 80).tint(Theme.accent)
                    Text("\(Int(f * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted)
                }
            case .ready:
                Button("Remove") { local.remove() }.font(.system(size: 11))
            }
        } else if s == .builtIn, OnDeviceInfo.status == .ready {
            Text("Ready").font(.system(size: 11)).foregroundStyle(.green)
        }
    }
}

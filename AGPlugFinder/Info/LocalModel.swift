import Foundation
import Observation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Free plugin descriptions with a small model downloaded once to this Mac (BL-50, option 2).
/// For Macs without the built-in model. It runs on the Mac, offline, after the download. Like
/// the built-in one it can't search the web.
@MainActor
@Observable
final class LocalModel {
    static let shared = LocalModel()
    static let repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    static let sizeText = "about 1.8 GB"

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State
    private var container: ModelContainer?

    private init() {
        state = UserDefaults.standard.bool(forKey: "localModel.downloaded") ? .ready : .notDownloaded
    }

    var isDownloading: Bool { if case .downloading = state { return true }; return false }

    /// Where the download lives (the shared model cache in the home folder).
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }

    func download() async {
        guard !isDownloading else { return }
        state = .downloading(0)
        do {
            container = try await load()
            UserDefaults.standard.set(true, forKey: "localModel.downloaded")
            state = .ready
        } catch {
            state = .failed("The download did not finish. Check the internet connection and try again.")
        }
    }

    func remove() {
        container = nil
        try? FileManager.default.removeItem(at: Self.folder)
        UserDefaults.standard.set(false, forKey: "localModel.downloaded")
        state = .notDownloaded
    }

    private func load() async throws -> ModelContainer {
        try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: Self.repo)
        ) { progress in
            let f = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = LocalModel.shared.state { LocalModel.shared.state = .downloading(f) }
            }
        }
    }

    func lookUp(_ p: Plugin) async -> Result<PluginDetails, Error> {
        do {
            if container == nil { container = try await load() }
            guard let container else { throw PluginInfoFetcher.LookupError.unreadable }
            let session = ChatSession(container, instructions: OnDeviceInfo.instructions + """
                 Answer with one JSON object and nothing else: {"category": one or two words, \
                "kind": a short phrase, "summary": two plain sentences, "bestFeature": one sentence, \
                "highlights": up to three short phrases}
                """,
                generateParameters: GenerateParameters(maxTokens: 500, temperature: 0.3))
            let text = try await session.respond(to: OnDeviceInfo.prompt(for: p))
            guard let details = PluginInfoFetcher.parse(text) else { throw PluginInfoFetcher.LookupError.unreadable }
            return .success(details)
        } catch {
            return .failure(error)
        }
    }
}

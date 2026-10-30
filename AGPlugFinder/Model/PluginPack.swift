import AppKit
import Foundation
import Observation

/// The plugin pack (BL-22): plugin pictures and looked-up info published with each GitHub
/// release, so a new install can fill its library without opening every plugin itself.
/// Only fills gaps: a picture or description the user already has is never replaced.
///
/// Pack layout (plugin-pack.zip): `screenshots/<plugin id>.jpg` and `info.json` ({id: details}).
@MainActor
@Observable
final class PluginPack {
    static let shared = PluginPack()

    enum State: Equatable {
        case idle, working
        case finished(pictures: Int, info: Int)
        case failed(String)
    }

    private(set) var state: State = .idle

    var packURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "AGPFPluginPackURL") as? String).flatMap(URL.init(string:))
    }

    /// Downloads the pack and copies in what is missing. Quiet mode never shows an error
    /// (first run without internet, or no pack published yet).
    @discardableResult
    func install() async -> Bool {
        guard state != .working, let packURL else { return false }
        state = .working
        do {
            let (pictures, info) = try await downloadAndApply(packURL)
            state = .finished(pictures: pictures, info: info)
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private struct PackError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func downloadAndApply(_ url: URL) async throws -> (Int, Int) {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw PackError(code == 404 ? "No plugin pack has been published yet." : "Download failed (\(code)).")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard size > 0, size < 300_000_000 else { throw PackError("The plugin pack is not valid.") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("agpf-pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tmp.path, work.path]
        try unzip.run()
        await withCheckedContinuation { c in
            DispatchQueue.global().async { unzip.waitUntilExit(); c.resume() }
        }
        guard unzip.terminationStatus == 0 else { throw PackError("The plugin pack could not be opened.") }

        let store = PluginStore.shared
        let known = Set(store.plugins.map(\.id))

        // Pictures: only for installed plugins that have none yet.
        var pictures = 0
        let shots = work.appendingPathComponent("screenshots")
        for file in (try? FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)) ?? [] {
            let id = file.deletingPathExtension().lastPathComponent
            guard ["jpg", "png"].contains(file.pathExtension.lowercased()), known.contains(id),
                  !store.hasScreenshot(id),
                  let image = NSImage(contentsOf: file), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: store.snapshotURL(for: id), options: .atomic)) != nil
            else { continue }
            store.update(id) { $0.snapshotState = .done; $0.snapshotError = nil }
            pictures += 1
        }

        // Info: only for plugins without a description.
        var info = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        if let data = try? Data(contentsOf: work.appendingPathComponent("info.json")),
           let map = try? decoder.decode([String: PluginDetails].self, from: data) {
            for (id, details) in map where known.contains(id) && store.plugin(id)?.details == nil {
                store.update(id) { $0.details = details }
                info += 1
            }
        }
        store.snapshotChanged()
        return (pictures, info)
    }
}

import Foundation
import Observation

/// Captures plugin screenshots one at a time, each in its own helper process with a time limit.
@MainActor
@Observable
final class SnapshotQueue {
    static let shared = SnapshotQueue()

    /// One plugin in the current run, for the progress window.
    struct Item: Identifiable, Equatable {
        enum Status: Equatable { case waiting, working, done, generic, noUI, failed(String), skipped }
        let id: String
        let name: String
        let maker: String
        var status: Status = .waiting
        var seconds: Double?
    }

    private(set) var isRunning = false
    private(set) var items: [Item] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var currentID: String?
    private var cancelled = false

    var total: Int { items.count }
    var done: Int { items.filter { ![.waiting, .working].contains($0.status) }.count }
    var currentName: String { items.first { $0.id == currentID }?.name ?? "" }
    var succeeded: Int { items.filter { $0.status == .done }.count }
    var failed: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var withoutWindow: Int { items.filter { $0.status == .noUI }.count }
    var cancelledRun: Bool { cancelled }

    /// Average seconds per plugin so far times what is left.
    var secondsLeft: Double? {
        let timed = items.compactMap(\.seconds)
        guard !timed.isEmpty, isRunning else { return nil }
        let left = items.filter { $0.status == .waiting || $0.status == .working }.count
        return timed.reduce(0, +) / Double(timed.count) * Double(left)
    }

    /// Captures every plugin that has no screenshot yet (or all of them when `force` is true).
    func start(force: Bool = false, only ids: Set<String>? = nil) {
        guard !isRunning else { return }
        let store = PluginStore.shared
        let todo = store.plugins
            .filter { p in
                guard !p.isLogic else { return false }
                if let ids { return ids.contains(p.id) }
                if force { return true }
                // Never re-capture a plugin whose picture is already on disk.
                let hasImage = FileManager.default.fileExists(atPath: store.snapshotURL(for: p.id).path)
                // A plugin that failed once is not tried again on every scan (it may show a popup
                // each time); Retry or Retake Screenshot still try it on request.
                switch p.snapshotState {
                case .pending, .done: return !hasImage
                case .failed, .noUI, .builtIn: return false
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !todo.isEmpty else { return }
        isRunning = true
        cancelled = false
        startedAt = Date()
        finishedAt = nil
        items = todo.map { Item(id: $0.id, name: $0.name, maker: $0.manufacturer) }
        SnapshotProgressWindow.shared.show()
        Task {
            for (i, plugin) in todo.enumerated() {
                if cancelled {
                    for j in i..<items.count { items[j].status = .skipped }
                    break
                }
                currentID = plugin.id
                items[i].status = .working
                let began = Date()
                let result = await Self.capture(plugin, to: store.snapshotURL(for: plugin.id))
                store.update(plugin.id) {
                    $0.snapshotState = result.state
                    $0.snapshotError = result.error
                    if let p = result.params { $0.parameterCount = p }
                }
                if result.state == .done {
                    store.snapshotChanged()
                    if let p = store.plugins.first(where: { $0.id == plugin.id }) { PlugDB.share(p) }
                }
                items[i].seconds = Date().timeIntervalSince(began)
                switch result.state {
                case .done: items[i].status = result.generic ? .generic : .done
                case .noUI: items[i].status = .noUI
                default: items[i].status = .failed(result.error ?? "Unknown problem")
                }
            }
            isRunning = false
            currentID = nil
            finishedAt = Date()
        }
    }

    func cancel() { cancelled = true }

    /// Tries the failed ones of the last run again.
    func retryFailed() {
        let ids = Set(items.filter { if case .failed = $0.status { return true }; return false }.map(\.id))
        guard !ids.isEmpty else { return }
        start(only: ids)
    }

    /// Re-captures one plugin on request (right-click → Retake Screenshot).
    func recapture(_ id: String) {
        guard !isRunning else { return }
        start(only: [id])
    }

    /// How many plugins still have no picture (what the camera button would capture).
    var missingCount: Int {
        let store = PluginStore.shared
        return store.plugins.filter { p in
            !p.isLogic && (p.snapshotState == .pending || p.snapshotState == .done)
                && !FileManager.default.fileExists(atPath: store.snapshotURL(for: p.id).path)
        }.count
    }

    struct Result {
        var state: SnapshotState
        var params: Int?
        var error: String?
        var generic = false
    }

    nonisolated static func capture(_ plugin: Plugin, to url: URL) async -> Result {
        guard let exe = Bundle.main.executableURL else {
            return Result(state: .failed, error: "app executable not found")
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = ["--render", String(plugin.componentType),
                                     String(plugin.componentSubType),
                                     String(plugin.componentManufacturer),
                                     plugin.isV3 ? "1" : "0", url.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    cont.resume(returning: Result(state: .failed, error: "could not start helper"))
                    return
                }
                // Hard time limit so a hanging plugin can never block the queue.
                let deadline = DispatchTime.now() + .seconds(25)
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: timer)
                process.waitUntilExit()
                timer.cancel()

                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                let line = String(data: out, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init) ?? ""
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    let why = process.terminationReason == .uncaughtSignal
                        ? "the plugin crashed or took too long" : "no answer from helper"
                    cont.resume(returning: Result(state: .failed, error: why))
                    return
                }
                let params = json["params"] as? Int
                switch json["status"] as? String {
                case "ok": cont.resume(returning: Result(state: .done, params: params))
                case "generic": cont.resume(returning: Result(state: .done, params: params, generic: true))
                case "noUI": cont.resume(returning: Result(state: .noUI, params: params))
                default: cont.resume(returning: Result(state: .failed, params: params,
                                                       error: json["error"] as? String))
                }
            }
        }
    }
}

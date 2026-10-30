import Foundation
import Observation

/// Captures plugin screenshots one at a time, each in its own helper process with a time limit.
@MainActor
@Observable
final class SnapshotQueue {
    static let shared = SnapshotQueue()

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var currentName = ""
    private var cancelled = false

    /// Captures every plugin that has no screenshot yet (or all of them when `force` is true).
    func start(force: Bool = false) {
        guard !isRunning else { return }
        let store = PluginStore.shared
        let todo = store.plugins
            .filter { force || $0.snapshotState == .pending }
            .sorted { $0.name < $1.name }
        guard !todo.isEmpty else { return }
        isRunning = true
        cancelled = false
        done = 0
        total = todo.count
        Task {
            for plugin in todo {
                if cancelled { break }
                currentName = plugin.name
                let result = await Self.capture(plugin, to: store.snapshotURL(for: plugin.id))
                store.update(plugin.id) {
                    $0.snapshotState = result.state
                    $0.snapshotError = result.error
                    if let p = result.params { $0.parameterCount = p }
                }
                if result.state == .done { store.snapshotChanged() }
                done += 1
            }
            isRunning = false
            currentName = ""
        }
    }

    func cancel() { cancelled = true }

    /// Re-captures one plugin.
    func recapture(_ id: String) {
        PluginStore.shared.update(id) { $0.snapshotState = .pending }
        start()
    }

    struct Result {
        var state: SnapshotState
        var params: Int?
        var error: String?
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
                case "ok", "generic": cont.resume(returning: Result(state: .done, params: params))
                case "noUI": cont.resume(returning: Result(state: .noUI, params: params))
                default: cont.resume(returning: Result(state: .failed, params: params,
                                                       error: json["error"] as? String))
                }
            }
        }
    }
}

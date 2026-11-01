import AppKit

/// Crash reports to Goldi (BL-73). When AG PlugFinder closed unexpectedly, the next launch
/// offers to send macOS's report of it; "Send Error Log to Goldi…" sends the app's logs any
/// time. Nothing is sent without the user pressing Send. The user's home folder name is
/// replaced with "~" in everything sent.
@MainActor
enum CrashReports {
    private static let checkedKey = "crash.lastChecked"
    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// A crash of the app itself since the last launch. Crashes of the picture helper (a plugin
    /// that crashed while its picture was taken) are expected and left out.
    static func newCrash() -> URL? {
        let d = UserDefaults.standard
        let since = d.object(forKey: checkedKey) as? Date
        d.set(Date(), forKey: checkedKey)
        guard let since else { return nil }   // first launch: older reports are not ours to ask about
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("AG PlugFinder") && $0.pathExtension == "ips" }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > since }
            .filter { !isHelperCrash($0) }
            .max { a, b in a.lastPathComponent < b.lastPathComponent }
    }

    private static func isHelperCrash(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        // The helper is started by the app itself; the app is started by launchd. Test builds
        // (they carry a debug library) are not the user's crashes either.
        return text.contains("\"parentProc\" : \"AG PlugFinder\"") || text.contains("\"parentProc\":\"AG PlugFinder\"")
            || text.contains("AG PlugFinder.debug.dylib")
    }

    static func checkOnLaunch() {
        guard let report = newCrash() else { return }
        ask(title: "AG PlugFinder closed unexpectedly last time",
            message: "Send the report to Goldi so it can be fixed? It says where in the app it happened, plus the app's own log. Nothing else from your Mac is sent.",
            crash: report)
    }

    /// The menu item: sends the app's logs, with the latest crash report if there is one.
    static func sendLogs() {
        let latest = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("AG PlugFinder") && $0.pathExtension == "ips" && !isHelperCrash($0) }
            .max { a, b in a.lastPathComponent < b.lastPathComponent }
        ask(title: "Send the error log to Goldi?",
            message: "It holds what the app did recently in Logic" + (latest == nil ? "." : ", and the last crash report.") +
                " Nothing else from your Mac is sent.",
            crash: latest)
    }

    private static func ask(title: String, message: String, crash: URL?) {
        NSApp.activate()
        let answer = Dialog.show(title, message: message, field: ("What were you doing? (optional)", ""), multiline: true,
                                 choices: [.init(title: "Not Now", cancel: true), .init(title: "Send to Goldi", primary: true)])
        guard answer.index == 1 else { return }
        let text = answer.text
        Task {
            let ok = await send(crash: crash, note: text)
            Toast.show(ok ? "Sent to Goldi. Thank you!" : "Couldn't send it. Check the internet connection and try again.", warning: !ok)
        }
    }

    private static func scrub(_ s: String) -> String {
        s.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            .replacingOccurrences(of: NSUserName(), with: "user")
    }

    /// The app's recent Logic log and the plugins whose picture failed, with names scrubbed.
    static func diagnostics() -> String {
        let logURL = PluginStore.shared.supportDir.appendingPathComponent("Insert log.txt")
        var text = (try? String(contentsOf: logURL, encoding: .utf8)).map { $0.split(separator: "\n").suffix(300).joined(separator: "\n") } ?? ""
        let failed = PluginStore.shared.plugins.filter { $0.snapshotState == .failed }
        if !failed.isEmpty {
            text += "\n\n=== Pictures that failed (\(failed.count)) ===\n" + failed.prefix(400)
                .map { "\($0.manufacturer) · \($0.name) [\($0.id)\($0.isV3 ? " v3" : "")]: \($0.snapshotError ?? "?")" }
                .joined(separator: "\n")
        }
        return scrub(text)
    }

    private static func send(crash: URL?, note: String) async -> Bool {
        guard let base = PlugDB.base, let key = PlugDB.key else { return false }
        let logURL = PluginStore.shared.supportDir.appendingPathComponent("Insert log.txt")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)).map { $0.split(separator: "\n").suffix(300).joined(separator: "\n") } ?? ""
        var report = crash.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { String($0.prefix(1_500_000)) }
        // Plugins whose picture failed, and why, so a report says which makers have trouble.
        let failed = PluginStore.shared.plugins.filter { $0.snapshotState == .failed }
        if !failed.isEmpty {
            let lines = failed.prefix(400).map { "\($0.manufacturer) · \($0.name) [\($0.id)\($0.isV3 ? " v3" : "")]: \($0.snapshotError ?? "?")" }
            report = (report.map { $0 + "\n\n" } ?? "") + "=== Pictures that failed (\(failed.count)) ===\n" + lines.joined(separator: "\n")
        }
        let info = ProcessInfo.processInfo
        let body: [String: Any] = [
            "installId": PlugDB.installID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "macOS": info.operatingSystemVersionString,
            "kind": crash == nil ? "log" : "crash",
            "note": String(note.prefix(2000)),
            "report": scrub(report ?? ""),
            "log": scrub(log),
        ]
        var request = URLRequest(url: base.appendingPathComponent("v1/reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 201
    }
}

import AppKit
import CryptoKit
import Observation

/// One-click updates, built like AGenda's (BL-05).
///
/// 30 s after launch and every 6 h the app reads the update feed (`AGPFUpdateFeedURL` in
/// Info.plist), a small JSON file the release script publishes. A newer version shows
/// "Update available" with what's new. "Install and Restart" downloads the zip, and the copy must
/// pass every check before it can replace the app: the published sha256, the bundle id and
/// version, `codesign` against our Developer ID team, and Gatekeeper. A helper script then swaps
/// the app, starts the new version and puts the old one back if the new one does not start.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let teamID = "4HJV6RPCLU"
    static let bundleID = "com.adigoldstein.AGPlugFinder"

    struct Release: Codable, Equatable {
        var version: String
        var url: String
        var sha256: String
        var size: Int64
        var notes: [String]
        var minOS: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, verifying, installing, restarting
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The release being installed (kept while it downloads and installs, for the update window).
    private(set) var installing: Release?
    /// Download progress, 0…1, and bytes so far.
    private(set) var progress: Double = 0
    private(set) var receivedBytes: Int64 = 0
    private(set) var lastChecked: Date?
    /// Shown once after an update installed itself.
    var whatsNew: (version: String, notes: [String])?

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.autoCheck") }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var feedURL: URL? {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["AGPF_UPDATE_FEED"] { return URL(string: test) }
        #endif
        return (Bundle.main.infoDictionary?["AGPFUpdateFeedURL"] as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// Debug builds only: allow a local http test server and skip Gatekeeper (test builds are
    /// not notarized). Never active in a release build.
    private var testMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["AGPF_UPDATE_TEST"] == "1"
        #else
        return false
        #endif
    }

    var busy: Bool {
        [.downloading, .verifying, .installing, .restarting].contains(state)
    }

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    private var timer: Timer?

    // MARK: Schedule

    func start() {
        showWhatsNewIfJustUpdated()
        guard feedURL != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task { @MainActor in
                guard let self, self.autoCheck else { return }
                await self.check()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck else { return }
                await self.check()
            }
        }
    }

    // MARK: Check

    /// Automatic checks stay quiet when something fails; only "Check Now" shows the problem.
    func check(userInitiated: Bool = false) async {
        guard let feedURL else { state = .failed("No update address is set for this build."); return }
        if busy { return }
        state = .checking
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // Nothing published yet: there is no newer version, so this copy is current.
                lastChecked = Date()
                state = .upToDate
                return
            }
            guard status == 200 else {
                throw UpdateError.message("The update server did not answer.")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastChecked = Date()
            guard release.sha256.count == 64, release.size > 0,
                  release.url.hasPrefix("https://") || (testMode && release.url.hasPrefix("http://localhost")) else {
                throw UpdateError.message("The update information is not valid.")
            }
            if Self.isNewer(release.version, than: currentVersion), osIsSupported(release.minOS) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: Install

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Downloads, checks, installs, then quits and opens the new version by itself (BL-24).
    func install() {
        guard let release = available ?? (state.isFailed ? installing : nil) else { return }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        installing = release
        UpdateWindow.shared.show()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed("Move AG PlugFinder to your Applications folder to update it.")
            return
        }
        progress = 0
        receivedBytes = 0
        state = .downloading
        Task {
            do {
                let newApp = try await downloadAndVerify(release)
                state = .installing
                UserDefaults.standard.set(release.notes, forKey: "update.pendingNotes")
                UserDefaults.standard.set(release.version, forKey: "update.pendingVersion")
                try await Task.sleep(for: .milliseconds(600))
                state = .restarting
                try launchSwapper(newApp: newApp, appURL: appURL)
                try await Task.sleep(for: .milliseconds(1400))      // let "Restarting" be seen
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads with live progress for the update window.
    private func download(_ url: URL, expected: Int64) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgress { [weak self] got, total in
            Task { @MainActor in
                guard let self else { return }
                self.receivedBytes = got
                let all = total > 0 ? total : expected
                self.progress = all > 0 ? min(1, Double(got) / Double(all)) : 0
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            delegate.finish = { result in c.resume(with: result) }
            session.downloadTask(with: url).resume()
        }
    }

    private func downloadAndVerify(_ r: Release) async throws -> URL {
        guard let url = URL(string: r.url) else { throw UpdateError.message("Bad download address.") }
        let (tmp, response) = try await download(url, expected: r.size)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("The download failed.")
        }
        progress = 1
        state = .verifying
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("AGPF-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        // 1. Size and checksum match what was published.
        let attrs = try FileManager.default.attributesOfItem(atPath: zip.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == r.size else {
            throw UpdateError.message("The download is incomplete.")
        }
        guard try sha256(of: zip) == r.sha256.lowercased() else {
            throw UpdateError.message("The download did not pass the safety check.")
        }
        // 2. Unpack.
        let unpack = work.appendingPathComponent("app", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The update has no app inside.")
        }
        // 3. Same app, the promised version.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Self.bundleID,
              info?["CFBundleShortVersionString"] as? String == r.version else {
            throw UpdateError.message("The update is not the expected app or version.")
        }
        // 4. Signed by our Developer ID, and accepted by Gatekeeper (notarized).
        let requirement = "identifier \"\(Self.bundleID)\" and anchor apple generic and " +
            "certificate leaf[subject.OU] = \"\(Self.teamID)\""
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path],
                failure: "The update is not signed by the developer.")
        if !testMode {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path],
                    failure: "macOS did not accept the update.")
        }
        return app
    }

    /// Writes and starts the helper that swaps the app once we have quit.
    private func launchSwapper(newApp: URL, appURL: URL) throws {
        let script = """
        #!/bin/bash
        OLD_PID="$1"; APP="$2"; NEW="$3"; BACKUP="$2.previous"
        while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$BACKUP"
        if ! mv "$APP" "$BACKUP"; then open "$APP"; exit 1; fi
        if ! mv "$NEW" "$APP"; then mv "$BACKUP" "$APP"; open "$APP"; exit 1; fi
        open "$APP"
        for i in $(seq 1 40); do
          sleep 0.5
          if pgrep -f "$APP/Contents/MacOS/" >/dev/null; then rm -rf "$BACKUP"; exit 0; fi
        done
        rm -rf "$APP"; mv "$BACKUP" "$APP"; open "$APP"
        """
        let url = newApp.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("swap.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), appURL.path, newApp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: What's new

    private func showWhatsNewIfJustUpdated() {
        let d = UserDefaults.standard
        guard let version = d.string(forKey: "update.pendingVersion") else { return }
        d.removeObject(forKey: "update.pendingVersion")
        let notes = d.stringArray(forKey: "update.pendingNotes") ?? []
        d.removeObject(forKey: "update.pendingNotes")
        if version == currentVersion {
            whatsNew = (version, notes)
            // The new version opens on a "You're updated" window with what is new.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { UpdateWindow.shared.show() }
        }
    }

    // MARK: Helpers

    static func parse(_ v: String) -> [Int] {
        v.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func osIsSupported(_ min: String?) -> Bool {
        guard let min else { return true }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return !Self.isNewer(min, than: os)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ tool: String, _ args: [String], failure: String? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.message(failure ?? "Could not unpack the update.")
        }
    }
}

extension Updater.State {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// Reports download progress and hands back the finished file (moved out of the session's
/// temporary location before the delegate returns).
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Int64, Int64) -> Void
    var finish: ((Result<(URL, URLResponse), Error>) -> Void)?
    private var done = false

    init(_ onProgress: @escaping (Int64, Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("AGPF-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            complete(.success((keep, response)))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
    }

    private func complete(_ r: Result<(URL, URLResponse), Error>) {
        guard !done else { return }
        done = true
        finish?(r)
    }
}

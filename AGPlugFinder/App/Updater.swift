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
        case idle, checking, upToDate, available(Release), downloading, installing, failed(String)
    }

    private(set) var state: State = .idle
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
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
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

    func install() {
        guard let release = available else { return }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed("Move AG PlugFinder to your Applications folder to update it.")
            return
        }
        state = .downloading
        Task {
            do {
                let newApp = try await downloadAndVerify(release)
                state = .installing
                UserDefaults.standard.set(release.notes, forKey: "update.pendingNotes")
                UserDefaults.standard.set(release.version, forKey: "update.pendingVersion")
                try launchSwapper(newApp: newApp, appURL: appURL)
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func downloadAndVerify(_ r: Release) async throws -> URL {
        guard let url = URL(string: r.url) else { throw UpdateError.message("Bad download address.") }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("The download failed.")
        }
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
        if version == currentVersion { whatsNew = (version, notes) }
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

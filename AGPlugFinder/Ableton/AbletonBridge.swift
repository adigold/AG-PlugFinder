import AppKit
import Darwin

/// Which music program a plugin goes to (BL-161): Logic Pro or Ableton Live. Found by itself:
/// the one that is open, or when both are, the one used last.
@MainActor
enum Host {
    case logic, ableton

    static let logicID = "com.apple.logic10"
    static let abletonPrefix = "com.ableton.live"

    /// The last of the two that came to the front.
    private static var lastUsed: Host?
    private static var watching = false
    /// Where plugins go right now, kept up to date as programs open, close and come to the front.
    private(set) static var now: Host = initial()

    /// Decided before the library is first drawn, so it never switches lists right at launch.
    private static func initial() -> Host {
        let apps = NSWorkspace.shared.runningApplications
        let ableton = apps.contains(where: isAbleton), logic = apps.contains(where: isLogic)
        if ableton && !logic { return .ableton }
        if ableton && logic, let front = NSWorkspace.shared.frontmostApplication, isAbleton(front) { return .ableton }
        return .logic
    }

    static func isAbleton(_ app: NSRunningApplication) -> Bool { app.bundleIdentifier?.hasPrefix(abletonPrefix) == true }
    static func isLogic(_ app: NSRunningApplication) -> Bool { app.bundleIdentifier == logicID }

    static var abletonRunning: Bool { NSWorkspace.shared.runningApplications.contains(where: isAbleton) }
    static var logicRunning: Bool { NSWorkspace.shared.runningApplications.contains(where: isLogic) }

    /// Starts following which program the user is in.
    static func watch() {
        guard !watching else { return }
        watching = true
        if let front = NSWorkspace.shared.frontmostApplication {
            if isAbleton(front) { lastUsed = .ableton } else if isLogic(front) { lastUsed = .logic }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      isAbleton(app) || isLogic(app) else { return }
                let activated = n.name == NSWorkspace.didActivateApplicationNotification
                MainActor.assumeIsolated {
                    if activated { lastUsed = isAbleton(app) ? .ableton : .logic }
                    update()
                }
            }
        }
        update()
    }

    /// Works out where plugins go; the library redraws when it changes.
    private static func update() {
        let ableton = abletonRunning, logic = logicRunning
        let next: Host = ableton && !logic ? .ableton : (ableton && logic ? (lastUsed ?? .logic) : .logic)
        let open = next == .ableton ? ableton : logic
        guard next != now || open != isOpen else { return }
        now = next
        isOpen = open
        PluginStore.shared.bumpRevision()
    }

    /// Whether the program in use is open right now (for the footer's indicator).
    private(set) static var isOpen: Bool = {
        let apps = NSWorkspace.shared.runningApplications
        return initial() == .ableton ? apps.contains(where: isAbleton) : apps.contains(where: isLogic)
    }()

    static var title: String { now == .ableton ? "Ableton Live" : "Logic Pro" }

    /// The program's own icon, from the app on this Mac.
    static var icon: NSImage? {
        let apps = NSWorkspace.shared.runningApplications
        if let running = apps.first(where: now == .ableton ? isAbleton : isLogic), let icon = running.icon { return icon }
        let path = now == .ableton ? AbletonCatalog.app?.path : LogicCatalog.appPaths.first { FileManager.default.fileExists(atPath: $0) }
        return path.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    /// Whether the library lists this plugin for the program in use: Logic's own plugins only
    /// for Logic, Ableton's devices only for Ableton, every Audio Unit for both.
    static func shows(_ p: Plugin) -> Bool {
        switch p.kind {
        case .logic: return now == .logic
        case .ableton: return now == .ableton
        default: return true
        }
    }

    /// Where the next plugin goes. Logic unless only Ableton is open, or Ableton was used last.
    static var current: Host {
        watch()
        return now
    }

    /// The add button's words for the program in use.
    static var insertTitle: String { now == .ableton ? "Add to Ableton" : "Insert in Logic" }
    static var addingTitle: String { now == .ableton ? "Adding to Ableton…" : "Adding to Logic…" }
    /// When neither program is open.
    static var notOpen: String { AbletonCatalog.app != nil ? "Open Logic Pro or Ableton Live first." : "Logic Pro isn't open." }

    /// Adds a plugin to the selected track of whichever program is in use. Logic goes the way
    /// it always did.
    static func insert(_ plugin: Plugin, replacing slot: Int? = nil) async -> InsertOutcome {
        if current == .ableton { return await AbletonBridge.shared.insert(plugin) }
        return await LogicInserter.shared.insert(plugin, replacing: slot)
    }
}

/// Talks to the small add-on (a Remote Script) that Ableton Live loads from the User Library
/// (BL-161). The add-on listens on this Mac only and loads plugins and devices onto the
/// selected track with Live's own browser.
final class AbletonBridge: @unchecked Sendable {
    @MainActor static let shared = AbletonBridge()
    static let port: UInt16 = 47391
    static let scriptName = "AGPlugFinder"

    static var scriptFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Ableton/User Library/Remote Scripts/\(scriptName)", isDirectory: true)
    }

    /// Puts the add-on in Live's User Library, or updates it when this version of the app has a
    /// newer one. Live picks it up the next time it starts.
    @discardableResult
    static func installScript() -> Bool {
        let fm = FileManager.default
        let file = scriptFolder.appendingPathComponent("__init__.py")
        if let current = try? String(contentsOf: file, encoding: .utf8), current == AbletonScript.source { return true }
        do {
            try fm.createDirectory(at: scriptFolder, withIntermediateDirectories: true)
            try AbletonScript.source.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// One request to the add-on, answered within the time given; nil when Live does not answer.
    func send(_ message: [String: Any], timeout: Double = 4) async -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: Self.roundTrip(body, timeout: timeout))
            }
        }
    }

    private static func roundTrip(_ body: Data, timeout: Double) -> [String: Any]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = body.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, body.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == body.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buffer[0..<n]))) as? [String: Any]
    }

    /// Whether Live has the add-on running.
    func isConnected() async -> Bool { await send(["cmd": "ping"], timeout: 1)?["ok"] as? Bool == true }

    /// Loads the plugin onto Ableton's selected track.
    func insert(_ plugin: Plugin) async -> InsertOutcome {
        guard await MainActor.run(body: { Host.abletonRunning }) else { return .failed("Ableton Live isn't open.") }
        Self.installScript()
        let request: [String: Any] = ["cmd": "load", "name": plugin.name, "maker": plugin.manufacturer,
                                      "kind": plugin.source == .ableton ? "device" : "au",
                                      "instrument": plugin.slotKind == .instrument]
        guard let reply = await send(request) else {
            await MainActor.run { Toast.show("Ableton Live isn't connected yet. Turn on AGPlugFinder in Live's Control Surfaces.", warning: true) }
            return .failed(Self.notConnectedHelp)
        }
        // A message either way, since Live itself shows nothing (BL-161).
        if reply["ok"] as? Bool == true {
            let track = reply["track"] as? String
            await MainActor.run { Toast.show("Added \(plugin.name) to Ableton" + (track.map { ", track \($0)" } ?? "")) }
            return .inserted
        }
        let problem = reply["error"] as? String ?? "Ableton Live could not add \(plugin.name)."
        await MainActor.run { Toast.show(problem, warning: true) }
        return .failed(problem)
    }

    static let notConnectedHelp = "Ableton Live needs the AG PlugFinder add-on turned on once: in Live, open Settings, " +
        "Link, Tempo & MIDI, and choose AGPlugFinder as a Control Surface. If it is not in the list, quit and open Live again."
}

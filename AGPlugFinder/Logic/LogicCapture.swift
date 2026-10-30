import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Screenshots of Logic's own plugins (BL-15). They only run inside Logic, so each one is added
/// to the selected track, its window is photographed, the window is closed and the plugin is
/// taken out again ("No Plug-in"). Needs Screen Recording permission to see Logic's windows.
@MainActor
enum LogicCapture {
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenAccess() { _ = CGRequestScreenCaptureAccess() }

    static func run(_ plugins: [Plugin], progress: @escaping (Int, String) -> Void) async -> (done: Int, failed: [String]) {
        let inserter = LogicInserter.shared
        let store = PluginStore.shared
        guard let logic = inserter.logicApp else { return (0, plugins.map(\.name)) }
        let pid = logic.processIdentifier
        let app = AXNode(el: AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        var done = 0
        var failed: [String] = []

        for (i, plugin) in plugins.enumerated() {
            progress(i, plugin.name)
            let before = Set(windows(app).map { CFHash($0.el) })
            let outcome = await inserter.insert(plugin, replacing: plugin.slotKind == .instrument ? 0 : nil)
            guard case .inserted = outcome else {
                inserter.log("CAPTURE \(plugin.name): not inserted (\(outcome))"); failed.append(plugin.name); continue
            }
            // Logic opens the plug-in's window after inserting it.
            var pluginWindow: AXNode?
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                pluginWindow = windows(app).first { !before.contains(CFHash($0.el)) }
                if pluginWindow != nil { break }
            }
            try? await Task.sleep(for: .milliseconds(1200))      // let it draw
            if let w = pluginWindow, let image = await capture(w, pid: pid),
               save(image, to: store.snapshotURL(for: plugin.id)) {
                store.update(plugin.id) { $0.snapshotState = .done }
                store.snapshotChanged()
                done += 1
                inserter.log("CAPTURE \(plugin.name): saved")
            } else {
                failed.append(plugin.name)
                inserter.log("CAPTURE \(plugin.name): no window to capture (window=\(pluginWindow != nil), access=\(hasScreenAccess))")
            }
            if let w = pluginWindow { close(w) }
            if plugin.slotKind != .instrument { await removeLastInsert(app: app, pid: pid) }
        }
        return (done, failed)
    }

    private static func windows(_ app: AXNode) -> [AXNode] {
        app.children.filter { $0.role == kAXWindowRole as String }
    }

    private static func close(_ window: AXNode) {
        if let button = window.children.first(where: { $0.subrole == "AXCloseButton" }) {
            button.perform(kAXPressAction)
        }
    }

    /// Takes the newest audio insert back out: its slot menu → "No Plug-in".
    private static func removeLastInsert(app: AXNode, pid: pid_t) async {
        let inserter = LogicInserter.shared
        guard let window = inserter.projectWindow(app) else { return }
        let win = AXNode(el: window)
        let minX = win.frame.minX
        let inserts = win.findAll(skipRoles: [AXRole.menuBar]) { n in
            n.role == "AXGroup" && !n.desc.isEmpty && n.frame.minX - minX > 10 && n.frame.minX - minX < 60
                && n.children.contains(where: { $0.desc == "list" })
                && n.children.contains(where: { $0.desc == "bypass" })   // a plug-in, not automation
        }
        // The instrument slot sits above the first audio insert; the newest insert is the lowest.
        guard let last = inserts.max(by: { $0.frame.minY < $1.frame.minY }),
              let list = last.children.first(where: { $0.desc == "list" }) else { return }
        list.perform(kAXPressAction)
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(80))
            if let menu = app.children.first(where: { $0.role == AXRole.menu })
                ?? app.children.filter({ $0.role != AXRole.menuBar }).lazy
                    .compactMap({ $0.first(maxNodes: 300, where: { $0.role == AXRole.menu && !$0.children.isEmpty }) }).first,
               let none = menu.children.first(where: { $0.title == "No Plug-in" }) {
                none.perform(kAXPressAction)
                inserter.log("CAPTURE removed \(last.desc)")
                return
            }
        }
        Keyboard.press(53, pid: pid)
        inserter.log("CAPTURE could not remove \(last.desc)")
    }

    private static func capture(_ window: AXNode, pid: pid_t) async -> CGImage? {
        let f = window.frame
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let sc = content.windows.first(where: {
                  $0.owningApplication?.processID == pid
                      && abs($0.frame.minX - f.minX) < 4 && abs($0.frame.width - f.width) < 4
              }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        config.width = Int(sc.frame.width) * scale
        config.height = Int(sc.frame.height) * scale
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config)
    }

    private static func save(_ image: CGImage, to url: URL) -> Bool {
        let scale = min(1.0, 720.0 / Double(image.width))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

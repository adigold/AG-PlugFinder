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
            // Only the project window stays open: leftover plug-in windows hide Logic's menus.
            await closePluginWindows(app, pid: pid)
            var outcome = await inserter.insert(plugin, replacing: plugin.slotKind == .instrument ? 0 : nil)
            if case .inserted = outcome {} else {
                // One retry: Logic sometimes needs a moment after the previous plug-in.
                Keyboard.escapeIfOpen(pid: pid)
                try? await Task.sleep(for: .milliseconds(1200))
                outcome = await inserter.insert(plugin, replacing: plugin.slotKind == .instrument ? 0 : nil)
            }
            guard case .inserted = outcome else {
                inserter.log("CAPTURE \(plugin.name): not inserted (\(outcome))"); failed.append(plugin.name)
                Keyboard.escapeIfOpen(pid: pid)
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            // Logic opens the plug-in's window after inserting it.
            var pluginWindow: AXNode?
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                // Logic keeps closed plug-in windows around hidden; the right one shows the name.
                let open = pluginWindows(app)
                pluginWindow = open.first { w in
                    w.first(maxNodes: 400, where: { $0.stringValue == plugin.name || $0.title == plugin.name }) != nil
                }
                if pluginWindow != nil { break }
            }
            // Some windows (MIDI FX, Studio instruments) do not show the name to Accessibility:
            // then the window Logic just focused is the plug-in's.
            if pluginWindow == nil, let el: AXUIElement = app.attr(kAXFocusedWindowAttribute) {
                let focused = AXNode(el: el)
                if !focused.title.contains(" - ") { pluginWindow = focused }
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
            await closePluginWindows(app, pid: pid)
            if plugin.slotKind != .instrument { await removeLastInsert(app: app, pid: pid) }
        }
        return (done, failed)
    }

    private static func windows(_ app: AXNode) -> [AXNode] {
        app.children.filter { $0.role == kAXWindowRole as String }
    }

    /// Every Logic window except the project's own ("Untitled - Tracks").
    private static func pluginWindows(_ app: AXNode) -> [AXNode] {
        windows(app).filter { !$0.title.contains(" - ") }
    }

    static func closePluginWindows(_ app: AXNode, pid: pid_t) async {
        for _ in 0..<2 {
            let open = pluginWindows(app)
            if open.isEmpty { return }
            for w in open {
                // The window's own close-button attribute, else any close button inside it.
                if let el: AXUIElement = w.attr(kAXCloseButtonAttribute) {
                    AXNode(el: el).perform(kAXPressAction)
                } else if let button = w.first(maxNodes: 60, where: { $0.subrole == "AXCloseButton" }) {
                    button.perform(kAXPressAction)
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
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
        // Two tries: the first press sometimes only brings the project window forward.
        for attempt in 1...2 {
            list.perform(kAXPressAction)
            if let menu = await inserter.waitForMenu(app: app, timeout: 2.5),
               let none = menu.first(maxNodes: 200, where: { $0.title == "No Plug-in" }) {
                none.perform(kAXPressAction)
                inserter.log("CAPTURE removed \(last.desc)")
                return
            }
            Keyboard.escapeIfOpen(pid: pid)
            inserter.log("CAPTURE remove try \(attempt) found no menu for \(last.desc)")
            try? await Task.sleep(for: .milliseconds(400))
        }
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

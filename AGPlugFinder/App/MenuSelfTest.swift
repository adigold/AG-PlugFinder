#if DEBUG
import AppKit
import ApplicationServices

/// --selftest-menu-of <pid>: a test build clicks every item of ANOTHER running copy's menu bar
/// menu through Accessibility, like a mouse would, and reports which windows each one opened,
/// then closes them (Adi, 2026-10-31). Never its own menu: AppKit crashes on that. Quit is only
/// checked, never pressed; an alert is answered with Not Now.
extension SelfTest {
    static func menuTest(of pid: pid_t) {
        func say(_ s: String) { print("MENU " + s); fflush(stdout) }
        Thread.detachNewThread {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 4)
            func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
                var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v
            }
            func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
            func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
            func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
            func describe(_ w: AXUIElement) -> String {
                var parts = [title(w)]
                if let s = attr(w, kAXSubroleAttribute) as? String { parts.append(s) }
                var size = CGSize.zero
                if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
                parts.append("\(Int(size.width))x\(Int(size.height))")
                // The first few texts inside, to tell windows with hidden titles apart.
                var texts: [String] = []
                func walk(_ e: AXUIElement, _ depth: Int) {
                    guard depth < 7, texts.count < 3 else { return }
                    if (attr(e, kAXRoleAttribute) as? String) == "AXStaticText",
                       let t = attr(e, kAXValueAttribute) as? String, t.count > 3 { texts.append(String(t.prefix(40))) }
                    for k in kids(e) { walk(k, depth + 1) }
                }
                walk(w, 0)
                return parts.joined(separator: " ") + " [" + texts.joined(separator: " / ") + "]"
            }
            func openMenu() -> [AXUIElement] {
                guard let extras = attr(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
                      let item = kids(extras as! AXUIElement).first else { return [] }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                for _ in 0..<25 {
                    usleep(100_000)
                    if let menu = kids(item).first {
                        let items = kids(menu).filter { !title($0).isEmpty }
                        if !items.isEmpty { return items }
                    }
                }
                return []
            }
            func closeMenu() {
                for down in [true, false] {
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid)
                }
                usleep(300_000)
            }

            var names: CFArray?
            AXUIElementCopyAttributeNames(app, &names)
            say("trusted=\(AXIsProcessTrusted()) attrs=\((names as? [String]) ?? [])")
            if let extras = attr(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID() {
                say("extras kids: " + kids(extras as! AXUIElement).map { "\(attr($0, kAXRoleAttribute) as? String ?? "?") \(title($0))" }.joined(separator: ", "))
            }
            let titles = openMenu().map(title)
            closeMenu()
            say("items: " + titles.joined(separator: " | "))
            if titles.isEmpty { say("done"); return }
            for t in titles {
                if t.hasPrefix("Quit") { say("[\(t)] present, not pressed"); continue }
                let before = windows()
                guard let item = openMenu().first(where: { title($0) == t }) else { say("[\(t)] NOT FOUND"); continue }
                let enabled = (attr(item, kAXEnabledAttribute) as? Bool) ?? false
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                usleep(2_000_000)
                let new = windows().filter { w in !before.contains(where: { CFEqual($0, w) }) }
                var notes: [String] = []
                for w in new {
                    notes.append(describe(w))
                    let buttons = kids(w).filter { (attr($0, kAXRoleAttribute) as? String) == "AXButton" }
                    if let no = buttons.first(where: { ["Not Now", "Cancel"].contains(title($0)) }) {
                        AXUIElementPerformAction(no, kAXPressAction as CFString); notes.append("(answered Not Now)")
                    } else if let close = attr(w, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() {
                        AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
                    }
                    usleep(400_000)
                }
                say("[\(t)] enabled=\(enabled) opened \(new.count): " + notes.joined(separator: " ; "))
            }
            say("done")
        }
    }
}

extension SelfTest {
    /// --selftest-menu-actions <dir>: runs what each menu bar item runs, one after another, and
    /// photographs and closes every window it opened. Alerts are answered with Not Now.
    static func menuActions(_ dir: URL) async {
        func say(_ s: String) { print("MENU " + s); fflush(stdout) }
        let updater = Updater.shared
        let steps: [(String, () -> Void)] = [
            ("Plugin Library", { NSApp.activate(); LibraryWindow.opener?() }),
            ("Quick Picker", { PickerPanelController.shared.show() }),
            ("Mini Window", { NSApp.activate(); LibraryWindow.opener?()
                NotificationCenter.default.post(name: .toggleMiniMode, object: nil) }),
            ("Check for Update", { Task { await updater.check(userInitiated: true) } }),
            ("Licenses and Subscriptions", { LicensesWindow.shared.show() }),
            ("Share AG PlugFinder", { ShareWindow.shared.show() }),
            ("Send Feedback to Goldi", { FeedbackWindow.shared.show() }),
            ("Send Error Log to Goldi", {
                // The alert runs modally: a timer in the modal run loop reads it and says Not Now.
                let t = Timer(timeInterval: 1.5, repeats: false) { _ in
                    if let w = NSApp.modalWindow {
                        let texts = (w.contentView?.subviews ?? []).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
                        print("MENU   alert: " + texts.prefix(2).joined(separator: " / ")); fflush(stdout)
                        NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    }
                }
                RunLoop.main.add(t, forMode: .modalPanel)
                CrashReports.sendLogs()
            }),
            ("Settings", { NSApp.activate(); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }),
        ]
        try? await Task.sleep(for: .seconds(4))
        for (n, (name, run)) in steps.enumerated() {
            let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            run()
            try? await Task.sleep(for: .milliseconds(2200))
            let new = NSApp.windows.filter { $0.isVisible && !before.contains($0.windowNumber) && $0.frame.width > 150 }
            let mini = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-"
            say("[\(name)] opened \(new.count): " + new.map { "\($0.title.isEmpty ? String(describing: type(of: $0)) : $0.title) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", ")
                + " | library window \(mini) | update: \(updater.state)")
            for (i, w) in new.enumerated() {
                await capture(w, to: dir.appendingPathComponent("menu-\(n)-\(i).png"), scale: 1)
                if name != "Plugin Library" { w.orderOut(nil) }
            }
        }
        say("done")
    }
}
#endif

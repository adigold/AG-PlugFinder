#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug-only: `--selftest <folder> [query]` opens the picker and saves pictures of it,
/// so the layout can be checked without a person at the keyboard.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // --dump-logic: save Logic's interface tree.  --test-insert <name>: insert like Return does.
        if args.contains("--selftest-update") {
            Task {
                await Updater.shared.check()
                print("UPDATE state \(Updater.shared.state)"); fflush(stdout)
                if Updater.shared.available != nil { Updater.shared.install() }
                // --selftest-update <dir>: photograph the update window (only that window) as it works.
                let dir = args.firstIndex(of: "--selftest-update").flatMap { i in
                    i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1]) : nil
                }
                for n in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let dir, let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<UpdateProgressView> }) {
                        await capture(w, to: dir.appendingPathComponent("update-\(n).png"))
                    }
                    if case .failed(let m) = Updater.shared.state { print("UPDATE failed \(m)"); fflush(stdout); return }
                }
            }
        }
        if let k = args.firstIndex(of: "--selftest-window"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                await Updater.shared.check(userInitiated: true)
                try? await Task.sleep(for: .milliseconds(1500))
                guard let window = NSApp.windows.first(where: { !($0 is PickerPanel) && $0.isVisible && $0.frame.width > 500 })
                else { print("WINDOW none"); fflush(stdout); return }
                await capture(window, to: out)
                if args.contains("--mini") {
                    NotificationCenter.default.post(name: .toggleMiniMode, object: nil)
                    try? await Task.sleep(for: .milliseconds(1200))
                    await capture(window, to: out.deletingPathExtension().appendingPathExtension("mini.png"))
                    print("MINI \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                print("WINDOW state \(Updater.shared.state)"); fflush(stdout)
            }
        }
        if let k = args.firstIndex(of: "--selftest-whatsnew"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                Updater.shared.whatsNew = (Updater.shared.currentVersion,
                                           ["New: Plugin chains you can drop on a track with one key.", "Improved: Faster search."])
                UpdateWindow.shared.show()
                try? await Task.sleep(for: .milliseconds(1200))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<UpdateProgressView> }) {
                    await capture(w, to: out); print("WHATSNEW ok")
                } else { print("WHATSNEW none") }
                fflush(stdout)
            }
        }
        if let k = args.firstIndex(of: "--selftest-onboarding"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                OnboardingWindow.shared.show()
                try? await Task.sleep(for: .milliseconds(1200))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<OnboardingView> }) {
                    await capture(w, to: out); print("ONBOARD ok")
                } else { print("ONBOARD none") }
                fflush(stdout)
            }
        }
        if args.contains("--dump-logic") {
            print("DUMP \(LogicInserter.shared.dumpDiagnostics()?.path ?? "failed (Logic open? Accessibility allowed?)")")
            fflush(stdout)
        }
        if let j = args.firstIndex(of: "--test-insert"), j + 1 < args.count {
            let name = args[j + 1]
            Task {
                guard let p = PluginStore.shared.plugins.first(where: { $0.name == name }) else {
                    print("INSERT no plugin named \(name)"); fflush(stdout); return
                }
                let slot = args.firstIndex(of: "--slot").flatMap { Int(args[$0 + 1]) }
                let outcome = await LogicInserter.shared.insert(p, replacing: slot)
                print("INSERT \(outcome)"); fflush(stdout)
            }
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[i + 1])
        let query = i + 2 < args.count ? args[i + 2] : ""
        Task {
            while SnapshotQueue.shared.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
            let controller = PickerPanelController.shared
            controller.show()
            let view = ViewSettings.shared
            view.layout = .grid; view.size = .medium; view.showName = true; view.showDetails = true
            view.showInfoPane = true; view.favoritesOnly = false
            controller.model.query = query
            try? await Task.sleep(for: .milliseconds(900))
            await capture(to: folder.appendingPathComponent("1-grid.png"))
            view.layout = .list
            try? await Task.sleep(for: .milliseconds(600))
            await capture(to: folder.appendingPathComponent("2-list.png"))
            view.layout = .grid; view.size = .huge; view.showName = false; view.showDetails = false
            view.showInfoPane = false; controller.model.query = ""
            try? await Task.sleep(for: .milliseconds(700))
            await capture(to: folder.appendingPathComponent("3-xl-no-info.png"))
            view.size = .medium; view.showName = true; view.showDetails = true; view.showInfoPane = true
            let store = PluginStore.shared
            print("COUNTS total \(store.plugins.count) visible \(store.plugins.filter(store.isVisible).count) logic \(store.plugins.filter(\.isLogic).count)")
            store.setGroup(.maker, "Apple", visible: false)
            print("HIDE Apple -> visible \(store.plugins.filter(store.isVisible).count)")
            store.setPlugin(store.plugins.first { $0.name == "AUDelay" }!.id, visible: true)
            print("SHOW AUDelay -> visible \(store.plugins.filter(store.isVisible).count)")
            store.setGroup(.maker, "Apple", visible: true)
            print("RESET -> visible \(store.plugins.filter(store.isVisible).count)")
            print("SELFTEST DONE")
            fflush(stdout)
        }
    }

    private static func capture(to url: URL) async {
        guard let window = NSApp.windows.first(where: { $0 is PickerPanel && $0.isVisible }) else { return }
        await capture(window, to: url)
    }

    private static func capture(_ window: NSWindow, to url: URL) async {
        guard let content = try? await SCShareableContent.currentProcess,
              let sc = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { print("SELFTEST no window"); return }
        let config = SCStreamConfiguration()
        config.width = Int(sc.frame.width) * 2
        config.height = Int(sc.frame.height) * 2
        guard let img = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { print("SELFTEST capture failed"); return }
        try? data.write(to: url)
    }
}
#endif

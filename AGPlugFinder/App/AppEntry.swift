import AppKit
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        // The same binary doubles as the screenshot helper process.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render") {
            SnapshotRenderer.run(Array(args[i...]))
        }
        // Read-only checks of Logic's interface, without the app's windows.
        if args.contains("--dump-logic") || args.contains("--probe-instrument-menu") || args.contains("--test-insert") || args.contains("--capture-logic") || args.contains("--close-logic-windows") || args.contains("--track-name") || args.contains("--track") {
            LogicProbe.run(args)
        }
        Migration.run()
        AGPlugFinderApp.main()
    }
}

struct AGPlugFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("AG PlugFinder", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 1120, height: 720)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarIcon()
        }

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Update…") { Task { await Updater.shared.check(userInitiated: true) } }
            }
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var updater = Updater.shared

    var body: some View {
        if let r = updater.available {
            Button("Update Available: \(r.version)…") {
                NSApp.activate()
                openWindow(id: "library")
            }
            Divider()
        }
        Button("Plugin Library  \(HotKey.display)") {
            NSApp.activate()
            openWindow(id: "library")
        }
        Button("Quick Picker") { PickerPanelController.shared.show() }
        Button("Mini Window") {
            NSApp.activate()
            openWindow(id: "library")
            NotificationCenter.default.post(name: .toggleMiniMode, object: nil)
        }
        Button(updater.state == .upToDate ? "You're updated (v\(updater.currentVersion))" : "Check for Update…") {
            Task { await updater.check(userInitiated: true) }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit AG PlugFinder") { NSApp.terminate(nil) }
    }
}

/// The menu bar icon; it also hands the window opener to the hotkey (BL-45).
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: "puzzlepiece.extension")
            .onAppear { LibraryWindow.opener = { openWindow(id: "library") } }
    }
}

/// Control Option P brings the main window up, or puts it away when it is already in front.
@MainActor
enum LibraryWindow {
    static var opener: (() -> Void)?

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }
    }

    static func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive {
            w.orderOut(nil)
            LogicInserter.shared.logicApp?.activate()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible || opener == nil {
            w.makeKeyAndOrderFront(nil)
        } else if let opener {
            opener()
        } else {
            PickerPanelController.shared.show()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // If macOS kept Logic in front, typing would reach Logic's key commands. The quick
            // picker takes the keyboard without needing the app in front, so it steps in.
            guard NSApp.isActive, window?.isKeyWindow == true else {
                window?.orderOut(nil)
                PickerPanelController.shared.show()
                return
            }
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.shared.register { Task { @MainActor in LibraryWindow.toggle() } }
        HotKey.shared.registerWindowKeys(
            openAll: { Task { @MainActor in TrackState.shared.run { _ = await LogicTrack.shared.openAll() } } },
            closeAll: { Task { @MainActor in await LogicTrack.shared.closeAll() } })
        _ = UserLibrary.shared
        HotKey.shared.registerPins()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in UserLibrary.shared.pullFromCloud() }
        }
        Task { @MainActor in Updater.shared.start() }

        Task { @MainActor in
            let store = PluginStore.shared
            store.rescan()
            if !OnboardingWindow.isDone {
                // First run: permissions first; the tour starts the scan itself.
                OnboardingWindow.shared.show()
            } else if store.plugins.contains(where: { $0.snapshotState == .pending }) {
                // Only new or updated plugins get a screenshot; the rest load from the cache.
                SnapshotQueue.shared.start()
            }
            #if DEBUG
            SelfTest.runIfRequested()
            #endif
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AG PlugFinder: launch at login change failed: \(error)")
        }
    }

    /// Turns launch at login on the first time the app runs (Adi's choice: on, with an off switch).
    static func applyDefaultOnFirstRun() {
        // Only the installed copy registers itself, never a test build.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let key = "didApplyLaunchAtLoginDefault"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

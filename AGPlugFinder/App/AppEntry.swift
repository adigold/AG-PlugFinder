import AppKit
import ServiceManagement
import SwiftUI
import AudioToolbox

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
        Button("My Purchases…") { LicensesWindow.shared.show() }
        Button("Share AG PlugFinder…") { ShareWindow.shared.show() }
        Button("Send Feedback to Goldi…") { FeedbackWindow.shared.show() }
        Button("Send Error Log to Goldi…") { CrashReports.sendLogs() }
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

    /// The AG PlugFinder mark (three bars, the bottom one strongest) as a template image, so
    /// macOS colours it for light and dark menu bars like every other menu bar icon.
    static let mark: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            let barH: CGFloat = 3.2, gap: CGFloat = 2.3, w: CGFloat = 14
            let top = (size.height - 3 * barH - 2 * gap) / 2
            for i in 0..<3 {
                let r = NSRect(x: (size.width - w) / 2, y: top + CGFloat(i) * (barH + gap), width: w, height: barH)
                NSColor.black.withAlphaComponent(i == 2 ? 1 : 0.5).setFill()
                NSBezierPath(roundedRect: r, xRadius: barH / 2, yRadius: barH / 2).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
    var body: some View {
        Image(nsImage: Self.mark)
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

    static func show() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { return }
        toggle()
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
        MainActor.assumeIsolated {
            HotKey.shared.apply()
            HyperKey.applyOnLaunch()
            // Ableton Live (BL-161): follow which program is in use, and keep the add-on in
            // Live's User Library up to date when Live is on this Mac.
            Host.watch()
            if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/Ableton/User Library").path) {
                AbletonBridge.installScript()
            }
        }
        _ = UserLibrary.shared
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in UserLibrary.shared.pullFromCloud(); Licenses.shared.pullFromCloud() }
        }
        Task { @MainActor in Updater.shared.start() }
        // Offers to send the report when the app closed unexpectedly last time (BL-73).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            CrashReports.checkOnLaunch()
        }
        // Tells the user when something they reported was fixed (BL-85).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            await Feedback.shared.announceFixed()
        }
        // Shares pictures taken before sharing existed, a little after launch (BL-71).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            PlugDB.shareExisting()
        }

        Task { @MainActor in
            let store = PluginStore.shared
            store.rescan()
            // Once: iZotope pictures taken before 0.9.6 show only a list of controls. Clear them
            // so they are taken again the new way, or come from the database or the web.
            if !UserDefaults.standard.bool(forKey: "fix.izotopePictures") {
                UserDefaults.standard.set(true, forKey: "fix.izotopePictures")
                let ids = store.plugins.filter { $0.manufacturer.localizedCaseInsensitiveContains("izotope") }.map(\.id)
                for id in ids {
                    try? FileManager.default.removeItem(at: store.snapshotURL(for: id))
                    store.update(id) { $0.snapshotState = .pending; $0.snapshotError = nil }
                }
                if !ids.isEmpty { store.snapshotChanged() }
            }
            if !OnboardingWindow.isDone {
                // First run: permissions first; the tour starts the scan itself.
                OnboardingWindow.shared.show()
            } else if store.plugins.contains(where: { $0.snapshotState == .pending }) {
                // Only new or updated plugins get a screenshot; the rest load from the cache.
                SnapshotQueue.shared.start()
            }
            PluginStore.shared.warmIndex()
            PluginWatcher.shared.start()
            Licenses.shared.refresh()
            // Categories other users chose for their plugins (BL-104), then, once, the offer to
            // share the user's own earlier changes.
            Task { @MainActor in
                await PlugDB.applyCommunityCategories()
                await PlugDB.refreshReplacedPictures()
                try? await Task.sleep(for: .seconds(12))
                if OnboardingWindow.isDone { PlugDB.offerEarlierCategories() }
            }
            #if DEBUG
            SelfTest.runIfRequested()
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Caps Lock works normally again while the app is not running.
        MainActor.assumeIsolated { if HyperKey.enabled { HyperKey.stop() } }
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


/// Plugins installed or removed while the app is open (Adi, 2026-10-31): macOS says so, and
/// the app rescans by itself, tells the user what is new and takes the new plugins' pictures.
@MainActor
final class PluginWatcher {
    static let shared = PluginWatcher()
    private var token: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    private var folderWatches: [DispatchSourceFileSystemObject] = []

    /// The Audio Units folders themselves: deleting a plugin there by hand does not always make
    /// macOS announce it (BL-142).
    private func watchFolders() {
        let fm = FileManager.default
        let folders = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/Components").path,
                       "/Library/Audio/Plug-Ins/Components"]
        for path in folders {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { PluginWatcher.shared.changed() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            folderWatches.append(source)
        }
    }

    func start() {
        guard token == nil else { return }
        watchFolders()
        token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kAudioComponentRegistrationsChangedNotification as String),
            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PluginWatcher.shared.changed() }
        }
    }

    /// Installers register several plugins in a row: wait for them to settle, then rescan once.
    private func changed() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            rescanNow(quietWhenNothingNew: true)
        }
    }

    /// Rescans the installed plugins, says what is new and takes the new plugins' pictures.
    /// Used by the watcher and by the Rescan Plugins button in Settings.
    func rescanNow(quietWhenNothingNew: Bool = false) {
        let store = PluginStore.shared
        let before = Set(store.plugins.map(\.id))
        store.rescan()
        let now = Set(store.plugins.map(\.id))
        let added = store.plugins.filter { !before.contains($0.id) }
        let removed = before.subtracting(now).count
        if removed > 0 {
            Toast.show(removed == 1 ? "Removed 1 plugin that is no longer installed" : "Removed \(removed) plugins that are no longer installed")
        }
        guard !added.isEmpty else {
            if !quietWhenNothingNew, removed == 0 { Toast.show("No new plugins found") }
            return
        }
        Toast.show(added.count == 1 ? "New plugin found: \(added[0].name)" : "Found \(added.count) new plugins")
        if !SnapshotQueue.shared.isRunning { SnapshotQueue.shared.start(only: Set(added.map(\.id))) }
    }
}
